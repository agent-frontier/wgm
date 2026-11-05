#!/usr/bin/env bash
#
# wgm/swarm.sh — fan out N sandboxed Ralph loops in colocated jj workspaces (default) or Git worktrees.
#
# "Swarm coding": instead of one sequential loop, the sheepdog (this script) spawns several dogs that
# work in PARALLEL on independent slices, each in its own colocated jj workspace (the default when jj is
# available; otherwise one visible notice and a Git worktree) on its own branch. Each stream runs `scripts/loop.sh build`; review and merge the branches yourself.
# Memories from successful, identity-verified lanes are consolidated before cleanup and handed to
# `harvest-hive.sh`, which owns consent and anonymization. Failed/unverified lane memories remain
# in the retained lane for manual review; isolation does not eliminate later integration conflicts.
#
# Partition the work yourself: a --tasks file gives each stream a distinct scope (its loop.sh
# --request), or -n COUNT runs COUNT identical streams (useful for racing/diversity). Each stream
# commits its work to its branch so there is something to merge.
#
# Usage:
#   ./scripts/swarm.sh --tasks FILE [flags] -- <agent argv...>
#   ./scripts/swarm.sh -n COUNT     [flags] -- <agent argv...>
#
# Flags:
#   --tasks FILE        one stream per non-empty, non-`#` line; the line is that stream's scope
#                       (passed to loop.sh as --request)
#   -n, --count N       run N identical streams (ignored when --tasks is given)
#   --max-iterations N  per-stream loop.sh build iteration cap; 0 = until each self-stops (default: 0)
#   --prefix NAME       branch/worktree name prefix (default: wgm/swarm)
#   --backend jj|git    workspace lifecycle backend. Default: jj when this is a colocated jj repository,
#                       jj >= 0.46.0 and Git `worktree add --orphan` are available; otherwise ONE visible
#                       notice and the git backend. An explicit `--backend jj` never falls back (exit 2).
#   --worktree-dir DIR  base dir for the worktrees/workspaces (default: .wgm/worktrees)
#   --gates FILE        project-wide gate file forwarded to every lane
#   --cleanup           remove verified successful worktrees; failed/dirty lanes and branches are kept
#   --devcontainer | --no-devcontainer | --devcontainer-image TAG | --devcontainer-mount HOST[:CONTAINER]
#                       sandbox choices, passed through to the ONE preflight and every lane. Each lane's
#                       agent and gates run in a container mounting that lane's workspace; this script's
#                       workspace/branch bookkeeping stays on the host (plumbing-only Git).
#   --dry-run           print the plan and the sandbox decision (non-mutating); create nothing
#   -h | --help         show this help
#
# Everything after `--` is the agent argv, forwarded verbatim to each stream's loop.sh (or set
# $WGM_AGENT). The streams run with --commit so each branch carries its work.
#
# Exit status: 0 all lanes ok · 2 refused before any lane (bad input, dirty parent, sandbox preflight
# refusal — no workspace, branch, directory or lane is created) · 1 a lane or the setup failed.
#
# jj setup: Git must support `worktree add --orphan` (normally 2.42+; backports work). Git's
# `worktree add -h` normally exits 129. The Git fallback backend (used whenever jj is unavailable, or with --backend git) does not need this jj-only check.
# Operators: see docs/reference/cli-swarm.md#try-the-jj-backend in the installed skill directory.
# Contributors: run `bash scripts/test-jj-swarm.sh`; see CONTRIBUTING.md#check-git-for-jj.
#
# Partitioning rule (the default, and it matters):
#   * Give every stream a DISJOINT, non-overlapping file set. Disjoint lanes make consolidation an
#     octopus merge with zero conflicts; overlapping lanes risk something worse than a conflict —
#     one lane silently reverting a sibling's edits in a shared tree.
#   * Size each batch to the host's concurrency cap. Every ready lane launches concurrently; this
#     script has no queue/backfill, so run remaining tasks in later batches.
#   * Prefer a full-shell agent for lanes whose deliverables need nested directories and per-lane
#     commits. A constrained file-writer that cannot create intermediate dirs does not fail loudly —
#     it flattens paths, hides content in bootstrap scripts, and stops committing.
#   * After merging the branches, run the consolidation gate (scripts/check-docs.sh): cross-link
#     integrity and UTF-8 double-encoding are defects no single lane can see.
#
# Safety:
#   * Operates on the current git repo (run it from the target project root). Requires an
#     IMPLEMENTATION_PLAN.md (root or .wgm/) — run '/wgm plan' first.
#   * Lanes default to .wgm/worktrees/. Merge a stream with `git merge wgm/swarm/<i>`; inspect
#     failed lanes before removing Git worktrees or named jj workspaces and deleting branches.
#   * Each lane's request is pinned to its absolute worktree + branch. Host-side checks refuse to
#     commit on a different path, branch, or tip; they do not sandbox the agent's own commands.

set -euo pipefail

