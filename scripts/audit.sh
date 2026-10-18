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
#   ./scripts/audit.sh --check-report FILE
#
# Flags:
#   --check-report FILE  check a completed native report using the dispatcher's report contract;
#                        standalone, read-only, no agent or git/lock required
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
#   --allow-unguarded    run against a target that is NOT a git working tree. Off by default: with
#                        no git tree there is no read-only guard, so the dispatcher refuses rather
#                        than silently downgrading its own safety property.
#   --dry-run            print the roles, order, commands, and output paths; invoke nothing
#   -h | --help          show this help
#
# Contract (what this script guarantees, and what it refuses to fake):
#   * Exactly four persona passes — wgm-docs-junior, wgm-docs-senior, wgm-docs-principal,
#     wgm-docs-pm — each with the IDENTICAL bounded scope, each blind to the other three.
#   * wgm-docs-writer runs LAST, and only after all four persona reports exist AND satisfy the
#     report contract below.
#   * Every role is read-only, and that is CHECKED against one run baseline after every attempt —
#     covering HEAD and branch (a role that COMMITS leaves a clean tree), the stash ref and depth (a
#     role that STASHES leaves a clean tree), every tracked, untracked, and IGNORED path except
#     holdouts and this run's own lock/work directory — ignored AND untracked files by CONTENT,
#     including durable .wgm/ artifacts, so overwriting an existing .env, build
#     artifact, or not-yet-added scratch file counts — and a content hash of the staged and unstaged
#     diffs. Any change fails the run
#     TERMINALLY — no retry, no re-baseline, nothing reverted — and the exact delta is printed.
#     The message says the repository changed DURING a role and that the origin is unknown; it does
#     not accuse the role, because a concurrent editor, watcher, or build in the same checkout
#     produces the same delta. A change made and then reverted exactly within one turn is not
#     detectable by a before/after comparison.
#   * A role that exits non-zero, times out, produces nothing, or produces something that does not
#     satisfy its report contract fails the run, blocks the writer, and exits non-zero with the
#     reason on stderr. No success-shaped report is ever created from a failed run.
#   * The holdout scenarios (scenarios/, .wgm/scenarios/) are never read, named, or modified here —
#     they belong to wgm-validator alone.
#   * One audit at a time per working tree: an atomic .wgm/audit.lock (mkdir) is taken before any
#     role runs, and each run still gets its own unique working directory underneath it.
#
# Report contract (the host decides which half of the DELIVERY it can satisfy; the CONTENT is not
# negotiable):
#   $WGM_AUDIT_REPORT_FILE is exported to a role-specific path. Write the report there if the agent
#   can write files; otherwise print it to STDOUT and this script captures it. Either delivery is
#   accepted — and then the content is checked against what the prompt demanded, because an agent
#   that exits 0 after printing a banner or an error message is exactly the failure a bare
#   "is it non-empty?" check cannot see:
#     * a PERSONA report needs a `### <role>` heading AND the four-column finding-table header
#       `| Doc | Observation | Severity | Recommended action |`;
#     * the WRITER's report needs four persona sections, a `Consolidated report` section, and
#       `Agent actions`, `Operator actions`, `Rejected findings`, and `Dissent` sections. Use the
#       template's display names or the persona role ids. Every section needs findings or an
#       explicit disposition (such as "None"); prose keywords, examples, and empty tables do not
#       satisfy the contract. Native --check-report uses this same structural check.
#   Anything looser lets a banner become the paper trail.
#
# Exit 0 = a consolidated report was produced, or --check-report found valid structure.
#          Neither means the qualitative verdict is GREEN.
# Exit 1 = a role failed, timed out, broke its report contract, repository inspection failed, or
#          the repository changed mid-run
#          (no report is written in any of those cases); or --check-report found an invalid report.
# Exit 2 = refused before any role ran: bad flag, bad slug, no agent, a non-git target without
#          --allow-unguarded, missing canonical resources, or another audit holding this tree's lock.

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
ALLOW_UNGUARDED=0
DRY_RUN=0
TIMEOUT_BIN=""

PERSONAS=(wgm-docs-junior wgm-docs-senior wgm-docs-principal wgm-docs-pm)
STATE_DELTA_LINES=40
WRITER="wgm-docs-writer"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

has_content() { [[ -f "$1" ]] && grep -q -- '[^[:space:]]' "$1" 2>/dev/null; }

