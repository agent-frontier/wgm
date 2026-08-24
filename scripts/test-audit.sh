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
git config commit.gpgsign false
mkdir -p docs
printf '# readme\n' > README.md
printf '# docs\n' > docs/README.md
# An ignored path, so the harness can prove that "not in git status" is not the same as "not a
# change": a role writing here is still writing to the operator's tree.
printf 'build/\n' > .gitignore

# A holdout scenario with a canary string. audit.sh must never read, name, or modify it: holdout
# scenarios belong to wgm-validator alone, and an audit that leaked them would contaminate the
# holdout (references/scenarios.md).
mkdir -p scenarios
printf 'id: s1\nprompt: CANARY-HOLDOUT-DO-NOT-LEAK\n' > scenarios/holdout.yaml
SCEN_SUM="$(cksum scenarios/holdout.yaml)"

git add -A && git commit -qm seed
SEED="$(git rev-parse HEAD)"

# `scenarios/` exists now, but the default-placement rule keys off AGENTS.md / IMPLEMENTATION_PLAN.md
# / specs/ only, so this repo still counts as greenfield until test 9 says otherwise.

# ----- the fake agent -------------------------------------------------------
# Behaviour is driven entirely by environment variables so each test can shape one failure mode:
#   FAKE_LOG         append-only role order log       FAKE_PROMPT_DIR   per-role prompt capture
#   FAKE_FAIL_ROLE   this role exits non-zero         FAKE_EMPTY_ROLE   this role exits 0 silently
#   FAKE_EDIT_ROLE   this role edits a tracked file   FAKE_STDOUT_ROLE  this role reports on STDOUT
#   FAKE_BANNER_ROLE this role exits 0 printing a status banner instead of a report
#   FAKE_TABLELESS_ROLE this role emits a correct heading but no finding table
#   FAKE_SLEEP_ROLE  this role sleeps FAKE_SLEEP_SECS seconds (for the timeout bound)
#   FAKE_COMMIT_ROLE / FAKE_STASH_ROLE / FAKE_IGNORED_ROLE — three mutations that leave
#                    `git status` clean: commit it, stash it, or write an ignored path
#   FAKE_FLAKY_ROLE  this role fails its FIRST attempt only, then succeeds (for the retry path)
#   FAKE_STDIN       read the prompt from stdin instead of "$1"
# The writer emits the five markers the consolidation contract requires; FAKE_THIN_WRITER makes it
# emit a plausible-looking but incomplete report instead.
cat > "$TMP/fake-agent.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
role="${WGM_AUDIT_ROLE:-unknown}"
if [[ "${FAKE_STDIN:-0}" == "1" ]]; then prompt="$(cat)"; else prompt="${1:-}"; fi
printf '%s\n' "$role" >> "$FAKE_LOG"
printf '%s' "$prompt" > "${FAKE_PROMPT_DIR}/${role}.prompt"
if [[ "${FAKE_EDIT_ROLE:-}" == "$role" ]]; then printf 'sneaky edit by %s\n' "$role" >> README.md; fi
if [[ "${FAKE_SLEEP_ROLE:-}" == "$role" ]]; then sleep "${FAKE_SLEEP_SECS:-5}"; fi
# Three ways to change a repository that leave `git status` looking pristine. Each is a real thing a
# capable agent does by habit — "I tidied up and committed it" is the single most likely one.
if [[ "${FAKE_COMMIT_ROLE:-}" == "$role" ]]; then
  printf 'committed by %s\n' "$role" >> README.md
  git add -A >/dev/null 2>&1
  git commit -qm "role commit" >/dev/null 2>&1
fi
if [[ "${FAKE_STASH_ROLE:-}" == "$role" ]]; then
  printf 'stashed by %s\n' "$role" >> README.md
  git stash -q >/dev/null 2>&1
fi
if [[ "${FAKE_IGNORED_ROLE:-}" == "$role" ]]; then
  mkdir -p build
  printf 'written by %s\n' "$role" > build/artifact.txt
