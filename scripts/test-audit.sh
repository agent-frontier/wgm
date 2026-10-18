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
export HOME="$TMP/home"
mkdir -p "$HOME"
VALID_REPORT="$TMP/valid-report.md"

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
# Ignored paths, so the harness can prove that "not in git status" is not the same as "not a change":
# a role writing here is still writing to the operator's tree. build/cache.bin is pre-created and
# committed to nothing — it exists before the audit starts, which is the case a path-list-only guard
# gets wrong: the path is there before AND after, so only its CONTENT can betray an overwrite.
printf '/build/\n.env\n' > .gitignore

# A holdout scenario with a canary string. audit.sh must never read, name, or modify it: holdout
# scenarios belong to wgm-validator alone, and an audit that leaked them would contaminate the
# holdout (references/scenarios.md).
mkdir -p scenarios
printf 'id: s1\nprompt: CANARY-HOLDOUT-DO-NOT-LEAK\n' > scenarios/holdout.yaml
SCEN_SUM="$(cksum scenarios/holdout.yaml)"

git add -A && git commit -qm seed
SEED="$(git rev-parse HEAD)"

mkdir -p build notes
printf 'ORIGINAL\n' > build/cache.bin
printf 'SECRET=original\n' > .env
# Untracked but NOT ignored, and created after the seed commit so it stays that way. git reports it
# as `?? notes/scratch.txt` before AND after an overwrite — the path never changes — so this is the
# file that proves a path-list guard is not enough for untracked content either.
printf 'ORIGINAL-SCRATCH\n' > notes/scratch.txt
restore_side_files() {  # put the pre-existing ignored/untracked fixtures back between cases
  # Self-healing on purpose: the role-commit case runs `git add -A`, which sweeps the untracked
  # fixture into its commit, and the `git reset --hard` that undoes that commit then deletes the
  # file. A fixture that quietly stays missing would make the untracked-overwrite case vacuous.
  mkdir -p build notes
  printf 'ORIGINAL\n' > build/cache.bin
  printf 'SECRET=original\n' > .env
  printf 'ORIGINAL-SCRATCH\n' > notes/scratch.txt
  rm -f build/new-artifact.txt
}

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
#                    `git status` clean: commit it, stash it, or overwrite an existing
#                    ignored file. FAKE_IGNORED_NEW_ROLE creates a new ignored file, and
#                    FAKE_UNTRACKED_ROLE appends to an existing untracked non-ignored one.
#   FAKE_FLAKY_ROLE  this role fails its FIRST attempt only, then succeeds (for the retry path)
#   FAKE_STDIN       read the prompt from stdin instead of "$1"
# The writer retains all four persona sections; FAKE_THIN_WRITER and FAKE_WRITER_KEYWORDS exercise
# incomplete reports. Optional mutations and resource checks below are confined to this sandbox.
cat > "$TMP/fake-agent.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
role="${WGM_AUDIT_ROLE:-unknown}"
if [[ "${FAKE_STDIN:-0}" == "1" ]]; then prompt="$(cat)"; else prompt="${1:-}"; fi
printf '%s\n' "$role" >> "$FAKE_LOG"
printf '%s' "$prompt" > "${FAKE_PROMPT_DIR}/${role}.prompt"
if [[ -n "${FAKE_EXPECT_ROOT:-}" ]]; then
  # Read the actual installed resources, not similarly named files in the audited project.
  check_resource() {
    local label="$1" relative="$2" resource
    resource="$(sed -n "s/^${label}: //p" <<<"$prompt")"
    [[ "$resource" == "$FAKE_EXPECT_ROOT/$relative" && -r "$resource" ]] \
      && cmp -s "$resource" "$FAKE_SOURCE_ROOT/$relative" || {
        echo "fake agent: wrong or unreadable ${label}: $resource" >&2; exit 8;
      }
  }
  check_resource "Role brief" ".github/agents/${role}.agent.md"
  check_resource "Discipline" "references/docs-audit.md"
  if [[ "$role" == wgm-docs-writer ]]; then
    check_resource "Report shape" "assets/docs-audit-report.template.md"
  fi
  printf '%s\n' "$role" >> "$FAKE_RESOURCE_LOG"
