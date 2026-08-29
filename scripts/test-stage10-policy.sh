#!/usr/bin/env bash
#
# wgm/test-stage10-policy.sh — deterministic backpressure for offline learned-policy comparison.
#
# It proves corroborated-history requirements, identical task pairing, metric direction, per-task
# hard-regression rejection, provenance, unsafe-input refusal, and no automatic activation. It never
# calls a provider or changes policy.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$ROOT/scripts/stage10_policy.py"
FAILED=0
PASSED=0
pass() { printf 'ok:   %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

[[ -f "$POLICY" ]] || { fail "missing $POLICY"; exit 1; }
command -v python3 >/dev/null 2>&1 || { fail "python3 is required"; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wgm-stage10-policy.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
mkdir -p "$PROJECT/.wgm/stage10/routing/policy"
printf '# policy fixture\n' >"$PROJECT/README.md"

cat >"$PROJECT/good.json" <<'EOF'
{
  "policy_name": "learner-v1",
  "incumbent_name": "transparent-v1",
  "learner_name": "learner-v1",
  "metric_direction": "max",
  "history": [
    {"id":"h1","standing":"corroborated","source":"run:h1","evidence":["command:test-1","review:h1"]},
    {"id":"h2","standing":"corroborated","source":"run:h2","evidence":["command:test-2","review:h2"]}
  ],
  "tasks": [
    {"id":"task-one","incumbent":{"route":"safe","value":5,"hard_gate":true,"holdout":true,"evidence":["run:i1"]},"learner":{"route":"fast","value":7,"hard_gate":true,"holdout":true,"evidence":["run:l1"]}},
    {"id":"task-two","incumbent":{"route":"safe","value":4,"hard_gate":true,"holdout":true,"evidence":["run:i2"]},"learner":{"route":"fast","value":6,"hard_gate":true,"holdout":true,"evidence":["run:l2"]}}
  ]
}
EOF
cat >"$PROJECT/sparse.json" <<'EOF'
{
  "policy_name":"learner-v1","incumbent_name":"transparent-v1","learner_name":"learner-v1","metric_direction":"max",
  "history":[{"id":"h1","standing":"validated","source":"run:h1","evidence":["run:h1"]}],
  "tasks":[{"id":"task-one","incumbent":{"route":"safe","value":1,"hard_gate":true,"holdout":true,"evidence":["run:i"]},"learner":{"route":"fast","value":2,"hard_gate":true,"holdout":true,"evidence":["run:l"]}}]
}
EOF
cat >"$PROJECT/regress.json" <<'EOF'
{
  "policy_name":"learner-v1","incumbent_name":"transparent-v1","learner_name":"learner-v1","metric_direction":"max",
  "history":[{"id":"h1","standing":"corroborated","source":"run:h1","evidence":["run:h1"]},{"id":"h2","standing":"corroborated","source":"run:h2","evidence":["run:h2"]}],
  "tasks":[{"id":"task-one","incumbent":{"route":"safe","value":1,"hard_gate":true,"holdout":true,"evidence":["run:i"]},"learner":{"route":"fast","value":99,"hard_gate":false,"holdout":true,"evidence":["run:l"]}}]
}
EOF

run_policy() {
  set +e
  OUT="$(PYTHONDONTWRITEBYTECODE=1 python3 "$POLICY" "$@" 2>&1)"
  RC=$?
  set -e
}

# 1) Corroborated history plus identical task pairs produces a recommendation report and Markdown
# card. The command succeeds only for a policy that improves the declared max metric.
run_policy compare --root "$PROJECT" --manifest "$PROJECT/good.json"
REPORT="$PROJECT/.wgm/stage10/routing/policy/comparison.json"
CARD="$PROJECT/.wgm/stage10/routing/policy/comparison.md"
if [[ "$RC" -eq 0 ]] && [[ -f "$REPORT" ]] && [[ -f "$CARD" ]] \
   && grep -q '"status": "recommend"' "$REPORT" \
   && grep -q 'human-reviewed PR may activate policy' "$REPORT" \
   && grep -q 'Human review' "$CARD"; then
  pass "corroborated learner improvement produces a human-only recommendation"
else
  fail "valid policy comparison did not recommend safely (rc=$RC): $OUT"
fi

# 2) The comparison preserves provenance and checks both policies against the same task records.
if PYTHONDONTWRITEBYTECODE=1 python3 - "$REPORT" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["metric_direction"] == "max"
assert result["aggregate"] == {"incumbent": 9, "learner": 13, "improves": True}
assert len(result["history_provenance"]) == 2
assert all("source" in item and "evidence" in item for item in result["history_provenance"])
assert all(row["incumbent"]["evidence"] and row["learner"]["evidence"] for row in result["tasks"])
assert "no automatic activation" in result["authority"]
PY
then
  pass "policy comparison preserves history, task evidence, metric direction, and authority"
else
  fail "policy report omitted comparison provenance"
fi

# 3) Sparse history stays deferred even when the learner's aggregate value is higher.
run_policy compare --root "$PROJECT" --manifest "$PROJECT/sparse.json"
if [[ "$RC" -eq 1 ]] && grep -q '"status": "deferred"' "$PROJECT/.wgm/stage10/routing/policy/comparison.json" \
   && grep -q 'insufficient corroborated route history' "$PROJECT/.wgm/stage10/routing/policy/comparison.json"; then
  pass "sparse route history remains deferred"
else
  fail "sparse history was promoted (rc=$RC): $OUT"
fi

# 4) A high aggregate score cannot hide a per-task hard regression.
run_policy compare --root "$PROJECT" --manifest "$PROJECT/regress.json"
if [[ "$RC" -eq 1 ]] \
   && grep -q '"status": "rejected"' "$PROJECT/.wgm/stage10/routing/policy/comparison.json" \
   && grep -q 'per-task hard regression: task-one' "$PROJECT/.wgm/stage10/routing/policy/comparison.json"; then
  pass "per-task hard regression rejects aggregate policy improvement"
else
  fail "hard regression was not rejected (rc=$RC): $OUT"
fi

# 5) Metric direction is explicit rather than assumed. A lower-is-better fixture must select the
# learner only when it reduces the aggregate value.
cat >"$PROJECT/min.json" <<'EOF'
{
  "policy_name":"learner-min","incumbent_name":"transparent-v1","learner_name":"learner-min","metric_direction":"min",
  "history":[{"id":"h1","standing":"corroborated","source":"run:h1","evidence":["run:h1"]},{"id":"h2","standing":"promoted","source":"run:h2","evidence":["run:h2","human-approved:h2"]}],
  "tasks":[{"id":"task-one","incumbent":{"route":"safe","value":10,"hard_gate":true,"holdout":true,"evidence":["run:i"]},"learner":{"route":"fast","value":4,"hard_gate":true,"holdout":true,"evidence":["run:l"]}}]
}
EOF
run_policy compare --root "$PROJECT" --manifest "$PROJECT/min.json"
if [[ "$RC" -eq 0 ]] && grep -q '"metric_direction": "min"' "$PROJECT/.wgm/stage10/routing/policy/comparison.json" \
   && grep -q '"improves": true' "$PROJECT/.wgm/stage10/routing/policy/comparison.json"; then
  pass "lower-is-better metric direction is honored"
else
  fail "metric direction was not honored (rc=$RC): $OUT"
fi

# 6) Unsafe input is rejected before output, and all output remains in the target project's .wgm.
printf '%s\n' '{"policy_name":"bad","incumbent_name":"safe","learner_name":"bad","metric_direction":"max","history":[{"id":"h1","standing":"corroborated","source":"token=sk-secret-value","evidence":["run:h1"]},{"id":"h2","standing":"corroborated","source":"run:h2","evidence":["run:h2"]}],"tasks":[{"id":"task-one","incumbent":{"route":"safe","value":1,"hard_gate":true,"holdout":true,"evidence":["run:i"]},"learner":{"route":"fast","value":2,"hard_gate":true,"holdout":true,"evidence":["run:l"]}}]}' >"$PROJECT/secret.json"
run_policy compare --root "$PROJECT" --manifest "$PROJECT/secret.json" --output "$TMP/outside.json"
if [[ "$RC" -eq 2 ]] && grep -q 'credential-like' <<<"$OUT" \
   && [[ ! -e "$TMP/outside.json" ]] \
   && [[ ! -e "$ROOT/.wgm/stage10/routing/policy/comparison.json" ]]; then
  pass "unsafe policy input and output escape are blocked"
else
  fail "policy boundary failed (rc=$RC): $OUT"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "stage10 policy harness: GREEN ($PASSED assertions passed)"
  exit 0
else
  echo "stage10 policy harness: RED" >&2
  exit 1
fi