fi
if [[ "${FAKE_FLAKY_ROLE:-}" == "$role" ]]; then
  # One transient failure, then success — the exact shape --retries exists for.
  tries="${FAKE_TRIES_DIR}/${role}"
  if [[ ! -e "$tries" ]]; then
    : > "$tries"
    echo "fake agent: transient failure for $role" >&2
    exit 4
  fi
fi
if [[ "${FAKE_FAIL_ROLE:-}" == "$role" ]]; then echo "fake agent: deliberate failure for $role" >&2; exit 3; fi
if [[ "${FAKE_EMPTY_ROLE:-}" == "$role" ]]; then exit 0; fi
if [[ "${FAKE_TABLELESS_ROLE:-}" == "$role" ]]; then
  # Correct heading, no finding table: plausible prose that is not a review.
  printf '### %s — fake lens\n\nEverything looked fine to me.\n' "$role" > "$WGM_AUDIT_REPORT_FILE"
  exit 0
fi
if [[ "${FAKE_BANNER_ROLE:-}" == "$role" ]]; then
  # Exit 0 with plenty of output and no report in it: the failure a non-empty check cannot see.
  printf 'Model ready.\nI reviewed the scope and everything looks fine to me.\nDone.\n'
  exit 0
fi
if [[ "$role" == "wgm-docs-writer" ]]; then
  if [[ "${FAKE_THIN_WRITER:-0}" == "1" ]]; then
    body="# Docs Audit Report — fake
Everything was fine, nothing else to say."
  else
    body="# Docs Audit Report — fake stamp — fake slug

## Consolidated report (wgm-docs-writer)

### Agent actions
| # | Finding | Raised by | Doc(s) | Action |
|---|---|---|---|---|
| 1 | fake | junior | README.md | fix |

### Operator actions
None.

### Rejected findings
None rejected.

### Dissent
Unanimous: no dissent recorded."
  fi
else
  body="### ${role} — fake lens
| Doc | Observation | Severity | Recommended action |
|---|---|---|---|
| README.md | fake finding from ${role} | GREEN | none |"
fi
if [[ "${FAKE_STDOUT_ROLE:-}" == "$role" ]]; then printf '%s\n' "$body"; else printf '%s\n' "$body" > "$WGM_AUDIT_REPORT_FILE"; fi
exit 0
FAKE
chmod +x "$TMP/fake-agent.sh"
AGENT_ARGV=(bash "$TMP/fake-agent.sh")

export FAKE_LOG="$TMP/order.log"
export FAKE_PROMPT_DIR="$TMP/prompts"
export FAKE_TRIES_DIR="$TMP/tries"

OUT=""; RC=0
run() {  # run audit.sh capturing combined output + exit code without tripping set -e
  : > "$FAKE_LOG"
  rm -rf "$FAKE_PROMPT_DIR"; mkdir -p "$FAKE_PROMPT_DIR"
  rm -rf "$FAKE_TRIES_DIR"; mkdir -p "$FAKE_TRIES_DIR"
  set +e
  OUT="$("$AUDIT" "$@" 2>&1)"; RC=$?
  set -e
}

run_in() {  # same as run(), but from another working directory
  local dir="$1"; shift
  : > "$FAKE_LOG"
  rm -rf "$FAKE_PROMPT_DIR"; mkdir -p "$FAKE_PROMPT_DIR"
  rm -rf "$FAKE_TRIES_DIR"; mkdir -p "$FAKE_TRIES_DIR"
  set +e
  OUT="$(cd "$dir" && "$AUDIT" "$@" 2>&1)"; RC=$?
  set -e
}

reset_runs() {  # drop reports + working dirs between tests
  rm -rf docs/audit .wgm
  git checkout -q -- README.md docs/README.md 2>/dev/null || true
}

