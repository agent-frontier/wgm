#!/usr/bin/env bash
#
# wgm/build-release-index.sh — build and validate the machine-readable release record.
#
# wgm has no marketplace, no update service, and no database. GitHub Releases IS the distribution
# channel, and a tag is the only immutable thing in this system. That is a feature: there is no
# server to trust, no auth to hold, and no endpoint that can start lying after publication. What was
# missing is a *machine-readable* statement of what a given release actually is, so a future updater
# (T9) can answer "is there a newer stable wgm, and did I download the bytes that release claims?"
# without scraping HTML or trusting a moving `main`.
#
# This script produces two artifacts next to the archives, both published as release assets:
#
#   SHA256SUMS    the `sha256sum -c`-compatible checksum file for the archives
#   release.json  a schema-versioned release record (channel, version, immutable tag + commit,
#                 asset names/URLs/hashes, publication timestamp, minimum updater schema, and an
#                 honestly-labelled provenance block)
#
# It is also the validator for that record (`--validate`), and the workflow runs it in that mode
# BEFORE `gh release create`. Everything here fails closed: malformed JSON, a missing field, a
# tag/version mismatch, a missing asset, a hash or size mismatch, a mutable stable ref, a stable
# archive that is not a byte-identical copy of the versioned one, a SHA256SUMS manifest whose lines
# disagree with the record or the files (or that is malformed, incomplete, duplicated, or names a
# path), or an archive that does not carry a root SKILL.md plus exactly the shipped companions and a
# references/ tree is RED, never a warning.
#
# Usage:
#   scripts/build-release-index.sh --tag vX.Y --commit SHA [options]   # build
#   scripts/build-release-index.sh --validate FILE [--assets-dir DIR] [--expect-tag vX.Y]
#
# Build options:
#   --tag TAG               release tag, e.g. v0.4 (required)
#   --commit SHA            full 40-hex commit the tag points at (required)
#   --repo OWNER/NAME       repository slug (default: $GITHUB_REPOSITORY, else agent-frontier/wgm)
#   --channel CHANNEL       stable (default) or edge
#   --dist DIR              directory holding the archives (default: dist)
#   --root DIR              skill tree to read SKILL.md/companions from (default: repo root)
#   --out FILE              record path (default: DIST/release.json)
#   --published-at TS       RFC 3339 UTC timestamp (default: now, or $SOURCE_DATE_EPOCH)
#   --attestation MODE      unavailable (default) or github-artifact-attestation
#   --attestation-url URL   required when MODE is github-artifact-attestation
#
# Validate options:
#   --validate FILE         validate an existing record and exit
#   --assets-dir DIR        also re-hash the named assets in DIR and check the archives' contents
#   --expect-tag TAG        require the record's tag to equal TAG (the workflow passes the ref)
#
# Exit 0 = green. Exit 1 = red (failures listed on stderr). Exit 2 = usage error or missing jq.

set -uo pipefail

ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The schema version this script writes AND the only one it can validate. Bumping the shape of the
# record means bumping this, so an old validator can never silently accept a newer record.
SCHEMA_VERSION=1
# The lowest updater implementation that can consume a schema-1 record. Published in the record so a
# future updater refuses a release it does not understand instead of guessing.
MIN_UPDATER_SCHEMA=1
# Companions that MUST be in the tree and in the archive. A release that ships wgm without them is a
# broken install, not a partial one — install.sh puts them beside wgm as sibling skills.
COMPANIONS=(teach-me quiz-me rugged)

MODE="build"
TAG=""
COMMIT=""
REPO="${GITHUB_REPOSITORY:-agent-frontier/wgm}"
CHANNEL="stable"
DIST="dist"
ROOT="$ROOT_DEFAULT"
OUT=""
PUBLISHED_AT=""
ATTESTATION="unavailable"
ATTESTATION_URL=""
RECORD=""
ASSETS_DIR=""
EXPECT_TAG=""

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

