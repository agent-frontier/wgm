#!/usr/bin/env bash
#
# wgm/test-stage10-qualification.sh — deterministic backpressure for the Stage 10 qualification
# ladder. It uses disposable fake commands, not a provider or model, to prove inventory, phase
# separation, fail-closed live authority, bounded execution, shell-injection resistance, redacted
# diagnostics, and .wgm output confinement. A live qualification belongs to an explicit operator
# envelope and is never implied by this fixture.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUALIFY="$ROOT/scripts/stage10_qualification.py"
FAILED=0
PASSED=0
pass() { printf 'ok:   %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

[[ -f "$QUALIFY" ]] || { fail "missing $QUALIFY"; exit 1; }
command -v python3 >/dev/null 2>&1 || { fail "python3 is required"; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wgm-stage10-qualification.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
mkdir -p "$PROJECT" "$TMP/bin"

cat >"$TMP/bin/pass" <<'EOF'
#!/usr/bin/env bash
printf 'fixture phase passed\n'
EOF
cat >"$TMP/bin/fail" <<'EOF'
#!/usr/bin/env bash
printf 'fixture phase failed\n' >&2
exit 7
EOF
cat >"$TMP/bin/hang" <<'EOF'
#!/usr/bin/env bash
sleep 10
EOF
chmod +x "$TMP/bin/pass" "$TMP/bin/fail" "$TMP/bin/hang"

git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email stage10@example.invalid
git -C "$PROJECT" config user.name stage10-fixture
printf '# qualification fixture\n' >"$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -q -m 'fixture: qualification baseline'

run_qualify() {
  set +e
  OUT="$(PYTHONDONTWRITEBYTECODE=1 python3 "$QUALIFY" "$@" 2>&1)"
  RC=$?
  set -e
}

# 1) Every ladder phase gets a record when its explicit fixture command passes. The route summary
# remains fixture-qualified rather than falsely claiming live qualification.
cat >"$TMP/valid.json" <<EOF
{"routes":[{"id":"fixture-pass","environment":"isolated-fixture","commands":{"contract":"$TMP/bin/pass","protocol":"$TMP/bin/pass","tool":"$TMP/bin/pass","ralph-smoke":"$TMP/bin/pass","repeated":"$TMP/bin/pass","benchmark":"$TMP/bin/pass"}}]}
EOF
run_qualify qualify --root "$PROJECT" --manifest "$TMP/valid.json"
QUALIFICATION="$PROJECT/.wgm/stage10/harnesses/qualification.jsonl"
if [[ "$RC" -eq 0 ]] && [[ -f "$QUALIFICATION" ]] \
   && grep -q 'wrote 7 records' <<<"$OUT" \
   && grep -q '"route_status": "fixture-qualified"' "$QUALIFICATION"; then
  pass "valid fixture advances through all qualification phases without live claims"
else
  fail "valid fixture did not produce seven phase records (rc=$RC): $OUT"
fi

# 2) The output carries the fields that make a route result comparable and revalidatable.
if PYTHONDONTWRITEBYTECODE=1 python3 - "$QUALIFICATION" <<'PY'
import json
import sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert [row["phase"] for row in rows] == [
    "inventory", "contract", "protocol", "tool", "ralph-smoke", "repeated", "benchmark"
]
assert all(row["evidence"] == "fixture" for row in rows)
assert all(len(row["environment_fingerprint"]) == 64 for row in rows)
assert all({"route", "environment", "command", "duration_ms", "status", "revalidate"} <= row.keys() for row in rows)
assert all("manifest_sha256" in row["revalidate"] for row in rows)
PY
then
  pass "qualification records carry route, environment, command, timing, evidence, and revalidation"
else
  fail "qualification records omitted required comparison fields"
fi

# 3) A failed phase is visible, stops that route, and returns nonzero rather than becoming an
# inventory-only success.
cat >"$TMP/fail.json" <<EOF
{"routes":[{"id":"fixture-fail","commands":{"contract":"$TMP/bin/fail","protocol":"$TMP/bin/pass"}}]}
EOF
run_qualify qualify --root "$PROJECT" --manifest "$TMP/fail.json" --output "$PROJECT/.wgm/stage10/harnesses/failure.jsonl"
if [[ "$RC" -eq 1 ]] && grep -q '"phase": "contract"' "$PROJECT/.wgm/stage10/harnesses/failure.jsonl" \
   && grep -q '"status": "failed"' "$PROJECT/.wgm/stage10/harnesses/failure.jsonl" \
   && grep -q '"route_status": "blocked"' "$PROJECT/.wgm/stage10/harnesses/failure.jsonl"; then
  pass "failed phase blocks the route and preserves its diagnostic record"
else
  fail "failed phase was not classified as blocked (rc=$RC): $OUT"
fi

# 4) A hung phase reaches a bounded timeout record rather than wedging the qualification process.
cat >"$TMP/timeout.json" <<EOF
{"routes":[{"id":"fixture-timeout","commands":{"contract":"$TMP/bin/hang"}}]}
EOF
run_qualify qualify --root "$PROJECT" --manifest "$TMP/timeout.json" --timeout-seconds 1 \
  --output "$PROJECT/.wgm/stage10/harnesses/timeout.jsonl"
if [[ "$RC" -eq 1 ]] && grep -q '"status": "timeout"' "$PROJECT/.wgm/stage10/harnesses/timeout.jsonl"; then
  pass "hung phase is bounded and recorded as timeout"
else
  fail "hung phase was not bounded (rc=$RC): $OUT"
fi

# 5) Shell metacharacters are data under shell=False, not a second command. The injected marker
# must never be created by a qualification manifest.
ESCAPED="$TMP/escaped"
cat >"$TMP/injection.json" <<EOF
{"routes":[{"id":"fixture-injection","commands":{"contract":"$TMP/bin/pass; touch $ESCAPED"}}]}
EOF
run_qualify qualify --root "$PROJECT" --manifest "$TMP/injection.json" \
  --output "$PROJECT/.wgm/stage10/harnesses/injection.jsonl"
if [[ "$RC" -eq 1 ]] && [[ ! -e "$ESCAPED" ]] \
   && grep -q '"status": "failed"' "$PROJECT/.wgm/stage10/harnesses/injection.jsonl"; then
  pass "manifest command metacharacters cannot execute a second command"
else
  fail "qualification command escaped shell=False (rc=$RC): $OUT"
fi

# 6) Live evidence requires both the manifest declaration and an explicit operator flag. The
# manifest alone cannot authorize a provider/network command.
cat >"$TMP/live.json" <<'EOF'
{"allow_live":true,"routes":[{"id":"live-route","evidence":"live","commands":{}}]}
EOF
run_qualify qualify --root "$PROJECT" --manifest "$TMP/live.json" \
  --output "$PROJECT/.wgm/stage10/harnesses/live.jsonl"
if [[ "$RC" -eq 2 ]] && grep -q 'requires --allow-live' <<<"$OUT"; then
  pass "live evidence requires explicit operator authority"
else
  fail "manifest-only live authority was accepted (rc=$RC): $OUT"
fi

# 7) Diagnostics are redacted before persistence. A fixture command may emit a token-shaped value,
# but qualification records must retain only the safe form.
cat >"$TMP/bin/leak" <<'EOF'
#!/usr/bin/env bash
printf 'token=sk-not-a-real-secret-value\n'
EOF
chmod +x "$TMP/bin/leak"
cat >"$TMP/leak.json" <<EOF
{"routes":[{"id":"fixture-leak","commands":{"contract":"$TMP/bin/leak"}}]}
EOF
run_qualify qualify --root "$PROJECT" --manifest "$TMP/leak.json" \
  --output "$PROJECT/.wgm/stage10/harnesses/leak.jsonl"
if [[ "$RC" -eq 0 ]] && ! grep -q 'sk-not-a-real-secret-value' "$PROJECT/.wgm/stage10/harnesses/leak.jsonl" \
   && grep -q '<redacted>' "$PROJECT/.wgm/stage10/harnesses/leak.jsonl"; then
  pass "qualification diagnostics redact token-shaped output before persistence"
else
  fail "qualification diagnostics persisted raw token-like output (rc=$RC): $OUT"
fi

# 8) The output boundary is enforced and the existing wgm checkout remains untouched.
run_qualify qualify --root "$PROJECT" --manifest "$TMP/valid.json" --output "$TMP/outside.jsonl"
if [[ "$RC" -eq 2 ]] && grep -q 'must remain under' <<<"$OUT" \
   && [[ ! -e "$TMP/outside.jsonl" ]] \
   && [[ ! -e "$ROOT/.wgm/stage10/harnesses/qualification.jsonl" ]]; then
  pass "qualification output is confined to project .wgm state"
else
  fail "qualification output escaped its boundary (rc=$RC): $OUT"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "stage10 qualification harness: GREEN ($PASSED assertions passed)"
  exit 0
else
  echo "stage10 qualification harness: RED" >&2
  exit 1
fi
