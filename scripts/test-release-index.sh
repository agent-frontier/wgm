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
#  10. the stable archive must be a byte-identical copy of the versioned one, or WGM_REF=latest and
#      WGM_REF=vX.Y would install different code from the same release with both hashes "valid"
#  11. a declared size_bytes that disagrees with the file on disk is rejected
#  12. contents.companions must be EXACTLY the shipped set — extra claims fail too, not just missing
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

# A minimal but structurally honest skill tree: the contents gate cares that a root SKILL.md, every
# companion, and the references/ tree are really in the archive.
make_tree() {
  local dir="$1"; shift
  local version="${1:-$VERSION}"; shift || true
  local skip="${1:-}"
  local c
  mkdir -p "$dir/references"
  cat > "$dir/SKILL.md" <<EOF
---
name: wgm
metadata:
  version: "${version}"
---
EOF
  printf '# ralph loop\n' > "$dir/references/ralph-loop.md"
  for c in teach-me quiz-me rugged; do
    [[ "$c" == "$skip" ]] && continue
    mkdir -p "$dir/companions/$c"
    printf -- '---\nname: %s\n---\n' "$c" > "$dir/companions/$c/SKILL.md"
  done
}

# Package a tree the way the release workflow does: a versioned archive plus a byte-identical
# stable-named copy.
pack() {
  local tree="$1" dest="$2" tag="$3" abs
  mkdir -p "$dest"
  abs="$(cd "$dest" && pwd)" || return 1
  ( cd "$tree" && tar -czf "$abs/wgm-${tag}.tar.gz" . ) || return 1
  cp "$abs/wgm-${tag}.tar.gz" "$abs/wgm.tar.gz"
}

make_tree tree
pack tree dist "$TAG" || exit 2

OUT=""; RC=0
# The build script is EXPECTED to exit non-zero in most cases here, so its status must be captured,
# never allowed to abort the harness before the assertion that names the case. This harness runs
# without errexit; the save/restore keeps that true even if a future edit turns errexit on, so a
# probe can never leave it enabled behind itself.
capture() {
  local had_errexit=0
  [[ $- == *e* ]] && had_errexit=1
  set +e
  OUT="$("$@" 2>&1)"
  RC=$?
  (( had_errexit )) && set -e
  return 0
}
run() { capture bash "$BUILD" "$@"; }

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

validate() { local f="$1"; shift; capture bash "$BUILD" --validate "$f" "$@"; }

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

# The generator refuses the same mismatch at source. The fixture is deliberately complete for the tag
# being built — correctly named `wgm-v1.2.tar.gz` and `wgm.tar.gz`, both carrying the full tree — so
# the ONLY thing wrong is that the source SKILL.md says 9.9. A missing archive must not be able to
# masquerade as this assertion passing.
pack tree v12dist v1.2 || exit 2
run --tag v1.2 --commit "$SHA" --repo "$REPO" --dist v12dist --root tree --out v12dist/bad.json
if [[ "$RC" -ne 0 ]] \
   && grep -q "tag 'v1.2' does not match SKILL.md version '9.9'" <<<"$OUT" \
   && ! grep -q "is missing from" <<<"$OUT"; then
  pass "the generator refuses a tag that disagrees with SKILL.md, with the archives all present"
else
  fail "the generator built a record for a mismatched tag, or failed for another reason (rc=$RC): $OUT"
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
#
# The SOURCE tree here is complete — SKILL.md, references/, and all three companions — so the
# generator's preflight over --root passes cleanly. Only the packaged archives omit `rugged`. That
# isolates the assertion to verify_archive_contents: if the tree were also incomplete, this case
# would pass on the preflight's error message while the archive gate silently rotted.
make_tree partial/tree
make_tree partial/pack "$VERSION" rugged
pack partial/pack partial/dist "$TAG" || exit 2
[[ -f "partial/dist/wgm-${TAG}.tar.gz" && -f partial/dist/wgm.tar.gz ]] \
  || fail "the companion-omission fixture did not produce both archives"
run --tag "$TAG" --commit "$SHA" --repo "$REPO" --dist partial/dist --root partial/tree --out partial/dist/release.json
if [[ "$RC" -ne 0 ]] \
   && grep -q "does not contain the companion skill 'rugged'" <<<"$OUT" \
   && ! grep -q "is missing from partial/tree" <<<"$OUT"; then
  pass "an archive that omits a companion is rejected by the archive gate, though the source tree is complete"
else
  fail "a companion-less archive was accepted, or failed for another reason (rc=$RC): $OUT"
fi

# Same discipline for the references/ tree: SKILL.md loads references/*.md every iteration, so an
# archive without them installs cleanly and dead-ends on first use.
make_tree norefs/tree
make_tree norefs/pack
rm -rf norefs/pack/references
pack norefs/pack norefs/dist "$TAG" || exit 2
run --tag "$TAG" --commit "$SHA" --repo "$REPO" --dist norefs/dist --root norefs/tree --out norefs/dist/release.json
if [[ "$RC" -ne 0 ]] && grep -q "does not contain the references/ tree" <<<"$OUT"; then
  pass "an archive missing the references/ tree is rejected, though SKILL.md and every companion are present"
else
  fail "an archive without references/ was accepted (rc=$RC): $OUT"
fi

