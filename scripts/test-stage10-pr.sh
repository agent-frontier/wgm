#!/usr/bin/env bash
#
# wgm/test-stage10-pr.sh — disposable local backpressure for human-gated PR preparation.
#
# This harness executes the real T12 and T7 contracts in a temporary Git fixture, then proves that
# invalid evidence and invalid human authority cannot emit a bundle. No hosting or network client
# is invoked, and the fixture's remote and protected base remain unchanged.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPERIMENTS="$ROOT/scripts/stage10_experiments.py"
PREPARE="$ROOT/scripts/stage10_pr.py"
FAILED=0
PASSED=0
pass() { printf 'ok:   %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

[[ -f "$EXPERIMENTS" ]] || { fail "missing $EXPERIMENTS"; exit 1; }
[[ -f "$PREPARE" ]] || { fail "missing $PREPARE"; exit 1; }
command -v python3 >/dev/null 2>&1 || { fail "python3 is required"; exit 1; }
command -v git >/dev/null 2>&1 || { fail "git is required"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wgm-stage10-pr.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
REMOTE="$TMP/remote.git"
HOSTING_MARKER="$TMP/hosting-client-called"
CACHE_BEFORE="$(find "$ROOT/scripts/__pycache__" -maxdepth 1 \
  \( -name 'stage10_pr.*.pyc' -o -name 'stage10_experiments.*.pyc' \) -print 2>/dev/null | sort)"
mkdir -p "$PROJECT/.wgm" "$TMP/bin"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email stage10@example.invalid
git -C "$PROJECT" config user.name stage10-fixture
printf '/.wgm/\n' >"$PROJECT/.gitignore"
printf 'baseline\n' >"$PROJECT/app.txt"
printf 'protected\n' >"$PROJECT/protected.txt"
cat >"$PROJECT/check.py" <<'PY'
import pathlib
import sys
raise SystemExit(0 if pathlib.Path("app.txt").read_text() == "candidate\n" else 9)
PY
git -C "$PROJECT" add .gitignore app.txt protected.txt check.py
git -C "$PROJECT" commit -q -m 'fixture: PR preparation baseline'
git init -q --bare "$REMOTE"
git -C "$PROJECT" remote add origin "$REMOTE"
BASELINE="$(git -C "$PROJECT" rev-parse HEAD)"
BASE_BRANCH="$(git -C "$PROJECT" branch --show-current)"
BASE_REMOTE_STATE="$(git --git-dir="$REMOTE" show-ref 2>/dev/null || true)"
BASE_PROTECTED_HASH="$(sha256sum "$PROJECT/protected.txt" | cut -d' ' -f1)"
cat >"$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
printf 'called\n' >"$HOSTING_MARKER"
exit 99
EOF
chmod +x "$TMP/bin/gh"

printf 'candidate\n' >"$PROJECT/app.txt"
git -C "$PROJECT" diff --binary -- app.txt >"$PROJECT/.wgm/candidate.patch"
git -C "$PROJECT" checkout -q -- app.txt
EXECUTION_MANIFEST="$PROJECT/.wgm/execution.json"
python3 - "$EXECUTION_MANIFEST" "$BASELINE" <<'PY'
import json
import sys
path, baseline = sys.argv[1:]
value = {
    "id": "approved-candidate",
    "hypothesis": "the candidate improves the local fixture",
    "baseline_sha": baseline,
    "candidate": {"patch": ".wgm/candidate.patch"},
    "route": {"id": "local-fixture", "evidence": "fixture"},
    "environment": {"kind": "disposable-local-git", "network": False},
    "allowed_files": ["app.txt"],
    "evaluator": {
        "name": "evaluator",
        "argv": ["python3", "check.py"],
        "timeout_seconds": 1,
    },
    "non_regression": [{
        "name": "tests",
        "argv": ["python3", "check.py"],
        "timeout_seconds": 1,
    }],
    "budget": {"seconds": 3, "cost_units": 0},
}
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
EXECUTION_HASH="$(sha256sum "$EXECUTION_MANIFEST" | cut -d' ' -f1)"
EXECUTION_REPORT="$PROJECT/.wgm/stage10/experiments/executions/approved-candidate-${EXECUTION_HASH:0:12}.json"
PYTHONDONTWRITEBYTECODE=1 python3 "$EXPERIMENTS" execute \
  --root "$PROJECT" --manifest "$EXECUTION_MANIFEST" >/dev/null \
  || { fail "could not create prerequisite T12 execution report"; exit 1; }
HEAD_BRANCH="stage10/experiment/approved-candidate-${EXECUTION_HASH:0:12}"
WORKTREE="$PROJECT/.wgm/stage10/worktrees/approved-candidate-${EXECUTION_HASH:0:12}"

COMPARISON_MANIFEST="$PROJECT/.wgm/comparison.json"
python3 - "$COMPARISON_MANIFEST" "$BASELINE" "$HEAD_BRANCH" <<'PY'
import json
import sys
path, baseline, branch = sys.argv[1:]
value = {
    "hypothesis": "the candidate improves the local fixture",
    "baseline_sha": baseline,
    "route": {"id": "local-fixture", "evidence": "fixture"},
    "environment": {"kind": "disposable-local-git", "network": False},
    "allowed_files": ["app.txt"],
    "evaluator": "evaluator",
    "target_metric": "quality",
    "metric_direction": "max",
    "non_regression": ["tests", "holdout"],
    "budget": {"seconds": 3, "cost_units": 0},
    "retirements": [
        {"retired": "old-route", "evidence": ["test:old-route"]},
        {"retired": "duplicate-view", "evidence": ["review:consolidation"]},
    ],
    "candidates": [{
        "id": "approved-candidate",
        "branch": branch,
        "metric": 9,
        "holdout_pass": True,
        "gates": [{"name": "tests", "passed": True}],
        "changed_files": ["app.txt"],
        "evidence": ["run:execution", "judge:holdout"],
    }],
}
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
COMPARISON_REPORT="$PROJECT/.wgm/stage10/experiments/comparison.json"
PYTHONDONTWRITEBYTECODE=1 python3 "$EXPERIMENTS" compare \
  --root "$PROJECT" --manifest "$COMPARISON_MANIFEST" --output "$COMPARISON_REPORT" >/dev/null \
  || { fail "could not create prerequisite T7 comparison report"; exit 1; }

APPROVAL="$PROJECT/.wgm/approval.json"
write_approval() {
  local expiry="${1:-2099-01-01T00:00:00Z}" mode="${2:-match}"
  python3 - "$APPROVAL" "$EXECUTION_REPORT" "$COMPARISON_REPORT" "$HEAD_BRANCH" \
    "$BASE_BRANCH" "$BASELINE" "$expiry" "$mode" <<'PY'
import hashlib
import json
import sys

approval, execution_path, comparison_path, head, base, baseline, expiry, mode = sys.argv[1:]
execution = json.load(open(execution_path, encoding="utf-8"))
value = {
    "schema": "stage10.pr-approval.v1",
    "approved": True,
    "approver": "fixture-maintainer",
    "expires_at": expiry,
    "execution_report_sha256": hashlib.sha256(open(execution_path, "rb").read()).hexdigest(),
    "comparison_report_sha256": hashlib.sha256(open(comparison_path, "rb").read()).hexdigest(),
    "candidate_snapshot_sha256": execution["candidate_snapshot_sha256"],
    "head_branch": head,
    "base_branch": base,
    "baseline_sha": baseline,
    "allowed_files": execution["allowed_files"],
}
if mode == "mismatch":
    value["head_branch"] = "stage10/experiment/not-approved"
json.dump(value, open(approval, "w", encoding="utf-8"), sort_keys=True)
PY
}

run_prepare() {
  local execution="${1:-$EXECUTION_REPORT}" comparison="${2:-$COMPARISON_REPORT}"
  shift 2 2>/dev/null || true
  set +e
  OUT="$(PATH="$TMP/bin:$PATH" python3 "$PREPARE" prepare \
    --root "$PROJECT" --execution-report "$execution" --comparison-report "$comparison" "$@" 2>&1)"
  RC=$?
  set -e
}

assert_no_bundle() {
  [[ ! -d "$PROJECT/.wgm/stage10/pr" ]] \
    || [[ -z "$(find "$PROJECT/.wgm/stage10/pr" -type f -print -quit)" ]]
}

# 1) A failed T12 report is evidence, not PR authority, even if its other fields look plausible.
FAILED_REPORT="$PROJECT/.wgm/failed-execution.json"
python3 - "$EXECUTION_REPORT" "$FAILED_REPORT" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["status"] = "failed"
value["result"] = "negative"
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=True)
PY
run_prepare "$FAILED_REPORT" "$COMPARISON_REPORT"
if [[ "$RC" -eq 1 ]] && grep -q 'execution report is not passed' <<<"$OUT" && assert_no_bundle; then
  pass "failed execution reports cannot become ready"
else
  fail "failed execution report was not blocked (rc=$RC): $OUT"
fi

# 2) An allowed-path edit after T12 invalidates the final snapshot instead of silently reusing it.
printf 'candidate changed after execution\n' >"$WORKTREE/app.txt"
run_prepare "$EXECUTION_REPORT" "$COMPARISON_REPORT"
if [[ "$RC" -eq 1 ]] && grep -q 'retained candidate content changed' <<<"$OUT" && assert_no_bundle; then
  pass "stale in-scope candidate content requires fresh execution evidence"
else
  fail "stale candidate content was not blocked (rc=$RC): $OUT"
fi
printf 'candidate\n' >"$WORKTREE/app.txt"

# 3) Report scope cannot be broadened beyond the exact T12/T7 allowed-file contract.
OUT_OF_SCOPE="$PROJECT/.wgm/out-of-scope-comparison.json"
python3 - "$COMPARISON_REPORT" "$OUT_OF_SCOPE" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["candidates"][0]["changed_files"] = ["protected.txt"]
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=True)
PY
run_prepare "$EXECUTION_REPORT" "$OUT_OF_SCOPE"
if [[ "$RC" -eq 1 ]] && grep -q 'escaped allowed scope' <<<"$OUT" && assert_no_bundle; then
  pass "out-of-scope comparison evidence cannot become ready"