# Shared by portable dispatch and native filing. Recognize actual Markdown sections, not keywords
# in a paragraph, comment, or fenced example. A header-only table is empty; an explicit "None"
# disposition is not. This checks structure, never the truth or qualitative severity of findings.
# Like persona_violation below, print the first violation, or nothing on success.
writer_violation() {  # $1 = file
  local f="$1"
  # Keep a relative filename like "-report.md" or "name=value.md" from becoming an awk argument.
  [[ "$f" == /* ]] || f="./$f"
  if [[ ! -f "$f" || ! -r "$f" ]]; then echo "missing or unreadable report: $f"; return; fi
  if ! has_content "$f"; then echo "empty report: $f"; return; fi
  awk '
    function section(title) {
      if (title ~ /^(junior developer|wgm-docs-junior)([[:space:]]|$)/) return 1
      if (title ~ /^(senior developer|wgm-docs-senior)([[:space:]]|$)/) return 2
      if (title ~ /^(principal developer|wgm-docs-principal)([[:space:]]|$)/) return 3
      if (title ~ /^(project manager|wgm-docs-pm)([[:space:]]|$)/) return 4
      if (title ~ /^consolidated report([[:space:]]|$)/) return 5
      if (title ~ /^agent actions?([[:space:]]|$)/) return 6
      if (title ~ /^operator actions?([[:space:]]|$)/) return 7
      if (title ~ /^rejected findings([[:space:]]|$)/) return 8
      if (title ~ /^dissent([[:space:]]|$)/) return 9
      return 0
    }
    function mask_escapes(row) {
      # Keep an escaped-only cell occupied: deleting it exposes an interior pipe as a border.
      gsub(/\\./, ".", row)
      return row
    }
    function pipe_row(row) {
      return index(mask_escapes(row), "|") > 0
    }
    function table_columns(row, cells) {
      row=mask_escapes(row)
      sub(/^[[:space:]]*\|/, "", row)
      sub(/\|[[:space:]]*$/, "", row)
      return split(row, cells, /\|/)
    }
    function table_delimiter(row) {
      sub(/^[[:space:]]*\|/, "", row)
      sub(/\|[[:space:]]*$/, "", row)
      return row ~ /^[[:space:]]*:?-+:?[[:space:]]*(\|[[:space:]]*:?-+:?[[:space:]]*)*$/
    }
    function record_content(text) {
      # Ignore blank/separator lines and the templates quoted instructions.
      if (text !~ /[[:alnum:]]/ || text ~ /^[[:space:]]*>/) return
      if (active) content[active]=1
      if (consolidating) content[5]=1
    }
    BEGIN {
      names[1]="Junior developer (wgm-docs-junior)"
      names[2]="Senior developer (wgm-docs-senior)"
      names[3]="Principal developer (wgm-docs-principal)"
      names[4]="Project manager (wgm-docs-pm)"
      names[5]="Consolidated report"
      names[6]="Agent actions"; names[7]="Operator actions"
      names[8]="Rejected findings"; names[9]="Dissent"
    }
    {
      line=$0; sub(/\r$/, "", line)
      trimmed=line; sub(/^[[:space:]]*/, "", trimmed)
      if (fence != "") {
        match(trimmed, /^(`+|~+)/)
        if (substr(trimmed, 1, 1) == fence && RLENGTH >= fence_length &&
            substr(trimmed, RLENGTH+1) ~ /^[[:space:]]*$/) fence=""
        next
      }
      # Mask comments without erasing cell occupancy or treating their headings as evidence.
      # A punctuation marker is non-whitespace for border detection but is not substantive text.
      visible=""
      while (comment || index(line, "<!--")) {
        if (comment) {
          end=index(line, "-->")
          if (!end) { line=""; break }
          line=substr(line, end+3); comment=0
        } else {
          start=index(line, "<!--")
          visible=visible substr(line, 1, start-1) "."
          line=substr(line, start+4); comment=1
        }
      }
      line=visible line
      # Delay a possible header until its delimiter row confirms a table, with either outer
      # pipe optional and no fixed column names. Otherwise preserve it as ordinary prose.
      if (pending != "") {
        if (table_delimiter(line) && table_columns(line) == table_columns(pending)) {
          pending=""; table=1; next
        }
        record_content(pending); pending=""
      }
      trimmed=line; sub(/^[[:space:]]*/, "", trimmed)
      if (match(trimmed, /^(```+|~~~+)/)) {
        fence=substr(trimmed, 1, 1); fence_length=RLENGTH; table=0; next
      }
      if (line ~ /^#+[[:space:]]+/) {
        match(line, /^#+/); level=RLENGTH
        if (active && level <= depth) active=0
        if (consolidating && level <= consolidation_depth) consolidating=0
        title=tolower(line); sub(/^#+[[:space:]]+/, "", title)
        sub(/[[:space:]]+#+[[:space:]]*$/, "", title)
        id=section(title)
        if (id) { seen[id]=1; active=id; depth=level }
        if (id == 5) { consolidating=1; consolidation_depth=level }
        table=0
        next
      }
      if (pipe_row(line)) {
        if (!table) { pending=line; next }
      } else table=0
      record_content(line)
    }
    END {
      record_content(pending)
      for (i=1; i<=9; i++) {
        if (!seen[i]) { printf "no \047%s\047 section heading\n", names[i]; exit }
        if (!content[i]) { printf "empty \047%s\047 section — add findings or an explicit disposition\n", names[i]; exit }
      }
    }
  ' "$f" || echo "could not inspect report structure: $f"
}

# Check mode must exit before any dispatch setup: no agent, canonical resources, git, output
# directory, or lock is needed. Keep it standalone so dispatch flags cannot imply side effects.
if [[ "${1:-}" == --check-report ]]; then
  if [[ $# -ne 2 || -z "${2:-}" ]]; then
    echo "--check-report requires exactly one FILE and no dispatch flags" >&2
    exit 2
  fi
  violation="$(writer_violation "$2")"
  if [[ -n "$violation" ]]; then
    printf 'audit report: INVALID — %s: %s\n' "$2" "$violation" >&2
    echo "  Complete the required sections and re-run --check-report before indexing the report." >&2
    exit 1
  fi
  printf 'audit report: structure valid — %s (not a qualitative verdict)\n' "$2"
  exit 0
fi

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
    --allow-unguarded) ALLOW_UNGUARDED=1; shift ;;
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

# Canonical resources belong to the skill, not the audited project. Both installers already copy
# .github/agents inside the skill tree, independently of native host adapter installation.
SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DISCIPLINE="${SKILL_ROOT}/references/docs-audit.md"
REPORT_TEMPLATE="${SKILL_ROOT}/assets/docs-audit-report.template.md"
missing=0
for resource in "${PERSONAS[@]}" "$WRITER"; do
  brief="${SKILL_ROOT}/.github/agents/${resource}.agent.md"
  if [[ ! -r "$brief" || ! -s "$brief" ]]; then
    printf 'missing or unreadable required audit resource: %s\n' "$brief" >&2
    missing=1
  fi
done
for resource in "$DISCIPLINE" "$REPORT_TEMPLATE"; do
  if [[ ! -r "$resource" || ! -s "$resource" ]]; then
    printf 'missing or unreadable required audit resource: %s\n' "$resource" >&2
    missing=1
  fi
done
if [[ "$missing" -ne 0 ]]; then
  echo "Restore the named resources or reinstall the complete wgm skill before dispatching an audit." >&2
  exit 2
fi

if [[ "$AGENT_TIMEOUT" -ne 0 ]]; then
  if command -v timeout >/dev/null 2>&1 && timeout --help 2>&1 | grep -q -- '--kill-after'; then
    TIMEOUT_BIN="$(command -v timeout)"
  elif command -v gtimeout >/dev/null 2>&1 && gtimeout --help 2>&1 | grep -q -- '--kill-after'; then
    TIMEOUT_BIN="$(command -v gtimeout)"
  else
    echo "⚠ --timeout-seconds ${AGENT_TIMEOUT} requested, but GNU timeout/gtimeout is unavailable:" >&2
    echo "  falling back to a cooperative timeout — the dispatcher cannot bound a role itself, so only" >&2
    echo "  the agent's own limits apply. Install GNU coreutils for an enforced bound." >&2
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
    OUT_DIR=".wgm/docs/audit"; PLACEMENT="existing-project default (.wgm/docs/audit — committed paper trail)"
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

Role brief: ${SKILL_ROOT}/.github/agents/${role}.agent.md
Discipline: ${DISCIPLINE}
Read these canonical skill resources and follow them exactly. Severity taxonomy: RED / AMBER / GREEN;
every finding is observation → severity → recommended action.
Resolve wgm reference/template paths from ${SKILL_ROOT}, not from the audited project.

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

Output contract (checked mechanically — a report that misses either line is REJECTED, and a bare
status banner is not a report):
Write your finding table to ${report_path} if you can write files; otherwise print it to STDOUT and
the dispatcher will capture it. \$WGM_AUDIT_REPORT_FILE and \$WGM_AUDIT_ROLE are exported for you.
1. Start with the heading:  ### ${role} — $(lens_for "$role")
2. Then the finding table, with exactly this header row:
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
    printf 'Role brief: %s/.github/agents/%s.agent.md\n' "$SKILL_ROOT" "$WRITER"
    printf 'Discipline: %s\n' "$DISCIPLINE"
    printf 'Report shape: %s\n' "$REPORT_TEMPLATE"
    printf 'Read these canonical skill resources and follow them exactly.\n'
    printf 'Resolve wgm reference/template paths from %s, not from the audited project.\n\n' "$SKILL_ROOT"
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

Output contract (checked mechanically — a report missing any of these is REJECTED and no paper
trail is filed, because a partial consolidation reads exactly like a complete one):
Write the complete report to ${report_path} if you can write files; otherwise print it to STDOUT and
the dispatcher will capture it. \$WGM_AUDIT_REPORT_FILE and \$WGM_AUDIT_ROLE are exported for you.
The report must contain:
1. all four persona finding sections, using their role ids or the template's display names;
2. a "Consolidated report" section;
3. an "Agent actions" section; 4. an "Operator actions" section;
5. a "Rejected findings" section (say so explicitly when nothing was rejected);
6. a "Dissent" section (say "Unanimous: no dissent recorded" only when the evidence supports it).
Use real Markdown headings and non-empty bodies, not keyword mentions or header-only tables.
Keep an explicit disposition such as "None" when a section has no findings. The dispatcher applies
the same structural check as "${SKILL_ROOT}/scripts/audit.sh" --check-report FILE before filing.
A structurally valid RED or AMBER report is still RED or AMBER; completion is not qualitative GREEN.
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
  timeout_note="disabled"
  if [[ "$AGENT_TIMEOUT" -ne 0 ]]; then
    timeout_note="${TIMEOUT_BIN:-cooperative fallback (unenforced)}"
  fi
  echo "timeout=${AGENT_TIMEOUT}s timeout_bin=${timeout_note} retries=${RETRIES} retry_delay=${RETRY_DELAY}s keep=${KEEP}"
  guard_note="required (git working tree)"
  if [[ "$ALLOW_UNGUARDED" -eq 1 ]]; then guard_note="waived (--allow-unguarded)"; fi
  echo "read_only_guard=${guard_note} lock=.wgm/audit.lock"
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

# ----- fail closed without a read-only guard --------------------------------
# The read-only rule is only a rule because the git tree is checked around every role. Outside a git
# working tree there is no snapshot to compare, so the guarantee silently evaporates — and a
# dispatcher that quietly downgrades its own safety property is worse than one that stops. Refuse by
# default; --allow-unguarded is the explicit, noisy operator escape hatch.
GIT_GUARD=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then GIT_GUARD=1; fi
if [[ "$GIT_GUARD" -eq 0 ]]; then
  if [[ "$ALLOW_UNGUARDED" -eq 0 ]]; then
    echo "✗ refusing to audit: $(pwd) is not a git working tree." >&2
    echo "  Without one there is no read-only guard, so a role could edit the docs it is reviewing" >&2
    echo "  and nothing here would notice. Run the audit inside the project's git checkout, or pass" >&2
    echo "  --allow-unguarded to accept an UNGUARDED run explicitly." >&2
    exit 2
  fi
  echo "⚠ --allow-unguarded: no git working tree, so the read-only guard is OFF for this run." >&2
  echo "  A role that edits files will not be detected. Treat the resulting report accordingly." >&2
fi

# ----- one audit at a time, per working tree --------------------------------
# Two audits sharing a tree interleave their read-only guards: each sees the other's (perfectly
# legitimate) writes as a mutation, and both can file a report for the same moment. `mkdir` is the
# portable atomic test-and-set, so the loser is refused before any role runs — and a refusal is
# never retried, because waiting on a lock is the operator's decision, not the dispatcher's.
#
# The lock and the scratch dir hang off the WORKTREE ROOT, not $(pwd). Two audits launched from two
# different subdirectories of the same checkout are two audits of the same tree: keyed on $(pwd)
# they would take two different locks, serialize on nothing, and then each read the other's writes
# as a repository mutation. Anchoring on `git rev-parse --show-toplevel` makes "one audit per tree"
# actually mean the tree. Outside a git checkout (--allow-unguarded) there is no root to ask for, so
# $(pwd) is the only available anchor and the lock is per-directory.
if [[ "$GIT_GUARD" -eq 1 ]]; then
  REPO_ROOT="$(git rev-parse --show-toplevel)"
else
  REPO_ROOT="$(pwd)"
fi
LOCK_DIR="${REPO_ROOT}/.wgm/audit.lock"
LOCK_HELD=0
WORK=""
cleanup() {
  if [[ "$LOCK_HELD" -eq 1 ]]; then rm -rf "$LOCK_DIR"; fi
  if [[ -n "$WORK" ]]; then
    if [[ "$KEEP" -eq 1 ]]; then echo "Working directory kept: ${WORK}"; else rm -rf "$WORK"; fi
  fi
}
trap cleanup EXIT

mkdir -p "${REPO_ROOT}/.wgm"
if mkdir "$LOCK_DIR" 2>/dev/null; then
  LOCK_HELD=1
  printf 'pid=%s\nstarted=%s\ncwd=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(pwd)" \
    > "${LOCK_DIR}/owner" 2>/dev/null || true
else
  echo "✗ refusing to start: another docs audit already holds this tree's lock." >&2
  echo "  tree: ${REPO_ROOT}" >&2
  echo "  lock: ${LOCK_DIR}" >&2
  if [[ -f "${LOCK_DIR}/owner" ]]; then sed 's/^/    /' "${LOCK_DIR}/owner" >&2 || true; fi
  echo "  Wait for that run to finish. If no audit is running, the lock is stale — remove it with:" >&2
  echo "    rm -rf ${LOCK_DIR}" >&2
  exit 2
fi

# ----- per-run working directory -------------------------------------------
# `mktemp -d` with a unique template: even under the lock, a kept working dir from an earlier run
# must never be reused or clobbered. Only this exact directory and the held lock are dispatcher
# scratch; other .wgm/ paths may be durable deliverables, even when the project ignores them.
WORK="$(mktemp -d "${REPO_ROOT}/.wgm/audit-run-XXXXXX")"
SNAPSHOT_PATHS=(.)
INDEX_EXCLUDES=()
for excluded in scenarios .wgm/scenarios .wgm/audit.lock "${WORK#"$REPO_ROOT"/}"; do
  SNAPSHOT_PATHS+=(":(top,exclude,literal)$excluded")
  INDEX_EXCLUDES+=(":(top,literal)$excluded")
done
INSPECTION_INDEX="${WORK}/inspection.index"

# ----- read-only guard ------------------------------------------------------
# Roles report; they never edit. The prompt says so, but a prompt is not a gate. ONE baseline is
# taken here, before any role runs, and every attempt is compared against THAT — never against a
# freshly re-read tree. Re-baselining after a change would adopt it as the new "clean" state and let
# the retry pass.
#
# "Is the working tree dirty?" is NOT the question, because the three cheapest ways for an agent to
# change a repository all leave a pristine `git status`:
#   * it commits    — the edit moves into history and the tree goes clean again;
#   * it stashes    — the edit moves into refs/stash and the tree goes clean again;
#   * it writes an ignored path — the edit was never in `git status` to begin with.
# So the snapshot covers where the repository IS (HEAD, branch), where work can be HIDDEN (the stash
# ref and its depth), every path state including ignored ones, a CONTENT fingerprint of every regular
# file git knows only by name — ignored AND untracked-but-not-ignored (a path list alone sees such a
# file appear or vanish, never an overwrite of one that was already there), and a content hash of the
# staged and unstaged diffs. Pathspecs alone are NOT a no-read boundary: Git can read excluded,
# racily-clean entries during index writeback. Every snapshot copies the caller's CURRENT index
# and removes excluded entries using metadata-only plumbing BEFORE any worktree inspection.
# The shared exclusions still filter status/diff output and untracked/ignored enumeration. Durable
# .wgm/ state and kept or lookalike run directories stay protected. Git inspection is anchored at
# the worktree root, independent of the subdirectory the audit was launched from.
#
# The snapshot is a FILE of stable, sorted lines rather than a bare hash, because a hash can only
# say "something changed". A file can be diffed, and the exact delta is what turns an accusation
# into evidence — which matters because the dispatcher genuinely cannot tell a role's write from a
# concurrent editor, watcher, or build running in the same tree. It reports the change and the
# delta, and explicitly does NOT claim to know the origin.
#
# Known limitations, stated rather than papered over:
#   * a role that changes something and reverts it EXACTLY within its own turn is invisible: this
#     compares two states, and closing that needs continuous filesystem observation;
#   * the content scan runs on every attempt over BOTH the ignored and the untracked-not-ignored
#     sets, so a repository with a large vendored, build, or not-yet-added tree pays a full walk plus
#     a hash of every such file per role attempt — five roles, five passes. That is the price of
#     seeing writes git does not track by content, and it is not waived by a size cap: a cap is
#     exactly the hole an agent writing into node_modules/, .venv/, or a scratch directory would
#     fall through.
# Content fingerprints for the files git tracks only by NAME. `git ls-files --others` enumerates them
# one path at a time (`--ignored` selects the ignored set, its absence the untracked-not-ignored set),
# and each regular file contributes a cksum line.
#
# Unsafe paths are never followed: a symlink is recorded by its TARGET, and a FIFO, socket, or device
# node by name only. An ignored symlink pointing at /dev/zero or an unread FIFO would otherwise hang
# the snapshot on every attempt — a denial of service wearing a safety check's clothes. Hashing runs
# in batched xargs calls rather than one process per file.
inspection_error() {
  printf '✗ audit inspection failed: %s\n' "$*" >&2
  return 1
}

inspection_git() {
  # Command-local override only: reviewer commands keep the caller's original environment/index.
  GIT_INDEX_FILE="$INSPECTION_INDEX" git -C "$REPO_ROOT" "$@"
}

prepare_inspection_index() {
  local source excluded_list="${WORK}/excluded-index-paths"
  # Resolve in the caller's cwd, including a relative caller-supplied GIT_INDEX_FILE.
  source="$(git rev-parse --git-path index)" \
    || { inspection_error "resolving the caller index"; return 1; }
  [[ -n "$source" ]] || { inspection_error "empty caller index path"; return 1; }
  [[ "$source" == /* ]] || source="$PWD/$source"
  # Metadata-only validation distinguishes a genuinely absent index from a corrupt/unreadable one.
  # It does not refresh the real index or open tracked worktree files.
  GIT_INDEX_FILE="$source" git -C "$REPO_ROOT" ls-files -z --cached -- "${SNAPSHOT_PATHS[@]}" >/dev/null \
    || { inspection_error "reading caller index metadata: $source"; return 1; }
  if [[ -e "$source" || -L "$source" ]]; then
    cp "$source" "$INSPECTION_INDEX" \
      || { inspection_error "copying caller index: $source"; return 1; }
  else
    inspection_git read-tree --empty \
      || { inspection_error "preparing an empty inspection index"; return 1; }
  fi
  # Check enumeration BEFORE starting the writer: a failed producer must never leave an unfiltered
  # index eligible for worktree refresh. Copying preserves staging flags as well as entry stages.
  inspection_git ls-files -z --cached -- "${INDEX_EXCLUDES[@]}" > "$excluded_list" \
    || { inspection_error "enumerating excluded inspection-index entries"; return 1; }
  inspection_git update-index --force-remove -z --stdin < "$excluded_list" \
    || { inspection_error "filtering the inspection index"; return 1; }
  rm -f "$excluded_list"
}

fingerprint_others() {  # $1 = label, $2 = scratch list path, $3.. = extra git ls-files flags
  local label="$1" list="$2" names="${2}.all" f target
  shift 2
  (
    cd "$REPO_ROOT" || return 1
    inspection_git ls-files -z --others --exclude-standard "$@" -- "${SNAPSHOT_PATHS[@]}" > "$names" \
      || return 1
    : > "$list" || return 1
    while IFS= read -r -d '' f; do
      if [[ -L "$f" ]]; then
        target="$(readlink "$f")" || return 1
        printf '%s-symlink: %s -> %s\n' "$label" "$f" "$target" || return 1
      elif [[ -f "$f" ]]; then
        printf '%s\0' "$f" >> "$list" || return 1
      else
        printf '%s-special: %s\n' "$label" "$f" || return 1
      fi
    done < "$names"
    if [[ -s "$list" ]]; then
      xargs -0 cksum < "$list" | sed "s/^/${label}: /" || return 1
    fi
    rm -f "$list" "$names"
  ) | LC_ALL=C sort
}

optional_snapshot_ref() {  # $1 = normal absence value, $2.. = Git ref query
  local absent="$1" value rc=0
  shift
  value="$(git -C "$REPO_ROOT" "$@" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) printf '%s\n' "$value" ;;
    1) printf '%s\n' "$absent" ;; # unborn HEAD, detached branch, or no stash
    *) inspection_error "git $*"; return 1 ;;
  esac
}

snapshot_state() {  # $1 = file to write the snapshot into
  local out="$1" head branch stash stashdepth content
  if [[ "$GIT_GUARD" -ne 1 ]]; then
    echo "no-git-guard" > "$out"
    return 0
  fi
  prepare_inspection_index || return 1
  head="$(optional_snapshot_ref none rev-parse --quiet --verify HEAD)" || return 1
  branch="$(optional_snapshot_ref detached symbolic-ref --quiet --short HEAD)" || return 1
  stash="$(optional_snapshot_ref none rev-parse --quiet --verify refs/stash)" || return 1
  stashdepth=0
  if [[ "$stash" != none ]]; then
    stashdepth="$(git -C "$REPO_ROOT" rev-list --walk-reflogs --count refs/stash)" \
      || { inspection_error "reading stash depth"; return 1; }
  fi
  {
    printf 'head:%s\nbranch:%s\nstash:%s\nstashdepth:%s\n' "$head" "$branch" "$stash" "$stashdepth" || return 1
    # Content hashes keep an in-place edit to an already-modified file visible; the name-status lines
    # below keep the delta readable.
    content="$(inspection_git diff -- "${SNAPSHOT_PATHS[@]}" | cksum)" \
      || { inspection_error "hashing git diff (unstaged)"; return 1; }
    printf 'unstaged-content:%s\n' "$content" || return 1
    content="$(inspection_git diff --cached -- "${SNAPSHOT_PATHS[@]}" | cksum)" \
      || { inspection_error "hashing git diff (staged)"; return 1; }
    printf 'staged-content:%s\n' "$content" || return 1
    inspection_git status --porcelain --untracked-files=all --ignored -- "${SNAPSHOT_PATHS[@]}" \
      | LC_ALL=C sort | sed 's/^/status: /' \
      || { inspection_error "git status"; return 1; }
    inspection_git diff --name-status -- "${SNAPSHOT_PATHS[@]}" \
      | LC_ALL=C sort | sed 's/^/unstaged: /' \
      || { inspection_error "git diff --name-status"; return 1; }
    inspection_git diff --cached --name-status -- "${SNAPSHOT_PATHS[@]}" \
      | LC_ALL=C sort | sed 's/^/staged: /' \
      || { inspection_error "git diff --cached --name-status"; return 1; }
    # Files git is not tracking the CONTENT of — ignored ones, and untracked-but-not-ignored ones —
    # are fingerprinted by content, not merely listed. `git status` reports that such a path exists
    # (`!!` or `??`); it reports exactly the same thing after the file is overwritten, because the
    # path did not change. Overwriting an existing .env, .envrc, cached build artifact, or a
    # not-yet-added scratch file is a write like any other, and only a content fingerprint sees it.
    fingerprint_others ignored   "${out}.ignored-paths"   --ignored \
      || { inspection_error "fingerprinting ignored paths"; return 1; }
    fingerprint_others untracked "${out}.untracked-paths" \
      || { inspection_error "fingerprinting untracked paths"; return 1; }
  } > "$out"
}

abort_inspection() {
  printf '✗ docs audit aborted: repository inspection failed %s.\n' "$1" >&2
  echo "  No report filed; no retry or fallback to the caller's index." >&2
  echo "  Fix the reported inspection error and rerun the audit." >&2
  echo "audit: RED" >&2
  exit 1
}

BASELINE_FILE="${WORK}/state-baseline.txt"
snapshot_state "$BASELINE_FILE" || abort_inspection "before dispatch"

# Print a bounded, exact delta so the operator can see WHAT changed instead of being told THAT
# something did. Bounded because a role that ran a build could otherwise dump thousands of lines.
report_state_delta() {  # $1 = the attempt's snapshot file
  local after="$1" delta lines
  delta="$(diff -u "$BASELINE_FILE" "$after" 2>/dev/null | tail -n +3 || true)"
  [[ -n "$delta" ]] || return 0
  lines="$(printf '%s\n' "$delta" | wc -l | tr -d ' ')"
  echo "  exact delta (baseline → this attempt):" >&2
  printf '%s\n' "$delta" | head -n "$STATE_DELTA_LINES" | sed 's/^/    /' >&2
  if [[ "$lines" -gt "$STATE_DELTA_LINES" ]]; then
    echo "    … ${lines} delta line(s) total; showing the first ${STATE_DELTA_LINES}." >&2
    echo "    full snapshots: ${BASELINE_FILE} and ${after} (re-run with --keep to retain them)" >&2
  fi
}

# ----- invoke ---------------------------------------------------------------
RUNNER=()
if [[ -n "$TIMEOUT_BIN" && "$AGENT_TIMEOUT" -ne 0 ]]; then
  RUNNER=("$TIMEOUT_BIN" --signal=TERM --kill-after=5s "$AGENT_TIMEOUT")
fi

# Failures are captured with `|| rc=$?` rather than by toggling `set -e` around the call. Toggling
# is what bit this script once: a `set -e` inside the callee re-armed errexit for the CALLER too, so
# the first agent that exited non-zero killed the whole dispatcher before it could report the role's
# failure, retry it, or write its own summary.
invoke_agent() {  # $1 = prompt, $2 = stdout capture file
  local prompt="$1" capture="$2" rc=0
  if [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then
    # argv passthrough: executed directly, never through a shell, so nothing in the prompt or the
    # scope text can be interpreted as a command.
    if [[ "$PROMPT_STDIN" == "1" ]]; then
      printf '%s' "$prompt" | ${RUNNER[@]+"${RUNNER[@]}"} "${AGENT_ARGV[@]}" > "$capture" || rc=$?
    else
      ${RUNNER[@]+"${RUNNER[@]}"} "${AGENT_ARGV[@]}" "$prompt" > "$capture" || rc=$?
    fi
  else
    # $AGENT is a command line the operator explicitly trusted, so it is shell-evaluated — but the
    # prompt is handed over as a positional ("$1"), never spliced into the command string.
    if [[ "$PROMPT_STDIN" == "1" ]]; then
      printf '%s' "$prompt" | ${RUNNER[@]+"${RUNNER[@]}"} bash -c "$AGENT" > "$capture" || rc=$?
    else
      ${RUNNER[@]+"${RUNNER[@]}"} bash -c "$AGENT \"\$1\"" _ "$prompt" > "$capture" || rc=$?
    fi
  fi
  return "$rc"
}

# ----- report contracts -----------------------------------------------------
# "The process exited 0 and the file is non-empty" is not evidence of a review. An agent that prints
# `Ready.` or `I could not read that path.` satisfies it perfectly, and the audit then looks complete
# with a whole lens missing. So each artifact is checked against the same contract its prompt spelled
# out. Both functions print the FIRST violation and print nothing when the artifact is valid.
persona_violation() {  # $1 = role, $2 = file
  local role="$1" f="$2"
  if ! grep -Eq "^###[[:space:]]+${role}([[:space:]]|$)" "$f"; then
    echo "no '### ${role} — $(lens_for "$role")' heading"
    return 0
  fi
  if ! grep -Eqi '^\|[[:space:]]*doc[[:space:]]*\|[[:space:]]*observation[[:space:]]*\|[[:space:]]*severity[[:space:]]*\|[[:space:]]*recommended action[[:space:]]*\|' "$f"; then
    echo "no '| Doc | Observation | Severity | Recommended action |' table header"
    return 0
  fi
}

contract_violation() {  # $1 = role, $2 = file
  if [[ "$1" == "$WRITER" ]]; then writer_violation "$2"; else persona_violation "$1" "$2"; fi
}

FAILURES=()

# Exit status: 0 = a valid report exists at $WORK/$role.md
#              1 = transient failure, retried up to --retries times and still failing
#              2 = TERMINAL failure (tree mutation): never retried, aborts the whole audit
run_role() {
  local role="$1" prompt="$2"
  local report="${WORK}/${role}.md" capture="${WORK}/${role}.stdout"
  local attempt=0 rc=0 after violation

  while :; do
    attempt=$((attempt + 1))
    rm -f "$report" "$capture"
    echo "→ ${role} (attempt ${attempt}/$((RETRIES + 1)))"
    rc=0
    WGM_AUDIT_ROLE="$role" WGM_AUDIT_REPORT_FILE="$report" WGM_AUDIT_SCOPE="$SCOPE" \
      invoke_agent "$prompt" "$capture" || rc=$?

    # Checked FIRST, and against the run baseline: if the repository moved, the one property the
    # dispatcher exists to hold is gone, so the role's exit status no longer matters.
    after="${WORK}/state-${role}-${attempt}.txt"
    snapshot_state "$after" || abort_inspection "during ${role}"
    if ! cmp -s "$BASELINE_FILE" "$after"; then
      # Deliberately NOT "the role edited the tree": a concurrent editor, watcher, formatter, or
      # build in the same checkout produces an identical delta, and a guard that names a culprit it
      # cannot identify teaches operators to distrust it. State the fact, show the evidence, name
      # both possible origins, and stop either way — an audit whose tree moved underneath it is not
      # a trustworthy audit regardless of who moved it.
      echo "✗ repository state changed during ${role}; origin unknown (role or concurrent process)." >&2
      report_state_delta "$after"
      echo "  Audit roles are READ-ONLY — the dispatcher writes the report — but this tree is shared" >&2
      echo "  with anything else running in it. Re-run with no other writer active to tell them apart." >&2
      echo "  This is terminal: no retry and no re-baseline, because retrying against the changed" >&2
      echo "  repository would accept it as the new normal. Nothing is reverted — inspect it with" >&2
      echo "  'git status --ignored', 'git log', and 'git stash list'." >&2
      rm -f "$report"
      return 2
    fi

    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
      echo "✗ ${role}: timed out after ${AGENT_TIMEOUT}s." >&2
    elif [[ "$rc" -ne 0 ]]; then
      echo "✗ ${role}: agent exited ${rc}." >&2
    else
      # Either half of the DELIVERY contract is accepted: the file it was given, or its stdout.
      if ! has_content "$report" && has_content "$capture"; then cp "$capture" "$report"; fi
      if ! has_content "$report"; then
        echo "✗ ${role}: exited 0 but produced no report (neither \$WGM_AUDIT_REPORT_FILE nor STDOUT)." >&2
        rc=1
      else
        violation="$(contract_violation "$role" "$report")"
        if [[ -z "$violation" ]]; then
          echo "✓ ${role}: report captured and contract-valid ($(wc -l < "$report" | tr -d ' ') lines)"
          return 0
        fi
        echo "✗ ${role}: output is not a report — ${violation}." >&2
        echo "  (An exit-0 banner or error message is not a review; see --help for the contract.)" >&2
        rc=1
      fi
    fi

    # Only transient failures get here: a non-zero exit, a timeout, nothing produced, or a broken
    # contract. Mutation and lock refusal never reach this point.
    if [[ "$attempt" -gt "$RETRIES" ]]; then
      rm -f "$report"
      return 1
    fi
    echo "  retrying ${role} (${attempt}/${RETRIES} used)" >&2
    if [[ "$RETRY_DELAY" -gt 0 ]]; then sleep "$RETRY_DELAY"; fi
  done
}

abort_mutation() {  # $1 = the role whose attempt observed the change
  local role="$1"
  echo "" >&2
  echo "✗ docs audit aborted: repository state changed during ${role}; origin unknown." >&2
  if [[ "$role" == "$WRITER" ]]; then
    # The writer HAS run by this point. Saying it was not run would be a plain lie in the one message
    # an operator reads when the audit fails at the last step.
    echo "  ${WRITER} ran, but no consolidated report was written to ${OUT_DIR}: its output is" >&2
    echo "  discarded because the repository it consolidated moved underneath it." >&2
  else
    echo "  ${WRITER} was NOT run and no report was written to ${OUT_DIR}." >&2
  fi
  echo "audit: RED" >&2
  exit 1
}

echo "== wgm docs audit =="
echo "scope: ${SCOPE}"
echo "output: ${REPORT}  [${PLACEMENT}]"
if [[ "$GIT_GUARD" -eq 1 ]]; then
  echo "guard: read-only (baseline over HEAD/branch, stash, and tracked+untracked+ignored paths)"
else
  echo "guard: NONE (--allow-unguarded) — a role that edits files will not be detected"
fi

# The four personas are independent: identical scope, no shared state, and none of them is told
# where another's report lives. Order here is arbitrary and carries no meaning.
for role in "${PERSONAS[@]}"; do
  role_rc=0
  run_role "$role" "$(persona_prompt "$role" "${WORK}/${role}.md")" || role_rc=$?
  if [[ "$role_rc" -eq 2 ]]; then abort_mutation "$role"; fi
  if [[ "$role_rc" -ne 0 ]]; then FAILURES+=("$role"); fi
done

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "" >&2
  echo "✗ docs audit aborted: ${#FAILURES[@]} of ${#PERSONAS[@]} persona pass(es) failed — ${FAILURES[*]}" >&2
  echo "  ${WRITER} was NOT run: consolidating fewer than four reports would understate the audit." >&2
  echo "  No report was written to ${OUT_DIR}." >&2
  echo "audit: RED" >&2
  exit 1
fi

# Belt and braces: the writer runs only when all four reports are present AND still satisfy their
# contract at writer time — the same check, re-asserted at the gate it actually guards.
for role in "${PERSONAS[@]}"; do
  if ! has_content "${WORK}/${role}.md" || [[ -n "$(contract_violation "$role" "${WORK}/${role}.md")" ]]; then
    echo "✗ docs audit aborted: ${role}'s report is missing or invalid at writer time." >&2
    echo "audit: RED" >&2
    exit 1
  fi
done

writer_rc=0
run_role "$WRITER" "$(writer_prompt "${WORK}/${WRITER}.md")" || writer_rc=$?
if [[ "$writer_rc" -eq 2 ]]; then abort_mutation "$WRITER"; fi
if [[ "$writer_rc" -ne 0 ]]; then
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
echo "audit: COMPLETE — report produced; see the report for the qualitative verdict."
