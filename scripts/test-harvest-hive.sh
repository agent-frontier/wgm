#!/usr/bin/env bash
#
# wgm/test-harvest-hive.sh — deterministic backpressure for scripts/harvest-hive.sh.
#
# Exercises the anonymize + consent-file state machine entirely with throwaway fixtures. Every case
# here stays on paths that never call `gh` for real (dry-run, or a declined/false consent — both are
# guaranteed no-network paths in harvest-hive.sh itself), so no real agent, model, network, or GitHub
# token is needed.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARVEST="$ROOT/scripts/harvest-hive.sh"

FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

TMP="$(mktemp -d)"
trap 'cd /; rm -rf "$TMP"' EXIT
cd "$TMP"

OUT=""; RC=0
run() {  # run harvest-hive.sh, capturing combined output + exit code without tripping set -e
  set +e
  OUT="$("$HARVEST" "$@" 2>&1 </dev/null)"; RC=$?
  set -e
}

printf 'lesson: hit a bug at https://example.com/secret in /home/someone/project/app.py with token=abcd1234efgh5678ijkl and repo SchwartzKamel/floci-az plus email foo@bar.com\n' > memories.md
: > empty.md
printf 'consent: false\nauto_report: false\nsources:\n  - dogfood\n' > consent-false.yml
printf 'consent: true\nauto_report: true\nsources:\n  - dogfood\n' > consent-true.yml

# 1) --dry-run with no consent file yet: asks once, previews (doesn't write) the file, redacts, and
#    never touches gh.
run --dry-run --memories memories.md --consent-file consent-new.yml --repo agent-frontier/wgm
if [[ "$RC" -eq 0 ]] \
   && grep -q "Enable this for this project?" <<<"$OUT" \
   && grep -q "Would write consent file consent-new.yml" <<<"$OUT" \
   && grep -q "no gh network or mutation calls were made" <<<"$OUT" \
   && [[ ! -f consent-new.yml ]]; then
  pass "dry-run with no consent file previews without writing or calling gh"
else
  fail "dry-run first-question path misbehaved (rc=$RC): $OUT"
fi

# 2) anonymization scrubs every planted category, and leaves ordinary prose alone.
if grep -q '<redacted-url>' <<<"$OUT" \
   && grep -q '<redacted-path>' <<<"$OUT" \
   && grep -q '<redacted-credential>' <<<"$OUT" \
   && grep -q '<redacted-email>' <<<"$OUT" \
   && grep -q 'hit a bug at' <<<"$OUT" \
   && ! grep -q 'example.com' <<<"$OUT" \
   && ! grep -q '/home/someone' <<<"$OUT" \
   && ! grep -q 'abcd1234efgh5678ijkl' <<<"$OUT" \
   && ! grep -q 'foo@bar.com' <<<"$OUT"; then
  pass "anonymization redacts URL, path, credential, and email while keeping ordinary prose"
else
  fail "anonymization did not redact every planted category: $OUT"
fi

# 3) an existing consent:false file takes the declined path for real (non-dry-run) and still never
#    calls gh — this path is unconditionally network-free in harvest-hive.sh, so it's safe to run
#    without --dry-run.
run --memories memories.md --consent-file consent-false.yml --repo agent-frontier/wgm
if [[ "$RC" -eq 0 ]] \
   && grep -q "Reporting is disabled for this project" <<<"$OUT" \
   && ! grep -q "Created new learning issue" <<<"$OUT" \
   && ! grep -q "Updated existing learning issue" <<<"$OUT" \
   && [[ "$(cat consent-false.yml)" == "$(printf 'consent: false\nauto_report: false\nsources:\n  - dogfood')" ]]; then
  pass "declined consent takes the local-only path for real and leaves the consent file untouched"
else
  fail "declined-consent real run misbehaved (rc=$RC): $OUT"
fi

# 4) a real (non-dry-run) first run with no consent file and non-interactive stdin still never
#    calls gh — it defaults to declined and writes the file so it is asked only once.
run --memories memories.md --consent-file consent-first-real.yml --repo agent-frontier/wgm
if [[ "$RC" -eq 0 ]] \
   && grep -q "stdin is not interactive; treating this run as declined" <<<"$OUT" \
   && [[ -f consent-first-real.yml ]] \
   && grep -q "^consent: false$" consent-first-real.yml \
   && ! grep -q "Created new learning issue" <<<"$OUT"; then
  pass "first real run with non-interactive stdin defaults to declined and writes the file once"
else
  fail "first real run did not default safely (rc=$RC): $OUT"
fi

# 5) re-running against the now-existing file from case 4 does not ask again.
run --memories memories.md --consent-file consent-first-real.yml --repo agent-frontier/wgm
if [[ "$RC" -eq 0 ]] && ! grep -q "Enable this for this project?" <<<"$OUT"; then
  pass "an existing consent file is never asked about again"
else
  fail "re-run asked again despite an existing consent file (rc=$RC): $OUT"
fi

# 6) missing memories file (never harvested yet) is a clean no-op, not an error.
run --dry-run --memories does-not-exist.md --consent-file consent-missing-memories.yml --repo agent-frontier/wgm
if [[ "$RC" -eq 0 ]] && grep -q "Nothing to harvest" <<<"$OUT"; then
  pass "a missing memories file is a clean no-op"
else
  fail "missing memories file was not handled as a no-op (rc=$RC): $OUT"
fi

# 7) an empty memories file is also a clean no-op.
run --dry-run --memories empty.md --consent-file consent-empty-memories.yml --repo agent-frontier/wgm
if [[ "$RC" -eq 0 ]] && grep -q "Nothing to harvest" <<<"$OUT"; then
  pass "an empty memories file is a clean no-op"
else
  fail "empty memories file was not handled as a no-op (rc=$RC): $OUT"
fi

# 8) --memories with no value is rejected before anything runs.
run --memories
if [[ "$RC" -eq 2 ]] && grep -q "requires a file" <<<"$OUT"; then
  pass "--memories with no value is rejected"
else
  fail "--memories with no value was not rejected (rc=$RC): $OUT"
fi

# 9) --help prints usage without touching any file.
run --help
if [[ "$RC" -eq 0 ]] && grep -q "harvest-hive.sh" <<<"$OUT"; then
  pass "--help prints usage"
else
  fail "--help did not print usage (rc=$RC)"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "harvest-hive harness: GREEN"
  exit 0
else
  echo "harvest-hive harness: RED" >&2
  exit 1
fi
