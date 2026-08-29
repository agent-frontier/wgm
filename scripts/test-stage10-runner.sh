#!/usr/bin/env bash
#
# wgm/test-stage10-runner.sh — deterministic backpressure for the generic Stage 10 bounded runner.
#
# The disposable fixture exercises the direct argv contract rather than a provider or model. It
# deliberately covers process-group cleanup, bounded/redacted diagnostics, explicit environment
# handling, path confinement, and the live-authority refusal before any future qualification adapter
# is allowed to reuse this boundary.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/stage10_runner.py"
FAILED=0
PASSED=0
pass() { printf 'ok:   %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

[[ -f "$RUNNER" ]] || { fail "missing $RUNNER"; exit 1; }
command -v python3 >/dev/null 2>&1 || { fail "python3 is required"; exit 1; }
command -v git >/dev/null 2>&1 || { fail "git is required"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wgm-stage10-runner.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
mkdir -p "$PROJECT/work" "$TMP/bin" "$TMP/outside"

cat >"$TMP/bin/pass" <<'EOF'
#!/usr/bin/env bash
printf 'fixture pass\n'
EOF
cat >"$TMP/bin/fail" <<'EOF'
#!/usr/bin/env bash
printf 'fixture failure\n' >&2
exit 7
EOF
cat >"$TMP/bin/echo-arg" <<'EOF'
#!/usr/bin/env bash
printf 'cwd=%s arg=%s\n' "$PWD" "${1-}"
EOF
cat >"$TMP/bin/mark" <<'EOF'
#!/usr/bin/env bash
printf 'invoked\n' >"$1"
EOF
cat >"$TMP/bin/leak" <<'EOF'
#!/usr/bin/env bash
for _ in $(seq 1 20); do
  printf 'token=sk-stage10-not-a-real-secret-value diagnostic-padding-xxxxxxxxxxxxxxxxxxxxxxxx\n'
done
EOF
cat >"$TMP/bin/env-check" <<'EOF'
#!/usr/bin/env bash
printf 'configured=%s\n' "${RUNNER_FIXTURE-absent}"
EOF
cat >"$TMP/bin/hang" <<'EOF'
#!/usr/bin/env bash
# Ignore TERM in the descendant so the runner must escalate the complete process group.
(bash -c 'trap "" TERM; sleep 30') &
printf '%s\n' "$!" >"$1"
wait
EOF
chmod +x "$TMP/bin/pass" "$TMP/bin/fail" "$TMP/bin/echo-arg" "$TMP/bin/mark" \
  "$TMP/bin/leak" "$TMP/bin/env-check" "$TMP/bin/hang"

# Give the runner a real disposable checkout so its cwd and project-boundary records are meaningful.
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email stage10@example.invalid
git -C "$PROJECT" config user.name stage10-fixture
printf '# runner fixture\n' >"$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -q -m 'fixture: runner baseline'
printf 'RUNNER_FIXTURE=fixture-value\n' >"$PROJECT/config.env"
printf 'outside environment\n' >"$TMP/outside.env"

make_manifest() {
  local manifest="$1" argv_json="$2" cwd="$3" timeout="$4" evidence="$5"
  local limit="${6:-}" environment_file="${7:-}"
  python3 - "$manifest" "$argv_json" "$cwd" "$timeout" "$evidence" "$limit" "$environment_file" <<'PY'
import json
import sys

path, argv_json, cwd, timeout, evidence, limit, environment_file = sys.argv[1:]
payload = {
    "argv": json.loads(argv_json),
    "cwd": cwd,
    "timeout_seconds": float(timeout) if "." in timeout else int(timeout),
    "evidence": evidence,
}
if limit:
    payload["diagnostic_limit"] = int(limit)
if environment_file:
    payload["environment_file"] = environment_file
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
    handle.write("\n")
PY
}

run_runner() {
  local manifest="$1" output="$2"
  shift 2
  local command=(python3 "$RUNNER" run --root "$PROJECT" --manifest "$manifest")
  [[ -n "$output" ]] && command+=(--output "$output")
  command+=("$@")
  set +e
  OUT="$(PYTHONDONTWRITEBYTECODE=1 "${command[@]}" 2>&1)"
  RC=$?
  set -e
}

OUT=""
RC=0
PASS_ARGV="[\"$TMP/bin/pass\"]"
FAIL_ARGV="[\"$TMP/bin/fail\"]"
MARK_ARGV="[\"$TMP/bin/mark\",\"$PROJECT/marker\"]"

# 1) A valid structured manifest runs directly and records the bounded contract fields. The test
# proves the smallest end-to-end path: manifest -> argv process -> .wgm result -> revalidation data.
make_manifest "$TMP/pass.json" "$PASS_ARGV" work 5 fixture
PASS_RESULT="$PROJECT/.wgm/stage10/runs/pass.json"
run_runner "$TMP/pass.json" "$PASS_RESULT"
if [[ "$RC" -eq 0 ]] && [[ -s "$PASS_RESULT" ]] && grep -q 'stage10 runner: passed' <<<"$OUT" \
  && PYTHONDONTWRITEBYTECODE=1 python3 - "$PASS_RESULT" "$PROJECT" <<'PY'
import json
import sys
from pathlib import Path

row = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
project = Path(sys.argv[2]).resolve()
assert row["schema"] == "stage10.runner.v1"
assert row["status"] == "passed" and row["exit_classification"] == "passed"
assert row["exit_code"] == 0
assert row["shell"] is False
assert row["cwd"] == str(project / "work")
assert row["cwd_relative"] == "work"
assert row["timeout_seconds"] == 5
assert row["evidence"] == "fixture" and row["evidence_class"] == "fixture"
assert len(row["environment_fingerprint"]) == 64
assert row["revalidate"]["manifest_sha256"]
assert row["revalidate"]["condition"]
PY
then
  pass "valid argv manifest records cwd, budget, evidence, fingerprint, and revalidation"
else
  fail "valid runner manifest did not produce the expected record (rc=$RC): $OUT"
fi

# 2) A nonzero direct process is a visible failed result, not a parser or qualification success.
make_manifest "$TMP/fail.json" "$FAIL_ARGV" . 5 fixture
FAIL_RESULT="$PROJECT/.wgm/stage10/runs/fail.json"
run_runner "$TMP/fail.json" "$FAIL_RESULT"
if [[ "$RC" -eq 1 ]] && PYTHONDONTWRITEBYTECODE=1 python3 - "$FAIL_RESULT" <<'PY'
import json
import sys

row = json.load(open(sys.argv[1], encoding="utf-8"))
assert row["status"] == "failed"
assert row["exit_code"] == 7
assert "fixture failure" in row["diagnostic"]
PY
then
  pass "direct nonzero exit is classified as failed with a bounded diagnostic"
else
  fail "direct failure was not recorded (rc=$RC): $OUT"
fi

# 3) Shell punctuation remains one argv datum. The marker can only appear if the runner inserted a
# shell, so this protects the injection boundary rather than merely checking an exit code.
INJECTED="$TMP/injected"
INJECTION_ARGV="$(python3 - "$TMP/bin/echo-arg" "safe; touch $INJECTED" <<'PY'
import json
import sys
print(json.dumps([sys.argv[1], sys.argv[2]]))
PY
)"
make_manifest "$TMP/injection.json" "$INJECTION_ARGV" . 5 fixture
INJECTION_RESULT="$PROJECT/.wgm/stage10/runs/injection.json"
run_runner "$TMP/injection.json" "$INJECTION_RESULT"
if [[ "$RC" -eq 0 ]] && [[ ! -e "$INJECTED" ]] \
  && grep -q 'safe; touch' "$INJECTION_RESULT"; then
  pass "shell metacharacters are passed as argv data without a second command"
else
  fail "argv metacharacters were interpreted as shell syntax (rc=$RC): $OUT"
fi

# 4) A timeout kills the complete process group. The spawned stubborn child writes its pid before
# the parent waits, giving the harness a real descendant to check after the runner returns.
HANG_PID="$PROJECT/hang-child.pid"
HANG_ARGV="$(python3 - "$TMP/bin/hang" "$HANG_PID" <<'PY'
import json
import sys
print(json.dumps([sys.argv[1], sys.argv[2]]))
PY
)"
make_manifest "$TMP/timeout.json" "$HANG_ARGV" . 0.2 fixture
TIMEOUT_RESULT="$PROJECT/.wgm/stage10/runs/timeout.json"
run_runner "$TMP/timeout.json" "$TIMEOUT_RESULT"
child_alive=0
if [[ -f "$HANG_PID" ]]; then
  for _ in $(seq 1 20); do
    if kill -0 "$(cat "$HANG_PID")" 2>/dev/null; then
      child_alive=1
      sleep 0.05
    else
      child_alive=0
      break
    fi
  done
