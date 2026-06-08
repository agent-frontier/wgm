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
#   mode             grill | analyze | plan | build | loop | review   (default: build; loop = build)
#   max_iterations   integer; 0 = unlimited (default: 0 for build, 1 for single-phase modes)
#   only             run a single iteration/phase then stop (e.g. `build only`)
#
# Flags:
#   --agent "CMD"    agent command, shell-evaluated (overrides $WGM_AGENT)
#   --request "TXT"  user request/scope to inject into the prompt (useful for plan/build)
#   --dry-run        print the prompt and the command that WOULD run; invoke nothing
#   --commit         git add -A && git commit after each build iteration (off by default)
#   -h | --help      show this help
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
REQUEST=""
AGENT_ARGV=()
PROMPT_STDIN="${WGM_PROMPT_STDIN:-0}"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

# ----- parse args -----------------------------------------------------------
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --commit)  DO_COMMIT=1; shift ;;
    --agent)   [[ $# -ge 2 ]] || { echo "--agent requires a command" >&2; exit 2; }; AGENT="$2"; shift 2 ;;
    --request) [[ $# -ge 2 ]] || { echo "--request requires text" >&2; exit 2; }; REQUEST="$2"; shift 2 ;;
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
  grill|analyze|plan|build|review) ;;
  *) echo "Invalid mode: $MODE (expected grill|analyze|plan|build|loop|review)" >&2; exit 2 ;;
esac

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

if [[ "$DRY_RUN" -eq 0 ]] && [[ "$MODE" == "build" || "$MODE" == "review" ]] && [[ -z "$PLAN" ]]; then
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
  build)    TASK="Read ${PLAN_REF}, pick the SINGLE most important pending task, implement it, run its validation/backpressure command, review the diff, and update the plan. Do EXACTLY ONE task, then stop. If NO pending must-have task remains, do not edit code — write the Ship/Handoff summary and create the ${STOP_FILE} sentinel file to end the loop." ;;
esac

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

if [[ ${#AGENT_ARGV[@]} -eq 0 && -z "$AGENT" ]]; then
  echo "No agent configured. Set \$WGM_AGENT, pass --agent \"CMD\", or append -- argv. See --help." >&2
  exit 2
fi

# ----- run the loop ---------------------------------------------------------
run_agent() {
  if [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then
    if [[ "$PROMPT_STDIN" == "1" ]]; then printf '%s' "$PROMPT" | "${AGENT_ARGV[@]}"
    else "${AGENT_ARGV[@]}" "$PROMPT"; fi
  elif [[ "$PROMPT_STDIN" == "1" ]]; then printf '%s' "$PROMPT" | eval "$AGENT"
  else eval "$AGENT \"\$PROMPT\""; fi
}

ITER=0
COMPLETED=0
while :; do
  ITER=$((ITER + 1))
  if [[ "$MAX_ITERS" -ne 0 && "$ITER" -gt "$MAX_ITERS" ]]; then
    echo "Reached max iterations ($MAX_ITERS)."; break
  fi
  if [[ -f "$STOP_FILE" ]]; then echo "Stop sentinel '$STOP_FILE' found; ending."; break; fi

  echo ""
  echo "==================== wgm ${MODE} — iteration ${ITER} ===================="
  run_agent || { echo "Agent exited non-zero on iteration ${ITER}; stopping." >&2; exit 1; }
  COMPLETED=$((COMPLETED + 1))

  if [[ "$MODE" == "build" && "$DO_COMMIT" -eq 1 ]]; then
    git add -A && git commit -m "wgm: build iteration ${ITER}" || echo "(nothing to commit)"
  fi

  # Single-phase modes do one pass.
  [[ "$MODE" != "build" ]] && break
done

echo "wgm loop finished (${COMPLETED} iteration(s))."
