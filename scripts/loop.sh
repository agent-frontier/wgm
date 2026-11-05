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
#   --max-runtime-seconds N  elapsed-runtime limit checked between iterations; active work can
#                           overrun it; no global deadline; 0 = unlimited (default: 0)
#   --idle-timeout N     stop if the plan makes no progress for N seconds; 0 = disabled (default: 0)
#   --max-no-progress-iterations N
#                        fail a build after N successful iterations leave the plan unchanged;
#                        0 = disabled (default: 3)
#   --checkpoint-interval N  commit every N build iterations; 0 = off (default: 0)
#   --notify "CMD"       run CMD (shell) on lifecycle events with $WGM_EVENT (start|retry|error|complete)
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
#                        agent, duration_s, plan_changed, result, cost, parent, sandbox) to FILE. Telemetry is
#                        ON by default at .wgm/metrics.tsv; pass `--metrics off` to disable it.
#                        $WGM_PARENT_TASK (set by swarm.sh per lane) populates the parent column.
#   --cost-cmd "CMD"     after each iteration run CMD (shell) to print a token/cost figure for the
#                        `cost` column; best-effort, its failure never breaks the loop (default: none)
#   --max-cost N         stop the build loop once cumulative cost (summed from --cost-cmd's output,
#                        whatever unit it emits) reaches N; 0 = unlimited (default: 0). Requires
#                        --cost-cmd to have anything to sum — warns at startup if set without it.
#   --devcontainer       FORCE the sandbox (a working Podman/Docker engine is required). The sandbox is
#                        ON BY DEFAULT: every agent invocation, gate/validation command and operator
#                        shell command (--notify, --cost-cmd) runs in a devcontainer
#                        (scripts/devcontainer.sh run --same-path) mounting only this project, its git
#                        directory (hooks/config read-only) and the approved agent credential copies;
#                        loop.sh itself, git bookkeeping and telemetry stay on the host. The decision
#                        comes from `scripts/sandbox.sh preflight` (see docs/reference/cli-loop.md).
#   --no-devcontainer    opt OUT: run unsandboxed on the host (labelled `sandbox: OFF` in the log and
#                        the metrics `sandbox` column). Also WGM_DEVCONTAINER=0.
#   --devcontainer-image TAG
#                        image for the sandbox (else WGM_DEVCONTAINER_IMAGE, the record, the shared base)
#   --devcontainer-mount HOST[:CONTAINER]
#                        repeatable EXTRA read-only mount (regular files/dirs only; policy-checked)
#   --dry-run            print the prompt and the command that WOULD run; invoke nothing
#   --commit             commit each build iteration; takes exclusive ownership of the worktree
#   -h | --help          show this help
#
# Safety:
#   * Sandbox on (default): the agent cannot touch anything outside this project, its git directory
#     and its own credential copies. It CAN change this repository's content and history (commits
#     need the git store) — see docs/reference/cli-loop.md for the residual risk.
#   * The host commits only with --commit or --checkpoint-interval and never pushes. The agent may
#     still edit files or run commands — use a workspace you trust it in.
#   * Every non-dry-run build or plan probes agent write capability before iteration 1.
#   * build/review modes refuse to run without an IMPLEMENTATION_PLAN.md (root or .wgm/).
#   * Stop anytime with Ctrl+C, or create a .wgm/STOP (or ./STOP) sentinel to end after the
#     current iteration. In build mode the agent is told to create that sentinel when no
#     must-have task remains, so the loop self-terminates.

set -euo pipefail

