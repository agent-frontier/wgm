#!/usr/bin/env bash
#
# wgm/test-stage10-router.sh — deterministic backpressure for transparent Stage 10 route policy.
#
# The fixture proves hard capability exclusion, stale/inventory evidence handling, local-only policy,
# stable scoring, decision-card provenance, input validation, secret/multiline refusal, output
# confinement, and no accidental writes to the invoking checkout. It never calls a model.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTER="$ROOT/scripts/stage10_router.py"
FAILED=0
PASSED=0
pass() { printf 'ok:   %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

[[ -f "$ROUTER" ]] || { fail "missing $ROUTER"; exit 1; }
command -v python3 >/dev/null 2>&1 || { fail "python3 is required"; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wgm-stage10-router.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
mkdir -p "$PROJECT/.wgm/stage10/routing"
printf '# route fixture\n' >"$PROJECT/README.md"

cat >"$PROJECT/routes.json" <<'EOF'
{
  "task": {
    "hard_capabilities": ["fresh-session", "tools"],
    "preferences": ["fast"],
    "local_only": true,
    "budget": {"seconds": 30, "cost_units": 4}
  },
  "routes": [
    {
      "id": "incapable",
      "environment": "local",
      "capabilities": ["tools"],
      "evidence": {"status": "corroborated", "level": "qualified", "refs": ["run:incapable"]}
    },
    {
      "id": "stale",
      "environment": "local",
      "capabilities": ["fresh-session", "tools"],
      "evidence": {"status": "corroborated", "level": "qualified", "stale": true, "refs": ["run:stale"]}
    },
    {
      "id": "inventory",
      "environment": "local",
      "capabilities": ["fresh-session", "tools"],
      "evidence": {"status": "observed", "level": "inventory", "refs": ["probe:inventory"]}
    },
    {
      "id": "remote",
      "environment": "remote",
      "capabilities": ["fresh-session", "tools", "fast"],
      "evidence": {"status": "promoted", "level": "corroborated", "refs": ["run:remote", "human-approved:route-review"]}
    },
    {
      "id": "zulu",
      "environment": "local",
      "capabilities": ["fresh-session", "tools", "fast"],
      "latency_ms": 2,
      "cost_units": 1,
      "evidence": {"status": "corroborated", "level": "qualified", "refs": ["run:zulu", "run:zulu-repeat"]}
    },
    {
      "id": "alpha",
      "environment": "local",
      "capabilities": ["fresh-session", "tools"],
      "latency_ms": 2,
      "cost_units": 1,
      "evidence": {"status": "qualified", "level": "qualified", "refs": ["run:alpha"]}
    }
  ]
}
EOF

run_router() {
  set +e
  OUT="$(PYTHONDONTWRITEBYTECODE=1 python3 "$ROUTER" "$@" 2>&1)"
  RC=$?
  set -e
}

# 1) The valid path selects the highest transparent score and writes both JSON and a human card
# under the fixture's .wgm directory, not the invoking checkout.
run_router route --root "$PROJECT" --manifest "$PROJECT/routes.json"
DECISION="$PROJECT/.wgm/stage10/routing/decision.json"
CARD="$PROJECT/.wgm/stage10/routing/decision.md"
if [[ "$RC" -eq 0 ]] && [[ -f "$DECISION" ]] && [[ -f "$CARD" ]] \
   && grep -q 'selected zulu' <<<"$OUT" \
   && grep -q 'Selected route: \*\*zulu\*\*' "$CARD"; then
  pass "valid routes produce a selected route and human decision card in target .wgm"
else
  fail "valid route decision was not produced correctly (rc=$RC): $OUT"
fi

# 2) Hard requirements, stale evidence, inventory-only evidence, and local-only policy are all
# excluded before scoring; only alpha and zulu remain eligible.
if PYTHONDONTWRITEBYTECODE=1 python3 - "$DECISION" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["selected_route"] == "zulu"
assert result["alternatives"] == ["alpha"]
by_route = {item["route"]: item for item in result["decisions"]}
assert not by_route["incapable"]["eligible"]
assert not by_route["stale"]["eligible"]
assert not by_route["inventory"]["eligible"]
assert not by_route["remote"]["eligible"]
assert len(result["uncertainty"]) == 4
assert result["confidence"] == "corroborated"
PY
then
  pass "hard capability and evidence gates precede deterministic scoring"
else
  fail "ineligible routes were scored or selected"
fi

# 3) The decision ordering is stable across repeated runs even though timestamps differ.
run_router route --root "$PROJECT" --manifest "$PROJECT/routes.json" \
  --output "$PROJECT/.wgm/stage10/routing/repeat.json"
if [[ "$RC" -eq 0 ]] && PYTHONDONTWRITEBYTECODE=1 python3 - "$PROJECT/.wgm/stage10/routing/repeat.json" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["selected_route"] == "zulu"
assert result["alternatives"] == ["alpha"]
assert [item["route"] for item in result["decisions"]] == [
    "incapable", "stale", "inventory", "remote", "zulu", "alpha"
]
PY
then
  pass "route selection and decision ordering are deterministic"
else
  fail "repeated route selection changed its decision (rc=$RC): $OUT"
fi

# 4) Policy inputs are typed and safe. A string "false" must not become a truthy local_only flag,
# and route metadata containing a credential-like value must never be written.
printf '%s\n' '{"task":{"hard_capabilities":[],"preferences":[],"local_only":"false","budget":{}},"routes":[]}' >"$PROJECT/bad-type.json"
run_router route --root "$PROJECT" --manifest "$PROJECT/bad-type.json" --output "$PROJECT/.wgm/stage10/routing/bad-type.json"
if [[ "$RC" -eq 2 ]] && grep -q 'local_only must be boolean' <<<"$OUT"; then
  pass "invalid policy types are rejected before routing"
else
  fail "invalid local_only type was accepted (rc=$RC): $OUT"
fi
printf '%s\n' '{"task":{"hard_capabilities":[],"preferences":[],"budget":{}},"routes":[{"id":"leak","environment":"local","capabilities":[],"evidence":{"refs":["token=sk-secret-value"]}}]}' >"$PROJECT/bad-secret.json"
run_router route --root "$PROJECT" --manifest "$PROJECT/bad-secret.json" --output "$PROJECT/.wgm/stage10/routing/bad-secret.json"
if [[ "$RC" -eq 2 ]] && grep -q 'credential-like' <<<"$OUT" \
   && [[ ! -e "$PROJECT/.wgm/stage10/routing/bad-secret.json" ]]; then
  pass "credential-like route data is rejected without an output artifact"
else
  fail "credential-like route data was persisted or misclassified (rc=$RC): $OUT"
fi

# 5) A route manifest is data, not a command channel. Newline-bearing values and output paths
# outside the target project are rejected.
printf '%s\n' '{"task":{"hard_capabilities":[],"preferences":[],"budget":{}},"routes":[{"id":"bad","environment":"local","capabilities":[],"evidence":{"refs":["line1\nline2"]}}]}' >"$PROJECT/bad-newline.json"
run_router route --root "$PROJECT" --manifest "$PROJECT/bad-newline.json"
if [[ "$RC" -eq 2 ]] && grep -q 'multiline' <<<"$OUT"; then
  pass "multiline route input is rejected"
else
  fail "multiline route input was accepted (rc=$RC): $OUT"
fi
run_router route --root "$PROJECT" --manifest "$PROJECT/routes.json" --output "$TMP/outside.json"
if [[ "$RC" -eq 2 ]] && grep -q 'must remain under' <<<"$OUT" \
   && [[ ! -e "$TMP/outside.json" ]] \
   && [[ ! -e "$ROOT/.wgm/stage10/routing/decision.json" ]]; then
  pass "decision output cannot escape the target project's .wgm boundary"
else
  fail "decision output escaped its target boundary (rc=$RC): $OUT"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "stage10 router harness: GREEN ($PASSED assertions passed)"
  exit 0
else
  echo "stage10 router harness: RED" >&2
  exit 1
fi
