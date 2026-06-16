#!/usr/bin/env bash
#
# wgm/loop.sh — OPTIONAL host-agnostic Ralph outer loop for the `wgm` skill.
#
# Ralph's strength is a FRESH context every iteration. This script provides that by invoking your
# coding agent once per iteration, each time feeding it a short prompt that tells it to follow the
# `wgm` skill in a given mode and advance exactly ONE task. The persistent IMPLEMENTATION_PLAN.md
# is the shared state between otherwise-disposable iterations.
#
# This script is generic: it does not know your agent's CLI. Provide it one of two ways:
#   * $WGM_AGENT (or --agent "CMD") — a command line evaluated by the shell. Set this only to a
#     command you trust; the prompt is appended as the final argument.
#       export WGM_AGENT='claude --dangerously-skip-permissions -p'
#       export WGM_AGENT='copilot -p'
#       export WGM_AGENT='codex exec'
#   * a `--` passthrough — everything after `--` is the agent argv, invoked WITHOUT eval (safest):
#       ./scripts/loop.sh build -- claude -p
# If your agent reads the prompt from STDIN instead of an argument, set WGM_PROMPT_STDIN=1.
#
# Usage:
#   ./scripts/loop.sh [mode] [max_iterations|only] [flags] [-- agent argv...]
#
#   mode             grill | analyze | plan | preflight | build | loop | review | extract
#                    (default: build; loop = build)
#   max_iterations   integer; 0 = unlimited (default: 0 for build, 1 for single-phase modes)
#   only             run a single iteration/phase then stop (e.g. `build only`)
#
# Flags:
#   --agent "CMD"        agent command, shell-evaluated (overrides $WGM_AGENT)
#   --frugal-agent "CMD" cheaper agent for routine iterations; escalates to --agent on a stall
#                        (overrides $WGM_FRUGAL_AGENT). Needs --agent set to enable escalation.
#   --request "TXT"      user request/scope to inject into the prompt (useful for plan/build)
#   --threshold N        satisfaction target 0-100 to converge to in build (default: 95)
#   --scenarios DIR      where the holdout scenarios live (default: scenarios/ or .wgm/scenarios/)
#   --stratified         validate scenarios by ascending tier (1->2->3)
#   --container ENGINE   podman | docker for containerized scenario validation (default: podman)
#   --source DIR         exemplar dir for `extract` (gene transfusion)
#   --escalate-after N   consecutive no-progress iterations before escalating (default: 2)
#   --downgrade-after N  consecutive progressing iterations before downgrading to frugal (default: 5)
#   --max-runtime-seconds N  hard wall-clock cap for the whole loop; 0 = unlimited (default: 0)
#   --idle-timeout N     stop if the plan makes no progress for N seconds; 0 = disabled (default: 0)
#   --checkpoint-interval N  git add -A && commit every N build iterations; 0 = off (default: 0)
#   --notify "CMD"       run CMD (shell) on lifecycle events with $WGM_EVENT (start|complete|error)
#                        and $WGM_ITER set; best-effort — its failure never fails the loop
#   --dry-run            print the prompt and the command that WOULD run; invoke nothing
#   --commit             git add -A && git commit after each build iteration (off by default)
#   -h | --help          show this help
#
# Safety:
#   * Non-destructive by default (no commits, no pushes) unless --commit is passed. The agent may
#     still edit files during a non-dry run — run this only in a workspace you trust it in.
#   * build/review modes refuse to run without an IMPLEMENTATION_PLAN.md (root or .wgm/).
#   * Stop anytime with Ctrl+C, or create a .wgm/STOP (or ./STOP) sentinel to end after the
#     current iteration. In build mode the agent is told to create that sentinel when no
#     must-have task remains, so the loop self-terminates.

set -euo pipefail

