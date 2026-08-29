#!/usr/bin/env bash
#
# wgm/test-stage10-live-qualification.sh — offline contract backpressure for explicitly authorized
# Stage 10 live qualification. Every child is a disposable local test double: this harness never
# invokes a provider, model, network, credential store, branch, PR, deployment, or publication.
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
command -v git >/dev/null 2>&1 || { fail "git is required"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wgm-stage10-live.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
mkdir -p "$PROJECT" "$TMP/bin"

cat >"$TMP/bin/mark" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$2"
printf 'local live-contract double passed: %s\n' "$1"
EOF
cat >"$TMP/bin/fail" <<'EOF'
#!/usr/bin/env bash
printf 'local live-contract double failed\n' >&2
exit 9
EOF
cat >"$TMP/bin/hang" <<'EOF'
#!/usr/bin/env bash
sleep 10
EOF
cat >"$TMP/bin/slow-mark" <<'EOF'
#!/usr/bin/env bash
sleep "$1"
printf '%s\n' "$2" >>"$3"
EOF
chmod +x "$TMP/bin/mark" "$TMP/bin/fail" "$TMP/bin/hang" "$TMP/bin/slow-mark"

git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email stage10@example.invalid
git -C "$PROJECT" config user.name stage10-fixture
printf '# live qualification contract fixture\n' >"$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -q -m 'fixture: live qualification baseline'

REAL_GIT="$(command -v git)"
GIT_PROBE="$PROJECT/git-probe"
cat >"$TMP/bin/git" <<EOF
#!/usr/bin/env bash
printf 'git\n' >>"\${GIT_PROBE:?}"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMP/bin/git"

run_qualify() {
  set +e
  OUT="$(PATH="$TMP/bin:$PATH" GIT_PROBE="$GIT_PROBE" PYTHONDONTWRITEBYTECODE=1 \
    LIVE_CONTRACT_SECRET=sk-this-must-never-persist \
    python3 "$QUALIFY" "$@" 2>&1)"
  RC=$?
  set -e
}

write_live_manifest() {
  local path="$1" route="$2" budget="$3" mode="$4" marker="$5"
  python3 - "$path" "$route" "$budget" "$mode" "$marker" \
    "$TMP/bin/mark" "$TMP/bin/fail" "$TMP/bin/hang" <<'PY'
import json
import sys

path, route, budget, mode, marker, mark, fail, hang = sys.argv[1:]
phases = ("contract", "protocol", "tool", "ralph-smoke", "repeated", "benchmark")
if mode == "all-pass":
    commands = {phase: f"{mark} {phase} {marker}" for phase in phases}
elif mode == "fail":
    commands = {"contract": fail}
elif mode == "hang":
    commands = {"contract": hang}
elif mode == "partial":
    commands = {"contract": f"{mark} contract {marker}"}
else:
    raise ValueError(mode)
payload = {
    "allow_live": True,
    "live_budget_seconds": float(budget),
    "routes": [{"id": route, "evidence": "live", "environment": "offline-contract-double", "commands": commands}],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True)
    handle.write("\n")
PY
}

write_authorization() {
  local manifest="$1" authorization="$2" route="$3" phases_json="$4" expiry="$5" budget="$6"
  local hash_mode="${7:-match}"
  python3 - "$manifest" "$authorization" "$route" "$phases_json" "$expiry" "$budget" "$hash_mode" <<'PY'
import hashlib
import json
import sys

manifest, authorization, route, phases_json, expiry, budget, hash_mode = sys.argv[1:]
digest = hashlib.sha256(open(manifest, "rb").read()).hexdigest()
if hash_mode == "mismatch":
    digest = "0" * 64
payload = {
    "schema": "stage10.live-authorization.v1",
    "allow_live": True,
    "manifest_sha256": digest,
    "scope": {"routes": {route: json.loads(phases_json)}},
    "expires_at": expiry,
    "budget_seconds": float(budget),
}
with open(authorization, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True)
    handle.write("\n")
PY
}

ALL_PHASES='["contract","protocol","tool","ralph-smoke","repeated","benchmark"]'
FUTURE="2099-01-01T00:00:00Z"
EXPIRED="2000-01-01T00:00:00Z"
MARKER="$PROJECT/live-marker"
LIVE_MANIFEST="$PROJECT/.wgm/stage10/harnesses/live-manifest.json"
LIVE_AUTH="$PROJECT/.wgm/stage10/harnesses/live-authorization.json"
mkdir -p "$(dirname "$LIVE_MANIFEST")"
write_live_manifest "$LIVE_MANIFEST" live-contract 5 all-pass "$MARKER"
write_authorization "$LIVE_MANIFEST" "$LIVE_AUTH" live-contract "$ALL_PHASES" "$FUTURE" 5

# 1) A copied live manifest and authorization are inert without the operator's invocation flag.
NO_FLAG_OUTPUT="$PROJECT/.wgm/stage10/harnesses/no-flag.jsonl"
run_qualify qualify --root "$PROJECT" --manifest "$LIVE_MANIFEST" \
  --authorization-file "$LIVE_AUTH" --output "$NO_FLAG_OUTPUT"
if [[ "$RC" -eq 2 ]] && [[ ! -e "$MARKER" ]] && [[ ! -e "$GIT_PROBE" ]] \
  && [[ ! -e "$NO_FLAG_OUTPUT" ]] \
  && grep -q 'requires --allow-live' <<<"$OUT"; then
  pass "copied manifest and authorization cannot execute without explicit --allow-live"
else
  fail "missing explicit live confirmation did not fail before execution (rc=$RC): $OUT"
fi

# 2) The explicit flag is also inert without a separately supplied authorization record.
NO_AUTH_OUTPUT="$PROJECT/.wgm/stage10/harnesses/no-authorization.jsonl"
run_qualify qualify --root "$PROJECT" --manifest "$LIVE_MANIFEST" --allow-live \
  --output "$NO_AUTH_OUTPUT"
if [[ "$RC" -eq 2 ]] && [[ ! -e "$MARKER" ]] && [[ ! -e "$NO_AUTH_OUTPUT" ]] \
  && grep -q 'requires --authorization-file' <<<"$OUT"; then
  pass "explicit flag cannot substitute for a live authorization record"
else
  fail "missing authorization did not fail before execution (rc=$RC): $OUT"
fi

# 3) Credential-bearing argv forms are rejected before authorization or runner artifacts exist.
CREDENTIAL_MANIFEST="$PROJECT/.wgm/stage10/harnesses/credential-manifest.json"
cat >"$CREDENTIAL_MANIFEST" <<EOF
{"allow_live":true,"live_budget_seconds":5,"routes":[{"id":"live-credential","evidence":"live","commands":{"contract":"$TMP/bin/mark --token opaque-fixture-value"}}]}
EOF
CREDENTIAL_OUTPUT="$PROJECT/.wgm/stage10/harnesses/credential.jsonl"
run_qualify qualify --root "$PROJECT" --manifest "$CREDENTIAL_MANIFEST" --allow-live \
  --output "$CREDENTIAL_OUTPUT"
if [[ "$RC" -eq 2 ]] && [[ ! -e "$GIT_PROBE" ]] && [[ ! -e "$CREDENTIAL_OUTPUT" ]] \
  && grep -q 'credential-bearing option' <<<"$OUT"; then
  pass "credential-bearing argv options are rejected before execution or persistence"
else
  fail "credential-bearing argv was accepted or persisted (rc=$RC): $OUT"
fi

# 4) Credential-like or structurally incomplete authorization metadata is rejected before spawn.
MALFORMED_AUTH="$PROJECT/.wgm/stage10/harnesses/malformed-authorization.json"
cat >"$MALFORMED_AUTH" <<'EOF'
{"schema":"stage10.live-authorization.v1","allow_live":true,"access":"token=sk-not-a-real-live-token"}
EOF
MALFORMED_OUTPUT="$PROJECT/.wgm/stage10/harnesses/malformed.jsonl"
run_qualify qualify --root "$PROJECT" --manifest "$LIVE_MANIFEST" \
  --authorization-file "$MALFORMED_AUTH" --allow-live --output "$MALFORMED_OUTPUT"
if [[ "$RC" -eq 2 ]] && [[ ! -e "$MARKER" ]] && [[ ! -e "$MALFORMED_OUTPUT" ]] \
  && grep -q 'credential-like material' <<<"$OUT"; then
  pass "malformed or credential-like authorization fails closed without a child"
else
  fail "unsafe authorization was accepted or persisted (rc=$RC): $OUT"
fi

# 5) Expiry is checked as UTC metadata before any phase or result artifact is created.
EXPIRED_AUTH="$PROJECT/.wgm/stage10/harnesses/expired-authorization.json"
write_authorization "$LIVE_MANIFEST" "$EXPIRED_AUTH" live-contract "$ALL_PHASES" "$EXPIRED" 5
EXPIRED_OUTPUT="$PROJECT/.wgm/stage10/harnesses/expired.jsonl"
run_qualify qualify --root "$PROJECT" --manifest "$LIVE_MANIFEST" \
  --authorization-file "$EXPIRED_AUTH" --allow-live --output "$EXPIRED_OUTPUT"
if [[ "$RC" -eq 2 ]] && [[ ! -e "$MARKER" ]] && [[ ! -e "$EXPIRED_OUTPUT" ]] \
  && grep -q 'authorization has expired' <<<"$OUT"; then
  pass "expired live authorization cannot invoke or create qualification evidence"
else
  fail "expired authorization was not refused (rc=$RC): $OUT"
fi

# 6) The authorization is bound to the exact manifest bytes, not merely a matching route label.
HASH_AUTH="$PROJECT/.wgm/stage10/harnesses/hash-authorization.json"
write_authorization "$LIVE_MANIFEST" "$HASH_AUTH" live-contract "$ALL_PHASES" "$FUTURE" 5 mismatch
HASH_OUTPUT="$PROJECT/.wgm/stage10/harnesses/hash-mismatch.jsonl"
run_qualify qualify --root "$PROJECT" --manifest "$LIVE_MANIFEST" \
  --authorization-file "$HASH_AUTH" --allow-live --output "$HASH_OUTPUT"
if [[ "$RC" -eq 2 ]] && [[ ! -e "$MARKER" ]] && [[ ! -e "$HASH_OUTPUT" ]] \
  && grep -q 'manifest_sha256 does not match' <<<"$OUT"; then
  pass "manifest hash mismatch refuses every live phase before execution"
else
  fail "manifest hash mismatch was accepted (rc=$RC): $OUT"
fi

# 7) Route and phase scope must exactly match; extra authority is not silently narrowed.
SCOPE_AUTH="$PROJECT/.wgm/stage10/harnesses/scope-authorization.json"
write_authorization "$LIVE_MANIFEST" "$SCOPE_AUTH" another-route "$ALL_PHASES" "$FUTURE" 5
SCOPE_OUTPUT="$PROJECT/.wgm/stage10/harnesses/scope-mismatch.jsonl"
run_qualify qualify --root "$PROJECT" --manifest "$LIVE_MANIFEST" \
  --authorization-file "$SCOPE_AUTH" --allow-live --output "$SCOPE_OUTPUT"
if [[ "$RC" -eq 2 ]] && [[ ! -e "$MARKER" ]] && [[ ! -e "$SCOPE_OUTPUT" ]] \
  && grep -q 'scope does not exactly match' <<<"$OUT"; then
  pass "out-of-scope route or phase authorization invokes no live command"
else
  fail "out-of-scope authorization was accepted (rc=$RC): $OUT"
fi

# 8) The total execution-time budget is independently declared and must agree on both sides.
BUDGET_AUTH="$PROJECT/.wgm/stage10/harnesses/budget-authorization.json"
write_authorization "$LIVE_MANIFEST" "$BUDGET_AUTH" live-contract "$ALL_PHASES" "$FUTURE" 4
BUDGET_OUTPUT="$PROJECT/.wgm/stage10/harnesses/budget-mismatch.jsonl"
run_qualify qualify --root "$PROJECT" --manifest "$LIVE_MANIFEST" \
  --authorization-file "$BUDGET_AUTH" --allow-live --output "$BUDGET_OUTPUT"
if [[ "$RC" -eq 2 ]] && [[ ! -e "$MARKER" ]] && [[ ! -e "$BUDGET_OUTPUT" ]] \
  && grep -q 'budget_seconds does not match' <<<"$OUT"; then
  pass "budget mismatch refuses execution rather than spending an inferred allowance"
else
  fail "mismatched live budget was accepted (rc=$RC): $OUT"
fi

# 9) A fully matching envelope executes each named phase once through T10 and records a dated,
# bounded live observation. The ambient token-shaped value proves credentials are not persisted.
LIVE_OUTPUT="$PROJECT/.wgm/stage10/harnesses/live-qualification.jsonl"
run_qualify qualify --root "$PROJECT" --manifest "$LIVE_MANIFEST" \
  --authorization-file "$LIVE_AUTH" --allow-live --output "$LIVE_OUTPUT"
if [[ "$RC" -eq 0 ]] && [[ "$(wc -l <"$MARKER")" -eq 6 ]] \
  && [[ "$(find "$PROJECT/.wgm/stage10/harnesses/runs" -name '*.json' | wc -l)" -eq 12 ]] \
  && ! grep -q 'sk-this-must-never-persist' "$LIVE_OUTPUT" \
  && PYTHONDONTWRITEBYTECODE=1 python3 - "$LIVE_OUTPUT" "$LIVE_AUTH" "$PROJECT" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
authorization_hash = hashlib.sha256(Path(sys.argv[2]).read_bytes()).hexdigest()
project = Path(sys.argv[3])
assert len(rows) == 7
assert all(row["evidence"] == "live" and row["route_status"] == "qualified" for row in rows)
assert all(row["authorization_sha256"] == authorization_hash for row in rows)
assert all(row["authorization_expires_at"] == "2099-01-01T00:00:00Z" for row in rows)
assert all(row["budget"]["authorized_seconds"] == 5 for row in rows)
assert all("no automatic route, policy, PR, merge, deploy, or publish" in row["authority"] for row in rows)
phase_rows = [row for row in rows if row["phase"] != "inventory"]
assert all(row["runner"]["contract"] == "stage10.runner.v1" for row in phase_rows)
assert all((project / row["runner"]["result"]).is_file() for row in phase_rows)
for row in phase_rows:
    result = json.loads((project / row["runner"]["result"]).read_text(encoding="utf-8"))
    assert result["shell"] is False and result["evidence"] == "live"
PY
then
  pass "matching authority runs only scoped phases through T10 and records bounded live provenance"
else
  fail "authorized contract double did not produce qualified T10-backed evidence (rc=$RC): $OUT"
fi

# 10) Qualification output cannot overwrite its manifest, authorization, or reserved T10 evidence.
rm -f "$MARKER" "$GIT_PROBE"
MANIFEST_BEFORE="$(sha256sum "$LIVE_MANIFEST" | awk '{print $1}')"
run_qualify qualify --root "$PROJECT" --manifest "$LIVE_MANIFEST" \
  --authorization-file "$LIVE_AUTH" --allow-live --output "$LIVE_MANIFEST"
MANIFEST_AFTER="$(sha256sum "$LIVE_MANIFEST" | awk '{print $1}')"
if [[ "$RC" -eq 2 ]] && [[ "$MANIFEST_BEFORE" == "$MANIFEST_AFTER" ]] \
  && [[ ! -e "$MARKER" ]] && [[ ! -e "$GIT_PROBE" ]] \
  && grep -q 'must not overwrite the manifest or authorization input' <<<"$OUT"; then
  pass "qualification output cannot overwrite authority inputs or spawn before collision refusal"
else
  fail "output collision damaged an input or spawned a child (rc=$RC): $OUT"
fi

# 11) A failed live phase is preserved below qualified and is never retried or promoted.
FAIL_MARKER="$PROJECT/fail-marker"
FAIL_MANIFEST="$PROJECT/.wgm/stage10/harnesses/fail-manifest.json"
FAIL_AUTH="$PROJECT/.wgm/stage10/harnesses/fail-authorization.json"
write_live_manifest "$FAIL_MANIFEST" live-fail 5 fail "$FAIL_MARKER"
write_authorization "$FAIL_MANIFEST" "$FAIL_AUTH" live-fail '["contract"]' "$FUTURE" 5
FAIL_OUTPUT="$PROJECT/.wgm/stage10/harnesses/live-fail.jsonl"
run_qualify qualify --root "$PROJECT" --manifest "$FAIL_MANIFEST" \
  --authorization-file "$FAIL_AUTH" --allow-live --output "$FAIL_OUTPUT"
if [[ "$RC" -eq 1 ]] && grep -q '"status": "failed"' "$FAIL_OUTPUT" \
  && grep -q '"route_status": "blocked"' "$FAIL_OUTPUT" \
  && ! grep -q '"route_status": "qualified"' "$FAIL_OUTPUT"; then
  pass "failed live phase stops once and remains blocked below qualified"
else
  fail "failed live phase was lost, retried, or promoted (rc=$RC): $OUT"
fi

# 12) A timeout consumes only its bounded T10 phase and leaves a timeout record below qualified.
HANG_MARKER="$PROJECT/hang-marker"
HANG_MANIFEST="$PROJECT/.wgm/stage10/harnesses/hang-manifest.json"
HANG_AUTH="$PROJECT/.wgm/stage10/harnesses/hang-authorization.json"
write_live_manifest "$HANG_MANIFEST" live-timeout 2 hang "$HANG_MARKER"
write_authorization "$HANG_MANIFEST" "$HANG_AUTH" live-timeout '["contract"]' "$FUTURE" 2
HANG_OUTPUT="$PROJECT/.wgm/stage10/harnesses/live-timeout.jsonl"
run_qualify qualify --root "$PROJECT" --manifest "$HANG_MANIFEST" \
  --authorization-file "$HANG_AUTH" --allow-live --timeout-seconds 1 --output "$HANG_OUTPUT"
if [[ "$RC" -eq 1 ]] && grep -q '"status": "timeout"' "$HANG_OUTPUT" \
  && grep -q '"route_status": "blocked"' "$HANG_OUTPUT"; then
  pass "timed-out live phase is bounded by T10 and remains blocked"
else
  fail "timed-out live phase was not bounded and blocked (rc=$RC): $OUT"
fi

# 13) Cumulative live duration consumes the shared authorization budget; a later phase cannot spend
# a fresh per-phase allowance after the total is exhausted.
AGGREGATE_MARKER="$PROJECT/aggregate-marker"
AGGREGATE_MANIFEST="$PROJECT/.wgm/stage10/harnesses/aggregate-manifest.json"
AGGREGATE_AUTH="$PROJECT/.wgm/stage10/harnesses/aggregate-authorization.json"
python3 - "$AGGREGATE_MANIFEST" "$TMP/bin/slow-mark" "$AGGREGATE_MARKER" <<'PY'
import json
import sys

path, slow, marker = sys.argv[1:]
payload = {
    "allow_live": True,
    "live_budget_seconds": 0.18,
    "routes": [{
        "id": "live-aggregate",
        "evidence": "live",
        "commands": {
            "contract": f"{slow} 0.12 contract {marker}",
            "protocol": f"{slow} 0.12 protocol {marker}",
            "tool": f"{slow} 0.12 tool {marker}",
        },
    }],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True)
    handle.write("\n")
PY
write_authorization "$AGGREGATE_MANIFEST" "$AGGREGATE_AUTH" live-aggregate \
  '["contract","protocol","tool"]' "$FUTURE" 0.18
AGGREGATE_OUTPUT="$PROJECT/.wgm/stage10/harnesses/live-aggregate.jsonl"
run_qualify qualify --root "$PROJECT" --manifest "$AGGREGATE_MANIFEST" \
  --authorization-file "$AGGREGATE_AUTH" --allow-live --output "$AGGREGATE_OUTPUT"
if [[ "$RC" -eq 1 ]] && grep -qx 'contract' "$AGGREGATE_MARKER" \
  && ! grep -q 'protocol\\|tool' "$AGGREGATE_MARKER" \
  && PYTHONDONTWRITEBYTECODE=1 python3 - "$AGGREGATE_OUTPUT" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert rows[-1]["phase"] == "protocol"
assert rows[-1]["status"] == "timeout"
assert rows[-1]["route_status"] == "blocked"
assert rows[-1]["budget"]["consumed_ms"] >= 170
assert rows[-1]["budget"]["remaining_ms"] <= 10
PY
then
  pass "aggregate duration exhausts one shared budget before later phases can spawn"
else
  fail "aggregate live budget was reset or not enforced (rc=$RC): $OUT"
fi

# 14) Expiry is rechecked between live phases, not only when the command starts.
EXPIRY_MARKER="$PROJECT/mid-expiry-marker"
EXPIRY_MANIFEST="$PROJECT/.wgm/stage10/harnesses/mid-expiry-manifest.json"
EXPIRY_AUTH="$PROJECT/.wgm/stage10/harnesses/mid-expiry-authorization.json"
python3 - "$EXPIRY_MANIFEST" "$TMP/bin/slow-mark" "$TMP/bin/mark" "$EXPIRY_MARKER" <<'PY'
import json
import sys

path, slow, mark, marker = sys.argv[1:]
payload = {
    "allow_live": True,
    "live_budget_seconds": 5,
    "routes": [{
        "id": "live-expiring",
        "evidence": "live",
        "commands": {
            "contract": f"{slow} 2.2 contract {marker}",
            "protocol": f"{mark} protocol {marker}",
        },
    }],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True)
    handle.write("\n")
PY
SOON="$(python3 - <<'PY'
import datetime as dt
print((dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=2)).isoformat())
PY
)"
write_authorization "$EXPIRY_MANIFEST" "$EXPIRY_AUTH" live-expiring \
  '["contract","protocol"]' "$SOON" 5
