#!/usr/bin/env bash
#
# wgm/swarm.sh — fan out N parallel wgm Ralph loops, each in its own git worktree + branch.
#
# "Swarm coding": instead of one sequential loop, the sheepdog (this script) spawns several dogs that
# work in PARALLEL on independent slices, each isolated in its own `git worktree` on its own branch so
# they never collide. Each stream runs `scripts/loop.sh build` (the sibling runner). When they finish
# you review and merge the branches — one thought per branch.
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
#   --worktree-dir DIR  base dir for the worktrees (default: .wgm/worktrees; gitignored by wgm)
#   --cleanup           remove the worktree dirs when done — branches are KEPT for merging
#   --dry-run           print the plan; create no worktrees and run nothing
#   -h | --help         show this help
#
# Everything after `--` is the agent argv, forwarded verbatim to each stream's loop.sh (or set
# $WGM_AGENT). The streams run with --commit so each branch carries its work.
#
# Safety:
#   * Operates on the current git repo (run it from the target project root). Requires an
#     IMPLEMENTATION_PLAN.md (root or .wgm/) — run '/wgm plan' first.
#   * Worktrees live under .wgm/worktrees/ (wgm gitignores .wgm/). Merge a stream with
#     `git merge wgm/swarm/<i>`; drop one with `git worktree remove` + `git branch -D`.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP="$HERE/loop.sh"

TASKS_FILE=""
COUNT=0
MAXIT=0
PREFIX="wgm/swarm"
WT_DIR=".wgm/worktrees"
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
    --worktree-dir) [[ $# -ge 2 ]] || { echo "--worktree-dir requires a dir" >&2; exit 2; }; WT_DIR="$2"; shift 2 ;;
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

SAFE_PREFIX="${PREFIX//\//-}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "== wgm swarm (dry run) =="
  echo "streams=${#TASKS[@]} prefix=${PREFIX} worktree_dir=${WT_DIR} max_iterations=${MAXIT} cleanup=${CLEANUP}"
  if [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then echo "agent(argv)=${AGENT_ARGV[*]}"; else echo "agent=\$WGM_AGENT"; fi
  i=0
  for task in "${TASKS[@]}"; do
    i=$((i + 1))
    echo "  stream $i → branch ${PREFIX}/${i} (worktree ${WT_DIR}/${SAFE_PREFIX}-${i})${task:+ — ${task}}"
  done
  exit 0
fi

mkdir -p "$WT_DIR"

PIDS=()
BRANCHES=()
DIRS=()
i=0
for task in "${TASKS[@]}"; do
  i=$((i + 1))
  br="${PREFIX}/${i}"
  dir="${WT_DIR}/${SAFE_PREFIX}-${i}"
  if [[ -e "$dir" ]] || git show-ref --verify --quiet "refs/heads/${br}"; then
    echo "✗ stream $i: branch '${br}' or dir '${dir}' already exists — skipping (clean up a prior run)." >&2
    continue
  fi
  if ! git worktree add -q -b "$br" "$dir" HEAD; then
    echo "✗ stream $i: 'git worktree add' failed for ${br}." >&2
    continue
  fi
  reqflag=()
  [[ -n "$task" ]] && reqflag=(--request "$task")
  ( cd "$dir" && "$LOOP" build "$MAXIT" "${reqflag[@]}" --commit -- "${AGENT_ARGV[@]}" ) >"${dir}/.swarm.log" 2>&1 &
  PIDS+=("$!")
  BRANCHES+=("$br")
  DIRS+=("$dir")
  echo "↗ stream $i → branch ${br}${task:+ — ${task}}"
done

[[ ${#PIDS[@]} -ge 1 ]] || { echo "No streams started." >&2; exit 1; }

echo ""
echo "Waiting for ${#PIDS[@]} stream(s)…"
FAIL=0
printf '%-7s %-24s %-6s %s\n' "stream" "branch" "status" "commits"
for idx in "${!PIDS[@]}"; do
  if wait "${PIDS[$idx]}"; then st="ok"; else st="FAIL"; FAIL=1; fi
  commits="$(git rev-list --count "HEAD..${BRANCHES[$idx]}" 2>/dev/null || echo '?')"
  printf '%-7s %-24s %-6s %s\n' "$((idx + 1))" "${BRANCHES[$idx]}" "$st" "$commits"
done

if [[ "$CLEANUP" -eq 1 ]]; then
  for d in "${DIRS[@]}"; do git worktree remove --force "$d" 2>/dev/null || true; done
  echo "(worktree dirs removed; branches kept — merge with: git merge ${PREFIX}/<i>)"
else
  echo "Worktrees kept under ${WT_DIR}/. Merge a stream with: git merge ${PREFIX}/<i>"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "swarm: all ${#PIDS[@]} stream(s) ok"
else
  echo "swarm: one or more streams failed (see ${WT_DIR}/*/.swarm.log)" >&2
fi
exit "$FAIL"
