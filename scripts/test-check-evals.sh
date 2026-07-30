#!/usr/bin/env bash
#
# wgm/test-check-evals.sh — deterministic backpressure for scripts/check-evals.sh.
#
# A schema gate that never fails is indistinguishable from no gate, so this harness proves
# check-evals.sh actually fails closed on each drift class it claims to catch:
#   1. the real fixture still passes (no false positive);
#   2. an unexpected top-level key fails — including one containing punctuation;
#   3. an unexpected per-case key fails — including one containing a digit;
#   4. a missing required field still fails.
#
# (2) and (3) are the [learn] issue #86 class: an identifier-shaped regex would skip exactly those
# keys, so the gate must read the key set structurally instead.
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

# 1) the shipped fixture is green
run_on "$FIXTURE"
if [[ "$RC" -eq 0 ]]; then
  pass "the shipped evals fixture passes the schema gate"
else
  fail "the shipped fixture unexpectedly failed the gate: $OUT"
fi

# 2) an unexpected top-level key with punctuation is rejected
jq '. + {"x-drift": 1}' "$FIXTURE" > "$TMP/top.json"
run_on "$TMP/top.json"
if [[ "$RC" -ne 0 ]] && grep -q "unexpected top-level key: 'x-drift'" <<<"$OUT"; then
  pass "an unexpected top-level key containing punctuation is rejected"
else
  fail "punctuation-bearing top-level drift was not rejected (rc=$RC): $OUT"
fi

# 3) an unexpected per-case key containing a digit is rejected
jq '.evals[0] += {"expected_output2": "drift"}' "$FIXTURE" > "$TMP/case.json"
run_on "$TMP/case.json"
if [[ "$RC" -ne 0 ]] && grep -q "unexpected key: 'expected_output2'" <<<"$OUT"; then
  pass "an unexpected per-case key containing a digit is rejected"
else
  fail "digit-bearing per-case drift was not rejected (rc=$RC): $OUT"
fi

# 4) a missing required field is still rejected (the gate's original job)
jq 'del(.evals[0].prompt)' "$FIXTURE" > "$TMP/missing.json"
run_on "$TMP/missing.json"
if [[ "$RC" -ne 0 ]] && grep -q "missing 'prompt'" <<<"$OUT"; then
  pass "a missing required field is rejected"
else
  fail "a missing required field was not rejected (rc=$RC): $OUT"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "check-evals harness: GREEN"
  exit 0
else
  echo "check-evals harness: RED" >&2
  exit 1
fi
