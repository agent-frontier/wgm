#!/usr/bin/env bash
#
# wgm/test-check-trailers.sh — deterministic backpressure for scripts/check-trailers.sh.
#
# The defect this gate exists for is narrow and easy to regress: every head commit carries the
# required trailers, then a GENERATED merge commit (the merge button, `gh pr merge --merge`) is
# created with none — and the product gates, being green, say nothing ([learn] issue #82). So the
# harness builds exactly that history in a throwaway repo and proves the audit catches it.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-trailers.sh"

FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

TMP="$(mktemp -d)"
trap 'cd /; rm -rf "$TMP"' EXIT
cd "$TMP" || exit 2

git init -q
git config user.email "wgm-test@example.com"
git config user.name "wgm test"
git config commit.gpgsign false

TRAILERS=$'\n\nCo-authored-by: Someone <s@example.com>\nCopilot-Session: test-session'

printf 'seed\n' > f.txt
git add -A && git commit -q -m "chore: seed${TRAILERS}"
git branch -M main
BASE_SHA="$(git rev-parse HEAD)"

OUT=""; RC=0
run() { set +e; OUT="$("$CHECK" "$@" 2>&1)"; RC=$?; set -e; }

# 1) with nothing mandated the audit is an explicit no-op, not a silent pass
run --base main
if [[ "$RC" -eq 0 ]] && grep -q "no required trailers configured" <<<"$OUT"; then
  pass "no configured trailers is an explicit no-op"
else
  fail "unconfigured run did not report a no-op (rc=$RC): $OUT"
fi

# 2) a compliant feature branch passes
git checkout -q -b feature
printf 'work\n' >> f.txt
git add -A && git commit -q -m "feat: do the work${TRAILERS}"
run --base main --trailer Co-authored-by --trailer Copilot-Session
if [[ "$RC" -eq 0 ]] && grep -q "trailers: GREEN" <<<"$OUT"; then
  pass "a branch whose commits all carry the trailers passes"
else
  fail "compliant branch failed the audit (rc=$RC): $OUT"
fi

# 3) a commit missing a trailer fails, and is named
printf 'more\n' >> f.txt
git add -A && git commit -q -m "feat: untrailered work"
run --base main --trailer Co-authored-by --trailer Copilot-Session
if [[ "$RC" -ne 0 ]] && grep -q "untrailered work" <<<"$OUT" && grep -q "Co-authored-by" <<<"$OUT"; then
  pass "a commit missing required trailers is named and fails the audit"
else
  fail "a missing trailer was not caught (rc=$RC): $OUT"
fi

# 4) the real defect: every head commit is compliant, but the GENERATED merge commit is not.
git checkout -q main
git checkout -q -b topic "$BASE_SHA"
printf 'topic\n' > t.txt
git add -A && git commit -q -m "feat: topic work${TRAILERS}"
git checkout -q main
# --no-ff with a bare -m is exactly what a merge button produces: no trailer block.
git merge -q --no-ff -m "Merge pull request #1 from topic" topic
run --base "$BASE_SHA" --trailer Co-authored-by --trailer Copilot-Session
if [[ "$RC" -ne 0 ]] \
   && grep -q "merge commit" <<<"$OUT" \
   && grep -q "Merge pull request #1" <<<"$OUT"; then
  pass "a generated merge commit without trailers is caught even when every head commit complies"
else
  fail "the generated merge commit escaped the audit (rc=$RC): $OUT"
fi

# 5) the same merge WITH the trailers passes — proving (4) failed on the trailers, not on being a merge
git reset -q --hard "$BASE_SHA"
git merge -q --no-ff -m "Merge pull request #1 from topic${TRAILERS}" topic
run --base "$BASE_SHA" --trailer Co-authored-by --trailer Copilot-Session
if [[ "$RC" -eq 0 ]] && grep -q "1 merge" <<<"$OUT"; then
  pass "a merge commit carrying the trailers passes, and is counted as a merge"
else
  fail "a compliant merge commit was rejected (rc=$RC): $OUT"
fi

# 6) required trailers can come from the config file instead of flags
printf '# governed trailers\nCo-authored-by\nCopilot-Session\n' > .wgm-required
mkdir -p .wgm && mv .wgm-required .wgm/required-trailers
run --base "$BASE_SHA"
if [[ "$RC" -eq 0 ]] && grep -q "Co-authored-by Copilot-Session" <<<"$OUT"; then
  pass "required trailers are read from .wgm/required-trailers"
else
  fail "config-file trailers were not honoured (rc=$RC): $OUT"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "check-trailers harness: GREEN"
  exit 0
else
  echo "check-trailers harness: RED" >&2
  exit 1
fi