fi
if [[ "$RC" -eq 1 ]] && [[ "$child_alive" -eq 0 ]] \
  && PYTHONDONTWRITEBYTECODE=1 python3 - "$TIMEOUT_RESULT" <<'PY'
import json
import sys

row = json.load(open(sys.argv[1], encoding="utf-8"))
assert row["status"] == "timeout"
assert row["exit_code"] not in (None, 0)
assert row["cleanup"]["process_group_termination"] is True
assert row["cleanup"]["reaped"] is True
PY
then
  pass "timeout terminates and reaps a spawned process group"
else
  fail "timeout left a descendant or lost its cleanup record (rc=$RC): $OUT"
fi

# 5) Large and credential-like output is drained but only a bounded, redacted diagnostic is kept.
make_manifest "$TMP/leak.json" "[\"$TMP/bin/leak\"]" . 5 fixture 120
LEAK_RESULT="$PROJECT/.wgm/stage10/runs/leak.json"
run_runner "$TMP/leak.json" "$LEAK_RESULT"
if [[ "$RC" -eq 0 ]] && PYTHONDONTWRITEBYTECODE=1 python3 - "$LEAK_RESULT" <<'PY'
import json
import sys

row = json.load(open(sys.argv[1], encoding="utf-8"))
diagnostic = row["diagnostic"]
assert row["status"] == "passed"
assert row["diagnostic_truncated"] is True
assert len(diagnostic) <= 120
assert "<redacted>" in diagnostic
assert "sk-stage10-not-a-real-secret-value" not in diagnostic
assert "diagnostic-padding" not in diagnostic or len(diagnostic) <= 120
PY
then
  pass "diagnostics are bounded and redact token-shaped process output"