EXPIRY_OUTPUT="$PROJECT/.wgm/stage10/harnesses/mid-expiry.jsonl"
run_qualify qualify --root "$PROJECT" --manifest "$EXPIRY_MANIFEST" \
  --authorization-file "$EXPIRY_AUTH" --allow-live --timeout-seconds 3 --output "$EXPIRY_OUTPUT"
if [[ "$RC" -eq 1 ]] && grep -qx 'contract' "$EXPIRY_MARKER" \
  && ! grep -q 'protocol' "$EXPIRY_MARKER" \
  && grep -q '"status": "refused"' "$EXPIRY_OUTPUT" \
  && grep -q 'authorization expired before phase' "$EXPIRY_OUTPUT"; then
  pass "authorization expiry is rechecked before every live phase"
else
  fail "a live phase spawned after its authorization expired (rc=$RC): $OUT"
fi

# 15) Missing protocol/tool phases are explicit unknowns; one passing command is not qualification.
PARTIAL_MARKER="$PROJECT/partial-marker"
PARTIAL_MANIFEST="$PROJECT/.wgm/stage10/harnesses/partial-manifest.json"
PARTIAL_AUTH="$PROJECT/.wgm/stage10/harnesses/partial-authorization.json"
write_live_manifest "$PARTIAL_MANIFEST" live-partial 2 partial "$PARTIAL_MARKER"
write_authorization "$PARTIAL_MANIFEST" "$PARTIAL_AUTH" live-partial '["contract"]' "$FUTURE" 2
PARTIAL_OUTPUT="$PROJECT/.wgm/stage10/harnesses/live-partial.jsonl"
run_qualify qualify --root "$PROJECT" --manifest "$PARTIAL_MANIFEST" \
  --authorization-file "$PARTIAL_AUTH" --allow-live --output "$PARTIAL_OUTPUT"
