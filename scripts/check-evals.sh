#!/usr/bin/env bash
#
# wgm/check-evals.sh — deterministic backpressure for the evals/ self-test fixture.
#
# Verifies evals/evals.json is structurally sound: valid JSON, a non-empty top-level "skill_name",
# and every test case carries id + prompt + expected_output + a non-empty assertions array. This is
# schema validation only — it does not run the evals (no live agent-skill host is wired into this
# repo to do that yet; see references/evals.md for what running them by hand looks like). Mirrors
# the honesty scoping of references/trigger-eval.md's structural check: real, runnable backpressure
# for the fixture's shape, not a substitute for actually executing it.
#
# The key set is allow-listed structurally (jq keys), so an unexpected/renamed field fails the gate
# instead of drifting silently. Point it at another fixture with $WGM_EVALS_FIXTURE.
#
# Exit 0 = green (schema valid). Exit 1 = red (one or more failures, listed).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

FAIL=0
note() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }
ok()   { printf 'ok:   %s\n' "$*"; }

if ! command -v jq >/dev/null 2>&1; then
  note "jq is required but not found on PATH (see CONTRIBUTING.md's Dev prerequisites)"
  echo "evals: RED" >&2
  exit 2
fi

FIXTURE="${WGM_EVALS_FIXTURE:-evals/evals.json}"

if [[ ! -f "$FIXTURE" ]]; then
  note "$FIXTURE is missing"
  echo "evals: RED" >&2
  exit 1
fi

if ! jq empty "$FIXTURE" 2>/dev/null; then
  note "$FIXTURE is not valid JSON"
  echo "evals: RED" >&2
  exit 1
fi

skill_name=$(jq -r '.skill_name // empty' "$FIXTURE")
[[ -n "$skill_name" ]] || note "$FIXTURE missing top-level 'skill_name'"

# Allow-list the schema so an unexpected key is a failure, not silent drift. The key set is read
# structurally with `jq keys` — which yields EVERY key verbatim, including ones containing digits,
# hyphens, or dots — rather than scanned with an identifier-shaped regex, which would quietly skip
# exactly those keys and let a renamed/typo'd field slip through the gate ([learn] issue #86).
TOP_ALLOWED=" _see evals skill_name "
CASE_ALLOWED=" assertions expected_output id prompt "

while IFS= read -r k; do
  [[ -z "$k" ]] && continue
  [[ "$TOP_ALLOWED" == *" $k "* ]] || note "$FIXTURE has an unexpected top-level key: '$k'"
done < <(jq -r 'keys[]' "$FIXTURE" 2>/dev/null)

eval_count=$(jq '.evals | length' "$FIXTURE" 2>/dev/null) || eval_count=0
if (( eval_count == 0 )); then
  note "$FIXTURE has no entries in 'evals'"
else
  for (( idx = 0; idx < eval_count; idx++ )); do
    id=$(jq -r ".evals[$idx].id // empty" "$FIXTURE")
    prompt=$(jq -r ".evals[$idx].prompt // empty" "$FIXTURE")
    expected=$(jq -r ".evals[$idx].expected_output // empty" "$FIXTURE")
    assertions_count=$(jq ".evals[$idx].assertions // [] | length" "$FIXTURE")
    [[ -n "$id" ]]       || note "evals[$idx] missing 'id'"
    [[ -n "$prompt" ]]   || note "evals[$idx] (id=$id) missing 'prompt'"
    [[ -n "$expected" ]] || note "evals[$idx] (id=$id) missing 'expected_output'"
    (( assertions_count > 0 )) || note "evals[$idx] (id=$id) has no assertions"
    while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      [[ "$CASE_ALLOWED" == *" $k "* ]] || note "evals[$idx] (id=$id) has an unexpected key: '$k'"
    done < <(jq -r ".evals[$idx] | keys[]" "$FIXTURE" 2>/dev/null)
  done
fi

if (( FAIL == 0 )); then
  ok "evals fixture schema valid (${eval_count} case(s))"
  echo "evals: GREEN"
  exit 0
else
  echo "evals: RED" >&2
  exit 1
fi