else
  fail "diagnostic bound or redaction failed (rc=$RC): $OUT"
fi

# 6) An in-bound environment file is parsed as explicit data, while the record keeps only its keys
# and a value fingerprint. This proves the safe environment path without persisting its value.
make_manifest "$TMP/environment.json" "[\"$TMP/bin/env-check\"]" . 5 fixture "" config.env
ENV_RESULT="$PROJECT/.wgm/stage10/runs/environment.json"
run_runner "$TMP/environment.json" "$ENV_RESULT"
if [[ "$RC" -eq 0 ]] && PYTHONDONTWRITEBYTECODE=1 python3 - "$ENV_RESULT" <<'PY'
import json
import sys

row = json.load(open(sys.argv[1], encoding="utf-8"))
assert row["status"] == "passed"
assert "configured=fixture-value" in row["diagnostic"]
assert row["environment"]["file"] == "config.env"
assert "RUNNER_FIXTURE" in row["environment"]["keys"]
assert "fixture-value" not in json.dumps(row["environment"])
PY
then
  pass "in-bound environment input is explicit, fingerprinted, and not persisted"
else
  fail "safe environment-file execution was not recorded correctly (rc=$RC): $OUT"
fi

# 7) Cwd, environment-file, and output escapes are rejected before the marker command can spawn.
make_manifest "$TMP/cwd-escape.json" "$MARK_ARGV" ../outside 5 fixture
CWD_ESCAPE_RESULT="$PROJECT/.wgm/stage10/runs/cwd-escape.json"
run_runner "$TMP/cwd-escape.json" "$CWD_ESCAPE_RESULT"
CWD_RC=$RC
CWD_OUT=$OUT
make_manifest "$TMP/env-escape.json" "$MARK_ARGV" . 5 fixture "" "$TMP/outside.env"
ENV_ESCAPE_RESULT="$PROJECT/.wgm/stage10/runs/env-escape.json"
run_runner "$TMP/env-escape.json" "$ENV_ESCAPE_RESULT"
ENV_RC=$RC
ENV_OUT=$OUT
make_manifest "$TMP/output-escape.json" "$PASS_ARGV" . 5 fixture
run_runner "$TMP/output-escape.json" "$TMP/outside/result.json"
OUTPUT_RC=$RC
OUTPUT_OUT=$OUT
if [[ "$CWD_RC" -eq 2 ]] && [[ "$ENV_RC" -eq 2 ]] && [[ "$OUTPUT_RC" -eq 2 ]] \
  && [[ ! -e "$PROJECT/marker" ]] && [[ ! -e "$CWD_ESCAPE_RESULT" ]] \
  && [[ ! -e "$ENV_ESCAPE_RESULT" ]] && [[ ! -e "$TMP/outside/result.json" ]] \
  && grep -q 'cwd must remain under project root' <<<"$CWD_OUT" \
  && grep -q 'environment_file must remain under project root' <<<"$ENV_OUT" \
  && grep -q 'output must remain under' <<<"$OUTPUT_OUT"; then
  pass "cwd, environment-file, and output boundaries fail closed before spawning or writing"
else
  fail "a boundary escape was accepted or spawned a process (cwd=$CWD_RC env=$ENV_RC output=$OUTPUT_RC)"
fi

# 8) A live evidence class without the caller's explicit authority envelope is refused and cannot
# become route evidence. The marker proves refusal happened before process creation.
LIVE_ARGV="$(python3 - "$TMP/bin/mark" "$PROJECT/live-marker" <<'PY'
import json
import sys
print(json.dumps([sys.argv[1], sys.argv[2]]))
PY
)"
make_manifest "$TMP/live.json" "$LIVE_ARGV" . 5 live
LIVE_RESULT="$PROJECT/.wgm/stage10/runs/live.json"
run_runner "$TMP/live.json" "$LIVE_RESULT"
if [[ "$RC" -eq 1 ]] && [[ ! -e "$PROJECT/live-marker" ]] \
  && PYTHONDONTWRITEBYTECODE=1 python3 - "$LIVE_RESULT" <<'PY'
import json
import sys

row = json.load(open(sys.argv[1], encoding="utf-8"))
assert row["status"] == "refused"
assert "authority envelope" in row["diagnostic"]
assert row["evidence_promoted"] is False
assert row["cleanup"]["actions"] == ["process not spawned"]
PY
then
  pass "live execution is refused without an explicit authority envelope"
else
  fail "unauthorized live evidence was executed or promoted (rc=$RC): $OUT"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "stage10 runner harness: GREEN ($PASSED assertions passed)"
  exit 0
else
  echo "stage10 runner harness: RED" >&2
  exit 1
fi
