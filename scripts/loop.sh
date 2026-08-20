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
#       export WGM_AGENT='copilot -p --allow-all-tools'
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
#   --plan FILE          explicit implementation plan path; otherwise prefer `.wgm/` when both
#                        root and `.wgm/` plans exist
#   --threshold N        satisfaction target 0-100 to converge to in build (default: 95)
#   --scenarios DIR      where the holdout scenarios live (default: scenarios/ or .wgm/scenarios/)
#   --stratified         validate scenarios by ascending tier (1->2->3)
#   --container ENGINE   auto | podman | docker for scenario validation (default: auto; auto selects
#                        available Podman, then Docker)
#   --agent-timeout-seconds N
#                        terminate an active agent process group after N seconds when GNU
#                        timeout/gtimeout is available; 0 = disabled (default: 0)
#   --source DIR         exemplar dir for `extract` (gene transfusion)
#   --escalate-after N   consecutive no-progress iterations before escalating (default: 2)
#   --downgrade-after N  consecutive progressing iterations before downgrading to frugal (default: 5)
#   --max-runtime-seconds N  hard wall-clock cap for the whole loop; 0 = unlimited (default: 0)
#   --idle-timeout N     stop if the plan makes no progress for N seconds; 0 = disabled (default: 0)
#   --max-no-progress-iterations N
#                        fail a build after N successful iterations leave the plan unchanged;
#                        0 = disabled (default: 3)
#   --checkpoint-interval N  commit every N build iterations; 0 = off (default: 0)
#   --notify "CMD"       run CMD (shell) on lifecycle events with $WGM_EVENT (start|complete|error)
#                        and $WGM_ITER set; best-effort — its failure never fails the loop
#   --gates FILE         project-wide backpressure: a YAML file with a `gates:` list of commands,
#                        injected as mandatory checks into every build iteration (default:
#                        auto-detect wgm.yml or .wgm/gates.yml)
#   --max-retries N      retry a failed agent invocation up to N times per iteration, with
#                        exponential backoff + jitter; 0 = no retry (default: 2)
#   --retry-base-delay N base seconds for the backoff (full jitter, capped); 0 = no wait (default: 5)
#   --retry-max-delay N  cap for a single backoff wait, in seconds (default: 60)
#   --max-consecutive-failures N  circuit breaker: stop after N build iterations that fail every
#                        retry in a row; 0 = never trip (default: 3). For fail-fast on the first
#                        error, set --max-retries 0 --max-consecutive-failures 1.
#   --metrics FILE       append a per-iteration TSV row (start_timestamp, end_timestamp, iter, mode,
#                        agent, duration_s, plan_changed, result, cost, parent) to FILE. Telemetry is
#                        ON by default at .wgm/metrics.tsv; pass `--metrics off` to disable it.
#                        $WGM_PARENT_TASK (set by swarm.sh per lane) populates the parent column.
#   --cost-cmd "CMD"     after each iteration run CMD (shell) to print a token/cost figure for the
#                        `cost` column; best-effort, its failure never breaks the loop (default: none)
#   --max-cost N         stop the build loop once cumulative cost (summed from --cost-cmd's output,
#                        whatever unit it emits) reaches N; 0 = unlimited (default: 0). Requires
#                        --cost-cmd to have anything to sum — warns at startup if set without it.
#   --devcontainer       run this ENTIRE invocation sandboxed in wgm's disk-conscious local
#                        devcontainer (scripts/devcontainer.sh) — one shared base image reused
#                        across every project, never a per-project build. See
#                        references/devcontainers.md. A no-op with --dry-run (annotates the
#                        preview instead of launching a container).
#   --dry-run            print the prompt and the command that WOULD run; invoke nothing
#   --commit             commit each build iteration; takes exclusive ownership of the worktree
#   -h | --help          show this help
#
# Safety:
#   * Non-destructive by default (no commits, no pushes) unless --commit is passed. The agent may
#     still edit files during a non-dry run — run this only in a workspace you trust it in.
#   * Every non-dry-run build or plan probes agent write capability before iteration 1.
#   * build/review modes refuse to run without an IMPLEMENTATION_PLAN.md (root or .wgm/).
#   * Stop anytime with Ctrl+C, or create a .wgm/STOP (or ./STOP) sentinel to end after the
#     current iteration. In build mode the agent is told to create that sentinel when no
#     must-have task remains, so the loop self-terminates.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_ARGV=("$@")

# ----- defaults -------------------------------------------------------------
MODE="build"
MAX_ITERS=""
ONLY=0
DRY_RUN=0
DO_COMMIT=0
AGENT="${WGM_AGENT:-}"
FRUGAL_AGENT="${WGM_FRUGAL_AGENT:-}"
REQUEST=""
PLAN_FILE="${WGM_PLAN:-}"
AGENT_ARGV=()
PROMPT_STDIN="${WGM_PROMPT_STDIN:-0}"
THRESHOLD=95
SCENARIOS_DIR=""
STRATIFIED=0
CONTAINER="podman"
CONTAINER_EXPLICIT=0
SOURCE_DIR=""
ESCALATE_AFTER=2
DOWNGRADE_AFTER=5
MAX_RUNTIME=0
IDLE_TIMEOUT=0
MAX_NO_PROGRESS=3
CHECKPOINT_INTERVAL=0
NOTIFY=""
GATES_FILE=""
MAX_RETRIES=2
RETRY_BASE_DELAY=5
RETRY_MAX_DELAY=60
MAX_CONSEC_FAIL=3
METRICS_FILE=""
COST_CMD=""
MAX_COST=0
CUM_COST=0
USE_DEVCONTAINER=0
AGENT_TIMEOUT=0
TIMEOUT_BIN=""

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

