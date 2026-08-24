#!/usr/bin/env bash
#
# wgm/test-audit.sh — deterministic backpressure for scripts/audit.sh.
#
# scripts/audit.sh orchestrates five agent invocations whose *content* only a real reviewer can
# judge. What it must never get wrong is the ORCHESTRATION: four independent personas, a writer that
# runs last and only on four real reports, read-only roles, an honest non-zero exit on any failure,
# and no success-shaped artifact from a failed run. All of that is deterministic, so all of it is
# tested here with a fake agent — no real agent, model, network, or token is needed.
#
# The fake agent reads its role from $WGM_AUDIT_ROLE, appends that role to an order log, saves the
# prompt it was handed, and writes a stub report — so ordering, independence, and the failure paths
# become assertions instead of hopes. It deliberately never reads holdout scenarios, and one test
# proves the dispatcher does not either.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$ROOT/scripts/audit.sh"

FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wgm-audit-test-XXXXXX")"
trap 'cd /; rm -rf "$TMP"' EXIT

# The sandbox project lives in a SUBDIRECTORY, and every piece of harness instrumentation (the
# order log, the captured prompts, the fake agent itself) lives outside it. Otherwise the harness's
# own scratch files would land inside the repo and trip audit.sh's read-only guard, making the guard
# look broken when it is working exactly as designed.
mkdir -p "$TMP/repo"
cd "$TMP/repo" || exit 1
git init -q
git config user.email "wgm-test@example.com"
git config user.name "wgm test"
mkdir -p docs
printf '# readme\n' > README.md
printf '# docs\n' > docs/README.md

# A holdout scenario with a canary string. audit.sh must never read, name, or modify it: holdout
# scenarios belong to wgm-validator alone, and an audit that leaked them would contaminate the
# holdout (references/scenarios.md).
mkdir -p scenarios
printf 'id: s1\nprompt: CANARY-HOLDOUT-DO-NOT-LEAK\n' > scenarios/holdout.yaml
SCEN_SUM="$(cksum scenarios/holdout.yaml)"

git add -A && git commit -qm seed

# `scenarios/` exists now, but the default-placement rule keys off AGENTS.md / IMPLEMENTATION_PLAN.md
# / specs/ only, so this repo still counts as greenfield until test 9 says otherwise.

# ----- the fake agent -------------------------------------------------------
# Behaviour is driven entirely by environment variables so each test can shape one failure mode:
#   FAKE_LOG        append-only role order log        FAKE_PROMPT_DIR  per-role prompt capture
#   FAKE_FAIL_ROLE  this role exits non-zero          FAKE_EMPTY_ROLE  this role exits 0 silently
#   FAKE_EDIT_ROLE  this role edits a tracked file    FAKE_STDOUT_ROLE this role reports on STDOUT only
#   FAKE_STDIN      read the prompt from stdin instead of "$1"
cat > "$TMP/fake-agent.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
role="${WGM_AUDIT_ROLE:-unknown}"
if [[ "${FAKE_STDIN:-0}" == "1" ]]; then prompt="$(cat)"; else prompt="${1:-}"; fi
printf '%s\n' "$role" >> "$FAKE_LOG"
printf '%s' "$prompt" > "${FAKE_PROMPT_DIR}/${role}.prompt"
if [[ "${FAKE_EDIT_ROLE:-}" == "$role" ]]; then printf 'sneaky edit by %s\n' "$role" >> README.md; fi
if [[ "${FAKE_FAIL_ROLE:-}" == "$role" ]]; then echo "fake agent: deliberate failure for $role" >&2; exit 3; fi
if [[ "${FAKE_EMPTY_ROLE:-}" == "$role" ]]; then exit 0; fi
body="### ${role} report
| Doc | Observation | Severity | Recommended action |
|---|---|---|---|
| README.md | fake finding from ${role} | GREEN | none |"
if [[ "${FAKE_STDOUT_ROLE:-}" == "$role" ]]; then printf '%s\n' "$body"; else printf '%s\n' "$body" > "$WGM_AUDIT_REPORT_FILE"; fi
exit 0
FAKE
chmod +x "$TMP/fake-agent.sh"
AGENT_ARGV=(bash "$TMP/fake-agent.sh")

