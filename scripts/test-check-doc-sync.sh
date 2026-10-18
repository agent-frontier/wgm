#!/usr/bin/env bash
#
# wgm/test-check-doc-sync.sh — deterministic backpressure for scripts/check-doc-sync.sh.
#
# The gate only earns its place if it distinguishes three cases: new public surface WITHOUT a doc
# touch (red), new public surface WITH one (green), and a diff with no new surface at all (green,
# and quiet — a gate that fires on every diff gets ignored, which is the same as not existing).
# Failed Git inspection is an error, never a clean or advisory result.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-doc-sync.sh"

FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

TMP="$(mktemp -d)"
trap 'cd /; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo" "$TMP/home"
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
cd "$TMP/repo" || exit 2

OUT=""; RC=0
run() { if OUT="$("$CHECK" "$@" 2>&1)"; then RC=0; else RC=$?; fi; }
expect_error() {
  if [[ "$RC" -eq 2 ]] && grep -qF "doc-sync: ERROR:" <<<"$OUT" \
      && grep -qF -- "$2" <<<"$OUT" && ! grep -q "doc-sync: GREEN" <<<"$OUT"; then
    pass "$1"
  else
    fail "$1 (expected named error, exit 2, no GREEN; rc=$RC): $OUT"
  fi
}

# Missing repositories and unborn HEADs must not look like an empty, successful comparison.
for mode in strict warn; do
  args=(); [[ "$mode" != warn ]] || args+=(--warn)
  run "${args[@]}"
  expect_error "a non-repository is refused ($mode)" "git rev-parse"
done
git init -q
git config user.email "wgm-test@example.com"
git config user.name "wgm test"
git config commit.gpgsign false
for mode in strict warn; do
  args=(); [[ "$mode" != warn ]] || args+=(--warn)
  run "${args[@]}"
  expect_error "an unborn HEAD is refused ($mode)" "HEAD"
done
mkdir -p scripts docs
printf '# readme\n' > README.md
printf '#!/usr/bin/env bash\necho hi\n' > scripts/tool.sh
printf '# docs\n' > docs/README.md
git add -A && git commit -q -m seed

# A successful parent query with no parent is the default root-commit worktree case, not an error.
run
if [[ "$RC" -eq 0 ]] && grep -q "no changes to inspect" <<<"$OUT"; then
  pass "the default comparison accepts a clean root commit"
else
  fail "clean root-commit comparison failed (rc=$RC): $OUT"
fi

# git diff names paths from the root, while ls-tree defaults to the caller's directory. A harmless
# tracked comment must not become a "new file" merely because the gate is invoked from scripts/.
printf '# harmless tracked comment\n' >> scripts/tool.sh
for from in . scripts; do
  cd "$TMP/repo/$from"
  run --base HEAD
  if [[ "$RC" -eq 0 ]] && grep -q "no new public surface" <<<"$OUT"; then
    pass "an ordinary tracked edit stays green from $from"
  else
    fail "ordinary tracked edit changed verdict from $from (rc=$RC): $OUT"
  fi
done
cd "$TMP/repo"

printf 'setting: 1\n' > root-only.yml
run
if [[ "$RC" -eq 1 ]] && grep -q "new file: root-only.yml" <<<"$OUT"; then
  pass "the default root-commit comparison includes untracked files"
else
  fail "root-commit worktree inspection failed (rc=$RC): $OUT"
fi

# Path normalization must retain real new-file detection, enumerate outside the caller's
# subdirectory, and read untracked content using those same paths (the function proves the read).
printf 'untracked_parity_fn() { :; }\n' > scripts/parity.sh
for from in . scripts; do
  cd "$TMP/repo/$from"
  run --base HEAD
  if [[ "$RC" -eq 1 ]] && grep -q "new file: scripts/parity.sh" <<<"$OUT" \
      && grep -q "new file: root-only.yml" <<<"$OUT" \
      && grep -q "new function: untracked_parity_fn" <<<"$OUT"; then
    pass "untracked enumeration, file detection, and content reads agree from $from"
  else
    fail "untracked inspection used inconsistent paths from $from (rc=$RC): $OUT"
  fi
done
cd "$TMP/repo"
rm root-only.yml scripts/parity.sh

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
run
if [[ "$RC" -eq 1 ]] && grep -q "new CLI flag: --verbose" <<<"$OUT"; then
  pass "the default comparison uses HEAD's first parent"
else
  fail "default parent comparison failed (rc=$RC): $OUT"
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

