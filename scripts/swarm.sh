#!/usr/bin/env bash
#
# wgm/swarm.sh — fan out N Ralph loops in Git worktrees or colocated jj workspaces + branches.
#
# "Swarm coding": instead of one sequential loop, the sheepdog (this script) spawns several dogs that
# work in PARALLEL on independent slices, each in a Git worktree or opt-in colocated jj workspace
# on its own branch. Each stream runs `scripts/loop.sh build`; review and merge the branches yourself.
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
#   --backend git|jj    workspace lifecycle backend (default: git; jj needs 0.46.0+ and Git --orphan)
#   --worktree-dir DIR  base dir for the worktrees/workspaces (default: .wgm/worktrees)
#   --gates FILE        project-wide gate file forwarded to every lane
#   --cleanup           remove verified successful worktrees; failed/dirty lanes and branches are kept
#   --dry-run           print the plan; create no worktrees and run nothing
#   -h | --help         show this help
#
# Everything after `--` is the agent argv, forwarded verbatim to each stream's loop.sh (or set
# $WGM_AGENT). The streams run with --commit so each branch carries its work.
#
# jj setup: Git must support `worktree add --orphan` (normally 2.42+; backports work). Git's
# `worktree add -h` normally exits 129. The default Git backend does not need this jj-only check.
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/swarm-parent-guard.sh
source "$HERE/swarm-parent-guard.sh"
LOOP="$HERE/loop.sh"