count_role() {  # how many times a role was invoked in the last run
  grep -c "^$1\$" "$FAKE_LOG" 2>/dev/null || true
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
   && grep -q "Docs Audit Report" "${REPORTS[0]}" \
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
   && grep -q "origin unknown (role or concurrent process)" <<<"$OUT" \
   && ! grep -q "wgm-docs-writer" "$FAKE_LOG" \
   && [[ ! -d docs/audit ]]; then
  pass "an edited working tree fails the audit and blocks the writer"
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
   && grep -q "^### wgm-docs-junior" "${KEPT[0]}/wgm-docs-junior.md"; then
  pass "a role that reports only on STDOUT still produces a captured report"
else
  fail "STDOUT-only reporting was not captured (rc=$RC): $OUT"
fi
reset_runs

# 13) An exit-0 status BANNER is not a report. This is the failure a "did the process succeed and is
#     the file non-empty?" check cannot see: the agent exits clean with plenty of output, so a naive
#     dispatcher consolidates a chat greeting into the paper trail and calls the audit done.
FAKE_BANNER_ROLE=wgm-docs-senior run --scope "docs/" --slug banner -- "${AGENT_ARGV[@]}"
if [[ "$RC" -ne 0 ]] \
   && grep -q "is not a report" <<<"$OUT" \
   && grep -q "no '### wgm-docs-senior" <<<"$OUT" \
   && ! grep -q "wgm-docs-writer" "$FAKE_LOG" \
   && [[ ! -d docs/audit ]]; then
  pass "an exit-0 banner fails the persona report contract and blocks the writer"
else
  fail "an exit-0 banner was accepted as a persona report (rc=$RC): $OUT"
fi
reset_runs

# 13b) The TABLE half of the persona contract is enforced independently: prose under a correct
#      heading is an opinion, not a finding list, and the four columns are what makes a finding
#      actionable (which doc, what, how bad, what to do).
FAKE_TABLELESS_ROLE=wgm-docs-pm run --scope "docs/" --slug notable -- "${AGENT_ARGV[@]}"
if [[ "$RC" -ne 0 ]] \
   && grep -q "table header" <<<"$OUT" \
   && ! grep -q "wgm-docs-writer" "$FAKE_LOG" \
   && [[ ! -d docs/audit ]]; then
  pass "a persona report with a heading but no finding table is rejected"
else
  fail "a tableless persona report was accepted (rc=$RC): $OUT"
fi
reset_runs

# 13a) The heading half of the contract is enforced too: a table with no role heading is not
#      attributable to a lens, and an audit's whole value is knowing which lens said what.
FAKE_BANNER_ROLE=wgm-docs-writer run --scope "docs/" --slug wbanner -- "${AGENT_ARGV[@]}"
if [[ "$RC" -ne 0 ]] && grep -q "is not a report" <<<"$OUT" && [[ ! -d docs/audit ]]; then
  pass "an exit-0 banner from the writer is rejected and files no report"
else
  fail "a writer banner was accepted (rc=$RC): $OUT"
fi
reset_runs

# 14) A writer report missing the consolidation markers is rejected. A partial consolidation reads
#     exactly like a complete one — no Dissent section looks identical to "there was no dissent".
FAKE_THIN_WRITER=1 run --scope "docs/" --slug thin -- "${AGENT_ARGV[@]}"
if [[ "$RC" -ne 0 ]] \
   && grep -qE "no '(Dissent|Rejected findings|Agent action|Operator action)' section" <<<"$OUT" \
   && [[ ! -d docs/audit ]]; then
  pass "a writer report missing Dissent/Rejected/Agent/Operator markers is rejected"
else
  fail "an incomplete consolidated report was filed (rc=$RC): $OUT"
fi
reset_runs

# 15) A tree mutation is TERMINAL. With --retries 1 a retryable failure would run twice; a mutation
#     must run exactly once, because retrying against the mutated tree would re-baseline the damage
#     into "clean" and let attempt 2 pass. The mutation is also left in place for diagnosis.
FAKE_EDIT_ROLE=wgm-docs-junior run --scope "docs/" --slug mutate --retries 1 --retry-delay 0 -- "${AGENT_ARGV[@]}"
edits="$(count_role wgm-docs-junior)"
if [[ "$RC" -ne 0 ]] \
   && [[ "$edits" -eq 1 ]] \
   && grep -q "This is terminal" <<<"$OUT" \
   && ! grep -q "attempt 2/" <<<"$OUT" \
   && ! grep -q "wgm-docs-senior" "$FAKE_LOG" \
   && ! grep -q "wgm-docs-writer" "$FAKE_LOG" \
   && [[ -n "$(git status --porcelain README.md)" ]] \
   && [[ ! -d docs/audit ]]; then
  pass "a tree change is terminal: one attempt, no retry, no writer, and the change stays visible"
else
  fail "a mutation was retried or did not abort the run (rc=$RC, attempts=$edits): $OUT"
fi
reset_runs

# 15a) A role that COMMITS its edit leaves a spotless `git status`. Hashing status alone would call
#      that GREEN, and the operator would find an unexplained commit on their branch after an audit
#      that "passed". This is the most likely evasion of the three: tidying up and committing is
#      ordinary agent behaviour.
FAKE_COMMIT_ROLE=wgm-docs-junior run --scope "docs/" --slug rolecommit --retries 1 --retry-delay 0 -- "${AGENT_ARGV[@]}"
tries="$(count_role wgm-docs-junior)"
if [[ "$RC" -ne 0 ]] \
   && [[ "$tries" -eq 1 ]] \
   && ! grep -q "attempt 2/" <<<"$OUT" \
   && grep -q "This is terminal" <<<"$OUT" \
   && ! grep -q "wgm-docs-writer" "$FAKE_LOG" \
   && [[ "$(git rev-parse HEAD)" != "$SEED" ]] \
   && [[ ! -d docs/audit ]]; then
  pass "a role that commits is caught (clean status, moved HEAD), terminally, with the commit left visible"
else
  fail "a role commit was not detected (rc=$RC, attempts=$tries, head moved=$([[ "$(git rev-parse HEAD)" != "$SEED" ]] && echo yes || echo no))"
fi
git reset -q --hard "$SEED"
reset_runs

# 15b) A role that STASHES its edit also leaves a spotless `git status` — the work is hidden in
#      refs/stash, where a status/diff hash cannot see it, and where an operator will not look.
FAKE_STASH_ROLE=wgm-docs-senior run --scope "docs/" --slug rolestash --retries 1 --retry-delay 0 -- "${AGENT_ARGV[@]}"
tries="$(count_role wgm-docs-senior)"
if [[ "$RC" -ne 0 ]] \
   && [[ "$tries" -eq 1 ]] \
   && ! grep -q "attempt 2/" <<<"$OUT" \
   && ! grep -q "wgm-docs-writer" "$FAKE_LOG" \
   && git rev-parse --quiet --verify refs/stash >/dev/null \
   && [[ ! -d docs/audit ]]; then
  pass "a role that stashes is caught via the stash ref, terminally, with the stash left for inspection"
else
  fail "a role stash was not detected (rc=$RC, attempts=$tries)"
fi
git stash drop -q >/dev/null 2>&1 || true
git checkout -q -- . 2>/dev/null || true
reset_runs

# 15c) A role that writes an IGNORED path never appears in a default `git status` at all. It is still
#      the operator's disk, and a reviewer that writes build output is not read-only.
FAKE_IGNORED_ROLE=wgm-docs-principal run --scope "docs/" --slug roleignored --retries 1 --retry-delay 0 -- "${AGENT_ARGV[@]}"
tries="$(count_role wgm-docs-principal)"
if [[ "$RC" -ne 0 ]] \
   && [[ "$tries" -eq 1 ]] \
   && ! grep -q "attempt 2/" <<<"$OUT" \
   && ! grep -q "wgm-docs-writer" "$FAKE_LOG" \
   && [[ -f build/artifact.txt ]] \
   && [[ -z "$(git status --porcelain)" ]] \
   && [[ ! -d docs/audit ]]; then
  pass "a role that writes a gitignored path is caught even though git status stays clean"
else
  fail "an ignored-path write was not detected (rc=$RC, attempts=$tries)"
fi
rm -rf build
reset_runs

# 15c-i) The message must be EVIDENCE, not an accusation. The dispatcher cannot distinguish a role's
#        write from a concurrent editor, watcher, or build in the same checkout — they produce an
#        identical delta — so it must report what changed and name both possible origins rather than
#        blaming the role. A guard that names a culprit it cannot identify gets distrusted, then
#        ignored. It must also show the exact delta: "something changed" is not actionable.
FAKE_EDIT_ROLE=wgm-docs-junior run --scope "docs/" --slug evidence -- "${AGENT_ARGV[@]}"
if [[ "$RC" -ne 0 ]] \
   && grep -q "repository state changed during wgm-docs-junior; origin unknown (role or concurrent process)" <<<"$OUT" \
   && grep -q "exact delta (baseline" <<<"$OUT" \
   && grep -qE '^[[:space:]]*\+(status|unstaged|unstaged-content):' <<<"$OUT" \
   && grep -q "no other writer active" <<<"$OUT" \
   && ! grep -qi "the role edited" <<<"$OUT"; then
  pass "a state change reports the exact delta and names both possible origins, accusing neither"
else
  fail "the state-change report lacked the delta or asserted an origin it cannot know (rc=$RC): $OUT"
fi
git checkout -q -- README.md
reset_runs

# 15c-ii) The same neutrality and evidence for a change that never touches the working tree at all —
#         here the delta is a moved HEAD, so the printed evidence must show it.
FAKE_COMMIT_ROLE=wgm-docs-pm run --scope "docs/" --slug evidencehead -- "${AGENT_ARGV[@]}"
if [[ "$RC" -ne 0 ]] \
   && grep -q "origin unknown" <<<"$OUT" \
   && grep -qE '^[[:space:]]*\+head:' <<<"$OUT"; then
  pass "a moved HEAD is shown in the delta, not just reported as 'something changed'"
else
  fail "a moved HEAD was not shown in the printed delta (rc=$RC): $OUT"
fi
git reset -q --hard "$SEED"
reset_runs

# 15c-iii) A change observed during the WRITER's turn must not claim the writer never ran — it did.
#          This is the one message an operator reads when the audit dies at the last step, and
#          "wgm-docs-writer was NOT run" there is simply false.
FAKE_EDIT_ROLE=wgm-docs-writer run --scope "docs/" --slug wmutate -- "${AGENT_ARGV[@]}"
if [[ "$RC" -ne 0 ]] \
   && grep -q "wgm-docs-writer" "$FAKE_LOG" \
   && grep -q "wgm-docs-writer ran, but no consolidated report was written" <<<"$OUT" \
   && ! grep -q "wgm-docs-writer was NOT run" <<<"$OUT" \
   && [[ ! -d docs/audit ]]; then
  pass "a change during the writer's turn is reported honestly: it ran, and no report was filed"
else
  fail "the writer-turn diagnostic was wrong or a report was filed (rc=$RC): $OUT"
fi
git checkout -q -- README.md
reset_runs

# 15d) The dispatcher's OWN scratch under .wgm/ is not a role mutation — it is ignored by the guard
#      on purpose, or every single run would fail itself.
run --scope "docs/" --slug selfscratch --keep -- "${AGENT_ARGV[@]}"
SELF_REPORT=(docs/audit/*_selfscratch.md)
if [[ "$RC" -eq 0 ]] && [[ -f "${SELF_REPORT[0]}" ]]; then
  pass "the dispatcher's own .wgm/ scratch does not trip its read-only guard"
else
  fail "the guard fired on the dispatcher's own working directory (rc=$RC): $OUT"
fi
reset_runs

# 16) A transient failure IS retryable — that is the only failure class --retries exists for.
FAKE_FLAKY_ROLE=wgm-docs-senior run --scope "docs/" --slug flaky --retries 1 --retry-delay 0 -- "${AGENT_ARGV[@]}"
tries="$(count_role wgm-docs-senior)"
FLAKY_REPORT=(docs/audit/*_flaky.md)
if [[ "$RC" -eq 0 ]] && [[ "$tries" -eq 2 ]] && [[ -f "${FLAKY_REPORT[0]}" ]] \
   && grep -q "retrying wgm-docs-senior" <<<"$OUT"; then
  pass "a transient role failure is retried and the audit completes"
else
  fail "--retries did not recover a transient failure (rc=$RC, attempts=$tries): $OUT"
fi
reset_runs

# 16a) …and retries are bounded: exhausting them is still a failure, not an infinite loop.
FAKE_FAIL_ROLE=wgm-docs-pm run --scope "docs/" --slug exhaust --retries 2 --retry-delay 0 -- "${AGENT_ARGV[@]}"
tries="$(count_role wgm-docs-pm)"
if [[ "$RC" -ne 0 ]] && [[ "$tries" -eq 3 ]] && [[ ! -d docs/audit ]]; then
  pass "retries are bounded at --retries + 1 attempts, then the role fails"
else
  fail "retry bound not honored (rc=$RC, attempts=$tries)"
fi
reset_runs

# 17) A non-git target has no read-only guard at all, so the default must be a clear refusal rather
#     than a silent downgrade of the one property this dispatcher enforces.
mkdir -p "$TMP/nogit"
run_in "$TMP/nogit" --scope "docs/" --slug nogit -- "${AGENT_ARGV[@]}"
if [[ "$RC" -eq 2 ]] \
   && grep -q "not a git working tree" <<<"$OUT" \
   && grep -q -- "--allow-unguarded" <<<"$OUT" \
   && [[ ! -s "$FAKE_LOG" ]]; then
  pass "a non-git target is refused before any role runs, and names the escape hatch"
else
  fail "a non-git target was audited without a guard (rc=$RC): $OUT"
fi

# 17a) The escape hatch works, and says out loud what it gave up.
run_in "$TMP/nogit" --scope "docs/" --slug nogit --allow-unguarded -- "${AGENT_ARGV[@]}"
NOGIT_REPORT=("$TMP"/nogit/docs/audit/*_nogit.md)
if [[ "$RC" -eq 0 ]] && [[ -f "${NOGIT_REPORT[0]}" ]] \
   && grep -q "read-only guard is OFF" <<<"$OUT" \
   && grep -q "guard: NONE" <<<"$OUT"; then
  pass "--allow-unguarded runs the audit and warns that the guard is off"
else
  fail "--allow-unguarded did not run or did not warn (rc=$RC): $OUT"
fi
rm -rf "$TMP/nogit"
reset_runs

# 18) Two audits in one tree would interleave their read-only guards — each seeing the other's
#     legitimate writes as a mutation — and could file two reports for one run. The loser is refused
#     before any role runs, and it must not delete the winner's lock on the way out.
mkdir -p .wgm/audit.lock
printf 'pid=99999\n' > .wgm/audit.lock/owner
run --scope "docs/" --slug locked -- "${AGENT_ARGV[@]}"
if [[ "$RC" -eq 2 ]] \
   && grep -q "already holds this tree's lock" <<<"$OUT" \
   && grep -q "pid=99999" <<<"$OUT" \
   && [[ ! -s "$FAKE_LOG" ]] \
   && [[ -d .wgm/audit.lock ]] \
   && [[ ! -d docs/audit ]]; then
  pass "a held lock refuses the second audit before any role runs, and keeps the holder's lock"
else
  fail "a concurrent audit was not refused (rc=$RC): $OUT"
fi
rm -rf .wgm/audit.lock
reset_runs

# 18b) The lock is keyed on the WORKTREE ROOT, not the current directory. Two audits launched from
#      two subdirectories of one checkout are two audits of the same tree: keyed on $(pwd) they would
#      take different locks, serialize on nothing, and then read each other's writes as repository
#      changes. Holding the root lock must refuse a run started from a subdirectory.
mkdir -p sub/dir .wgm/audit.lock
printf 'pid=88888\n' > .wgm/audit.lock/owner
run_in "$TMP/repo/sub/dir" --scope "docs/" --slug sublock -- "${AGENT_ARGV[@]}"
if [[ "$RC" -eq 2 ]] \
   && grep -q "already holds this tree's lock" <<<"$OUT" \
   && grep -q "pid=88888" <<<"$OUT" \
   && [[ ! -s "$FAKE_LOG" ]] \
   && [[ -d .wgm/audit.lock ]]; then
  pass "an audit started in a subdirectory serializes on the worktree root's lock"
else
  fail "a subdirectory run took its own lock instead of the tree's (rc=$RC): $OUT"
fi
rm -rf .wgm/audit.lock sub
reset_runs

# 18a) A completed run releases its own lock, so the next audit is not blocked by a ghost.
run --scope "docs/" --slug unlocked -- "${AGENT_ARGV[@]}"
if [[ "$RC" -eq 0 ]] && [[ ! -e .wgm/audit.lock ]]; then
  pass "a finished run releases its lock"
else
  fail "the lock survived a completed run (rc=$RC)"
fi
reset_runs

# 19) --timeout-seconds must actually bound a role when GNU timeout is available…
if command -v timeout >/dev/null 2>&1 && timeout --help 2>&1 | grep -q -- '--kill-after'; then
  FAKE_SLEEP_ROLE=wgm-docs-junior FAKE_SLEEP_SECS=8 \
    run --scope "docs/" --slug slow --timeout-seconds 1 -- "${AGENT_ARGV[@]}"
  if [[ "$RC" -ne 0 ]] \
     && grep -q "timed out after 1s" <<<"$OUT" \
     && ! grep -q "wgm-docs-writer" "$FAKE_LOG" \
     && [[ ! -d docs/audit ]]; then
    pass "--timeout-seconds bounds a hanging role, blocks the writer, and files no report"
  else
    fail "--timeout-seconds did not bound a hanging role (rc=$RC): $OUT"
  fi
  reset_runs
else
  pass "(skipped) --timeout-seconds bound: GNU timeout/gtimeout is unavailable on this host"
fi

# 19a) …and when it is NOT available, the run says so instead of implying a bound it cannot enforce.
#      A stub `timeout`/`gtimeout` without --kill-after makes this deterministic on any host.
mkdir -p "$TMP/stub"
for stub in timeout gtimeout; do
  printf '#!/usr/bin/env bash\necho "usage: %s SECONDS COMMAND"\nexit 0\n' "$stub" > "$TMP/stub/$stub"
  chmod +x "$TMP/stub/$stub"
done
set +e
OUT="$(PATH="$TMP/stub:$PATH" "$AUDIT" --scope "docs/" --dry-run --timeout-seconds 30 -- "${AGENT_ARGV[@]}" 2>&1)"; RC=$?
set -e
if [[ "$RC" -eq 0 ]] \
   && grep -q "cooperative timeout" <<<"$OUT" \
   && grep -q "cooperative fallback (unenforced)" <<<"$OUT"; then
  pass "without GNU timeout the run reports the cooperative fallback instead of claiming a bound"
else
  fail "the cooperative-fallback path was not reported (rc=$RC): $OUT"
fi
rm -rf "$TMP/stub"
reset_runs

if [[ "$FAILED" -eq 0 ]]; then
  echo "audit harness: GREEN"
  exit 0
else
  echo "audit harness: RED" >&2
  exit 1
fi
