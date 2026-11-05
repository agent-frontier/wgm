#!/usr/bin/env bash
# Internal shared helper for swarm.sh and loop.sh. It fingerprints the parent checkout without
# recording file contents: HEAD/ref, tracked status and diffs, non-runtime untracked path status,
# and refs outside the swarm's own branch namespace. This detects drift; it is not a sandbox and
# cannot detect a change that is later reverted or edits to an already-untracked file's contents.

# ONE neutralized git boundary for every host git call of the swarm machinery, defined HERE so it also holds in
# lane loop processes (loop.sh with WGM_SWARM_LANE=1), where swarm.sh's own wrappers do not exist. When lane u's
# sandbox.sh is loaded (swarm.sh and loop.sh both source it) the call goes through `wgm_host_git`, which adds the
# per-repository neutralizers (empty clean/smudge/process/textconv drivers, no credential helper, pager or editor:
# NO repository-configured command ever runs on the host); standalone it keeps the argv/env protections (no
# fsmonitor, no hooks, no transports, no lazy fetch). Trade-off: with filters disabled a filtered file whose stat
# changed may read as modified — callers fail closed (run `git status` once yourself to refresh the index).
wgm_neutral_git() {
  # (Re-entrancy: wgm_host_git's own base call runs `git`, which in swarm.sh is a function that lands back here;
  # the nested call must go straight to the real git with the fixed protections.)
  if [[ -z "${WGM_NEUTRAL_GIT_ACTIVE:-}" ]] && declare -F wgm_host_git >/dev/null 2>&1; then
    WGM_NEUTRAL_GIT_ACTIVE=1 wgm_host_git "$@"; return $?
  fi
  GIT_ALLOW_PROTOCOL='' GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat GIT_EDITOR=: \
    command git -c core.fsmonitor=false -c core.hooksPath=/dev/null -c protocol.allow=never \
    -c credential.helper= -c core.pager=cat -c core.editor=: "$@"
}

wgm_swarm_parent_fingerprint() (
  local root="$1" prefix="$2" worktree_dir="$3" safe_prefix="$4" count="$5" runtime_dir="$6"
  local head ref status tracked unstaged staged refs relative i index scratch scratch_dir common tb w
  local -a scope=(.)
  # Even with GIT_OPTIONAL_LOCKS=0, `git diff` can refresh an index. Inspect a private copy instead; the caller's
  # actual index and any command-local GIT_INDEX_FILE override remain untouched.
  # The copy is made WITHOUT following symlinks (an agent can swap the shared index for a symlink to a host file)
  # into a run-private 0700 dir OUTSIDE every mount — never inside the shared git dir, where sibling lanes could
  # read it. The copy must be a regular file, else the inspection is refused.
  unset GIT_INDEX_FILE
  # NO-FOLLOW git-dir boundary (lane u) before this batch of git calls: a planted link anywhere git may open → refuse.
  if declare -F sb_gitdir_guard >/dev/null 2>&1; then
    # (pinned expectation: argument 7, else the swarm-exported WGM_SWARM_PARENT_COMMON that lane loops inherit)
    local expect_common="${7:-${WGM_SWARM_PARENT_COMMON:-}}"
    if [[ -n "$expect_common" ]]; then ( sb_gitdir_guard "$root" full --expect-common "$expect_common" ) || return 2
    else ( sb_gitdir_guard "$root" full ) || return 2; fi
  fi
  # (`rev-parse --git-path index` RESOLVES a symlinked index to its target, hiding the swap: build the path from
  # the git dir instead, so the symlink itself is what gets examined.)
  index="$(wgm_neutral_git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  index="$index/index"
  common="$(wgm_neutral_git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  tb="${TMPDIR:-/tmp}"; [[ -d "$tb" ]] && tb="$(cd "$tb" && pwd -P)"
  for w in "$(cd "$root" && pwd -P)" "$common"; do
    [[ -n "$w" ]] && { [[ "$tb" == "$w" || "$tb" == "$w"/* ]] && tb=/tmp; }
  done
  scratch_dir="$(umask 077; mktemp -d "$tb/wgm-parent-guard.XXXXXX")" || return 1
  trap 'rm -rf "$scratch_dir"' EXIT
  scratch="$scratch_dir/index"
  if [[ -e "$index" || -L "$index" ]]; then
    cp -P -- "$index" "$scratch" 2>/dev/null || { echo "parent guard: cannot copy the git index $index (refusing)" >&2; return 2; }
    if [[ -L "$scratch" || ! -f "$scratch" || -L "$index" ]]; then
      echo "parent guard: the git index $index is not a regular file (symlink or special file written by an agent?) — refusing to read it" >&2
      return 2
    fi
  fi
  export GIT_INDEX_FILE="$scratch" GIT_OPTIONAL_LOCKS=0
  if [[ "$runtime_dir" == "$root/"* ]]; then
    relative="${runtime_dir#"$root"/}"
    scope+=(":(exclude,literal)$relative")
  fi

  # Runtime worktrees may be inside the source checkout. Exclude their paths from the untracked
  # status comparison, but still include every tracked file in the tracked-status/diff checks.
  if [[ "$worktree_dir" == "$root" ]]; then
    for ((i = 1; i <= count; i++)); do scope+=(":(exclude,literal)${safe_prefix}-${i}"); done
  elif [[ "$worktree_dir" == "$root/"* ]]; then
    relative="${worktree_dir#"$root"/}"
    scope+=(":(exclude,literal)$relative")
  fi

  head="$(wgm_neutral_git -C "$root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || return 1
  ref="$(wgm_neutral_git -C "$root" symbolic-ref -q HEAD 2>/dev/null || true)"
  status="$(wgm_neutral_git -C "$root" status --porcelain=v1 --untracked-files=all -- "${scope[@]}" 2>/dev/null)" || return 1
  tracked="$(wgm_neutral_git -C "$root" status --porcelain=v1 --untracked-files=no 2>/dev/null)" || return 1
  unstaged="$(wgm_neutral_git -C "$root" diff --no-ext-diff --no-textconv --binary --no-color 2>/dev/null | wgm_neutral_git -C "$root" hash-object --stdin)" || return 1
  staged="$(wgm_neutral_git -C "$root" diff --cached --no-ext-diff --no-textconv --binary --no-color 2>/dev/null | wgm_neutral_git -C "$root" hash-object --stdin)" || return 1
  refs="$(wgm_neutral_git -C "$root" for-each-ref --format='%(refname) %(objectname)' refs/heads/ refs/tags/ refs/remotes/ 2>/dev/null)" || return 1
  refs="$(printf '%s\n' "$refs" | awk -v prefix="refs/heads/${prefix}/" 'index($0, prefix) != 1')" || return 1
  printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0' "$head" "$ref" "$status" "$tracked" "$unstaged" "$staged" "$refs" \
    | wgm_neutral_git -C "$root" hash-object --stdin
)
