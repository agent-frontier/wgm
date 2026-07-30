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

# 3) anonymization matches repo slugs case-insensitively and redacts Windows-style paths, but does
#    not mistake a plain numeric fraction for a repo slug (a planted regression case: an earlier
#    version of this scrub was lowercase-only and left mixed-case org/repo names exposed).
printf 'note: prefer golang/go idioms; roughly 3/4 of tasks pass; see MyOrg/SecretRepo and C:\\Users\\bob\\project\\file.py\n' > memories-case.md
run --dry-run --memories memories-case.md --consent-file consent-case.yml --repo agent-frontier/wgm
if [[ "$RC" -eq 0 ]] \
   && grep -q '<redacted-repo>' <<<"$OUT" \
   && grep -q '<redacted-path>' <<<"$OUT" \
   && grep -q '3/4' <<<"$OUT" \
   && ! grep -qi 'MyOrg/SecretRepo' <<<"$OUT" \
   && ! grep -q 'C:\\Users\\bob' <<<"$OUT"; then
  pass "anonymization redacts mixed-case repo slugs and Windows paths, without mangling a plain fraction"
else
  fail "case-insensitive / Windows-path anonymization regressed: $OUT"
fi

# 4) an existing consent:false file takes the declined path for real (non-dry-run) and still never
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

# 5) a real (non-dry-run) run with no consent file and non-interactive stdin never calls gh, and
#    does NOT persist a decision on a human's behalf — no one was present to actually answer, so the
#    file is left unwritten (only an interactive Triage session, or a human editing the file by hand,
#    may record real consent) — this run is declined for itself only, not forever.
run --memories memories.md --consent-file consent-first-real.yml --repo agent-frontier/wgm
if [[ "$RC" -eq 0 ]] \
   && grep -q "no human is present to answer, so treating only this run as declined" <<<"$OUT" \
   && [[ ! -f consent-first-real.yml ]] \
   && ! grep -q "Created new learning issue" <<<"$OUT"; then
  pass "a non-interactive run with no consent file declines for itself only, without persisting"
else
  fail "non-interactive first run did not default safely (rc=$RC): $OUT"
fi

# 6) an existing (human-authored) consent file is genuinely never asked about again.
printf 'consent: false\nauto_report: false\nsources:\n  - dogfood\n' > consent-second-real.yml
run --memories memories.md --consent-file consent-second-real.yml --repo agent-frontier/wgm
if [[ "$RC" -eq 0 ]] && ! grep -q "Enable this for this project?" <<<"$OUT"; then
  pass "an existing consent file is never asked about again"
else
  fail "re-run asked again despite an existing consent file (rc=$RC): $OUT"
fi

# 7) missing memories file (never harvested yet) is a clean no-op, not an error.
run --dry-run --memories does-not-exist.md --consent-file consent-missing-memories.yml --repo agent-frontier/wgm
if [[ "$RC" -eq 0 ]] && grep -q "Nothing to harvest" <<<"$OUT"; then
  pass "a missing memories file is a clean no-op"
else
  fail "missing memories file was not handled as a no-op (rc=$RC): $OUT"
fi

# 8) an empty memories file is also a clean no-op.
run --dry-run --memories empty.md --consent-file consent-empty-memories.yml --repo agent-frontier/wgm
if [[ "$RC" -eq 0 ]] && grep -q "Nothing to harvest" <<<"$OUT"; then
  pass "an empty memories file is a clean no-op"
else
  fail "empty memories file was not handled as a no-op (rc=$RC): $OUT"
fi

# 9) --memories with no value is rejected before anything runs.
run --memories
if [[ "$RC" -eq 2 ]] && grep -q "requires a file" <<<"$OUT"; then
  pass "--memories with no value is rejected"
else
  fail "--memories with no value was not rejected (rc=$RC): $OUT"
fi

# 10) multiple concurrent non-interactive first runs against the same missing consent file all
#     decline in-memory only: nobody crashes, nobody persists consent, and nobody attempts to file
#     anything.
shared_consent="consent-concurrent.yml"
out1="concurrent-1.out"
out2="concurrent-2.out"
out3="concurrent-3.out"
"$HARVEST" --memories memories.md --consent-file "$shared_consent" --repo agent-frontier/wgm >"$out1" 2>&1 </dev/null &
pid1=$!
"$HARVEST" --memories memories.md --consent-file "$shared_consent" --repo agent-frontier/wgm >"$out2" 2>&1 </dev/null &
pid2=$!
"$HARVEST" --memories memories.md --consent-file "$shared_consent" --repo agent-frontier/wgm >"$out3" 2>&1 </dev/null &
pid3=$!

set +e
wait "$pid1"; rc1=$?
wait "$pid2"; rc2=$?
wait "$pid3"; rc3=$?
set -e

