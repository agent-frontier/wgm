#!/usr/bin/env bash
#
# wgm/test-stage10-experiments.sh — deterministic backpressure for Stage 10 experiment governance.
#
# The fixture proves frozen-baseline comparison, explicit metric direction, required holdout/gate
# evidence, changed-file scope, negative-result retention, two-retirement economy, input redaction,
# output confinement, and the no-merge/no-provider authority boundary. It never creates branches or
# calls a model.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPERIMENTS="$ROOT/scripts/stage10_experiments.py"
FAILED=0
PASSED=0
pass() { printf 'ok:   %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

[[ -f "$EXPERIMENTS" ]] || { fail "missing $EXPERIMENTS"; exit 1; }
command -v python3 >/dev/null 2>&1 || { fail "python3 is required"; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wgm-stage10-experiments.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
mkdir -p "$PROJECT/.wgm/stage10/experiments" "$PROJECT/src"
printf '# experiment fixture\n' >"$PROJECT/README.md"
printf 'print("candidate")\n' >"$PROJECT/src/example.py"

cat >"$PROJECT/experiment.json" <<'EOF'
{
  "hypothesis": "fixture candidate improves quality",
  "baseline_sha": "0123456789abcdef0123456789abcdef01234567",
  "route": "fixture-route",
  "environment": {"kind": "offline-fixture", "warm": false},
  "allowed_files": ["src/example.py"],
  "evaluator": "fixture-evaluator-v1",
  "target_metric": "quality",
  "metric_direction": "max",
  "non_regression": ["tests", "holdout"],
  "budget": {"seconds": 10, "cost_units": 0},
  "retirements": [
    {"retired": "old-route", "evidence": ["test:old-route"]},
    {"retired": "duplicate-view", "evidence": ["review:consolidation"]}
  ],
  "candidates": [
    {
      "id": "winner",
      "branch": "candidate-winner",
      "metric": 9,
      "holdout_pass": true,
      "gates": [{"name": "tests", "passed": true}],
      "changed_files": ["src/example.py"],
      "evidence": ["run:winner", "run:winner-repeat"]
    },
    {
      "id": "regression",
      "branch": "candidate-regression",
      "metric": 99,
      "holdout_pass": false,
      "gates": [{"name": "tests", "passed": false}],
      "changed_files": ["src/example.py"],
      "evidence": ["run:regression"]
    }
  ]
}
EOF

run_experiment() {
  set +e
  OUT="$(PYTHONDONTWRITEBYTECODE=1 python3 "$EXPERIMENTS" "$@" 2>&1)"
  RC=$?
  set -e
}

# 1) A comparison writes a report even when a candidate regresses, but returns nonzero and refuses
# PR eligibility for the batch. The winner remains visible for human diagnosis.
run_experiment compare --root "$PROJECT" --manifest "$PROJECT/experiment.json"
REPORT="$PROJECT/.wgm/stage10/experiments/report.json"
CARD="$PROJECT/.wgm/stage10/experiments/report.md"
if [[ "$RC" -eq 1 ]] && [[ -f "$REPORT" ]] && [[ -f "$CARD" ]] \
   && grep -q 'wrote' <<<"$OUT" \
   && grep -q '"negative_result": true' "$REPORT" \
   && grep -q 'Human review is required' "$CARD"; then
  pass "hard regression is retained and blocks PR recommendation"
else
  fail "regressing candidate was not preserved safely (rc=$RC): $OUT"
fi

# 2) The report proves that the baseline is frozen, the winner is selected using the declared
# direction, economy evidence is present, and every candidate result is traceable.
if PYTHONDONTWRITEBYTECODE=1 python3 - "$REPORT" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["frozen_baseline"] is True
assert result["baseline_sha"] == "0123456789abcdef0123456789abcdef01234567"
assert result["winner"] == "winner"
assert result["pr_recommendation"] is False
assert result["feature_economy"]["eligible"] is True
assert len(result["feature_economy"]["retirements"]) == 2
assert all("evidence" in candidate and "gates" in candidate for candidate in result["candidates"])
assert "no merge" in result["authority"]
PY
then
  pass "baseline, metric direction, candidate evidence, economy, and authority are recorded"
else
  fail "comparison report omitted required provenance or policy fields"
fi

# 3) Missing holdout/gate evidence cannot default to a passing candidate.
printf '%s\n' '{"hypothesis":"bad","baseline_sha":"0123456789abcdef0123456789abcdef01234567","route":"fixture","environment":"offline","allowed_files":["src/example.py"],"evaluator":"e","target_metric":"quality","metric_direction":"max","non_regression":["tests"],"budget":{"seconds":1},"retirements":[{"retired":"one","evidence":["a"]},{"retired":"two","evidence":["b"]}],"candidates":[{"id":"missing","branch":"b","metric":1,"evidence":["run:missing"]}]}' >"$PROJECT/missing-gates.json"
run_experiment compare --root "$PROJECT" --manifest "$PROJECT/missing-gates.json" --output "$PROJECT/.wgm/stage10/experiments/missing.json"
if [[ "$RC" -eq 2 ]] && grep -q 'holdout_pass must be boolean' <<<"$OUT"; then
  pass "missing hard evidence is rejected before comparison"
else
  fail "missing holdout evidence was accepted (rc=$RC): $OUT"
fi

# 4) A changed file outside the declared experiment surface invalidates the candidate.
printf '%s\n' '{"hypothesis":"bad","baseline_sha":"0123456789abcdef0123456789abcdef01234567","route":"fixture","environment":"offline","allowed_files":["src/example.py"],"evaluator":"e","target_metric":"quality","metric_direction":"max","non_regression":["tests"],"budget":{"seconds":1},"retirements":[{"retired":"one","evidence":["a"]},{"retired":"two","evidence":["b"]}],"candidates":[{"id":"outside","branch":"b","metric":1,"holdout_pass":true,"gates":[{"name":"tests","passed":true}],"changed_files":["README.md"],"evidence":["run:outside"]}]}' >"$PROJECT/outside.json"
run_experiment compare --root "$PROJECT" --manifest "$PROJECT/outside.json"
if [[ "$RC" -eq 2 ]] && grep -q 'changed_files must be listed' <<<"$OUT"; then
  pass "candidate changes outside the allowed surface are rejected"
else
  fail "out-of-scope candidate changes were accepted (rc=$RC): $OUT"
fi

# 5) The two-retirement rule is real and a single retirement cannot be padded into eligibility.
python3 - "$PROJECT/experiment.json" "$PROJECT/no-economy.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["candidates"] = [value["candidates"][0]]
value["retirements"] = [{"retired": "one", "evidence": ["a"]}]
json.dump(value, open(sys.argv[2], "w"), sort_keys=True)
PY
run_experiment compare --root "$PROJECT" --manifest "$PROJECT/no-economy.json"
if [[ "$RC" -eq 1 ]] && grep -q 'requires two evidence-backed retirements' "$PROJECT/.wgm/stage10/experiments/report.json"; then
  pass "one retirement blocks PR eligibility"
else
  fail "feature economy allowed an under-retired feature (rc=$RC): $OUT"
fi

# 6) A credential-like manifest value is rejected before any report is written; fixture runs never
# touch the wgm checkout's own experiment output.
printf '%s\n' '{"hypothesis":"token=sk-secret-value","baseline_sha":"0123456789abcdef0123456789abcdef01234567","route":"fixture","environment":"offline","allowed_files":["src/example.py"],"evaluator":"e","target_metric":"quality","metric_direction":"max","non_regression":["tests"],"budget":{"seconds":1},"retirements":[{"retired":"one","evidence":["a"]},{"retired":"two","evidence":["b"]}],"candidates":[{"id":"safe","branch":"b","metric":1,"holdout_pass":true,"gates":[{"name":"tests","passed":true}],"changed_files":["src/example.py"],"evidence":["run:safe"]}]}' >"$PROJECT/secret.json"
run_experiment compare --root "$PROJECT" --manifest "$PROJECT/secret.json" --output "$PROJECT/.wgm/stage10/experiments/secret.json"
if [[ "$RC" -eq 2 ]] && grep -q 'credential-like' <<<"$OUT" \
   && [[ ! -e "$PROJECT/.wgm/stage10/experiments/secret.json" ]] \
   && [[ ! -e "$ROOT/.wgm/stage10/experiments/report.json" ]]; then
  pass "credential-like input is rejected and experiment output stays isolated"
else
  fail "secret or checkout state escaped experiment boundaries (rc=$RC): $OUT"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "stage10 experiments harness: GREEN ($PASSED assertions passed)"
  exit 0
else
  echo "stage10 experiments harness: RED" >&2
  exit 1
fi
