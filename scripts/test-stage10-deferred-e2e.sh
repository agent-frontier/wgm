#!/usr/bin/env bash
#
# wgm/test-stage10-deferred-e2e.sh — final disposable Stage 10 boundary integration.
#
# The harness composes the real bounded runner, live-authorization, isolated execution,
# comparison, and PR-preparation entry points in one temporary Git fixture. Its "live" command is
# an explicitly authorized local contract double: no provider, model, network, hosting client,
# remote mutation, PR, merge, deployment, publication, or policy activation is attempted.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUALIFY="$ROOT/scripts/stage10_qualification.py"
EXPERIMENTS="$ROOT/scripts/stage10_experiments.py"
PREPARE="$ROOT/scripts/stage10_pr.py"
FAILED=0
PASSED=0
pass() { printf 'ok:   %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

for required in "$QUALIFY" "$EXPERIMENTS" "$PREPARE"; do
  [[ -f "$required" ]] || { fail "missing $required"; exit 1; }
done
for command in python3 git shellcheck; do
  command -v "$command" >/dev/null 2>&1 || { fail "$command is required"; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wgm-stage10-deferred-e2e.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
REMOTE="$TMP/remote.git"
STATE="$PROJECT/.wgm/stage10/deferred-e2e"
mkdir -p "$PROJECT/.wgm" "$TMP/bin" "$STATE/gates"

snapshot_repository() {
  local root="$1" destination="$2"
  {
    printf '%s\n' '--- HEAD ---'
    git -C "$root" rev-parse HEAD
    printf '%s\n' '--- branch ---'
    git -C "$root" branch --show-current
    printf '%s\n' '--- status ---'
    git -C "$root" status --porcelain=v1 --untracked-files=all --ignored
    printf '%s\n' '--- remotes ---'
    git -C "$root" remote -v
    printf '%s\n' '--- worktrees ---'
    git -C "$root" worktree list --porcelain
    printf '%s\n' '--- refs ---'
    git -C "$root" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/remotes
  } >"$destination"
}

snapshot_repository "$ROOT" "$TMP/real-before"

git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email stage10@example.invalid
git -C "$PROJECT" config user.name stage10-fixture
printf '/.wgm/\n' >"$PROJECT/.gitignore"
printf 'baseline\n' >"$PROJECT/app.txt"
printf 'protected\n' >"$PROJECT/protected.txt"
cat >"$PROJECT/check.py" <<'PY'
import pathlib
import sys

mode = sys.argv[1]
if mode == "pass":
    raise SystemExit(0 if pathlib.Path("app.txt").read_text(encoding="utf-8") == "candidate\n" else 8)
if mode == "fail":
    print("intentional deferred-boundary negative result", file=sys.stderr)
    raise SystemExit(9)
raise SystemExit(10)
PY
git -C "$PROJECT" add .gitignore app.txt protected.txt check.py
git -C "$PROJECT" commit -q -m 'fixture: deferred boundary baseline'
git init -q --bare "$REMOTE"
git -C "$PROJECT" remote add origin "$REMOTE"
BASELINE="$(git -C "$PROJECT" rev-parse HEAD)"
BASE_BRANCH="$(git -C "$PROJECT" branch --show-current)"
BASE_REMOTES="$(git -C "$PROJECT" remote -v)"
BASE_REMOTE_REFS="$(git --git-dir="$REMOTE" for-each-ref --format='%(refname) %(objectname)')"
BASE_PROTECTED_HASH="$(sha256sum "$PROJECT/protected.txt" | cut -d' ' -f1)"

# Provider, network, and hosting clients are observable tripwires, not implementations.
for blocked_client in gh curl wget ssh scp copilot claude codex aider; do
  cat >"$TMP/bin/$blocked_client" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$blocked_client' >>'$TMP/external-client-called'
exit 97
EOF
  chmod +x "$TMP/bin/$blocked_client"
done

cat >"$TMP/bin/live-contract-double" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$2"
printf 'authorized local contract double: %s\n' "$1"
EOF
chmod +x "$TMP/bin/live-contract-double"

LIVE_MANIFEST="$STATE/live-manifest.json"
LIVE_AUTHORIZATION="$STATE/live-authorization.json"
LIVE_MARKER="$STATE/live-contract-double.marker"
LIVE_REFUSAL="$STATE/live-refusal.jsonl"
LIVE_OUTPUT="$STATE/live-qualification.jsonl"
python3 - "$LIVE_MANIFEST" "$LIVE_AUTHORIZATION" "$LIVE_MARKER" \
  "$TMP/bin/live-contract-double" <<'PY'
import hashlib
import json
import sys

manifest_path, authorization_path, marker, executable = sys.argv[1:]
phases = ["contract", "protocol", "tool", "ralph-smoke", "repeated", "benchmark"]
manifest = {
    "allow_live": True,
    "live_budget_seconds": 5,
    "routes": [{
        "id": "authorized-local-double",
        "evidence": "live",
        "environment": "offline-authorized-local-contract-double",
        "commands": {phase: f"{executable} {phase} {marker}" for phase in phases},
    }],
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, sort_keys=True)
    handle.write("\n")
authorization = {
    "schema": "stage10.live-authorization.v1",
    "allow_live": True,
    "manifest_sha256": hashlib.sha256(open(manifest_path, "rb").read()).hexdigest(),
    "scope": {"routes": {"authorized-local-double": phases}},
    "expires_at": "2099-01-01T00:00:00Z",
    "budget_seconds": 5,
}
with open(authorization_path, "w", encoding="utf-8") as handle:
    json.dump(authorization, handle, sort_keys=True)
    handle.write("\n")
PY

# This assertion protects the default authority boundary: metadata alone cannot spawn the local
# double or produce success-shaped qualification evidence.
set +e
LIVE_REFUSAL_TEXT="$(PATH="$TMP/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$QUALIFY" qualify --root "$PROJECT" --manifest "$LIVE_MANIFEST" \
  --authorization-file "$LIVE_AUTHORIZATION" --output "$LIVE_REFUSAL" 2>&1)"
LIVE_REFUSAL_RC=$?
if [[ "$LIVE_REFUSAL_RC" -eq 2 ]] && [[ ! -e "$LIVE_MARKER" ]] \
  && [[ ! -e "$LIVE_REFUSAL" ]] && grep -q 'requires --allow-live' <<<"$LIVE_REFUSAL_TEXT"; then
  pass "unauthorized live metadata refuses before any command or evidence"
else
  fail "unauthorized live path crossed the invocation boundary (rc=$LIVE_REFUSAL_RC): $LIVE_REFUSAL_TEXT"
fi

# This assertion protects honest evidence labeling: explicit authority may exercise T10 through a
# local double, but the integration report must not call that provider or Windows-origin evidence.
set +e
LIVE_TEXT="$(PATH="$TMP/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$QUALIFY" qualify --root "$PROJECT" --manifest "$LIVE_MANIFEST" \
  --authorization-file "$LIVE_AUTHORIZATION" --allow-live --output "$LIVE_OUTPUT" 2>&1)"
LIVE_RC=$?
if [[ "$LIVE_RC" -eq 0 ]] && [[ "$(wc -l <"$LIVE_MARKER")" -eq 6 ]] \
  && PYTHONDONTWRITEBYTECODE=1 python3 - "$LIVE_OUTPUT" "$PROJECT" <<'PY'
import json
import pathlib
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
project = pathlib.Path(sys.argv[2])
assert len(rows) == 7
assert all(row["route"] == "authorized-local-double" for row in rows)
assert all(row["evidence"] == "live" and row["route_status"] == "qualified" for row in rows)
assert all(row["environment"] == "offline-authorized-local-contract-double" for row in rows)
phase_rows = [row for row in rows if row["phase"] != "inventory"]
assert all(row["runner"]["contract"] == "stage10.runner.v1" for row in phase_rows)
for row in phase_rows:
    result = json.loads((project / row["runner"]["result"]).read_text(encoding="utf-8"))
    assert result["schema"] == "stage10.runner.v1"
    assert result["shell"] is False
    assert result["status"] == "passed"
PY
then
  pass "authorized local double stays labeled and executes every phase through T10"
else
  fail "authorized local contract path failed or overclaimed evidence (rc=$LIVE_RC): $LIVE_TEXT"
fi

printf 'candidate\n' >"$PROJECT/app.txt"
git -C "$PROJECT" diff --binary -- app.txt >"$PROJECT/.wgm/candidate.patch"
git -C "$PROJECT" checkout -q -- app.txt

write_execution_manifest() {
  local path="$1" identifier="$2" evaluator_mode="$3"
  python3 - "$path" "$identifier" "$evaluator_mode" "$BASELINE" "$LIVE_OUTPUT" <<'PY'
import json
import sys

path, identifier, evaluator_mode, baseline, qualification_path = sys.argv[1:]
rows = [json.loads(line) for line in open(qualification_path, encoding="utf-8")]
route = rows[0]["route"]
value = {
    "id": identifier,
    "hypothesis": "the deferred-boundary candidate improves the disposable fixture",
    "baseline_sha": baseline,
    "candidate": {"patch": ".wgm/candidate.patch"},
    "route": {
        "id": route,
        "evidence": "authorized-local-contract-double",
        "qualification_artifact": ".wgm/stage10/deferred-e2e/live-qualification.jsonl",
    },
    "environment": {"kind": "disposable-local-git", "network": False},
    "allowed_files": ["app.txt"],
    "evaluator": {
        "name": "evaluator",
        "argv": ["python3", "check.py", evaluator_mode],
        "timeout_seconds": 1,
    },
    "non_regression": [{
        "name": "non-regression",
        "argv": ["python3", "check.py", "pass"],
        "timeout_seconds": 1,
    }],
    "budget": {"seconds": 3, "cost_units": 0},
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True)
    handle.write("\n")
PY
}

execution_paths() {
  local manifest="$1" identifier="$2"
  local digest
  digest="$(sha256sum "$manifest" | cut -d' ' -f1)"
  EXECUTION_REPORT="$PROJECT/.wgm/stage10/experiments/executions/$identifier-${digest:0:12}.json"
  EXECUTION_BRANCH="stage10/experiment/$identifier-${digest:0:12}"
  EXECUTION_WORKTREE="$PROJECT/.wgm/stage10/worktrees/$identifier-${digest:0:12}"
}

PASS_MANIFEST="$PROJECT/.wgm/passing-execution.json"
write_execution_manifest "$PASS_MANIFEST" approved-candidate pass
execution_paths "$PASS_MANIFEST" approved-candidate
PASS_REPORT="$EXECUTION_REPORT"
PASS_BRANCH="$EXECUTION_BRANCH"
PASS_WORKTREE="$EXECUTION_WORKTREE"
set +e
PASS_TEXT="$(PATH="$TMP/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$EXPERIMENTS" execute --root "$PROJECT" --manifest "$PASS_MANIFEST" 2>&1)"
PASS_RC=$?
if [[ "$PASS_RC" -eq 0 ]] && [[ -d "$PASS_WORKTREE" ]] \
  && git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$PASS_BRANCH" \
  && PYTHONDONTWRITEBYTECODE=1 python3 - "$PASS_REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["status"] == "passed"
assert report["cleanup"]["state"] == "retained-for-human-review"
assert report["source_checkout"]["unchanged"] is True
assert report["changed_files"] == ["app.txt"]
assert all(check["runner_contract"] == "stage10.runner.v1" for check in report["checks"])
assert all(check["runner_result_record"]["shell"] is False for check in report["checks"])
PY
then
  pass "passing execution retains only its verified local review branch and worktree"
else
  fail "passing isolated execution failed (rc=$PASS_RC): $PASS_TEXT"
fi

FAIL_MANIFEST="$PROJECT/.wgm/failing-execution.json"
write_execution_manifest "$FAIL_MANIFEST" rejected-candidate fail
execution_paths "$FAIL_MANIFEST" rejected-candidate
FAIL_REPORT="$EXECUTION_REPORT"
FAIL_BRANCH="$EXECUTION_BRANCH"
FAIL_WORKTREE="$EXECUTION_WORKTREE"
set +e
FAIL_TEXT="$(PATH="$TMP/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$EXPERIMENTS" execute --root "$PROJECT" --manifest "$FAIL_MANIFEST" 2>&1)"
FAIL_RC=$?
if [[ "$FAIL_RC" -eq 1 ]] && [[ -f "$FAIL_REPORT" ]] && [[ ! -e "$FAIL_WORKTREE" ]] \
  && ! git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$FAIL_BRANCH" \
  && PYTHONDONTWRITEBYTECODE=1 python3 - "$FAIL_REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["status"] == "failed"
assert report["result"] == "negative"
assert report["cleanup"]["state"] == "removed"
assert report["source_checkout"]["unchanged"] is True
assert report["checks"][0]["runner_result_record"]["status"] == "failed"
PY
then
  pass "failed execution preserves negative T10 evidence and removes its Git identity"
else
  fail "negative execution was lost or not cleaned (rc=$FAIL_RC): $FAIL_TEXT"
fi

COMPARISON_MANIFEST="$PROJECT/.wgm/comparison.json"
COMPARISON_REPORT="$PROJECT/.wgm/stage10/experiments/comparison.json"
python3 - "$COMPARISON_MANIFEST" "$PASS_REPORT" "$FAIL_REPORT" "$PASS_BRANCH" <<'PY'
import json
import sys

path, passing_path, failing_path, passing_branch = sys.argv[1:]
passing = json.load(open(passing_path, encoding="utf-8"))
failing = json.load(open(failing_path, encoding="utf-8"))
value = {
    "hypothesis": passing["frozen_manifest"]["hypothesis"],
    "baseline_sha": passing["baseline_sha"],
    "route": passing["route"],
    "environment": passing["environment"],
    "allowed_files": passing["allowed_files"],
    "evaluator": passing["frozen_manifest"]["evaluator"]["name"],
    "target_metric": "quality",
    "metric_direction": "max",
    "non_regression": ["non-regression", "holdout"],
    "budget": passing["frozen_manifest"]["budget"],
    "retirements": [
        {"retired": "old-route", "evidence": ["historical:T7"]},
        {"retired": "duplicate-view", "evidence": ["historical:T9"]},
    ],
    "candidates": [{
        "id": passing["frozen_manifest"]["id"],
        "branch": passing_branch,
        "metric": 9,
        "holdout_pass": True,
        "gates": [{"name": "non-regression", "passed": True}],
        "changed_files": passing["changed_files"],
        "evidence": [
            f"execution:{passing_path}",
            f"negative-execution-observed:{failing_path}",
            "holdout:fixture",
        ],
    }],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True)
    handle.write("\n")
PY
set +e
COMPARE_TEXT="$(PATH="$TMP/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$EXPERIMENTS" compare --root "$PROJECT" --manifest "$COMPARISON_MANIFEST" \
  --output "$COMPARISON_REPORT" 2>&1)"
COMPARE_RC=$?
if [[ "$COMPARE_RC" -eq 0 ]] && PYTHONDONTWRITEBYTECODE=1 \
  python3 - "$COMPARISON_REPORT" "$PASS_BRANCH" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["winner"] == "approved-candidate"
assert report["pr_recommendation"] is True
assert report["feature_economy"]["eligible"] is True
assert report["candidates"][0]["branch"] == sys.argv[2]
assert any(ref.startswith("negative-execution-observed:") for ref in report["candidates"][0]["evidence"])
PY
then
  pass "T7 comparison consumes the passing execution and cites preserved negative evidence"
else
  fail "artifact-derived comparison failed (rc=$COMPARE_RC): $COMPARE_TEXT"
fi

APPROVAL="$PROJECT/.wgm/approval.json"
python3 - "$APPROVAL" "$PASS_REPORT" "$COMPARISON_REPORT" "$BASE_BRANCH" <<'PY'
import hashlib
import json
import sys

path, execution_path, comparison_path, base_branch = sys.argv[1:]
execution = json.load(open(execution_path, encoding="utf-8"))
value = {
    "schema": "stage10.pr-approval.v1",
    "approved": True,
    "approver": "fixture-maintainer",
    "expires_at": "2099-01-01T00:00:00Z",
    "execution_report_sha256": hashlib.sha256(open(execution_path, "rb").read()).hexdigest(),
    "comparison_report_sha256": hashlib.sha256(open(comparison_path, "rb").read()).hexdigest(),
    "candidate_snapshot_sha256": execution["candidate_snapshot_sha256"],
    "head_branch": execution["identity"]["branch"],
    "base_branch": base_branch,
    "baseline_sha": execution["baseline_sha"],
    "allowed_files": execution["allowed_files"],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True)
    handle.write("\n")
PY

# This assertion protects the second human control: an exact approval record is inert without the
# explicit invocation flag, and no success-shaped bundle is emitted.
set +e
PR_BLOCKED_TEXT="$(PATH="$TMP/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$PREPARE" prepare --root "$PROJECT" --execution-report "$PASS_REPORT" \
  --comparison-report "$COMPARISON_REPORT" --approval-file "$APPROVAL" 2>&1)"
PR_BLOCKED_RC=$?
if [[ "$PR_BLOCKED_RC" -eq 1 ]] && grep -q 'awaiting-human-review' <<<"$PR_BLOCKED_TEXT" \
  && [[ ! -d "$PROJECT/.wgm/stage10/pr" ]]; then
  pass "approval metadata alone cannot emit a PR preparation bundle"
else
  fail "PR preparation bypassed explicit human approval (rc=$PR_BLOCKED_RC): $PR_BLOCKED_TEXT"
fi

set +e
PR_TEXT="$(PATH="$TMP/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$PREPARE" prepare --root "$PROJECT" --execution-report "$PASS_REPORT" \
  --comparison-report "$COMPARISON_REPORT" --approval-file "$APPROVAL" --human-approve 2>&1)"
PR_RC=$?
BUNDLE="$(find "$PROJECT/.wgm/stage10/pr" -maxdepth 1 -name '*.json' -print -quit 2>/dev/null)"
BUNDLE_BODY="${BUNDLE%.json}.md"
if [[ "$PR_RC" -eq 0 ]] && [[ -f "$BUNDLE" ]] && [[ -f "$BUNDLE_BODY" ]] \
  && [[ "$(stat -c %s "$BUNDLE")" -le 200000 ]] \
  && [[ "$(stat -c %s "$BUNDLE_BODY")" -le 200000 ]] \
  && PYTHONDONTWRITEBYTECODE=1 python3 - "$BUNDLE" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1], encoding="utf-8"))
