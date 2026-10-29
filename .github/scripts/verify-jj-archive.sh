#!/usr/bin/env bash
# Verify the exact official Linux x86_64 jj archive CI installs; no network access is performed.
set -euo pipefail

EXPECTED="fce0271158e665ceb82dc66c5eb95b1728649094e9133074f3b5baece345fc08"
if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: bash .github/scripts/verify-jj-archive.sh ARCHIVE" >&2
  exit 2
fi
if command -v sha256sum >/dev/null 2>&1; then
  digest="$(sha256sum < "$1")"
elif command -v shasum >/dev/null 2>&1; then
  digest="$(shasum -a 256 < "$1")"
else
  echo "A SHA-256 tool (sha256sum or shasum) is required." >&2
  exit 2
fi
digest="${digest%% *}"
if [[ "$digest" != "$EXPECTED" ]]; then
  echo "jj v0.46.0 archive checksum mismatch; refusing to extract." >&2
  exit 1
fi
echo "jj v0.46.0 Linux x86_64 archive SHA-256 verified."