fi
if [[ "${FAKE_MUTATE_ROLE:-}" == "$role" ]]; then
  if [[ "${FAKE_MUTATE_KIND:-}" == delete ]]; then
    rm -f "$FAKE_MUTATE_PATH"
  else
    mkdir -p "$(dirname "$FAKE_MUTATE_PATH")"
    printf 'APPENDED by %s\n' "$role" >> "$FAKE_MUTATE_PATH"
  fi
  if [[ "${FAKE_MUTATE_STAGE:-0}" == 1 ]]; then git add -f -- "$FAKE_MUTATE_PATH"; fi
fi
if [[ "${FAKE_SCRATCH_ROLE:-}" == "$role" ]]; then
  printf 'run scratch\n' > "${WGM_AUDIT_REPORT_FILE%/*}/extra.txt"
  printf 'lock scratch\n' > .wgm/audit.lock/extra.txt
fi
if [[ "${FAKE_HOLDOUT_ROLE:-}" == "$role" ]]; then
  # Synthetic holdouts only: writes expose an accidental status/diff/content read by the guard.
  for prefix in scenarios .wgm/scenarios; do
    for kind in tracked untracked ignored; do
      printf 'CANARY-HOLDOUT-MUTATION\n' >> "$prefix/$kind.yaml"
    done
    git add -f -- "$prefix/tracked.yaml"
  done
fi
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
  # Overwrite an ignored file that ALREADY existed: the path list is identical before and after.
  printf 'OVERWRITTEN by %s\n' "$role" > build/cache.bin
  printf 'SECRET=exfiltrated-by-%s\n' "$role" > .env
fi
if [[ "${FAKE_UNTRACKED_ROLE:-}" == "$role" ]]; then
  # Append to an untracked, non-ignored file that already existed: `?? notes/scratch.txt` before,
  # `?? notes/scratch.txt` after.
  printf 'APPENDED by %s\n' "$role" >> notes/scratch.txt
fi
if [[ "${FAKE_IGNORED_NEW_ROLE:-}" == "$role" ]]; then
  mkdir -p build
  printf 'written by %s\n' "$role" > build/new-artifact.txt
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
  if [[ -n "${FAKE_WRITER_REPORT:-}" ]]; then
    # Replay the same complete-report fixture through portable and native structural validation.
    body="$(cat "$FAKE_WRITER_REPORT")"
  elif [[ "${FAKE_THIN_WRITER:-0}" == "1" ]]; then
    body="# Docs Audit Report — fake
Everything was fine, nothing else to say."
  else
    body="# Docs Audit Report — fake stamp — fake slug

Overall verdict: ${FAKE_VERDICT:-GREEN}

## Persona findings

$(for persona in wgm-docs-junior wgm-docs-senior wgm-docs-principal wgm-docs-pm; do
  cat "${WGM_AUDIT_REPORT_FILE%/*}/${persona}.md"
  printf '\n'
done)

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
  if [[ "${FAKE_WRITER_KEYWORDS:-0}" == 1 ]]; then
    body="$(sed -E 's/^### (Agent actions|Operator actions|Rejected findings|Dissent)$/\1/' <<<"$body")"
  fi
else
  body="### ${role} — fake lens
| Doc | Observation | Severity | Recommended action |
|---|---|---|---|
| README.md | fake finding from ${role} | ${FAKE_VERDICT:-GREEN} | none |"
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