assert bundle["status"] == "ready"
assert bundle["candidate"]["head_branch"].startswith("stage10/experiment/")
assert bundle["validation"]["holdout_pass"] is True
assert bundle["feature_economy"]["eligible"] is True
assert "no hosting client" in bundle["authority"]
assert "push and create the PR" in bundle["remaining_human_action"]
PY
then
  pass "explicit human gate emits only a bounded report-derived local bundle"
else
  fail "approved local PR bundle failed (rc=$PR_RC): $PR_TEXT"
fi

GATE_RESULTS="$STATE/gates/results.tsv"
: >"$GATE_RESULTS"
run_gate() {
  local gate="$1"
  shift
  local log="$STATE/gates/$gate.log" rc
  "$@" >"$log" 2>&1
  rc=$?
  printf '%s\t%s\t%s\n' "$gate" "$rc" "$(sha256sum "$log" | cut -d' ' -f1)" >>"$GATE_RESULTS"
  if [[ "$rc" -eq 0 ]]; then
    pass "$gate gate passed and was recorded"
  else
    fail "$gate gate failed (rc=$rc): $(tail -n 3 "$log" | tr '\n' ' ')"
  fi
}

# These are the completed T1-T9 deterministic gates. Each owns its own disposable fixture; their
# logs and hashes become inputs to this integration report rather than prose-only claims.
run_gate t1-t4-memory bash "$ROOT/scripts/test-stage10-memory.sh"
run_gate t5-qualification bash "$ROOT/scripts/test-stage10-qualification.sh"
run_gate t6-routing bash "$ROOT/scripts/test-stage10-router.sh"
run_gate t7-experiments bash "$ROOT/scripts/test-stage10-experiments.sh"
run_gate t8-policy bash "$ROOT/scripts/test-stage10-policy.sh"
run_gate t9-offline-e2e bash "$ROOT/scripts/test-stage10-e2e.sh"
run_gate t14-shellcheck shellcheck "$ROOT/scripts/test-wsl-windows-boundary.sh"
run_gate t14-boundary bash "$ROOT/scripts/test-wsl-boundary-harness.sh"