if [[ "$RC" -eq 0 ]] && grep -q '"status": "unknown"' "$PARTIAL_OUTPUT" \
  && grep -q '"route_status": "inventory-only"' "$PARTIAL_OUTPUT" \
  && ! grep -q '"route_status": "qualified"' "$PARTIAL_OUTPUT"; then
  pass "unsupported live phases remain unknown and below qualified"
else
  fail "partial live ladder was incorrectly qualified (rc=$RC): $OUT"
fi

# 16) The ordinary fixture path needs no live authority and cannot acquire a live standing.
FIXTURE_MANIFEST="$PROJECT/.wgm/stage10/harnesses/fixture-manifest.json"
cat >"$FIXTURE_MANIFEST" <<EOF
{"routes":[{"id":"fixture-only","commands":{"contract":"$TMP/bin/mark contract $PROJECT/fixture-marker"}}]}
EOF
FIXTURE_OUTPUT="$PROJECT/.wgm/stage10/harnesses/fixture-qualification.jsonl"
run_qualify qualify --root "$PROJECT" --manifest "$FIXTURE_MANIFEST" --output "$FIXTURE_OUTPUT"
if [[ "$RC" -eq 0 ]] && grep -q '"evidence": "fixture"' "$FIXTURE_OUTPUT" \
  && grep -q '"route_status": "inventory-only"' "$FIXTURE_OUTPUT" \
  && grep -q 'fixture evidence only; never live or corroborated' "$FIXTURE_OUTPUT" \
  && ! grep -q '"evidence": "live"' "$FIXTURE_OUTPUT"; then
  pass "offline fixture evidence remains separate from authorized live observations"
else
  fail "fixture evidence crossed into the live authority path (rc=$RC): $OUT"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "stage10 live qualification harness: GREEN ($PASSED assertions passed)"
  exit 0
else
  echo "stage10 live qualification harness: RED" >&2
  exit 1
fi