# Commit-ish tags must be peeled before selecting committed versus worktree inspection.
git tag -a previous-commit HEAD~1 -m previous
run --base previous-commit
if [[ "$RC" -eq 1 ]] && grep -q "new file: newconfig.yml" <<<"$OUT"; then
  pass "an annotated tag to a previous commit compares committed changes"
else
  fail "annotated comparison base failed (rc=$RC): $OUT"
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
run --base HEAD --warn
if [[ "$RC" -eq 0 ]] && grep -q "doc-sync: WARN" <<<"$OUT"; then
  pass "valid worktree findings remain advisory with --warn"
else
  fail "worktree advisory mode failed (rc=$RC): $OUT"
fi
git tag -a current-commit -m current
for ref in "$(git rev-parse HEAD)" current-commit; do
  run --base "$ref"
  if [[ "$RC" -eq 1 ]] && grep -q "new file: uncommitted.yml" <<<"$OUT"; then
    pass "a base resolving to current HEAD includes untracked files ($ref)"
  else
    fail "current-HEAD alias ignored the worktree ($ref, rc=$RC): $OUT"
  fi
done
rm -f uncommitted.yml

# Staged and unstaged tracked additions must both remain visible in worktree mode.
printf 'staged_fn() { :; }\n' >> scripts/tool.sh
git add scripts/tool.sh
printf 'unstaged_fn() { :; }\n' >> scripts/tool.sh
run --base HEAD
if [[ "$RC" -eq 1 ]] && grep -q "new function: staged_fn" <<<"$OUT" \
    && grep -q "new function: unstaged_fn" <<<"$OUT"; then
  pass "worktree inspection includes staged and unstaged tracked changes"
else
  fail "tracked worktree additions were missed (rc=$RC): $OUT"
fi

# Reject missing, option-like, empty, tree, and blob inputs before examining any diff.
for mode in strict warn; do
  args=(); [[ "$mode" != warn ]] || args+=(--warn)
  for ref in definitely-not-a-ref --all '' 'HEAD^{tree}' HEAD:README.md; do
    run --base "$ref" "${args[@]}"
    expect_error "invalid/non-commit base is refused ('$ref', $mode)" "--base"
    if [[ -n "$ref" ]] && ! grep -qF -- "$ref" <<<"$OUT"; then
      fail "base error did not identify '$ref': $OUT"
    fi
  done
done

# Inject nonzero Git exits (with partial stdout) independently of ref validity. A trailing grep,
# --warn, or a mistaken "file absent" interpretation must not hide a failed inspection operation.
run_git_failure() {
  local operation="$1" argument="$2"; shift 2
  if OUT="$(
    # shellcheck disable=SC2317,SC2329  # Exported for the gate's child Bash, not called in this subshell.
    git() {
      if [[ "$1" == "$FAIL_GIT_OPERATION" && ( -z "$FAIL_GIT_ARGUMENT" || "${2:-}" == "$FAIL_GIT_ARGUMENT" ) ]]; then
        printf 'README.md\n'
        printf 'fixture: forced Git inspection failure\n' >&2
        return 97
      fi
      command git "$@"
    }
    export -f git
    export FAIL_GIT_OPERATION="$operation" FAIL_GIT_ARGUMENT="$argument"
    "$CHECK" "$@" 2>&1
  )"; then RC=0; else RC=$?; fi
}
for mode in strict warn; do
  args=(); [[ "$mode" != warn ]] || args+=(--warn)
  for base in HEAD~1 HEAD; do
    for inspection in diff:--name-only diff:--unified=0 ls-tree:; do
      operation="${inspection%%:*}"; argument="${inspection#*:}"
      run_git_failure "$operation" "$argument" --base "$base" "${args[@]}"
      expect_error "failed git $operation $argument is refused ($base, $mode)" "git $operation"
    done
  done
  run_git_failure ls-files '' --base HEAD "${args[@]}"
  expect_error "failed untracked enumeration is refused ($mode)" "git ls-files"
  run_git_failure rev-list '' "${args[@]}"
  expect_error "failed default-parent inspection is refused ($mode)" "git rev-list"
  run_git_failure rev-parse --verify --base HEAD "${args[@]}"
  expect_error "failed HEAD resolution is refused ($mode)" "HEAD"
  run_git_failure rev-parse --show-toplevel --base HEAD "${args[@]}"
  expect_error "failed worktree-root discovery is refused ($mode)" "git rev-parse --show-toplevel"
done

if [[ "$FAILED" -eq 0 ]]; then
  echo "check-doc-sync harness: GREEN"
  exit 0
else
  echo "check-doc-sync harness: RED" >&2
  exit 1
fi