else
  fail "out-of-scope report was not blocked (rc=$RC): $OUT"
fi

# 4) T7 remains the economy authority; changing a report to one retirement cannot be approved.
UNDER_RETIRED="$PROJECT/.wgm/under-retired-comparison.json"
python3 - "$COMPARISON_REPORT" "$UNDER_RETIRED" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["feature_economy"]["eligible"] = False
value["feature_economy"]["retirements"] = value["feature_economy"]["retirements"][:1]
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=True)
PY
run_prepare "$EXECUTION_REPORT" "$UNDER_RETIRED"
if [[ "$RC" -eq 1 ]] && grep -q 'under-retired' <<<"$OUT" && assert_no_bundle; then
  pass "under-retired comparison reports remain blocked"
else
  fail "under-retired report was not blocked (rc=$RC): $OUT"
fi

# 5) Report-declared runner paths cannot hide a real out-of-scope worktree edit.
TAMPERED_EXECUTION="$PROJECT/.wgm/tampered-execution.json"
python3 - "$EXECUTION_REPORT" "$TAMPERED_EXECUTION" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["checks"][0]["runner_manifest"] = "protected.txt"
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=True)
PY
printf 'hidden out-of-scope edit\n' >"$WORKTREE/protected.txt"
run_prepare "$TAMPERED_EXECUTION" "$COMPARISON_REPORT"
if [[ "$RC" -eq 1 ]] && grep -q 'does not match exact passing evidence' <<<"$OUT" \
  && assert_no_bundle; then
  pass "tampered execution evidence cannot hide out-of-scope candidate files"