# (bash builtins only: no external tool runs before the host environment/PATH is sanitized — see sb_bootstrap_host_env)
_h="${BASH_SOURCE[0]}"; if [[ "$_h" == */* ]]; then _h="${_h%/*}"; else _h=.; fi
HERE="$(cd "$_h" && pwd)"; unset _h
# shellcheck source=scripts/swarm-parent-guard.sh
# shellcheck disable=SC1091  # resolvable when the whole scripts/ set is checked; info-only otherwise
source "$HERE/swarm-parent-guard.sh"
# shellcheck source=scripts/sandbox.sh
source "$HERE/sandbox.sh"
ORIGINAL_ARGV=("$@")
# C7 phase 1 — the FIRST host action: in-process (builtins only) environment allowlist, when this run may be
# sandboxed. The original environment is kept IN MEMORY (never exported, never on an argv) so an unsandboxed
# decision (recorded decline) can restore it; it is dropped as soon as the run is known to be sandboxed.
SB_ORIG_ENV=""
if sb_sandbox_may_be_on "$@"; then SB_ORIG_ENV="$(export -p)"; sb_env_allowlist_inproc; fi

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
CONTAINER="auto"
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
NO_DEVCONTAINER=0
DEV_IMAGE=""
AGENT_TIMEOUT=0
TIMEOUT_BIN=""
DEV_MOUNTS=()

usage() { sb_usage_from "$0"; }   # builtins only (see sb_usage_from)

# ----- parse args -----------------------------------------------------------
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --commit)  DO_COMMIT=1; shift ;;
    --devcontainer) USE_DEVCONTAINER=1; shift ;;
    --no-devcontainer) NO_DEVCONTAINER=1; shift ;;
    --devcontainer-image) [[ $# -ge 2 ]] || { echo "--devcontainer-image requires TAG" >&2; exit 2; }; DEV_IMAGE="$2"; shift 2 ;;
    --devcontainer-mount) [[ $# -ge 2 ]] || { echo "--devcontainer-mount requires HOST[:CONTAINER]" >&2; exit 2; }; DEV_MOUNTS+=("$2"); shift 2 ;;
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
if [[ -z "$COST_CMD" && "$MAX_COST" =~ [1-9] ]]; then   # (m > 0 without awk: a non-zero digit)
  echo "⚠ --max-cost is set but --cost-cmd is not; the cost ceiling will never trigger." >&2
fi

# Sandbox mode: bind the host tools FIRST (builtins only up to here). Everything below may now run externals.
if [[ "$NO_DEVCONTAINER" -eq 0 && "${WGM_DEVCONTAINER:-}" != 0 && -z "${WGM_IN_DEVCONTAINER:-}" ]]; then
  SB_EXTRA_MOUNTS=("${DEV_MOUNTS[@]}")   # (known CLI extra mounts: no private artifact may land inside them)
  sb_bootstrap_host_env "$PWD"
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

# Strip ONE pair of quotes only when they wrap the whole entry; a gate such as `sh -c 'a; b'` ends in
# a quote that belongs to the command and must reach bash -c untouched.
strip_wrapping_quotes() {
  local v="$1"
  if [[ ${#v} -ge 2 && ( ( "${v:0:1}" == '"' && "${v: -1}" == '"' ) || ( "${v:0:1}" == "'" && "${v: -1}" == "'" ) ) ]]; then
    v="${v:1:${#v}-2}"
  fi
  printf '%s' "$v"
}

# ----- project gates (wgm.yml) ---------------------------------------------
# Optional named backpressure: commands executed by the host after every build iteration.
GATES=()
# NO-FOLLOW GUARD for every host read of the gates file (it is agent-writable: a contained command — the readiness
# probe included — could swap it for a symlink to an outside readable file, which the host would then read and echo into
# the prompt). Inside the project the file must be a regular file with no symlinked component on its path (the project
# root itself included); the guard runs before AND after the single read, and the parser works on the bytes read once.
gates_refuse() {  # print the refusal, release a decision dir this (re-exec'd) process owns — no trap exists yet — and exit 2
  echo "$1" >&2
  local d="${WGM_SANDBOX_DECISION%/*}"   # (pure bash: the PATH here may not carry dirname/rm yet)
  if [[ "${WGM_SANDBOX_DECISION_OWNED:-}" == 1 && "${d##*/}" == wgm-decision.* ]]; then "${SB_BOOT_RM:-/bin/rm}" -rf -- "$d" 2>/dev/null || true; fi
  exit 2
}
gates_guard() {  # gates_guard FILE → returns 0, or exits 2 naming the offending path
  local f="$1" abs root bad
  root="$(pwd -P)"
  case "$f" in /*) abs="$f" ;; *) abs="$root/$f" ;; esac
  abs="$(sb_lexnorm "$abs")"
  if [[ "$abs" == "$root"/* ]]; then
    if ! bad="$(sb_chain_ok "$abs" "$root")"; then
      gates_refuse "gates file refused: $bad is a symlink (on the path to $f); the gates file must be a regular file inside the project. Recovery: remove that link itself, never its target."
    fi
  fi
  if [[ -e "$f" && ! -f "$f" ]]; then gates_refuse "gates file refused: $f is not a regular file"; fi
}
if [[ -z "$GATES_FILE" ]]; then
  if [[ -e "wgm.yml" || -L "wgm.yml" ]]; then GATES_FILE="wgm.yml"
  elif [[ -e ".wgm/gates.yml" || -L ".wgm/gates.yml" ]]; then GATES_FILE=".wgm/gates.yml"; fi
fi
if [[ -n "$GATES_FILE" ]]; then
  gates_guard "$GATES_FILE"
  [[ -f "$GATES_FILE" ]] || { echo "gates file not found: $GATES_FILE" >&2; exit 2; }
  [[ -r "$GATES_FILE" ]] || { echo "gates file is unreadable: $GATES_FILE" >&2; exit 2; }
  _gates_text="$(<"$GATES_FILE")"
  gates_guard "$GATES_FILE"
  _gates_header="$(awk '/^[[:space:]]*gates[[:space:]]*:/ { print; exit }' <<<"$_gates_text")"
  [[ -n "$_gates_header" ]] || { echo "gates file must declare a gates: list: $GATES_FILE" >&2; exit 2; }
  if [[ "$_gates_header" =~ gates[[:space:]]*:[[:space:]]*\[(.*)\] ]]; then
    _inline="${BASH_REMATCH[1]}"
    IFS=',' read -r -a _inline_gates <<< "$_inline"
    for _g in "${_inline_gates[@]}"; do
      _g="${_g#"${_g%%[![:space:]]*}"}"; _g="${_g%"${_g##*[![:space:]]}"}"
      _g="$(strip_wrapping_quotes "$_g")"
      [[ -n "$_g" ]] && GATES+=("$_g")
    done
  else
    while IFS= read -r _g; do
      _g="${_g#"${_g%%[![:space:]]*}"}"; _g="${_g%"${_g##*[![:space:]]}"}"
      _g="$(strip_wrapping_quotes "$_g")"
      [[ -n "$_g" ]] && GATES+=("$_g")
    done < <(
      awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*gates[[:space:]]*:[[:space:]]*$/ { g=1; next }
        g && /^[[:space:]]*-[[:space:]]+/ { sub(/^[[:space:]]*-[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; next }
        g && /^[^[:space:]#]/ { g=0 }
      ' <<<"$_gates_text"
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

# ----- sandbox (D1): decision, host-env re-exec, run state ------------------------------------------
SB_ON=0
SB_METRIC="off:unknown"

sandbox_preflight_args() {  # fills the global SB_PF array
  SB_PF=(preflight --project "$PWD")
  local m g
  if [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then SB_PF+=(--agent-exe "${AGENT_ARGV[0]}")
  elif [[ -n "$AGENT" ]]; then SB_PF+=(--agent-cmd "$AGENT"); fi
  [[ -n "$FRUGAL_AGENT" ]] && SB_PF+=(--agent-cmd "$FRUGAL_AGENT")
  [[ "$USE_DEVCONTAINER" -eq 1 ]] && SB_PF+=(--devcontainer)
  [[ "$NO_DEVCONTAINER" -eq 1 ]] && SB_PF+=(--no-devcontainer)
  [[ -n "$DEV_IMAGE" ]] && SB_PF+=(--devcontainer-image "$DEV_IMAGE")
  for m in "${DEV_MOUNTS[@]}"; do SB_PF+=(--devcontainer-mount "$m"); done
  # EVERY configured gate is smoked inside the sandbox in EVERY mode (contract step 11) — not only in build mode
  for g in "${GATES[@]}"; do SB_PF+=(--gate-cmd "$g"); done
  return 0
}

sandbox_stage() {
  local decision="" rc=0 dfile="" ddir tb snap="" w script oldpath="$PATH" pe
  sandbox_preflight_args
  # No external tool may run from a project-planted PATH entry: strip those before the first git call.
  if [[ -z "${WGM_HOST_ENV_CLEAN:-}" ]]; then
    sb_path_text_clean "$(pwd -P)"
    PATH="$SB_CLEAN_PATH"; export PATH
  fi
  if [[ -n "${WGM_SANDBOX_DECISION:-}" ]]; then
    sb_load_decision_file "$WGM_SANDBOX_DECISION"
  else
    # Handlers exist BEFORE the first launch of any kind. Preflight runs as a background child (stdin kept
    # for the interactive questions) so a signal interrupts the wait at once; the child has its own
    # registry/handlers and removes its containers, and we TERM it.
    sb_host_tmp_init
    trap 'sb_cleanup' EXIT
    trap 'sb_on_signal 130' INT
    trap 'sb_on_signal 143' TERM
    WGM_HOST_ENV_QUIET=1 "$BASH" "$HERE/sandbox.sh" "${SB_PF[@]}" > "$SB_HOSTTMP/decision.out" <&0 &
    SB_CHILD=$!
    wait "$SB_CHILD" || rc=$?
    SB_CHILD=""
    if [[ "$rc" -ne 0 ]]; then exit "$rc"; fi
    decision="$(cat "$SB_HOSTTMP/decision.out")"
    sb_parse_decision <<<"$decision"
  fi
  if [[ "$SB_MODE" == on ]]; then
    sb_apply_decision_env   # C7 phase 2: unset every credential name the decision did not approve
    SB_ORIG_ENV=""
  elif [[ -n "$SB_ORIG_ENV" ]]; then
    eval "$SB_ORIG_ENV" 2>/dev/null || true   # an unsandboxed decision keeps the operator's environment
    SB_ORIG_ENV=""
  fi
  case "$SB_MODE" in
    inside) trap 'sb_cleanup' EXIT; PATH="$oldpath"; SB_METRIC="inside"; echo "sandbox: inside (already running in a wgm devcontainer; not nesting)"; return 0 ;;
    off)    trap 'sb_cleanup' EXIT; PATH="$oldpath"; SB_METRIC="off:${SB_REASON}"; echo "sandbox: OFF — unsandboxed (${SB_REASON})"; return 0 ;;
  esac
  SB_METRIC="container:${SB_ENGINE}"
  for pe in "${SB_PATH_DROPPED[@]}"; do sb_note "host env: dropped PATH entry $pe"; done
  sb_repo_layout "$PWD"
  SB_WRITABLE=("$SB_PROJECT" "$SB_COMMON")
  if [[ -n "${WGM_SANDBOX_DECISION:-}" ]]; then
    # a SUPPLIED decision must lie outside EVERY mount (project, git dir, approved extra mounts, skill bundle)
    sb_outside_all_mounts "$WGM_SANDBOX_DECISION" || sb_die "decision file $WGM_SANDBOX_DECISION lies inside the mount $SB_INSIDE_OF — a container could read it"
  fi
  # the trusted-runner snapshot, too, must lie outside every approved mount (it IS the skill mount's source, so
  # the skill source is excluded from this one comparison)
  if [[ -n "${WGM_TRUSTED_RUNNER:-}" ]]; then
    SB_MSRC_SKIP_SKILL=1
    sb_outside_all_mounts "$WGM_TRUSTED_RUNNER" || sb_die "the trusted-runner snapshot $WGM_TRUSTED_RUNNER lies inside the approved mount $SB_INSIDE_OF — a container could rewrite or read it. Move that mount or set TMPDIR elsewhere."
    SB_MSRC_SKIP_SKILL=0
  fi
  if [[ -z "${WGM_HOST_ENV_CLEAN:-}" ]]; then
    # Host trusts nothing it inherited: re-exec under an allowlisted environment (and, when the skill
    # dir is itself writable by the agent, from a private snapshot of it).
    if [[ -z "${WGM_SANDBOX_DECISION:-}" ]]; then
      tb="$(sb_private_base)" || exit 2   # outside EVERY mount (project, git dir, extra mounts, skill)
      ddir="$(umask 077; mktemp -d "$tb/wgm-decision.XXXXXX")" || sb_die "cannot create the decision dir"
      chmod 700 "$ddir"
      dfile="$ddir/decision"
      ( umask 077; printf '%s\n' "$decision" > "$dfile" )
      export WGM_SANDBOX_DECISION="$dfile" WGM_SANDBOX_DECISION_OWNED=1
    fi
    script="$HERE/loop.sh"
    if [[ -z "${WGM_TRUSTED_RUNNER:-}" ]]; then
      snap="$(sb_trusted_snapshot "$HERE/..")"
      if [[ -n "$snap" ]]; then export WGM_TRUSTED_RUNNER="$snap" WGM_TRUSTED_RUNNER_OWNED=1; script="$snap/scripts/loop.sh"; fi
    fi
    [[ -n "$SB_HOSTTMP" ]] && { rm -rf -- "$SB_HOSTTMP"; SB_HOSTTMP=""; unset WGM_LIVE_REGISTRY; }   # exec skips traps: no leak (the re-exec'd loop makes its own registry)
    trap - EXIT
    SB_KEEP_ENV=("${SB_ENVS[@]}")   # only the APPROVED credential env names survive the host re-exec
    sb_clean_env_exec 0 "$script" "${ORIGINAL_ARGV[@]}"
  fi
  # ---- clean host environment from here on ----
  sb_export_git_env   # no-op when the re-exec already applied it (e.g. a swarm-provided environment)
  if [[ -n "${WGM_DEBUG_HOST_ENV:-}" ]]; then sb_safe_path "$WGM_DEBUG_HOST_ENV"; compgen -e > "$WGM_DEBUG_HOST_ENV"; fi
  sb_check_host_tools
  [[ "${WGM_SANDBOX_DECISION_OWNED:-}" == 1 && -n "${WGM_SANDBOX_DECISION:-}" ]] && SB_OWNED_DECISION="$WGM_SANDBOX_DECISION"
  [[ "${WGM_TRUSTED_RUNNER_OWNED:-}" == 1 && -n "${WGM_TRUSTED_RUNNER:-}" ]] && SB_SNAPSHOT="$WGM_TRUSTED_RUNNER"
  [[ -n "$SB_SNAPSHOT" ]] && echo "sandbox: running from the trusted runner snapshot $SB_SNAPSHOT (the skill dir is writable by the agent)"
  trap 'sb_cleanup' EXIT
  trap 'sb_on_signal 130' INT
  trap 'sb_on_signal 143' TERM
  SB_DIE_PROPAGATE=1; trap 'exit 2' USR1
  sb_host_tmp_init
  cd "$SB_PROJECT"
  sb_ensure_overlays
  sb_pin_capture
  sb_make_copies
  sb_assert_private_outside
  SB_ON=1
  echo "sandbox: on (${SB_ENGINE}, image ${SB_IMAGE}) — agent, gates and git commits run in a container; the host runs only loop bookkeeping"
}

# ----- trusted runner FIRST: before preflight, readiness, probe, smoke or any dry-run container work ---
SB_EXTRA_MOUNTS=("${DEV_MOUNTS[@]}")
[[ "$NO_DEVCONTAINER" -eq 1 ]] || sb_ensure_trusted_runner "$HERE/loop.sh" "${ORIGINAL_ARGV[@]}"
if [[ "${WGM_TRUSTED_RUNNER_OWNED:-}" == 1 && -n "${WGM_TRUSTED_RUNNER:-}" ]]; then
  SB_SNAPSHOT="$WGM_TRUSTED_RUNNER"; trap 'sb_cleanup' EXIT
fi

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
  echo "devcontainer=${USE_DEVCONTAINER} mounts=${#DEV_MOUNTS[@]} (the sandbox is on by default; --no-devcontainer opts out)"
  sandbox_preflight_args
  _dr_rc=0
  _dr_out="$("$BASH" "$HERE/sandbox.sh" "${SB_PF[@]}" --dry-run 2>&1)" || _dr_rc=$?
  if [[ "$_dr_rc" -eq 0 ]]; then
    echo "sandbox decision (dry run, nothing launched or written):"
    while IFS= read -r _dr_line; do echo "  $_dr_line"; done <<<"$_dr_out"
  else
    echo "sandbox: unresolved — ${_dr_out//$'\n'/ }"
  fi
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

# ----- sandbox decision (preflight once; headless lanes reuse swarm's decision file) ------------------
sandbox_stage

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

  if [[ "$SB_ON" -eq 1 ]]; then
    # Every agent invocation goes through sandbox_exec (the container); the timeout wrapper, when any,
    # supervises the engine client on the host and the container is reaped afterwards.
    SB_TIMEOUT=("${timeout_args[@]}")
    local shell_cmd="" use_argv=0
    if [[ "$role" == "frugal" ]]; then shell_cmd="$FRUGAL_AGENT"
    elif [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then use_argv=1
    else shell_cmd="$AGENT"; fi
    rc=0
    if [[ "$use_argv" -eq 1 ]]; then
      if [[ "$PROMPT_STDIN" == "1" ]]; then sandbox_exec -i "${AGENT_ARGV[@]}" < <(printf '%s' "$prompt") || rc=$?
      else sandbox_exec "${AGENT_ARGV[@]}" "$prompt" || rc=$?; fi
    elif [[ "$PROMPT_STDIN" == "1" ]]; then
      sandbox_exec -i bash -c "$shell_cmd" < <(printf '%s' "$prompt") || rc=$?
    else
      sandbox_exec bash -c "$shell_cmd \"\$1\"" _ "$prompt" || rc=$?
    fi
    SB_TIMEOUT=()
    report_agent_status "$rc"
    return
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

# Every host READ of an agent-writable path first goes through safe_path (symlinked ancestor/leaf or a
# non-regular file → exit 2 naming it, even from a $(...) subshell via the USR1 propagation).
plan_hash() {
  [[ -n "$PLAN" ]] && safe_path "$PLAN"
  if [[ -n "$PLAN" && -f "$PLAN" ]]; then
    if command -v sha1sum >/dev/null 2>&1; then sha1sum "$PLAN" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum "$PLAN" | awk '{print $1}'
    else cksum "$PLAN" | awk '{print $1}'; fi
  else
    echo "none"
  fi
}

plan_done_count() {
  local count=0
  [[ -n "$PLAN" ]] && safe_path "$PLAN"
  if [[ -n "$PLAN" && -f "$PLAN" ]]; then
    count="$(grep -ciE '(status\*\*:[[:space:]]*done|status:[[:space:]]*done|\[x\])' "$PLAN" 2>/dev/null || true)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
  fi
  printf '%s\n' "$count"
}

file_hash() {
  local file="$1"
  safe_path "$file"
  if command -v sha1sum >/dev/null 2>&1; then sha1sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum "$file" | awk '{print $1}'
  else cksum "$file" | awk '{print $1}'; fi
}

file_hash_or_none() {
  local file="$1"
  [[ -n "$file" ]] && safe_path "$file"
  if [[ -f "$file" ]]; then file_hash "$file"; else printf 'none'; fi
}

codebase_patterns_content() {
  local file content
  for file in AGENTS.md .wgm/AGENTS.md; do
    safe_path "$file"
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
  safe_path "$1"
  [[ -f "$1" ]] && grep -q '[^[:space:]]' "$1"
}

# Operator-supplied shell command strings (--notify, --cost-cmd, gates) share the agent's boundary.
shell_cmd_exec() {
  if [[ "$SB_ON" -eq 1 ]]; then sandbox_exec bash -c "$1"; else bash -c "$1"; fi
}
# git that can run repository-configured programs (hooks, filters, fsmonitor, textconv) runs in the
# container when the sandbox is on; the host only ever uses plumbing (wgm_host_git).
loop_git() {
  if [[ "$SB_ON" -eq 1 ]]; then sandbox_exec git "$@"; else git "$@"; fi
}
# Refuse agent-written symlinks before any host write/read of a file the agent could have replaced.
# Run-private 0700 scratch dir outside every mount (removed by sb_cleanup on exit).
host_tmp_init() { sb_host_tmp_init; }  # call in the main shell (a $(...) subshell would lose the variable)
host_tmp_file() {  # host_tmp_file LABEL → path of a fresh O_EXCL file inside it
  mktemp "$SB_HOSTTMP/$1.XXXXXX"
}
safe_path() { [[ "$SB_ON" -eq 1 ]] && sb_safe_path "$1"; return 0; }
# EVERY host mutation (rm, mv, write, truncate) of an agent-writable path goes through the no-follow guard first —
# on the success, failure, disposal and cleanup paths alike. safe_rm = guard, then remove (rm never follows the
# leaf, but a symlinked ANCESTOR such as `.wgm/run` would redirect it onto an outside file of the same name).
safe_rm() { local f; for f in "$@"; do safe_path "$f"; done; rm -f -- "$@"; }
ensure_run_dir() { safe_path ".wgm/run/.x"; mkdir -p .wgm/run; }

notify() {  # $1 = lifecycle event; best-effort, its failure never breaks the loop
  [[ -n "$NOTIFY" ]] || return 0
  WGM_EVENT="$1" WGM_ITER="${ITER:-0}" shell_cmd_exec "$NOTIFY" || true
}

record_metrics() {  # $1 = result (ok|fail|stall); best-effort, never breaks the loop
  local dur changed cost ts ts_start parent
  dur=$(( $(date +%s) - ITER_START ))
  if [[ "$(plan_hash)" != "$HASH_BEFORE" ]]; then changed=1; else changed=0; fi
  cost=""
  if [[ -n "$COST_CMD" ]]; then
    # via a FILE, not $(...): a signal must interrupt a slow sandboxed cost command immediately
    local cf; cf="$(host_tmp_file cost)"
    WGM_EVENT=iteration WGM_ITER="$ITER" shell_cmd_exec "$COST_CMD" > "$cf" 2>/dev/null || true
    cost="$(cat "$cf")"; rm -f "$cf"
    [[ "$SB_ON" -eq 1 ]] && sb_verify_pins
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
  safe_path "$METRICS_FILE"
  mkdir -p "$(dirname "$METRICS_FILE")" 2>/dev/null || true
  if [[ ! -f "$METRICS_FILE" ]]; then
    printf 'start_timestamp\tend_timestamp\titer\tmode\tagent\tduration_s\tplan_changed\tresult\tcost\tparent\tsandbox\n' > "$METRICS_FILE"
  elif ! head -1 "$METRICS_FILE" | grep -q $'\tsandbox$'; then
    # migrate an older ledger in place: only the header gains the column (older rows stay shorter)
    # mktemp (O_EXCL, unpredictable) next to the ledger, then an atomic rename over it (after safe_path)
    local mig; mig="$(mktemp "${METRICS_FILE}.XXXXXX")" || return 0
    { printf '%s\tsandbox\n' "$(head -1 "$METRICS_FILE")"; tail -n +2 "$METRICS_FILE"; } > "$mig" && mv -f "$mig" "$METRICS_FILE"
    rm -f "$mig"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts_start" "$ts" "$ITER" "$MODE" "$ACTIVE" "$dur" "$changed" "$1" "$cost" "${parent:-none}" "$SB_METRIC" >> "$METRICS_FILE"
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

  ensure_run_dir
  PROBE_FILE="$(pwd)/.wgm/run/.loop-write-probe-${$}-${RANDOM}"
  local probe_content="wgm-capability-probe" probe_plan_hash probe_rc
  safe_rm "$PROBE_FILE"
  probe_plan_hash="$(plan_hash)"
  echo "Capability probe: asking ${ACTIVE} agent to create a disposable write marker."
  export WGM_CAPABILITY_PROBE_FILE="$PROBE_FILE"
  export WGM_CAPABILITY_PROBE_CONTENT="$probe_content"
  set +e
  run_with_prompt "Capability probe only. Create the file at ${PROBE_FILE} with exactly ${probe_content}, then stop. Do not edit any other path, run tests, or commit." "$ACTIVE"
  probe_rc=$?
  set -e
  unset WGM_CAPABILITY_PROBE_FILE WGM_CAPABILITY_PROBE_CONTENT

  safe_path "$PROBE_FILE"
  if [[ "$probe_rc" -ne 0 || ! -f "$PROBE_FILE" || "$(cat "$PROBE_FILE" 2>/dev/null || true)" != "$probe_content" ]]; then
    safe_rm "$PROBE_FILE"
    echo "Capability probe failed: the ${ACTIVE} agent exited ${probe_rc} without creating the required marker." >&2
    echo "Grant the agent write access or use a full-shell invocation, then rerun the lifecycle." >&2
    notify error
    return 1
  fi
  safe_rm "$PROBE_FILE"
  if [[ "$(plan_hash)" != "$probe_plan_hash" ]]; then
    echo "Capability probe failed: the agent changed the plan during the probe." >&2
    notify error
    return 1
  fi
  echo "Capability probe: passed."
}

# A swarm lane's prompt is guidance, not an enforcement boundary. Recheck the assignment around
# every invocation and before committing so a detached or switched HEAD cannot be committed by the
# host runner. This does not sandbox commands the agent itself chooses to run.
assert_lane_identity() {
  [[ "${WGM_SWARM_LANE:-0}" == 1 ]] || return 0
  local top branch tip expected_top="${WGM_SWARM_ROOT:-}" expected_branch="${WGM_SWARM_BRANCH:-}"
  top="$(wgm_host_git rev-parse --show-toplevel 2>/dev/null || true)"
  branch="$(wgm_host_git symbolic-ref --short -q HEAD 2>/dev/null || true)"
  tip="$(wgm_host_git rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
  if [[ -z "$expected_top" || -z "$expected_branch" || -z "$tip" || "$top" != "$expected_top" \
        || "$branch" != "$expected_branch" || ( -n "${LANE_EXPECTED_TIP:-}" && "$tip" != "$LANE_EXPECTED_TIP" ) ]]; then
    echo "✗ lane guard: expected worktree ${expected_top:-<unset>} on ${expected_branch:-<unset>} at ${LANE_EXPECTED_TIP:-<initial>}, got ${top:-<none>} on ${branch:-<none>} at ${tip:-<none>}" >&2
    return 1
  fi
  local parent_hash
  if [[ -z "${WGM_SWARM_PARENT_ROOT:-}" || -z "${WGM_SWARM_PARENT_HASH:-}" || -z "${WGM_SWARM_PREFIX:-}" \
        || -z "${WGM_SWARM_WORKTREE_DIR:-}" || -z "${WGM_SWARM_RUNTIME_DIR:-}" \
        || -z "${WGM_SWARM_SAFE_PREFIX:-}" || -z "${WGM_SWARM_COUNT:-}" ]]; then
    echo "✗ parent guard: missing swarm parent identity." >&2
    return 1
  fi
  parent_hash="$(wgm_swarm_parent_fingerprint "$WGM_SWARM_PARENT_ROOT" "$WGM_SWARM_PREFIX" \
    "$WGM_SWARM_WORKTREE_DIR" "$WGM_SWARM_SAFE_PREFIX" "$WGM_SWARM_COUNT" "$WGM_SWARM_RUNTIME_DIR")" || {
      echo "✗ parent guard: could not inspect the invoking checkout." >&2; return 1;
    }
  if [[ "$parent_hash" != "$WGM_SWARM_PARENT_HASH" ]]; then
    echo "✗ parent guard: invoking checkout, index, or non-lane refs changed; stop and inspect before recovery." >&2
    return 1
  fi
}

git_status_paths() {
  local st_tmp
  st_tmp="$(host_tmp_file status)"
  loop_git status --porcelain=v1 > "$st_tmp" || { rm -f "$st_tmp"; return 1; }
  while IFS= read -r status_line; do
    path="${status_line:3}"
    # Only untracked .wgm runtime scratch is disposable. Tracked .wgm paths are project data and
    # must pass the same clean-baseline and ownership checks as every other tracked file.
    if [[ "${status_line:0:2}" == '??' && "$path" == .wgm/* ]]; then continue; fi
    if [[ "${status_line:0:2}" == *R* || "${status_line:0:2}" == *C* ]] && [[ "$path" == *" -> "* ]]; then
      printf '%s\n' "${path%% -> *}" "${path##* -> }"
    else
      printf '%s\n' "$path"
    fi
  done < "$st_tmp" | sort -u
  rm -f "$st_tmp"
}

COMMIT_MODE=0
if [[ "$MODE" == "build" && ( "$DO_COMMIT" -eq 1 || "$CHECKPOINT_INTERVAL" -ne 0 ) ]]; then
  COMMIT_MODE=1
fi

assert_clean_commit_baseline() {
  if ! wgm_host_git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Refusing to commit: current directory is not a Git worktree." >&2
    return 1
  fi
  local dirty df
  df="$(host_tmp_file dirty)"
  if ! git_status_paths > "$df"; then
    rm -f "$df"
    echo "Refusing to commit: could not inspect the worktree status." >&2
    return 1
  fi
  dirty="$(cat "$df")"; rm -f "$df"
  [[ "$SB_ON" -eq 1 ]] && sb_verify_pins
  if [[ -n "$dirty" ]]; then
    echo "Refusing to commit: --commit requires a clean worktree before iteration 1." >&2
    printf 'Unowned paths already present:\n%s\n' "$dirty" >&2
    echo "Commit or move those edits, or run without --commit; the loop must own its worktree exclusively." >&2
    return 1
  fi
}

OWNERSHIP_MANIFESTS=()
stage_owned_paths() {
  local owned_tmp actual_tmp staged_tmp undeclared path manifest
  ensure_run_dir
  # host-only scratch lives in a run-private dir OUTSIDE the project (never a predictable in-project name)
  owned_tmp="$(host_tmp_file owned)"
  actual_tmp="$(host_tmp_file actual)"
  staged_tmp="$(host_tmp_file staged)"
  if [[ "${#OWNERSHIP_MANIFESTS[@]}" -eq 0 ]]; then
    echo "Refusing to commit: no iteration ownership manifest was registered." >&2
    return 1
  fi
  for manifest in "${OWNERSHIP_MANIFESTS[@]}"; do
    safe_path "$manifest"
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
  if ! git_status_paths > "$actual_tmp"; then
    echo "Refusing to commit: could not inspect iteration changes." >&2
    rm -f "$owned_tmp" "$actual_tmp" "$staged_tmp"
    return 1
  fi
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
    loop_git add -A -- "$path"
  done < "$owned_tmp"
  if ! loop_git diff --cached --name-only > "$staged_tmp"; then
    echo "Refusing to commit: could not inspect staged paths." >&2
    rm -f "$owned_tmp" "$actual_tmp" "$staged_tmp"
    return 1
  fi
  if comm -23 "$staged_tmp" "$owned_tmp" | grep -q .; then
    echo "Refusing to commit: staged paths exceed the iteration ownership manifest." >&2
    rm -f "$owned_tmp" "$actual_tmp" "$staged_tmp"
    return 1
  fi
  rm -f "$owned_tmp" "$actual_tmp" "$staged_tmp"
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
    assert_lane_identity || return 1
    rc=0
    run_current || rc=$?
    assert_lane_identity || return 1
    [[ "$rc" -eq 0 ]] && return 0
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
    if ! shell_cmd_exec "$gate"; then
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
  [[ -n "${OWNERSHIP_MANIFEST:-}" ]] && safe_rm "$OWNERSHIP_MANIFEST"
  if [[ "${#OWNERSHIP_MANIFESTS[@]}" -gt 0 ]]; then
    last=$(( ${#OWNERSHIP_MANIFESTS[@]} - 1 ))
    unset "OWNERSHIP_MANIFESTS[$last]"
  fi
}

run_harvest_hook() {
  local memories=".wgm/memories.md" hash marker=".wgm/.last-harvest-hash" rc memory_hash consent_hash
  [[ "$MODE" == "build" && "$LOOP_FAILED" -eq 0 && "$LOOP_HANDOFF" -eq 1 ]] || return 0
  [[ "${WGM_SWARM_LANE:-0}" -eq 0 && -x "$HERE/harvest-hive.sh" ]] || return 0
  safe_path "$memories"; safe_path .github/wgm-hive.yml; safe_path "$marker"
  # WGM_HIVE_DENYLIST survives the env allowlist and harvest-hive.sh (not ours) tests it with -f and greps it on the HOST:
  # inside a writable root it goes through the no-follow guard (regular file, no symlinked component) BEFORE the hook
  # runs, else exit 2 naming it; outside every writable root it is used as is.
  [[ -z "${WGM_HIVE_DENYLIST:-}" ]] || safe_path "$WGM_HIVE_DENYLIST"
  [[ -s "$memories" ]] || return 0
  memory_hash="$(file_hash "$memories")"
  consent_hash="$(file_hash_or_none .github/wgm-hive.yml)"
  if command -v sha1sum >/dev/null 2>&1; then
    hash="$(printf '%s\n%s\n' "$memory_hash" "$consent_hash" | sha1sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s\n%s\n' "$memory_hash" "$consent_hash" | shasum | awk '{print $1}')"
  else
    hash="$(printf '%s\n%s\n' "$memory_hash" "$consent_hash" | cksum | awk '{print $1}')"
  fi
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
    safe_path "$marker"
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
LOOP_HANDOFF=0
NOPROG=0
PROG=0
START_TS=$(date +%s)
LAST_PROG_TS=$START_TS
host_tmp_init
notify start
LANE_EXPECTED_TIP=""
assert_lane_identity || exit 1
if [[ "${WGM_SWARM_LANE:-0}" == 1 ]]; then
  LANE_EXPECTED_TIP="$(wgm_host_git rev-parse --verify 'HEAD^{commit}')" || exit 1
fi
if [[ "$DRY_RUN" -eq 0 && "$COMMIT_MODE" -eq 1 ]]; then
  assert_clean_commit_baseline || exit 1
fi
probe_capability || exit 1
assert_lane_identity || exit 1
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
  DONE_BEFORE="$(plan_done_count)"
  ITER_START=$(date +%s)
  STOP_BEFORE=0
  stop_requested && STOP_BEFORE=1
  ITER_PROMPT="$PROMPT"
  PHASE_PLAN_ROOT_BEFORE="$(file_hash_or_none IMPLEMENTATION_PLAN.md)"
  PHASE_PLAN_WGM_BEFORE="$(file_hash_or_none .wgm/IMPLEMENTATION_PLAN.md)"
  PHASE_PLAN_CUSTOM_BEFORE="$(file_hash_or_none "$PLAN_FILE")"
  PHASE_GENES_BEFORE="$(file_hash_or_none .wgm/genes.md)"
  PHASE_AGENT_PATTERNS_BEFORE="$(codebase_patterns_content)"
  export WGM_PLAN_FILE="$PLAN_REF"
  if [[ "$COMMIT_MODE" -eq 1 ]]; then
    ensure_run_dir
    OWNERSHIP_MANIFEST="$(pwd)/.wgm/run/.loop-touched-${ITER}-$$"
    safe_rm "$OWNERSHIP_MANIFEST"
    OWNERSHIP_MANIFESTS+=("$OWNERSHIP_MANIFEST")
    export WGM_OWNERSHIP_MANIFEST="$OWNERSHIP_MANIFEST"
    ITER_PROMPT="${PROMPT}
Commit ownership: before you finish, write every repository-relative file path you intentionally changed in this iteration to ${OWNERSHIP_MANIFEST}, one path per line. Do not list directories, do not list unrelated edits, and do not commit the manifest itself."
  else
    unset WGM_OWNERSHIP_MANIFEST
  fi
  if run_iteration; then
    if [[ "$MODE" == "build" ]]; then
      DONE_AFTER="$(plan_done_count)"
      if [[ "$DONE_AFTER" -lt "$DONE_BEFORE" ]]; then
        discard_iteration_ownership
        iteration_failure "Monotonic plan-progress guard failed after iteration ${ITER}: completed task count decreased (${DONE_BEFORE} -> ${DONE_AFTER}) in ${PLAN_REF}."
        continue
      fi
    fi
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
    assert_lane_identity || { record_metrics fail; notify error; exit 1; }
    iteration_failure "Agent failed iteration ${ITER} after exhausting retries (consecutive: $((CONSEC_FAIL + 1)))."
    continue
  fi

  # Project gates can also change the checkout. Never stage or commit after identity drift.
  assert_lane_identity || { record_metrics fail; notify error; exit 1; }
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
      assert_lane_identity || { record_metrics fail; notify error; exit 1; }
      if loop_git diff --cached --quiet; then
        echo "(nothing to commit)"
      elif ! loop_git commit -m "chore: wgm build iteration ${ITER}"; then
        record_metrics fail
        notify error
        exit 1
      elif [[ "${WGM_SWARM_LANE:-0}" == 1 ]]; then
        LANE_EXPECTED_TIP="$(wgm_host_git rev-parse --verify 'HEAD^{commit}')" || exit 1
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
      [[ "$STOP_BEFORE" -eq 0 ]] && LOOP_HANDOFF=1
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
