#!/usr/bin/env bash
#
# wgm/test-release-index.sh — deterministic backpressure for scripts/build-release-index.sh.
#
# The release record is the one artifact a future updater (T9) will trust without a human in the
# loop: it decides "is there a newer stable wgm?" and "are these the bytes that release claims?".
# There is no server to correct a bad record after publication — a tag's assets are immutable — so
# every failure mode has to be caught BEFORE `gh release create`, by this validator, offline.
#
# Hence this harness. It builds a throwaway skill tree and real gzip archives in a temp directory,
# then proves each failure mode is RED and the honest case is GREEN. It needs no network, no `gh`,
# and no credentials: everything it asserts about is a local file plus jq.
#
# Cases (each maps to a way a release could lie or break):
#   1. a well-formed record validates, and the generator self-validates what it writes
#   2. a missing required field is caught (a truncated/hand-edited record)
#   3. a tag/version mismatch is caught (tag v9.9 shipping SKILL.md 0.3 — wrong bytes under a name)
#   4. a malformed record (not JSON / not an object) is caught, not half-parsed
#   5. an archive hash mismatch is caught (record and file disagree = corrupted or swapped asset)
#   6. stable-channel immutability: a moving ref (main/latest) or a non-sha commit is rejected
#   7. a release missing SKILL.md or a companion is rejected even though its checksum is perfect
#   8. false provenance claims (signatures, unbacked attestation) are rejected
#   9. unknown/extra keys and unknown schema versions are rejected, so drift can't creep in silently
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/scripts/build-release-index.sh"

FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