# ----- parse args -----------------------------------------------------------
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --commit)  DO_COMMIT=1; shift ;;
    --devcontainer) USE_DEVCONTAINER=1; shift ;;
    --agent)   [[ $# -ge 2 ]] || { echo "--agent requires a command" >&2; exit 2; }; AGENT="$2"; shift 2 ;;
    --frugal-agent) [[ $# -ge 2 ]] || { echo "--frugal-agent requires a command" >&2; exit 2; }; FRUGAL_AGENT="$2"; shift 2 ;;
    --request) [[ $# -ge 2 ]] || { echo "--request requires text" >&2; exit 2; }; REQUEST="$2"; shift 2 ;;
    --plan) [[ $# -ge 2 ]] || { echo "--plan requires a file" >&2; exit 2; }; PLAN_FILE="$2"; shift 2 ;;
    --threshold) [[ $# -ge 2 ]] || { echo "--threshold requires a number" >&2; exit 2; }; THRESHOLD="$2"; shift 2 ;;
    --scenarios) [[ $# -ge 2 ]] || { echo "--scenarios requires a dir" >&2; exit 2; }; SCENARIOS_DIR="$2"; shift 2 ;;
    --stratified) STRATIFIED=1; shift ;;
    --container) [[ $# -ge 2 ]] || { echo "--container requires auto|podman|docker" >&2; exit 2; }; CONTAINER="$2"; CONTAINER_EXPLICIT=1; shift 2 ;;
    --agent-timeout-seconds) [[ $# -ge 2 ]] || { echo "--agent-timeout-seconds requires a number" >&2; exit 2; }; AGENT_TIMEOUT="$2"; shift 2 ;;
    --source) [[ $# -ge 2 ]] || { echo "--source requires a dir" >&2; exit 2; }; SOURCE_DIR="$2"; shift 2 ;;
    --escalate-after) [[ $# -ge 2 ]] || { echo "--escalate-after requires a number" >&2; exit 2; }; ESCALATE_AFTER="$2"; shift 2 ;;
    --downgrade-after) [[ $# -ge 2 ]] || { echo "--downgrade-after requires a number" >&2; exit 2; }; DOWNGRADE_AFTER="$2"; shift 2 ;;
    --max-runtime-seconds) [[ $# -ge 2 ]] || { echo "--max-runtime-seconds requires a number" >&2; exit 2; }; MAX_RUNTIME="$2"; shift 2 ;;
    --idle-timeout) [[ $# -ge 2 ]] || { echo "--idle-timeout requires a number" >&2; exit 2; }; IDLE_TIMEOUT="$2"; shift 2 ;;
    --max-no-progress-iterations) [[ $# -ge 2 ]] || { echo "--max-no-progress-iterations requires a number" >&2; exit 2; }; MAX_NO_PROGRESS="$2"; shift 2 ;;
    --checkpoint-interval) [[ $# -ge 2 ]] || { echo "--checkpoint-interval requires a number" >&2; exit 2; }; CHECKPOINT_INTERVAL="$2"; shift 2 ;;
    --notify) [[ $# -ge 2 ]] || { echo "--notify requires a command" >&2; exit 2; }; NOTIFY="$2"; shift 2 ;;
    --gates) [[ $# -ge 2 ]] || { echo "--gates requires a file" >&2; exit 2; }; GATES_FILE="$2"; shift 2 ;;
    --max-retries) [[ $# -ge 2 ]] || { echo "--max-retries requires a number" >&2; exit 2; }; MAX_RETRIES="$2"; shift 2 ;;
    --retry-base-delay) [[ $# -ge 2 ]] || { echo "--retry-base-delay requires a number" >&2; exit 2; }; RETRY_BASE_DELAY="$2"; shift 2 ;;
    --retry-max-delay) [[ $# -ge 2 ]] || { echo "--retry-max-delay requires a number" >&2; exit 2; }; RETRY_MAX_DELAY="$2"; shift 2 ;;
    --max-consecutive-failures) [[ $# -ge 2 ]] || { echo "--max-consecutive-failures requires a number" >&2; exit 2; }; MAX_CONSEC_FAIL="$2"; shift 2 ;;
    --metrics) [[ $# -ge 2 ]] || { echo "--metrics requires a file" >&2; exit 2; }; METRICS_FILE="$2"; shift 2 ;;
    --cost-cmd) [[ $# -ge 2 ]] || { echo "--cost-cmd requires a command" >&2; exit 2; }; COST_CMD="$2"; shift 2 ;;
    --max-cost) [[ $# -ge 2 ]] || { echo "--max-cost requires a number" >&2; exit 2; }; MAX_COST="$2"; shift 2 ;;
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

case "$CONTAINER" in auto|podman|docker) ;; *) echo "Invalid --container: $CONTAINER (auto|podman|docker)" >&2; exit 2 ;; esac
for n in "$THRESHOLD" "$ESCALATE_AFTER" "$DOWNGRADE_AFTER" "$MAX_RUNTIME" "$IDLE_TIMEOUT" "$MAX_NO_PROGRESS" "$CHECKPOINT_INTERVAL" "$AGENT_TIMEOUT" "$MAX_RETRIES" "$RETRY_BASE_DELAY" "$RETRY_MAX_DELAY" "$MAX_CONSEC_FAIL"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "expected a non-negative integer, got: $n" >&2; exit 2; }
done
# --max-cost is a plain number, not necessarily an integer (a cost figure may be fractional).
[[ "$MAX_COST" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "expected a non-negative number for --max-cost, got: $MAX_COST" >&2; exit 2; }
if [[ -z "$COST_CMD" ]] && awk -v m="$MAX_COST" 'BEGIN{exit !(m>0)}'; then
  echo "⚠ --max-cost is set but --cost-cmd is not; the cost ceiling will never trigger." >&2
fi

resolve_runtime_primitives() {
  if [[ "$CONTAINER" == "auto" ]]; then
    CONTAINER_EXPLICIT=0
  fi
  if [[ "$CONTAINER_EXPLICIT" -eq 0 ]]; then
    if command -v podman >/dev/null 2>&1; then
      CONTAINER="podman"
    elif command -v docker >/dev/null 2>&1; then
      CONTAINER="docker"
    else
      CONTAINER="unavailable"
    fi
  elif ! command -v "$CONTAINER" >/dev/null 2>&1; then
    echo "Requested container engine '$CONTAINER' is unavailable on PATH." >&2
    exit 2
  fi

  if [[ "$AGENT_TIMEOUT" -ne 0 ]]; then
    if command -v timeout >/dev/null 2>&1 && timeout --help 2>&1 | grep -q -- '--kill-after'; then
      TIMEOUT_BIN="$(command -v timeout)"
    elif command -v gtimeout >/dev/null 2>&1 && gtimeout --help 2>&1 | grep -q -- '--kill-after'; then
      TIMEOUT_BIN="$(command -v gtimeout)"
    else
      echo "⚠ --agent-timeout-seconds is requested, but GNU timeout/gtimeout is unavailable; using cooperative fallback." >&2
    fi
  fi
}
resolve_runtime_primitives

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
if [[ -n "$PLAN_FILE" ]]; then
  if [[ ! -f "$PLAN_FILE" && "$MODE" != "plan" ]]; then
    echo "plan file not found: $PLAN_FILE" >&2
    exit 2
  fi
  PLAN="$PLAN_FILE"
elif [[ -f ".wgm/IMPLEMENTATION_PLAN.md" ]]; then
  PLAN=".wgm/IMPLEMENTATION_PLAN.md"
elif [[ -f "IMPLEMENTATION_PLAN.md" ]]; then
  PLAN="IMPLEMENTATION_PLAN.md"
fi
STOP_FILE=".wgm/STOP"; [[ -d .wgm ]] || STOP_FILE="STOP"

# Telemetry is on by default so every iteration is timed without the operator opting in; wgm's own
# scratch dir keeps the ledger out of the project tree. `--metrics off` disables it explicitly.
[[ -n "$METRICS_FILE" ]] || METRICS_FILE=".wgm/metrics.tsv"
[[ "$METRICS_FILE" == "off" ]] && METRICS_FILE=""

if [[ "$DRY_RUN" -eq 0 ]] && [[ "$MODE" == "build" || "$MODE" == "review" || "$MODE" == "preflight" ]] && [[ -z "$PLAN" ]]; then
  echo "Refusing to run '$MODE': no IMPLEMENTATION_PLAN.md found (root or .wgm/)." >&2
  echo "Run './scripts/loop.sh plan' (or '/wgm plan') first to create one." >&2
  exit 1
fi
PLAN_REF="${PLAN:-IMPLEMENTATION_PLAN.md (none yet)}"

# ----- project gates (wgm.yml) ---------------------------------------------
# Optional named backpressure: commands executed by the host after every build iteration.
GATES=()
if [[ -z "$GATES_FILE" ]]; then
  if [[ -f "wgm.yml" ]]; then GATES_FILE="wgm.yml"
  elif [[ -f ".wgm/gates.yml" ]]; then GATES_FILE=".wgm/gates.yml"; fi
fi
if [[ -n "$GATES_FILE" ]]; then
  [[ -f "$GATES_FILE" ]] || { echo "gates file not found: $GATES_FILE" >&2; exit 2; }
  [[ -r "$GATES_FILE" ]] || { echo "gates file is unreadable: $GATES_FILE" >&2; exit 2; }
  _gates_header="$(awk '/^[[:space:]]*gates[[:space:]]*:/ { print; exit }' "$GATES_FILE")"
  [[ -n "$_gates_header" ]] || { echo "gates file must declare a gates: list: $GATES_FILE" >&2; exit 2; }
  if [[ "$_gates_header" =~ gates[[:space:]]*:[[:space:]]*\[(.*)\] ]]; then
    _inline="${BASH_REMATCH[1]}"
    IFS=',' read -r -a _inline_gates <<< "$_inline"
    for _g in "${_inline_gates[@]}"; do
      _g="${_g#"${_g%%[![:space:]]*}"}"; _g="${_g%"${_g##*[![:space:]]}"}"
      _g="${_g#\"}"; _g="${_g%\"}"; _g="${_g#\'}"; _g="${_g%\'}"
      [[ -n "$_g" ]] && GATES+=("$_g")
    done
  else
    while IFS= read -r _g; do
      [[ -n "$_g" ]] && GATES+=("$_g")
    done < <(
      awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*gates[[:space:]]*:[[:space:]]*$/ { g=1; next }
        g && /^[[:space:]]*-[[:space:]]+/ { sub(/^[[:space:]]*-[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; next }
        g && /^[^[:space:]#]/ { g=0 }
      ' "$GATES_FILE"
    )
  fi
  [[ "${#GATES[@]}" -gt 0 ]] || { echo "gates file contains no executable gate commands: $GATES_FILE" >&2; exit 2; }
fi

# ----- build the per-iteration prompt --------------------------------------
case "$MODE" in
  grill)    TASK="Run ONLY the Grill phase: interview to alignment, then stop at the Grill-exit gate." ;;
  analyze)  TASK="Run ONLY the Analyze phase: explore the code and requirements and report findings/specs. Do NOT implement." ;;
  plan)     TASK="Run ONLY the Plan phase: write/refresh specs and ${PLAN_REF}. Stop at the Plan-exit gate." ;;
  review)   TASK="Run ONLY a Review: assess the current diff against the acceptance criteria in ${PLAN_REF}. Do NOT write new code." ;;
  preflight) TASK="Run ONLY Preflight: score the plan's readiness 0-100 (goal clarity, observable success criteria, scenario coverage of the demo path, acceptance->backpressure mapping, scope edges) per references/scoring.md. If readiness is below ~80, list the weakest dimensions to fix and STOP. Do NOT implement." ;;
  extract)  TASK="Run ONLY gene transfusion: survey the exemplar codebase at ${SOURCE_DIR:-<set --source DIR>} and distill reusable patterns into .wgm/genes.md (or root/.wgm/AGENTS.md under 'Codebase patterns', following artifact placement) per references/gene-transfusion.md. Extract patterns, not code; cite sources. Do NOT implement features." ;;
  build)    TASK="Read ${PLAN_REF}, pick the SINGLE most important pending task, implement it, run its validation/backpressure command, review the diff, and update the plan. Do EXACTLY ONE task, then stop. If NO pending must-have task remains, do not edit code — write the Ship/Handoff summary and create the ${STOP_FILE} sentinel file to end the loop." ;;
esac

if [[ "$MODE" == "build" ]]; then
  SCN_REF="${SCENARIOS_DIR:-scenarios/ or .wgm/scenarios/}"
  TASK="${TASK}
Holdout judging: do NOT read scenario files while implementing. In Validate, judge satisfaction (0-100) against the holdout scenarios in ${SCN_REF} and converge to overall satisfaction >= ${THRESHOLD} (deterministic checks still gate 'done')."
  [[ "$STRATIFIED" -eq 1 ]] && TASK="${TASK}
Stratified: validate scenarios by ascending tier (1->2->3); converge a tier before advancing."
  TASK="${TASK}
If a scenario needs a running service, build and run it with ${CONTAINER} (OCI) per references/validation-env.md. If the selected engine is unavailable, report that limitation instead of claiming container validation ran.
On a stall (satisfaction flat ~2 iterations, or a task failing repeatedly), run wonder/reflect and consider model escalation per references/stall-recovery.md."
  if [[ ${#GATES[@]} -gt 0 ]]; then
    _gatelist="$(printf '%s; ' "${GATES[@]}")"
    TASK="${TASK}
Project gates (from ${GATES_FILE}) — every one MUST exit 0 before a task is 'done': ${_gatelist}"
  fi
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
  echo "max_runtime=${MAX_RUNTIME}s idle_timeout=${IDLE_TIMEOUT}s no_progress_limit=${MAX_NO_PROGRESS} checkpoint_interval=${CHECKPOINT_INTERVAL} notify=${NOTIFY:+set}"
  echo "agent_timeout=${AGENT_TIMEOUT}s timeout_bin=${TIMEOUT_BIN:-cooperative}"
  echo "retries=${MAX_RETRIES} retry_base=${RETRY_BASE_DELAY}s retry_max=${RETRY_MAX_DELAY}s circuit_breaker=${MAX_CONSEC_FAIL}"
  echo "metrics=${METRICS_FILE:-off} cost_cmd=${COST_CMD:+set} max_cost=${MAX_COST}"
  echo "capability_probe=on (dry-run never executes the probe)"
  echo "gates=${GATES_FILE:-none} (${#GATES[@]})"
  echo "devcontainer=${USE_DEVCONTAINER}$([[ $USE_DEVCONTAINER -eq 1 ]] && echo ' (would re-exec this whole invocation inside scripts/devcontainer.sh — skipped for --dry-run)')"
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

# ----- optional: re-exec this whole invocation inside a disk-conscious devcontainer sandbox ------
# WGM_IN_DEVCONTAINER is set by devcontainer.sh's own `run` on every container it launches (not
# just when asked to), so this guard also prevents any accidental nested re-wrap if --devcontainer
# somehow reaches an invocation already running inside one.
if [[ "$USE_DEVCONTAINER" -eq 1 && -z "${WGM_IN_DEVCONTAINER:-}" ]]; then
  SKILL_ROOT="$(cd "$HERE/.." && pwd)"
  REEXEC_ARGV=()
  for _a in "${ORIGINAL_ARGV[@]}"; do
    [[ "$_a" == "--devcontainer" ]] || REEXEC_ARGV+=("$_a")
  done
  ENV_FLAGS=()
  [[ -n "${WGM_AGENT:-}" ]] && ENV_FLAGS+=(--env WGM_AGENT)
  [[ -n "${WGM_FRUGAL_AGENT:-}" ]] && ENV_FLAGS+=(--env WGM_FRUGAL_AGENT)
  [[ -n "${WGM_PROMPT_STDIN:-}" ]] && ENV_FLAGS+=(--env WGM_PROMPT_STDIN)
  exec "$HERE/devcontainer.sh" run --skill-dir "$SKILL_ROOT" "${ENV_FLAGS[@]}" -- \
    /opt/wgm-skill/scripts/loop.sh "${REEXEC_ARGV[@]}"
fi

# ----- run the loop ---------------------------------------------------------
run_main() {
  run_with_prompt "$ITER_PROMPT" main
}
run_frugal() {
  run_with_prompt "$ITER_PROMPT" frugal
}
report_agent_status() {
  local rc="$1"
  if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
    echo "Agent timed out after ${AGENT_TIMEOUT}s." >&2
  fi
  return "$rc"
}
run_with_prompt() {
  local prompt="$1" role="$2" rc
  local timeout_args=()
  if [[ -n "$TIMEOUT_BIN" && "$AGENT_TIMEOUT" -ne 0 ]]; then
    timeout_args=("$TIMEOUT_BIN" --signal=TERM --kill-after=5s "$AGENT_TIMEOUT")
  fi

  if [[ "$role" == "frugal" ]]; then
    if [[ ${#timeout_args[@]} -gt 0 ]]; then
      if [[ "$PROMPT_STDIN" == "1" ]]; then
        printf '%s' "$prompt" | "${timeout_args[@]}" bash -c "$FRUGAL_AGENT"
      else
        "${timeout_args[@]}" bash -c "$FRUGAL_AGENT \"\$1\"" _ "$prompt"
      fi
    elif [[ "$PROMPT_STDIN" == "1" ]]; then
      printf '%s' "$prompt" | eval "$FRUGAL_AGENT"
    else
      eval "$FRUGAL_AGENT \"\$prompt\""
    fi
  elif [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then
    if [[ "$PROMPT_STDIN" == "1" ]]; then
      printf '%s' "$prompt" | "${timeout_args[@]}" "${AGENT_ARGV[@]}"
    else
      "${timeout_args[@]}" "${AGENT_ARGV[@]}" "$prompt"
    fi
  elif [[ "$PROMPT_STDIN" == "1" ]]; then
    if [[ ${#timeout_args[@]} -gt 0 ]]; then
      printf '%s' "$prompt" | "${timeout_args[@]}" bash -c "$AGENT"
    else
      printf '%s' "$prompt" | eval "$AGENT"
    fi
  else
    if [[ ${#timeout_args[@]} -gt 0 ]]; then
      "${timeout_args[@]}" bash -c "$AGENT \"\$1\"" _ "$prompt"
    else
      eval "$AGENT \"\$prompt\""
    fi
  fi
  rc=$?
  report_agent_status "$rc"
}
# GNU date wants -d @EPOCH; BSD/macOS date wants -r EPOCH. Fall back to the raw epoch if neither works.
epoch_to_utc() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo "$1"
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

file_hash() {
  local file="$1"
  if command -v sha1sum >/dev/null 2>&1; then sha1sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum "$file" | awk '{print $1}'
  else cksum "$file" | awk '{print $1}'; fi
}

file_hash_or_none() {
  local file="$1"
  if [[ -f "$file" ]]; then file_hash "$file"; else printf 'none'; fi
}

codebase_patterns_content() {
  local file content
  for file in AGENTS.md .wgm/AGENTS.md; do
    [[ -f "$file" ]] || continue
    content="$(awk '
      /^##+[[:space:]]+Codebase patterns[[:space:]]*$/ { capture=1 }
      capture && /^##+[[:space:]]+/ && $0 !~ /Codebase patterns/ && NR > 1 { exit }
      capture { print }
    ' "$file")"
    [[ -n "${content//[[:space:]]/}" ]] || continue
    printf '%s\n%s\n' "$file" "$content"
  done
}

meaningful_file() {
  [[ -f "$1" ]] && grep -q '[^[:space:]]' "$1"
}

notify() {  # $1 = lifecycle event; best-effort, its failure never breaks the loop
  [[ -n "$NOTIFY" ]] || return 0
  WGM_EVENT="$1" WGM_ITER="${ITER:-0}" bash -c "$NOTIFY" || true
}

record_metrics() {  # $1 = result (ok|fail|stall); best-effort, never breaks the loop
  local dur changed cost ts ts_start parent
  dur=$(( $(date +%s) - ITER_START ))
  if [[ "$(plan_hash)" != "$HASH_BEFORE" ]]; then changed=1; else changed=0; fi
  cost=""
  if [[ -n "$COST_CMD" ]]; then
    cost="$(WGM_EVENT=iteration WGM_ITER="$ITER" bash -c "$COST_CMD" 2>/dev/null || true)"
    cost="${cost//$'\t'/ }"; cost="${cost//$'\n'/ }"
    # Accumulate toward --max-cost independent of --metrics; a non-numeric cost figure contributes
    # nothing (best-effort, same contract as the rest of --cost-cmd's failure handling).
    if [[ "$cost" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      CUM_COST="$(awk -v a="$CUM_COST" -v b="$cost" 'BEGIN{print a+b}')"
    fi
  fi
  [[ -n "$METRICS_FILE" ]] || return 0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ts_start="$(epoch_to_utc "$ITER_START")"
  parent="${WGM_PARENT_TASK:-}"
  parent="${parent//$'\t'/ }"; parent="${parent//$'\n'/ }"
  mkdir -p "$(dirname "$METRICS_FILE")" 2>/dev/null || true
  [[ -f "$METRICS_FILE" ]] || printf 'start_timestamp\tend_timestamp\titer\tmode\tagent\tduration_s\tplan_changed\tresult\tcost\tparent\n' > "$METRICS_FILE"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts_start" "$ts" "$ITER" "$MODE" "$ACTIVE" "$dur" "$changed" "$1" "$cost" "${parent:-none}" >> "$METRICS_FILE"
}

# Model escalation engages only when BOTH a frugal and a main agent are available.
HAVE_MAIN=0
[[ ${#AGENT_ARGV[@]} -gt 0 || -n "$AGENT" ]] && HAVE_MAIN=1
ESC_ENABLED=0
[[ -n "$FRUGAL_AGENT" && "$HAVE_MAIN" -eq 1 ]] && ESC_ENABLED=1
if [[ -n "$FRUGAL_AGENT" ]]; then ACTIVE="frugal"; else ACTIVE="main"; fi
run_current() { if [[ "$ACTIVE" == "frugal" ]]; then run_frugal; else run_main; fi; }

# A successful agent process is not evidence that it can mutate the target tree. Probe the exact
# command selected for the first iteration with a unique disposable file before paying for a build.
PROBE_FILE=""
probe_capability() {
  [[ "$MODE" == "build" || "$MODE" == "plan" ]] || return 0

  mkdir -p .wgm
  PROBE_FILE="$(pwd)/.wgm/.loop-write-probe-${$}-${RANDOM}"
  local probe_content="wgm-capability-probe" probe_plan_hash probe_rc
  rm -f "$PROBE_FILE"
  probe_plan_hash="$(plan_hash)"
  echo "Capability probe: asking ${ACTIVE} agent to create a disposable write marker."
  export WGM_CAPABILITY_PROBE_FILE="$PROBE_FILE"
  export WGM_CAPABILITY_PROBE_CONTENT="$probe_content"
  set +e
  run_with_prompt "Capability probe only. Create the file at ${PROBE_FILE} with exactly ${probe_content}, then stop. Do not edit any other path, run tests, or commit." "$ACTIVE"
  probe_rc=$?
  set -e
  unset WGM_CAPABILITY_PROBE_FILE WGM_CAPABILITY_PROBE_CONTENT

  if [[ "$probe_rc" -ne 0 || ! -f "$PROBE_FILE" || "$(cat "$PROBE_FILE" 2>/dev/null || true)" != "$probe_content" ]]; then
    rm -f "$PROBE_FILE"
    echo "Capability probe failed: the ${ACTIVE} agent exited ${probe_rc} without creating the required marker." >&2
    echo "Grant the agent write access or use a full-shell invocation, then rerun the lifecycle." >&2
    notify error
    return 1
  fi
  rm -f "$PROBE_FILE"
  if [[ "$(plan_hash)" != "$probe_plan_hash" ]]; then
    echo "Capability probe failed: the agent changed the plan during the probe." >&2
    notify error
    return 1
  fi
  echo "Capability probe: passed."
}

git_status_paths() {
  git status --porcelain=v1 | while IFS= read -r status_line; do
    path="${status_line:3}"
    if [[ "${status_line:0:2}" == *R* || "${status_line:0:2}" == *C* ]] && [[ "$path" == *" -> "* ]]; then
      printf '%s\n' "${path%% -> *}" "${path##* -> }"
    else
      printf '%s\n' "$path"
    fi
  done | sort -u
}

COMMIT_MODE=0
if [[ "$MODE" == "build" && ( "$DO_COMMIT" -eq 1 || "$CHECKPOINT_INTERVAL" -ne 0 ) ]]; then
  COMMIT_MODE=1
fi

assert_clean_commit_baseline() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Refusing to commit: current directory is not a Git worktree." >&2
    return 1
  fi
  local dirty
  dirty="$(git_status_paths | grep -v '^\.wgm/' || true)"
  if [[ -n "$dirty" ]]; then
    echo "Refusing to commit: --commit requires a clean worktree before iteration 1." >&2
    printf 'Unowned paths already present:\n%s\n' "$dirty" >&2
    echo "Commit or move those edits, or run without --commit; the loop must own its worktree exclusively." >&2
    return 1
  fi
}

OWNERSHIP_MANIFESTS=()
stage_owned_paths() {
  local owned_tmp actual_tmp undeclared path manifest
  owned_tmp=".wgm/.loop-owned-${ITER}-$$"
  actual_tmp=".wgm/.loop-actual-${ITER}-$$"
  if [[ "${#OWNERSHIP_MANIFESTS[@]}" -eq 0 ]]; then
    echo "Refusing to commit: no iteration ownership manifest was registered." >&2
    return 1
  fi
  : > "$owned_tmp"
  for manifest in "${OWNERSHIP_MANIFESTS[@]}"; do
    if [[ ! -f "$manifest" ]]; then
      echo "Refusing to commit: iteration ownership manifest is missing: $manifest" >&2
      rm -f "$owned_tmp" "$actual_tmp"
      return 1
    fi
    while IFS= read -r path || [[ -n "$path" ]]; do
      [[ -n "${path//[[:space:]]/}" ]] || continue
      [[ "$path" == \#* ]] && continue
      case "$path" in
        "$PWD"/*) path="${path#"$PWD"/}" ;;
        ./*) path="${path#./}" ;;
      esac
      if [[ "$path" == "." || "$path" == */ || -d "$path" ]]; then
        echo "Refusing to commit: ownership manifest contains a directory or root path: $path" >&2
        rm -f "$owned_tmp" "$actual_tmp"
        return 1
      fi
      printf '%s\n' "$path" >> "$owned_tmp"
    done < "$manifest"
  done
  sort -u "$owned_tmp" -o "$owned_tmp"
  git_status_paths | grep -v '^\.wgm/' > "$actual_tmp" || true
  undeclared="$(comm -23 "$actual_tmp" "$owned_tmp" || true)"
  if [[ -n "$undeclared" ]]; then
    echo "Refusing to commit: iteration changed paths absent from its ownership manifest." >&2
    printf 'Undeclared paths:\n%s\n' "$undeclared" >&2
    echo "Stop the loop, move the unrelated edits to another worktree, then rerun." >&2
    rm -f "$owned_tmp" "$actual_tmp"
    return 1
  fi
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    git add -A -- "$path"
  done < "$owned_tmp"
  if git diff --cached --name-only | grep -v '^\.wgm/' | comm -23 - "$owned_tmp" | grep -q .; then
    echo "Refusing to commit: staged paths exceed the iteration ownership manifest." >&2
    rm -f "$owned_tmp" "$actual_tmp"
    return 1
  fi
  rm -f "$owned_tmp" "$actual_tmp"
  return 0
}

stop_requested() {
  [[ -f "$STOP_FILE" || -f "STOP" || -f ".wgm/STOP" ]]
}

verify_phase_artifact() {
  local root_after wgm_after custom_after genes_after patterns_after
  case "$MODE" in
    plan)
      if [[ -n "$PLAN_FILE" ]]; then
        custom_after="$(file_hash_or_none "$PLAN_FILE")"
        if [[ ! -f "$PLAN_FILE" ]]; then
          echo "Phase artifact missing: plan did not create ${PLAN_FILE}." >&2
        elif [[ "$custom_after" == "$PHASE_PLAN_CUSTOM_BEFORE" ]]; then
          echo "Phase artifact unchanged: plan did not update ${PLAN_FILE}." >&2
        elif ! meaningful_file "$PLAN_FILE" || ! grep -q '^#' "$PLAN_FILE"; then
          echo "Phase artifact invalid: plan did not produce a structured ${PLAN_FILE}." >&2
        else
          return 0
        fi
        return 1
      fi
      root_after="$(file_hash_or_none IMPLEMENTATION_PLAN.md)"
      wgm_after="$(file_hash_or_none .wgm/IMPLEMENTATION_PLAN.md)"
      if [[ ! -f IMPLEMENTATION_PLAN.md && ! -f .wgm/IMPLEMENTATION_PLAN.md ]]; then
        echo "Phase artifact missing: plan did not create IMPLEMENTATION_PLAN.md (root or .wgm/)." >&2
      elif [[ "$root_after" == "$PHASE_PLAN_ROOT_BEFORE" && "$wgm_after" == "$PHASE_PLAN_WGM_BEFORE" ]]; then
        echo "Phase artifact unchanged: plan did not update IMPLEMENTATION_PLAN.md." >&2
      elif { [[ -f IMPLEMENTATION_PLAN.md ]] && ! meaningful_file IMPLEMENTATION_PLAN.md; } \
        || { [[ -f .wgm/IMPLEMENTATION_PLAN.md ]] && ! meaningful_file .wgm/IMPLEMENTATION_PLAN.md; }; then
        echo "Phase artifact invalid: plan created an empty IMPLEMENTATION_PLAN.md." >&2
      else
        if { [[ "$root_after" != "$PHASE_PLAN_ROOT_BEFORE" ]] && [[ -f IMPLEMENTATION_PLAN.md ]] && grep -q '^#' IMPLEMENTATION_PLAN.md; } \
          || { [[ "$wgm_after" != "$PHASE_PLAN_WGM_BEFORE" ]] && [[ -f .wgm/IMPLEMENTATION_PLAN.md ]] && grep -q '^#' .wgm/IMPLEMENTATION_PLAN.md; }; then
          return 0
        fi
        echo "Phase artifact invalid: plan did not produce a structured plan document." >&2
      fi
      ;;
    extract)
      genes_after="$(file_hash_or_none .wgm/genes.md)"
      patterns_after="$(codebase_patterns_content)"
      if [[ ! -f .wgm/genes.md && ! -f AGENTS.md && ! -f .wgm/AGENTS.md ]]; then
        echo "Phase artifact missing: extract did not create .wgm/genes.md or a root/.wgm/AGENTS.md Codebase patterns section." >&2
      elif [[ "$genes_after" == "$PHASE_GENES_BEFORE" && "$patterns_after" == "$PHASE_AGENT_PATTERNS_BEFORE" ]]; then
        echo "Phase artifact unchanged: extract did not update its genes artifact." >&2
      elif [[ "$genes_after" != "$PHASE_GENES_BEFORE" ]] && meaningful_file .wgm/genes.md; then
        return 0
      elif [[ "$patterns_after" != "$PHASE_AGENT_PATTERNS_BEFORE" ]] \
        && [[ -n "${patterns_after//[[:space:]]/}" ]]; then
        return 0
      else
        echo "Phase artifact invalid: extract changed no meaningful genes artifact or root/.wgm/AGENTS.md Codebase patterns section." >&2
      fi
      ;;
    *)
      return 0
      ;;
  esac
  return 1
}

# Run one agent invocation, retrying a non-zero exit with exponential backoff + full jitter
# (AWS-style), capped at --retry-max-delay. Returns 0 on success, the last failure code otherwise.
run_iteration() {
  local attempt=0 rc=0 exp ceil delay
  while :; do
    run_current && return 0
    rc=$?
    [[ "$attempt" -ge "$MAX_RETRIES" ]] && return "$rc"
    attempt=$((attempt + 1))
    exp=$((attempt - 1)); [[ "$exp" -gt 30 ]] && exp=30
    ceil=$(( RETRY_BASE_DELAY * (1 << exp) ))
    [[ "$ceil" -gt "$RETRY_MAX_DELAY" ]] && ceil="$RETRY_MAX_DELAY"
    if [[ "$ceil" -le 0 ]]; then delay=0; else delay=$(( RANDOM % (ceil + 1) )); fi
    echo "⚠ agent failed (rc=${rc}) on iteration ${ITER}; retry ${attempt}/${MAX_RETRIES} after ${delay}s backoff." >&2
    notify retry
    sleep "$delay"
  done
}

run_project_gates() {
  local gate_index=0 gate
  [[ "${#GATES[@]}" -gt 0 ]] || return 0
  for gate in "${GATES[@]}"; do
    gate_index=$((gate_index + 1))
    echo "Project gate ${gate_index}/${#GATES[@]}: ${gate}"
    if ! bash -c "$gate"; then
      echo "Project gate failed (${gate_index}/${#GATES[@]}): ${gate}" >&2
      return 1
    fi
  done
  return 0
}

iteration_failure() {
  local reason="$1"
  LOOP_FAILED=1
  CONSEC_FAIL=$((CONSEC_FAIL + 1))
  record_metrics fail
  echo "$reason" >&2
  if [[ "$MODE" != "build" ]]; then
    notify error
    exit 1
  fi
  if [[ "$MAX_CONSEC_FAIL" -ne 0 && "$CONSEC_FAIL" -ge "$MAX_CONSEC_FAIL" ]]; then
    echo "Circuit breaker: ${CONSEC_FAIL} consecutive failed iteration(s); stopping." >&2
    notify error
    exit 1
  fi
}

discard_iteration_ownership() {
  local last
  [[ "$COMMIT_MODE" -eq 1 ]] || return 0
  [[ -n "${OWNERSHIP_MANIFEST:-}" ]] && rm -f "$OWNERSHIP_MANIFEST"
  if [[ "${#OWNERSHIP_MANIFESTS[@]}" -gt 0 ]]; then
    last=$(( ${#OWNERSHIP_MANIFESTS[@]} - 1 ))
    unset "OWNERSHIP_MANIFESTS[$last]"
  fi
}

run_harvest_hook() {
  local memories=".wgm/memories.md" hash marker=".wgm/.last-harvest-hash" rc
  [[ "$MODE" == "build" && "$LOOP_FAILED" -eq 0 && -x "$HERE/harvest-hive.sh" ]] || return 0
  [[ -s "$memories" ]] || return 0
  hash="$(file_hash "$memories")"
  if [[ -f "$marker" ]] && [[ "$(cat "$marker" 2>/dev/null || true)" == "$hash" ]]; then
    echo "Ship/Handoff harvest: memories unchanged; skipping duplicate harvest."
    return 0
  fi
  echo "Ship/Handoff harvest: invoking consent-gated harvest-hive hook."
  if [[ -n "$TIMEOUT_BIN" ]]; then
    set +e
    "$TIMEOUT_BIN" --signal=TERM --kill-after=5s 60 "$HERE/harvest-hive.sh" </dev/null
    rc=$?
    set -e
  else
    set +e
    "$HERE/harvest-hive.sh" </dev/null
    rc=$?
    set -e
  fi
  if [[ "$rc" -eq 0 ]]; then
    printf '%s\n' "$hash" > "$marker"
  elif [[ -n "$TIMEOUT_BIN" ]]; then
    echo "Ship/Handoff harvest hook failed or timed out; build result is unchanged." >&2
  else
    echo "Ship/Handoff harvest hook failed; build result is unchanged." >&2
  fi
}

ITER=0
COMPLETED=0
CONSEC_FAIL=0
LOOP_FAILED=0
NOPROG=0
PROG=0
START_TS=$(date +%s)
LAST_PROG_TS=$START_TS
notify start
if [[ "$DRY_RUN" -eq 0 && "$COMMIT_MODE" -eq 1 ]]; then
  assert_clean_commit_baseline || exit 1
fi
probe_capability || exit 1
while :; do
  ITER=$((ITER + 1))
  if [[ "$MAX_ITERS" -ne 0 && "$ITER" -gt "$MAX_ITERS" ]]; then
    echo "Reached max iterations ($MAX_ITERS)."; break
  fi
  if [[ "$MAX_RUNTIME" -ne 0 && $(( $(date +%s) - START_TS )) -ge "$MAX_RUNTIME" ]]; then
    echo "Reached max runtime (${MAX_RUNTIME}s)."; break
  fi
  if stop_requested; then echo "Stop sentinel found; ending."; break; fi

  echo ""
  echo "==================== wgm ${MODE} (${ACTIVE}) — iteration ${ITER} ===================="
  HASH_BEFORE="$(plan_hash)"
  ITER_START=$(date +%s)
  ITER_PROMPT="$PROMPT"
  PHASE_PLAN_ROOT_BEFORE="$(file_hash_or_none IMPLEMENTATION_PLAN.md)"
  PHASE_PLAN_WGM_BEFORE="$(file_hash_or_none .wgm/IMPLEMENTATION_PLAN.md)"
  PHASE_PLAN_CUSTOM_BEFORE="$(file_hash_or_none "$PLAN_FILE")"
  PHASE_GENES_BEFORE="$(file_hash_or_none .wgm/genes.md)"
  PHASE_AGENT_PATTERNS_BEFORE="$(codebase_patterns_content)"
  export WGM_PLAN_FILE="$PLAN_REF"
  if [[ "$COMMIT_MODE" -eq 1 ]]; then
    OWNERSHIP_MANIFEST="$(pwd)/.wgm/.loop-touched-${ITER}-$$"
    rm -f "$OWNERSHIP_MANIFEST"
    OWNERSHIP_MANIFESTS+=("$OWNERSHIP_MANIFEST")
    export WGM_OWNERSHIP_MANIFEST="$OWNERSHIP_MANIFEST"
    ITER_PROMPT="${PROMPT}
Commit ownership: before you finish, write every repository-relative file path you intentionally changed in this iteration to ${OWNERSHIP_MANIFEST}, one path per line. Do not list directories, do not list unrelated edits, and do not commit the manifest itself."
  else
    unset WGM_OWNERSHIP_MANIFEST
  fi
  if run_iteration; then
    if [[ "$MODE" == "build" ]] && ! run_project_gates; then
      discard_iteration_ownership
      iteration_failure "Project-wide gate failure after iteration ${ITER}."
      continue
    fi
    LOOP_FAILED=0
    CONSEC_FAIL=0
    COMPLETED=$((COMPLETED + 1))
  else
    discard_iteration_ownership
    iteration_failure "Agent failed iteration ${ITER} after exhausting retries (consecutive: $((CONSEC_FAIL + 1)))."
    continue
  fi

  if [[ "$MODE" == "build" ]]; then
    DO_CP=0
    [[ "$DO_COMMIT" -eq 1 ]] && DO_CP=1
    [[ "$CHECKPOINT_INTERVAL" -ne 0 && $(( ITER % CHECKPOINT_INTERVAL )) -eq 0 ]] && DO_CP=1
    if [[ "$DO_CP" -eq 1 ]]; then
      if ! stage_owned_paths; then
        record_metrics fail
        notify error
        exit 1
      fi
      if git diff --cached --quiet; then
        echo "(nothing to commit)"
      elif ! git commit -m "chore: wgm build iteration ${ITER}"; then
        record_metrics fail
        notify error
        exit 1
      fi
      OWNERSHIP_MANIFESTS=()
    fi
  fi

  # Progress proxy (build): did this iteration change the plan file? Drives idle-timeout + escalation.
  if [[ "$MODE" == "build" ]]; then
    HASH_AFTER="$(plan_hash)"
    [[ "$HASH_AFTER" != "$HASH_BEFORE" ]] && LAST_PROG_TS=$(date +%s)
    if [[ "$HASH_AFTER" == "$HASH_BEFORE" ]]; then
      NOPROG=$((NOPROG + 1))
      PROG=0
    else
      NOPROG=0
      PROG=$((PROG + 1))
    fi
    if stop_requested; then
      record_metrics ok
      echo "Stop sentinel found after iteration ${ITER}; ending."
      break
    fi
    if [[ "$MAX_NO_PROGRESS" -ne 0 && "$NOPROG" -ge "$MAX_NO_PROGRESS" ]]; then
      record_metrics stall
      echo "No progress: plan unchanged for ${NOPROG} successful build iteration(s); treating the exit-0 agent as stalled." >&2
      notify error
      exit 1
    fi
    record_metrics ok
    if [[ "$IDLE_TIMEOUT" -ne 0 && $(( $(date +%s) - LAST_PROG_TS )) -ge "$IDLE_TIMEOUT" ]]; then
      echo "Idle timeout: no plan progress for ${IDLE_TIMEOUT}s; ending."; break
    fi
    if awk -v a="$CUM_COST" -v b="$MAX_COST" 'BEGIN{exit !(b>0 && a>=b)}'; then
      echo "Reached max cost (${CUM_COST} >= ${MAX_COST})."; break
    fi
    if [[ "$ESC_ENABLED" -eq 1 ]]; then
      if [[ "$ACTIVE" == "frugal" && "$NOPROG" -ge "$ESCALATE_AFTER" ]]; then
        ACTIVE="main"; NOPROG=0; PROG=0
        echo "↑ escalating to main agent (no progress for ${ESCALATE_AFTER} iteration(s))."
      elif [[ "$ACTIVE" == "main" && "$PROG" -ge "$DOWNGRADE_AFTER" ]]; then
        ACTIVE="frugal"; NOPROG=0; PROG=0
        echo "↓ downgrading to frugal agent (${DOWNGRADE_AFTER} progressing iteration(s))."
      fi
    fi
  else
    if ! verify_phase_artifact; then
      record_metrics fail
      notify error
      exit 1
    fi
    record_metrics ok
  fi

  # Single-phase modes do one pass.
  [[ "$MODE" != "build" ]] && break
done

if [[ "$LOOP_FAILED" -ne 0 ]]; then
  notify error
  echo "wgm loop finished with failed iteration(s)." >&2
  exit 1
fi
run_harvest_hook
notify complete
echo "wgm loop finished (${COMPLETED} iteration(s))."
