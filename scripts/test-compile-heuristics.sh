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

# Only text that predates pins may go without one, so the fixture's older entry borrows the exact
# text of a real unpinned fragment from this repository.
LEGACY_SRC="$(grep -L '^pin: ' "$HERE"/../references/heuristics/*.md | grep -v '/README\.md$' | head -1)"
LEGACY_BODY="$(awk 'n == 2 { print; next } /^---$/ { n++ }' "$LEGACY_SRC"; printf x)"
LEGACY_BODY="${LEGACY_BODY%x}"

# frag <name> <section> <order> <pin or ""> <first line>: write one fragment into the fixture.
frag() {
  {
    printf -- '---\nsection: %s\norder: %s\n' "$2" "$3"
    if [ -n "$4" ]; then printf 'pin: %s\n' "$4"; fi
    printf -- '---\n- **Heuristic:** %s\n%b' "$5" "$ENTRY"
  } > "$T/r/references/heuristics/$1.md"
}

# A fresh fixture: two sections, one landing file, two pinned fragments, and one older entry.
mkroot() {
  rm -rf "$T/r"
  mkdir -p "$T/r/references/heuristics"
  printf '# Ledger\n\nHand-written header.\n\n## Alpha\n- **Heuristic:** stale.\n\n## Beta\n' \
    > "$T/r/references/heuristics.md"
  printf 'Some text with **A pinned rule.** inside.\n' > "$T/r/references/landing.md"
  printf -- '---\nsection: Alpha\norder: 1\n---\n%s' "$LEGACY_BODY" > "$T/r/references/heuristics/old-rule.md"
  frag new-rule Alpha 9 "$PIN" "new rule."
  frag beta-rule Beta 3 "$PIN" "beta rule."
}

run() { python3 "$TOOL" --root "$T/r" "$@" > "$T/out" 2>&1; }

# expect_lint_fail <label> <message fragment>: lint must exit exactly 1 and name the broken rule.
expect_lint_fail() {
  run --lint
  local rc=$?
  if [ "$rc" -ne 1 ]; then fail "$1: lint exited $rc, not 1"; return; fi
  if grep -qF -- "$2" "$T/out"; then ok "$1"; else fail "$1: no '$2' in: $(head -3 "$T/out")"; fi
}

if [ -z "$LEGACY_SRC" ] || [ -z "$LEGACY_BODY" ]; then
  fail "no unpinned fragment in the repository to borrow older-entry text from"
fi

# Compiling rewrites only the sections: the header stays byte-for-byte, and inside a section the
# highest order comes first, so a new lesson lands on top without anyone editing shared lines.
mkroot
expected="$(printf '# Ledger\n\nHand-written header.\n\n## Alpha\n- **Heuristic:** new rule.\n%b%s\n## Beta\n- **Heuristic:** beta rule.\n%bx' "$ENTRY" "$LEGACY_BODY" "$ENTRY")"
if run && [ "$(cat "$T/r/references/heuristics.md"; printf x)" = "$expected" ]; then
  ok "compile keeps the header and orders each section newest first"
else
  fail "compile output differs: $(head -3 "$T/out")"
fi

# --check is the release gate: green right after a compile, red as soon as a fragment changes.
if run --check; then ok "--check passes on a freshly compiled ledger"; else fail "--check failed after compile"; fi
sed -i 's/new rule/newer rule/' "$T/r/references/heuristics/new-rule.md"
run --check
rc=$?
if [ "$rc" -eq 1 ] && grep -q '^STALE:' "$T/out"; then
  ok "--check exits 1 and reports a stale ledger"
else
  fail "--check on an edited fragment exited $rc: $(head -3 "$T/out")"
fi

# A valid fixture lints clean and reports how many older entries still have no pin.
mkroot
if run --lint && grep -qF '3 fragments, 2 pinned, 1 older entries without a pin' "$T/out"; then
  ok "--lint passes and counts pinned fragments"
else
  fail "--lint on a valid fixture: $(head -3 "$T/out")"
fi

# The older-entry exemption follows the text, not the file name, and README.md is not a fragment.
mkroot; mv "$T/r/references/heuristics/old-rule.md" "$T/r/references/heuristics/renamed-rule.md"
printf '# Notes for humans\n' > "$T/r/references/heuristics/README.md"
if run --lint; then
  ok "a renamed older entry keeps its exemption and README.md is skipped"
else
  fail "rename or README.md: $(head -3 "$T/out")"
fi

# A pin into a landing file with CRLF line endings still resolves.
mkroot; printf 'Windows text with **A CRLF rule.** inside.\r\nMore.\r\n' > "$T/r/references/landing-crlf.md"
frag crlf-rule Beta 5 "references/landing-crlf.md :: **A CRLF rule.**" "crlf rule."
if run --lint; then ok "a pin into a CRLF landing file resolves"; else fail "CRLF pin: $(head -3 "$T/out")"; fi

# An indented '---' inside an entry is entry text, not front matter, and compiles verbatim.
mkroot; printf -- '---\nsection: Beta\norder: 5\npin: %s\n---\n- **Heuristic:** fence.\n  ---\n%b' "$PIN" "$ENTRY" \
  > "$T/r/references/heuristics/fence-rule.md"
if run && grep -qxF -- '  ---' "$T/r/references/heuristics.md"; then
  ok "an indented --- inside an entry compiles verbatim"
else
  fail "--- inside an entry: $(head -3 "$T/out")"
fi

# Each case below breaks one lint rule on a fresh, valid fixture and expects exit 1 with that
# rule's message.
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
expect_lint_fail "a new fragment without a pin fails" "add a pin"
mkroot; sed -i 's/^- \*\*Heuristic:\*\* /- **Heuristic:** reworded, /' "$T/r/references/heuristics/old-rule.md"
expect_lint_fail "a reworded older entry needs a pin" "add a pin"
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

# Only .md fragments and a README.md file belong in the directory; anything else fails, so a lesson
# cannot hide from the lint under another name or type.
mkroot; printf 'notes\n' > "$T/r/references/heuristics/notes.txt"
expect_lint_fail "a stray text file fails" "unexpected file"
mkroot; printf 'x' > "$T/r/references/heuristics/.DS_Store"
expect_lint_fail "a hidden file fails" "unexpected file"
mkroot; mkdir "$T/r/references/heuristics/drafts"
expect_lint_fail "a subdirectory fails" "unexpected file"
mkroot; mkdir "$T/r/references/heuristics/README.md"
expect_lint_fail "a README.md that is not a file fails" "unexpected file"

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
