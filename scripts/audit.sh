#!/usr/bin/env bash
#
# wgm/audit.sh — OPTIONAL host-agnostic docs-audit dispatcher for the `wgm` skill.
#
# The docs audit (references/docs-audit.md) is four INDEPENDENT persona reviews plus one
# consolidating technical writer. On a host with a native subagent mechanism the orchestrator
# dispatches those five roles itself. This script is the portable fallback for every other host: it
# drives the same five roles through ONE opaque headless agent command, invoked five times with a
# fresh prompt each time. It assumes nothing about the host beyond "you can run a command that takes
# a prompt", so it never implies a marketplace, a custom-agent registry, or a proprietary subagent
# API exists.
#
# It is an ORCHESTRATOR, not a reviewer: it writes the paper trail, and the roles only report.
#
# Provide the agent exactly the way scripts/loop.sh does:
#   * $WGM_AGENT (or --agent "CMD") — a command line evaluated by the shell. Set this only to a
#     command you trust; the prompt is passed to it as a single positional argument ("$1").
#       export WGM_AGENT='claude --dangerously-skip-permissions -p'
#       export WGM_AGENT='copilot -p --allow-all-tools'
#       export WGM_AGENT='codex exec'
#   * a `--` passthrough — everything after `--` is the agent argv, invoked WITHOUT eval (safest):
#       ./scripts/audit.sh --scope "docs/" -- claude -p
# If your agent reads the prompt from STDIN instead of an argument, set WGM_PROMPT_STDIN=1.
#
# Usage:
#   ./scripts/audit.sh [flags] [-- agent argv...]
#
# Flags:
#   --scope "TXT"        what this audit covers — the identical, bounded scope handed to all four
#                        personas and the writer (default: the project's own doc set)
#   --request "TXT"      alias for --scope
#   --agent "CMD"        agent command, shell-evaluated (overrides $WGM_AGENT)
#   --out DIR            where the consolidated report lands. Default follows the artifact rule in
#                        references/artifacts.md: `docs/audit` for a greenfield project, and
#                        `.wgm/docs/audit` for a project that already has AGENTS.md /
#                        IMPLEMENTATION_PLAN.md / specs/ (so wgm never clobbers a project's own docs).
#   --slug NAME          report slug: `<UTC-timestamp>_<slug>.md` (default: docs-audit)
#   --timeout-seconds N  bounded per-role wall clock when GNU timeout/gtimeout is available;
#                        0 = disabled (default: 0)
#   --retries N          retry a failed role up to N times (default: 0)
#   --retry-delay N      seconds to wait between retries (default: 5)
#   --keep               keep the run's working directory (the four persona reports live there)
#   --dry-run            print the roles, order, commands, and output paths; invoke nothing
#   -h | --help          show this help
#
# Contract (what this script guarantees, and what it refuses to fake):
#   * Exactly four persona passes — wgm-docs-junior, wgm-docs-senior, wgm-docs-principal,
#     wgm-docs-pm — each with the IDENTICAL bounded scope, each blind to the other three.
#   * wgm-docs-writer runs LAST, and only after all four persona reports exist and are non-empty.
#   * Every role is read-only. The dispatcher snapshots the git working tree around each role and
#     FAILS the run if a role mutated it — the roles report, this script writes.
#   * A role that exits non-zero, times out, or produces an empty report fails the run, blocks the
#     writer, and exits non-zero with the reason on stderr. No success-shaped report is ever
#     created from a failed run.
#   * The holdout scenarios (scenarios/, .wgm/scenarios/) are never read, named, or modified here —
#     they belong to wgm-validator alone.
#   * Each run gets its own unique working directory, so two concurrent audits cannot race on a
#     shared same-name temp file.
#
# Report contract per role (the host decides which half it can satisfy):
#   $WGM_AUDIT_REPORT_FILE is exported to a role-specific path. Write the report there if the agent
#   can write files; otherwise print it to STDOUT and this script captures it. Either is accepted;
#   producing neither fails the role.
#
# Exit 0 = a consolidated report was produced. Exit 1 = a role failed (no report written).
# Exit 2 = misconfiguration (bad flag, bad slug, no agent).

set -euo pipefail