export FAKE_LOG="$TMP/order.log"
export FAKE_PROMPT_DIR="$TMP/prompts"

OUT=""; RC=0
run() {  # run audit.sh capturing combined output + exit code without tripping set -e
  : > "$FAKE_LOG"
  rm -rf "$FAKE_PROMPT_DIR"; mkdir -p "$FAKE_PROMPT_DIR"
  set +e
  OUT="$("$AUDIT" "$@" 2>&1)"; RC=$?
  set -e
}

reset_runs() {  # drop reports + working dirs between tests
  rm -rf docs/audit .wgm
  git checkout -q -- README.md docs/README.md 2>/dev/null || true
}

# 1) --help succeeds and describes the contract; bad arguments are rejected before anything runs.
#    An orchestrator that silently accepts a typo'd flag runs the wrong audit.
run --help
if [[ "$RC" -eq 0 ]] && grep -q "docs-audit dispatcher" <<<"$OUT" && grep -q -- "--dry-run" <<<"$OUT"; then
  pass "--help prints usage and exits 0"
else
  fail "--help did not print usage (rc=$RC)"
fi

run --nope -- "${AGENT_ARGV[@]}"
if [[ "$RC" -eq 2 ]] && grep -q "Unknown flag" <<<"$OUT"; then
  pass "an unknown flag exits 2"
else
  fail "unknown flag was not rejected (rc=$RC): $OUT"
fi

run --slug
if [[ "$RC" -eq 2 ]] && grep -q -- "--slug requires a name" <<<"$OUT"; then
  pass "a flag missing its value exits 2"
else
  fail "missing flag value was not rejected (rc=$RC): $OUT"
fi

# A slug becomes a filename, so a traversal slug must be refused rather than steering the report
# out of the audit directory.
run --slug "../../escape" -- "${AGENT_ARGV[@]}"
if [[ "$RC" -eq 2 ]] && grep -q -- "--slug must be a lowercase slug" <<<"$OUT"; then
  pass "a path-traversal slug is rejected"
else
  fail "traversal slug was not rejected (rc=$RC): $OUT"
fi

# With no agent at all the run must stop before pretending to audit anything.
set +e
OUT="$(env -u WGM_AGENT "$AUDIT" --scope "docs/" 2>&1)"; RC=$?
set -e
if [[ "$RC" -eq 2 ]] && grep -q "No agent configured" <<<"$OUT"; then
  pass "no configured agent exits 2"
else
  fail "missing agent was not reported (rc=$RC): $OUT"
fi

# 2) --dry-run shows the roles, their order, and the output path — and invokes nothing, creates
#    nothing. A preview that silently ran the agent would defeat its only purpose.
run --scope "docs/" --dry-run -- "${AGENT_ARGV[@]}"
if [[ "$RC" -eq 0 ]] \
   && grep -q "1. wgm-docs-junior" <<<"$OUT" \
   && grep -q "2. wgm-docs-senior" <<<"$OUT" \
   && grep -q "3. wgm-docs-principal" <<<"$OUT" \
   && grep -q "4. wgm-docs-pm" <<<"$OUT" \
   && grep -q "5. wgm-docs-writer" <<<"$OUT" \
   && grep -q "runs only after all four persona reports exist" <<<"$OUT" \
   && grep -q "docs/audit/" <<<"$OUT" \
   && grep -q "would invoke" <<<"$OUT" \
   && [[ ! -s "$FAKE_LOG" ]] \
   && [[ ! -d docs/audit ]]; then
  pass "--dry-run shows roles, order, and output path without invoking the agent"
else
  fail "--dry-run misbehaved (rc=$RC): $OUT"
fi
reset_runs

