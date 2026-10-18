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
#   8. the evidence-boundary learning cases stay in wgm's own fixture, one per issue.
#   9. the numerical/API/performance learning cases stay in wgm's own fixture, one per issue.
#  10. cleanup guidance preserves tracked history and concurrent edits.
#
# (3) and (4) are the [learn] issue #86 class: an identifier-shaped regex would skip exactly those
# keys, so the gate must read the key set structurally instead.
#
# (7) exists because the ruggedness gate is a wgm protocol requirement (SKILL.md, "The ruggedness
# gate"), and a protocol requirement with no fixture coverage silently decays into a suggestion: the
# schema gate alone would happily pass a fixture from which every rugged case had been deleted.
# (8) is the same limitation for the evidence-boundary lessons: schema-valid JSON says nothing about
# whether the public fixtures that keep those rules visible are still present or still load-bearing.
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
mkdir -p "$TMP/home"
export HOME="$TMP/home"

run_on() {  # $1 = fixture path; sets OUT/RC without tripping set -e
  OUT="$(WGM_EVALS_FIXTURE="$1" bash "$CHECK" 2>&1)"; RC=$?
}

run_all() {  # exercise the real repository-discovery branch
  OUT="$(cd "$ROOT" && env -u WGM_EVALS_FIXTURE bash "$CHECK" 2>&1)"; RC=$?
}

