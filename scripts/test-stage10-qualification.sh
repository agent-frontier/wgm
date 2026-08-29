#!/usr/bin/env bash
# Qualification backpressure: prove phase separation, fixture/live boundary, and failure records.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.wgm/stage10" "$tmp/bin"
cat >"$tmp/bin/pass" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tmp/bin/fail" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$tmp/bin/"*
cat >"$tmp/valid.json" <<EOF
{"routes":[{"id":"fixture-pass","environment":"isolated-fixture","commands":{"contract":"$tmp/bin/pass","protocol":"$tmp/bin/pass","tool":"$tmp/bin/pass","ralph-smoke":"$tmp/bin/pass","repeated":"$tmp/bin/pass","benchmark":"$tmp/bin/pass"}}]}
EOF
python3 "$ROOT/scripts/stage10_qualification.py" qualify --root "$tmp" --manifest "$tmp/valid.json" >/dev/null
python3 - "$tmp/.wgm/stage10/harnesses/qualification.jsonl" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1])]
assert [r["phase"] for r in rows] == ["inventory","contract","protocol","tool","ralph-smoke","repeated","benchmark"]
assert all(r["evidence"]=="fixture" and r["route"]=="fixture-pass" for r in rows)
assert all(set(("route","environment","command","duration_ms","status","revalidate")) <= r.keys() for r in rows)
PY
cat >"$tmp/fail.json" <<EOF
{"routes":[{"id":"fixture-fail","commands":{"contract":"$tmp/bin/fail","protocol":"$tmp/bin/pass"}}]}
EOF
if python3 "$ROOT/scripts/stage10_qualification.py" qualify --root "$tmp" --manifest "$tmp/fail.json" >/dev/null; then echo 'FAIL: failing phase accepted' >&2; exit 1; fi
if python3 "$ROOT/scripts/stage10_qualification.py" qualify --root "$tmp" --manifest "$tmp/fail.json" --output "$tmp/outside.json" >/dev/null 2>&1; then echo 'FAIL: escaped .wgm output accepted' >&2; exit 1; fi
cat >"$tmp/live.json" <<'EOF'
{"routes":[{"id":"live","evidence":"live"}]}
EOF
if python3 "$ROOT/scripts/stage10_qualification.py" qualify --root "$tmp" --manifest "$tmp/live.json" >/dev/null 2>&1; then echo 'FAIL: live evidence accepted without explicit authority' >&2; exit 1; fi
echo 'stage10 qualification harness: GREEN'