# 3) The happy path: four persona passes, then the writer LAST, and exactly one report on disk.
run --scope "docs/ and README.md" --slug happy -- "${AGENT_ARGV[@]}"
ORDER="$(tr '\n' ' ' < "$FAKE_LOG")"
REPORTS=(docs/audit/*_happy.md)
if [[ "$RC" -eq 0 ]] \
   && [[ "$ORDER" == "wgm-docs-junior wgm-docs-senior wgm-docs-principal wgm-docs-pm wgm-docs-writer " ]] \
   && [[ -f "${REPORTS[0]}" ]] \
   && [[ "${#REPORTS[@]}" -eq 1 ]] \
   && grep -q "wgm-docs-writer report" "${REPORTS[0]}" \
   && grep -q "audit: GREEN" <<<"$OUT"; then
  pass "four personas run, the writer runs last, and one consolidated report is written"
else
  fail "happy path did not produce the expected order/report (rc=$RC, order='$ORDER'): $OUT"
fi

# 3a) Report placement: the timestamped name and the greenfield docs/audit/ default.
if [[ "${REPORTS[0]}" =~ ^docs/audit/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{4}Z_happy\.md$ ]] \
   && grep -q "greenfield default" <<<"$OUT"; then
  pass "the report lands at docs/audit/<UTC-stamp>_<slug>.md by the greenfield rule"
else
  fail "report placement/naming is wrong: ${REPORTS[0]}"
fi

# 3b) Every persona gets the IDENTICAL bounded scope, and none of them is told where another
#     persona's report lives — independence is the whole reason for running four.
identical=1
for r in wgm-docs-senior wgm-docs-principal wgm-docs-pm; do
  grep -q "docs/ and README.md" "$FAKE_PROMPT_DIR/$r.prompt" || identical=0
done
leaked=0
for r in wgm-docs-junior wgm-docs-senior wgm-docs-principal wgm-docs-pm; do
  for other in wgm-docs-junior wgm-docs-senior wgm-docs-principal wgm-docs-pm; do
    [[ "$r" == "$other" ]] && continue
    grep -q "${other}.md" "$FAKE_PROMPT_DIR/$r.prompt" && leaked=1
  done
done
if [[ "$identical" -eq 1 && "$leaked" -eq 0 ]] \
   && grep -q "READ ONLY" "$FAKE_PROMPT_DIR/wgm-docs-junior.prompt"; then
  pass "all four personas receive an identical bounded scope and no sibling's report path"
else
  fail "persona independence broken (identical=$identical leaked=$leaked)"
fi

# 3c) The writer is handed all four report paths — it consolidates evidence, it does not re-review.
w=0
for r in wgm-docs-junior wgm-docs-senior wgm-docs-principal wgm-docs-pm; do
  grep -q "${r}.md" "$FAKE_PROMPT_DIR/wgm-docs-writer.prompt" && w=$((w + 1))
done
if [[ "$w" -eq 4 ]] \
   && grep -q "Preserve dissent" "$FAKE_PROMPT_DIR/wgm-docs-writer.prompt" \
   && grep -q "Rejected findings" "$FAKE_PROMPT_DIR/wgm-docs-writer.prompt" \
   && grep -q "Agent action" "$FAKE_PROMPT_DIR/wgm-docs-writer.prompt" \
   && grep -q "Operator action" "$FAKE_PROMPT_DIR/wgm-docs-writer.prompt"; then
  pass "the writer receives all four reports plus the dissent/rejected/action-label contract"
else
  fail "writer prompt is missing report paths or the consolidation contract (paths=$w)"
fi

# 3d) The dispatcher never touches the holdout scenarios: unchanged on disk, and never named in a
#     prompt. A leaked holdout silently invalidates every later satisfaction score.
if [[ "$(cksum scenarios/holdout.yaml)" == "$SCEN_SUM" ]] \
   && ! grep -rq "CANARY-HOLDOUT-DO-NOT-LEAK" "$FAKE_PROMPT_DIR" \
   && ! grep -rq "scenarios/holdout" "$FAKE_PROMPT_DIR"; then
  pass "holdout scenarios are neither modified nor named in any prompt"
else
  fail "the dispatcher touched or leaked the holdout scenarios"
fi

# 3e) The run's working directory is cleaned up by default — scratch is not an artifact.
leftovers=(.wgm/audit-run-*)
if [[ ! -e "${leftovers[0]}" ]]; then
  pass "the per-run working directory is removed on exit"
else
  fail "a working directory survived the run: ${leftovers[0]}"
fi
reset_runs

# 4) --keep retains the working dir, and two runs never share one — concurrent audits must not race
#    on a same-name scratch file.
run --scope "docs/" --slug keep1 --keep -- "${AGENT_ARGV[@]}"
run --scope "docs/" --slug keep2 --keep -- "${AGENT_ARGV[@]}"
kept=(.wgm/audit-run-*)
if [[ "$RC" -eq 0 ]] && [[ "${#kept[@]}" -eq 2 ]] \
   && [[ -f "${kept[0]}/wgm-docs-junior.md" ]] \
   && grep -q "Working directory kept" <<<"$OUT"; then
  pass "--keep retains the persona reports, and each run gets its own unique working directory"
else
  fail "--keep/unique working dirs failed (rc=$RC, dirs=${#kept[@]})"
fi
reset_runs

# 5) A persona that FAILS blocks the writer entirely and leaves no report. Consolidating three of
#    four reports would look like a completed audit while silently dropping a whole lens.
FAKE_FAIL_ROLE=wgm-docs-principal run --scope "docs/" --slug failing -- "${AGENT_ARGV[@]}"
if [[ "$RC" -ne 0 ]] \
   && ! grep -q "wgm-docs-writer" "$FAKE_LOG" \
   && grep -q "wgm-docs-principal" <<<"$OUT" \
   && grep -q "was NOT run" <<<"$OUT" \
   && [[ ! -d docs/audit ]]; then
  pass "a failed persona blocks the writer, exits non-zero, and writes no report"
else
  fail "a failed persona did not block the writer (rc=$RC): $OUT"
fi
reset_runs

# 6) A persona that exits 0 but produces NOTHING is the same failure, and is the one a naive
#    dispatcher misses: the process succeeded, so only the artifact check can catch it.
FAKE_EMPTY_ROLE=wgm-docs-pm run --scope "docs/" --slug empty -- "${AGENT_ARGV[@]}"
if [[ "$RC" -ne 0 ]] \
   && ! grep -q "wgm-docs-writer" "$FAKE_LOG" \
   && grep -q "produced no report" <<<"$OUT" \
   && [[ ! -d docs/audit ]]; then
  pass "an exit-0 persona with an empty report blocks the writer and writes no report"
else
  fail "an empty persona report was treated as success (rc=$RC): $OUT"
fi
reset_runs

# 7) A failing writer must not leave a success-shaped artifact behind. A half-written report in
#    docs/audit/ would be read later as evidence the audit passed.
FAKE_FAIL_ROLE=wgm-docs-writer run --scope "docs/" --slug wfail -- "${AGENT_ARGV[@]}"
if [[ "$RC" -ne 0 ]] \
   && grep -q "wgm-docs-writer" "$FAKE_LOG" \
   && grep -q "failed to consolidate" <<<"$OUT" \
   && [[ ! -d docs/audit ]]; then
  pass "a failed writer exits non-zero and leaves no report behind"
else
  fail "a failed writer left a success-shaped result (rc=$RC): $OUT"
fi
reset_runs

# 7a) …and the same for a writer that exits 0 with nothing to show for it.
FAKE_EMPTY_ROLE=wgm-docs-writer run --scope "docs/" --slug wempty -- "${AGENT_ARGV[@]}"
if [[ "$RC" -ne 0 ]] && grep -q "failed to consolidate" <<<"$OUT" && [[ ! -d docs/audit ]]; then
  pass "an empty writer report is a failure, not an empty artifact"
else
  fail "an empty writer report was accepted (rc=$RC): $OUT"
fi
reset_runs

# 8) Roles are READ-ONLY. The prompt says so; this proves the dispatcher enforces it rather than
#    trusting it — a persona that edits docs is exactly the reviewer/author conflation the four-eyes
#    split exists to prevent.
FAKE_EDIT_ROLE=wgm-docs-senior run --scope "docs/" --slug readonly -- "${AGENT_ARGV[@]}"
if [[ "$RC" -ne 0 ]] \
   && grep -q "modified the working tree" <<<"$OUT" \
   && ! grep -q "wgm-docs-writer" "$FAKE_LOG" \
   && [[ ! -d docs/audit ]]; then
  pass "a role that edits the working tree fails the audit and blocks the writer"
else
  fail "a file-editing role was allowed to pass (rc=$RC): $OUT"
fi
reset_runs

# 9) Output placement: an explicit --out is honored, and the existing-project rule sends the report
#    to the local .wgm/ path instead of the project's committed docs/ tree.
run --scope "docs/" --slug custom --out audits -- "${AGENT_ARGV[@]}"
CUSTOM=(audits/*_custom.md)
if [[ "$RC" -eq 0 ]] && [[ -f "${CUSTOM[0]}" ]]; then
  pass "--out places the report in the requested directory"
else
  fail "--out was not honored (rc=$RC)"
fi
rm -rf audits
reset_runs

printf '# agents\n' > AGENTS.md
run --scope "docs/" --slug existing -- "${AGENT_ARGV[@]}"
EXIST=(.wgm/docs/audit/*_existing.md)
if [[ "$RC" -eq 0 ]] && [[ -f "${EXIST[0]}" ]] && grep -q "existing-project default" <<<"$OUT" \
   && [[ ! -d docs/audit ]]; then
  pass "an existing project (AGENTS.md) gets the local .wgm/docs/audit path, not docs/audit"
else
  fail "existing-project placement rule failed (rc=$RC): $OUT"
fi
rm -f AGENTS.md
git checkout -q -- . 2>/dev/null || true
reset_runs

# 10) Safe argv passthrough: shell metacharacters inside the scope must reach the agent as LITERAL
#     text. If the prompt were ever spliced into a shell string, this scope would execute.
# shellcheck disable=SC2016  # the metacharacters are the fixture — they must stay unexpanded here.
INJECT='$(touch pwned-argv) `touch pwned-backtick` ; touch pwned-semi'
run --scope "$INJECT" --slug inject -- "${AGENT_ARGV[@]}"
if [[ "$RC" -eq 0 ]] \
   && [[ ! -e pwned-argv && ! -e pwned-backtick && ! -e pwned-semi ]] \
   && grep -qF 'touch pwned-semi' "$FAKE_PROMPT_DIR/wgm-docs-junior.prompt"; then
  pass "argv passthrough hands the prompt over literally — no shell evaluation of scope text"
else
  fail "argv passthrough evaluated the prompt as shell (rc=$RC)"
fi
rm -f pwned-*
reset_runs

# 10a) The same guarantee for the shell-evaluated --agent form: the operator's COMMAND is trusted
#      and evaluated, but the prompt is passed as a positional and never spliced into it.
run --scope "$INJECT" --slug injectcmd --agent "bash $TMP/fake-agent.sh"
if [[ "$RC" -eq 0 ]] && [[ ! -e pwned-argv && ! -e pwned-backtick && ! -e pwned-semi ]]; then
  pass "--agent evaluates the trusted command but never the prompt"
else
  fail "--agent spliced the prompt into the shell command (rc=$RC): $OUT"
fi
rm -f pwned-*
reset_runs

# 11) STDIN mode for agents that read their prompt from stdin rather than argv.
FAKE_STDIN=1 WGM_PROMPT_STDIN=1 run --scope "docs/" --slug stdin -- "${AGENT_ARGV[@]}"
STDIN_REPORT=(docs/audit/*_stdin.md)
if [[ "$RC" -eq 0 ]] && [[ -f "${STDIN_REPORT[0]}" ]] \
   && grep -q "docs/" "$FAKE_PROMPT_DIR/wgm-docs-junior.prompt"; then
  pass "WGM_PROMPT_STDIN=1 delivers the prompt on stdin and still completes the audit"
else
  fail "stdin mode failed (rc=$RC): $OUT"
fi
reset_runs

# 12) The report contract has two halves and either is enough: a host whose agent cannot write files
#     may report on STDOUT, and the dispatcher captures it.
FAKE_STDOUT_ROLE=wgm-docs-junior run --scope "docs/" --slug stdout --keep -- "${AGENT_ARGV[@]}"
KEPT=(.wgm/audit-run-*)
if [[ "$RC" -eq 0 ]] && [[ -f "${KEPT[0]}/wgm-docs-junior.md" ]] \
   && grep -q "wgm-docs-junior report" "${KEPT[0]}/wgm-docs-junior.md"; then
  pass "a role that reports only on STDOUT still produces a captured report"
else
  fail "STDOUT-only reporting was not captured (rc=$RC): $OUT"
fi
reset_runs

if [[ "$FAILED" -eq 0 ]]; then
  echo "audit harness: GREEN"
  exit 0
else
  echo "audit harness: RED" >&2
  exit 1
fi
