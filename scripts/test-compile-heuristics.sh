#!/usr/bin/env bash
#
# wgm/test-compile-heuristics.sh — behavior checks for scripts/compile_heuristics.py.
#
# Builds a throwaway ledger with fragments, then checks the compile order, the stale check, and
# each lint rule. Prints ok:/FAIL: lines and exits nonzero if any assertion fails.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/compile_heuristics.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAILS=0
ok()   { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAILS=$((FAILS + 1)); }

ENTRY='  **Why:** w. **Provenance:** p. **Landed in:** l.\n'
PIN='references/landing.md :: **A pinned rule.**'

# frag <name> <section> <order> <pin or ""> <first line>: write one fragment into the fixture.
frag() {
  {
    printf -- '---\nsection: %s\norder: %s\n' "$2" "$3"
    if [ -n "$4" ]; then printf 'pin: %s\n' "$4"; fi
    printf -- '---\n- **Heuristic:** %s\n%b' "$5" "$ENTRY"
  } > "$T/r/references/heuristics/$1.md"
}

# A fresh fixture: two sections, one landing file, and three valid fragments (one unpinned).
mkroot() {
  rm -rf "$T/r"
  mkdir -p "$T/r/references/heuristics"
  printf '# Ledger\n\nHand-written header.\n\n## Alpha\n- **Heuristic:** stale.\n\n## Beta\n' \
    > "$T/r/references/heuristics.md"
  printf 'Some text with **A pinned rule.** inside.\n' > "$T/r/references/landing.md"
  printf '1\n' > "$T/r/references/heuristics/UNPINNED_CEILING"
  frag old-rule Alpha 1 "" "old rule."
  frag new-rule Alpha 9 "$PIN" "new rule."
  frag beta-rule Beta 3 "$PIN" "beta rule."
}

run() { python3 "$TOOL" --root "$T/r" "$@" > "$T/out" 2>&1; }

# expect_lint_fail <label> <message fragment>: lint must exit 1 and name the broken rule.
expect_lint_fail() {
  if run --lint; then fail "$1: lint passed"; return; fi
  if grep -qF -- "$2" "$T/out"; then ok "$1"; else fail "$1: no '$2' in: $(head -3 "$T/out")"; fi
}

# Compiling rewrites only the sections: the header stays byte-for-byte, and inside a section the
# highest order comes first, so a new lesson lands on top without anyone editing shared lines.
mkroot
expected="$(printf '# Ledger\n\nHand-written header.\n\n## Alpha\n- **Heuristic:** new rule.\n%b- **Heuristic:** old rule.\n%b\n## Beta\n- **Heuristic:** beta rule.\n%bx' "$ENTRY" "$ENTRY" "$ENTRY")"
if run && [ "$(cat "$T/r/references/heuristics.md"; printf x)" = "$expected" ]; then
  ok "compile keeps the header and orders each section newest first"
else
  fail "compile output differs: $(head -3 "$T/out")"
fi

# --check is the release gate: green right after a compile, red as soon as a fragment changes.
if run --check; then ok "--check passes on a freshly compiled ledger"; else fail "--check failed after compile"; fi
sed -i 's/old rule/older rule/' "$T/r/references/heuristics/old-rule.md"
if run --check; then
  fail "--check missed an edited fragment"
elif grep -q '^STALE:' "$T/out"; then
  ok "--check reports a stale ledger"
else
  fail "--check failed without saying STALE"
fi

# A valid fixture lints clean and reports its pin counts, so the ceiling stays visible.
mkroot
if run --lint && grep -qF '3 fragments, 2 pinned, 1 unpinned (ceiling 1)' "$T/out"; then
  ok "--lint passes and counts pinned fragments"
else
  fail "--lint on a valid fixture: $(head -3 "$T/out")"
fi

# A ceiling above the unpinned count is reported, so it is lowered as legacy entries get pins.
printf '5\n' > "$T/r/references/heuristics/UNPINNED_CEILING"
if run --lint && grep -qF 'lower references/heuristics/UNPINNED_CEILING to 1' "$T/out"; then
  ok "--lint asks to lower a loose ceiling"
else
  fail "no ratchet hint: $(head -3 "$T/out")"
fi

# Each lint rule below fails closed; every case starts from a fresh, valid fixture.
mkroot; frag gamma-rule Gamma 2 "$PIN" "gamma rule."
expect_lint_fail "unknown section fails" "is not a '## ' heading"
mkroot; frag bad-order Alpha soon "$PIN" "bad order."
expect_lint_fail "non-numeric order fails" "order must be a whole number"
mkroot; frag lost-pin Alpha 4 "references/landing.md :: **Not in the file.**" "lost pin."
expect_lint_fail "a pin whose phrase is gone fails" "pinned phrase is missing"
mkroot; frag no-file Alpha 4 "references/gone.md :: **A pinned rule.**" "no file."
expect_lint_fail "a pin to a missing file fails" "does not exist"
mkroot; frag escape Alpha 4 "../outside.md :: **A pinned rule.**" "escape."
expect_lint_fail "a pin outside the repository fails" "pin must be"
mkroot; frag Upper-Case Alpha 4 "$PIN" "bad name."
expect_lint_fail "a non-kebab file name fails" "kebab-case"
mkroot; frag new-unpinned Alpha 4 "" "unpinned."
expect_lint_fail "an unpinned new fragment above the ceiling fails" "above the ceiling"
mkroot; cp "$T/r/references/heuristics/beta-rule.md" "$T/r/references/heuristics/beta-copy.md"
expect_lint_fail "a duplicated entry fails" "already exists"
mkroot; printf -- '---\nsection: Alpha\norder: 4\npin: %s\n---\n- **Heuristic:** no why.\n  **Provenance:** p. **Landed in:** l.\n' "$PIN" \
  > "$T/r/references/heuristics/no-why.md"
expect_lint_fail "an entry without a Why fails" "missing **Why:**"
mkroot; printf -- '---\nsection: Alpha\norder: 4\npin: %s\n---\n- **Heuristic:** gap.\n\n%b' "$PIN" "$ENTRY" \
  > "$T/r/references/heuristics/gap.md"
expect_lint_fail "a blank line inside an entry fails" "no blank lines"
mkroot; printf -- 'section: Alpha\n- **Heuristic:** bare.\n' > "$T/r/references/heuristics/bare.md"
expect_lint_fail "a fragment without front matter fails" "front matter"

# The repository's own fragments must lint clean, so make test catches a broken pin too.
if python3 "$TOOL" --lint > "$T/out" 2>&1; then
  ok "the repository's fragments lint clean"
else
  fail "repository fragments: $(head -3 "$T/out")"
fi

if (( FAILS == 0 )); then
  echo "heuristics-compile: GREEN"
else
  echo "heuristics-compile: RED ($FAILS failure(s))" >&2
  exit 1
fi
