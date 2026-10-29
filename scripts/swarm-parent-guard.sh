#!/usr/bin/env bash
# Internal shared helper for swarm.sh and loop.sh. It fingerprints the parent checkout without
# recording file contents: HEAD/ref, tracked status and diffs, non-runtime untracked path status,
# and refs outside the swarm's own branch namespace. This detects drift; it is not a sandbox and
# cannot detect a change that is later reverted or edits to an already-untracked file's contents.

wgm_swarm_parent_fingerprint() (
  local root="$1" prefix="$2" worktree_dir="$3" safe_prefix="$4" count="$5" runtime_dir="$6"
  local head ref status tracked unstaged staged refs relative i index index_dir scratch
  local -a scope=(.)
  # Even with GIT_OPTIONAL_LOCKS=0, `git diff` can refresh an index. Inspect a private copy instead;
  # the caller's actual index and any command-local GIT_INDEX_FILE override remain untouched.
  unset GIT_INDEX_FILE
  index="$(git -C "$root" rev-parse --git-path index 2>/dev/null)" || return 1
  [[ "$index" == /* ]] || index="$root/$index"
  # Keep the temporary index in Git metadata, not an operator-supplied TMPDIR that may itself be
  # inside the worktree and appear as a fresh untracked file to another parallel lane.
  index_dir="$(cd "$(dirname "$index")" && pwd -P)" || return 1
  scratch="$(mktemp "$index_dir/wgm-parent-index.XXXXXX")" || return 1
  trap 'rm -f "$scratch"' EXIT
  if [[ -f "$index" ]]; then cp "$index" "$scratch" || return 1; else rm -f "$scratch"; fi
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

  head="$(git -C "$root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || return 1
  ref="$(git -C "$root" symbolic-ref -q HEAD 2>/dev/null || true)"
  status="$(git -C "$root" status --porcelain=v1 --untracked-files=all -- "${scope[@]}" 2>/dev/null)" || return 1
  tracked="$(git -C "$root" status --porcelain=v1 --untracked-files=no 2>/dev/null)" || return 1
  unstaged="$(git -C "$root" diff --no-ext-diff --no-textconv --binary --no-color 2>/dev/null | git -C "$root" hash-object --stdin)" || return 1
  staged="$(git -C "$root" diff --cached --no-ext-diff --no-textconv --binary --no-color 2>/dev/null | git -C "$root" hash-object --stdin)" || return 1
  refs="$(git -C "$root" for-each-ref --format='%(refname) %(objectname)' refs/heads/ refs/tags/ refs/remotes/ 2>/dev/null)" || return 1
  refs="$(printf '%s\n' "$refs" | awk -v prefix="refs/heads/${prefix}/" 'index($0, prefix) != 1')" || return 1
  printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0' "$head" "$ref" "$status" "$tracked" "$unstaged" "$staged" "$refs" \
    | git -C "$root" hash-object --stdin
)
