#!/usr/bin/env bash
#
# wgm/swarm.sh — fan out N parallel wgm Ralph loops, each in its own git worktree + branch.
#
# "Swarm coding": instead of one sequential loop, the sheepdog (this script) spawns several dogs that
# work in PARALLEL on independent slices, each isolated in its own `git worktree` on its own branch so
# they never collide. Each stream runs `scripts/loop.sh build` (the sibling runner). When they finish
# you review and merge the branches — one thought per branch — and any per-stream `.wgm/memories.md`
# notes are always consolidated back into the invoking worktree before optional cleanup, then handed
# to `harvest-hive.sh` (the Hive Growth Loop's standing dispatch — safe to call unconditionally; it
# owns every consent/anonymize decision itself and never fails the swarm run).
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
METRICS_DIR="$(pwd)/.wgm/metrics"
mkdir -p "$METRICS_DIR"
SWARM_START=$(date +%s)

PIDS=()
BRANCHES=()
DIRS=()
LANE_START=()
LANE_END=()
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
  # Every lane is timed: its own metrics ledger lands in the PARENT's .wgm/metrics/ so the summary
  # below can aggregate it even when --cleanup removes the worktree.
  ( cd "$dir" && WGM_PARENT_TASK="${task:-stream-${i}}" \
      "$LOOP" build "$MAXIT" "${reqflag[@]}" --commit \
      --metrics "${METRICS_DIR}/${SAFE_PREFIX}-${i}.tsv" -- "${AGENT_ARGV[@]}" ) >"${dir}/.swarm.log" 2>&1 &
  PIDS+=("$!")
  BRANCHES+=("$br")
  DIRS+=("$dir")
  LANE_START+=("$(date +%s)")
  echo "↗ stream $i → branch ${br}${task:+ — ${task}}"
done

[[ ${#PIDS[@]} -ge 1 ]] || { echo "No streams started." >&2; exit 1; }

echo ""
echo "Waiting for ${#PIDS[@]} stream(s)…"
FAIL=0
printf '%-7s %-24s %-6s %s\n' "stream" "branch" "status" "commits"
for idx in "${!PIDS[@]}"; do
  if wait "${PIDS[$idx]}"; then st="ok"; else st="FAIL"; FAIL=1; fi
  LANE_END[idx]="$(date +%s)"
  commits="$(git rev-list --count "HEAD..${BRANCHES[$idx]}" 2>/dev/null || echo '?')"
  printf '%-7s %-24s %-6s %s\n' "$((idx + 1))" "${BRANCHES[$idx]}" "$st" "$commits"
done

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
  ledger="${METRICS_DIR}/${SAFE_PREFIX}-$((idx + 1)).tsv"
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
  mkdir -p .wgm
  lines="$(wc -l < "$memories")"
  {
    printf '\n<!-- from %s -->\n\n' "${BRANCHES[$idx]}"
    cat "$memories"
    printf '\n'
  } >> "$MAIN_MEMORIES"
  echo "✓ stream $((idx + 1)): consolidated .wgm/memories.md (${lines} lines) from ${BRANCHES[$idx]}"
  CONSOLIDATED_ANY=1
done

# Standing hive dispatch: hand the just-consolidated memories to harvest-hive.sh unconditionally.
# harvest-hive.sh itself owns every safety decision from here (no consent file yet -> declines for
# this run only, without persisting anything on a human's behalf; consent false -> local preview
# only; consent true -> real anonymized upstream report) -- swarm.sh does not duplicate that logic,
# and a harvest hiccup never fails the swarm itself.
if [[ "$CONSOLIDATED_ANY" -eq 1 && -x "$HERE/harvest-hive.sh" ]]; then
  "$HERE/harvest-hive.sh" </dev/null || echo "(harvest-hive.sh had a non-zero exit; swarm result is unaffected)" >&2
fi

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