# ----- defaults -------------------------------------------------------------
SCOPE=""
AGENT="${WGM_AGENT:-}"
AGENT_ARGV=()
PROMPT_STDIN="${WGM_PROMPT_STDIN:-0}"
OUT_DIR=""
SLUG="docs-audit"
AGENT_TIMEOUT=0
RETRIES=0
RETRY_DELAY=5
KEEP=0
DRY_RUN=0
TIMEOUT_BIN=""

PERSONAS=(wgm-docs-junior wgm-docs-senior wgm-docs-principal wgm-docs-pm)
WRITER="wgm-docs-writer"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

# ----- parse args -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --scope|--request) [[ $# -ge 2 ]] || { echo "$1 requires text" >&2; exit 2; }; SCOPE="$2"; shift 2 ;;
    --agent) [[ $# -ge 2 ]] || { echo "--agent requires a command" >&2; exit 2; }; AGENT="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || { echo "--out requires a dir" >&2; exit 2; }; OUT_DIR="$2"; shift 2 ;;
    --slug) [[ $# -ge 2 ]] || { echo "--slug requires a name" >&2; exit 2; }; SLUG="$2"; shift 2 ;;
    --timeout-seconds) [[ $# -ge 2 ]] || { echo "--timeout-seconds requires a number" >&2; exit 2; }; AGENT_TIMEOUT="$2"; shift 2 ;;
    --retries) [[ $# -ge 2 ]] || { echo "--retries requires a number" >&2; exit 2; }; RETRIES="$2"; shift 2 ;;
    --retry-delay) [[ $# -ge 2 ]] || { echo "--retry-delay requires a number" >&2; exit 2; }; RETRY_DELAY="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; AGENT_ARGV=("$@"); break ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *) echo "Unexpected argument: $1 (did you mean --scope \"$1\"?)" >&2; exit 2 ;;
  esac
done

for n in "$AGENT_TIMEOUT" "$RETRIES" "$RETRY_DELAY"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "expected a non-negative integer, got: $n" >&2; exit 2; }
done

# The slug becomes a filename. Refusing anything but a plain slug keeps `--slug ../../etc/passwd`
# from steering the report out of the audit directory.
[[ "$SLUG" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || {
  echo "--slug must be a lowercase slug matching ^[a-z0-9][a-z0-9._-]*$, got: $SLUG" >&2; exit 2; }

[[ -n "$SCOPE" ]] || SCOPE="the project's documentation set: docs/, README.md, references/ (or their equivalents), and any AGENTS.md"

if [[ "$AGENT_TIMEOUT" -ne 0 ]]; then
  if command -v timeout >/dev/null 2>&1 && timeout --help 2>&1 | grep -q -- '--kill-after'; then
    TIMEOUT_BIN="$(command -v timeout)"
  elif command -v gtimeout >/dev/null 2>&1 && gtimeout --help 2>&1 | grep -q -- '--kill-after'; then
    TIMEOUT_BIN="$(command -v gtimeout)"
  else
    echo "⚠ --timeout-seconds is requested, but GNU timeout/gtimeout is unavailable; roles run unbounded." >&2
  fi
fi

# ----- artifact placement ---------------------------------------------------
# Same root-vs-.wgm rule as every other wgm artifact (references/artifacts.md): a greenfield project
# gets the committed paper trail at docs/audit/; a project that already owns AGENTS.md /
# IMPLEMENTATION_PLAN.md / specs/ gets .wgm/docs/audit/ so wgm never writes into docs the project
# already maintains. Either way the report is EVIDENCE for a human — never gitignore it by default.
PLACEMENT="explicit (--out)"
if [[ -z "$OUT_DIR" ]]; then
  if [[ -f AGENTS.md || -f IMPLEMENTATION_PLAN.md || -d specs ]]; then
    OUT_DIR=".wgm/docs/audit"; PLACEMENT="existing-project default (.wgm/ — local, wgm-owned)"
  else
    OUT_DIR="docs/audit"; PLACEMENT="greenfield default (docs/audit — committed paper trail)"
  fi
fi

STAMP="$(date -u +%Y-%m-%dT%H%MZ)"
REPORT="${OUT_DIR}/${STAMP}_${SLUG}.md"

# ----- prompts --------------------------------------------------------------
lens_for() {
  case "$1" in
    wgm-docs-junior)    echo "clarity & onboarding" ;;
    wgm-docs-senior)    echo "correctness, completeness, maintainability" ;;
    wgm-docs-principal) echo "architecture, strategic fit, consistency" ;;
    wgm-docs-pm)        echo "status, risk, traceability" ;;
    *)                  echo "unknown lens" ;;
  esac
}

persona_prompt() {
  local role="$1" report_path="$2"
  cat <<EOF
wgm docs audit — independent persona pass. You are ${role} (lens: $(lens_for "$role")).

Role brief: .github/agents/${role}.agent.md — read it if it is present and follow it exactly.
Discipline: references/docs-audit.md — severity taxonomy RED / AMBER / GREEN, and every finding is
observation → severity → recommended action.

Scope (identical for all four personas — review this and nothing wider):
${SCOPE}

Rules:
* READ ONLY. Do not edit, create, or delete any file in the working tree; do not run any state-changing
  git command; do not commit. The dispatcher writes every artifact of this audit.
* You are one of four independent passes. Do not read, wait for, or reference another persona's
  report — independence is the point of running four.
* Report findings only. Do not fix anything, and do not classify Agent action vs Operator action;
  that is ${WRITER}'s job.
* Execute the published examples in scope rather than reasoning about them, against the real
  artifacts they name.

Output contract:
Write your finding table to ${report_path} if you can write files; otherwise print it to STDOUT and
the dispatcher will capture it. \$WGM_AUDIT_REPORT_FILE and \$WGM_AUDIT_ROLE are exported for you.
Start with the heading "### ${role} — $(lens_for "$role")", then one table:
| Doc | Observation | Severity | Recommended action |
Emit the table even when you found nothing; a clean pass is a claim, so state in one sentence what
you examined and why you found nothing.
EOF
}

writer_prompt() {
  local report_path="$1" role
  {
    printf 'wgm docs audit — consolidation pass. You are %s, and you run LAST: all four persona\n' "$WRITER"
    printf 'reports below already exist.\n\n'
    printf 'Role brief: .github/agents/%s.agent.md — read it if present and follow it exactly.\n' "$WRITER"
    printf 'Discipline: references/docs-audit.md ("The technical writer (consolidation)").\n'
    printf 'Report shape: assets/docs-audit-report.template.md.\n\n'
    printf 'Persona reports to consolidate (read all four):\n'
    for role in "${PERSONAS[@]}"; do printf '  * %s — %s\n' "$role" "${WORK}/${role}.md"; done
    printf '\nScope this audit covered:\n%s\n\n' "$SCOPE"
    cat <<EOF
Rules:
* Add no new opinions of your own. You normalize four reports; you do not become a fifth reviewer.
* Dedupe: one entry per underlying issue, noting which personas raised it.
* Preserve dissent explicitly in a Dissent section — never average conflicting severities or silently
  pick a winner. If all four converge, say so: "Unanimous: no dissent recorded".
* Verify before promotion: persona observations and severities are hypotheses. Check each against the
  real artifact before it reaches an action table, weighting RED/AMBER first. Record every rejected or
  already-mitigated finding in a "Rejected findings" table with the exact check run and the evidence
  that disproved it — never silently drop one.
* Classify every surviving finding strictly as **Agent action** or **Operator action** by the KIND of
  action required, never by which persona raised it.
* Structure the report using the project's own README/docs index, and flag index entries that point at
  missing files or docs indexed nowhere.
* READ ONLY on the working tree: do not edit project files or commit. The dispatcher files the report.

Output contract:
Write the complete report to ${report_path} if you can write files; otherwise print it to STDOUT and
the dispatcher will capture it. \$WGM_AUDIT_REPORT_FILE and \$WGM_AUDIT_ROLE are exported for you.
EOF
  }
}

# ----- dry run --------------------------------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  WORK="<work dir: created per run under .wgm/, unique to that run>"
  echo "== wgm docs audit (dry run) =="
  echo "scope=${SCOPE}"
  echo "out_dir=${OUT_DIR} placement=${PLACEMENT}"
  echo "report=${REPORT}"
  echo "timeout=${AGENT_TIMEOUT}s timeout_bin=${TIMEOUT_BIN:-none} retries=${RETRIES} retry_delay=${RETRY_DELAY}s keep=${KEEP}"
  if [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then echo "agent(argv)=${AGENT_ARGV[*]}"
  else echo "agent=${AGENT:-<unset: set \$WGM_AGENT, --agent, or -- argv>}"; fi
  echo "prompt_stdin=${PROMPT_STDIN}"
  echo "--- order (four independent personas, then the writer LAST) ---"
  i=0
  for role in "${PERSONAS[@]}"; do
    i=$((i + 1))
    echo "  ${i}. ${role} (persona, independent) → report ${role}.md"
  done
  echo "  5. ${WRITER} (consolidator; runs only after all four persona reports exist)"
  echo "--- would invoke (once per role) ---"
  if [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then
    if [[ "$PROMPT_STDIN" == "1" ]]; then echo "printf '%s' \"\$PROMPT\" | ${AGENT_ARGV[*]}"
    else echo "${AGENT_ARGV[*]} \"\$PROMPT\""; fi
  elif [[ "$PROMPT_STDIN" == "1" ]]; then echo "printf '%s' \"\$PROMPT\" | bash -c \"${AGENT:-<agent>}\""
  else echo "bash -c \"${AGENT:-<agent>} \\\"\\\$1\\\"\" _ \"\$PROMPT\""; fi
  echo "(dry run: nothing was invoked, no directory was created, no report was written)"
  exit 0
fi

if [[ ${#AGENT_ARGV[@]} -eq 0 && -z "$AGENT" ]]; then
  echo "No agent configured. Set \$WGM_AGENT, pass --agent \"CMD\", or append -- argv. See --help." >&2
  exit 2
fi

# ----- per-run working directory -------------------------------------------
# `mktemp -d` with a unique template: two audits started in the same second must not collide on a
# shared same-name scratch file. It lives under .wgm/ (wgm's own scratch space, gitignored) so the
# run leaves no residue in the project's tree.
mkdir -p .wgm
WORK="$(mktemp -d "$(pwd)/.wgm/audit-run-XXXXXX")"
cleanup() {
  if [[ "$KEEP" -eq 1 ]]; then
    echo "Working directory kept: ${WORK}"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# ----- read-only guard ------------------------------------------------------
# Roles report; they never edit. The prompt says so, but a prompt is not a gate — so snapshot the
# tree around every role and fail the run if one mutated it. .wgm/ is excluded because that is where
# the dispatcher's own scratch lives. Outside a git repo the guard is skipped, and says so.
GIT_GUARD=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then GIT_GUARD=1; fi

tree_snapshot() {
  [[ "$GIT_GUARD" -eq 1 ]] || { echo "no-git-guard"; return 0; }
  {
    git status --porcelain --untracked-files=all -- ':(exclude).wgm' 2>/dev/null || true
    git diff -- ':(exclude).wgm' 2>/dev/null || true
    git diff --cached -- ':(exclude).wgm' 2>/dev/null || true
  } | cksum
}

# ----- invoke ---------------------------------------------------------------
RUNNER=()
if [[ -n "$TIMEOUT_BIN" && "$AGENT_TIMEOUT" -ne 0 ]]; then
  RUNNER=("$TIMEOUT_BIN" --signal=TERM --kill-after=5s "$AGENT_TIMEOUT")
fi

invoke_agent() {  # $1 = prompt, $2 = stdout capture file
  local prompt="$1" capture="$2" rc=0
  set +e
  if [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then
    # argv passthrough: executed directly, never through a shell, so nothing in the prompt or the
    # scope text can be interpreted as a command.
    if [[ "$PROMPT_STDIN" == "1" ]]; then
      printf '%s' "$prompt" | ${RUNNER[@]+"${RUNNER[@]}"} "${AGENT_ARGV[@]}" > "$capture"
    else
      ${RUNNER[@]+"${RUNNER[@]}"} "${AGENT_ARGV[@]}" "$prompt" > "$capture"
    fi
  else
    # $AGENT is a command line the operator explicitly trusted, so it is shell-evaluated — but the
    # prompt is handed over as a positional ("$1"), never spliced into the command string.
    if [[ "$PROMPT_STDIN" == "1" ]]; then
      printf '%s' "$prompt" | ${RUNNER[@]+"${RUNNER[@]}"} bash -c "$AGENT" > "$capture"
    else
      ${RUNNER[@]+"${RUNNER[@]}"} bash -c "$AGENT \"\$1\"" _ "$prompt" > "$capture"
    fi
  fi
  rc=$?
  set -e
  return "$rc"
}

has_content() { [[ -f "$1" ]] && grep -q '[^[:space:]]' "$1" 2>/dev/null; }

FAILURES=()

run_role() {  # $1 = role, $2 = prompt; 0 = a non-empty report exists at $WORK/$role.md
  local role="$1" prompt="$2"
  local report="${WORK}/${role}.md" capture="${WORK}/${role}.stdout"
  local attempt=0 rc=0 before after

  while :; do
    attempt=$((attempt + 1))
    rm -f "$report" "$capture"
    before="$(tree_snapshot)"
    echo "→ ${role} (attempt ${attempt}/$((RETRIES + 1)))"
    set +e
    WGM_AUDIT_ROLE="$role" WGM_AUDIT_REPORT_FILE="$report" WGM_AUDIT_SCOPE="$SCOPE" \
      invoke_agent "$prompt" "$capture"
    rc=$?
    set -e
    after="$(tree_snapshot)"

    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
      echo "✗ ${role}: timed out after ${AGENT_TIMEOUT}s." >&2
    elif [[ "$rc" -ne 0 ]]; then
      echo "✗ ${role}: agent exited ${rc}." >&2
    elif [[ "$before" != "$after" ]]; then
      echo "✗ ${role}: modified the working tree. Audit roles are READ-ONLY — the dispatcher writes the report." >&2
      rc=1
    else
      # Either half of the report contract is accepted: the file it was given, or its stdout.
      if ! has_content "$report" && has_content "$capture"; then cp "$capture" "$report"; fi
      if has_content "$report"; then
        echo "✓ ${role}: report captured ($(wc -l < "$report" | tr -d ' ') lines)"
        return 0
      fi
      echo "✗ ${role}: exited 0 but produced no report (neither \$WGM_AUDIT_REPORT_FILE nor STDOUT)." >&2
      rc=1
    fi

    if [[ "$attempt" -gt "$RETRIES" ]]; then
      rm -f "$report"
      return 1
    fi
    if [[ "$RETRY_DELAY" -gt 0 ]]; then sleep "$RETRY_DELAY"; fi
  done
}

echo "== wgm docs audit =="
echo "scope: ${SCOPE}"
echo "output: ${REPORT}  [${PLACEMENT}]"
[[ "$GIT_GUARD" -eq 1 ]] || echo "note: not a git repository — the read-only guard is skipped for this run."

# The four personas are independent: identical scope, no shared state, and none of them is told
# where another's report lives. Order here is arbitrary and carries no meaning.
for role in "${PERSONAS[@]}"; do
  if ! run_role "$role" "$(persona_prompt "$role" "${WORK}/${role}.md")"; then
    FAILURES+=("$role")
  fi
done

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "" >&2
  echo "✗ docs audit aborted: ${#FAILURES[@]} of ${#PERSONAS[@]} persona pass(es) failed — ${FAILURES[*]}" >&2
  echo "  ${WRITER} was NOT run: consolidating fewer than four reports would understate the audit." >&2
  echo "  No report was written to ${OUT_DIR}." >&2
  echo "audit: RED" >&2
  exit 1
fi

# Belt and braces: the writer runs only when all four reports are physically present and non-empty.
for role in "${PERSONAS[@]}"; do
  if ! has_content "${WORK}/${role}.md"; then
    echo "✗ docs audit aborted: ${role}'s report is missing or empty at writer time." >&2
    echo "audit: RED" >&2
    exit 1
  fi
done

if ! run_role "$WRITER" "$(writer_prompt "${WORK}/${WRITER}.md")"; then
  echo "" >&2
  echo "✗ docs audit aborted: ${WRITER} failed to consolidate the four persona reports." >&2
  echo "  No report was written to ${OUT_DIR} — a failed audit must not leave a success-shaped artifact." >&2
  echo "  Re-run with --keep to inspect the persona reports." >&2
  echo "audit: RED" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
# Never overwrite an existing report: two audits in the same UTC minute each keep their evidence.
if [[ -e "$REPORT" ]]; then
  n=2
  while [[ -e "${OUT_DIR}/${STAMP}_${SLUG}-${n}.md" ]]; do n=$((n + 1)); done
  REPORT="${OUT_DIR}/${STAMP}_${SLUG}-${n}.md"
fi
cp "${WORK}/${WRITER}.md" "$REPORT"

echo ""
echo "✓ docs audit complete — 4 persona passes consolidated by ${WRITER}."
echo "  report: ${REPORT}"
echo "  next:   add a newest-first row for it in ${OUT_DIR}/README.md (date, verdict, coverage, link)."
echo "audit: GREEN"