# T13 has consumed the retained candidate. Remove its local review identity now, while keeping the
# execution, comparison, negative, and approval artifacts available for the final report.
git -C "$PROJECT" worktree remove --force "$PASS_WORKTREE" >/dev/null 2>&1
git -C "$PROJECT" branch -D "$PASS_BRANCH" >/dev/null 2>&1
git -C "$PROJECT" worktree prune

fixture_unchanged() {
  [[ "$(git -C "$PROJECT" rev-parse HEAD)" == "$BASELINE" ]] \
    && [[ "$(git -C "$PROJECT" branch --show-current)" == "$BASE_BRANCH" ]] \
    && [[ "$(git -C "$PROJECT" remote -v)" == "$BASE_REMOTES" ]] \
    && [[ "$(git --git-dir="$REMOTE" for-each-ref --format='%(refname) %(objectname)')" == "$BASE_REMOTE_REFS" ]] \
    && [[ "$(sha256sum "$PROJECT/protected.txt" | cut -d' ' -f1)" == "$BASE_PROTECTED_HASH" ]] \
    && [[ -z "$(git -C "$PROJECT" status --porcelain=v1 --untracked-files=all -- . \
      ':(exclude).wgm' ':(exclude).wgm/**')" ]] \
    && [[ ! -e "$PASS_WORKTREE" ]] \
    && ! git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$PASS_BRANCH"
}