else
  fail "tampered execution evidence was not blocked (rc=$RC): $OUT"
fi
printf 'protected\n' >"$WORKTREE/protected.txt"

# 6) Passing reports alone remain visibly blocked at the human checkpoint.
run_prepare "$EXECUTION_REPORT" "$COMPARISON_REPORT"
if [[ "$RC" -eq 1 ]] && grep -q 'awaiting-human-review' <<<"$OUT" && assert_no_bundle; then
  pass "absent human approval leaves the candidate awaiting review"
else
  fail "missing approval did not block bundle generation (rc=$RC): $OUT"
fi

# 7) A matching approval file is inert unless the operator also supplies --human-approve.
write_approval
run_prepare "$EXECUTION_REPORT" "$COMPARISON_REPORT" --approval-file "$APPROVAL"
if [[ "$RC" -eq 1 ]] && grep -q 'awaiting-human-review' <<<"$OUT" && assert_no_bundle; then
  pass "approval metadata cannot replace the explicit human action"
else
  fail "missing explicit approval flag did not block (rc=$RC): $OUT"
fi

# 8) Expired approval cannot be silently reused.
write_approval "2000-01-01T00:00:00Z"
run_prepare "$EXECUTION_REPORT" "$COMPARISON_REPORT" \
  --approval-file "$APPROVAL" --human-approve
