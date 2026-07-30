#!/usr/bin/env bash
#
# wgm/test-check-doc-sync.sh — deterministic backpressure for scripts/check-doc-sync.sh.
#
# The gate only earns its place if it distinguishes three cases: new public surface WITHOUT a doc
# touch (red), new public surface WITH one (green), and a diff with no new surface at all (green,
# and quiet — a gate that fires on every diff gets ignored, which is the same as not existing).
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-doc-sync.sh"

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
mkdir -p scripts docs
printf '# readme\n' > README.md
printf '#!/usr/bin/env bash\necho hi\n' > scripts/tool.sh
printf '# docs\n' > docs/README.md
git add -A && git commit -q -m seed

OUT=""; RC=0
run() { set +e; OUT="$("$CHECK" "$@" 2>&1)"; RC=$?; set -e; }

# 1) a diff that adds a new CLI flag but touches no documentation is caught
cat >> scripts/tool.sh <<'EOF'
case "$1" in
  --verbose) VERBOSE=1 ;;
esac
EOF
git add -A && git commit -q -m "feat: add a flag"
run --base HEAD~1
if [[ "$RC" -ne 0 ]] && grep -q "new CLI flag: --verbose" <<<"$OUT" && grep -q "no doc file touched" <<<"$OUT"; then
  pass "a new CLI flag with no doc touch fails the gate"
else
  fail "undocumented CLI flag was not caught (rc=$RC): $OUT"
fi

# 2) --warn downgrades the same diff to advisory (the Record-step default)
run --base HEAD~1 --warn
if [[ "$RC" -eq 0 ]] && grep -q "doc-sync: WARN" <<<"$OUT"; then
  pass "--warn reports the same finding advisorily and exits 0"
else
  fail "--warn did not downgrade the failure (rc=$RC): $OUT"
fi

# 3) the same surface WITH a documentation touch passes
cat >> scripts/tool.sh <<'EOF'
  --quiet) QUIET=1 ;;
EOF
printf 'documents --quiet\n' >> docs/README.md
git add -A && git commit -q -m "feat: add a documented flag"
run --base HEAD~1
if [[ "$RC" -eq 0 ]] && grep -q "documentation was touched" <<<"$OUT"; then
  pass "new public surface accompanied by a doc touch passes"
else
  fail "documented surface was wrongly failed (rc=$RC): $OUT"
fi

# 4) a diff with no new public surface is quiet and green — no crying wolf on ordinary edits
printf 'echo more\n' >> scripts/tool.sh
git add -A && git commit -q -m "chore: internal tweak"
run --base HEAD~1
if [[ "$RC" -eq 0 ]] && grep -q "no new public surface" <<<"$OUT"; then
  pass "an ordinary diff with no new surface passes quietly"
else
  fail "the gate fired on a diff with no new public surface (rc=$RC): $OUT"
fi

# 5) a brand-new config file counts as public surface
printf 'setting: 1\n' > newconfig.yml
git add -A && git commit -q -m "feat: add config"
run --base HEAD~1
if [[ "$RC" -ne 0 ]] && grep -q "new file: newconfig.yml" <<<"$OUT"; then
  pass "a new config file counts as public surface"
else
  fail "a new config file was not treated as public surface (rc=$RC): $OUT"
fi

# 6) --base HEAD inspects the UNCOMMITTED working tree, including untracked files.
#    This is the published example, and it silently reported "no changes" before being fixed:
#    `git diff BASE HEAD` with BASE=HEAD is always empty, so the gate passed on everything.
printf 'setting: 2\n' > uncommitted.yml
run --base HEAD
if [[ "$RC" -ne 0 ]] && grep -q "new file: uncommitted.yml" <<<"$OUT"; then
  pass "--base HEAD inspects the working tree, untracked files included"
else
  fail "--base HEAD did not inspect the working tree (rc=$RC): $OUT"
fi
rm -f uncommitted.yml

if [[ "$FAILED" -eq 0 ]]; then
  echo "check-doc-sync harness: GREEN"
  exit 0
else
  echo "check-doc-sync harness: RED" >&2
  exit 1
fi
