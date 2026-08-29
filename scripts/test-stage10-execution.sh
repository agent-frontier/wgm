#!/usr/bin/env bash
#
# wgm/test-stage10-execution.sh — local fixture backpressure for isolated experiment execution.
#
# Every command runs against disposable local Git repositories. The harness never calls a provider,
# model, network, credential store, gh, remote push, PR, merge, deploy, publish, or policy action.
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
command -v git >/dev/null 2>&1 || { fail "git is required"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wgm-stage10-execution.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

new_fixture() {
  local name="$1"
  PROJECT="$TMP/$name"
  mkdir -p "$PROJECT/.wgm"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email stage10@example.invalid
  git -C "$PROJECT" config user.name stage10-fixture
  printf '/.wgm/\n' >"$PROJECT/.gitignore"
  printf 'baseline\n' >"$PROJECT/app.txt"
  printf 'protected\n' >"$PROJECT/protected.txt"
  cat >"$PROJECT/check.py" <<'PY'
import pathlib
import sys
import time

mode = sys.argv[1]
if mode == "pass":
    raise SystemExit(0 if pathlib.Path("app.txt").read_text() == "candidate\n" else 8)
if mode == "fail":
    print("fixture evaluator failed", file=sys.stderr)
    raise SystemExit(9)
if mode == "hang":
    time.sleep(5)
if mode == "mutate":
    pathlib.Path("escaped.txt").write_text("outside declared scope\n")
if mode == "mutate-evidence":
    checks = list(pathlib.Path(".wgm/stage10/experiments/executions").glob("*/checks"))
    if len(checks) != 1:
        raise SystemExit(10)
    (checks[0] / "smuggled.txt").write_text("outside generated evidence files\n")
PY
  git -C "$PROJECT" add .gitignore app.txt protected.txt check.py
  git -C "$PROJECT" commit -q -m 'fixture: execution baseline'
  git init -q --bare "$TMP/$name-remote.git"
  git -C "$PROJECT" remote add origin "$TMP/$name-remote.git"
  BASELINE="$(git -C "$PROJECT" rev-parse HEAD)"
  SOURCE_BRANCH="$(git -C "$PROJECT" branch --show-current)"
  SOURCE_REMOTES="$(git -C "$PROJECT" remote -v)"
}

make_patch() {
  local include_protected="${1:-no}"
  printf 'candidate\n' >"$PROJECT/app.txt"
  if [[ "$include_protected" == "yes" ]]; then
    printf 'candidate escaped scope\n' >"$PROJECT/protected.txt"
  fi
  git -C "$PROJECT" diff --binary -- app.txt protected.txt >"$PROJECT/.wgm/candidate.patch"
  git -C "$PROJECT" checkout -q -- app.txt protected.txt
}

write_manifest() {
  local identifier="$1" baseline="$2" evaluator_mode="$3"
  local evaluator_timeout="${4:-1}" budget="${5:-3}" non_regression_mode="${6:-pass}"
  python3 - "$PROJECT/.wgm/execution.json" "$identifier" "$baseline" "$evaluator_mode" \
    "$evaluator_timeout" "$budget" "$non_regression_mode" <<'PY'
import json
import sys

path, identifier, baseline, evaluator_mode, evaluator_timeout, budget, non_regression_mode = sys.argv[1:]
manifest = {
    "id": identifier,
    "hypothesis": "the local fixture candidate passes bounded checks",
    "baseline_sha": baseline,
    "candidate": {"patch": ".wgm/candidate.patch"},
    "route": {"id": "local-fixture", "evidence": "fixture"},
    "environment": {"kind": "disposable-local-git", "network": False},
    "allowed_files": ["app.txt"],
    "evaluator": {
        "name": "evaluator",
        "argv": ["python3", "check.py", evaluator_mode],
        "timeout_seconds": float(evaluator_timeout),
    },
    "non_regression": [{
        "name": "non-regression",
        "argv": ["python3", "check.py", non_regression_mode],
        "timeout_seconds": 1,
    }],
    "budget": {"seconds": float(budget), "cost_units": 0},
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, sort_keys=True)
PY
  MANIFEST_HASH="$(python3 - "$PROJECT/.wgm/execution.json" <<'PY'
import hashlib
import pathlib
import sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
  SUFFIX="${identifier}-${MANIFEST_HASH:0:12}"
  BRANCH="stage10/experiment/$SUFFIX"
  WORKTREE="$PROJECT/.wgm/stage10/worktrees/$SUFFIX"
  REPORT="$PROJECT/.wgm/stage10/experiments/executions/$SUFFIX.json"
}

run_execution() {
  set +e
  OUT="$(PYTHONDONTWRITEBYTECODE=1 python3 "$EXPERIMENTS" execute \
    --root "$PROJECT" --manifest "$PROJECT/.wgm/execution.json" "$@" 2>&1)"
  RC=$?
  set -e
}

source_unchanged() {
  [[ "$(git -C "$PROJECT" rev-parse HEAD)" == "$BASELINE" ]] \
    && [[ "$(git -C "$PROJECT" branch --show-current)" == "$SOURCE_BRANCH" ]] \
    && [[ -z "$(git -C "$PROJECT" status --porcelain=v1 --untracked-files=all -- . ':(exclude).wgm' ':(exclude).wgm/**')" ]] \
    && [[ "$(git -C "$PROJECT" remote -v)" == "$SOURCE_REMOTES" ]]
}

# 1) This assertion protects the core clean path: candidate material is isolated, every executable
# check uses T10's direct-argv result contract, and only local review artifacts are retained.
new_fixture success
make_patch
write_manifest clean "$BASELINE" pass
run_execution
if [[ "$RC" -eq 0 ]] && [[ -f "$REPORT" ]] && [[ -d "$WORKTREE" ]] \
   && git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$BRANCH" \
   && [[ -z "$(git --git-dir="$TMP/success-remote.git" for-each-ref --format='%(refname)')" ]] \
   && grep -q '^count: 0$' < <(git --git-dir="$TMP/success-remote.git" count-objects -v) \
   && source_unchanged \
   && PYTHONDONTWRITEBYTECODE=1 python3 - "$REPORT" "$WORKTREE" "$BRANCH" "$BASELINE" <<'PY'
import json
import pathlib
import subprocess
import sys

report_path, worktree, branch, baseline = sys.argv[1:]
report = json.load(open(report_path, encoding="utf-8"))
assert report["status"] == "passed"
assert report["result"] == "execution-passed"
assert report["baseline_sha"] == baseline
assert report["changed_files"] == ["app.txt"]
assert len(report["candidate_snapshot_sha256"]) == 64
assert report["source_checkout"]["unchanged"] is True
assert report["cleanup"]["state"] == "retained-for-human-review"
assert report["pr_eligible"] is False
assert len(report["checks"]) == 2
assert all(check["runner_contract"] == "stage10.runner.v1" for check in report["checks"])
assert all(check["runner_result_record"]["shell"] is False for check in report["checks"])
assert pathlib.Path(worktree).resolve().is_relative_to(
    pathlib.Path(report["identity"]["source_root"], ".wgm/stage10/worktrees").resolve()
)
assert subprocess.check_output(
    ["git", "-C", worktree, "rev-parse", "--show-toplevel"], text=True
).strip() == worktree
assert subprocess.check_output(
    ["git", "-C", worktree, "branch", "--show-current"], text=True
).strip() == branch
PY
then
  pass "clean execution retains a verified local branch/worktree and T10-backed evidence"
else
  fail "clean execution contract failed (rc=$RC): $OUT"
fi

# 2) This assertion protects the comparison authority boundary: an execution success is not a T7
# comparison manifest and cannot bypass hard non-regression, holdout, or feature-economy evidence.
set +e
COMPARE_OUT="$(PYTHONDONTWRITEBYTECODE=1 python3 "$EXPERIMENTS" compare \
  --root "$PROJECT" --manifest "$REPORT" 2>&1)"
COMPARE_RC=$?
set -e
if [[ "$COMPARE_RC" -eq 2 ]] && grep -q 'manifest missing:' <<<"$COMPARE_OUT"; then
  pass "execution success cannot bypass the T7 comparison and economy contract"
else
  fail "execution report entered comparison authority (rc=$COMPARE_RC): $COMPARE_OUT"
fi
git -C "$PROJECT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
git -C "$PROJECT" branch -D "$BRANCH" >/dev/null 2>&1 || true

# 3) This assertion protects baseline freshness: a stale SHA is reported before any branch or
# worktree exists, while the source branch, HEAD, status, and local remote configuration stay fixed.
new_fixture stale
make_patch
write_manifest stale 0123456789abcdef0123456789abcdef01234567 pass
run_execution
if [[ "$RC" -eq 1 ]] && [[ -f "$REPORT" ]] && [[ ! -e "$WORKTREE" ]] \
   && ! git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$BRANCH" \
   && grep -q 'stale baseline' "$REPORT" && source_unchanged; then
  pass "stale baseline is refused before Git mutation"
else
  fail "stale baseline guard failed (rc=$RC): $OUT"
fi

# 4) This assertion protects an operator's checkout: tracked dirt outside .wgm cannot be mistaken
# for candidate material and is never reset or otherwise repaired by the executor.
new_fixture dirty
make_patch
write_manifest dirty "$BASELINE" pass
printf 'operator edit\n' >>"$PROJECT/README.md"
run_execution
if [[ "$RC" -eq 1 ]] && grep -q 'dirty outside .wgm' "$REPORT" \
   && [[ ! -e "$WORKTREE" ]] && grep -q 'operator edit' "$PROJECT/README.md" \
   && [[ "$(git -C "$PROJECT" rev-parse HEAD)" == "$BASELINE" ]]; then
  pass "dirty source checkout is refused without resetting operator work"
else
  fail "dirty-checkout guard failed (rc=$RC): $OUT"
fi

# 5) This assertion protects concurrent local work: a pre-existing generated branch name blocks
# setup and remains intact rather than being mistaken for a failed branch owned by this execution.
new_fixture branch-collision
make_patch
write_manifest branch-collision "$BASELINE" pass
git -C "$PROJECT" branch "$BRANCH" "$BASELINE"
run_execution
if [[ "$RC" -eq 1 ]] && grep -q 'branch collision' "$REPORT" \
   && git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$BRANCH" \
   && [[ ! -e "$WORKTREE" ]] && source_unchanged; then
  pass "branch collision is refused before worktree creation"
else
  fail "branch-collision guard failed (rc=$RC): $OUT"
fi

# 6) This assertion protects an occupied filesystem path: the executor reports the collision before
# Git mutation and does not delete or overwrite the marker owned by another operation.
new_fixture path-collision
make_patch
write_manifest path-collision "$BASELINE" pass
mkdir -p "$WORKTREE"
printf 'owned elsewhere\n' >"$WORKTREE/marker"
run_execution
if [[ "$RC" -eq 1 ]] && grep -q 'worktree path collision' "$REPORT" \
   && grep -q 'owned elsewhere' "$WORKTREE/marker" \
   && ! git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$BRANCH" \
   && source_unchanged; then
  pass "occupied worktree path is refused without deleting foreign state"
else
  fail "worktree-path collision guard failed (rc=$RC): $OUT"
fi

# 7) This assertion protects path confinement: an escaping patch path is rejected while parsing the
# frozen manifest, before an output, branch, or worktree can be created.
new_fixture confinement
make_patch
write_manifest confinement "$BASELINE" pass
python3 - "$PROJECT/.wgm/execution.json" <<'PY'
import json
import sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["candidate"]["patch"] = "../candidate.patch"
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
run_execution
if [[ "$RC" -eq 2 ]] && grep -q "without '..'" <<<"$OUT" \
   && [[ ! -d "$PROJECT/.wgm/stage10/worktrees" ]] \
   && [[ ! -d "$PROJECT/.wgm/stage10/experiments/executions" ]] \
   && source_unchanged; then
  pass "escaping candidate path is rejected before any execution mutation"
else
  fail "path-confinement guard failed (rc=$RC): $OUT"
fi

# 8) This assertion protects negative evidence and recovery: a hard evaluator failure is retained in
# JSON while its disposable worktree and branch are removed and the source checkout stays unchanged.
new_fixture evaluator-failure
make_patch
write_manifest evaluator-failure "$BASELINE" fail
run_execution
if [[ "$RC" -eq 1 ]] && [[ -f "$REPORT" ]] && [[ ! -e "$WORKTREE" ]] \
   && ! git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$BRANCH" \
   && source_unchanged \
   && PYTHONDONTWRITEBYTECODE=1 python3 - "$REPORT" <<'PY'
import json
import sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["status"] == "failed"
assert report["result"] == "negative"
assert report["cleanup"]["state"] == "removed"
assert report["checks"][0]["runner_result_record"]["status"] == "failed"
assert report["source_checkout"]["unchanged"] is True
PY
then
  pass "failed evaluator preserves negative T10 evidence and removes failed Git identity"
else
  fail "failed-evaluator cleanup contract failed (rc=$RC): $OUT"
fi

# 9) This assertion protects the aggregate budget rather than only per-command timeouts: remaining
# total time caps the second check, whose timeout result is retained before full cleanup.
new_fixture budget
make_patch
write_manifest budget "$BASELINE" pass 1 0.25 hang
run_execution
if [[ "$RC" -eq 1 ]] && [[ -f "$REPORT" ]] && [[ ! -e "$WORKTREE" ]] \
   && ! git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$BRANCH" \
   && source_unchanged \
   && PYTHONDONTWRITEBYTECODE=1 python3 - "$REPORT" <<'PY'
import json
import sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["status"] == "timeout"
assert report["cleanup"]["state"] == "removed"
assert report["checks"][-1]["runner_result_record"]["status"] == "timeout"
assert report["checks"][-1]["effective_timeout_seconds"] < 1
assert report["budget"]["remaining_ms"] == 0
PY
then
  pass "total budget bounds non-regression execution and timeout cleanup"
else
  fail "aggregate-budget guard failed (rc=$RC): $OUT"
fi

# 10) This assertion protects the declared file surface: out-of-scope candidate content is diagnosed
# before evaluator execution, retained in the report, and removed with the failed Git identity.
new_fixture out-of-scope
make_patch yes
write_manifest out-of-scope "$BASELINE" pass
run_execution
if [[ "$RC" -eq 1 ]] && grep -q 'outside allowed_files' "$REPORT" \
   && [[ ! -e "$WORKTREE" ]] \
   && ! git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$BRANCH" \
   && source_unchanged \
   && PYTHONDONTWRITEBYTECODE=1 python3 - "$REPORT" <<'PY'
import json
import sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["status"] == "out-of-scope"
assert report["checks"] == []
assert report["changed_files"] == ["app.txt", "protected.txt"]
assert report["cleanup"]["state"] == "removed"
PY
then
  pass "out-of-scope candidate is rejected before checks and cleaned up"
else
  fail "allowed-files guard failed (rc=$RC): $OUT"
fi

# 11) This assertion protects the evidence directory from becoming a scope blind spot: only the
# exact T10 manifest/result files are exempt, so evaluator-created neighbors still fail closed.
new_fixture evidence-scope
make_patch
write_manifest evidence-scope "$BASELINE" mutate-evidence
run_execution
if [[ "$RC" -eq 1 ]] && grep -q 'outside allowed_files' "$REPORT" \
   && [[ ! -e "$WORKTREE" ]] \
   && ! git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$BRANCH" \
   && source_unchanged \
   && PYTHONDONTWRITEBYTECODE=1 python3 - "$REPORT" <<'PY'
import json
import sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["status"] == "out-of-scope"
assert any(path.endswith("/checks/smuggled.txt") for path in report["changed_files"])
assert report["cleanup"]["state"] == "removed"
PY
then
  pass "generated evidence exemption cannot hide evaluator-created files"
else
  fail "generated-evidence scope guard failed (rc=$RC): $OUT"
fi

# 12) This assertion protects immutable evidence: an existing report causes a pre-mutation refusal,
# and neither its content nor a branch/worktree is replaced by a repeated execution.
new_fixture output-collision
make_patch
write_manifest output-collision "$BASELINE" pass
mkdir -p "$(dirname "$REPORT")"
printf 'existing evidence\n' >"$REPORT"
run_execution
if [[ "$RC" -eq 2 ]] && grep -q 'output already exists' <<<"$OUT" \
   && [[ "$(cat "$REPORT")" == "existing evidence" ]] \
   && [[ ! -e "$WORKTREE" ]] \
   && ! git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$BRANCH" \
   && source_unchanged; then
  pass "output collision preserves existing evidence before Git mutation"
else
  fail "output-collision guard failed (rc=$RC): $OUT"
fi

# 13) This assertion protects partial setup recovery: even if Git reports failure after creating the
# branch/worktree, the prepared report is finalized and both pieces of failed identity are removed.
new_fixture setup-failure
make_patch
write_manifest setup-failure "$BASELINE" pass
REAL_GIT="$(command -v git)"
mkdir -p "$TMP/setup-bin"
cat >"$TMP/setup-bin/git" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" worktree add "* ]]; then
  "$REAL_GIT" "\$@"
  exit 23
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMP/setup-bin/git"
set +e
OUT="$(PATH="$TMP/setup-bin:$PATH" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$EXPERIMENTS" execute \
  --root "$PROJECT" --manifest "$PROJECT/.wgm/execution.json" 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 1 ]] && [[ -f "$REPORT" ]] && [[ ! -e "$WORKTREE" ]] \
   && ! git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$BRANCH" \
   && source_unchanged \
   && PYTHONDONTWRITEBYTECODE=1 python3 - "$REPORT" <<'PY'