# (bash builtins only: no external tool runs before the host environment/PATH is sanitized — sb_bootstrap_host_env)
_h="${BASH_SOURCE[0]}"; if [[ "$_h" == */* ]]; then _h="${_h%/*}"; else _h=.; fi
HERE="$(cd "$_h" && pwd)"; unset _h
# shellcheck source=scripts/swarm-parent-guard.sh disable=SC1091
source "$HERE/swarm-parent-guard.sh"
LOOP="$HERE/loop.sh"
# shellcheck source=scripts/sandbox.sh disable=SC1091
source "$HERE/sandbox.sh"
ORIGINAL_ARGV=("$@")
# C7 phase 1 — the FIRST host action: in-process (builtins only) environment allowlist when this run may be
# sandboxed. The original environment is kept IN MEMORY (never exported, never on an argv) so an unsandboxed
# decision (recorded decline / --no-devcontainer outcome) can restore it.
SB_ORIG_ENV=""
if sb_sandbox_may_be_on "$@"; then
  SB_ORIG_ENV="$(export -p)"; sb_env_allowlist_inproc
  # The allowlist unsets the (non-allowlisted) GIT_* protection variables but keeps WGM_*: a re-exec'd pass would
  # otherwise see the "already applied" marker with the variables gone and never re-apply them (jj's git children
  # then ran unprotected). Re-applied below by sb_export_git_env.
  unset WGM_GIT_ENV_APPLIED
fi

# GIT SPLIT (C2): every host git call goes through this wrapper. On a LANE workspace (agent-written tree) the
# host uses PLUMBING only (rev-parse, symbolic-ref, update-ref, rev-list, merge-base, cat-file, show <rev>:<path>,
# ls-files, diff-index, for-each-ref). Porcelain (`status --porcelain`, ls-files -m) is allowed ONLY on the
# operator's PARENT checkout, which is never mounted into a lane. Host git is plumbing-only and neutralized: no fsmonitor, no hooks, no transports, no lazy
# fetch. Defined as a function so every host git call below (and in the sourced parent guard) carries it.
# The boundary itself (wgm_neutral_git) lives in swarm-parent-guard.sh so lane loop processes share it.
# (Run in a subshell: lane u's no-follow git-dir boundary inside wgm_host_git EXITS 2 on a planted link; that must
# be a failing git status here — the lane gets retained — never the end of the whole swarm.)
git() ( wgm_neutral_git "$@" )

TASKS_FILE=""
COUNT=0
MAXIT=0
PREFIX="wgm/swarm"
BACKEND=""
BACKEND_EXPLICIT=0
SB_FLAGS=()
SB_EXTRA_MOUNTS=()   # read by sandbox.sh's sb_mount_sources (private artifacts must lie outside every mount)
NO_DC=0
WT_DIR=".wgm/worktrees"
GATES_FILE=""
CLEANUP=0
DRY_RUN=0
AGENT_ARGV=()

usage() {  # builtins only (--help may run before the host tools are bound)
  local line n=0
  while IFS= read -r line; do
    n=$((n + 1)); [[ "$n" -eq 1 ]] && continue
    [[ "$line" == "#"* ]] || break
    line="${line#\#}"; line="${line# }"; printf '%s\n' "$line"
  done < "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --tasks) [[ $# -ge 2 ]] || { echo "--tasks requires a file" >&2; exit 2; }; TASKS_FILE="$2"; shift 2 ;;
    -n|--count) [[ $# -ge 2 ]] || { echo "--count requires a number" >&2; exit 2; }; COUNT="$2"; shift 2 ;;
    --max-iterations) [[ $# -ge 2 ]] || { echo "--max-iterations requires a number" >&2; exit 2; }; MAXIT="$2"; shift 2 ;;
    --prefix) [[ $# -ge 2 ]] || { echo "--prefix requires a name" >&2; exit 2; }; PREFIX="$2"; shift 2 ;;
    --backend) [[ $# -ge 2 ]] || { echo "--backend requires git or jj" >&2; exit 2; }; BACKEND="$2"; BACKEND_EXPLICIT=1; shift 2 ;;
    --devcontainer) SB_FLAGS+=(--devcontainer); shift ;;
    --no-devcontainer) NO_DC=1; SB_FLAGS+=(--no-devcontainer); shift ;;
    --devcontainer-image) [[ $# -ge 2 ]] || { echo "--devcontainer-image requires TAG" >&2; exit 2; }; SB_FLAGS+=(--devcontainer-image "$2"); shift 2 ;;
    --devcontainer-mount) [[ $# -ge 2 ]] || { echo "--devcontainer-mount requires HOST[:CONTAINER]" >&2; exit 2; }; SB_FLAGS+=(--devcontainer-mount "$2"); SB_EXTRA_MOUNTS+=("$2"); shift 2 ;;
    --worktree-dir) [[ $# -ge 2 ]] || { echo "--worktree-dir requires a dir" >&2; exit 2; }; WT_DIR="$2"; shift 2 ;;
    --gates) [[ $# -ge 2 ]] || { echo "--gates requires a file" >&2; exit 2; }; GATES_FILE="$2"; shift 2 ;;
    --cleanup) CLEANUP=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; AGENT_ARGV=("$@"); break ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *) echo "Unexpected argument: $1" >&2; exit 2 ;;
  esac
done

for n in "$COUNT" "$MAXIT"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "expected a non-negative integer, got: $n" >&2; exit 2; }
done
case "${BACKEND:-jj}" in git|jj) ;; *) echo "Invalid --backend: $BACKEND (expected git or jj)." >&2; exit 2 ;; esac

# Sandbox may be on: bind the host tools FIRST (builtins only up to here). Everything below may now run externals.
if [[ "$NO_DC" -eq 0 && "${WGM_DEVCONTAINER:-}" != 0 && -z "${WGM_IN_DEVCONTAINER:-}" ]]; then
  sb_bootstrap_host_env "$PWD"
fi

# ----- trusted runner FIRST: before any preflight, readiness probe, smoke, container or dry-run work ----------
# A contained preflight command (the agent's --version, the probe, the gate smoke) can rewrite an in-project
# skill dir; swarm and every lane loop must therefore already run from a private snapshot (lane loops inherit
# WGM_TRUSTED_RUNNER and load loop.sh from it). No-op unless the skill dir lies inside a writable mount.
[[ "$NO_DC" -eq 1 ]] || sb_ensure_trusted_runner "$HERE/swarm.sh" "${ORIGINAL_ARGV[@]}"
if [[ "${WGM_TRUSTED_RUNNER_OWNED:-}" == 1 && -n "${WGM_TRUSTED_RUNNER:-}" ]]; then
  # shellcheck disable=SC2034  # read by sb_cleanup (sandbox.sh)
  SB_SNAPSHOT="$WGM_TRUSTED_RUNNER"
  trap 'sb_cleanup' EXIT   # replaced by swarm_exit once it is defined; removes the snapshot on early refusals
fi

# Host git protections in the ENVIRONMENT of every process swarm starts (jj and anything it spawns, lane loops):
# sandbox_stage withdraws them again when the decision turns out to be unsandboxed (hooks are then the operator's).
SWARM_SAVED_GITENV=""
SWARM_GITENV_APPLIED=0
if [[ "$NO_DC" -eq 0 && "${WGM_DEVCONTAINER:-}" != 0 && -z "${WGM_IN_DEVCONTAINER:-}" ]]; then
  SWARM_SAVED_GITENV="$(export -p | grep -E '^declare -x (GIT_CONFIG_|GIT_ALLOW_PROTOCOL|GIT_NO_LAZY_FETCH|GIT_TERMINAL_PROMPT|WGM_GIT_ENV_APPLIED)' || true)"
  sb_export_git_env
  SWARM_GITENV_APPLIED=1
fi

# Lane Git commands must resolve their own repository and index, not an ambient parent override.
# Refuse before any Git/jj operation rather than silently redirecting a lane or hiding staged data.
for git_override in GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE; do
  if [[ -n "${!git_override:-}" ]]; then
    echo "Refusing to swarm with ambient $git_override; unset it and retry from the project root." >&2
    exit 2
  fi
done

if [[ -n "$GATES_FILE" ]]; then
  [[ -f "$GATES_FILE" ]] || { echo "gates file not found: $GATES_FILE" >&2; exit 2; }
  [[ -r "$GATES_FILE" ]] || { echo "gates file is unreadable: $GATES_FILE" >&2; exit 2; }
fi

# Never mask a refusal of the host-git boundary (lane u's git-dir guard / host-tool checks exit 2 with their own
# message) as "not a repository": surface it verbatim; reserve the repository message for a real non-repository.
inside_rc=0
inside_out="$(git rev-parse --is-inside-work-tree 2>&1)" || inside_rc=$?
if [[ "$inside_rc" -ne 0 || "$inside_out" != true ]]; then
  if [[ "$inside_rc" -eq 2 ]]; then printf '%s\n' "$inside_out" >&2; exit 2; fi
  echo "Not inside a git repository." >&2; exit 2
fi

TASKS=()
if [[ -n "$TASKS_FILE" ]]; then
  [[ -f "$TASKS_FILE" ]] || { echo "tasks file not found: $TASKS_FILE" >&2; exit 2; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    TASKS+=("$line")
  done < "$TASKS_FILE"
elif [[ "$COUNT" -gt 0 ]]; then
  for ((i = 1; i <= COUNT; i++)); do TASKS+=(""); done
else
  echo "Provide --tasks FILE or -n COUNT. See --help." >&2; exit 2
fi
[[ ${#TASKS[@]} -ge 1 ]] || { echo "No streams to run (empty --tasks file?)." >&2; exit 2; }

if [[ ${#AGENT_ARGV[@]} -eq 0 && -z "${WGM_AGENT:-}" ]]; then
  echo "No agent configured. Set \$WGM_AGENT or append -- argv. See --help." >&2; exit 2
fi

if [[ ! -f IMPLEMENTATION_PLAN.md && ! -f .wgm/IMPLEMENTATION_PLAN.md ]]; then
  echo "Refusing to swarm: no IMPLEMENTATION_PLAN.md found (root or .wgm/)." >&2
  echo "Run './scripts/loop.sh plan' (or '/wgm plan') first to create one." >&2
  exit 1
fi

git check-ref-format --branch "${PREFIX}/1" >/dev/null 2>&1 \
  || { echo "Invalid branch prefix: $PREFIX" >&2; exit 2; }
SAFE_PREFIX="${PREFIX//\//-}"
BASE_SHA="$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
  || { echo "A committed Git HEAD is required." >&2; exit 2; }
PARENT_ROOT="$(pwd -P)"
PARENT_GIT_ROOT="$(git rev-parse --show-toplevel)"
PARENT_GIT_ROOT="$(cd "$PARENT_GIT_ROOT" && pwd -P)"
PARENT_REF="$(git symbolic-ref -q HEAD 2>/dev/null || true)"
PARENT_COMMON=""

# Resolve Git's common directory physically so a jj repo backed by another Git store cannot be
# mistaken for a colocated workspace just because both tools find a repository in the same folder.
git_common_dir() {
  local root="$1" common
  common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || return 1
  (cd "$root" && cd "$common" && pwd -P)
}

parent_head_unchanged() {
  local head ref
  head="$(git -C "$PARENT_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || return 1
  ref="$(git -C "$PARENT_ROOT" symbolic-ref -q HEAD 2>/dev/null || true)"
  [[ "$head" == "$BASE_SHA" && "$ref" == "$PARENT_REF" ]]
}

parent_unchanged() {
  local status
  parent_head_unchanged || return 1
  status="$(GIT_OPTIONAL_LOCKS=0 git -C "$PARENT_ROOT" status --porcelain=v1 --untracked-files=all 2>/dev/null)" || return 1
  [[ -z "$status" ]]
}

jj_workspace_records() {
  jj --ignore-working-copy -R "$PARENT_ROOT" workspace list -T 'name ++ "\t" ++ root ++ "\n"'
}

jj_workspace_at() {
  local records expected
  records="$(jj_workspace_records)" || return 1
  expected="$(printf '%s\t%s' "$1" "$2")"
  grep -Fxq -- "$expected" <<<"$records"
}

# jj capability probes. Failure means "jj is not usable here": an explicit --backend jj turns it into a hard
# exit 2, the default degrades to Git with ONE visible notice. Repository-state refusals (dirty parent,
# un-ignored runtime paths) are never a reason to fall back: they exit 2 for either selection.
JJ_MSG=""
JJ_DIRTY=0
jj_capable() {
  local jj_version jj_major jj_minor git_help_rc git_worktree_help git_root jj_root jj_common
  command -v jj >/dev/null 2>&1 || { JJ_MSG="The jj backend requires jj 0.46.0 or newer on PATH."; return 1; }
  jj_version="$(jj --version 2>/dev/null)" || { JJ_MSG="Could not determine jj version."; return 1; }
  if [[ ! "$jj_version" =~ ^jj[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    JJ_MSG="Unrecognized jj version: $jj_version (requires 0.46.0 or newer)."; return 1
  fi
  jj_major="${BASH_REMATCH[1]}"; jj_minor="${BASH_REMATCH[2]}"
  if (( 10#$jj_major == 0 && 10#$jj_minor < 46 )); then
    JJ_MSG="Unsupported jj version: $jj_version (requires 0.46.0 or newer)."; return 1
  fi
  # jj creates colocated workspaces using Git's orphan-worktree option. Probe the actual
  # capability rather than rejecting a vendor backport solely on its version string. Git help
  # normally exits 129; other errors must not become success just because they mention the flag.
  # (A help probe reads no repository, so it bypasses the host-git wrapper.)
  git_help_rc=0
  git_worktree_help="$(LC_ALL=C command git worktree add -h 2>&1)" || git_help_rc=$?
  if [[ "$git_help_rc" -ne 0 && "$git_help_rc" -ne 129 ]] \
    || ! grep -Eq '(^usage:.*--orphan|^[[:space:]]*(\[--orphan\]|--orphan|--\[no-\]orphan)([[:space:]=]|$))' <<<"$git_worktree_help" \
    || grep -Eiq '^[[:space:]]*(fatal|error):' <<<"$git_worktree_help"; then
    JJ_MSG="The jj backend requires git worktree add --orphan (normally Git 2.42 or newer); install a compatible Git or use --backend git."
    return 1
  fi
  git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || { JJ_MSG="Cannot locate Git root."; return 1; }
  git_root="$(cd "$git_root" && pwd -P)"
  [[ "$git_root" == "$PARENT_ROOT" ]] || { JJ_MSG="The jj backend must run from the project root."; return 1; }
  # A dirty parent is a state refusal, not a missing capability: remember it, keep probing, decide below.
  parent_unchanged || JJ_DIRTY=1
  if [[ "$JJ_DIRTY" -eq 1 && "$BACKEND_EXPLICIT" -eq 1 ]]; then
    JJ_MSG="The jj backend requires a clean parent checkout at its original Git HEAD. (If a clean/smudge filter is configured, run git status once yourself to refresh the index, then rerun.)"; return 1
  fi
  jj_root="$(jj --ignore-working-copy workspace root 2>/dev/null)" \
    || { JJ_MSG="The jj backend requires an existing colocated jj workspace; it will not initialize one."; return 1; }
  jj_root="$(cd "$jj_root" && pwd -P)"
  [[ "$jj_root" == "$PARENT_ROOT" ]] || { JJ_MSG="The jj workspace and Git project roots differ."; return 1; }
  jj_common="$(jj --ignore-working-copy git root 2>/dev/null)" \
    || { JJ_MSG="The jj backend requires a Git-backed colocated workspace."; return 1; }
  jj_common="$(cd "$jj_common" && pwd -P)"
  PARENT_COMMON="$(git_common_dir "$PARENT_ROOT")" || { JJ_MSG="Cannot locate Git common directory."; return 1; }
  [[ "$jj_common" == "$PARENT_COMMON" ]] \
    || { JJ_MSG="The jj workspace is backed by a different Git store; use a colocated workspace."; return 1; }
  return 0
}

if [[ -z "$BACKEND" ]]; then
  if jj_capable; then
    BACKEND=jj
  else
    BACKEND=git
    PARENT_COMMON=""
    JJ_DIRTY=0
    [[ -n "${WGM_SWARM_DECISION_OWNED:-}" ]] || echo "swarm: jj backend unavailable (${JJ_MSG}) — using the git backend (worktrees)." >&2
  fi
elif [[ "$BACKEND" == jj ]]; then
  jj_capable || { echo "$JJ_MSG" >&2; exit 2; }
fi

if [[ "$BACKEND" == jj ]]; then
  [[ "$JJ_DIRTY" -eq 0 ]] || { echo "The jj backend requires a clean parent checkout at its original Git HEAD. (If a clean/smudge filter is configured, run git status once yourself to refresh the index, then rerun.)" >&2; exit 2; }
  # A project may deliberately track individual .wgm files. Check the ignore rule for generated
  # runtime paths without mistaking those tracked files for evidence that new scratch is ignored.
  for scratch in .wgm/.wgm-ignore-probe .wgm/metrics/.wgm-ignore-probe \
    .wgm/swarm-logs/.wgm-ignore-probe .wgm/memories.md; do
    git check-ignore --no-index -q -- "$PARENT_ROOT/$scratch" \
      || { echo "The jj backend requires .wgm/ runtime paths to be Git-ignored so they are not snapshotted." >&2; exit 2; }
  done
  [[ "$PARENT_ROOT" != *$'\n'* && "$PARENT_ROOT" != *$'\t'* && "$WT_DIR" != *$'\n'* && "$WT_DIR" != *$'\t'* ]] \
    || { echo "The jj project and workspace paths cannot contain tabs or newlines." >&2; exit 2; }
fi

# ----- sandbox: ONE preflight before any lane, one decision file for every lane ----------------------
SWARM_SB_MODE=""
SWARM_SB_REASON=""
SWARM_DECISION=""

# Strip ONE quote pair that wraps the WHOLE entry (same semantics as loop.sh's strip_wrapping_quotes): a quote
# that belongs to the command (`sh -c 'echo ready'`) must reach bash -c untouched.
swarm_strip_wrapping_quotes() {
  local v="$1"
  if [[ ${#v} -ge 2 && ( ( "${v:0:1}" == '"' && "${v: -1}" == '"' ) || ( "${v:0:1}" == "'" && "${v: -1}" == "'" ) ) ]]; then
    v="${v:1:${#v}-2}"
  fi
  printf '%s' "$v"
}

# The gate commands the lanes will run, parsed exactly as loop.sh parses them, one array element per gate
# (never joined: each runs as its own `bash -c "$gate"`). Fills SWARM_GATES.
swarm_gates() {
  local file="$PARENT_GATES_FILE_EARLY" header inline g gl=()
  SWARM_GATES=()
  [[ -n "$file" && -r "$file" ]] || return 0
  header="$(awk '/^[[:space:]]*gates[[:space:]]*:/ { print; exit }' "$file")"
  [[ -n "$header" ]] || return 0
  if [[ "$header" =~ gates[[:space:]]*:[[:space:]]*\[(.*)\] ]]; then
    inline="${BASH_REMATCH[1]}"
    IFS=',' read -r -a gl <<< "$inline"
  else
    mapfile -t gl < <(awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*gates[[:space:]]*:[[:space:]]*$/ { g=1; next }
      g && /^[[:space:]]*-[[:space:]]+/ { sub(/^[[:space:]]*-[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; next }
      g && /^[^[:space:]#]/ { g=0 }
    ' "$file")
  fi
  for g in "${gl[@]}"; do
    g="${g#"${g%%[![:space:]]*}"}"; g="${g%"${g##*[![:space:]]}"}"
    g="$(swarm_strip_wrapping_quotes "$g")"
    [[ -n "$g" ]] && SWARM_GATES+=("$g")
  done
  return 0
}

swarm_preflight_args() {  # swarm_preflight_args PROJECT — fills SWARM_PF
  local g
  SWARM_PF=(preflight --project "${1:-$PARENT_ROOT}")
  # argv[0] is an OPAQUE pathname (a path containing a space stays one executable; identity = basename of the whole
  # path): --agent-exe. The shell-command TEXT forms (WGM_AGENT / frugal agent) stay --agent-cmd.
  if [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then SWARM_PF+=(--agent-exe "${AGENT_ARGV[0]}")
  elif [[ -n "${WGM_AGENT:-}" ]]; then SWARM_PF+=(--agent-cmd "$WGM_AGENT"); fi
  [[ -n "${WGM_FRUGAL_AGENT:-}" ]] && SWARM_PF+=(--agent-cmd "$WGM_FRUGAL_AGENT")
  SWARM_PF+=("${SB_FLAGS[@]}")
  swarm_gates
  for g in "${SWARM_GATES[@]}"; do SWARM_PF+=(--gate-cmd "$g"); done
  return 0
}

PARENT_GATES_FILE_EARLY=""
if [[ -n "$GATES_FILE" ]]; then PARENT_GATES_FILE_EARLY="$GATES_FILE"
elif [[ -f wgm.yml ]]; then PARENT_GATES_FILE_EARLY="wgm.yml"
elif [[ -f .wgm/gates.yml ]]; then PARENT_GATES_FILE_EARLY=".wgm/gates.yml"; fi

# Remove containers a lane's loop left behind: names are wgm-<repo-key8>-<loop pid>-<seq>; only those whose
# loop process is gone are ours to remove (a live sibling swarm/loop of the same repo keeps its own).
# Returns non-zero when cleanup could not be VERIFIED: an engine `ps` that fails is never read as "nothing left"
# (every lane loop's container handle wgm-<key8>-<loop pid>-* is reported as retained), nor is a container that
# could not be confirmed removed.
sweep_containers() {
  [[ "$SWARM_SB_MODE" == on && -n "${SB_KEY8:-}" && -n "${SB_ENGINE:-}" && "$SB_ENGINE" != none ]] || return 0
  local names n pid lp rc=0
  # Bounded (sb_bounded, lane u): a hung engine client must not hang the sweep. Output goes to a file so an
  # orphaned child of a hung client cannot hold a pipe open; a timeout is an inspection failure like any other.
  local psout ps_ok=1
  psout="$(mktemp "${TMPDIR:-/tmp}/wgm-swarm-ps.XXXXXX")" || psout=""
  if [[ -n "$psout" ]] && sb_bounded "${SB_CALL_BOUND:-5}" "$SB_ENGINE" ps -a --filter "name=wgm-${SB_KEY8}-" --format '{{.Names}}' >"$psout" 2>/dev/null; then
    names="$(cat "$psout")"
  else
    ps_ok=0
  fi
  [[ -z "$psout" ]] || rm -f "$psout"
  if [[ "$ps_ok" -eq 0 ]]; then
    for lp in "${LANE_LOOP_PIDS[@]}"; do
      [[ -n "$lp" ]] && printf 'cleanup unverified: retained container wgm-%s-%s-* (engine inspection failed; remove with: %s rm -f <name>)\n' "$SB_KEY8" "$lp" "$SB_ENGINE" >&2
    done
    printf 'cleanup unverified: %s ps failed; lane containers may remain\n' "$SB_ENGINE" >&2
    return 1
  fi
  while IFS= read -r n; do
    [[ "$n" == "wgm-${SB_KEY8}-"* ]] || continue
    pid="${n#"wgm-${SB_KEY8}-"}"; pid="${pid%%-*}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    # ONLY containers of THIS swarm's lane loops (membership in LANE_LOOP_PIDS): another run's retained container in
    # the same repository is never ours to remove.
    sb_has "$pid" "${LANE_LOOP_PIDS[@]}" || continue
    kill -0 "$pid" 2>/dev/null && continue
    sb_reap "$n" || rc=1
  done <<<"$names"
  return "$rc"
}

# Throwaway preflight workspace (outside the parent tree, in a private temp dir; same backend as the lanes) and the
# supervised preflight run. Teardown is ACCOUNTABLE: remove, then VERIFY absence (jj workspace list / git worktree
# list AND the directory); anything left is reported with its exact recovery command and fails the run.
SWARM_PF_ROOT=""; SWARM_PF_DIR=""; SWARM_PF_NAME=""; SWARM_PF_PID=""
SWARM_PF_RETAINED=0; SWARM_INDEX_TAMPERED=0; SWARM_IN_TEARDOWN=0; SWARM_SIG_PENDING=0
# The base dir for EVERY private swarm artifact (decision file, containment files, preflight workspace, temp dir):
# $TMPDIR or /tmp, whichever lies outside EVERY mount — the parent/common dir and, when a container can run, every
# approved extra mount (lane u's sb_private_base/sb_outside_all_mounts; exit 2 naming the mount when neither does).
swarm_private_base() {
  local b w c
  if [[ "$NO_DC" -eq 0 && "${WGM_DEVCONTAINER:-}" != 0 && -z "${WGM_IN_DEVCONTAINER:-}" ]]; then
    [[ -n "${SB_PROJECT:-}" ]] || sb_repo_layout "$PARENT_ROOT"
    sb_private_base; return $?
  fi
  for b in "${TMPDIR:-/tmp}" /tmp; do
    [[ -d "$b" ]] || continue
    c="$(sb_canon "$b")"
    for w in "$PARENT_ROOT" "${PARENT_COMMON:-$PARENT_ROOT/.git}"; do [[ "$c" == "$w" || "$c" == "$w/"* ]] && continue 2; done
    printf '%s' "$b"; return 0
  done
  echo "no safe location for private swarm artifacts (TMPDIR and /tmp are inside the project)" >&2; return 2
}
swarm_pf_mkroot() {  # private 0700 dir outside the parent tree and git dir (holds the workspace + preflight output)
  local tb
  tb="$(swarm_private_base)" || return 1
  SWARM_PF_ROOT="$(umask 077; mktemp -d "$tb/wgm-swarm-pf.XXXXXX")" || { SWARM_PF_ROOT=""; return 1; }
  SWARM_PF_ROOT="$(cd "$SWARM_PF_ROOT" && pwd -P)"
  SWARM_PF_DIR="$SWARM_PF_ROOT/ws"
  SWARM_PF_NAME="wgm-preflight-$$"
}
swarm_pf_create() {
  if [[ "$BACKEND" == jj ]]; then
    jj -R "$PARENT_ROOT" --config 'snapshot.auto-track="none()"' workspace add --name "$SWARM_PF_NAME" --colocate \
      --sparse-patterns full -r "$BASE_SHA" "$SWARM_PF_DIR" >/dev/null 2>&1 || return 1
  else
    git -C "$PARENT_ROOT" worktree add -q --detach "$SWARM_PF_DIR" "$BASE_SHA" >/dev/null 2>&1 || return 1
  fi
}
# Re-capture the PREFLIGHT pins after an authorized change swarm itself made to the shared store (lane u's U49 contract:
# verify immediately before — every wgm_host_git call does — change, then re-pin; never disable verification).
swarm_repin_pf() {
  [[ -n "${WGM_PIN_FILE:-}" && -f "$SWARM_PF_ROOT/pins" ]] || return 0
  ( sb_pin_recapture_to "$SWARM_PF_ROOT/pins" ) && return 0
  echo "swarm: preflight teardown: cannot re-pin the shared git store" >&2; return 1
}
# Returns 0 only when the workspace and its directory are VERIFIED gone. Never silent about a failure.
# The shared git dir is writable by every container (preflight readiness included): before ANY host jj/git call
# that would read the parent's index, prove it is still a regular file (never a symlink an agent pointed elsewhere).
swarm_parent_index_safe() {
  local idx gd
  # No git call to find the path (the git-dir boundary itself refuses a tampered dir: failure here = unsafe), and
  # never `--git-path index` (it resolves a symlinked index to its target and would hide the swap).
  if [[ -d "$PARENT_ROOT/.git" && ! -L "$PARENT_ROOT/.git" ]]; then gd="$PARENT_ROOT/.git"
  else
    gd="$(git -C "$PARENT_ROOT" rev-parse --absolute-git-dir 2>/dev/null)" || {
      echo "swarm: cannot locate the parent git dir safely — refusing to run jj/git against it." >&2; return 1; }
  fi
  idx="$gd/index"
  [[ ! -L "$idx" && ( ! -e "$idx" || -f "$idx" ) ]] && return 0
  echo "swarm: the parent git index $idx is not a regular file (written by an agent?) — refusing to run jj/git against it." >&2
  return 1
}
swarm_pf_remove() {
  [[ -n "$SWARM_PF_ROOT" ]] || return 0
  SWARM_IN_TEARDOWN=1
  local out records wts left=0 reg=0 cl
  if [[ -s "$SWARM_PF_ROOT/containment.lost" ]]; then
    # CONTAINMENT LOST in the preflight: a container could not be confirmed gone. Terminal — NO host jj/git at all
    # (no forget, no worktree remove, no prune): list the handles with their recovery, retain the workspace.
    SWARM_PF_RETAINED=1
    while IFS= read -r cl; do
      [[ "$cl" == "retained container "* ]] || continue
      printf '%s — recover: podman rm -f -t 0 %s  (docker: docker rm -f %s)\n' "$cl" "${cl#retained container }" "${cl#retained container }" >&2
    done < "$SWARM_PF_ROOT/containment.lost"
    if [[ "$BACKEND" == jj ]]; then
      printf 'retained preflight workspace %s at %s — recover: jj workspace forget %s && rm -rf %s\n' "$SWARM_PF_NAME" "$SWARM_PF_DIR" "$SWARM_PF_NAME" "$SWARM_PF_DIR" >&2
    else
      printf 'retained preflight workspace %s at %s — recover: git worktree remove --force %s\n' "$SWARM_PF_NAME" "$SWARM_PF_DIR" "$SWARM_PF_DIR" >&2
    fi
    SWARM_PF_ROOT=""; SWARM_IN_TEARDOWN=0
    return 1
  fi
  # TRUST: the preflight's containers could write the shared store (executable config, pointers, links). Before ANY
  # jj/git here: a non-empty trust file from the preflight, or failing pin verification (git-free), retains the
  # workspace with its recovery, names the changed path, runs NO host git/jj and ends the run with exit 2.
  local tl="" tv="" tvrc=0
  [[ ! -s "$SWARM_PF_ROOT/trust.lost" ]] || tl="$(cat "$SWARM_PF_ROOT/trust.lost")"
  if [[ -f "$SWARM_PF_ROOT/pins" ]]; then tv="$( (sb_pin_verify_from "$SWARM_PF_ROOT/pins") 2>&1 )" || tvrc=$?; fi
  if [[ -n "$tl" || "$tvrc" -ne 0 ]]; then
    SWARM_INDEX_TAMPERED=1; SWARM_PF_RETAINED=1
    echo "✗ trust lost in the shared git store during the preflight (executable configuration, pointers or links changed). No host git/jj is run against it." >&2
    [[ -z "$tl" ]] || printf '%s\n' "$tl" >&2
    [[ "$tvrc" -eq 0 ]] || printf '%s\n' "$tv" >&2
    echo "  recovery: restore the named path from a known-good copy (re-create the file content you expect, put a pointer's original content back, remove a LINK itself — never its target), then remove the workspace below." >&2
    if [[ "$BACKEND" == jj ]]; then
      printf 'retained preflight workspace %s at %s — recover: jj workspace forget %s && rm -rf %s\n' "$SWARM_PF_NAME" "$SWARM_PF_DIR" "$SWARM_PF_NAME" "$SWARM_PF_DIR" >&2
    else
      printf 'retained preflight workspace %s at %s — recover: git worktree remove --force %s\n' "$SWARM_PF_NAME" "$SWARM_PF_DIR" "$SWARM_PF_DIR" >&2
    fi
    SWARM_PF_ROOT=""; SWARM_IN_TEARDOWN=0
    return 1
  fi
  # (WGM_PIN_FILE stays ON through the whole teardown — lane u's U49: after each AUTHORIZED change swarm itself makes to
  # the shared store (jj forget, worktree remove, prune) the pins are RE-CAPTURED explicitly, never switched off.)
  if ! swarm_parent_index_safe; then
    SWARM_INDEX_TAMPERED=1
    # No jj/git call may touch the tampered index: leave the workspace for the operator, with its recovery line.
    SWARM_PF_RETAINED=1
    if [[ "$BACKEND" == jj ]]; then
      printf 'retained preflight workspace %s at %s — recover: jj workspace forget %s && rm -rf %s\n' "$SWARM_PF_NAME" "$SWARM_PF_DIR" "$SWARM_PF_NAME" "$SWARM_PF_DIR" >&2
    else
      printf 'retained preflight workspace %s at %s — recover: git worktree remove --force %s\n' "$SWARM_PF_NAME" "$SWARM_PF_DIR" "$SWARM_PF_DIR" >&2
    fi
    SWARM_PF_ROOT=""; SWARM_IN_TEARDOWN=0
    return 1
  fi
  if [[ -d "$SWARM_PF_DIR" || "$BACKEND" == jj ]]; then
    if [[ "$BACKEND" == jj ]]; then
      out="$(jj -R "$PARENT_ROOT" --config 'snapshot.auto-track="none()"' workspace forget "$SWARM_PF_NAME" 2>&1)" \
        || echo "swarm: preflight teardown: jj workspace forget ${SWARM_PF_NAME} failed: ${out}" >&2
      swarm_repin_pf || left=1
      if records="$(jj --ignore-working-copy -R "$PARENT_ROOT" workspace list -T 'name ++ "\n"' 2>&1)"; then
        if grep -Fxq -- "$SWARM_PF_NAME" <<<"$records"; then reg=1; fi
      else
        echo "swarm: preflight teardown: cannot inspect jj workspaces: ${records}" >&2; reg=1
      fi
    fi
    # (after a jj forget the colocated git worktree entry is normally already gone: only remove what is still listed)
    if [[ -d "$SWARM_PF_DIR" && "$reg" -eq 0 ]] \
       && git -C "$PARENT_ROOT" worktree list --porcelain 2>/dev/null | grep -Fxq -- "worktree $SWARM_PF_DIR"; then
      out="$(git -C "$PARENT_ROOT" worktree remove --force "$SWARM_PF_DIR" 2>&1)" \
        || echo "swarm: preflight teardown: git worktree remove ${SWARM_PF_DIR} failed: ${out}" >&2
      swarm_repin_pf || left=1
    fi
  fi
  # A still-registered jj workspace keeps its directory: the printed recovery command needs it.
  if [[ "$reg" -eq 0 ]]; then
    # (the workspace dir only: the pin file lives in SWARM_PF_ROOT until the last verified git call below)
    rm -rf -- "$SWARM_PF_DIR" 2>/dev/null || echo "swarm: preflight teardown: could not remove ${SWARM_PF_DIR}" >&2
    git -C "$PARENT_ROOT" worktree prune >/dev/null 2>&1 || true
    swarm_repin_pf || left=1
  fi
  [[ "$reg" -eq 0 ]] || left=1
  if wts="$(git -C "$PARENT_ROOT" worktree list --porcelain 2>&1)"; then
    if grep -Fxq -- "worktree $SWARM_PF_DIR" <<<"$wts"; then left=1; fi
  else
    echo "swarm: preflight teardown: cannot inspect git worktrees: ${wts}" >&2; left=1
  fi
  # last verified git call done: the pin file goes with its private dir (a retained workspace keeps its dir)
  unset WGM_PIN_FILE
  if [[ "$reg" -eq 0 ]]; then rm -rf -- "$SWARM_PF_ROOT" 2>/dev/null || echo "swarm: preflight teardown: could not remove ${SWARM_PF_ROOT}" >&2; fi
  [[ ! -e "$SWARM_PF_ROOT" && ! -L "$SWARM_PF_ROOT" ]] || left=1
  if [[ "$left" -eq 1 ]]; then
    SWARM_PF_RETAINED=1
    if [[ "$BACKEND" == jj ]]; then
      printf 'retained preflight workspace %s at %s — recover: jj workspace forget %s && rm -rf %s\n' \
        "$SWARM_PF_NAME" "$SWARM_PF_DIR" "$SWARM_PF_NAME" "$SWARM_PF_DIR" >&2
    else
      printf 'retained preflight workspace %s at %s — recover: git worktree remove --force %s\n' \
        "$SWARM_PF_NAME" "$SWARM_PF_DIR" "$SWARM_PF_DIR" >&2
    fi
  fi
  SWARM_PF_ROOT=""
  SWARM_IN_TEARDOWN=0
  [[ "$left" -eq 0 ]]
}
# SHARED LIVE-CONTAINER REGISTRY (lane u's U46 contract). The first process creates it (sb_host_tmp_init exports
# WGM_LIVE_REGISTRY; the preflight child and every lane loop inherit it, and every `sandbox_exec` records its container
# name BEFORE launch). A supervisor that had to KILL a child therefore still knows every handle the child may have lost.
swarm_registry_init() {
  [[ -z "${SB_HOSTTMP:-}" ]] || return 0
  [[ -n "${SB_PROJECT:-}" ]] || sb_repo_layout "$PARENT_ROOT"
  sb_host_tmp_init
}
# Before an exec (traps do not run): drop the registry dir this process created, unless names are retained in it.
swarm_registry_release() {
  [[ -n "${SB_HOSTTMP:-}" ]] || return 0
  if [[ ! -e "$SB_HOSTTMP/retained" ]]; then rm -rf -- "$SB_HOSTTMP"; SB_HOSTTMP=""; unset WGM_LIVE_REGISTRY; fi
}
# Reap every registered name (engine: ours, else the registry's `engine` entry) not already listed under retained/;
# `retained container <name>` is printed by sb_reap for any it cannot confirm gone. Bounded by SB_DEADLINE.
# shellcheck disable=SC2317,SC2329  # invoked indirectly (by the signal handlers)
swarm_reap_registry() {
  local rd rn eng
  rd="$(sb_registry_dir)"   # (U48: the registry is a DIRECTORY of per-name entries: live/<name>, retained/<name>, engine)
  [[ -n "$rd" && -d "$rd/live" ]] || return 0
  if [[ "${SB_ENGINE:-none}" != podman && "${SB_ENGINE:-none}" != docker && -f "$rd/engine" ]]; then
    eng="$(cat "$rd/engine" 2>/dev/null || true)"
    case "$eng" in podman|docker) SB_ENGINE="$eng" ;; esac
  fi
  [[ "${SB_ENGINE:-none}" == podman || "${SB_ENGINE:-none}" == docker ]] || return 0
  while IFS= read -r rn; do
    [[ -n "$rn" ]] || continue
    [[ ! -e "$rd/retained/$rn" ]] || continue   # already printed as retained
    sb_reap "$rn" || true
  done < <(sb_registry_list)
}
# INT/TERM while the preflight runs (or while its workspace is being torn down). A signal during teardown is
# remembered and honoured once teardown has finished; otherwise: forward TERM to the preflight process (it removes
# its containers), wait a bounded time, KILL, tear down, exit 130/143.
# shellcheck disable=SC2317,SC2329  # invoked indirectly by the INT/TERM traps
swarm_pf_signal() {
  local code="$1" wd
  if [[ "$SWARM_IN_TEARDOWN" -eq 1 ]]; then SWARM_SIG_PENDING="$code"; return 0; fi
  trap '' INT TERM
  if [[ -n "$SWARM_PF_PID" ]]; then
    kill -TERM "$SWARM_PF_PID" 2>/dev/null || true
    # The child's own signal handler spends up to SB_CLEANUP_DEADLINE on container cleanup: it gets SB_CHILD_GRACE
    # (deadline + margin, from sandbox.sh) before KILL — never a shorter hard-coded wait.
    ( trap 'kill "$s" 2>/dev/null; exit 0' TERM; sleep "$SB_CHILD_GRACE" & s=$!; wait "$s"; kill -KILL "$SWARM_PF_PID" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
    wd=$!
    wait "$SWARM_PF_PID" 2>/dev/null || true
    kill "$wd" 2>/dev/null || true; wait "$wd" 2>/dev/null || true
    SWARM_PF_PID=""
    # a killed child may have lost handles: reap everything the shared registry still lists (fresh bounded budget)
    # shellcheck disable=SC2034  # read by sb_bounded (sandbox.sh)
    SB_DEADLINE=$((SECONDS + SB_CLEANUP_DEADLINE))
    swarm_reap_registry
  fi
  swarm_pf_remove || true
  exit "$code"
}

# shellcheck disable=SC2317,SC2329  # invoked indirectly by the EXIT trap
swarm_exit() {
  local rc=$?
  # Keep the swarm's own status — except that an unverifiable teardown of the preflight workspace may never
  # turn a successful run green.
  swarm_pf_remove || true
  # (own removals BEFORE sb_cleanup: sb_cleanup deletes the private bound-tools dir that `rm` itself resolves through)
  [[ -z "${SWARM_CTL_DIR:-}" ]] || rm -rf -- "$SWARM_CTL_DIR"
  [[ -z "${SWARM_TMPROOT:-}" ]] || rm -rf -- "$SWARM_TMPROOT"
  sb_cleanup || true
  if [[ "$SWARM_PF_RETAINED" -eq 1 && "$rc" -eq 0 ]]; then exit 1; fi
  return 0
}

sandbox_stage() {
  local decision="" rc=0 oldpath="$PATH" tb ddir dfile w script snap="" mode_line pf_project pf_td
  # EVERY process swarm starts from here on (preflight, the clean-env re-exec, lane loops) must not put private
  # artifacts under a TMPDIR that lies inside a mount (project, git dir, approved extra mounts known so far).
  local tbase
  tbase="$(swarm_private_base)" || exit 2
  if [[ "$(sb_canon "${TMPDIR:-/tmp}")" != "$(sb_canon "$tbase")" ]]; then export TMPDIR="$tbase"; fi
  if [[ -z "${WGM_HOST_ENV_CLEAN:-}" ]]; then
    sb_path_text_clean "$PARENT_ROOT"
    PATH="$SB_CLEAN_PATH"; export PATH
  fi
  if [[ -n "${WGM_SANDBOX_DECISION:-}" ]]; then
    sb_load_decision_file "$WGM_SANDBOX_DECISION"
    SWARM_DECISION="$WGM_SANDBOX_DECISION"
    [[ "${WGM_SWARM_DECISION_OWNED:-}" == 1 ]] && SB_OWNED_DECISION="$WGM_SANDBOX_DECISION"
    if [[ "$SB_MODE" == on ]]; then
      # Same rule as loop.sh: the decision must live outside EVERY mount (project, git dir, the decision's own and
      # the CLI's approved extra mounts, the skill bundle).
      sb_repo_layout "$PARENT_ROOT"
      sb_outside_all_mounts "$WGM_SANDBOX_DECISION" \
        || sb_die "decision file $WGM_SANDBOX_DECISION lies inside the mount $SB_INSIDE_OF, so a container could read it. Keep the decision file outside every mount."
    fi
  else
    # NO CONTAINER EVER MOUNTS THE PARENT (C4): the preflight's readiness command, probe and gate smoke run
    # in containers, so they get a THROWAWAY WORKSPACE at the parent's HEAD (same backend, same git common dir
    # and so the same approval record), removed right afterwards — also on refusal and on signals.
    pf_project="$PARENT_ROOT"
    trap 'swarm_pf_signal 130' INT
    trap 'swarm_pf_signal 143' TERM
    swarm_pf_mkroot || { echo "swarm: cannot create a private preflight dir; no lane was created." >&2; exit 2; }
    if [[ "$NO_DC" -eq 0 && "${WGM_DEVCONTAINER:-}" != 0 && -z "${WGM_IN_DEVCONTAINER:-}" ]]; then
      if ! swarm_pf_create; then
        swarm_pf_remove || exit 1
        echo "swarm: could not create the throwaway preflight workspace; no lane was created." >&2; exit 2
      fi
      pf_project="$SWARM_PF_DIR"
      # PIN the shared store BEFORE the preflight (before any container; the throwaway workspace already exists, so the
      # pinned admin-dir set includes it and still matches at its teardown). The overlay targets are created first so
      # the preflight's own startup does not change the digest. swarm_pf_remove verifies these pins before ANY git/jj.
      if ! { ( sb_repo_layout "$PARENT_ROOT"; sb_ensure_overlays ) && ( sb_pin_capture_to "$SWARM_PF_ROOT/pins" "$PARENT_ROOT" ); }; then
        swarm_pf_remove || true
        echo "swarm: cannot pin the shared git store before the preflight; no lane was created." >&2; exit 2
      fi
      # (lane u's U48) captured in a subshell, so the pin state never reaches this shell: WGM_PIN_FILE makes EVERY host
      # git call of swarm itself verify the pins first (until swarm_pf_remove's verdict; the teardown legitimately
      # changes the admin-dir set). The preflight child has its own pins and runs without it (see below).
      export WGM_PIN_FILE="$SWARM_PF_ROOT/pins"
    fi
    if [[ "$pf_project" != "$PARENT_ROOT" ]]; then swarm_registry_init; fi   # (containers will run: share the registry)
    swarm_preflight_args "$pf_project"
    # SUPERVISED: a background child + `wait` (interruptible) — a foreground $(...) would defer our signal traps
    # until the preflight ended. stdin stays attached (explicit <&0) so the ONE interactive prompt still works;
    # stderr stays on the terminal; only the decision text goes to a run-private file.
    # (containment-loss contract, lane u U20: the preflight child records every container whose absence it could not
    # confirm in this private file; swarm_pf_remove evaluates it BEFORE touching the workspace.)
    WGM_PIN_FILE="" WGM_CONTAINMENT_LOST_FILE="$SWARM_PF_ROOT/containment.lost" WGM_TRUST_LOST_FILE="$SWARM_PF_ROOT/trust.lost" WGM_HOST_ENV_QUIET=1 "$BASH" "$HERE/sandbox.sh" "${SWARM_PF[@]}" <&0 >"$SWARM_PF_ROOT/decision.out" &
    SWARM_PF_PID=$!
    wait "$SWARM_PF_PID" || rc=$?
    SWARM_PF_PID=""
    decision="$(cat "$SWARM_PF_ROOT/decision.out" 2>/dev/null || true)"
    pf_td=0
    swarm_pf_remove || pf_td=1
    [[ "$SWARM_SIG_PENDING" -eq 0 ]] || exit "$SWARM_SIG_PENDING"
    trap - INT TERM
    if [[ "$rc" -ne 0 ]]; then
      echo "swarm: sandbox preflight refused; no lane was created." >&2
      exit 2
    fi
    if [[ "$pf_td" -eq 1 ]]; then
      echo "swarm: the preflight workspace could not be removed; no lane was created." >&2
      exit "$(( SWARM_INDEX_TAMPERED == 1 ? 2 : 1 ))"
    fi
    sb_parse_decision <<<"$decision"
  fi
  SWARM_SB_MODE="$SB_MODE"; SWARM_SB_REASON="$SB_REASON"
  # C7 phase 2: only the credential env names the decision APPROVED survive (lane u's sb_apply_decision_env also
  # sets SB_KEEP_ENV for the clean-env re-exec below, so lanes inherit exactly the approved names); an unsandboxed
  # outcome restores the operator's original environment.
  if [[ "$SB_MODE" == on ]]; then sb_apply_decision_env; SB_ORIG_ENV=""
  elif [[ -n "$SB_ORIG_ENV" ]]; then eval "$SB_ORIG_ENV" 2>/dev/null || true; SB_ORIG_ENV=""; fi
  [[ "$SB_MODE" == on ]] || PATH="$oldpath"
  if [[ "$SB_MODE" != on && "$SWARM_GITENV_APPLIED" -eq 1 ]]; then
    # Unsandboxed outcome: the repository's hooks are the operator's again; put back what we found.
    local _gn
    for _gn in $(compgen -e | grep -E '^(GIT_CONFIG_|GIT_ALLOW_PROTOCOL$|GIT_NO_LAZY_FETCH$|GIT_TERMINAL_PROMPT$|WGM_GIT_ENV_APPLIED$)' || true); do unset "$_gn"; done
    [[ -z "$SWARM_SAVED_GITENV" ]] || eval "$SWARM_SAVED_GITENV"
  fi
  unset WGM_SWARM_DECISION_OWNED
  [[ -n "$SWARM_DECISION" ]] || {
    if [[ "$SB_MODE" == on ]]; then sb_repo_layout "$PARENT_ROOT"; fi
    tb="$(swarm_private_base)" || exit 2   # outside EVERY mount, approved extra mounts included (decision parsed above)
    ddir="$(umask 077; mktemp -d "$tb/wgm-decision.XXXXXX")" || sb_die "cannot create the decision dir"
    chmod 700 "$ddir"
    dfile="$ddir/decision"
    # Verbatim: only what preflight decided (credentials, env names, image, approved extra mounts). Each lane's
    # sandbox_exec derives its own project, git common dir and read-only overlays from its working tree.
    ( umask 077; printf '%s\n' "$decision" > "$dfile" )
    SWARM_DECISION="$dfile"
    if [[ "$SB_MODE" == on && -z "${WGM_HOST_ENV_CLEAN:-}" ]]; then
      export WGM_SANDBOX_DECISION="$dfile" WGM_SWARM_DECISION_OWNED=1
      script="$HERE/swarm.sh"
      if [[ -z "${WGM_TRUSTED_RUNNER:-}" ]]; then
        snap="$(sb_trusted_snapshot "$HERE/..")"
        if [[ -n "$snap" ]]; then export WGM_TRUSTED_RUNNER="$snap" WGM_TRUSTED_RUNNER_OWNED=1; script="$snap/scripts/swarm.sh"; fi
      fi
      swarm_registry_release   # exec skips the EXIT trap: do not leak this pass's registry dir
      sb_clean_env_exec 0 "$script" "${ORIGINAL_ARGV[@]}"
    fi
    # shellcheck disable=SC2034  # read by sb_cleanup (sandbox.sh)
    SB_OWNED_DECISION="$dfile"
  }
  # ---- (clean host environment from here on when sandboxed) ----
  if [[ -n "${WGM_DEBUG_HOST_ENV:-}" ]]; then compgen -e > "$WGM_DEBUG_HOST_ENV"; fi
  # shellcheck disable=SC2034  # read by sb_cleanup (sandbox.sh)
  [[ "${WGM_TRUSTED_RUNNER_OWNED:-}" == 1 && -n "${WGM_TRUSTED_RUNNER:-}" ]] && SB_SNAPSHOT="$WGM_TRUSTED_RUNNER"
  # The lanes get the decision (never ownership of it or of the runner snapshot: swarm deletes both).
  export WGM_SANDBOX_DECISION="$SWARM_DECISION"
  unset WGM_SANDBOX_DECISION_OWNED WGM_TRUSTED_RUNNER_OWNED
  if [[ "$SB_MODE" == on ]]; then
    sb_repo_layout "$PARENT_ROOT"
    mode_line="sandbox: on (${SB_ENGINE}, image ${SB_IMAGE}) — each lane's agent, gates and commits run in its own container"
  elif [[ "$SB_MODE" == inside ]]; then
    mode_line="sandbox: inside (already in a wgm devcontainer; lanes do not nest)"
  else
    mode_line="sandbox: OFF — unsandboxed (${SB_REASON})"
  fi
  echo "$mode_line"
  return 0
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "== wgm swarm (dry run) =="
  echo "streams=${#TASKS[@]} backend=${BACKEND} prefix=${PREFIX} worktree_dir=${WT_DIR} max_iterations=${MAXIT} cleanup=${CLEANUP} gates=${GATES_FILE:-auto}"
  if [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then echo "agent(argv)=${AGENT_ARGV[*]}"; else echo "agent=\$WGM_AGENT"; fi
  i=0
  for task in "${TASKS[@]}"; do
    i=$((i + 1))
    echo "  stream $i → branch ${PREFIX}/${i} (worktree ${WT_DIR}/${SAFE_PREFIX}-${i})${task:+ — ${task}}"
  done
  swarm_gates
  for g in "${SWARM_GATES[@]}"; do echo "  gate: ${g}"; done
  # Non-mutating: the preflight's own dry run prints the decision it would make or the unresolved prerequisite.
  swarm_preflight_args "$PARENT_ROOT"   # a dry run launches nothing, so the parent may be named
  rc=0
  dry_decision="$(WGM_HOST_ENV_QUIET=1 "$BASH" "$HERE/sandbox.sh" "${SWARM_PF[@]}" --dry-run)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then echo "swarm: sandbox preflight would refuse (exit $rc); no lane would be created." >&2; exit 2; fi
  echo "sandbox decision (dry run):"
  grep -E '^(sandbox|engine|reason|image)=' <<<"$dry_decision" | sed 's/^/  /'
  exit 0
fi

# The PARENT's canonical git common dir, captured ONCE, before any container runs: every lane guard below must
# resolve to exactly this (a lane's agent can rewrite its worktree's `commondir`/`.git` pointer to name another
# repository; the guard refuses that before it scans or opens anything there). Lane loops inherit it too.
if [[ -d "$PARENT_ROOT/.git" && ! -L "$PARENT_ROOT/.git" ]]; then
  PARENT_COMMON_PIN="$(cd "$PARENT_ROOT/.git" && pwd -P)"
else
  PARENT_COMMON_PIN="$(git_common_dir "$PARENT_ROOT")" || { echo "Cannot pin the parent git common directory." >&2; exit 2; }
fi
export WGM_SWARM_PARENT_COMMON="$PARENT_COMMON_PIN"
trap swarm_exit EXIT
sandbox_stage
# A TMPDIR inside the checkout would make every lane's temp files look like parent drift to the other lanes'
# parent guards. Lanes (and this script) get a private temp dir outside the project instead; removed on exit.
# (Same for a TMPDIR inside an approved extra mount: a container could read what swarm and its lanes put there.)
SWARM_TMPROOT=""
swarm_tmpbase="$(swarm_private_base)" || exit 2
if [[ "$(sb_canon "${TMPDIR:-/tmp}")" != "$(sb_canon "$swarm_tmpbase")" ]]; then
  SWARM_TMPROOT="$(umask 077; mktemp -d "$swarm_tmpbase/wgm-swarm-tmp.XXXXXX")" || { echo "cannot create a private temp dir" >&2; exit 2; }
  export TMPDIR="$SWARM_TMPROOT"
fi
# CONTAINMENT-LOSS files (lane u's contract): a private 0700 dir outside the parent tree; one file per lane loop plus
# one for swarm's own sweeps. Any non-empty file = a container could not be confirmed gone = terminal for the WHOLE
# swarm (see swarm_containment_stop): no further host git/jj of any kind.
SWARM_CTL_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/wgm-swarm-ctl.XXXXXX")" || { echo "cannot create the private containment dir" >&2; exit 2; }
chmod 700 "$SWARM_CTL_DIR"
export WGM_CONTAINMENT_LOST_FILE="$SWARM_CTL_DIR/swarm.lost"
# shared live-container registry for every lane loop (lane u's U46): created here, inherited through WGM_LIVE_REGISTRY
if [[ "$SWARM_SB_MODE" == on ]]; then swarm_registry_init; fi
# Re-capture the lane-phase pins after an authorized change swarm itself made to the shared store (removing a lane
# workspace): verified immediately before (every wgm_host_git call verifies), changed, re-pinned immediately after.
swarm_repin_lanes() {
  [[ "$SWARM_PINNED" -eq 1 ]] || return 0
  ( sb_pin_recapture_to "$SWARM_PIN_FILE" ) && return 0
  echo "✗ cannot re-pin the shared git store after removing a lane; the remaining lanes are retained." >&2
  return 1
}
containment_lost_any() { local f; for f in "$SWARM_CTL_DIR"/*.lost; do [[ -s "$f" ]] && return 0; done; return 1; }
# TRUST-LOST files (lane u's U30 contract): every lane loop gets its own WGM_TRUST_LOST_FILE; a pin/guard violation
# there (pointer contents, executable-config digest, a planted link, a redirected common dir) appends
# `trust lost <path>` before the loop exits 2. swarm also verifies the shared store's pins itself (SWARM_PIN_FILE).
export WGM_TRUST_LOST_FILE="$SWARM_CTL_DIR/swarm.trust"
SWARM_PIN_FILE="$SWARM_CTL_DIR/pins"
SWARM_PINNED=0
trust_lost_any() { local f; for f in "$SWARM_CTL_DIR"/*.trust; do [[ -s "$f" ]] && return 0; done; return 1; }
# Terminal stop for lost TRUST in the shared git store: name the changed path(s), retain every lane with its recovery,
# exit 2 — pure printing, NO host git/jj (no inspection, consolidation or cleanup).
swarm_trust_stop() {  # swarm_trust_stop [VERIFY-OUTPUT]
  local f line idx
  echo "✗ trust lost in the shared git store: an agent changed git pointers, links or executable configuration. Stopping the whole swarm; no further host git/jj, inspection, consolidation or cleanup runs." >&2
  for f in "$SWARM_CTL_DIR"/*.trust; do
    [[ -s "$f" ]] || continue
    while IFS= read -r line; do [[ "$line" == "trust lost "* ]] && printf '%s\n' "$line" >&2; done < "$f"
  done
  [[ -z "${1:-}" ]] || printf '%s\n' "$1" >&2
  echo "  recovery: restore the named path from a known-good copy (config/hooks/info: re-create the file content you expect; a pointer: put its original content back; a link: remove the LINK itself, never its target), then re-run." >&2
  for idx in "${!READY_DIRS[@]}"; do
    if [[ "$BACKEND" == jj ]]; then
      printf 'retained lane %s at %s (branch %s kept) — recover: after the restore above: jj workspace forget %s && rm -rf %s\n' \
        "${READY_NUMS[$idx]}" "${READY_DIRS[$idx]}" "${READY_BRANCHES[$idx]}" "${READY_NAMES[$idx]}" "${READY_DIRS[$idx]}" >&2
    else
      printf 'retained lane %s at %s (branch %s kept) — recover: after the restore above: git worktree remove --force %s\n' \
        "${READY_NUMS[$idx]}" "${READY_DIRS[$idx]}" "${READY_BRANCHES[$idx]}" "${READY_DIRS[$idx]}" >&2
    fi
  done
  exit 2
}
# Terminal stop: print every retained container (exact line + recovery) and every lane as retained with its recovery,
# exit non-zero. Pure printing: NO git, NO jj, NO file inspection, NO memory consolidation, NO --cleanup teardown.
swarm_containment_stop() {
  local f line idx names=""
  echo "✗ containment lost: at least one container could not be confirmed gone. Stopping the whole swarm; no further git/jj, inspection, consolidation or cleanup runs." >&2
  for f in "$SWARM_CTL_DIR"/*.lost; do
    [[ -s "$f" ]] || continue
    while IFS= read -r line; do
      [[ "$line" == "retained container "* ]] || continue
      [[ " $names " == *" ${line#retained container} "* ]] && continue
      names+="${line#retained container} "
      printf '%s — recover: %s rm -f %s\n' "$line" "${SB_ENGINE:-podman}" "${line#retained container }" >&2
    done < "$f"
  done
  for idx in "${!DIRS[@]}"; do
    if [[ "$BACKEND" == jj ]]; then
      printf 'retained lane %s at %s (branch %s kept) — recover: after removing the container(s) above: jj workspace forget %s && rm -rf %s\n' \
        "${LANE_NUMS[$idx]}" "${DIRS[$idx]}" "${BRANCHES[$idx]}" "${LANE_NAMES[$idx]}" "${DIRS[$idx]}" >&2
    else
      printf 'retained lane %s at %s (branch %s kept) — recover: after removing the container(s) above: git worktree remove --force %s\n' \
        "${LANE_NUMS[$idx]}" "${DIRS[$idx]}" "${BRANCHES[$idx]}" "${DIRS[$idx]}" >&2
    fi
  done
  exit 1
}
mkdir -p "$WT_DIR"
WT_ABS="$(cd "$WT_DIR" && pwd -P)"
if [[ "$BACKEND" == jj && ( "$WT_ABS" == *$'\n'* || "$WT_ABS" == *$'\t'* ) ]]; then
  echo "The resolved jj workspace directory cannot contain tabs or newlines." >&2; exit 2
fi
if [[ "$BACKEND" == jj && ( "$WT_ABS" == "$PARENT_ROOT" || "$WT_ABS" == "$PARENT_ROOT/"* ) ]]; then
  git check-ignore --no-index -q -- "$WT_ABS/.wgm-ignore-probe" \
    || { echo "The jj workspace directory inside the project must be Git-ignored: $WT_ABS" >&2; exit 2; }
fi
METRICS_DIR="$(pwd)/.wgm/metrics"
mkdir -p "$METRICS_DIR"
LOG_DIR="$(pwd)/.wgm/swarm-logs"
mkdir -p "$LOG_DIR"
pf_rc=0
PARENT_FINGERPRINT="$(wgm_swarm_parent_fingerprint "$PARENT_GIT_ROOT" "$PREFIX" "$WT_ABS" "$SAFE_PREFIX" "${#TASKS[@]}" "$PARENT_ROOT/.wgm")" || pf_rc=$?
if [[ "$pf_rc" -ne 0 ]]; then
  echo "Could not inspect the parent checkout, index, or non-lane refs; refusing to swarm." >&2
  exit "$(( pf_rc == 2 ? 2 : 1 ))"
fi
parent_state_matches() {
  local current
  current="$(wgm_swarm_parent_fingerprint "$PARENT_GIT_ROOT" "$PREFIX" "$WT_ABS" "$SAFE_PREFIX" "${#TASKS[@]}" "$PARENT_ROOT/.wgm")" || return 1
  [[ "$current" == "$PARENT_FINGERPRINT" ]]
}
SWARM_START=$(date +%s)
PARENT_GATES_FILE=""
if [[ -n "$GATES_FILE" ]]; then
  PARENT_GATES_FILE="$GATES_FILE"
elif [[ -f wgm.yml ]]; then
  PARENT_GATES_FILE="wgm.yml"
elif [[ -f .wgm/gates.yml ]]; then
  PARENT_GATES_FILE=".wgm/gates.yml"
fi
if [[ -n "$PARENT_GATES_FILE" && "$PARENT_GATES_FILE" != /* ]]; then
  PARENT_GATES_FILE="$(cd "$(dirname "$PARENT_GATES_FILE")" && pwd)/$(basename "$PARENT_GATES_FILE")"
fi

# Tracked paths of a LANE whose working file differs from the index (plumbing only; over-reports, never hides):
# a symlink/non-regular entry, a missing file, an exec-bit change or a differing unfiltered blob is "modified".
# Every host READ of a lane-writable path first proves the path AND every ancestor inside the lane are real,
# non-symlink entries. `lane_path_safe LANE REL` for a regular-file entry uses lane u's sb_safe_path (run in a
# subshell with SB_PROJECT = the lane, so its exit is a status): a symlink at/above REL, or a non-regular REL, fails.
# `lane_path_safe LANE REL ancestors` (a tracked symlink entry is legitimately a symlink itself) walks the
# directories above REL the same way. A failure means "unverified": never opened, never followed.
lane_path_safe() (
  local lane="$1" rel="$2" mode="${3:-full}" d
  if [[ "$mode" != ancestors ]]; then
    SB_PROJECT="$lane"
    sb_safe_path "$lane/$rel"
    return $?
  fi
  d="$(dirname "$lane/$rel")"
  while [[ "$d" != "$lane" && "$d" != "/" && -n "$d" ]]; do
    [[ ! -L "$d" ]] || return 1
    d="$(dirname "$d")"
  done
  return 0
) 2>/dev/null

# Tracked paths of a LANE whose working file differs from the index (plumbing only; over-reports, never hides):
# a symlink/non-regular entry, a missing file, an exec-bit change or a differing unfiltered blob is "modified", and
# so is any path with a symlink ANYWHERE above it (agent-written: reported as unsafe and NEVER opened, so the
# hash-object read cannot be steered outside the lane).
lane_modified() {
  local dir="$1" mode sha path actual
  while IFS= read -r -d '' rec; do
    path="${rec#*$'\t'}"; read -r mode sha _ <<<"${rec%%$'\t'*}"
    if [[ "$mode" == 160000 ]]; then continue; fi
    if [[ "$mode" == 120000 ]]; then
      if ! lane_path_safe "$dir" "$path" ancestors; then echo "unsafe lane path $path (symlink above it) — not read" >&2; printf '%s\n' "$path"; continue; fi
      [[ -L "$dir/$path" ]] || { printf '%s\n' "$path"; continue; }
      actual="$(readlink -- "$dir/$path" | git -C "$dir" hash-object --stdin)" || actual=""
    else
      if ! lane_path_safe "$dir" "$path"; then echo "unsafe lane path $path (symlink at or above it) — not read" >&2; printf '%s\n' "$path"; continue; fi
      if [[ -L "$dir/$path" || ! -f "$dir/$path" ]]; then printf '%s\n' "$path"; continue; fi
      if [[ "$mode" == 100755 && ! -x "$dir/$path" ]] || [[ "$mode" == 100644 && -x "$dir/$path" ]]; then printf '%s\n' "$path"; continue; fi
      actual="$(git -C "$dir" hash-object --no-filters -- "$dir/$path")" || actual=""
    fi
    [[ "$actual" == "$sha" ]] || printf '%s\n' "$path"
  done < <(git -C "$dir" ls-files -s -z)
}

copy_lane_artifacts() {
  local rel parent
  # Plan/spec/scenario artifacts may be intentionally ignored and therefore absent from a worktree
  # created from HEAD. Copy the selected parent state into each lane without copying runtime scratch.
  for rel in IMPLEMENTATION_PLAN.md AGENTS.md .wgm/IMPLEMENTATION_PLAN.md .wgm/AGENTS.md \
    specs scenarios .wgm/specs .wgm/scenarios; do
    [[ -e "$rel" ]] || continue
    [[ -e "$dir/$rel" ]] && continue
    parent="$(dirname "$rel")"
    mkdir -p "$dir/$parent" || return 1
    cp -a "$rel" "$dir/$rel" || return 1
  done
}

# shellcheck disable=SC2016  # expanded by the launcher shell, not here
LANE_LAUNCH='printf "%s\n" "$$" > "$1"; shift; exec "$@"'
PIDS=()
ACTIVE_PIDS=()
BRANCHES=()
DIRS=()
LANE_ABS=()
LANE_NAMES=()
LANE_START=()
LANE_END=()
LANE_END_FILES=()
LANE_LEDGER_BASE=()
LANE_LOOP_PIDS=()
LANE_PID_FILES=()
LANE_NUMS=()
LANE_STATUS=()
READY_BRANCHES=()
READY_DIRS=()
READY_ABS=()
READY_NAMES=()
READY_TASKS=()
READY_NUMS=()
FAIL=0
PARENT_STABLE=1

# Workspace registrations and Git refs are durable recovery handles. Graceful interruption stops our lane
# process groups and leaves any remaining workspaces in place; SIGKILL or an agent deliberately
# escaping its group cannot be handled by the shell. Print names before creation/removal so even an
# interrupted command that already took effect can be reconciled with `jj workspace list`.
# shellcheck disable=SC2317,SC2329  # invoked indirectly by the signal trap below
interrupt_swarm() {  # interrupt_swarm CODE — CODE is the ORIGINATING signal's status (130 INT / 143 TERM), preserved
  local sig_code="${1:-130}"
  trap - INT TERM
  # shellcheck disable=SC2034  # read by sb_bounded (sandbox.sh)
  SB_DEADLINE=$((SECONDS + 16))   # every engine call below shares one global deadline (sb_bounded)
  echo "Interrupted: stopping active lane groups; remaining workspaces and branches are retained for inspection." >&2
  local pid pf lp
  for pf in "${LANE_PID_FILES[@]}"; do   # lane loop pids (the sweep only reaps THIS swarm's own lane containers)
    lp=""; if [[ -r "$pf" ]]; then read -r lp < "$pf" || true; fi
    [[ "$lp" =~ ^[0-9]+$ ]] && LANE_LOOP_PIDS+=("$lp")
  done
  for pid in "${ACTIVE_PIDS[@]}"; do
    [[ -z "$pid" ]] || kill -TERM -- "-$pid" 2>/dev/null || true
  done
  if [[ ${#ACTIVE_PIDS[@]} -gt 0 ]]; then
    # each lane loop's handler needs up to SB_CLEANUP_DEADLINE to remove its containers: wait SB_CHILD_GRACE for ALL of
    # them (leaving as soon as they are gone), only then KILL the stragglers
    local _w _alive
    for _w in $(seq 1 $((SB_CHILD_GRACE * 10))); do
      _alive=0
      for pid in "${ACTIVE_PIDS[@]}"; do [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null || _alive=1; done
      [[ "$_alive" -eq 1 ]] || break
      sleep 0.1
    done
    for pid in "${ACTIVE_PIDS[@]}"; do
      [[ -z "$pid" ]] || kill -KILL -- "-$pid" 2>/dev/null || true
    done
    for pid in "${ACTIVE_PIDS[@]}"; do
      [[ -z "$pid" ]] || wait "$pid" 2>/dev/null || true
    done
  fi
  # shellcheck disable=SC2034  # read by sb_bounded (sandbox.sh)
  SB_DEADLINE=$((SECONDS + 16))   # fresh bounded budget for the reaping below
  swarm_reap_registry
  sweep_containers || true
  echo "Inspect 'git worktree list' and the printed branch/workspace names before manual recovery." >&2
  [[ "$BACKEND" != jj ]] || echo "Also inspect 'jj workspace list'." >&2
  exit "$sig_code"
}
trap 'interrupt_swarm 130' INT
trap 'interrupt_swarm 143' TERM

# Prepare all workspaces before any agent runs. This avoids importing Git refs into jj while a
# sibling lane is concurrently committing, and ensures every lane starts at the same frozen SHA.
i=0
for task in "${TASKS[@]}"; do
  i=$((i + 1))
  br="${PREFIX}/${i}"
  name="${SAFE_PREFIX}-${i}"
  dir="${WT_ABS}/${name}"
  if [[ -e "$dir" || -L "$dir" ]] || git show-ref --verify --quiet "refs/heads/${br}"; then
    echo "✗ stream $i: branch '${br}' or dir '${dir}' already exists — skipping (clean up a prior run)." >&2
    FAIL=1
    continue
  fi
  if ! parent_state_matches; then
    echo "✗ stream $i: parent checkout, index, or non-lane refs changed during setup; retain prepared lanes." >&2
    FAIL=1
    PARENT_STABLE=0
    break
  fi
  if [[ "$BACKEND" == jj ]]; then
    if ! parent_unchanged; then
      echo "✗ stream $i: parent changed during setup; no more workspaces will be created." >&2
      FAIL=1
      PARENT_STABLE=0
      break
    fi
    if ! records="$(jj_workspace_records)"; then
      echo "✗ stream $i: could not inspect jj workspace identities." >&2
      FAIL=1
      break
    fi
    if grep -Fq -- "$(printf '%s\t' "$name")" <<<"$records"; then
      # Match the complete name field, not a prefix of another workspace name.
      if awk -F '\t' -v wanted="$name" '$1 == wanted {found=1} END {exit !found}' <<<"$records"; then
        echo "✗ stream $i: jj workspace '${name}' already exists — leaving it untouched." >&2
        FAIL=1
        continue
      fi
    fi
    echo "Preparing jj workspace ${name} at ${dir} (branch ${br})."
    # Do not let lifecycle commands auto-track untracked files from the parent or a lane.
    if ! jj -R "$PARENT_ROOT" --config 'snapshot.auto-track="none()"' workspace add --name "$name" --colocate --sparse-patterns full -r "$BASE_SHA" "$dir"; then
      echo "✗ stream $i: jj workspace add failed; inspect '${name}' at '${dir}' before recovery." >&2
      FAIL=1
      continue
    fi
    abs_dir="$(cd "$dir" && pwd -P)" || { echo "✗ stream $i: workspace '${name}' path is unavailable: $dir" >&2; FAIL=1; continue; }
    lane_top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
    lane_common="$(git_common_dir "$dir" 2>/dev/null || true)"
    if [[ "$lane_top" != "$abs_dir" || "$lane_common" != "$PARENT_COMMON" ]] \
      || ! jj_workspace_at "$name" "$abs_dir" || ! parent_unchanged; then
      echo "✗ stream $i: jj/Git identity or parent changed; inspect '${name}' at '${dir}'." >&2
      FAIL=1
      continue
    fi
    # Plumbing equivalent of `switch -c`: create the branch at the lane's HEAD, then point HEAD at it.
    if ! lane_tip0="$(git -C "$dir" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
      || ! git -C "$dir" update-ref "refs/heads/${br}" "$lane_tip0" "" \
      || ! git -C "$dir" symbolic-ref HEAD "refs/heads/${br}"; then
      echo "✗ stream $i: could not create branch '${br}'; workspace '${name}' retained at '${dir}'." >&2
      FAIL=1
      continue
    fi
  else
    echo "Preparing Git worktree ${dir} (branch ${br})."
    if ! git worktree add -q -b "$br" "$dir" "$BASE_SHA"; then
      echo "✗ stream $i: 'git worktree add' failed; inspect branch '${br}' and path '${dir}' with git worktree list before recovery." >&2
      FAIL=1
      continue
    fi
    abs_dir="$(cd "$dir" && pwd -P)"
  fi
  if ! copy_lane_artifacts; then
    echo "✗ stream $i: artifact copy failed; workspace retained at '${dir}'." >&2
    FAIL=1
    continue
  fi
  READY_BRANCHES+=("$br")
  READY_DIRS+=("$dir")
  READY_ABS+=("$abs_dir")
  READY_NAMES+=("$name")
  READY_TASKS+=("$task")
  READY_NUMS+=("$i")
done

[[ ${#READY_DIRS[@]} -ge 1 ]] || { echo "No streams started." >&2; exit 1; }
[[ "$PARENT_STABLE" -eq 1 ]] || { echo "Prepared lanes retained; inspect them before recovery." >&2; exit 1; }
# Pin the shared store ONCE, now: every lane workspace exists (the admin-dir set is part of the pinned digest) and no
# lane container has run yet. Captured only when containers will run; git-free (lane u's sb_pin_capture_to).
if [[ "$SWARM_SB_MODE" == on ]]; then
  # (the lane loops create the empty read-only overlay targets — config, config.worktree of every admin dir, … —
  # at their own start; create them HERE first so that normal startup does not change the pinned digest)
  ( sb_repo_layout "$PARENT_ROOT"; sb_ensure_overlays ) || { echo "Cannot prepare the shared git store overlays; refusing to start lanes." >&2; exit 2; }
  ( sb_pin_capture_to "$SWARM_PIN_FILE" "$PARENT_ROOT" ) || { echo "Cannot pin the shared git store; refusing to start lanes." >&2; exit 2; }
  SWARM_PINNED=1
  # (lane u's U48) the capture ran in a subshell: export WGM_PIN_FILE so EVERY swarm host git call from here until the
  # post-run verification (dispatch guards, parent checks, result table) verifies the pins first — exit 2 + `trust lost`
  # in WGM_TRUST_LOST_FILE before git runs. Lane loops keep their own in-memory pins and run without it.
  export WGM_PIN_FILE="$SWARM_PIN_FILE"
fi
# Monitor mode gives each background lane its own process group for graceful interruption.
set -m
for idx in "${!READY_DIRS[@]}"; do
  # containment lost by an already-started lane: dispatch nothing further and run no further host git
  if containment_lost_any || trust_lost_any; then FAIL=1; break; fi
  if ! parent_state_matches; then
    echo "✗ parent checkout, index, or non-lane refs changed before dispatch; prepared lanes are retained." >&2
    FAIL=1
    PARENT_STABLE=0
    break
  fi
  br="${READY_BRANCHES[$idx]}"; dir="${READY_DIRS[$idx]}"; abs_dir="${READY_ABS[$idx]}"
  name="${READY_NAMES[$idx]}"; task="${READY_TASKS[$idx]}"; i="${READY_NUMS[$idx]}"
  reqflag=()
  lane_gate_args=()
  [[ -n "$PARENT_GATES_FILE" ]] && lane_gate_args=(--gates "$PARENT_GATES_FILE")
  # Re-pin the path and branch on every turn; the host checks them again around each invocation.
  pin="Work ONLY inside the git worktree at ${abs_dir} on branch ${br}. Run git as 'git -C ${abs_dir} ...' rather than relying on the current directory. Before ANY state-mutating command, verify 'git -C ${abs_dir} rev-parse --show-toplevel' is ${abs_dir} and 'git -C ${abs_dir} branch --show-current' is ${br}; if either differs, stop and report instead of mutating. Do not commit, amend, reset, rebase, or switch branches: the loop owns commits and checks the lane tip."
  if [[ "$BACKEND" == jj ]]; then
    pin="$pin This is a colocated jj workspace, but this loop uses Git commits. Do not run jj operations that move the working copy or Git HEAD while the lane runs."
  fi
  if [[ -n "$task" ]]; then reqflag=(--request "${task}"$'\n\n'"${pin}"); else reqflag=(--request "$pin"); fi
  # Ledger paths are reused per prefix/lane number and loop.sh APPENDS: remember how many lines this lane's ledger already
  # holds so telemetry reads ONLY the rows written during THIS run (a lane that refused before any row counts nothing).
  lane_ledger="${METRICS_DIR}/${SAFE_PREFIX}-${i}.tsv"
  lane_ledger_base=0
  if [[ -f "$lane_ledger" ]]; then lane_ledger_base="$(wc -l < "$lane_ledger")"; lane_ledger_base="${lane_ledger_base//[[:space:]]/}"; fi
  lane_end_file="${METRICS_DIR}/.${SAFE_PREFIX}-${i}-end-$$"
  rm -f "$lane_end_file"
  # The lane loop's pid (it names its containers wgm-<key8>-<pid>-<seq>); exec keeps the pid through the launcher.
  lane_pid_file="${METRICS_DIR}/.${SAFE_PREFIX}-${i}-pid-$$"
  rm -f "$lane_pid_file"
  lane_start="$(date +%s)"
  (
    # Record actual child completion, not the later moment the parent happens to wait for it.
    trap 'date +%s > "$lane_end_file"' EXIT
    cd "$dir" || exit 1
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    cur="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
    if [[ "$top" != "$abs_dir" || "$cur" != "$br" ]]; then
      echo "✗ lane guard: expected worktree ${abs_dir} on ${br}, got ${top:-<none>} on ${cur:-<none>}" >&2
      exit 1
    fi
    # Lanes reuse the decision (WGM_SANDBOX_DECISION) silently and never own it: swarm deletes it.
    unset WGM_SANDBOX_DECISION_OWNED WGM_TRUSTED_RUNNER_OWNED WGM_SWARM_DECISION_OWNED WGM_PIN_FILE
    WGM_CONTAINMENT_LOST_FILE="$SWARM_CTL_DIR/lane-${i}.lost" WGM_TRUST_LOST_FILE="$SWARM_CTL_DIR/lane-${i}.trust" \
      WGM_SWARM_LANE=1 WGM_SWARM_ROOT="$abs_dir" WGM_SWARM_BRANCH="$br" \
      WGM_SWARM_PARENT_ROOT="$PARENT_GIT_ROOT" WGM_SWARM_PARENT_HASH="$PARENT_FINGERPRINT" \
      WGM_SWARM_PREFIX="$PREFIX" WGM_SWARM_WORKTREE_DIR="$WT_ABS" WGM_SWARM_RUNTIME_DIR="$PARENT_ROOT/.wgm" \
      WGM_SWARM_SAFE_PREFIX="$SAFE_PREFIX" WGM_SWARM_COUNT="${#TASKS[@]}" \
      WGM_PARENT_TASK="${task:-stream-${i}}" \
      "$BASH" -c "$LANE_LAUNCH" _ "$lane_pid_file" \
      "$LOOP" build "$MAXIT" "${reqflag[@]}" "${lane_gate_args[@]}" "${SB_FLAGS[@]}" --commit \
      --metrics "${METRICS_DIR}/${SAFE_PREFIX}-${i}.tsv" -- "${AGENT_ARGV[@]}"
  ) >"${LOG_DIR}/${SAFE_PREFIX}-${i}.log" 2>&1 &
  PIDS+=("$!")
  ACTIVE_PIDS+=("$!")
  BRANCHES+=("$br")
  DIRS+=("$dir")
  LANE_ABS+=("$abs_dir")
  LANE_NAMES+=("$name")
  LANE_START+=("$lane_start")
  LANE_END_FILES+=("$lane_end_file")
  LANE_LEDGER_BASE+=("$lane_ledger_base")
  LANE_PID_FILES+=("$lane_pid_file")
  LANE_NUMS+=("$i")
  echo "↗ stream $i → branch ${br}${task:+ — ${task}}"
done

if [[ ${#PIDS[@]} -eq 0 && "$SWARM_PINNED" -eq 1 ]]; then
  # nothing was dispatched: was it because trust in the shared store was lost (a changed config/include/hook between two
  # swarm host git calls)? That is terminal — exit 2 naming the path, every prepared lane retained.
  dtrust_rc=0
  dtrust_out="$( (sb_pin_verify_from "$SWARM_PIN_FILE") 2>&1 )" || dtrust_rc=$?
  if [[ "$dtrust_rc" -ne 0 ]] || trust_lost_any; then swarm_trust_stop "$dtrust_out"; fi
fi
[[ ${#PIDS[@]} -ge 1 ]] || { echo "No streams started; prepared lanes retained." >&2; exit 1; }
echo ""
echo "Waiting for ${#PIDS[@]} stream(s)…"
# Do not query or remove jj workspaces until every agent has exited.
for idx in "${!PIDS[@]}"; do
  if wait "${PIDS[$idx]}"; then LANE_STATUS[idx]="ok"; else LANE_STATUS[idx]="FAIL"; FAIL=1; fi
  ACTIVE_PIDS[idx]=""
  ended=""
  if [[ -r "${LANE_END_FILES[$idx]}" ]]; then read -r ended < "${LANE_END_FILES[$idx]}" || true; fi
  if [[ "$ended" =~ ^[0-9]+$ ]]; then LANE_END[idx]="$ended"; else LANE_END[idx]=""; fi
  rm -f "${LANE_END_FILES[$idx]}"
  lp=""
  if [[ -r "${LANE_PID_FILES[$idx]}" ]]; then read -r lp < "${LANE_PID_FILES[$idx]}" || true; fi
  [[ "$lp" =~ ^[0-9]+$ ]] && LANE_LOOP_PIDS[idx]="$lp"
  rm -f "${LANE_PID_FILES[$idx]}"
done
sweep_rc=0
sweep_containers || sweep_rc=$?
[[ "$sweep_rc" -eq 0 ]] || FAIL=1
# TERMINAL: any containment file non-empty, or a sweep that cannot confirm absence, stops everything here.
if [[ "$sweep_rc" -ne 0 ]] || containment_lost_any; then swarm_containment_stop; fi
# TRUST: before ANY post-run host git (inspection, consolidation, cleanup) — even for lanes that already failed — a
# lane loop's trust-lost file or a failing pin verification of the shared store stops the whole swarm.
if [[ "$SWARM_PINNED" -eq 1 ]]; then
  trust_out=""
  if trust_lost_any; then swarm_trust_stop; fi
  trust_rc=0
  trust_out="$( (sb_pin_verify_from "$SWARM_PIN_FILE") 2>&1 )" || trust_rc=$?
  if [[ "$trust_rc" -ne 0 ]]; then swarm_trust_stop "$trust_out"; fi
  # (WGM_PIN_FILE stays ON through inspection, consolidation and cleanup — lane u's U49: after each AUTHORIZED removal of
  # a lane swarm re-captures the pins explicitly with swarm_repin_lanes; verification is never switched off.)
fi
printf '%-7s %-24s %-6s %s\n' "stream" "branch" "status" "commits"
LANE_UNSAFE=()
for idx in "${!PIDS[@]}"; do
  # a refused host git call (pins changed since the post-run verification) is terminal: stop BEFORE the next call
  if [[ "$SWARM_PINNED" -eq 1 ]] && trust_lost_any; then swarm_trust_stop; fi
  st="${LANE_STATUS[$idx]}"
  # NO-FOLLOW git-dir boundary (lane u, sb_gitdir_guard) BEFORE any host git inspection of this lane: a contained
  # hook/helper may have swapped an admin file (index, HEAD, a ref) for a symlink to a host file. A refusal retains
  # the lane, names the path with its recovery (`rm` the link, never its target; `git reset` afterwards) and is
  # never read through.
  if ! gd_out="$( (sb_gitdir_guard "${DIRS[$idx]}" full --expect-common "$PARENT_COMMON_PIN") 2>&1 )"; then
    LANE_UNSAFE[idx]=1; LANE_STATUS[idx]="FAIL"; FAIL=1
    echo "✗ stream ${LANE_NUMS[$idx]}: ${gd_out}" >&2
    echo "  recovery: restore the lane's git pointers — its admin dir's commondir must contain '../..' (and its .git file the gitdir: line it was created with); nothing was scanned or opened at the redirected location." >&2
    echo "  lane retained at ${DIRS[$idx]} (not inspected, not read through)." >&2
    printf '%-7s %-24s %-6s %s\n' "${LANE_NUMS[$idx]}" "${BRANCHES[$idx]}" "FAIL" "?"
    continue
  fi
  commits="$(git rev-list --count "${BASE_SHA}..${BRANCHES[$idx]}" 2>/dev/null || echo '?')"
  if [[ "$st" == "ok" ]] && { [[ "$commits" == "0" || "$commits" == "?" ]] \
      || ! git merge-base --is-ancestor "$BASE_SHA" "${BRANCHES[$idx]}"; }; then
    st="FAIL"
    FAIL=1
    echo "✗ stream ${LANE_NUMS[$idx]}: agent exited successfully but produced no verifiable commit artifact." >&2
  fi
  top="$(git -C "${DIRS[$idx]}" rev-parse --show-toplevel 2>/dev/null || true)"
  branch="$(git -C "${DIRS[$idx]}" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  if [[ "$top" != "${LANE_ABS[$idx]}" || "$branch" != "${BRANCHES[$idx]}" ]]; then
    st="FAIL"
    FAIL=1
    echo "✗ stream ${LANE_NUMS[$idx]}: Git lane identity changed; retain and inspect ${DIRS[$idx]}." >&2
  fi
  if [[ "$BACKEND" == jj ]] && ! jj_workspace_at "${LANE_NAMES[$idx]}" "${LANE_ABS[$idx]}"; then
    st="FAIL"
    FAIL=1
    echo "✗ stream ${LANE_NUMS[$idx]}: jj workspace identity changed; retain and inspect ${DIRS[$idx]}." >&2
  fi
  LANE_STATUS[idx]="$st"
  printf '%-7s %-24s %-6s %s\n' "${LANE_NUMS[$idx]}" "${BRANCHES[$idx]}" "$st" "$commits"
done
if [[ "$SWARM_PINNED" -eq 1 ]] && trust_lost_any; then swarm_trust_stop; fi
if ! parent_head_unchanged || ! parent_state_matches; then
  echo "✗ parent Git HEAD or branch changed, or its checkout, index, or non-lane refs drifted; retain lanes for inspection." >&2
  PARENT_STABLE=0
  FAIL=1
fi
if [[ "$SWARM_PINNED" -eq 1 ]] && trust_lost_any; then swarm_trust_stop; fi

# ----- telemetry summary ----------------------------------------------------
# Two explicit clocks, kept separate on purpose ([learn] issues #70/#72/#74/#84/#85):
#   WALL   — parent elapsed, frozen at the ready-to-test gate below, before reporting overhead.
#   LANE   — summed lane lifetimes. This is CAPACITY ALLOCATED, an upper bound: a lane parked
#            between turns still burns lifetime. It is NOT agent-hours and must never be labelled so.
#   ACTIVE — summed per-turn durations from the lanes' own ledgers. This is the measured lower
#            bound on real agent work; the gap to LANE is parked time.
# Missing telemetry is counted and reported, never estimated away, and every ratio is labelled an
# operational heuristic rather than billing data or a causal speedup claim.
SWARM_END=$(date +%s)
WALL=$(( SWARM_END - SWARM_START ))
LANE_SECS=0
LANES_TIMED=0
CRITICAL=0
for idx in "${!PIDS[@]}"; do
  s="${LANE_START[$idx]:-}"; e="${LANE_END[$idx]:-}"
  if [[ -n "$s" && -n "$e" ]]; then
    d=$(( e - s ))
    LANE_SECS=$(( LANE_SECS + d ))
    LANES_TIMED=$(( LANES_TIMED + 1 ))
    [[ "$d" -gt "$CRITICAL" ]] && CRITICAL="$d"
  fi
done
LANES_UNMETERED=$(( ${#PIDS[@]} - LANES_TIMED ))

# Active agent time comes from the per-turn duration_s column each lane's ledger recorded. Turns
# that produced no duration are counted, not guessed at, so the total stays an honest lower bound.
ACTIVE_SECS=0
TURNS_TIMED=0
TURNS_MISSING=0
for idx in "${!PIDS[@]}"; do
  ledger="${METRICS_DIR}/${SAFE_PREFIX}-${LANE_NUMS[$idx]}.tsv"
  [[ -f "$ledger" ]] || { TURNS_MISSING=$(( TURNS_MISSING + 1 )); continue; }
  # ONLY the rows appended during this run (lines after the pre-dispatch count; the header line never counts)
  read -r _sum _timed _missing < <(awk -F'\t' -v base="${LANE_LEDGER_BASE[$idx]:-0}" 'NR == 1 || NF == 0 { next } NR > base { if ($6 ~ /^[0-9]+$/) { s += $6; t++ } else m++ } END { print s + 0, t + 0, m + 0 }' "$ledger")
  ACTIVE_SECS=$(( ACTIVE_SECS + _sum )); TURNS_TIMED=$(( TURNS_TIMED + _timed )); TURNS_MISSING=$(( TURNS_MISSING + _missing ))
  # a lane that wrote no row this run (e.g. it refused during setup) has no duration telemetry either
  [[ $(( _timed + _missing )) -gt 0 ]] || TURNS_MISSING=$(( TURNS_MISSING + 1 ))
done
PARKED_SECS=$(( LANE_SECS - ACTIVE_SECS ))
(( PARKED_SECS < 0 )) && PARKED_SECS=0

# Peak concurrency = the largest number of lanes alive at the same instant, computed by sweeping
# every lane start/end boundary rather than assuming all lanes overlapped.
PEAK=0
for idx in "${!PIDS[@]}"; do
  t="${LANE_START[$idx]:-}"; [[ -n "$t" ]] || continue
  live=0
  for j in "${!PIDS[@]}"; do
    js="${LANE_START[$j]:-}"; je="${LANE_END[$j]:-}"
    [[ -n "$js" && -n "$je" ]] || continue
    if [[ "$js" -le "$t" && "$je" -ge "$t" ]]; then live=$(( live + 1 )); fi
  done
  [[ "$live" -gt "$PEAK" ]] && PEAK="$live"
done

hms() { printf '%dh%02dm%02ds' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )) $(( $1 % 60 )); }
ratio() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b > 0) printf "%.2fx", a/b; else printf "n/a" }'; }

echo ""
echo "== swarm telemetry (frozen at the ready-to-test gate) =="
printf 'wall time (parent):        %s\n' "$(hms "$WALL")"
printf 'lane time (allocated):     %s   [capacity upper bound — includes parked time]\n' "$(hms "$LANE_SECS")"
printf 'agent time (active):       %s   [measured LOWER BOUND — summed per-turn durations]\n' "$(hms "$ACTIVE_SECS")"
printf 'parked time:               %s\n' "$(hms "$PARKED_SECS")"
printf 'lanes completed/started:   %s/%s\n' "$LANES_TIMED" "${#PIDS[@]}"
printf 'lanes unmetered:           %s\n' "$LANES_UNMETERED"
printf 'turns timed/missing:       %s/%s\n' "$TURNS_TIMED" "$TURNS_MISSING"
printf 'peak concurrency:          %s\n' "$PEAK"
printf 'critical path (longest):   %s\n' "$(hms "$CRITICAL")"
printf 'lifecycle effectiveness:   %s  [active / wall]\n' "$(ratio "$ACTIVE_SECS" "$WALL")"
printf 'implementation parallelism:%s  [allocated / longest lane]\n' "$(ratio "$LANE_SECS" "$CRITICAL")"
printf 'per-turn ledgers:          %s\n' "$METRICS_DIR"
LANES_BOXED=0
for idx in "${!PIDS[@]}"; do
  ledger="${METRICS_DIR}/${SAFE_PREFIX}-${LANE_NUMS[$idx]}.tsv"
  [[ -f "$ledger" ]] || continue
  # the LAST non-empty sandbox value among the rows written during THIS run only (never a previous run's row)
  lane_sb="$(awk -F'\t' -v base="${LANE_LEDGER_BASE[$idx]:-0}" 'NR==1{for(i=1;i<=NF;i++) if($i=="sandbox") c=i; next} NR > base && c && NF>=c && $c!="" {v=$c} END{print v}' "$ledger")"
  [[ "$lane_sb" == container:* ]] && LANES_BOXED=$(( LANES_BOXED + 1 ))
done
case "$SWARM_SB_MODE" in
  on) printf 'sandbox: on (%s) — %s/%s lanes ran the agent in a container\n' "$SB_ENGINE" "$LANES_BOXED" "${#PIDS[@]}" ;;
  inside) printf 'sandbox: inside (already in a wgm devcontainer) — %s/%s lanes ran the agent in a container\n' "$LANES_BOXED" "${#PIDS[@]}" ;;
  *) printf 'sandbox: OFF (%s)\n' "${SWARM_SB_REASON:-unknown}" ;;
esac
echo "Ratios are operational heuristics from one run — not billing data and not a causal speedup claim."
if (( LANES_UNMETERED > 0 || TURNS_MISSING > 0 )); then
  echo "NOTE: ${LANES_UNMETERED} lane(s) and ${TURNS_MISSING} turn(s) have no duration telemetry — active agent time is a LOWER BOUND."
fi

MAIN_MEMORIES=".wgm/memories.md"
CONSOLIDATED_ANY=0
for idx in "${!DIRS[@]}"; do
  memories="${DIRS[$idx]}/.wgm/memories.md"
  [[ -e "$memories" || -L "$memories" ]] || continue
  if [[ "${LANE_STATUS[$idx]}" != ok || "$PARENT_STABLE" -ne 1 ]]; then
    echo "✗ stream ${LANE_NUMS[$idx]}: unverified memories retained at $memories, not harvested." >&2
    continue
  fi
  # Read the agent-written memories as DATA: a committed copy comes from the store (`git show <rev>:<path>`,
  # no textconv); an uncommitted one is read only when it and every ancestor inside the lane are real
  # (non-symlink) entries — an agent-written symlink is never followed.
  mem_text="$(mktemp "${TMPDIR:-/tmp}/wgm-swarm-mem.XXXXXX")"
  if git -C "${DIRS[$idx]}" cat-file -e "${BRANCHES[$idx]}:.wgm/memories.md" 2>/dev/null; then
    git -C "${DIRS[$idx]}" show "${BRANCHES[$idx]}:.wgm/memories.md" > "$mem_text" 2>/dev/null || : > "$mem_text"
  elif [[ -f "$memories" ]] && lane_path_safe "${DIRS[$idx]}" ".wgm/memories.md"; then
    cat -- "$memories" > "$mem_text"
  else
    rm -f "$mem_text"
    echo "✗ stream ${LANE_NUMS[$idx]}: memories at $memories is not a regular, unlinked file; not harvested." >&2
    continue
  fi
  mkdir -p .wgm
  lines="$(wc -l < "$mem_text")"
  {
    printf '\n<!-- from %s -->\n\n' "${BRANCHES[$idx]}"
    cat "$mem_text"
    printf '\n'
  } >> "$MAIN_MEMORIES"
  rm -f "$mem_text"
  echo "✓ stream ${LANE_NUMS[$idx]}: consolidated .wgm/memories.md (${lines} lines) from ${BRANCHES[$idx]}"
  CONSOLIDATED_ANY=1
done

# Standing hive dispatch: hand any eligible consolidated memories to harvest-hive.sh.
# harvest-hive.sh itself owns every safety decision from here (no consent file yet -> declines for
# this run only, without persisting anything on a human's behalf; consent false -> local preview
# only; consent true -> real anonymized upstream report) -- swarm.sh does not duplicate that logic,
# and a harvest hiccup never fails the swarm itself.
if [[ "$CONSOLIDATED_ANY" -eq 1 && -x "$HERE/harvest-hive.sh" ]]; then
  "$HERE/harvest-hive.sh" </dev/null || echo "(harvest-hive.sh had a non-zero exit; swarm result is unaffected)" >&2
fi

if [[ "$CLEANUP" -eq 1 ]]; then
  for idx in "${!DIRS[@]}"; do
    d="${DIRS[$idx]}"
    if [[ "${LANE_STATUS[$idx]}" != ok ]] || [[ "$PARENT_STABLE" -ne 1 ]] || ! parent_state_matches; then
      echo "✗ stream ${LANE_NUMS[$idx]}: failed or parent-changed lane retained at $d for recovery${LANE_UNSAFE[$idx]:+ (planted link in its git dir — see the recovery line above)}." >&2
      FAIL=1
      continue
    fi
    top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)"
    branch="$(git -C "$d" symbolic-ref -q --short HEAD 2>/dev/null || true)"
    if ! abs_dir="$(cd "$d" 2>/dev/null && pwd)"; then
      abs_dir=""
    fi
    # LANE = plumbing only (C2): no status, no ls-files -m, no diff. Untracked files come from
    # `ls-files -o --exclude-standard`; tracked content is compared blob-to-file without filters (lane_modified).
    mod_list="$(lane_modified "$d")" || mod_list="<inspection failed>"   # stderr stays visible: names unsafe paths
    dirty="$({ git -C "$d" ls-files -o --exclude-standard -- . ':(exclude).wgm' ':(exclude).wgm/**'; grep -v '^\.wgm/' <<<"$mod_list" || true; } 2>/dev/null)" || dirty="<status failed>"
    # Tracked .wgm paths are project data even when the directory is otherwise ignored scratch.
    tracked_dirty="$({ [[ -z "$mod_list" ]] || printf '%s\n' "$mod_list"; git -C "$d" diff-index --cached --name-only HEAD --; } 2>/dev/null)" || tracked_dirty="<tracked-status failed>"
    # Ignored build/user data is invisible to ordinary status. Only wgm scratch and jj metadata
    # are eligible for removal; other ignored artifacts require explicit operator inspection.
    if ignored="$(git -C "$d" ls-files --others --ignored --exclude-standard --directory -- . ':(exclude).wgm' ':(exclude).wgm/**' ':(exclude).jj' ':(exclude).jj/**' 2>/dev/null)"; then
      # Git may report the ignored directory itself despite an exclusion for its contents.
      ignored="$(printf '%s\n' "$ignored" | awk '$0 != ".wgm/" && $0 != ".jj/"')"
    else
      ignored="<ignored-file inspection failed>"
    fi
    if [[ -z "$abs_dir" || "$top" != "$abs_dir" || "$branch" != "${BRANCHES[$idx]}" || -n "$dirty" || -n "$tracked_dirty" || -n "$ignored" ]]; then
      first_path="$(printf '%s\n%s\n%s\n' "$dirty" "$mod_list" "$ignored" | awk 'NF {print; exit}')"
      echo "✗ stream ${LANE_NUMS[$idx]}: dirty or unverified lane retained at $d for recovery${first_path:+ (first path: $first_path)}." >&2
      FAIL=1
      continue
    fi
    lane_tip="$(git -C "$d" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || {
      echo "✗ stream ${LANE_NUMS[$idx]}: cannot verify branch tip; workspace retained at $d." >&2
      FAIL=1
      continue
    }
    if [[ "$BACKEND" == jj ]]; then
      name="${LANE_NAMES[$idx]}"
      if ! parent_unchanged || ! jj_workspace_at "$name" "$abs_dir" \
        || [[ "$(git_common_dir "$d" 2>/dev/null || true)" != "$PARENT_COMMON" ]]; then
        echo "✗ stream ${LANE_NUMS[$idx]}: changed parent or unverified jj workspace retained at $d." >&2
        FAIL=1
        continue
      fi
      echo "Removing jj workspace ${name} at ${d}; branch ${BRANCHES[$idx]} is kept."
      if ! jj -R "$PARENT_ROOT" --config 'snapshot.auto-track="none()"' workspace remove "$name"; then
        echo "✗ cleanup failed for jj workspace ${name}; inspect its registration, path and branch before retrying." >&2
        FAIL=1
        continue
      fi
      swarm_repin_lanes || { FAIL=1; break; }
      if ! records="$(jj_workspace_records)" || ! worktrees="$(git worktree list --porcelain)"; then
        echo "✗ cleanup verification failed for jj workspace ${name}; inspect it and its branch." >&2
        FAIL=1
        continue
      fi
      branch_tip="$(git rev-parse --verify "refs/heads/${BRANCHES[$idx]}^{commit}" 2>/dev/null || true)"
      if [[ -e "$d" || "$branch_tip" != "$lane_tip" ]] \
        || awk -F '\t' -v wanted="$name" '$1 == wanted {found=1} END {exit !found}' <<<"$records" \
        || grep -Fxq -- "worktree $d" <<<"$worktrees" || ! parent_unchanged || ! parent_state_matches; then
        echo "✗ cleanup verification failed for jj workspace ${name}; inspect its path, branch and parent." >&2
        FAIL=1
      fi
    elif ! git worktree remove --force "$d" 2>/dev/null; then
      echo "✗ cleanup failed: could not remove worktree $d; inspect it before retrying." >&2
      FAIL=1
    else
      swarm_repin_lanes || { FAIL=1; break; }
      worktrees="$(git worktree list --porcelain)" || worktrees="<worktree inspection failed>"
      branch_tip="$(git rev-parse --verify "refs/heads/${BRANCHES[$idx]}^{commit}" 2>/dev/null || true)"
      if [[ -e "$d" || -L "$d" || "$branch_tip" != "$lane_tip" || "$worktrees" == '<worktree inspection failed>' ]] \
        || grep -Fxq -- "worktree $d" <<<"$worktrees" || ! parent_state_matches; then
        echo "✗ cleanup verification failed for worktree $d; inspect its path, branch and parent." >&2
        FAIL=1
      fi
    fi
  done
  echo "(verified successful worktrees removed; failed/dirty lanes and branches kept — merge with: git merge ${PREFIX}/<i>)"
else
  echo "Worktrees kept under ${WT_DIR}/. Merge a stream with: git merge ${PREFIX}/<i>"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "swarm: all ${#PIDS[@]} stream(s) ok"
else
  echo "swarm: one or more streams failed (see ${LOG_DIR}/*.log)" >&2
fi
exit "$FAIL"