TASKS_FILE=""
COUNT=0
MAXIT=0
PREFIX="wgm/swarm"
BACKEND="git"
WT_DIR=".wgm/worktrees"
GATES_FILE=""
CLEANUP=0
DRY_RUN=0
AGENT_ARGV=()

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --tasks) [[ $# -ge 2 ]] || { echo "--tasks requires a file" >&2; exit 2; }; TASKS_FILE="$2"; shift 2 ;;
    -n|--count) [[ $# -ge 2 ]] || { echo "--count requires a number" >&2; exit 2; }; COUNT="$2"; shift 2 ;;
    --max-iterations) [[ $# -ge 2 ]] || { echo "--max-iterations requires a number" >&2; exit 2; }; MAXIT="$2"; shift 2 ;;
    --prefix) [[ $# -ge 2 ]] || { echo "--prefix requires a name" >&2; exit 2; }; PREFIX="$2"; shift 2 ;;
    --backend) [[ $# -ge 2 ]] || { echo "--backend requires git or jj" >&2; exit 2; }; BACKEND="$2"; shift 2 ;;
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
case "$BACKEND" in git|jj) ;; *) echo "Invalid --backend: $BACKEND (expected git or jj)." >&2; exit 2 ;; esac

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

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Not inside a git repository." >&2; exit 2; }

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

if [[ "$BACKEND" == jj ]]; then
  command -v jj >/dev/null 2>&1 || { echo "The jj backend requires jj 0.46.0 or newer on PATH." >&2; exit 2; }
  jj_version="$(jj --version 2>/dev/null)" || { echo "Could not determine jj version." >&2; exit 2; }
  if [[ ! "$jj_version" =~ ^jj[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    echo "Unrecognized jj version: $jj_version (requires 0.46.0 or newer)." >&2; exit 2
  fi
  jj_major="${BASH_REMATCH[1]}"; jj_minor="${BASH_REMATCH[2]}"
  if (( 10#$jj_major == 0 && 10#$jj_minor < 46 )); then
    echo "Unsupported jj version: $jj_version (requires 0.46.0 or newer)." >&2; exit 2
  fi
  # jj creates colocated workspaces using Git's orphan-worktree option. Probe the actual
  # capability rather than rejecting a vendor backport solely on its version string. Git help
  # normally exits 129; other errors must not become success just because they mention the flag.
  git_help_rc=0
  git_worktree_help="$(LC_ALL=C git worktree add -h 2>&1)" || git_help_rc=$?
  if [[ "$git_help_rc" -ne 0 && "$git_help_rc" -ne 129 ]] \
    || ! grep -Eq '(^usage:.*--orphan|^[[:space:]]*(\[--orphan\]|--orphan|--\[no-\]orphan)([[:space:]=]|$))' <<<"$git_worktree_help" \
    || grep -Eiq '^[[:space:]]*(fatal|error):' <<<"$git_worktree_help"; then
    echo "The jj backend requires git worktree add --orphan (normally Git 2.42 or newer); install a compatible Git or use --backend git." >&2
    exit 2
  fi
  git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "Cannot locate Git root." >&2; exit 2; }
  git_root="$(cd "$git_root" && pwd -P)"
  [[ "$git_root" == "$PARENT_ROOT" ]] || { echo "The jj backend must run from the project root." >&2; exit 2; }
  parent_unchanged || { echo "The jj backend requires a clean parent checkout at its original Git HEAD." >&2; exit 2; }
  jj_root="$(jj --ignore-working-copy workspace root 2>/dev/null)" \
    || { echo "The jj backend requires an existing colocated jj workspace; it will not initialize one." >&2; exit 2; }
  jj_root="$(cd "$jj_root" && pwd -P)"
  [[ "$jj_root" == "$PARENT_ROOT" ]] || { echo "The jj workspace and Git project roots differ." >&2; exit 2; }
  jj_common="$(jj --ignore-working-copy git root 2>/dev/null)" \
    || { echo "The jj backend requires a Git-backed colocated workspace." >&2; exit 2; }
  jj_common="$(cd "$jj_common" && pwd -P)"
  PARENT_COMMON="$(git_common_dir "$PARENT_ROOT")" || { echo "Cannot locate Git common directory." >&2; exit 2; }
  [[ "$jj_common" == "$PARENT_COMMON" ]] \
    || { echo "The jj workspace is backed by a different Git store; use a colocated workspace." >&2; exit 2; }
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

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "== wgm swarm (dry run) =="
  echo "streams=${#TASKS[@]} backend=${BACKEND} prefix=${PREFIX} worktree_dir=${WT_DIR} max_iterations=${MAXIT} cleanup=${CLEANUP} gates=${GATES_FILE:-auto}"
  if [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then echo "agent(argv)=${AGENT_ARGV[*]}"; else echo "agent=\$WGM_AGENT"; fi
  i=0
  for task in "${TASKS[@]}"; do
    i=$((i + 1))
    echo "  stream $i → branch ${PREFIX}/${i} (worktree ${WT_DIR}/${SAFE_PREFIX}-${i})${task:+ — ${task}}"
  done
  exit 0
fi

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
if ! PARENT_FINGERPRINT="$(wgm_swarm_parent_fingerprint "$PARENT_GIT_ROOT" "$PREFIX" "$WT_ABS" "$SAFE_PREFIX" "${#TASKS[@]}" "$PARENT_ROOT/.wgm")"; then
  echo "Could not inspect the parent checkout, index, or non-lane refs; refusing to swarm." >&2
  exit 1
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

PIDS=()
ACTIVE_PIDS=()
BRANCHES=()
DIRS=()
LANE_ABS=()
LANE_NAMES=()
LANE_START=()
LANE_END=()
LANE_END_FILES=()
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
interrupt_swarm() {
  trap - INT TERM
  echo "Interrupted: stopping active lane groups; remaining workspaces and branches are retained for inspection." >&2
  local pid
  for pid in "${ACTIVE_PIDS[@]}"; do
    [[ -z "$pid" ]] || kill -TERM -- "-$pid" 2>/dev/null || true
  done
  if [[ ${#ACTIVE_PIDS[@]} -gt 0 ]]; then
    sleep 0.2
    for pid in "${ACTIVE_PIDS[@]}"; do
      [[ -z "$pid" ]] || kill -KILL -- "-$pid" 2>/dev/null || true
    done
    for pid in "${ACTIVE_PIDS[@]}"; do
      [[ -z "$pid" ]] || wait "$pid" 2>/dev/null || true
    done
  fi
  echo "Inspect 'git worktree list' and the printed branch/workspace names before manual recovery." >&2
  [[ "$BACKEND" != jj ]] || echo "Also inspect 'jj workspace list'." >&2
  exit 130
}
trap interrupt_swarm INT TERM

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
    if ! git -C "$dir" switch -q -c "$br"; then
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
# Monitor mode gives each background lane its own process group for graceful interruption.
set -m
for idx in "${!READY_DIRS[@]}"; do
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
  lane_end_file="${METRICS_DIR}/.${SAFE_PREFIX}-${i}-end-$$"
  rm -f "$lane_end_file"
  lane_start="$(date +%s)"
  (
    # Record actual child completion, not the later moment the parent happens to wait for it.
    trap 'date +%s > "$lane_end_file"' EXIT
    cd "$dir" || exit 1
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    cur="$(git branch --show-current 2>/dev/null || true)"
    if [[ "$top" != "$abs_dir" || "$cur" != "$br" ]]; then
      echo "✗ lane guard: expected worktree ${abs_dir} on ${br}, got ${top:-<none>} on ${cur:-<none>}" >&2
      exit 1
    fi
    WGM_SWARM_LANE=1 WGM_SWARM_ROOT="$abs_dir" WGM_SWARM_BRANCH="$br" \
      WGM_SWARM_PARENT_ROOT="$PARENT_GIT_ROOT" WGM_SWARM_PARENT_HASH="$PARENT_FINGERPRINT" \
      WGM_SWARM_PREFIX="$PREFIX" WGM_SWARM_WORKTREE_DIR="$WT_ABS" WGM_SWARM_RUNTIME_DIR="$PARENT_ROOT/.wgm" \
      WGM_SWARM_SAFE_PREFIX="$SAFE_PREFIX" WGM_SWARM_COUNT="${#TASKS[@]}" \
      WGM_PARENT_TASK="${task:-stream-${i}}" \
      "$LOOP" build "$MAXIT" "${reqflag[@]}" "${lane_gate_args[@]}" --commit \
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
  LANE_NUMS+=("$i")
  echo "↗ stream $i → branch ${br}${task:+ — ${task}}"
done

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
done
printf '%-7s %-24s %-6s %s\n' "stream" "branch" "status" "commits"
for idx in "${!PIDS[@]}"; do
  st="${LANE_STATUS[$idx]}"
  commits="$(git rev-list --count "${BASE_SHA}..${BRANCHES[$idx]}" 2>/dev/null || echo '?')"
  if [[ "$st" == "ok" ]] && { [[ "$commits" == "0" || "$commits" == "?" ]] \
      || ! git merge-base --is-ancestor "$BASE_SHA" "${BRANCHES[$idx]}"; }; then
    st="FAIL"
    FAIL=1
    echo "✗ stream ${LANE_NUMS[$idx]}: agent exited successfully but produced no verifiable commit artifact." >&2
  fi
  top="$(git -C "${DIRS[$idx]}" rev-parse --show-toplevel 2>/dev/null || true)"
  branch="$(git -C "${DIRS[$idx]}" branch --show-current 2>/dev/null || true)"
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
if ! parent_head_unchanged || ! parent_state_matches; then
  echo "✗ parent Git HEAD or branch changed, or its checkout, index, or non-lane refs drifted; retain lanes for inspection." >&2
  PARENT_STABLE=0
  FAIL=1
fi

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
  while IFS=$'\t' read -r _start _end _iter _mode _agent dur _rest; do
    [[ "$_start" == "start_timestamp" ]] && continue
    if [[ "$dur" =~ ^[0-9]+$ ]]; then
      ACTIVE_SECS=$(( ACTIVE_SECS + dur )); TURNS_TIMED=$(( TURNS_TIMED + 1 ))
    else
      TURNS_MISSING=$(( TURNS_MISSING + 1 ))
    fi
  done < "$ledger"
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
echo "Ratios are operational heuristics from one run — not billing data and not a causal speedup claim."
if (( LANES_UNMETERED > 0 || TURNS_MISSING > 0 )); then
  echo "NOTE: ${LANES_UNMETERED} lane(s) and ${TURNS_MISSING} turn(s) have no duration telemetry — active agent time is a LOWER BOUND."
fi

MAIN_MEMORIES=".wgm/memories.md"
CONSOLIDATED_ANY=0
for idx in "${!DIRS[@]}"; do
  memories="${DIRS[$idx]}/.wgm/memories.md"
  [[ -f "$memories" ]] || continue
  if [[ "${LANE_STATUS[$idx]}" != ok || "$PARENT_STABLE" -ne 1 ]]; then
    echo "✗ stream ${LANE_NUMS[$idx]}: unverified memories retained at $memories, not harvested." >&2
    continue
  fi
  mkdir -p .wgm
  lines="$(wc -l < "$memories")"
  {
    printf '\n<!-- from %s -->\n\n' "${BRANCHES[$idx]}"
    cat "$memories"
    printf '\n'
  } >> "$MAIN_MEMORIES"
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
      echo "✗ stream ${LANE_NUMS[$idx]}: failed or parent-changed lane retained at $d for recovery." >&2
      FAIL=1
      continue
    fi
    top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)"
    branch="$(git -C "$d" branch --show-current 2>/dev/null || true)"
    if ! abs_dir="$(cd "$d" 2>/dev/null && pwd)"; then
      abs_dir=""
    fi
    dirty="$(git -C "$d" status --porcelain=v1 --untracked-files=all -- . ':(exclude).wgm' ':(exclude).wgm/**' 2>/dev/null)" || dirty="<status failed>"
    # Tracked .wgm paths are project data even when the directory is otherwise ignored scratch.
    tracked_dirty="$(git -C "$d" status --porcelain=v1 --untracked-files=no 2>/dev/null)" || tracked_dirty="<tracked-status failed>"
    # Ignored build/user data is invisible to ordinary status. Only wgm scratch and jj metadata
    # are eligible for removal; other ignored artifacts require explicit operator inspection.
    if ignored="$(git -C "$d" ls-files --others --ignored --exclude-standard --directory -- . ':(exclude).wgm' ':(exclude).wgm/**' ':(exclude).jj' ':(exclude).jj/**' 2>/dev/null)"; then
      # Git may report the ignored directory itself despite an exclusion for its contents.
      ignored="$(printf '%s\n' "$ignored" | awk '$0 != ".wgm/" && $0 != ".jj/"')"
    else
      ignored="<ignored-file inspection failed>"
    fi
    if [[ -z "$abs_dir" || "$top" != "$abs_dir" || "$branch" != "${BRANCHES[$idx]}" || -n "$dirty" || -n "$tracked_dirty" || -n "$ignored" ]]; then
      echo "✗ stream ${LANE_NUMS[$idx]}: dirty or unverified lane retained at $d for recovery." >&2
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
