#!/usr/bin/env bash
# shellcheck disable=SC2015
# Deterministic Stage 10 vertical slice: observe, qualify, route, compare, and report.
# This is deliberately fixture-only: it proves composition without providers or external writes.
set -uo pipefail
# These compact assertion chains intentionally record a failure without aborting the harness.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wgm-stage10-e2e.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
mkdir -p "$PROJECT"; printf '# disposable Stage 10 fixture\n' > "$PROJECT/README.md"
git -C "$PROJECT" init -q; git -C "$PROJECT" config user.email fixture@example.invalid; git -C "$PROJECT" config user.name fixture; git -C "$PROJECT" add README.md; git -C "$PROJECT" commit -qm initial
fail=0; pass=0
ok() { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }
run() { local script="$1"; shift; PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/$script" "$@"; }

# Observe and recall are the real memory command and its generated brief, not a mock record.
run stage10_memory.py inspect --root "$PROJECT" || bad 'memory observation failed'
[[ -s "$PROJECT/.wgm/stage10/brief.md" ]] \
  && ok 'observe/recall produced a bounded offline brief' || bad 'brief output missing'
cat >"$PROJECT/qualification.json" <<'EOF'
{"routes":[{"id":"safe","environment":"offline-fixture","commands":{"contract":"true","protocol":"true","tool":"true","ralph-smoke":"true","repeated":"true","benchmark":"true"}},{"id":"alternate","environment":"offline-fixture","commands":{"contract":"true","protocol":"true","tool":"true","ralph-smoke":"true","repeated":"true","benchmark":"true"}}]}
EOF
run stage10_qualification.py qualify --root "$PROJECT" --manifest "$PROJECT/qualification.json" || bad 'qualification failed'
if PYTHONDONTWRITEBYTECODE=1 python3 - "$PROJECT/.wgm/stage10/harnesses/qualification.jsonl" <<'PY'
import json
import sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert len(rows) == 14
assert {row["route_status"] for row in rows} == {"fixture-qualified"}
assert all(row["status"] == "passed" for row in rows)
PY
then
  ok 'two fixture routes qualified with phase evidence'
else
  bad 'qualification evidence missing or overclaimed'
fi
cat >"$PROJECT/routes.json" <<'EOF'
{"task":{"hard_capabilities":["fresh-session","tools"],"preferences":["fast"],"local_only":true,"budget":{"seconds":30,"cost_units":4}},"routes":[{"id":"safe","environment":"local","capabilities":["fresh-session","tools"],"evidence":{"status":"corroborated","level":"qualified","refs":["qualification:safe"]},"latency_ms":5,"cost_units":2},{"id":"alternate","environment":"local","capabilities":["fresh-session","tools","fast"],"evidence":{"status":"corroborated","level":"qualified","refs":["qualification:alternate"]},"latency_ms":2,"cost_units":1}]}
EOF
run stage10_router.py route --root "$PROJECT" --manifest "$PROJECT/routes.json" || bad 'route selection failed'
grep -q '"selected_route": "alternate"' "$PROJECT/.wgm/stage10/routing/decision.json" && ok 'route selected with alternatives, evidence, and budget' || bad 'route decision missing selected route'
BASE="$(git -C "$PROJECT" rev-parse HEAD)"
cat >"$PROJECT/experiment.json" <<EOF
{"hypothesis":"fixture improves quality","baseline_sha":"$BASE","route":"alternate","environment":"offline","allowed_files":["README.md"],"evaluator":"fixture","target_metric":"quality","metric_direction":"max","non_regression":["tests"],"budget":{"seconds":1},"retirements":[{"retired":"old-route","evidence":["review:1"]},{"retired":"duplicate","evidence":["review:2"]}],"candidates":[{"id":"candidate","branch":"fixture-candidate","metric":2,"holdout_pass":true,"gates":[{"name":"tests","passed":true}],"changed_files":["README.md"],"evidence":["run:1"]}]}
EOF
run stage10_experiments.py compare --root "$PROJECT" --manifest "$PROJECT/experiment.json" || bad 'experiment comparison failed'
cat >"$PROJECT/policy.json" <<'EOF'
{"policy_name":"learner","incumbent_name":"transparent","learner_name":"learner","metric_direction":"max","history":[{"id":"h1","standing":"corroborated","source":"run:h1","evidence":["review:h1"]},{"id":"h2","standing":"corroborated","source":"run:h2","evidence":["review:h2"]}],"tasks":[{"id":"task","incumbent":{"route":"safe","value":1,"hard_gate":true,"holdout":true,"evidence":["run:i"]},"learner":{"route":"alternate","value":2,"hard_gate":true,"holdout":true,"evidence":["run:l"]}}]}
EOF
run stage10_policy.py compare --root "$PROJECT" --manifest "$PROJECT/policy.json" || bad 'policy comparison failed'
REPORT="$PROJECT/.wgm/stage10/e2e-report.md"
mkdir -p "$(dirname "$REPORT")"
# Generate the human report from the actual decision artifacts rather than a hand-written success
# fixture. This catches a future schema/output drift that leaves the narrative claiming a result the
# composed tools did not produce.
if PYTHONDONTWRITEBYTECODE=1 python3 - "$PROJECT" <<'PY'
import json
import sys
from pathlib import Path

project = Path(sys.argv[1])
brief = project / ".wgm/stage10/brief.md"
qualification = project / ".wgm/stage10/harnesses/qualification.jsonl"
route = project / ".wgm/stage10/routing/decision.json"
experiment = project / ".wgm/stage10/experiments/report.json"
policy = project / ".wgm/stage10/routing/policy/comparison.json"
assert brief.is_file()
rows = [json.loads(line) for line in qualification.read_text(encoding="utf-8").splitlines()]
route_result = json.loads(route.read_text(encoding="utf-8"))
experiment_result = json.loads(experiment.read_text(encoding="utf-8"))
policy_result = json.loads(policy.read_text(encoding="utf-8"))
assert len(rows) == 14 and {row["route_status"] for row in rows} == {"fixture-qualified"}
assert route_result["selected_route"] == "alternate"
assert experiment_result["frozen_baseline"] is True
assert experiment_result["feature_economy"]["eligible"] is True
assert policy_result["status"] == "recommend"
report = "\n".join([
    "# Stage 10 end-to-end demonstration",
    "",
    "- Path: observe → recall → qualify → route → experiment → compare → report",
    f"- Selected route: `{route_result['selected_route']}`; alternative: `{route_result['alternatives'][0]}`",
    f"- Evidence: {len(rows)} fixture qualification records, route references, frozen baseline, and corroborated history",
    f"- Budget: `{route_result['budget']}`",
    f"- Baseline comparison: winner `{experiment_result['winner']}`; hard gates passed for the composed candidate",
    f"- Knowledge: policy status `{policy_result['status']}`; feature economy `{experiment_result['feature_economy']['reason']}",
    "- Human decision required: review the recommendation before activation or merge",
    "",
    "**Authority boundary:** fixture-only and offline. No model, network, publish, deploy, PR creation, merge, or automatic activation occurs.",
    "",
])
(project / ".wgm/stage10/e2e-report.md").write_text(report, encoding="utf-8")
PY
then
  if grep -q 'Human decision required' "$REPORT" && grep -q 'No model, network' "$REPORT"; then
    ok 'generated report preserves actual decisions and authority boundaries'
  else
    bad 'generated e2e report incomplete'
  fi
else
  bad 'e2e report generation failed'
fi
[[ "$fail" -eq 0 ]] && printf 'stage10 e2e harness: GREEN (%d assertions passed)\n' "$pass" || { echo 'stage10 e2e harness: RED' >&2; exit 1; }