reset_runs() {  # drop reports + working dirs between tests, and restore the side-file fixtures
  rm -rf docs/audit .wgm
  git checkout -q -- README.md docs/README.md 2>/dev/null || true
  restore_side_files
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
   && grep -q "audit: COMPLETE" <<<"$OUT" \
   && ! grep -q "audit: GREEN" <<<"$OUT"; then
  pass "four personas run, the writer runs last, and one consolidated report is written"
else
  fail "happy path did not produce the expected order/report (rc=$RC, order='$ORDER'): $OUT"
fi
if [[ -f "${REPORTS[0]}" ]]; then cp "${REPORTS[0]}" "$VALID_REPORT"; fi

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
   && grep -qE "no '.*' section" <<<"$OUT" \
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

# 15c) A role that CREATES an ignored path never appears in a default `git status` at all. It is
#      still the operator's disk, and a reviewer that writes build output is not read-only.
FAKE_IGNORED_NEW_ROLE=wgm-docs-principal run --scope "docs/" --slug roleignored --retries 1 --retry-delay 0 -- "${AGENT_ARGV[@]}"
tries="$(count_role wgm-docs-principal)"
if [[ "$RC" -ne 0 ]] \
   && [[ "$tries" -eq 1 ]] \
   && ! grep -q "attempt 2/" <<<"$OUT" \
   && ! grep -q "wgm-docs-writer" "$FAKE_LOG" \
   && [[ -f build/new-artifact.txt ]] \
   && ! git status --porcelain --untracked-files=all | grep -q 'build/new-artifact.txt' \
   && [[ ! -d docs/audit ]]; then
  pass "a role that creates a gitignored path is caught even though git status stays clean"
else
  fail "an ignored-path creation was not detected (rc=$RC, attempts=$tries)"
fi
restore_side_files
reset_runs

# 15c-0) The harder half, and the one a path-list guard gets wrong: OVERWRITING an ignored file that
#        already existed. `git status --ignored` says the same thing before and after — the path is
#        there, it was there — so only a content fingerprint can see it. This is not academic:
#        .env, .envrc, and cached build artifacts are all ignored, all present, and all worth
#        overwriting from an agent's point of view.
FAKE_IGNORED_ROLE=wgm-docs-senior run --scope "docs/" --slug ignoredoverwrite --retries 1 --retry-delay 0 -- "${AGENT_ARGV[@]}"
tries="$(count_role wgm-docs-senior)"
if [[ "$RC" -ne 0 ]] \
   && [[ "$tries" -eq 1 ]] \
   && ! grep -q "attempt 2/" <<<"$OUT" \
   && grep -q "origin unknown" <<<"$OUT" \
   && grep -qE '^[[:space:]]*\+ignored: .*(build/cache\.bin|\.env)' <<<"$OUT" \
   && ! grep -q "wgm-docs-writer" "$FAKE_LOG" \
   && grep -q "OVERWRITTEN by wgm-docs-senior" build/cache.bin \
   && grep -q "exfiltrated-by-wgm-docs-senior" .env \
   && ! git status --porcelain --untracked-files=all | grep -qE 'build/cache\.bin|^.. \.env$' \
   && [[ ! -d docs/audit ]]; then
  pass "overwriting an existing ignored file (.env, build cache) is caught by content, terminally"
else
  fail "an ignored-file overwrite was not detected (rc=$RC, attempts=$tries): $OUT"
fi
restore_side_files
reset_runs

# 15c-0b) The same hole, one step to the left: a file that is UNTRACKED but not ignored. git reports
#         `?? notes/scratch.txt` before the overwrite and `?? notes/scratch.txt` after, so the status
#         line is identical and only the content fingerprint moves. Not-yet-added scratch files,
#         drafts, and freshly generated output all live here.
FAKE_UNTRACKED_ROLE=wgm-docs-principal run --scope "docs/" --slug untrackedoverwrite --retries 1 --retry-delay 0 -- "${AGENT_ARGV[@]}"
tries="$(count_role wgm-docs-principal)"
if [[ "$RC" -ne 0 ]] \
   && [[ "$tries" -eq 1 ]] \
   && ! grep -q "attempt 2/" <<<"$OUT" \
   && grep -q "origin unknown" <<<"$OUT" \
   && grep -qE '^[[:space:]]*\+untracked: .*notes/scratch\.txt' <<<"$OUT" \
   && ! grep -qE '^[[:space:]]*[-+]status: \?\? notes/scratch\.txt' <<<"$OUT" \
   && ! grep -q "wgm-docs-writer" "$FAKE_LOG" \
   && grep -q "APPENDED by wgm-docs-principal" notes/scratch.txt \
   && [[ ! -d docs/audit ]]; then
  pass "overwriting an existing untracked non-ignored file is caught by content, not by its ?? line"
else
  fail "an untracked-file overwrite was not detected (rc=$RC, attempts=$tries): $OUT"
fi
restore_side_files
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

# 15d) Only this run's work directory and lock are exempt, or every run would fail on its own writes.
FAKE_SCRATCH_ROLE=wgm-docs-junior run --scope "docs/" --slug selfscratch --keep -- "${AGENT_ARGV[@]}"
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

# 20) Exercise the published downstream ignore block, not a second hand-maintained policy.
# Durable artifacts must be trackable in BOTH layouts, while explicit runtime scratch stays local.
retention="$TMP/retention"
git init -q "$retention"
awk '/^```gitignore$/ { copying=1; next } copying && /^```$/ { exit } copying' \
  "$ROOT/docs/reference/artifacts.md" > "$retention/.gitignore"
retention_ok=1
for path in IMPLEMENTATION_PLAN.md specs/slice.md docs/audit/report.md \
    .wgm/IMPLEMENTATION_PLAN.md .wgm/specs/slice.md .wgm/docs/audit/report.md; do
  if git -C "$retention" check-ignore -q "$path"; then retention_ok=0; fi
done
for path in .wgm/memories.md .wgm/metrics.tsv .wgm/audit.lock/owner .wgm/audit-run-old/report.md; do
  git -C "$retention" check-ignore -q "$path" || retention_ok=0
done
if [[ "$retention_ok" -eq 1 ]]; then
  pass "published ignore rules retain downstream plans/specs/audits and exclude explicit scratch"
else
  fail "published ignore rules hide durable artifacts or fail to exclude runtime scratch"
fi

# 21) A .wgm prefix does not make plans/specs/audits disposable. Include pre-existing staged
# changes: an in-place index overwrite keeps the same status line and needs the diff-content hash.
for tracking in tracked untracked ignored; do
  for mutation in overwrite delete create; do
    case "$tracking" in
      tracked) path=.wgm/IMPLEMENTATION_PLAN.md ;;
      untracked) path=.wgm/specs/slice.md ;;
      ignored) path=.wgm/docs/audit/prior.md; printf '/.wgm/\n' >> .git/info/exclude ;;
    esac
    mkdir -p "$(dirname "$path")"
    printf 'ORIGINAL\n' > "$path"
    stage=0
    if [[ "$tracking" == tracked ]]; then git add -f -- "$path"; stage=1; fi
    if [[ "$mutation" == create ]]; then rm -f "$path"; fi
    FAKE_MUTATE_ROLE=wgm-docs-junior FAKE_MUTATE_PATH="$path" FAKE_MUTATE_KIND="$mutation" \
      FAKE_MUTATE_STAGE="$stage" run --slug durable --retries 1 --retry-delay 0 -- "${AGENT_ARGV[@]}"
    # An already-staged overwrite changes only the content hash, not the name/status line.
    evidence="$path"
    if [[ "$tracking" == tracked && "$mutation" == overwrite ]]; then evidence="staged-content:"; fi
    retained=0
    if [[ "$mutation" == delete ]]; then
      [[ ! -e "$path" ]] && retained=1
    elif grep -q "APPENDED by wgm-docs-junior" "$path"; then retained=1; fi
    if [[ "$RC" -eq 1 && "$(count_role wgm-docs-junior)" -eq 1 ]] \
       && [[ "$retained" -eq 1 ]] \
       && grep -q "origin unknown" <<<"$OUT" && grep -qF "$evidence" <<<"$OUT" \
       && ! grep -q "wgm-docs-writer" "$FAKE_LOG" && [[ ! -d docs/audit ]]; then
      pass "$tracking durable .wgm $mutation is terminal, visible, and never retried"
    else
      fail "$tracking durable .wgm $mutation lacked terminal/retained evidence (rc=$RC): $OUT"
    fi
    git reset -q "$SEED" -- .wgm
    rm -f .git/info/exclude
    reset_runs
  done
