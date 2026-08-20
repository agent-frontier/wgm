#!/usr/bin/env bash
#
# wgm/test-check-docs.sh — deterministic backpressure for scripts/check-docs.sh.
#
# A docs gate that silently never fires is worse than no gate: it reports GREEN forever and the
# defect class it was written for ships anyway. (The mojibake sweep shipped in exactly that state
# once — its byte pattern only matches under LC_ALL=C, and in a UTF-8 locale it matched nothing.)
# So this harness proves the gate actually goes RED on each class it claims to catch:
#   1. the real docs tree is GREEN (no false positive);
#   2. UTF-8 double-encoding (mojibake) is detected;
#   3. a broken internal relative link is detected;
#   4. an unbalanced code fence is detected.
#
# Probes are written into docs/ and removed again by an EXIT trap, so a failed run cannot leave the
# working tree dirty.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-docs.sh"
PROBE="$ROOT/docs/_check_docs_probe.md"
PROTOCOL_TMP="$(mktemp -d)"

FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

trap 'rm -f "$PROBE"; rm -rf "$PROTOCOL_TMP"' EXIT

run_check() { OUT="$(bash "$CHECK" 2>&1)"; RC=$?; }

# 1) the shipped docs tree is green before any probe exists
rm -f "$PROBE"
run_check
if [[ "$RC" -eq 0 ]] && grep -q "protocol contracts" <<<"$OUT"; then
  pass "the shipped docs tree and protocol contracts pass the gate"
else
  fail "the shipped docs tree or protocol contracts unexpectedly failed the gate: $OUT"
fi

# 1b) deleting a required protocol contract turns an isolated copy of the gate red
mkdir -p "$PROTOCOL_TMP/repo"
cp -a "$ROOT/." "$PROTOCOL_TMP/repo/"
grep -vF "Verify before promotion" "$PROTOCOL_TMP/repo/references/docs-audit.md" \
  > "$PROTOCOL_TMP/repo/references/docs-audit.md.tmp"
mv "$PROTOCOL_TMP/repo/references/docs-audit.md.tmp" "$PROTOCOL_TMP/repo/references/docs-audit.md"
OUT="$(bash "$PROTOCOL_TMP/repo/scripts/check-docs.sh" 2>&1)"
RC=$?
if [[ "$RC" -ne 0 ]] && grep -q "protocol contract is missing" <<<"$OUT"; then
  pass "removing a required protocol phrase turns the docs gate red"
else
  fail "protocol contract deletion did not trip the gate (rc=$RC): $OUT"
fi

# 2) mojibake: `Â` + `·` and `Ã` + an em dash, as emitted by a CP1252 round-trip
printf '# probe\n\nlane one \xc3\x82\xc2\xb7 lane two \xc3\x83\xe2\x80\x94 done\n' > "$PROBE"
run_check
if [[ "$RC" -ne 0 ]] && grep -qi "mojibake" <<<"$OUT"; then
  pass "UTF-8 double-encoding (mojibake) is detected"
else
  fail "mojibake probe did not trip the gate (rc=$RC) — is the byte pattern locale-pinned?"
fi

# 3) a relative link that resolves nowhere on disk
printf '# probe\n\nSee [the thing](./definitely-not-here.md).\n' > "$PROBE"
run_check
if [[ "$RC" -ne 0 ]] && grep -q "broken link" <<<"$OUT"; then
  pass "a broken internal relative link is detected"
else
  fail "broken-link probe did not trip the gate (rc=$RC)"
fi

# 4) an opened code fence that is never closed
printf '# probe\n\n```bash\necho hi\n' > "$PROBE"
run_check
if [[ "$RC" -ne 0 ]] && grep -q "unbalanced code fence" <<<"$OUT"; then
  pass "an unbalanced code fence is detected"
else
  fail "unbalanced-fence probe did not trip the gate (rc=$RC)"
fi

# 4b) a marked reference table rejects blank cells, then accepts a populated table
printf '# probe\n\n<!-- wgm: complete-table -->\n| Name | Constraint |\n|---|---|\n| value | |\n' > "$PROBE"
run_check
if [[ "$RC" -ne 0 ]] && grep -q "complete table" <<<"$OUT"; then
  pass "a marked complete table rejects blank cells"
else
  fail "blank complete-table probe did not trip the gate (rc=$RC)"
fi
printf '# probe\n\n<!-- wgm: complete-table -->\n| Name | Constraint |\n|---|---|\n| - | - |\n' > "$PROBE"
run_check
if [[ "$RC" -ne 0 ]] && grep -q "complete table" <<<"$OUT"; then
  pass "a marked complete table rejects placeholder dashes"
else
  fail "placeholder complete-table probe did not trip the gate (rc=$RC)"
fi
printf '# probe\n\n<!-- wgm: complete-table -->\nName | Constraint\n--- | ---\nvalue |\n' > "$PROBE"
run_check
if [[ "$RC" -ne 0 ]] && grep -q "complete table" <<<"$OUT"; then
  pass "a marked complete table rejects blank cells without outer pipes"
else
  fail "outer-pipe-free complete-table probe did not trip the gate (rc=$RC)"
fi
printf '# probe\n\n<!-- wgm: complete-table -->\n| Name | Constraint |\n|---|---|\n| value | bounded |\n' > "$PROBE"
run_check
if [[ "$RC" -eq 0 ]]; then
  pass "a populated complete table passes the gate"
else
  fail "populated complete-table probe stayed red: $OUT"
fi

# 5) removing the probe returns the tree to green (the probes were the only cause)
rm -f "$PROBE"
run_check
if [[ "$RC" -eq 0 ]]; then
  pass "removing the probes returns the docs gate to green"
else
  fail "docs gate stayed red after probe cleanup: $OUT"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "check-docs harness: GREEN"
  exit 0
else
  echo "check-docs harness: RED" >&2
  exit 1
fi