FAIL=0
note() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
ok()   { printf 'ok:   %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --validate) [[ $# -ge 2 ]] || { echo "--validate requires a file" >&2; exit 2; }; MODE="validate"; RECORD="$2"; shift 2 ;;
    --assets-dir) [[ $# -ge 2 ]] || { echo "--assets-dir requires a directory" >&2; exit 2; }; ASSETS_DIR="$2"; shift 2 ;;
    --expect-tag) [[ $# -ge 2 ]] || { echo "--expect-tag requires a tag" >&2; exit 2; }; EXPECT_TAG="$2"; shift 2 ;;
    --tag) [[ $# -ge 2 ]] || { echo "--tag requires a value" >&2; exit 2; }; TAG="$2"; shift 2 ;;
    --commit) [[ $# -ge 2 ]] || { echo "--commit requires a value" >&2; exit 2; }; COMMIT="$2"; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || { echo "--repo requires a value" >&2; exit 2; }; REPO="$2"; shift 2 ;;
    --channel) [[ $# -ge 2 ]] || { echo "--channel requires a value" >&2; exit 2; }; CHANNEL="$2"; shift 2 ;;
    --dist) [[ $# -ge 2 ]] || { echo "--dist requires a directory" >&2; exit 2; }; DIST="$2"; shift 2 ;;
    --root) [[ $# -ge 2 ]] || { echo "--root requires a directory" >&2; exit 2; }; ROOT="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || { echo "--out requires a file" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --published-at) [[ $# -ge 2 ]] || { echo "--published-at requires a timestamp" >&2; exit 2; }; PUBLISHED_AT="$2"; shift 2 ;;
    --attestation) [[ $# -ge 2 ]] || { echo "--attestation requires a mode" >&2; exit 2; }; ATTESTATION="$2"; shift 2 ;;
    --attestation-url) [[ $# -ge 2 ]] || { echo "--attestation-url requires a URL" >&2; exit 2; }; ATTESTATION_URL="$2"; shift 2 ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *) echo "Unexpected argument: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required but not found on PATH (see CONTRIBUTING.md)." >&2; exit 2; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

skill_version_of() {
  sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/SKILL.md" | head -n1
}

# ---------------------------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------------------------

read -r -d '' JQ_VALIDATE <<'JQ'
def ne: type == "string" and (length > 0);
def keycheck($allowed; $where):
  ( ((keys_unsorted - $allowed) | map("\($where) has an unexpected key: '\(.)'"))
  + (($allowed - keys_unsorted) | map("\($where) is missing required key: '\(.)'")) )[];

def top_allowed: ["assets","channel","commit","contents","generated_at","minimum_updater_schema","provenance","published_at","repository","schema_version","tag","version"];
def asset_allowed: ["name","role","sha256","size_bytes","url"];
def contents_allowed: ["companions","skill"];
def provenance_allowed: ["attestation","attestation_url","notes","signatures"];
def roles_allowed: ["checksums","stable-archive","versioned-archive"];
def channels_allowed: ["edge","stable"];
# Refs that move. A stable channel pinned to any of these is the exact failure this record exists to
# prevent: an updater would "upgrade" to whatever main happened to be at fetch time.
def mutable_refs: ["main","master","HEAD","head","latest","stable","edge","nightly"];
def isint: type == "number" and (. == floor);
def ts: ne and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");

. as $r
| ($r.tag // "") as $tag
| ($r.version // "") as $ver
| ($r.repository // "") as $repo
| [
    keycheck(top_allowed; "release record")

  , (if ($r.schema_version | isint | not) or ($r.schema_version != ($schema | tonumber))
     then "schema_version must be the integer \($schema); this validator cannot vouch for any other shape"
     else empty end)

  , (if ($repo | test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$") | not)
     then "repository must be 'owner/name', got '\($repo)'" else empty end)

  , (if (($r.channel // "") as $c | channels_allowed | index($c)) == null
     then "channel must be one of \(channels_allowed|join(", ")), got '\($r.channel // "")'" else empty end)

  , (if ($ver | test("^[0-9]+(\\.[0-9]+)+$") | not)
     then "version must look like X.Y, got '\($ver)'" else empty end)

  , (if $tag != "v\($ver)"
     then "tag/version mismatch: tag '\($tag)' must be 'v\($ver)'" else empty end)

  , (if (mutable_refs | index($tag)) != null
     then "tag '\($tag)' is a moving ref; a release record must name an immutable tag" else empty end)

  , (if (($r.commit // "") | test("^[0-9a-f]{40}$") | not)
     then "commit must be a full 40-hex sha (immutable), got '\($r.commit // "")'" else empty end)

  , (if ($r.generated_at | ts | not) then "generated_at must be an RFC 3339 UTC timestamp" else empty end)
  , (if ($r.published_at | ts | not) then "published_at must be an RFC 3339 UTC timestamp" else empty end)

  , (if ($r.minimum_updater_schema | isint | not) or ($r.minimum_updater_schema < 1)
       or ($r.minimum_updater_schema > ($schema | tonumber))
     then "minimum_updater_schema must be an integer in 1..\($schema)" else empty end)

  , (if ($r.contents | type) != "object" then "contents must be an object" else
      ( ($r.contents | keycheck(contents_allowed; "contents"))
      , (if ($r.contents.skill // "") != "SKILL.md" then "contents.skill must be 'SKILL.md'" else empty end)
      , (if ($r.contents.companions | type) != "array" then "contents.companions must be an array" else
          ( ($companions | split(",")) as $req
            | ( (($req - $r.contents.companions)
                 | map("contents.companions is missing the companion skill '\(.)'") | .[])
              , (($r.contents.companions - $req)
                 | map("contents.companions claims a companion skill this release does not ship: '\(.)'") | .[])
              # Exactly the required set, not merely a superset or a set with duplicates: the archive
              # ships three companions and the record must say three, no more and no fewer.
              , (if ($r.contents.companions | length) != ($req | length)
                 then "contents.companions must list exactly the \($req | length) required companion skills, got \($r.contents.companions | length)"
                 else empty end) ) ) end)
      ) end)

  , (if ($r.provenance | type) != "object" then "provenance must be an object" else
      ( ($r.provenance | keycheck(provenance_allowed; "provenance"))
      # Honest labelling is a hard requirement: SHA-256 is an integrity checksum, not a signature.
      # "none" is the only signature value this validator will vouch for, so nobody can claim
      # cryptographic signing by editing a string — adding signing means adding the machinery here.
      , (if ($r.provenance.signatures // "") != "none"
         then "provenance.signatures must be 'none' until real signing exists; SHA-256 is a checksum, not a signature"
         else empty end)
      , (if (["unavailable","github-artifact-attestation"] | index($r.provenance.attestation // "")) == null
         then "provenance.attestation must be 'unavailable' or 'github-artifact-attestation'" else empty end)
      , (if ($r.provenance.attestation // "") == "unavailable" and ($r.provenance.attestation_url != null)
         then "provenance.attestation_url must be null when no attestation is configured" else empty end)
      , (if ($r.provenance.attestation // "") == "github-artifact-attestation"
           and (($r.provenance.attestation_url // "") | test("^https://") | not)
         then "provenance.attestation_url must be an https URL when an attestation is claimed" else empty end)
      , (if ($r.provenance.notes | ne | not) then "provenance.notes must say what the integrity evidence actually is" else empty end)
      ) end)

  , (if ($r.assets | type) != "array" or ($r.assets | length) < 3 then "assets must be an array of at least 3 entries" else
      ( ( $r.assets[] as $a
          | ( ($a | keycheck(asset_allowed; "asset '\($a.name // "?")'"))
            , (if ($a.name | ne | not) then "an asset has an empty name" else empty end)
            , (if (roles_allowed | index($a.role // "")) == null
               then "asset '\($a.name // "?")' has unknown role '\($a.role // "")'" else empty end)
            , (if (($a.sha256 // "") | test("^[0-9a-f]{64}$") | not)
               then "asset '\($a.name // "?")' has a malformed sha256" else empty end)
            , (if ($a.size_bytes | isint | not) or ($a.size_bytes <= 0)
               then "asset '\($a.name // "?")' has a non-positive size_bytes" else empty end)
            # Every asset URL must be the per-tag immutable download path. The /releases/latest/
            # alias still exists for installers, but it must never appear IN the record.
            , (if ($a.url // "") != "https://github.com/\($repo)/releases/download/\($tag)/\($a.name // "")"
               then "asset '\($a.name // "?")' url must be the immutable tag download URL for \($tag)" else empty end)
            ) )
      , ( [ $r.assets[] | select(.role == "versioned-archive") ] as $v
          | if ($v | length) != 1 then "exactly one versioned-archive asset is required"
            elif ($v[0].name != "wgm-\($tag).tar.gz") then "the versioned archive must be named 'wgm-\($tag).tar.gz', got '\($v[0].name)'"
            else empty end )
      , ( [ $r.assets[] | select(.role == "stable-archive") ] as $s
          | if ($s | length) != 1 then "exactly one stable-archive asset is required"
            elif ($s[0].name != "wgm.tar.gz") then "the stable-named archive must be 'wgm.tar.gz', got '\($s[0].name)'"
            else empty end )
      , ( [ $r.assets[] | select(.role == "checksums") ] as $c
          | if ($c | length) != 1 then "exactly one checksums asset is required"
            elif ($c[0].name != "SHA256SUMS") then "the checksum file must be named 'SHA256SUMS', got '\($c[0].name)'"
            else empty end )
      # wgm.tar.gz is defined as a byte-identical copy of the versioned archive under a stable name.
      # If the two ever diverge, `WGM_REF=latest` and `WGM_REF=vX.Y` install DIFFERENT code from the
      # same release while every individual checksum still verifies — an integrity hole a per-asset
      # hash cannot see, so the record must state that they are the same bytes.
      , ( ( [ $r.assets[] | select(.role == "versioned-archive") ] | first ) as $v
          | ( [ $r.assets[] | select(.role == "stable-archive") ] | first ) as $s
          | if ($v == null) or ($s == null) then empty
            elif ($v.sha256 != $s.sha256)
              then "the stable archive must be a byte-identical copy of the versioned archive: sha256 \($s.sha256 // "?") != \($v.sha256 // "?")"
            elif ($v.size_bytes != $s.size_bytes)
              then "the stable archive must be a byte-identical copy of the versioned archive: size \($s.size_bytes // "?") != \($v.size_bytes // "?")"
            else empty end )
      ) end)

  , (if $expect_tag != "" and $tag != $expect_tag
     then "record tag '\($tag)' does not match the expected tag '\($expect_tag)'" else empty end)
  ]
| .[]
JQ

validate_record() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    note "release record '$file' is missing"
    return 1
  fi

  # Malformed JSON is RED before anything else: a record nobody can parse is worse than no record,
  # because an updater might half-parse it.
  if ! jq empty "$file" 2>/dev/null; then
    note "release record '$file' is not valid JSON"
    return 1
  fi
  if [[ "$(jq -r 'type' "$file")" != "object" ]]; then
    note "release record '$file' must be a JSON object"
    return 1
  fi

  local errors rc=0
  errors="$(jq -r \
    --arg schema "$SCHEMA_VERSION" \
    --arg companions "$(IFS=,; echo "${COMPANIONS[*]}")" \
    --arg expect_tag "$EXPECT_TAG" \
    "$JQ_VALIDATE" "$file" 2>&1)" || {
      note "release record '$file' could not be validated: $errors"
      return 1
    }

  if [[ -n "$errors" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && note "$line"
    done <<<"$errors"
    rc=1
  fi

  if [[ -n "$ASSETS_DIR" ]]; then
    verify_assets "$file" || rc=1
  fi

  return "$rc"
}

# Re-hash what the record claims. The record is written by the same job that built the archives, so
# the only way this diverges is a real bug (wrong file copied, archive rebuilt after hashing) — which
# is exactly the case that must not reach `gh release create`.
verify_assets() {
  local file="$1" rc=0 name expected size actual actual_size path
  while IFS=$'\t' read -r name expected size; do
    [[ -n "$name" ]] || continue
    path="$ASSETS_DIR/$name"
    if [[ ! -f "$path" ]]; then
      note "asset '$name' is named in the record but missing from $ASSETS_DIR"
      rc=1
      continue
    fi
    actual="$(sha256_of "$path")"
    if [[ "$actual" != "$expected" ]]; then
      note "asset '$name' hash mismatch: record says $expected, file is $actual"
      rc=1
    fi
    # Size is cheap, independent corroboration: a truncated upload or a swapped asset shows up here
    # even when the hash field was updated to match the wrong file.
    actual_size="$(wc -c < "$path" | tr -d ' ')"
    if [[ "$actual_size" != "$size" ]]; then
      note "asset '$name' size mismatch: record says ${size} bytes, file is ${actual_size}"
      rc=1
    fi
  done < <(jq -r '.assets[]? | [.name, .sha256, (.size_bytes | tostring)] | @tsv' "$file" 2>/dev/null)

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    verify_archive_contents "$ASSETS_DIR/$name" || rc=1
  done < <(jq -r '.assets[]? | select(.role == "versioned-archive" or .role == "stable-archive") | .name' "$file" 2>/dev/null)

  verify_stable_is_copy "$file" || rc=1
  verify_checksum_manifest "$file" || rc=1

  return "$rc"
}

# SHA256SUMS is the file a human actually runs their checksum tool against, and until it is PARSED it
# is just an opaque blob: its own hash and size can be perfectly correct while the lines inside name
# the wrong hashes, the wrong files, or a path outside the download directory. A verifier would then
# get a cheerful "OK" for bytes the release never vouched for. So every line is checked against both
# the record and the file on disk.
#
# Parsed by hand with sha256_of rather than shelling out to `sha256sum -c`: that flag set is GNU-only,
# and macOS ships `shasum` instead. Verification must not depend on which coreutils you have.
verify_checksum_manifest() {
  local file="$1" manifest_name manifest_path rc=0
  manifest_name="$(jq -r '[.assets[]? | select(.role == "checksums") | .name] | first // ""' "$file" 2>/dev/null)"
  [[ -n "$manifest_name" ]] || return 0
  manifest_path="$ASSETS_DIR/$manifest_name"
  # A missing manifest is already reported by the per-asset loop; don't double-report it.
  [[ -f "$manifest_path" ]] || return 0

  local -a want_names=() want_hashes=() seen=()
  local n h
  while IFS=$'\t' read -r n h; do
    [[ -n "$n" ]] || continue
    want_names+=("$n")
    want_hashes+=("$h")
  done < <(jq -r '.assets[]? | select(.role == "versioned-archive" or .role == "stable-archive") | [.name, .sha256] | @tsv' "$file" 2>/dev/null)

  local lineno=0 line hash name idx found expected actual
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    if [[ "$line" == *$'\r'* ]]; then
      note "$manifest_name line ${lineno} has a carriage return; the manifest must be LF-only"
      rc=1
      continue
    fi
    [[ -n "${line//[[:space:]]/}" ]] || { note "$manifest_name line ${lineno} is blank"; rc=1; continue; }

    # coreutils/shasum format: 64 hex digits, two spaces (or space + '*' for binary mode), then the name.
    if [[ ! "$line" =~ ^([0-9a-f]{64})\ [\ *](.+)$ ]]; then
      note "$manifest_name line ${lineno} is malformed: '${line}'"
      rc=1
      continue
    fi
    hash="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"

    # The manifest is consumed in whatever directory a user downloaded into, so a name with a path in
    # it — or a traversal — would point their checksum tool somewhere it was never meant to look.
    if [[ "$name" == */* || "$name" == ".."* || "$name" == -* ]]; then
      note "$manifest_name line ${lineno} names a path rather than a plain file: '${name}'"
      rc=1
      continue
    fi

    found=""
    for idx in "${!want_names[@]}"; do
      [[ "${want_names[$idx]}" == "$name" ]] && found="$idx"
    done
    if [[ -z "$found" ]]; then
      note "$manifest_name names '${name}', which is not an archive this release record covers"
      rc=1
      continue
    fi

    for idx in "${seen[@]:-}"; do
      [[ "$idx" == "$name" ]] && { note "$manifest_name lists '${name}' more than once"; rc=1; }
    done
    seen+=("$name")

    expected="${want_hashes[$found]}"
    if [[ "$hash" != "$expected" ]]; then
      note "$manifest_name gives '${name}' the hash ${hash}, but the release record says ${expected}"
      rc=1
      continue
    fi
    if [[ -f "$ASSETS_DIR/$name" ]]; then
      actual="$(sha256_of "$ASSETS_DIR/$name")"
      if [[ "$hash" != "$actual" ]]; then
        note "$manifest_name gives '${name}' the hash ${hash}, but the file is ${actual}"
        rc=1
      fi
    fi
  done < "$manifest_path"

  for idx in "${!want_names[@]}"; do
    name="${want_names[$idx]}"
    found=""
    for h in "${seen[@]:-}"; do
      [[ "$h" == "$name" ]] && found=1
    done
    [[ -n "$found" ]] || { note "$manifest_name does not cover '${name}', so a user verifying that archive gets no answer"; rc=1; }
  done

  return "$rc"
}

# The stable-named archive exists so `…/releases/latest/download/wgm.tar.gz` resolves. It is only
# safe if it is the SAME BYTES as the versioned archive; otherwise WGM_REF=latest and WGM_REF=vX.Y
# install different code from one release. Checked on the real files, not just on the record.
verify_stable_is_copy() {
  local file="$1" versioned stable vpath spath vsum ssum
  versioned="$(jq -r '[.assets[]? | select(.role == "versioned-archive") | .name] | first // ""' "$file" 2>/dev/null)"
  stable="$(jq -r '[.assets[]? | select(.role == "stable-archive") | .name] | first // ""' "$file" 2>/dev/null)"
  [[ -n "$versioned" && -n "$stable" ]] || return 0
  vpath="$ASSETS_DIR/$versioned"
  spath="$ASSETS_DIR/$stable"
  [[ -f "$vpath" && -f "$spath" ]] || return 0

  vsum="$(sha256_of "$vpath")"
  ssum="$(sha256_of "$spath")"
  if [[ "$vsum" != "$ssum" ]]; then
    note "'$stable' is not a byte-identical copy of '$versioned' (${ssum:0:12}… != ${vsum:0:12}…); WGM_REF=latest and WGM_REF=vX.Y would install different code"
    return 1
  fi
  if [[ "$(wc -c < "$vpath" | tr -d ' ')" != "$(wc -c < "$spath" | tr -d ' ')" ]]; then
    note "'$stable' and '$versioned' differ in size despite matching hashes"
    return 1
  fi
  return 0
}

# A release that omits SKILL.md, a companion, or the references/ tree is a broken install for every
# user who fetches it, and no checksum would notice — the archive would hash perfectly. So the
# contents are a gate too.
#
# The skill manifest must be at the ARCHIVE ROOT. A loose `SKILL.md` match would be satisfied by
# companions/teach-me/SKILL.md, so an archive containing only companions — no wgm at all — would pass.
verify_archive_contents() {
  local archive="$1" listing rc=0 c
  [[ -f "$archive" ]] || { note "archive '$archive' is missing"; return 1; }
  listing="$(tar -tzf "$archive" 2>/dev/null)" || { note "archive '$archive' is not a readable gzip tarball"; return 1; }

  if ! grep -qE '^(\./)?SKILL\.md$' <<<"$listing"; then
    note "archive '$(basename "$archive")' does not contain SKILL.md at its root"
    rc=1
  fi
  for c in "${COMPANIONS[@]}"; do
    if ! grep -qE "^(\./)?companions/${c}/SKILL\.md$" <<<"$listing"; then
      note "archive '$(basename "$archive")' does not contain the companion skill '$c'"
      rc=1
    fi
  done
  # SKILL.md is a router: it tells the agent to load references/*.md every iteration. An archive with
  # a manifest and no references/ installs cleanly and then dead-ends at the first load, so the
  # "complete skill tree" the release claims has to include them.
  if ! grep -qE '^(\./)?references/[^/]+\.md$' <<<"$listing"; then
    note "archive '$(basename "$archive")' does not contain the references/ tree that SKILL.md loads"
    rc=1
  fi
  return "$rc"
}

if [[ "$MODE" == "validate" ]]; then
  if validate_record "$RECORD"; then
    ok "release record '$RECORD' is valid (schema $SCHEMA_VERSION)"
    echo "release-index: GREEN"
    exit 0
  fi
  echo "release-index: RED" >&2
  exit 1
fi

# ---------------------------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------------------------

[[ -n "$TAG" ]] || { echo "--tag is required when building." >&2; exit 2; }
[[ -n "$COMMIT" ]] || { echo "--commit is required when building." >&2; exit 2; }
[[ -d "$DIST" ]] || { echo "--dist directory '$DIST' does not exist." >&2; exit 2; }
[[ -f "$ROOT/SKILL.md" ]] || { echo "--root '$ROOT' has no SKILL.md." >&2; exit 2; }

[[ -n "$OUT" ]] || OUT="$DIST/release.json"

if [[ -z "$PUBLISHED_AT" ]]; then
  if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
    PUBLISHED_AT="$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -r "${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"
  else
    PUBLISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
fi

VERSION="${TAG#v}"
SKILL_VERSION="$(skill_version_of "$ROOT")"
if [[ -z "$SKILL_VERSION" ]]; then
  note "could not read metadata.version from $ROOT/SKILL.md"
elif [[ "$SKILL_VERSION" != "$VERSION" ]]; then
  # Caught here as well as in the workflow's tag check, because this script is what a maintainer runs
  # by hand when reproducing a release locally.
  note "tag '$TAG' does not match SKILL.md version '$SKILL_VERSION'"
fi

for c in "${COMPANIONS[@]}"; do
  [[ -f "$ROOT/companions/$c/SKILL.md" ]] || note "companion skill '$c' is missing from $ROOT/companions"
done

VERSIONED="wgm-${TAG}.tar.gz"
STABLE="wgm.tar.gz"
SUMS="SHA256SUMS"

for a in "$VERSIONED" "$STABLE"; do
  [[ -f "$DIST/$a" ]] || note "expected archive '$a' is missing from $DIST"
done

if [[ "$FAIL" -ne 0 ]]; then
  echo "release-index: RED" >&2
  exit 1
fi

verify_archive_contents "$DIST/$VERSIONED" || FAIL=$((FAIL + 1))
verify_archive_contents "$DIST/$STABLE" || FAIL=$((FAIL + 1))

if [[ "$FAIL" -ne 0 ]]; then
  echo "release-index: RED" >&2
  exit 1
fi

# `sha256sum -c SHA256SUMS` must work for a user who downloads both archives into one directory, so
# the file holds bare names and the standard two-space format.
{
  printf '%s  %s\n' "$(sha256_of "$DIST/$VERSIONED")" "$VERSIONED"
  printf '%s  %s\n' "$(sha256_of "$DIST/$STABLE")" "$STABLE"
} > "$DIST/$SUMS"

if [[ "$ATTESTATION" == "github-artifact-attestation" && -z "$ATTESTATION_URL" ]]; then
  echo "--attestation github-artifact-attestation requires --attestation-url." >&2
  exit 2
fi

if [[ "$ATTESTATION" == "unavailable" ]]; then
  PROV_NOTES="SHA-256 checksums only. No build attestation and no cryptographic signatures are published for this release; verify with 'sha256sum -c SHA256SUMS'."
  PROV_URL_JSON="null"
else
  PROV_NOTES="GitHub artifact attestation published alongside SHA-256 checksums; verify with 'gh attestation verify' and 'sha256sum -c SHA256SUMS'."
  PROV_URL_JSON="$(jq -Rn --arg u "$ATTESTATION_URL" '$u')"
fi

asset_json() {
  local name="$1" role="$2"
  jq -n \
    --arg name "$name" \
    --arg role "$role" \
    --arg sha "$(sha256_of "$DIST/$name")" \
    --arg url "https://github.com/${REPO}/releases/download/${TAG}/${name}" \
    --argjson size "$(wc -c < "$DIST/$name" | tr -d ' ')" \
    '{name: $name, role: $role, sha256: $sha, size_bytes: $size, url: $url}'
}

ASSETS_JSON="$(jq -s '.' \
  <(asset_json "$VERSIONED" "versioned-archive") \
  <(asset_json "$STABLE" "stable-archive") \
  <(asset_json "$SUMS" "checksums"))"

COMPANIONS_JSON="$(printf '%s\n' "${COMPANIONS[@]}" | jq -R . | jq -s .)"

jq -n \
  --argjson schema "$SCHEMA_VERSION" \
  --argjson min_schema "$MIN_UPDATER_SCHEMA" \
  --arg repo "$REPO" \
  --arg channel "$CHANNEL" \
  --arg version "$VERSION" \
  --arg tag "$TAG" \
  --arg commit "$COMMIT" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg published_at "$PUBLISHED_AT" \
  --arg attestation "$ATTESTATION" \
  --argjson attestation_url "$PROV_URL_JSON" \
  --arg prov_notes "$PROV_NOTES" \
  --argjson assets "$ASSETS_JSON" \
  --argjson companions "$COMPANIONS_JSON" \
  '{
     schema_version: $schema,
     channel: $channel,
     repository: $repo,
     version: $version,
     tag: $tag,
     commit: $commit,
     published_at: $published_at,
     generated_at: $generated_at,
     minimum_updater_schema: $min_schema,
     assets: $assets,
     contents: { skill: "SKILL.md", companions: $companions },
     provenance: {
       attestation: $attestation,
       attestation_url: $attestation_url,
       signatures: "none",
       notes: $prov_notes
     }
   }' > "$OUT"

# Self-validate what we just wrote, with the archives re-hashed from disk. A generator that emits a
# record its own validator rejects must never reach the publish step.
ASSETS_DIR="$DIST"
EXPECT_TAG="$TAG"
if ! validate_record "$OUT"; then
  echo "release-index: RED" >&2
  exit 1
fi

ok "wrote $DIST/$SUMS"
ok "wrote $OUT (schema $SCHEMA_VERSION, channel $CHANNEL, $TAG @ ${COMMIT:0:9})"
echo "release-index: GREEN"