done

# Kept runs and similarly named directories are not owned by the current dispatcher. Nor is a
# nested directory named scenarios a root holdout: an over-broad glob would hide real project data.
for path in .wgm/audit-run-kept/report.md .wgm/audit.lock-other/report.md notes/scenarios/data.md; do
  mkdir -p "$(dirname "$path")"
  printf 'ORIGINAL\n' > "$path"
  FAKE_MUTATE_ROLE=wgm-docs-junior FAKE_MUTATE_PATH="$path" \
    run --slug lookalike -- "${AGENT_ARGV[@]}"
  if [[ "$RC" -eq 1 ]] && grep -qF "$path" <<<"$OUT"; then
    pass "lookalike path stays mutation-guarded: $path"
  else
    fail "lookalike path escaped the guard: $path (rc=$RC)"
  fi
  rm -f "$path"
  reset_runs
done

# 22) Synthetic tracked (staged AND unstaged), untracked, and ignored holdouts in both layouts.
# Instrument cksum so even an unchanged holdout read is detected; inspect saved snapshots too,
# because excluding fingerprints alone still leaks tracked holdouts through status/diff commands.
mkdir -p "$TMP/hash-bin" scenarios .wgm/scenarios
export REAL_CKSUM
REAL_CKSUM="$(command -v cksum)"
export FAKE_HASH_LOG="$TMP/hash.log"
: > "$FAKE_HASH_LOG"
cat > "$TMP/hash-bin/cksum" <<'HASH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$FAKE_HASH_LOG"
if [[ "$#" -eq 0 ]]; then
  content="$(cat)"
  if [[ "$content" == *CANARY-HOLDOUT* ]]; then printf 'HOLDOUT-DIFF-READ\n' >> "$FAKE_HASH_LOG"; fi
  printf '%s' "$content" | "$REAL_CKSUM"