pin_case_ids() {  # $1 = success message; $2 = failure noun; $3... = eval ids
  local success_message="$1"
  local failure_noun="$2"
  shift 2
  local missing=()
  local id
  for id in "$@"; do
    jq -e --arg id "$id" 'any(.evals[]; .id == $id)' "$FIXTURE" >/dev/null 2>&1 \
      || missing+=("$id")
  done
  if (( ${#missing[@]} == 0 )); then
    pass "$success_message"
  else
    fail "the shipped fixture is missing $failure_noun: ${missing[*]}"
  fi
}

pin_case_assertions() {  # $1 = success message; $2 = failure noun; remaining args = id/assertion pairs
  local success_message="$1"
  local failure_noun="$2"
  shift 2
  if (( $# % 2 != 0 )); then
    fail "internal harness bug: pin_case_assertions needs id/assertion pairs"
    return
  fi
  local missing=()
  local id assertion
  while (( $# > 0 )); do
    id="$1"; assertion="$2"; shift 2
    jq -e --arg id "$id" --arg assertion "$assertion" \
      'any(.evals[] | select(.id == $id) | .assertions[]; contains($assertion))' "$FIXTURE" >/dev/null 2>&1 \
      || missing+=("$id")
  done
  if (( ${#missing[@]} == 0 )); then
    pass "$success_message"
  else
    fail "$failure_noun lack their pinned assertion: ${missing[*]}"
  fi
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
pin_case_ids \
  "the ruggedness-gate lifecycle cases are all present in the shipped fixture" \
  "ruggedness-gate case(s)" \
  "${RUGGED_CASE_IDS[@]}"

# 7b) the cases that define each verdict must assert their specific behavior themselves, so a
# generic enumeration in another assertion cannot keep a blocking behavior test green after it is
# hollowed out.
pin_case_assertions \
  "Plan-exit RUGGED/FRAGILE/UNKNOWN cases each assert their own verdict behavior" \
  "ruggedness case(s)" \
  plan-exit-rugged-gate-rugged "RUGGED is justified by plan-readiness evidence" \
  rugged-fragile-blocks-plan-exit "The recorded verdict is FRAGILE and the Plan-exit ruggedness gate item is marked FAIL" \
  rugged-unknown-blocks-with-validation-task "The recorded verdict is UNKNOWN and the Plan-exit ruggedness gate item is marked FAIL"

# 8) the evidence-boundary learning cases stay present. Like the ruggedness pins above, this is not
# behavioral grading: it only prevents the public regression fixtures from silently disappearing while
# the schema gate stays green.
EVIDENCE_CASE_IDS=(
  wsl-consumer-origin-evidence
  offline-proxy-is-not-live-release-evidence
  model-tool-omission-sentinel
  embedded-host-bootstrap-first
  intermediary-shell-semantics
  pinned-sdk-async-boundary
)
pin_case_ids \
  "the evidence-boundary learning cases are all present in the shipped fixture" \
  "evidence-boundary case(s)" \
  "${EVIDENCE_CASE_IDS[@]}"

# 8b) each evidence-boundary case must keep one issue-specific, load-bearing assertion in its own
# assertion list. Presence alone is not enough if the case is hollowed out into generic prose.
pin_case_assertions \
  "evidence-boundary cases each retain their issue-specific load-bearing assertion" \
  "evidence-boundary case(s)" \
  wsl-consumer-origin-evidence "wgm requires a probe that runs on the consumer's OS and declares that origin" \
  offline-proxy-is-not-live-release-evidence "A separate deploy or release check is required before claiming the change is publicly released" \
  model-tool-omission-sentinel "Arbitrary strings such as 'none' are not globally normalized away; invalid input is rejected and legitimate values are preserved" \
  embedded-host-bootstrap-first "The bootstrap proves the loader, listener, and private discovery path" \
  intermediary-shell-semantics "The transformed command is executed under the actual shell with hostile but valid path characters" \
  pinned-sdk-async-boundary "Detached initialization and credential cleanup are covered, not hidden behind synchronous method-level mocks"

# 9) the numerical/API/performance learning cases stay present. This is still fixture-content pinning,
# not behavioral grading: it prevents public regression cases from disappearing or turning generic
# while the schema gate stays green.
NUMERICAL_CASE_IDS=(
  performance-benchmark-semantic-parity
  public-math-api-boundary-contracts
  floating-statistical-tolerance-contracts
)
pin_case_ids \
  "the numerical/API/performance learning cases are all present in the shipped fixture" \
  "numerical/API/performance case(s)" \
  "${NUMERICAL_CASE_IDS[@]}"

# 9b) retain every numerical rule; keeping only the headline loses edge-case protection.
pin_case_assertions \
  "numerical/API/performance cases each retain their issue-specific load-bearing assertion" \
  "numerical/API/performance case(s)" \
  performance-benchmark-semantic-parity "Equivalent semantics and results are established before a timing win is accepted" \
  performance-benchmark-semantic-parity "Warmups and repeated pinned measurements are required instead of a single opportunistic run" \
  performance-benchmark-semantic-parity "Compiler/build mode, dataset/input shape, and environment or semantic caveats are disclosed with the benchmark claim" \
  public-math-api-boundary-contracts "Undefined or out-of-domain inputs are given an explicit public status contract before documentation promises are accepted" \
  public-math-api-boundary-contracts "Deterministic boundary tests are required for the documented edge cases before the API promise is treated as proven" \
  public-math-api-boundary-contracts "Current implementation behavior or a happy-path example is not accepted as the contract by itself" \
  floating-statistical-tolerance-contracts "Floating or statistical outputs are checked against documented absolute and relative tolerances rather than exact decimal strings" \
  floating-statistical-tolerance-contracts "The comparison contract names near-zero handling plus finite/NaN/domain expectations" \
  floating-statistical-tolerance-contracts "Tolerance is derived from the algorithm or API contract, not loosened ad hoc just to make a failing test pass"

# 10) pin every cleanup distinction so a generic "clean tree" assertion cannot erase ownership safety.
pin_case_ids "the cleanup history case is present" "cleanup case(s)" cleanup-preserves-tracked-history
pin_case_assertions \
  "the cleanup case retains its history and ownership safeguards" "cleanup case(s)" \
  cleanup-preserves-tracked-history "Tracked history, ignored generated residue, and unrelated user files are classified before cleanup" \
  cleanup-preserves-tracked-history "Only known run-owned stale generated files are removed; tracked metrics and concurrent user edits are preserved" \
  cleanup-preserves-tracked-history "Recovery uses the recorded pre-run baseline for this run's changes, never a blanket deletion or reset to HEAD"

# Correctness independence and immutable publication cannot become weaker fallback paths. Keep
# every distinction pinned; fixture presence or schema-valid generic prose is not sufficient.
pin_case_ids "the review/history governance cases are present" "governance case(s)" \
  non-author-review-without-native-dispatch published-trailer-forward-only
pin_case_assertions \
  "review/history cases retain non-author blocking and forward-only handling" "governance case(s)" \
  non-author-review-without-native-dispatch "Both correctness-review passes require non-author reviewers via separate fresh invocations or an independent human handoff" \
  non-author-review-without-native-dispatch "Unavailable independent review blocks the gate and done; serial author self-review is not a PASS" \
  non-author-review-without-native-dispatch "Inline ruggedness remains permitted when the companion is missing, and scripts/audit.sh remains the separate docs-audit fallback" \
  published-trailer-forward-only "Published history is preserved: no sibling replacement promotion, force push, or history rewrite" \
  published-trailer-forward-only "The offending SHA and a forward-only correction/attestation are recorded; handoff is blocked pending an explicit maintainer decision with no automatic waiver" \
  published-trailer-forward-only "The trailer checker stays RED for a range containing the original violation even after an attestation"

if [[ "$FAILED" -eq 0 ]]; then
  echo "check-evals harness: GREEN"
  exit 0
else
  echo "check-evals harness: RED" >&2
  exit 1
fi
