#!/usr/bin/env bash
#
# wgm/test-check-evals.sh — deterministic backpressure for scripts/check-evals.sh.
#
# A schema gate that never fails is indistinguishable from no gate, so this harness proves
# check-evals.sh actually fails closed on each drift class it claims to catch:
#   1. the real fixture still passes (no false positive);
#   2. default discovery reaches the rugged companion fixture;
#   3. an unexpected top-level key fails — including one containing punctuation;
#   4. an unexpected per-case key fails — including one containing a digit;
#   5. a missing required field still fails;
#   6. assertions must actually be an array;
#   7. the ruggedness-gate lifecycle cases stay in wgm's own fixture, one per distinction.
#
# (3) and (4) are the [learn] issue #86 class: an identifier-shaped regex would skip exactly those
# keys, so the gate must read the key set structurally instead.
#
# (7) exists because the ruggedness gate is a wgm protocol requirement (SKILL.md, "The ruggedness
# gate"), and a protocol requirement with no fixture coverage silently decays into a suggestion: the
# schema gate alone would happily pass a fixture from which every rugged case had been deleted.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-evals.sh"
FIXTURE="$ROOT/evals/evals.json"

FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not found on PATH (see CONTRIBUTING.md's Dev prerequisites)" >&2
  echo "check-evals harness: RED" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_on() {  # $1 = fixture path; sets OUT/RC without tripping set -e
  OUT="$(WGM_EVALS_FIXTURE="$1" bash "$CHECK" 2>&1)"; RC=$?
}

run_all() {  # exercise the real repository-discovery branch
  OUT="$(cd "$ROOT" && env -u WGM_EVALS_FIXTURE bash "$CHECK" 2>&1)"; RC=$?
}

# 1) the shipped fixture is green
run_on "$FIXTURE"
if [[ "$RC" -eq 0 ]]; then
  pass "the shipped evals fixture passes the schema gate"
else
  fail "the shipped fixture unexpectedly failed the gate: $OUT"
fi

# 2) default discovery reaches the rugged companion fixture
run_all
if [[ "$RC" -eq 0 ]] && grep -q "companions/rugged/evals/evals.json schema valid" <<<"$OUT"; then
  pass "default discovery validates the rugged companion fixture"
else
  fail "default discovery skipped or failed the rugged companion fixture (rc=$RC): $OUT"
fi

# 3) an unexpected top-level key with punctuation is rejected
jq '. + {"x-drift": 1}' "$FIXTURE" > "$TMP/top.json"
run_on "$TMP/top.json"
if [[ "$RC" -ne 0 ]] && grep -q "unexpected top-level key: 'x-drift'" <<<"$OUT"; then
  pass "an unexpected top-level key containing punctuation is rejected"
else
  fail "punctuation-bearing top-level drift was not rejected (rc=$RC): $OUT"
fi

# 4) an unexpected per-case key containing a digit is rejected
jq '.evals[0] += {"expected_output2": "drift"}' "$FIXTURE" > "$TMP/case.json"
run_on "$TMP/case.json"
if [[ "$RC" -ne 0 ]] && grep -q "unexpected key: 'expected_output2'" <<<"$OUT"; then
  pass "an unexpected per-case key containing a digit is rejected"
else
  fail "digit-bearing per-case drift was not rejected (rc=$RC): $OUT"
fi

# 5) a missing required field is still rejected (the gate's original job)
jq 'del(.evals[0].prompt)' "$FIXTURE" > "$TMP/missing.json"
run_on "$TMP/missing.json"
if [[ "$RC" -ne 0 ]] && grep -q "missing 'prompt'" <<<"$OUT"; then
  pass "a missing required field is rejected"
else
  fail "a missing required field was not rejected (rc=$RC): $OUT"
fi

# 6) assertions must be a non-empty array, not merely a value with a length
jq '.evals[0].assertions = "not-an-array"' "$FIXTURE" > "$TMP/assertions-type.json"
run_on "$TMP/assertions-type.json"
if [[ "$RC" -ne 0 ]] && grep -q "'assertions' must be a non-empty array" <<<"$OUT"; then
  pass "a non-array assertions value is rejected"
else
  fail "a non-array assertions value was not rejected (rc=$RC): $OUT"
fi

# 7) the ruggedness-gate lifecycle cases stay in wgm's own fixture — one case per distinction the
# gate has to make. The schema gate cannot see this: a fixture with every rugged case deleted is
# still schema-valid, which would let a mandatory protocol gate (SKILL.md, "The ruggedness gate")
# decay into an untested suggestion. Each id below covers a distinct behavior: a RUGGED Plan-exit,
# FRAGILE blocking with a remediation task, UNKNOWN blocking with a validation-signal task, the
# Quick-track inline rubric, the missing-companion fallback, and refusal of a lifecycle bypass.
RUGGED_CASE_IDS=(
  plan-exit-rugged-gate-rugged
  rugged-fragile-blocks-plan-exit
  rugged-unknown-blocks-with-validation-task
  quick-track-inline-rugged-gate
  rugged-companion-missing-fallback
  rugged-gate-no-lifecycle-bypass
)
missing_cases=()
for id in "${RUGGED_CASE_IDS[@]}"; do
  jq -e --arg id "$id" 'any(.evals[]; .id == $id)' "$FIXTURE" >/dev/null 2>&1 \
    || missing_cases+=("$id")
done
if (( ${#missing_cases[@]} == 0 )); then
  pass "the ruggedness-gate lifecycle cases are all present in the shipped fixture"
else
  fail "the shipped fixture is missing ruggedness-gate case(s): ${missing_cases[*]}"
fi

# 7b) the cases that define each verdict must assert their specific behavior themselves, so a
# generic enumeration in another assertion cannot keep a blocking behavior test green after it is
# hollowed out.
declare -A RUGGED_CASE_ASSERTIONS=(
  [plan-exit-rugged-gate-rugged]="RUGGED is justified by plan-readiness evidence"
  [rugged-fragile-blocks-plan-exit]="The recorded verdict is FRAGILE and the Plan-exit ruggedness gate item is marked FAIL"
  [rugged-unknown-blocks-with-validation-task]="The recorded verdict is UNKNOWN and the Plan-exit ruggedness gate item is marked FAIL"
)
missing_verdicts=()
for id in "${!RUGGED_CASE_ASSERTIONS[@]}"; do
  assertion="${RUGGED_CASE_ASSERTIONS[$id]}"
  jq -e --arg id "$id" --arg assertion "$assertion" \
    'any(.evals[] | select(.id == $id) | .assertions[]; contains($assertion))' "$FIXTURE" >/dev/null 2>&1 \
    || missing_verdicts+=("$id")
done
if (( ${#missing_verdicts[@]} == 0 )); then
  pass "Plan-exit RUGGED/FRAGILE/UNKNOWN cases each assert their own verdict behavior"
else
  fail "ruggedness case(s) lack their own behavior assertion: ${missing_verdicts[*]}"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "check-evals harness: GREEN"
  exit 0
else
  echo "check-evals harness: RED" >&2
  exit 1
fi