if [[ "$RC" -eq 1 ]] && grep -q 'approval has expired' <<<"$OUT" && assert_no_bundle; then
  pass "expired approval remains blocked"
else
  fail "expired approval was not blocked (rc=$RC): $OUT"
fi

# 9) Approval scope must match the exact local head rather than a plausible branch label.
write_approval "2099-01-01T00:00:00Z" mismatch
run_prepare "$EXECUTION_REPORT" "$COMPARISON_REPORT" \
  --approval-file "$APPROVAL" --human-approve
if [[ "$RC" -eq 1 ]] && grep -q 'head_branch does not match' <<<"$OUT" && assert_no_bundle; then
  pass "mismatched approval scope remains blocked"
else
  fail "mismatched approval was not blocked (rc=$RC): $OUT"
fi

# 10) Changing a report after approval invalidates the bound report hash.
write_approval
TAMPERED="$PROJECT/.wgm/tampered-comparison.json"
cp "$COMPARISON_REPORT" "$TAMPERED"
python3 - "$TAMPERED" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["recorded_at"] = "2099-01-01T00:00:00Z"
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
run_prepare "$EXECUTION_REPORT" "$TAMPERED" --approval-file "$APPROVAL" --human-approve
if [[ "$RC" -eq 1 ]] && grep -q 'comparison_report_sha256 does not match' <<<"$OUT" \
  && assert_no_bundle; then
  pass "tampered report bytes invalidate the hash-bound approval"
else
  fail "tampered report was not blocked (rc=$RC): $OUT"
fi

# 11) A symlinked output boundary is refused before either local bundle file is written.
write_approval
mkdir -p "$TMP/outside-pr-output"
ln -s "$TMP/outside-pr-output" "$PROJECT/.wgm/stage10/pr"
run_prepare "$EXECUTION_REPORT" "$COMPARISON_REPORT" \
  --approval-file "$APPROVAL" --human-approve
if [[ "$RC" -eq 2 ]] && grep -q 'output boundary must not traverse symlinks' <<<"$OUT" \
  && [[ -z "$(find "$TMP/outside-pr-output" -type f -print -quit)" ]]; then
  pass "symlinked PR output boundary cannot escape the project"
else
  fail "symlinked output boundary was not blocked (rc=$RC): $OUT"
fi
rm "$PROJECT/.wgm/stage10/pr"

# 12) Pair publication removes a ready JSON if the Markdown publication fails.
if PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/scripts" "$PROJECT/.wgm/stage10/pr" <<'PY'
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
import stage10_pr

directory = pathlib.Path(sys.argv[2])
json_path = directory / "injected-failure.json"
markdown_path = directory / "injected-failure.md"
real_replace = stage10_pr.os.replace
calls = 0

