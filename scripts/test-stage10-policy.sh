#!/usr/bin/env bash
# Focused offline policy gate: each assertion protects a policy safety boundary.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ok=0; fail=0
assert() { if "$@" >/dev/null 2>&1; then echo "ok: $1"; ok=$((ok+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
cat >"$TMP/good.json" <<'JSON'
{"history":[{"id":"h1","standing":"corroborated","source":"fixture:a"},{"id":"h2","standing":"corroborated","source":"fixture:b"}],"tasks":[{"id":"t1","incumbent":{"route":"safe","value":5,"hard_gate":true,"holdout":true},"learner":{"route":"fast","value":7,"hard_gate":true,"holdout":true}},{"id":"t2","incumbent":{"route":"safe","value":4,"hard_gate":true,"holdout":true},"learner":{"route":"fast","value":6,"hard_gate":true,"holdout":true}}]}
JSON
cat >"$TMP/sparse.json" <<'JSON'
{"history":[{"id":"h1","standing":"validated","source":"fixture:a"}],"tasks":[{"id":"t1","incumbent":{"route":"safe","value":1,"hard_gate":true,"holdout":true},"learner":{"route":"fast","value":2,"hard_gate":true,"holdout":true}}]}
JSON
cat >"$TMP/regress.json" <<'JSON'
{"history":[{"id":"h1","standing":"corroborated","source":"fixture:a"},{"id":"h2","standing":"corroborated","source":"fixture:b"}],"tasks":[{"id":"t1","incumbent":{"route":"safe","value":1,"hard_gate":true,"holdout":true},"learner":{"route":"fast","value":99,"hard_gate":false,"holdout":true}}]}
JSON
assert bash -c "python3 '$ROOT/scripts/stage10_policy.py' compare --root '$TMP' --manifest '$TMP/good.json'"
# Sparse history must remain visibly deferred, not treated as a winning learner.
if python3 "$ROOT/scripts/stage10_policy.py" compare --root "$TMP" --manifest "$TMP/sparse.json"; then echo 'FAIL: sparse history unexpectedly promoted'; fail=$((fail+1)); else grep -q '"status": "deferred"' "$TMP/.wgm/stage10/routing/policy/comparison.json" && { echo 'ok: sparse history deferred'; ok=$((ok+1)); } || { echo 'FAIL: sparse history reason missing'; fail=$((fail+1)); }; fi
# Aggregate gains must not bypass a per-task hard regression.
if python3 "$ROOT/scripts/stage10_policy.py" compare --root "$TMP" --manifest "$TMP/regress.json"; then echo 'FAIL: hard regression promoted'; fail=$((fail+1)); else grep -q 'per-task hard regression' "$TMP/.wgm/stage10/routing/policy/comparison.json" && { echo 'ok: hard regression rejected'; ok=$((ok+1)); } || { echo 'FAIL: regression reason missing'; fail=$((fail+1)); }; fi
[ "$fail" -eq 0 ] || exit 1
echo "stage10 policy harness: GREEN ($ok assertions)"