command -v jq >/dev/null 2>&1 || { echo "jq is required but not found on PATH." >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'cd /; rm -rf "$TMP"' EXIT
cd "$TMP" || exit 2

TAG="v9.9"
VERSION="9.9"
SHA="0123456789abcdef0123456789abcdef01234567"
REPO="agent-frontier/wgm"

# A minimal but structurally honest skill tree: the record's contents gate only cares that SKILL.md
# and every companion are really in the archive.
mkdir -p tree/companions/teach-me tree/companions/quiz-me tree/companions/rugged
cat > tree/SKILL.md <<EOF
---
name: wgm
metadata:
  version: "${VERSION}"
---
EOF
for c in teach-me quiz-me rugged; do
  printf -- '---\nname: %s\n---\n' "$c" > "tree/companions/$c/SKILL.md"
done

mkdir -p dist
( cd tree && tar -czf "../dist/wgm-${TAG}.tar.gz" . ) || exit 2
cp "dist/wgm-${TAG}.tar.gz" dist/wgm.tar.gz

OUT=""; RC=0
run() { set +e; OUT="$(bash "$BUILD" "$@" 2>&1)"; RC=$?; set -e; }

# --- 1) the honest case -----------------------------------------------------------------------
run --tag "$TAG" --commit "$SHA" --repo "$REPO" --dist dist --root tree --out dist/release.json
if [[ "$RC" -eq 0 ]] && grep -q "release-index: GREEN" <<<"$OUT" && [[ -f dist/release.json ]]; then
  pass "a complete release builds a record and self-validates"
else
  fail "building the honest release record failed (rc=$RC): $OUT"
fi

if [[ -f dist/SHA256SUMS ]] && ( cd dist && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
  pass "SHA256SUMS is written and verifies with 'sha256sum -c'"
else
  fail "SHA256SUMS is missing or does not verify"
fi

GOOD="$TMP/good.json"
cp dist/release.json "$GOOD"

# The record must carry the fields the updater contract promises. Asserting them by name here is the
# thing that stops a future refactor from quietly dropping one.
for field in schema_version channel version tag commit published_at minimum_updater_schema; do
  if [[ "$(jq -r --arg f "$field" 'has($f)' "$GOOD")" != "true" ]]; then
    fail "the record is missing the contract field '$field'"
  fi
done
if [[ "$(jq -r '.assets | length' "$GOOD")" -ge 3 ]] \
   && [[ "$(jq -r '[.assets[].role] | sort | join(",")' "$GOOD")" == "checksums,stable-archive,versioned-archive" ]]; then
  pass "the record names the versioned archive, the stable archive, and the checksum file"
else
  fail "the record's asset roles are wrong: $(jq -c '[.assets[].role]' "$GOOD")"
fi

# Every asset URL must be the immutable per-tag download path, never the /latest/ alias. The alias
# still exists for installers (WGM_REF=latest) — it just must not be what the record points at.
if [[ "$(jq -r --arg t "$TAG" '[.assets[] | select(.url | contains("/releases/download/" + $t + "/"))] | length' "$GOOD")" == "3" ]] \
   && ! grep -q "releases/latest/download" "$GOOD"; then
  pass "asset URLs are immutable per-tag paths, not the moving /releases/latest/ alias"
else
  fail "the record points at a moving URL: $(jq -c '[.assets[].url]' "$GOOD")"
fi

validate() { set +e; OUT="$(bash "$BUILD" --validate "$1" "${@:2}" 2>&1)"; RC=$?; set -e; }

validate "$GOOD" --assets-dir dist --expect-tag "$TAG"
if [[ "$RC" -eq 0 ]]; then
  pass "the good record re-validates against the archives on disk"
else
  fail "the good record failed re-validation (rc=$RC): $OUT"
fi

# --- 2) a missing required field --------------------------------------------------------------
# Hand edits and truncated writes happen; an updater reading a record with no channel would have to
# guess, so the validator must refuse it instead.
jq 'del(.channel)' "$GOOD" > missing.json
validate missing.json
if [[ "$RC" -ne 0 ]] && grep -q "missing required key: 'channel'" <<<"$OUT"; then
  pass "a record missing a required field is rejected and the field is named"
else
  fail "a missing field was not caught (rc=$RC): $OUT"
fi

# --- 3) tag/version mismatch ------------------------------------------------------------------
# The nastiest silent failure: v9.9 assets built from a 0.3 tree. The updater would install older
# code believing it is newer, and every hash would check out.
jq '.version = "0.3"' "$GOOD" > mismatch.json
validate mismatch.json
if [[ "$RC" -ne 0 ]] && grep -q "tag/version mismatch" <<<"$OUT"; then
  pass "a tag that disagrees with the record's version is rejected"
else
  fail "a tag/version mismatch was not caught (rc=$RC): $OUT"
fi

validate "$GOOD" --expect-tag v1.2
if [[ "$RC" -ne 0 ]] && grep -q "does not match the expected tag" <<<"$OUT"; then
  pass "a record whose tag differs from the tag being published is rejected"
else
  fail "the --expect-tag cross-check did not fire (rc=$RC): $OUT"
fi

# The generator refuses the same mismatch at source, so a local reproduction can't produce it.
run --tag v1.2 --commit "$SHA" --repo "$REPO" --dist dist --root tree --out dist/bad.json
if [[ "$RC" -ne 0 ]] && grep -q "does not match SKILL.md version" <<<"$OUT"; then
  pass "the generator refuses a tag that disagrees with SKILL.md"
else
  fail "the generator built a record for a mismatched tag (rc=$RC): $OUT"
fi

# --- 4) malformed record ----------------------------------------------------------------------
printf '{"schema_version": 1, "channel":\n' > malformed.json
validate malformed.json
if [[ "$RC" -ne 0 ]] && grep -q "not valid JSON" <<<"$OUT"; then
  pass "a truncated/malformed record is rejected as unparseable"
else
  fail "malformed JSON was not caught (rc=$RC): $OUT"
fi

printf '[]\n' > array.json
validate array.json
if [[ "$RC" -ne 0 ]] && grep -q "must be a JSON object" <<<"$OUT"; then
  pass "a record that parses but is not an object is rejected"
else
  fail "a non-object record was not caught (rc=$RC): $OUT"
fi

validate no-such-file.json
if [[ "$RC" -ne 0 ]] && grep -q "is missing" <<<"$OUT"; then
  pass "a missing record file is RED, not a silent pass"
else
  fail "a missing record file did not fail (rc=$RC): $OUT"
fi

# --- 5) archive hash mismatch -----------------------------------------------------------------
# Corruption, a re-packed archive after hashing, or a swapped asset. The bytes users get must be the
# bytes the record vouches for, so validation re-hashes rather than trusting the field.
mkdir -p tampered && cp dist/* tampered/
printf 'tampered\n' >> "tampered/wgm-${TAG}.tar.gz"
validate "$GOOD" --assets-dir tampered
if [[ "$RC" -ne 0 ]] && grep -q "hash mismatch" <<<"$OUT"; then
  pass "an archive whose bytes differ from the recorded sha256 is rejected"
else
  fail "an archive hash mismatch was not caught (rc=$RC): $OUT"
fi

# A record naming an asset that was never uploaded would 404 for every user.
mkdir -p incomplete && cp dist/SHA256SUMS dist/wgm.tar.gz incomplete/
validate "$GOOD" --assets-dir incomplete
if [[ "$RC" -ne 0 ]] && grep -q "missing from" <<<"$OUT"; then
  pass "a record naming an asset that is not present is rejected"
else
  fail "a missing asset was not caught (rc=$RC): $OUT"
fi

# A malformed sha256 field (wrong length, uppercase, placeholder) must not slip through.
jq '.assets[0].sha256 = "deadbeef"' "$GOOD" > shortsha.json
validate shortsha.json
if [[ "$RC" -ne 0 ]] && grep -q "malformed sha256" <<<"$OUT"; then
  pass "a malformed sha256 field is rejected"
else
  fail "a malformed sha256 was not caught (rc=$RC): $OUT"
fi

# --- 6) stable-channel immutability -------------------------------------------------------------
# The whole point of the stable channel: it must name a tag and a commit that can never move. A
# record pinned to main/latest would make every updater run a lottery.
for moving in main latest HEAD; do
  jq --arg t "$moving" '.tag = $t' "$GOOD" > "moving-$moving.json"
  validate "moving-$moving.json"
  if [[ "$RC" -ne 0 ]] && grep -qE "moving ref|tag/version mismatch" <<<"$OUT"; then
    pass "a stable record pinned to '$moving' is rejected"
  else
    fail "a stable record pinned to '$moving' was accepted (rc=$RC): $OUT"
  fi
done

jq '.commit = "main"' "$GOOD" > branchcommit.json
validate branchcommit.json
if [[ "$RC" -ne 0 ]] && grep -q "full 40-hex sha" <<<"$OUT"; then
  pass "a record whose commit is a branch name instead of a sha is rejected"
else
  fail "a non-sha commit was accepted (rc=$RC): $OUT"
fi

jq '.assets[0].url = "https://github.com/agent-frontier/wgm/releases/latest/download/wgm-v9.9.tar.gz"' "$GOOD" > aliasurl.json
validate aliasurl.json
if [[ "$RC" -ne 0 ]] && grep -q "immutable tag download URL" <<<"$OUT"; then
  pass "an asset URL using the moving /releases/latest/ alias is rejected"
else
  fail "a moving asset URL was accepted (rc=$RC): $OUT"
fi

jq '.channel = "marketplace"' "$GOOD" > channel.json
validate channel.json
if [[ "$RC" -ne 0 ]] && grep -q "channel must be one of" <<<"$OUT"; then
  pass "an unknown channel is rejected (only stable and edge exist)"
else
  fail "an unknown channel was accepted (rc=$RC): $OUT"
fi

# --- 7) incomplete skill tree -------------------------------------------------------------------
# A perfectly-hashed archive can still be a broken install. Checksums say nothing about contents.
mkdir -p partial/dist partial/tree/companions/teach-me partial/tree/companions/quiz-me
cp tree/SKILL.md partial/tree/SKILL.md
cp tree/companions/teach-me/SKILL.md partial/tree/companions/teach-me/SKILL.md
cp tree/companions/quiz-me/SKILL.md partial/tree/companions/quiz-me/SKILL.md
( cd partial/tree && tar -czf "../dist/wgm-${TAG}.tar.gz" . ) || exit 2
cp "partial/dist/wgm-${TAG}.tar.gz" partial/dist/wgm.tar.gz
run --tag "$TAG" --commit "$SHA" --repo "$REPO" --dist partial/dist --root partial/tree --out partial/dist/release.json
if [[ "$RC" -ne 0 ]] && grep -q "rugged" <<<"$OUT"; then
  pass "a release whose archive omits a companion skill is rejected despite a valid checksum"
else
  fail "a companion-less release was accepted (rc=$RC): $OUT"
fi

mkdir -p noskill/dist noskill/tree/companions
( cd noskill && mkdir -p empty && cd empty && printf 'x\n' > x.txt && tar -czf "../dist/wgm-${TAG}.tar.gz" . ) || exit 2
cp "noskill/dist/wgm-${TAG}.tar.gz" noskill/dist/wgm.tar.gz
cp tree/SKILL.md noskill/tree/SKILL.md
for c in teach-me quiz-me rugged; do
  mkdir -p "noskill/tree/companions/$c" && cp "tree/companions/$c/SKILL.md" "noskill/tree/companions/$c/SKILL.md"
done
run --tag "$TAG" --commit "$SHA" --repo "$REPO" --dist noskill/dist --root noskill/tree --out noskill/dist/release.json
if [[ "$RC" -ne 0 ]] && grep -q "does not contain SKILL.md" <<<"$OUT"; then
  pass "an archive with no SKILL.md is rejected before publication"
else
  fail "an archive without SKILL.md was accepted (rc=$RC): $OUT"
fi

jq '.contents.companions = ["teach-me"]' "$GOOD" > dropped.json
validate dropped.json
if [[ "$RC" -ne 0 ]] && grep -q "missing the companion skill" <<<"$OUT"; then
  pass "a record that stops claiming a companion is rejected"
else
  fail "a dropped companion claim was accepted (rc=$RC): $OUT"
fi

# --- 8) honest provenance -----------------------------------------------------------------------
# SHA-256 proves integrity against corruption and mixed-up assets. It is NOT a signature and proves
# nothing about who built the bytes. The record must never imply otherwise.
if [[ "$(jq -r '.provenance.signatures' "$GOOD")" == "none" ]] \
   && [[ "$(jq -r '.provenance.attestation' "$GOOD")" == "unavailable" ]] \
   && [[ "$(jq -r '.provenance.attestation_url' "$GOOD")" == "null" ]]; then
  pass "provenance is labelled honestly: checksums only, no signatures, no attestation claimed"
else
  fail "the default provenance block overclaims: $(jq -c '.provenance' "$GOOD")"
fi

jq '.provenance.signatures = "sigstore"' "$GOOD" > signed.json
validate signed.json
if [[ "$RC" -ne 0 ]] && grep -q "not a signature" <<<"$OUT"; then
  pass "a record claiming signatures that do not exist is rejected"
else
  fail "a false signature claim was accepted (rc=$RC): $OUT"
fi

jq '.provenance.attestation = "github-artifact-attestation" | .provenance.attestation_url = null' "$GOOD" > attest.json
validate attest.json
if [[ "$RC" -ne 0 ]] && grep -q "attestation_url must be an https URL" <<<"$OUT"; then
  pass "claiming an attestation without a URL to it is rejected"
else
  fail "an unbacked attestation claim was accepted (rc=$RC): $OUT"
fi

# --- 9) schema drift ------------------------------------------------------------------------------
# Allow-listed keys, same discipline as check-evals/check-harnesses: an invented or renamed field
# fails loudly instead of being ignored by a consumer that never looks at it.
jq '.marketplace_url = "https://example.com"' "$GOOD" > extra.json
validate extra.json
if [[ "$RC" -ne 0 ]] && grep -q "unexpected key: 'marketplace_url'" <<<"$OUT"; then
  pass "an unexpected top-level key is rejected"
else
  fail "an unexpected key was accepted (rc=$RC): $OUT"
fi

jq '.schema_version = 99' "$GOOD" > future.json
validate future.json
if [[ "$RC" -ne 0 ]] && grep -q "schema_version must be" <<<"$OUT"; then
  pass "a record from an unknown schema version is rejected, not guessed at"
else
  fail "an unknown schema_version was accepted (rc=$RC): $OUT"
fi

jq '.published_at = "yesterday"' "$GOOD" > ts.json
validate ts.json
if [[ "$RC" -ne 0 ]] && grep -q "published_at must be an RFC 3339" <<<"$OUT"; then
  pass "a non-RFC-3339 publication timestamp is rejected"
else
  fail "a malformed timestamp was accepted (rc=$RC): $OUT"
fi

jq '.minimum_updater_schema = 0' "$GOOD" > minschema.json
validate minschema.json
if [[ "$RC" -ne 0 ]] && grep -q "minimum_updater_schema" <<<"$OUT"; then
  pass "an out-of-range minimum_updater_schema is rejected"
else
  fail "a bad minimum_updater_schema was accepted (rc=$RC): $OUT"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "release-index harness: GREEN"
  exit 0
else
  echo "release-index harness: RED" >&2
  exit 1
fi
