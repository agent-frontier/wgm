#!/usr/bin/env bash
#
# wgm/test-check-harnesses.sh — deterministic backpressure for scripts/check-harnesses.sh.
#
# A contract gate that never fails is indistinguishable from the unfalsifiable "runs on any
# compatible agent" claim it replaced, so this harness mutation-tests the checker: it takes the real
# record, breaks exactly one thing, and asserts the gate goes RED with a message naming the defect.
#
#   1. the shipped record passes (no false positive);
#   2. an unsupported status value is rejected — only Verified/Expected/Degraded/Unknown exist;
#   3. a missing discovery path is rejected;
#   4. a Verified entry stripped of its evidence is rejected (the core evidence rule);
#   5. malformed JSON is rejected, not skipped;
#   6. a valid Degraded Pi/Aider-style entry — no subagent primitive, named missing capability and
#      fallback, no journey evidence — is accepted, so "Degraded" stays usable rather than becoming
#      a status nothing can legally hold;
#   7. a missing file fails closed;
#   8. a duplicate harness id is rejected;
#   9. unexpected and missing keys are rejected, including punctuation- and digit-bearing names
#      (the [learn] issue #86 class: an identifier-shaped regex would skip exactly those);
#  10. deleting a harness wgm publishes a claim about is rejected — an inconvenient entry cannot be
#      made to disappear;
#  11. an Expected entry carrying journey evidence is rejected (it is Verified, or it is not real);
#  12. a host with no subagent primitive may not be anything but Degraded;
#  13. a source that is not an https:// URL is rejected;
#  14. the Pi entry keeps the facts wgm publishes about it — Agent Skills native, no built-in
#      subagent primitive, an explicit fallback — since the schema alone would happily pass a
#      record in which those had been quietly softened.
#
# No network and no vendor CLI are required: this tests the gate, not the harnesses.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-harnesses.sh"
RECORD="$ROOT/compatibility/harnesses.json"

FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not found on PATH (see CONTRIBUTING.md's Dev prerequisites)" >&2
  echo "check-harnesses harness: RED" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_on() {  # $1 = record path; sets OUT/RC without tripping set -e
  OUT="$(WGM_HARNESSES="$1" bash "$CHECK" 2>&1)"; RC=$?
}

run_default() {  # exercise the real repository-discovery branch
  OUT="$(cd "$ROOT" && env -u WGM_HARNESSES bash "$CHECK" 2>&1)"; RC=$?
}

expect_red() {  # $1 = label, $2 = expected substring
  if [[ "$RC" -ne 0 ]] && grep -qF "$2" <<<"$OUT"; then
    pass "$1"
  else
    fail "$1 — gate did not fail as expected (rc=$RC): $OUT"
  fi
}

# 1) the shipped record is green through the default path
run_default
if [[ "$RC" -eq 0 ]] && grep -q "harnesses: GREEN" <<<"$OUT"; then
  pass "the shipped harness record passes the contract gate"
else
  fail "the shipped record unexpectedly failed the gate (rc=$RC): $OUT"
fi

# 2) only the four contract statuses exist
jq '(.harnesses[] | select(.id == "claude-code") | .status) = "Supported"' "$RECORD" > "$TMP/status.json"
run_on "$TMP/status.json"
expect_red "an unsupported status value is rejected" "unsupported status: 'Supported'"

# 3) discovery paths must actually be recorded
jq '(.harnesses[] | select(.id == "gemini-cli") | .skill_discovery.paths) = []' "$RECORD" > "$TMP/paths.json"
run_on "$TMP/paths.json"
expect_red "an empty discovery-path list is rejected" "'skill_discovery.paths' must be a non-empty array"

jq 'del(.harnesses[] | select(.id == "gemini-cli") | .skill_discovery.paths)' "$RECORD" > "$TMP/paths-missing.json"
run_on "$TMP/paths-missing.json"
expect_red "a missing discovery-path key is rejected" "skill_discovery is missing required key: 'paths'"

# 4) Verified is the status that has to be earned
jq '(.harnesses[] | select(.id == "copilot-cli") | .evidence) = []' "$RECORD" > "$TMP/no-evidence.json"
run_on "$TMP/no-evidence.json"
expect_red "a Verified entry with no evidence is rejected" "is Verified without journey evidence"

jq '(.harnesses[] | select(.id == "copilot-cli") | .evidence) |= map(select(.kind != "journey"))' "$RECORD" > "$TMP/no-journey.json"
run_on "$TMP/no-journey.json"
expect_red "a Verified entry without an end-to-end journey is rejected" "is Verified without journey evidence"

jq '(.harnesses[] | select(.id == "copilot-cli") | .invocation.verification) = "documented"' "$RECORD" > "$TMP/soft-invocation.json"
run_on "$TMP/soft-invocation.json"
expect_red "a Verified entry whose invocation is merely documented is rejected" "'invocation.verification' is not 'verified'"

# 5) malformed JSON fails closed
printf '{ "harnesses": [ ' > "$TMP/broken.json"
run_on "$TMP/broken.json"
expect_red "malformed JSON is rejected" "is not valid JSON"

# 6) a valid Degraded entry stays legal — the fallback path must remain expressible
jq '(.harnesses[] | select(.id == "aider")) |= (
      .status = "Degraded"
      | .subagents = {"capability": "none", "notes": "No dispatchable subagent primitive is documented."}
      | .missing_capability = "Agent Skills discovery and host-dispatched subagents."
      | .fallback = "Hand the protocol to the model explicitly and run both review passes inline."
      | .evidence = []
    )' "$RECORD" > "$TMP/degraded.json"