import json
import sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["status"] == "failed"
assert report["result"] == "negative"
assert report["cleanup"]["state"] == "removed"
assert "removed failed worktree" in report["cleanup"]["actions"]
assert "removed failed branch" in report["cleanup"]["actions"]
assert report["source_checkout"]["unchanged"] is True
PY
then
  pass "partial worktree setup failure is reported and fully cleaned"
else
  fail "partial-setup cleanup contract failed (rc=$RC): $OUT"
fi

# 14) This assertion protects the local-only authority envelope: direct argv is not permission to
# invoke a hosting client or mutate/publish a Git ref from an experiment evaluator.
new_fixture authority-command
make_patch
write_manifest authority-command "$BASELINE" pass
python3 - "$PROJECT/.wgm/execution.json" <<'PY'
import json
import sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["evaluator"]["argv"] = ["git", "push", "origin", "HEAD"]
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
run_execution
if [[ "$RC" -eq 2 ]] && grep -q 'external-authority executable\|mutating git operation' <<<"$OUT" \
   && [[ ! -e "$REPORT" ]] && [[ ! -e "$WORKTREE" ]] \
   && ! git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$BRANCH" \
   && source_unchanged; then
  pass "local execution rejects external-authority commands before Git mutation"
else
  fail "local authority guard accepted a publication-capable evaluator (rc=$RC): $OUT"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "stage10 execution harness: GREEN ($PASSED assertions passed)"
  exit 0
else
  echo "stage10 execution harness: RED" >&2
  exit 1
fi