combined_output="$(cat "$out1" "$out2" "$out3")"
if [[ "$rc1" -eq 0 ]] \
   && [[ "$rc2" -eq 0 ]] \
   && [[ "$rc3" -eq 0 ]] \
   && [[ ! -f "$shared_consent" ]] \
   && ! grep -q "Created new learning issue" <<<"$combined_output" \
   && ! grep -q "Updated existing learning issue" <<<"$combined_output"; then
  pass "concurrent non-interactive first runs all decline safely without persisting or filing"
else
  fail "concurrent non-interactive first runs were not all safe (rcs=$rc1/$rc2/$rc3): $combined_output"
fi

# 11) --help prints usage without touching any file.
run --help
if [[ "$RC" -eq 0 ]] && grep -q "harvest-hive.sh" <<<"$OUT"; then
  pass "--help prints usage"
else
  fail "--help did not print usage (rc=$RC)"
fi

# ---- fail-closed contract ([learn] issue #79) -----------------------------------
# A consent flag authorizes ONE sanitized lesson, never the source ledger. These cases prove the
# courier refuses rather than publishing whenever it cannot show the candidate is minimal and clean.

printf 'AcmeCorp\nsecret-product\n' > denylist.txt
export WGM_HIVE_DENYLIST="$TMP/denylist.txt"

# 12) a multi-entry ledger yields ONE lesson — the source ledger can never become the issue body.
printf -- '- lesson: first entry about parked lane accounting\n- lesson: second entry about worktree re-pinning\n' > ledger.md
run --dry-run --memories ledger.md --consent-file c12.yml
if [[ "$RC" -eq 0 ]] \
   && grep -q "second entry about worktree re-pinning" <<<"$OUT" \
   && ! grep -q "first entry about parked lane accounting" <<<"$OUT"; then
  pass "only one lesson is forwarded; the rest of the ledger never reaches the body"
else
  fail "multi-entry ledger was not reduced to a single lesson (rc=$RC): $OUT"
fi

# 13) a residual host identifier refuses with a non-zero exit and no filing.
printf -- '- lesson: the secret-product gate needs a probe per AcmeCorp runbook\n' > dirty.md
run --dry-run --memories dirty.md --consent-file c13.yml
if [[ "$RC" -ne 0 ]] \
   && grep -q "REFUSING to publish" <<<"$OUT" \
   && grep -q "secret-product" <<<"$OUT" \
   && ! grep -q "Would file to" <<<"$OUT"; then
  pass "a residual host identifier refuses publication with a non-zero exit"
else
  fail "a dirty lesson was not refused (rc=$RC): $OUT"
fi

# 14) consent:true does NOT bypass the scrub — a failed scan still refuses, still without gh.
printf 'consent: true\nauto_report: true\nsources:\n  - dogfood\n' > c14.yml
run --memories dirty.md --consent-file c14.yml
if [[ "$RC" -ne 0 ]] \
   && grep -q "REFUSING to publish" <<<"$OUT" \
   && grep -q "no network call was made" <<<"$OUT"; then
  pass "consent true plus a scrub failure still refuses"
else
  fail "consent:true bypassed the fail-closed scan (rc=$RC): $OUT"
fi

# 15) over the single-lesson size ceiling: refuse rather than forwarding a ledger-sized payload.
{ printf -- '- lesson: '; for _ in $(seq 1 400); do printf 'generic loop guidance word '; done; printf '\n'; } > big.md
run --dry-run --memories big.md --consent-file c15.yml
if [[ "$RC" -ne 0 ]] && grep -q "single-lesson ceiling" <<<"$OUT"; then
  pass "a candidate over the single-lesson size ceiling is refused"
else
  fail "the size ceiling did not refuse an oversized candidate (rc=$RC): $OUT"
fi

# 16) a minimal generic lesson passes, and dry-run and real mode render byte-identical title+body.
printf -- '- lesson: re-pin the lane worktree path on every state-mutating turn\n' > clean.md
printf 'consent: false\nauto_report: false\nsources:\n  - dogfood\n' > c16.yml
run --dry-run --memories clean.md --consent-file c16.yml
dry_draft="$(sed -n '/^Would file to/,$p' <<<"$OUT" | grep -v '^Dry run:')"
dry_rc="$RC"
run --memories clean.md --consent-file c16.yml
real_draft="$(sed -n '/^Would file to/,$p' <<<"$OUT" | grep -v '^Reporting is disabled')"
if [[ "$dry_rc" -eq 0 && "$RC" -eq 0 ]] \
   && [[ -n "$dry_draft" ]] && [[ "$dry_draft" == "$real_draft" ]]; then
  pass "a clean lesson passes, and dry-run and real mode render the identical payload"
else
  fail "dry-run and real payloads diverged (dry_rc=$dry_rc rc=$RC): [$dry_draft] vs [$real_draft]"
fi

unset WGM_HIVE_DENYLIST

if [[ "$FAILED" -eq 0 ]]; then
  echo "harvest-hive harness: GREEN"
  exit 0
else
  echo "harvest-hive harness: RED" >&2
  exit 1
fi
