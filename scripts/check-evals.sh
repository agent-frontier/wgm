#!/usr/bin/env bash
#
# wgm/check-evals.sh — deterministic backpressure for repo eval fixtures.
#
# Verifies evals/evals.json (wgm's own fixture) AND every companions/*/evals/*.json fixture are
# structurally sound: valid JSON, a non-empty top-level "skill_name", and every test case carries
# id + prompt + expected_output + a non-empty assertions array. This is schema validation only — it
# does not run the evals (no live agent-skill host is wired into this repo to do that yet; see
# references/evals.md for what running them by hand looks like). Mirrors the honesty scoping of
# references/trigger-eval.md's structural check: real, runnable backpressure for the fixture's
# shape, not a substitute for actually executing it.
#
# The key set is allow-listed structurally (jq keys), so an unexpected/renamed field fails the gate
# instead of drifting silently. Point it at exactly one fixture with $WGM_EVALS_FIXTURE (used by
# scripts/test-check-evals.sh so it can probe drift cases without also re-checking every companion).
#
# Exit 0 = green (all fixtures schema-valid). Exit 1 = red (one or more failures, listed).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

FAIL=0
note() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
ok()   { printf 'ok:   %s\n' "$*"; }

if ! command -v jq >/dev/null 2>&1; then
  note "jq is required but not found on PATH (see CONTRIBUTING.md's Dev prerequisites)"
  echo "evals: RED" >&2
  exit 2
fi

# $WGM_EVALS_FIXTURE pins the check to exactly one fixture (the test harness's drift probes rely on
# this). Otherwise check every fixture in the repo: wgm's own plus each companion's.
if [[ -n "${WGM_EVALS_FIXTURE:-}" ]]; then
  FIXTURES=("$WGM_EVALS_FIXTURE")
else
  FIXTURES=("evals/evals.json")
  shopt -s nullglob
  COMPANION_FIXTURES=(companions/*/evals/*.json)
  shopt -u nullglob
  if (( ${#COMPANION_FIXTURES[@]} > 0 )); then
    FIXTURES+=("${COMPANION_FIXTURES[@]}")
  fi
fi

# Allow-list the schema so an unexpected key is a failure, not silent drift. The key set is read
# structurally with `jq keys` — which yields EVERY key verbatim, including ones containing digits,
# hyphens, or dots — rather than scanned with an identifier-shaped regex, which would quietly skip
# exactly those keys and let a renamed/typo'd field slip through the gate ([learn] issue #86).
TOP_ALLOWED=" _see evals skill_name "
CASE_ALLOWED=" assertions expected_output id prompt "

TOTAL_CASES=0
for FIXTURE in "${FIXTURES[@]}"; do
  fixture_failures_before=$FAIL
  if [[ ! -f "$FIXTURE" ]]; then
    note "$FIXTURE is missing"
    continue
  fi

  if ! jq empty "$FIXTURE" 2>/dev/null; then
    note "$FIXTURE is not valid JSON"
    continue
  fi

  skill_name=$(jq -r '.skill_name // empty' "$FIXTURE")
  [[ -n "$skill_name" ]] || note "$FIXTURE missing top-level 'skill_name'"

  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    [[ "$TOP_ALLOWED" == *" $k "* ]] || note "$FIXTURE has an unexpected top-level key: '$k'"
  done < <(jq -r 'keys[]' "$FIXTURE" 2>/dev/null)

  evals_type=$(jq -r 'if type == "object" and has("evals") then (.evals | type) else "missing" end' "$FIXTURE")
  if [[ "$evals_type" != "array" ]]; then
    note "$FIXTURE top-level 'evals' must be a non-empty array"
    continue
  fi

  eval_count=$(jq '.evals | length' "$FIXTURE")
  if (( eval_count == 0 )); then
    note "$FIXTURE has no entries in 'evals'"
  else
    for (( idx = 0; idx < eval_count; idx++ )); do
      id=$(jq -r ".evals[$idx].id // empty" "$FIXTURE")
      prompt=$(jq -r ".evals[$idx].prompt // empty" "$FIXTURE")
      expected=$(jq -r ".evals[$idx].expected_output // empty" "$FIXTURE")
      assertions_type=$(jq -r ".evals[$idx] | if type == \"object\" and has(\"assertions\") then (.assertions | type) else \"missing\" end" "$FIXTURE")
      if [[ "$assertions_type" == "array" ]]; then
        assertions_count=$(jq ".evals[$idx].assertions | length" "$FIXTURE")
      else
        assertions_count=0
      fi
      [[ -n "$id" ]]       || note "$FIXTURE evals[$idx] missing 'id'"
      [[ -n "$prompt" ]]   || note "$FIXTURE evals[$idx] (id=$id) missing 'prompt'"
      [[ -n "$expected" ]] || note "$FIXTURE evals[$idx] (id=$id) missing 'expected_output'"
      [[ "$assertions_type" == "array" ]] || note "$FIXTURE evals[$idx] (id=$id) 'assertions' must be a non-empty array"
      (( assertions_count > 0 )) || note "$FIXTURE evals[$idx] (id=$id) has no assertions"
      while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        [[ "$CASE_ALLOWED" == *" $k "* ]] || note "$FIXTURE evals[$idx] (id=$id) has an unexpected key: '$k'"
      done < <(jq -r ".evals[$idx] | keys[]" "$FIXTURE" 2>/dev/null)
    done
    TOTAL_CASES=$(( TOTAL_CASES + eval_count ))
  fi
  if (( FAIL == fixture_failures_before )); then
    ok "$FIXTURE schema valid (${eval_count} case(s))"
  fi
done

if (( FAIL == 0 )); then
  ok "evals fixtures schema valid (${#FIXTURES[@]} fixture(s), ${TOTAL_CASES} case(s) total)"
  echo "evals: GREEN"
  exit 0
else
  echo "evals: RED" >&2
  exit 1
fi