# ----- defaults -------------------------------------------------------------
MODE="build"
MAX_ITERS=""
ONLY=0
DRY_RUN=0
DO_COMMIT=0
AGENT="${WGM_AGENT:-}"
FRUGAL_AGENT="${WGM_FRUGAL_AGENT:-}"
REQUEST=""
AGENT_ARGV=()
PROMPT_STDIN="${WGM_PROMPT_STDIN:-0}"
THRESHOLD=95
SCENARIOS_DIR=""
STRATIFIED=0
CONTAINER="podman"
SOURCE_DIR=""
ESCALATE_AFTER=2
DOWNGRADE_AFTER=5
MAX_RUNTIME=0
IDLE_TIMEOUT=0
CHECKPOINT_INTERVAL=0
NOTIFY=""

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

# ----- parse args -----------------------------------------------------------
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --commit)  DO_COMMIT=1; shift ;;
    --agent)   [[ $# -ge 2 ]] || { echo "--agent requires a command" >&2; exit 2; }; AGENT="$2"; shift 2 ;;
    --frugal-agent) [[ $# -ge 2 ]] || { echo "--frugal-agent requires a command" >&2; exit 2; }; FRUGAL_AGENT="$2"; shift 2 ;;
    --request) [[ $# -ge 2 ]] || { echo "--request requires text" >&2; exit 2; }; REQUEST="$2"; shift 2 ;;
    --threshold) [[ $# -ge 2 ]] || { echo "--threshold requires a number" >&2; exit 2; }; THRESHOLD="$2"; shift 2 ;;
    --scenarios) [[ $# -ge 2 ]] || { echo "--scenarios requires a dir" >&2; exit 2; }; SCENARIOS_DIR="$2"; shift 2 ;;
    --stratified) STRATIFIED=1; shift ;;
    --container) [[ $# -ge 2 ]] || { echo "--container requires podman|docker" >&2; exit 2; }; CONTAINER="$2"; shift 2 ;;
    --source) [[ $# -ge 2 ]] || { echo "--source requires a dir" >&2; exit 2; }; SOURCE_DIR="$2"; shift 2 ;;
    --escalate-after) [[ $# -ge 2 ]] || { echo "--escalate-after requires a number" >&2; exit 2; }; ESCALATE_AFTER="$2"; shift 2 ;;
    --downgrade-after) [[ $# -ge 2 ]] || { echo "--downgrade-after requires a number" >&2; exit 2; }; DOWNGRADE_AFTER="$2"; shift 2 ;;
    --max-runtime-seconds) [[ $# -ge 2 ]] || { echo "--max-runtime-seconds requires a number" >&2; exit 2; }; MAX_RUNTIME="$2"; shift 2 ;;
    --idle-timeout) [[ $# -ge 2 ]] || { echo "--idle-timeout requires a number" >&2; exit 2; }; IDLE_TIMEOUT="$2"; shift 2 ;;
    --checkpoint-interval) [[ $# -ge 2 ]] || { echo "--checkpoint-interval requires a number" >&2; exit 2; }; CHECKPOINT_INTERVAL="$2"; shift 2 ;;
    --notify) [[ $# -ge 2 ]] || { echo "--notify requires a command" >&2; exit 2; }; NOTIFY="$2"; shift 2 ;;
    --)        shift; AGENT_ARGV=("$@"); break ;;
    --*)       echo "Unknown flag: $1" >&2; exit 2 ;;
    *)         POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ ${#POSITIONAL[@]} -ge 1 ]]; then MODE="${POSITIONAL[0]}"; fi
if [[ ${#POSITIONAL[@]} -ge 2 ]]; then
  if [[ "${POSITIONAL[1]}" == "only" ]]; then ONLY=1; else MAX_ITERS="${POSITIONAL[1]}"; fi
fi
[[ "$MODE" == "loop" ]] && MODE="build"

case "$MODE" in
  grill|analyze|plan|preflight|build|review|extract) ;;
  *) echo "Invalid mode: $MODE (expected grill|analyze|plan|preflight|build|loop|review|extract)" >&2; exit 2 ;;
esac

case "$CONTAINER" in podman|docker) ;; *) echo "Invalid --container: $CONTAINER (podman|docker)" >&2; exit 2 ;; esac
for n in "$THRESHOLD" "$ESCALATE_AFTER" "$DOWNGRADE_AFTER" "$MAX_RUNTIME" "$IDLE_TIMEOUT" "$CHECKPOINT_INTERVAL"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "expected a non-negative integer, got: $n" >&2; exit 2; }
done

# Single-phase modes run once by default; build runs unlimited by default; `only` forces one pass.
if [[ -z "$MAX_ITERS" ]]; then
  if [[ "$MODE" == "build" ]]; then MAX_ITERS=0; else MAX_ITERS=1; fi
fi
[[ "$ONLY" -eq 1 ]] && MAX_ITERS=1
if ! [[ "$MAX_ITERS" =~ ^[0-9]+$ ]]; then
  echo "max_iterations must be a non-negative integer (or 'only'), got: $MAX_ITERS" >&2; exit 2
fi

# ----- locate the plan / working dir ---------------------------------------
PLAN=""
if [[ -f "IMPLEMENTATION_PLAN.md" ]]; then PLAN="IMPLEMENTATION_PLAN.md"
elif [[ -f ".wgm/IMPLEMENTATION_PLAN.md" ]]; then PLAN=".wgm/IMPLEMENTATION_PLAN.md"
fi
STOP_FILE=".wgm/STOP"; [[ -d .wgm ]] || STOP_FILE="STOP"

if [[ "$DRY_RUN" -eq 0 ]] && [[ "$MODE" == "build" || "$MODE" == "review" || "$MODE" == "preflight" ]] && [[ -z "$PLAN" ]]; then
  echo "Refusing to run '$MODE': no IMPLEMENTATION_PLAN.md found (root or .wgm/)." >&2
  echo "Run './scripts/loop.sh plan' (or '/wgm plan') first to create one." >&2
  exit 1
fi
PLAN_REF="${PLAN:-IMPLEMENTATION_PLAN.md (none yet)}"

# ----- build the per-iteration prompt --------------------------------------
case "$MODE" in
  grill)    TASK="Run ONLY the Grill phase: interview to alignment, then stop at the Grill-exit gate." ;;
  analyze)  TASK="Run ONLY the Analyze phase: explore the code and requirements and report findings/specs. Do NOT implement." ;;
  plan)     TASK="Run ONLY the Plan phase: write/refresh specs and ${PLAN_REF}. Stop at the Plan-exit gate." ;;
  review)   TASK="Run ONLY a Review: assess the current diff against the acceptance criteria in ${PLAN_REF}. Do NOT write new code." ;;
  preflight) TASK="Run ONLY Preflight: score the plan's readiness 0-100 (goal clarity, observable success criteria, scenario coverage of the demo path, acceptance->backpressure mapping, scope edges) per references/scoring.md. If readiness is below ~80, list the weakest dimensions to fix and STOP. Do NOT implement." ;;
  extract)  TASK="Run ONLY gene transfusion: survey the exemplar codebase at ${SOURCE_DIR:-<set --source DIR>} and distill reusable patterns into .wgm/genes.md (or AGENTS.md 'Codebase patterns') per references/gene-transfusion.md. Extract patterns, not code; cite sources. Do NOT implement features." ;;
  build)    TASK="Read ${PLAN_REF}, pick the SINGLE most important pending task, implement it, run its validation/backpressure command, review the diff, and update the plan. Do EXACTLY ONE task, then stop. If NO pending must-have task remains, do not edit code — write the Ship/Handoff summary and create the ${STOP_FILE} sentinel file to end the loop." ;;
esac

if [[ "$MODE" == "build" ]]; then
  SCN_REF="${SCENARIOS_DIR:-scenarios/ or .wgm/scenarios/}"
  TASK="${TASK}
Holdout judging: do NOT read scenario files while implementing. In Validate, judge satisfaction (0-100) against the holdout scenarios in ${SCN_REF} and converge to overall satisfaction >= ${THRESHOLD} (deterministic checks still gate 'done')."
  [[ "$STRATIFIED" -eq 1 ]] && TASK="${TASK}
Stratified: validate scenarios by ascending tier (1->2->3); converge a tier before advancing."
  TASK="${TASK}
If a scenario needs a running service, build and run it with ${CONTAINER} (OCI) per references/validation-env.md.
On a stall (satisfaction flat ~2 iterations, or a task failing repeatedly), run wonder/reflect and consider model escalation per references/stall-recovery.md."
fi

REQ_LINE=""
[[ -n "$REQUEST" ]] && REQ_LINE="User request / scope: ${REQUEST}"

read -r -d '' PROMPT <<EOF || true
Use the wgm skill (SKILL.md). Mode: ${MODE}.
${TASK}
${REQ_LINE}
Honor wgm's gates, backpressure (a task is done only when its validation command exits 0), and
context hygiene (advance exactly one task; leave ${PLAN_REF} resumable by a fresh agent).
EOF

# ----- dry run --------------------------------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "== wgm loop (dry run) =="
  echo "mode=${MODE} max_iterations=${MAX_ITERS} plan=${PLAN_REF} commit=${DO_COMMIT}"
  echo "threshold=${THRESHOLD} stratified=${STRATIFIED} container=${CONTAINER} scenarios=${SCENARIOS_DIR:-auto} frugal=${FRUGAL_AGENT:+set}"
  echo "max_runtime=${MAX_RUNTIME}s idle_timeout=${IDLE_TIMEOUT}s checkpoint_interval=${CHECKPOINT_INTERVAL} notify=${NOTIFY:+set}"
  if [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then echo "agent(argv)=${AGENT_ARGV[*]}"
  else echo "agent=${AGENT:-<unset: set \$WGM_AGENT, --agent, or -- argv>}"; fi
  echo "--- prompt ---"; printf '%s\n' "$PROMPT"
  echo "--- would invoke (per iteration) ---"
  if [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then
    if [[ "$PROMPT_STDIN" == "1" ]]; then echo "printf '%s' \"\$PROMPT\" | ${AGENT_ARGV[*]}"
    else echo "${AGENT_ARGV[*]} \"\$PROMPT\""; fi
  elif [[ "$PROMPT_STDIN" == "1" ]]; then echo "printf '%s' \"\$PROMPT\" | ${AGENT:-<agent>}"
  else echo "${AGENT:-<agent>} \"\$PROMPT\""; fi
  exit 0
fi

if [[ ${#AGENT_ARGV[@]} -eq 0 && -z "$AGENT" && -z "$FRUGAL_AGENT" ]]; then
  echo "No agent configured. Set \$WGM_AGENT, pass --agent \"CMD\", --frugal-agent \"CMD\", or append -- argv. See --help." >&2
  exit 2
fi

# ----- run the loop ---------------------------------------------------------
run_main() {
  if [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then
    if [[ "$PROMPT_STDIN" == "1" ]]; then printf '%s' "$PROMPT" | "${AGENT_ARGV[@]}"
    else "${AGENT_ARGV[@]}" "$PROMPT"; fi
  elif [[ "$PROMPT_STDIN" == "1" ]]; then printf '%s' "$PROMPT" | eval "$AGENT"
  else eval "$AGENT \"\$PROMPT\""; fi
}
run_frugal() {
  if [[ "$PROMPT_STDIN" == "1" ]]; then printf '%s' "$PROMPT" | eval "$FRUGAL_AGENT"
  else eval "$FRUGAL_AGENT \"\$PROMPT\""; fi
}
plan_hash() {
  if [[ -n "$PLAN" && -f "$PLAN" ]]; then
    if command -v sha1sum >/dev/null 2>&1; then sha1sum "$PLAN" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum "$PLAN" | awk '{print $1}'
    else cksum "$PLAN" | awk '{print $1}'; fi
  else
    echo "none"
  fi
}

notify() {  # $1 = lifecycle event; best-effort, its failure never breaks the loop
  [[ -n "$NOTIFY" ]] || return 0
  WGM_EVENT="$1" WGM_ITER="${ITER:-0}" bash -c "$NOTIFY" || true
}

# Model escalation engages only when BOTH a frugal and a main agent are available.
HAVE_MAIN=0
[[ ${#AGENT_ARGV[@]} -gt 0 || -n "$AGENT" ]] && HAVE_MAIN=1
ESC_ENABLED=0
[[ -n "$FRUGAL_AGENT" && "$HAVE_MAIN" -eq 1 ]] && ESC_ENABLED=1
if [[ -n "$FRUGAL_AGENT" ]]; then ACTIVE="frugal"; else ACTIVE="main"; fi
run_current() { if [[ "$ACTIVE" == "frugal" ]]; then run_frugal; else run_main; fi; }

ITER=0
COMPLETED=0
NOPROG=0
PROG=0
START_TS=$(date +%s)
LAST_PROG_TS=$START_TS
notify start
while :; do
  ITER=$((ITER + 1))
  if [[ "$MAX_ITERS" -ne 0 && "$ITER" -gt "$MAX_ITERS" ]]; then
    echo "Reached max iterations ($MAX_ITERS)."; break
  fi
  if [[ "$MAX_RUNTIME" -ne 0 && $(( $(date +%s) - START_TS )) -ge "$MAX_RUNTIME" ]]; then
    echo "Reached max runtime (${MAX_RUNTIME}s)."; break
  fi
  if [[ -f "$STOP_FILE" ]]; then echo "Stop sentinel '$STOP_FILE' found; ending."; break; fi

  echo ""
  echo "==================== wgm ${MODE} (${ACTIVE}) — iteration ${ITER} ===================="
  HASH_BEFORE="$(plan_hash)"
  run_current || { echo "Agent exited non-zero on iteration ${ITER}; stopping." >&2; notify error; exit 1; }
  COMPLETED=$((COMPLETED + 1))

  if [[ "$MODE" == "build" ]]; then
    DO_CP=0
    [[ "$DO_COMMIT" -eq 1 ]] && DO_CP=1
    [[ "$CHECKPOINT_INTERVAL" -ne 0 && $(( ITER % CHECKPOINT_INTERVAL )) -eq 0 ]] && DO_CP=1
    if [[ "$DO_CP" -eq 1 ]]; then
      git add -A && git commit -m "wgm: build iteration ${ITER}" || echo "(nothing to commit)"
    fi
  fi

  # Progress proxy (build): did this iteration change the plan file? Drives idle-timeout + escalation.
  if [[ "$MODE" == "build" ]]; then
    HASH_AFTER="$(plan_hash)"
    [[ "$HASH_AFTER" != "$HASH_BEFORE" ]] && LAST_PROG_TS=$(date +%s)
    if [[ "$IDLE_TIMEOUT" -ne 0 && $(( $(date +%s) - LAST_PROG_TS )) -ge "$IDLE_TIMEOUT" ]]; then
      echo "Idle timeout: no plan progress for ${IDLE_TIMEOUT}s; ending."; break
    fi
    if [[ "$ESC_ENABLED" -eq 1 ]]; then
      if [[ "$HASH_AFTER" != "$HASH_BEFORE" ]]; then PROG=$((PROG + 1)); NOPROG=0
      else NOPROG=$((NOPROG + 1)); PROG=0; fi
      if [[ "$ACTIVE" == "frugal" && "$NOPROG" -ge "$ESCALATE_AFTER" ]]; then
        ACTIVE="main"; NOPROG=0; PROG=0
        echo "↑ escalating to main agent (no progress for ${ESCALATE_AFTER} iteration(s))."
      elif [[ "$ACTIVE" == "main" && "$PROG" -ge "$DOWNGRADE_AFTER" ]]; then
        ACTIVE="frugal"; NOPROG=0; PROG=0
        echo "↓ downgrading to frugal agent (${DOWNGRADE_AFTER} progressing iteration(s))."
      fi
    fi
  fi

  # Single-phase modes do one pass.
  [[ "$MODE" != "build" ]] && break
done

notify complete
echo "wgm loop finished (${COMPLETED} iteration(s))."