make_tree noskill/tree
mkdir -p noskill/pack && printf 'x\n' > noskill/pack/x.txt
pack noskill/pack noskill/dist "$TAG" || exit 2
run --tag "$TAG" --commit "$SHA" --repo "$REPO" --dist noskill/dist --root noskill/tree --out noskill/dist/release.json
if [[ "$RC" -ne 0 ]] && grep -q "does not contain SKILL.md at its root" <<<"$OUT"; then
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

# "Contains the required set" is not enough: a record advertising a companion the archive does not
# ship is a promise the install cannot keep, so the claim must be exactly the shipped set.
jq '.contents.companions += ["ghost-me"]' "$GOOD" > extracompanion.json
validate extracompanion.json
if [[ "$RC" -ne 0 ]] && grep -q "does not ship: 'ghost-me'" <<<"$OUT"; then
  pass "a record claiming a companion the release does not ship is rejected"
else
  fail "an extra companion claim was accepted (rc=$RC): $OUT"
fi

jq '.contents.companions += ["rugged"]' "$GOOD" > dupcompanion.json
validate dupcompanion.json
if [[ "$RC" -ne 0 ]] && grep -q "exactly the 3 required companion skills" <<<"$OUT"; then
  pass "a duplicated companion entry is rejected (exact set, not superset)"
else
  fail "a duplicated companion entry was accepted (rc=$RC): $OUT"
fi

# --- 7b) SKILL.md must be at the ARCHIVE ROOT ---------------------------------------------------
# A loose match on "any path ending in SKILL.md" is satisfied by companions/teach-me/SKILL.md, so an
# archive carrying only the companions — no wgm skill at all — would pass a naive contents check.
make_tree rootless/tree                  # the source tree is complete …
make_tree rootless/pack
rm -f rootless/pack/SKILL.md             # … but the ARCHIVE keeps only the companions' manifests
pack rootless/pack rootless/dist "$TAG" || exit 2
run --tag "$TAG" --commit "$SHA" --repo "$REPO" --dist rootless/dist --root rootless/tree --out rootless/dist/release.json
if [[ "$RC" -ne 0 ]] && grep -q "does not contain SKILL.md at its root" <<<"$OUT"; then
  pass "an archive with companion SKILL.md files but no root SKILL.md is rejected"
else
  fail "a rootless archive passed the contents gate (rc=$RC): $OUT"
fi

# --- 10) the stable archive must be the versioned archive's bytes -------------------------------
# The subtlest hole in a per-asset checksum scheme: wgm.tar.gz and wgm-vX.Y.tar.gz each hash
# correctly, but they are DIFFERENT builds. WGM_REF=latest and WGM_REF=vX.Y then install different
# code from one release and every checksum still verifies. Both must be the same bytes.
mkdir -p divergent/dist
cp -r tree divergent/tree
( cd divergent/tree && tar -czf "../dist/wgm-${TAG}.tar.gz" . ) || exit 2
printf '\n# drifted stable build\n' >> divergent/tree/SKILL.md
( cd divergent/tree && tar -czf ../dist/wgm.tar.gz . ) || exit 2
run --tag "$TAG" --commit "$SHA" --repo "$REPO" --dist divergent/dist --root divergent/tree --out divergent/dist/release.json
if [[ "$RC" -ne 0 ]] && grep -q "byte-identical copy" <<<"$OUT"; then
  pass "a stable archive whose contents differ from the versioned archive is rejected, though both hashes are valid"
else
  fail "a divergent stable archive was accepted (rc=$RC): $OUT"
fi

# Same defect reached from the other side: a record that simply declares two different hashes.
jq '(.assets[] | select(.role == "stable-archive") | .sha256) = "1111111111111111111111111111111111111111111111111111111111111111"' "$GOOD" > splithash.json
validate splithash.json
if [[ "$RC" -ne 0 ]] && grep -q "byte-identical copy" <<<"$OUT"; then
  pass "a record declaring different hashes for the stable and versioned archives is rejected"
else
  fail "a record with divergent declared hashes was accepted (rc=$RC): $OUT"
fi

# And from the disk side: a record claiming they match while the files on disk do not.
mkdir -p swapped
cp dist/SHA256SUMS "dist/wgm-${TAG}.tar.gz" swapped/
cp -r tree other-tree
printf '\n# other build\n' >> other-tree/SKILL.md
( cd other-tree && tar -czf ../swapped/wgm.tar.gz . ) || exit 2
validate "$GOOD" --assets-dir swapped
if [[ "$RC" -ne 0 ]] && grep -qE "byte-identical copy|hash mismatch" <<<"$OUT"; then
  pass "archives on disk that disagree with each other are rejected during re-validation"
else
  fail "divergent archives on disk were accepted (rc=$RC): $OUT"
fi

# --- 11) declared size must match the file ------------------------------------------------------
# Independent corroboration of the hash: a truncated upload or a swapped asset shows up in the size
# even when someone updates the hash field to match the wrong file.
jq '(.assets[] | select(.role == "checksums") | .size_bytes) = 999999' "$GOOD" > size.json
validate size.json --assets-dir dist
if [[ "$RC" -ne 0 ]] && grep -q "size mismatch" <<<"$OUT"; then
  pass "a declared size_bytes that disagrees with the file on disk is rejected"
else
  fail "a wrong size_bytes was accepted (rc=$RC): $OUT"
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