def fail_second(source, target):
    global calls
    calls += 1
    if calls == 2:
        raise OSError("fixture second-publication failure")
    return real_replace(source, target)

stage10_pr.os.replace = fail_second
try:
    stage10_pr.write_bundle_pair(json_path, "{}\n", markdown_path, "# body\n", lambda: None)
except OSError as exc:
    assert "fixture second-publication failure" in str(exc)
else:
    raise AssertionError("second publication unexpectedly succeeded")
assert not json_path.exists()
assert not markdown_path.exists()
PY
then
  pass "JSON/Markdown publication rolls back a partial ready pair"
else
  fail "partial bundle publication was not rolled back"
fi

# 13) Only exact evidence plus both human controls emits the bounded local JSON/Markdown handoff.
write_approval
run_prepare "$EXECUTION_REPORT" "$COMPARISON_REPORT" \
  --approval-file "$APPROVAL" --human-approve
BUNDLE="$(find "$PROJECT/.wgm/stage10/pr" -maxdepth 1 -name '*.json' -print -quit)"
BODY="${BUNDLE%.json}.md"
if [[ "$RC" -eq 0 ]] && [[ -f "$BUNDLE" ]] && [[ -f "$BODY" ]] \
  && [[ "$(stat -c %s "$BUNDLE")" -le 200000 ]] && [[ "$(stat -c %s "$BODY")" -le 200000 ]] \
  && [[ ! -e "$HOSTING_MARKER" ]] \
  && [[ "$(git --git-dir="$REMOTE" show-ref 2>/dev/null || true)" == "$BASE_REMOTE_STATE" ]] \
  && [[ "$(sha256sum "$PROJECT/protected.txt" | cut -d' ' -f1)" == "$BASE_PROTECTED_HASH" ]] \
  && [[ "$(git -C "$PROJECT" rev-parse "$BASE_BRANCH")" == "$BASELINE" ]] \
  && [[ "$(find "$ROOT/scripts/__pycache__" -maxdepth 1 \
      \( -name 'stage10_pr.*.pyc' -o -name 'stage10_experiments.*.pyc' \) \
      -print 2>/dev/null | sort)" == "$CACHE_BEFORE" ]] \
  && PYTHONDONTWRITEBYTECODE=1 python3 - "$BUNDLE" "$BODY" "$HEAD_BRANCH" "$BASE_BRANCH" <<'PY'
import json
import pathlib
import sys
bundle_path, body_path, head, base = sys.argv[1:]
bundle = json.load(open(bundle_path, encoding="utf-8"))
body = pathlib.Path(body_path).read_text(encoding="utf-8")
assert bundle["schema"] == "stage10.pr-bundle.v1"
assert bundle["status"] == "ready"
assert bundle["candidate"]["head_branch"] == head
assert bundle["candidate"]["base_branch"] == base
assert bundle["candidate"]["changed_files"] == ["app.txt"]
assert len(bundle["candidate"]["candidate_snapshot_sha256"]) == 64
assert all(item["status"] == "passed" and item["argv"] for item in bundle["validation"]["execution_checks"])
assert bundle["validation"]["holdout_pass"] is True
assert bundle["feature_economy"]["eligible"] is True
assert len(bundle["feature_economy"]["retirements"]) == 2
assert len(bundle["source_reports"]["execution"]["sha256"]) == 64
assert len(bundle["source_reports"]["comparison"]["sha256"]) == 64
assert "remaining_human_action" in bundle
assert "push and create the PR" in bundle["remaining_human_action"]
assert "Remaining human action" in body
assert "Exact validation" in body
assert "no hosting client" in bundle["authority"]
PY
then
  pass "matching hash-bound approval emits only a bounded report-derived local handoff"
else
  fail "approved local bundle contract failed (rc=$RC): $OUT"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "stage10 PR preparation harness: GREEN ($PASSED assertions passed)"
  exit 0
else
  echo "stage10 PR preparation harness: RED" >&2
  exit 1
fi
