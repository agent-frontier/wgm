#!/usr/bin/env bash
# Deterministic fixture backpressure for isolated comparison, negative retention, and economy.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
P="$TMP/project"; mkdir -p "$P"; printf '# fixture\n' > "$P/README.md"
cat >"$P/experiment.json" <<'EOF'
{"hypothesis":"fixture candidate improves value","baseline_sha":"baseline-frozen-123","route":"fixture","environment":{"kind":"offline"},"allowed_files":["src/example.py"],"evaluator":"fixture-evaluator-v1","target_metric":"quality","non_regression":["tests","holdout"],"budget":{"seconds":10},"retirements":[{"retired":"old-route","evidence":"test:old-route"},{"retired":"duplicate-view","evidence":"review:consolidation"}],"candidates":[{"id":"winner","branch":"candidate-winner","metric":9,"holdout_pass":true,"gates":[{"name":"tests","passed":true}]},{"id":"regression","branch":"candidate-regression","metric":99,"holdout_pass":false,"gates":[{"name":"tests","passed":false}]}]}
EOF
set +e; python3 "$ROOT/scripts/stage10_experiments.py" compare --root "$P" --manifest "$P/experiment.json"; rc=$?; set -e
R="$P/.wgm/stage10/experiments/report.json"
if [[ $rc -eq 1 ]] && [[ -f "$R" ]] && grep -q '"negative_result": true' "$R" && grep -q 'Human review' "$P/.wgm/stage10/experiments/report.md"; then echo 'ok: regression retained and human report written'; else echo 'FAIL: regression handling'; exit 1; fi
python3 - "$R" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); assert x['frozen_baseline']; assert x['winner']=='winner'; assert not x['pr_recommendation']; assert not x['candidates'][1]['pr_eligible']; assert x['feature_economy']['eligible']
PY
echo 'ok: frozen baseline, hard gate, and two-retirement economy are recorded'
python3 - "$P" <<'PY'
import json,sys
p=sys.argv[1]; x=json.load(open(p+'/experiment.json')); x['candidates']=[x['candidates'][0]]; x['retirements']=[]; json.dump(x,open(p+'/bad.json','w'))
PY
set +e; python3 "$ROOT/scripts/stage10_experiments.py" compare --root "$P" --manifest "$P/bad.json" >/dev/null 2>&1; rc=$?; set -e
[[ $rc -eq 1 ]] || { echo 'FAIL: economy gate'; exit 1; }; echo 'ok: missing economy blocks recommendation'
echo 'stage10 experiments harness: GREEN (3 assertions passed)'