else
  exec "$REAL_CKSUM" "$@"
fi
HASH
chmod +x "$TMP/hash-bin/cksum"
for prefix in scenarios .wgm/scenarios; do
  for kind in tracked untracked ignored; do printf 'CANARY-HOLDOUT-BASELINE\n' > "$prefix/$kind.yaml"; done
  printf '/%s/ignored.yaml\n' "$prefix" >> .git/info/exclude
  git add -f -- "$prefix/tracked.yaml"
  printf 'CANARY-HOLDOUT-UNSTAGED\n' >> "$prefix/tracked.yaml"
done
PATH="$TMP/hash-bin:$PATH" FAKE_HOLDOUT_ROLE=wgm-docs-junior \
  run --slug holdout --keep -- "${AGENT_ARGV[@]}"
kept=(.wgm/audit-run-*)
if [[ "$RC" -eq 0 ]] \
   && ! grep -qE 'scenarios/|HOLDOUT-DIFF-READ' "$FAKE_HASH_LOG" \
   && ! grep -qE 'scenarios/|CANARY-HOLDOUT' "${kept[0]}"/state-*.txt; then
  pass "both holdout layouts are excluded from fingerprints, status, and staged/unstaged diffs"
else
  fail "holdouts were read, hashed, or included in the mutation snapshot (rc=$RC)"
fi
git reset -q "$SEED" -- .wgm scenarios
rm -f scenarios/tracked.yaml scenarios/untracked.yaml scenarios/ignored.yaml .git/info/exclude
reset_runs