run_on "$TMP/degraded.json"
if [[ "$RC" -eq 0 ]]; then
  pass "a valid Degraded entry (no subagents, named missing capability + fallback) is accepted"
else
  fail "a valid Degraded entry was rejected (rc=$RC): $OUT"
fi

# 7) a missing record fails closed rather than passing vacuously
run_on "$TMP/does-not-exist.json"
expect_red "a missing record file fails closed" "is missing"

# 8) duplicate ids are drift, not a merge artifact to tolerate
jq '.harnesses += [(.harnesses[] | select(.id == "pi"))]' "$RECORD" > "$TMP/dupe.json"
run_on "$TMP/dupe.json"
expect_red "a duplicate harness id is rejected" "duplicate harness id: 'pi'"

# 9) unexpected / missing keys — including names a naive identifier regex would skip
jq '. + {"x-drift": 1}' "$RECORD" > "$TMP/top-drift.json"
run_on "$TMP/top-drift.json"
expect_red "an unexpected top-level key containing punctuation is rejected" "top level has an unexpected key: 'x-drift'"

jq '(.harnesses[] | select(.id == "pi")) += {"status2": "Verified"}' "$RECORD" > "$TMP/entry-drift.json"
run_on "$TMP/entry-drift.json"
expect_red "an unexpected per-entry key containing a digit is rejected" "has an unexpected key: 'status2'"

jq 'del(.harnesses[] | select(.id == "pi") | .fallback)' "$RECORD" > "$TMP/missing-key.json"
run_on "$TMP/missing-key.json"
expect_red "a missing required per-entry key is rejected" "is missing required key: 'fallback'"

# 10) a harness wgm publishes a claim about cannot be deleted to tidy the table
jq '.harnesses |= map(select(.id != "windsurf"))' "$RECORD" > "$TMP/deleted.json"
run_on "$TMP/deleted.json"
expect_red "deleting a published harness entry is rejected" "required harness entry is missing: 'windsurf'"

# 11) Expected is contract-fit-but-untested; journey evidence contradicts it
jq '(.harnesses[] | select(.id == "claude-code") | .evidence) = [{"kind":"journey","ref":"somewhere","detail":"a run someone remembers"}]' \
  "$RECORD" > "$TMP/expected-journey.json"
run_on "$TMP/expected-journey.json"
expect_red "an Expected entry carrying journey evidence is rejected" "is Expected but carries journey evidence"

jq '(.harnesses[] | select(.id == "windsurf") | .evidence) = [{"kind":"discovery","ref":"somewhere","detail":"a directory listing"}]' \
  "$RECORD" > "$TMP/unknown-evidence.json"
run_on "$TMP/unknown-evidence.json"
expect_red "an Unknown entry carrying evidence is rejected" "is Unknown but carries evidence"

# 12) a missing host capability must be stated as Degraded, not smoothed into Expected
jq '(.harnesses[] | select(.id == "pi") | .status) = "Expected"' "$RECORD" > "$TMP/none-expected.json"
run_on "$TMP/none-expected.json"
expect_red "a host with no subagent primitive may not be Expected" "must be Degraded with a named fallback"

# 13) sources have to be authoritative URLs, not prose
jq '(.harnesses[] | select(.id == "cursor") | .sources) = ["the vendor told me"]' "$RECORD" > "$TMP/source.json"
run_on "$TMP/source.json"
expect_red "a non-URL source is rejected" "is not an https:// URL"

jq '(.harnesses[] | select(.id == "cursor") | .sources) = []' "$RECORD" > "$TMP/source-empty.json"
run_on "$TMP/source-empty.json"
expect_red "an empty source list is rejected" "'sources' must be a non-empty array"

# 14) the Pi facts wgm publishes are load-bearing: Agent Skills native (so ~/.agents/skills works),
# no built-in subagent primitive, and an explicit fallback. The schema cannot see these — a record
# that had quietly upgraded Pi to Expected-with-subagents would still be schema-valid.
pi_problems=()
jq -e '.harnesses[] | select(.id == "pi") | select(.status == "Degraded")' "$RECORD" >/dev/null 2>&1 \
  || pi_problems+=("pi is no longer recorded as Degraded")
jq -e '.harnesses[] | select(.id == "pi") | select(.subagents.capability == "none")' "$RECORD" >/dev/null 2>&1 \
  || pi_problems+=("pi no longer records the absent subagent primitive")
jq -e '.harnesses[] | select(.id == "pi") | select(.missing_capability | length > 0) | select(.fallback | length > 0)' "$RECORD" >/dev/null 2>&1 \
  || pi_problems+=("pi no longer names both the missing capability and the fallback")
jq -e '.harnesses[] | select(.id == "pi") | select(.skill_discovery.paths | index("~/.agents/skills/"))' "$RECORD" >/dev/null 2>&1 \
  || pi_problems+=("pi no longer records the ~/.agents/skills/ discovery path the installer writes")
if (( ${#pi_problems[@]} == 0 )); then
  pass "the Pi entry keeps its published facts (Agent Skills native, no subagent primitive, explicit fallback)"
else
  fail "the Pi entry drifted: ${pi_problems[*]}"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "check-harnesses harness: GREEN"
  exit 0
else
  echo "check-harnesses harness: RED" >&2
  exit 1
fi
