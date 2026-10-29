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
mkdir -p "$TMP/home" "$TMP/repo"
export HOME="$TMP/home"
cd "$TMP/repo" || exit 2

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

# 4b) An attestation is a forward-only record, not a waiver. Pin the offending history locally
# (no remote publication) and prove the checker still names it after a compliant follow-up.
PUBLISHED_SHA="$(git rev-parse HEAD)"
PUBLISHED_MESSAGE="$(git show -s --format=%B "$PUBLISHED_SHA")"
git branch fixture-published "$PUBLISHED_SHA"
git commit -q --allow-empty -m "docs: attest trailer violation at ${PUBLISHED_SHA}${TRAILERS}"
run --base "$BASE_SHA" --trailer Co-authored-by --trailer Copilot-Session
if [[ "$RC" -eq 1 ]] && grep -qF "${PUBLISHED_SHA:0:9}" <<<"$OUT" \
   && grep -qF "forward-only correction/attestation" <<<"$OUT" \
   && grep -qF "blocked pending an explicit maintainer" <<<"$OUT" \
   && grep -qF "never automatically waived" <<<"$OUT" \
   && ! grep -qF "trailers: GREEN" <<<"$OUT" \
   && [[ "$(git rev-parse fixture-published)" == "$PUBLISHED_SHA" ]] \
   && [[ "$(git show -s --format=%B "$PUBLISHED_SHA")" == "$PUBLISHED_MESSAGE" ]] \
   && git merge-base --is-ancestor "$PUBLISHED_SHA" HEAD; then
  pass "forward-only attestation preserves the offending SHA and cannot waive the RED audit"
else
  fail "published-history handling changed or lost the original violation (rc=$RC): $OUT"
fi

# 5) A separately prepared compliant merge passes. Leave the offending history intact rather than
# resetting it: preventing a new violation is not repair of the pinned, already-published history.
git checkout -q -b compliant "$BASE_SHA"
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

# 7) Required keys are data, not regexes. Each isolated commit runs through the real checker
# via flags and both config sources so no input path can silently weaken the governance rule.
CASE=0
literal_case() {
  local expected="$1" key="$2" trailer="$3" description="$4" source marker
  CASE=$((CASE + 1))
  git checkout -q -b "literal-case-$CASE" "$BASE_SHA"
  printf 'test: literal key case %s\n\n%s\n' "$CASE" "$trailer" > "$TMP/message"
  # Verbatim keeps whitespace-only values in the commit, rather than testing Git's cleanup.
  git -c commit.cleanup=verbatim commit -q --allow-empty -F "$TMP/message"
  for source in flag local-config github-config; do
    rm -f .wgm/required-trailers .github/required-trailers
    case "$source" in
      flag)
        # Explicit flags must override even a conflicting local configuration.
        printf 'Unrelated-Key\n' > .wgm/required-trailers
        run --base "$BASE_SHA" --trailer "$key" ;;
      local-config)
        printf '%s\n' "$key" > .wgm/required-trailers
        mkdir -p .github
        printf 'Unrelated-Key\n' > .github/required-trailers
        run --base "$BASE_SHA" ;;
      github-config)
        mkdir -p .github
        printf '%s\n' "$key" > .github/required-trailers
        run --base "$BASE_SHA" ;;
    esac
    if [[ "$expected" -eq 0 ]]; then marker='trailers: GREEN'; else marker="missing trailer(s): $key"; fi
    if [[ "$RC" -eq "$expected" ]] && grep -qF "$marker" <<<"$OUT" \
       && { [[ "$expected" -eq 0 ]] || ! grep -qF 'trailers: GREEN' <<<"$OUT"; }; then
      pass "$description ($source)"
    else
      fail "$description ($source, expected=$expected, rc=$RC): $OUT"
    fi
  done
}

# Punctuation must not stand for another character, repetition, or an alternative spelling.
literal_case 1 'X.Build' 'X-Build: value' 'dotted key rejects hyphenated lookalike'
literal_case 1 'X.*' 'Xanything: value' 'regex-shaped key rejects wildcard lookalike'
literal_case 0 'X.Build' 'x.build: value' 'literal key matches case-insensitively'
literal_case 0 'X[Build]' 'x[build]: value' 'brackets are literal key text'
literal_case 0 'X+Build' 'x+build: value' 'plus is literal key text'
literal_case 0 'X(Ok)?{2}|Build^$*' 'x(ok)?{2}|build^$*: value' 'regex operators are literal key text'
# Backslashes must survive text-tool argument handling as well as pattern matching.
literal_case 0 'X\Build' 'x\build: value' 'backslash is literal key text'
literal_case 0 '-X.Build' '-x.build: value' 'leading hyphen is literal key text'

# Preserve exact column/separator and nonempty same-line value behavior, not full footer parsing.
literal_case 1 'X.Build' 'x.build:' 'empty value is rejected'
literal_case 1 'X.Build' $'x.build: \t\r' 'whitespace-only value is rejected'
literal_case 1 'X.Build' $'x.build:\n  value' 'next-line text cannot supply an empty value'
literal_case 1 'X.Build' ' x.build: value' 'indented key is rejected'
literal_case 1 'X.Build' 'prefix-x.build: value' 'embedded key is rejected'
literal_case 1 'X.Build' 'x.build.extra: value' 'longer key prefix is rejected'
literal_case 1 'X.Build' 'x.build value' 'missing colon is rejected'
literal_case 0 'X.Build' $'unrelated: value\nx.build: \tpassed' 'later matching line with a value is accepted'

# Repeatable flags must each be satisfied literally, even if another requested key matches.
rm -f .wgm/required-trailers .github/required-trailers
run --base "$BASE_SHA" --trailer X.Build --trailer X.Other
if [[ "$RC" -eq 1 ]] && grep -qF 'missing trailer(s): X.Other' <<<"$OUT"; then
  pass 'repeatable required keys cannot be satisfied by one matching key'
else
  fail "a matching key hid another missing required key (rc=$RC): $OUT"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "check-trailers harness: GREEN"
  exit 0
else
  echo "check-trailers harness: RED" >&2
  exit 1
fi