snapshot_repository "$ROOT" "$TMP/real-after"
REAL_UNCHANGED=false
cmp -s "$TMP/real-before" "$TMP/real-after" && REAL_UNCHANGED=true
FIXTURE_UNCHANGED=false
fixture_unchanged && FIXTURE_UNCHANGED=true
EXTERNAL_CLIENTS_UNUSED=false
[[ ! -e "$TMP/external-client-called" ]] && EXTERNAL_CLIENTS_UNUSED=true

AUTHORITY_RESULT="$STATE/authority-result.json"
python3 - "$AUTHORITY_RESULT" "$REAL_UNCHANGED" "$FIXTURE_UNCHANGED" \
  "$EXTERNAL_CLIENTS_UNUSED" "$LIVE_REFUSAL_RC" "$PR_BLOCKED_RC" <<'PY'
import json
import sys

path, real_unchanged, fixture_unchanged, clients_unused, live_rc, pr_rc = sys.argv[1:]
value = {
    "schema": "stage10.deferred-authority-result.v1",
    "real_checkout_unchanged": real_unchanged == "true",
    "fixture_checkout_and_remotes_unchanged": fixture_unchanged == "true",
    "provider_network_and_hosting_clients_unused": clients_unused == "true",
    "unauthorized_live_exit_code": int(live_rc),
    "approval_without_explicit_flag_exit_code": int(pr_rc),
    "external_transitions": {
        "provider_or_model": False,
        "network_qualification": False,
        "remote_push": False,
        "pr_creation": False,
        "merge": False,
        "deployment": False,
        "publication": False,
        "policy_activation": False,
    },
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

REPORT_JSON="$STATE/report.json"
REPORT_MD="$STATE/report.md"
if PYTHONDONTWRITEBYTECODE=1 python3 - "$PROJECT" "$LIVE_OUTPUT" "$PASS_REPORT" \
  "$FAIL_REPORT" "$COMPARISON_REPORT" "$BUNDLE" "$GATE_RESULTS" "$AUTHORITY_RESULT" \
  "$REPORT_JSON" "$REPORT_MD" <<'PY'
import hashlib
import json
import pathlib
import sys

(
    project_raw,
    live_path_raw,
    passing_path_raw,
    failing_path_raw,
    comparison_path_raw,
    bundle_path_raw,
    gates_path_raw,
    authority_path_raw,
    report_json_raw,
    report_md_raw,
) = sys.argv[1:]
project = pathlib.Path(project_raw)
live_path = pathlib.Path(live_path_raw)
passing_path = pathlib.Path(passing_path_raw)
failing_path = pathlib.Path(failing_path_raw)
comparison_path = pathlib.Path(comparison_path_raw)
bundle_path = pathlib.Path(bundle_path_raw)
gates_path = pathlib.Path(gates_path_raw)
authority_path = pathlib.Path(authority_path_raw)
report_json = pathlib.Path(report_json_raw)
report_md = pathlib.Path(report_md_raw)

live = [json.loads(line) for line in live_path.read_text(encoding="utf-8").splitlines()]
passing = json.loads(passing_path.read_text(encoding="utf-8"))
failing = json.loads(failing_path.read_text(encoding="utf-8"))
comparison = json.loads(comparison_path.read_text(encoding="utf-8"))
bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
authority = json.loads(authority_path.read_text(encoding="utf-8"))
gates = []
for line in gates_path.read_text(encoding="utf-8").splitlines():
    name, exit_code, digest = line.split("\t")
    gates.append({"name": name, "exit_code": int(exit_code), "log_sha256": digest})

assert len(live) == 7
assert all(row["route"] == "authorized-local-double" for row in live)
assert all(row["environment"] == "offline-authorized-local-contract-double" for row in live)
assert all(row["route_status"] == "qualified" for row in live)
assert passing["status"] == "passed"
assert passing["cleanup"]["state"] == "retained-for-human-review"
assert not pathlib.Path(passing["identity"]["worktree"]).exists()
assert failing["result"] == "negative" and failing["cleanup"]["state"] == "removed"
assert comparison["winner"] == passing["frozen_manifest"]["id"]
assert any(
    ref.startswith("negative-execution-observed:")
    for ref in comparison["candidates"][0]["evidence"]
)
assert bundle["status"] == "ready"
assert bundle["candidate"]["head_branch"] == passing["identity"]["branch"]
assert all(gate["exit_code"] == 0 for gate in gates)
assert authority["unauthorized_live_exit_code"] == 2
assert authority["approval_without_explicit_flag_exit_code"] == 1
assert authority["real_checkout_unchanged"] is True
assert authority["fixture_checkout_and_remotes_unchanged"] is True
assert authority["provider_network_and_hosting_clients_unused"] is True
assert not any(authority["external_transitions"].values())

sources = {}
for label, path in {
    "live_qualification": live_path,
    "passing_execution": passing_path,
    "negative_execution": failing_path,
    "comparison": comparison_path,
    "pr_bundle": bundle_path,
    "gate_results": gates_path,
    "authority_result": authority_path,
}.items():
    sources[label] = {
        "path": path.relative_to(project).as_posix(),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }

report = {
    "schema": "stage10.deferred-e2e.v1",
    "status": "passed",
    "route": {
        "id": live[0]["route"],
        "label": "authorized local contract double",
        "environment": live[0]["environment"],
        "provider_qualified": False,
        "actual_live_qualification": "operator action not performed",
    },
    "bounded_runner": {
        "contract": "stage10.runner.v1",
        "qualification_phase_records": len(live) - 1,
        "execution_check_records": len(passing["checks"]) + len(failing["checks"]),
        "shell": False,
    },
    "authority": authority,
    "execution": {
        "passed_candidate": passing["frozen_manifest"]["id"],
        "review_identity_was_retained": passing["cleanup"]["state"],
        "review_identity_final_fixture_cleanup": "removed",
        "negative_candidate": failing["frozen_manifest"]["id"],
        "negative_result_preserved": failing["result"] == "negative",
        "negative_identity_cleanup": failing["cleanup"]["state"],
    },
    "comparison": {
        "winner": comparison["winner"],
        "negative_results": [failing["frozen_manifest"]["id"]],
        "feature_economy_eligible": comparison["feature_economy"]["eligible"],
    },
    "approval": {
        "metadata_without_explicit_flag": "awaiting-human-review",
        "approved_local_bundle": bundle["status"],
        "remaining_human_action": bundle["remaining_human_action"],
        "external_pr_action": "operator decision not performed",
    },
    "prior_and_boundary_gates": gates,
    "sources": sources,
    "operator_decisions": [
        "Actual live qualification remains an explicit operator action.",
        "Any push or external PR action remains an explicit operator decision.",
        "Policy activation and deployment remain separate human-governed actions.",
    ],
}
json_text = json.dumps(report, indent=2, sort_keys=True) + "\n"
markdown = "\n".join([
    "# Stage 10 deferred-boundary demonstration",
    "",
    f"- Route: `{report['route']['id']}` — **authorized local contract double**, not provider or Windows-origin evidence.",
    f"- T10 runner: `{report['bounded_runner']['contract']}` with direct argv and bounded result artifacts.",
    "- T11 authority: copied metadata refused before spawn; the explicit fixture authorization ran only the scoped local double.",
    f"- T12 execution: `{report['execution']['passed_candidate']}` was retained through human review, then removed by fixture cleanup; `{report['execution']['negative_candidate']}` kept its negative report and removed its failed Git identity.",
    f"- T7 comparison: winner `{report['comparison']['winner']}`; preserved negatives: `{', '.join(report['comparison']['negative_results'])}`.",
    f"- T13 handoff: metadata alone stayed `{report['approval']['metadata_without_explicit_flag']}`; explicit fixture approval produced a bounded local `{report['approval']['approved_local_bundle']}` bundle.",
    f"- T1-T9/T14 gates: {len(gates)} artifact-hashed checks exited 0.",
    "- Checkout boundary: the disposable source/remotes and the real checkout/remotes/refs/worktrees remained unchanged.",
    "",
    "## Operator decisions still required",
    "",
    "- Actual live qualification remains an explicit operator action; this fixture did not qualify a provider or model.",
    "- Any push or external PR action remains an explicit operator decision; no hosting client ran.",
    "- No merge, deployment, publication, or policy activation occurred.",
    "",
    "## Artifact provenance",
    "",
    *(f"- `{label}`: `{item['path']}` (`{item['sha256']}`)" for label, item in sources.items()),
    "",
])
assert len(json_text.encode()) <= 32768
assert len(markdown.encode()) <= 32768
report_json.write_text(json_text, encoding="utf-8")
report_md.write_text(markdown, encoding="utf-8")
PY
then
  if [[ "$(stat -c %s "$REPORT_JSON")" -le 32768 ]] \
    && [[ "$(stat -c %s "$REPORT_MD")" -le 32768 ]] \
    && grep -q 'Actual live qualification remains an explicit operator action' "$REPORT_MD" \
    && grep -q 'external PR action remains an explicit operator decision' "$REPORT_MD" \
    && grep -q 'authorized local contract double' "$REPORT_MD"; then
    pass "bounded final report is derived from generated artifacts and preserves operator authority"
  else
    fail "final report omitted a required bound or operator decision"
  fi
else
  fail "artifact-derived deferred-boundary report generation failed"
fi

if [[ "$REAL_UNCHANGED" == true ]] && [[ "$FIXTURE_UNCHANGED" == true ]] \
  && [[ "$EXTERNAL_CLIENTS_UNUSED" == true ]]; then
  pass "real and fixture checkouts/remotes stayed unchanged with no external client invocation"
else
  fail "checkout, remote, worktree, ref, or external-client boundary changed"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "stage10 deferred e2e harness: GREEN ($PASSED assertions passed)"
  exit 0
else
  echo "stage10 deferred e2e harness: RED" >&2
  exit 1
fi