# 23) Report production succeeding says nothing about the severity of the retained findings.
for verdict in RED AMBER; do
  FAKE_VERDICT="$verdict" run --slug findings -- "${AGENT_ARGV[@]}"
  reports=(docs/audit/*_findings.md)
  if [[ "$RC" -eq 0 && -f "${reports[0]}" ]] \
     && grep -q "Overall verdict: $verdict" "${reports[0]}" \
     && grep -q "audit: COMPLETE" <<<"$OUT" && ! grep -q "audit: GREEN" <<<"$OUT"; then
    pass "$verdict findings allow completed dispatch without a qualitative GREEN banner"
  else
    fail "$verdict findings were confused with dispatch success (rc=$RC)"
  fi
  reset_runs
done
FAKE_WRITER_KEYWORDS=1 run --slug keywords -- "${AGENT_ARGV[@]}"
if [[ "$RC" -eq 1 ]] && grep -q "section" <<<"$OUT" && [[ ! -d docs/audit ]]; then
  pass "portable filing rejects prose keywords in place of required section headings"
else
  fail "portable filing accepted keywords instead of sections (rc=$RC)"
fi
reset_runs

# 24) Native filing uses the very same contract, without an agent, git checkout, lock, or mutation.
# A held lock and deliberately configured fake agent prove that check mode never enters dispatch.
native="$TMP/native reports"
mkdir -p "$native/.wgm/audit.lock"
printf 'native lock sentinel\n' > "$native/.wgm/audit.lock/owner"
native_check() {
  local file="$1" expected="$2" reason="$3" label="${4:-$3}" before after
  before="$(find "$native" -type f -exec cksum {} \; | LC_ALL=C sort)"
  WGM_AGENT="bash $TMP/fake-agent.sh" run_in "$native" --check-report "$file"
  after="$(find "$native" -type f -exec cksum {} \; | LC_ALL=C sort)"
  if [[ "$RC" -eq "$expected" && "$before" == "$after" && ! -s "$FAKE_LOG" ]] \
     && grep -qF "$reason" <<<"$OUT" && ! grep -q "audit: GREEN" <<<"$OUT"; then
    pass "native checker: $label (exit $expected, read-only, no dispatch)"
  else
    fail "native checker ($label): expected $expected / $reason, got $RC: $OUT"
  fi
}
if [[ -f "$VALID_REPORT" ]]; then
  for verdict in GREEN AMBER RED; do
    sed "s/Overall verdict: GREEN/Overall verdict: $verdict/" "$VALID_REPORT" > "$native/report.md"
    native_check "$native/report.md" 0 "structure valid"
  done
  # Template display names and canonical role ids must both be usable by native hosts.
  sed -e 's/wgm-docs-junior/Junior developer/g' -e 's/wgm-docs-senior/Senior developer/g' \
    -e 's/wgm-docs-principal/Principal developer/g' -e 's/wgm-docs-pm/Project manager/g' \
    "$VALID_REPORT" > "$native/report.md"
  native_check "$native/report.md" 0 "structure valid"
  for section in wgm-docs-junior wgm-docs-senior wgm-docs-principal wgm-docs-pm \
      "Consolidated report" "Agent actions" "Operator actions" "Rejected findings" Dissent; do
    # Remove just the heading: surviving prose/keywords must not satisfy a missing section.
    awk -v section="$section" '$0 !~ "^##?#? " section "([[:space:]]|$)"' \
      "$VALID_REPORT" > "$native/report.md"
    native_check "$native/report.md" 1 "section"
    # Keep the heading but remove its body (including nested sections for consolidation).
    awk -v section="$section" '
      /^#+ / {
        match($0, /^#+/); level=RLENGTH
        if (skip && level <= depth) skip=0
        if ($0 ~ "^##?#? " section "([[:space:]]|$)") { print; skip=1; depth=level; next }
      }
      !skip { print }
    ' "$VALID_REPORT" > "$native/report.md"
    native_check "$native/report.md" 1 "section"
  done
  # Empty tables and Markdown examples/comments are not evidence or explicit "none" dispositions.
  sed '/| 1 | fake |/d' "$VALID_REPORT" > "$native/report.md"
  native_check "$native/report.md" 1 "Agent actions"
  for fence in '```markdown' '<!--'; do
    printf '%s\n' "$fence" > "$native/report.md"
    cat "$VALID_REPORT" >> "$native/report.md"
    if [[ "$fence" == '<!--' ]]; then printf '%s\n' '-->'; else printf '%s\n' '```'; fi >> "$native/report.md"
    native_check "$native/report.md" 1 "section"
  done
  : > "$native/report.md"
  native_check "$native/report.md" 1 "empty"
  native_check "$native/missing.md" 1 "missing.md"
  # No WGM_AGENT at all is also valid in check-only mode.
  WGM_AGENT="" run_in "$native" --check-report "$VALID_REPORT"
  if [[ "$RC" -eq 0 && ! -s "$FAKE_LOG" ]]; then pass "native checker needs no configured agent"
  else fail "native checker required an agent (rc=$RC): $OUT"; fi

  # Markdown permits either outer pipe to be omitted. Recognize header/delimiter pairs rather
  # than particular column names: the review blocker was an empty Dissent table accepted as prose.
  # Drive both filing paths with identical fixtures and retain positive data/plain-text controls.
  table_contract_case() {
    local label="$1" body="$2" expected="$3" reason="structure valid"
    local section="${4:-Dissent}"
    local candidate="$native/table.md"
    local -a reports
    [[ "$expected" -eq 0 ]] || reason="empty '$section' section"
    # Replace only the selected section; write body bytes with printf rather than awk -v,
    # which can interpret the very backslash escapes this fixture must preserve.
    awk -v section="$section" '$0 == "### " section { print; exit } { print }' \
      "$VALID_REPORT" > "$candidate"
    printf '%s\n' "$body" >> "$candidate"
    awk -v section="$section" '
      $0 == "### " section { after=1; next }
      after && /^### / { copying=1 }
      copying { print }
    ' "$VALID_REPORT" >> "$candidate"
    native_check "$candidate" "$expected" "$reason" "$label"
    FAKE_WRITER_REPORT="$candidate" run --slug table -- "${AGENT_ARGV[@]}"
    reports=(docs/audit/*_table.md)
    if [[ "$expected" -eq 1 && "$RC" -eq 1 && ! -d docs/audit ]] \
       && grep -qF "$reason" <<<"$OUT"; then
      pass "portable checker: $label (exit 1, no report filed)"
    elif [[ "$expected" -eq 0 && "$RC" -eq 0 && -f "${reports[0]}" ]] \
         && cmp -s "$candidate" "${reports[0]}"; then
      pass "portable checker: $label (exit 0, report retained)"
    else
      fail "portable checker ($label): expected $expected, got $RC: $OUT"
    fi
    reset_runs
  }
  for columns in reported arbitrary; do
    if [[ "$columns" == reported ]]; then
      header="Finding | Persona A view | Persona B view | Preserved as"
      delimiter="--- | --- | --- | ---"
      row="Example | RED | AMBER | Open question"
    else
      header='Perspective \| lens | Resolution'
      delimiter=":--- | ---:"
      row="Both reviewers | Agreement recorded"
    fi
    for edges in outer neither leading trailing; do
      left=""; right=""
      case "$edges" in
        outer) left="| "; right=" |" ;;
        leading) left="| " ;;
        trailing) right=" |" ;;
      esac
      table_body="$(printf '%s%s%s\n%s%s%s\n' "$left" "$header" "$right" "$left" "$delimiter" "$right")"
      table_contract_case "$columns columns, $edges pipes, header only" "$table_body" 1
      table_contract_case "$columns columns, $edges pipes, data row" \
        "$table_body"$'\n'"$left$row$right" 0
    done
  done
  table_contract_case "explicit None disposition" "None." 0
  table_contract_case "plain disposition containing a pipe" "None | all reviewers agree." 0
  table_contract_case "plain pipe disposition before a horizontal rule" $'None | all reviewers agree.\n---' 0
  table_contract_case "plain disposition containing an escaped pipe" $'None \\| all reviewers agree.\n---' 0

  # Occupancy, not the spelling of a header, is the invariant: an escaped-only edge cell must
  # survive masking until border removal. Cover both edges and all four optional-border shapes,
  # varying ordinary punctuation, escaped separators, and escaped backslashes across the matrix.
  for edge in first last; do
    for borders in neither leading trailing outer; do
      left=""; right=""
      case "$borders" in
        neither) escaped='\#' ;;
        leading) escaped='\*'; left="| " ;;
        trailing) escaped='\|'; right=" |" ;;
        outer) escaped="\\\\"; left="| "; right=" |" ;;
      esac
      if [[ "$edge" == first ]]; then
        header="$escaped | Finding | Doc(s) | Action"
      else
        header="Finding | Doc(s) | Action | $escaped"
      fi
      table_body="$(printf '%s%s%s\n%s%s%s\n' "$left" "$header" "$right" \
        "$left" '--- | --- | --- | ---' "$right")"
      table_contract_case "escaped-only $edge cell ($escaped), $borders borders" \
        "$table_body" 1 "Agent actions"
      table_contract_case "escaped-only $edge cell ($escaped), $borders borders, data row" \
        "$table_body"$'\n'"${left}1 | Verified finding | README.md | Fix${right}" 0 "Agent actions"
    done
  done
  # Comment redaction precedes the same border removal. It must retain a cell boundary without
  # counting the hidden comment itself as substantive evidence.
  table_contract_case "comment-only last header cell" \
    $'Identifier | Finding | Doc(s) | <!-- reserved -->\n--- | --- | --- | ---' 1 "Agent actions"
  table_contract_case "comment-only last header cell with data row" \
    $'Identifier | Finding | Doc(s) | <!-- reserved -->\n--- | --- | --- | ---\n1 | Verified finding | README.md | Fix' 0 "Agent actions"
  table_contract_case "comment-only section remains empty" "<!-- not a disposition -->" 1 "Agent actions"
  table_contract_case "plain disposition after escape and comment masking" \
    $'\\# None | all reviewers agree. <!-- recorded -->\n---' 0 "Agent actions"
else
  fail "valid report fixture was not produced; native checks cannot run"
fi

# 25) Install the ACTUAL tracked working-tree source, including this diff, through the real
# installer. Never tar/copy the whole checkout: private ignored state and sibling worktrees must
# not be read. Holdouts are explicitly omitted even if tracked. This is fixture preparation, not
# another packaging implementation; install.sh's normal copy supplies the canonical .github roles.
source_tree="$TMP/source with spaces"
install_home="$TMP/home with spaces"
installed="$install_home/.agents/skills/wgm"
mkdir -p "$source_tree" "$install_home"
git -C "$ROOT" ls-files -z -- . ':(top,exclude)scenarios' ':(top,exclude).wgm' \
  | tar -C "$ROOT" --null -T - -cf - | tar -C "$source_tree" -xf -
install_rc=0
install_out="$(HOME="$install_home" WGM_FORCE_WSL=0 bash "$source_tree/scripts/install.sh" \
  --user --client agents --no-windows --no-agents --no-companions --method copy 2>&1)" || install_rc=$?
if [[ "$install_rc" -eq 0 && -f "$installed/scripts/audit.sh" && ! -e "$installed/.wgm" \
    && ! -e "$installed/scenarios" ]]; then
  export FAKE_RESOURCE_LOG="$TMP/resources.log"
  : > "$FAKE_RESOURCE_LOG"
  FAKE_EXPECT_ROOT="$installed" FAKE_SOURCE_ROOT="$source_tree" AUDIT="$installed/scripts/audit.sh" \
    run --slug installed -- "${AGENT_ARGV[@]}"
  if [[ "$RC" -eq 0 && "$(wc -l < "$FAKE_RESOURCE_LOG")" -eq 5 \
      && ! -e .github/agents && ! -e references && ! -e assets ]]; then
    pass "five fake roles read real installed canonical resources through paths with spaces"
  else
    fail "installed dispatch used target-relative or missing resources (rc=$RC): $OUT"
  fi
  reset_runs
  # Every mandatory resource is a pre-dispatch requirement, including roles scheduled last.
  for resource in .github/agents/wgm-docs-{junior,senior,principal,pm,writer}.agent.md \
      references/docs-audit.md assets/docs-audit-report.template.md; do
    mv "$installed/$resource" "$installed/$resource.saved"
    AUDIT="$installed/scripts/audit.sh" run --slug missing -- "${AGENT_ARGV[@]}"
    mv "$installed/$resource.saved" "$installed/$resource"
    if [[ "$RC" -eq 2 && ! -s "$FAKE_LOG" && ! -e .wgm/audit.lock && ! -d docs/audit ]] \
       && grep -qF "$installed/$resource" <<<"$OUT"; then
      pass "missing installed resource is named before any dispatch: $resource"
    else
      fail "missing resource was silently downgraded or dispatched: $resource (rc=$RC)"
    fi
    reset_runs
  done
else
  fail "isolated real-source install failed or copied excluded state (rc=$install_rc): $install_out"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "audit harness: GREEN"
  exit 0
else
  echo "audit harness: RED" >&2
  exit 1
fi
