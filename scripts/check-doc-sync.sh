#!/usr/bin/env bash
#
# wgm/check-doc-sync.sh — per-iteration backpressure against silent documentation drift.
#
# The Loop's Record step commits a task once its own validation command exits 0, and no product gate
# asks whether a NEW PUBLIC SURFACE introduced by that diff was documented. The docs-audit swarm is
# the only thing that catches it, and it runs at Ship/Handoff — so drift accumulates across several
# merged PRs before anyone notices, and the fix cost scales with how many piled up ([learn] #78).
#
# This turns "a batch audit eventually catches it" into "the loop catches it same-iteration" by
# checking one diff: if it ADDS public surface but touches no documentation path, say so.
#
# Public surface detected (added lines only):
#   * a new CLI flag/subcommand   — a new `--flag)` case arm or `--flag` help line in scripts/
#   * a new shell function        — `name() {` at column 0 in scripts/
#   * a new script or config file — an added scripts/*.sh, *.yml, *.yaml, *.toml, *.json path
#
# Usage:
#   scripts/check-doc-sync.sh [--base REF] [--warn] [--doc-path GLOB]...
#
# Flags:
#   --base REF       diff REF..HEAD (default: HEAD~1..HEAD). Pass --base HEAD to inspect the
#                    uncommitted working tree instead, untracked files included. REF must resolve
#                    to a commit; any ref resolving to HEAD selects worktree inspection.
#                    With no parent commit, the default also inspects the working tree.
#   --warn           make findings advisory (exit 0); invalid input / Git failures still exit 2
#   --doc-path GLOB  extra path prefix that counts as documentation; repeatable
#   -h | --help      show this help
#
# Doc paths by default: docs/, references/, README.md, SKILL.md, companions/**/SKILL.md, CONTRIBUTING.md.
#
# Exit 0 = successful inspection with no finding (or --warn). Exit 1 = undocumented new surface.
# Exit 2 = invalid input or failed inspection; never GREEN, even with --warn.

set -uo pipefail

BASE=""
WARN=0
EXTRA_DOCS=()

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }
inspection_error() { printf 'doc-sync: ERROR: %s\n' "$*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --base) [[ $# -ge 2 && -n "$2" ]] || inspection_error "--base requires a non-empty commit ref."; BASE="$2"; shift 2 ;;
    --warn) WARN=1; shift ;;
    --doc-path) [[ $# -ge 2 ]] || { echo "--doc-path requires a glob" >&2; exit 2; }; EXTRA_DOCS+=("$2"); shift 2 ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *) echo "Unexpected argument: $1" >&2; exit 2 ;;
  esac
done

INSIDE_WORKTREE="$(git rev-parse --is-inside-work-tree)" \
  || inspection_error "git rev-parse --is-inside-work-tree failed; run inside a Git worktree."
[[ "$INSIDE_WORKTREE" == true ]] \
  || inspection_error "git rev-parse --is-inside-work-tree did not find a worktree; run inside one."
# Keep diff paths, tree listings, untracked enumeration, and file reads in one coordinate system.
# Merely making ls-tree root-relative would leave untracked paths/reads dependent on the caller.
WORKTREE_ROOT="$(git rev-parse --show-toplevel)" \
  || inspection_error "git rev-parse --show-toplevel failed; check the Git worktree and retry."
cd "$WORKTREE_ROOT" \
  || inspection_error "could not enter Git worktree '$WORKTREE_ROOT'; check access and retry."
HEAD_COMMIT="$(git rev-parse --verify --end-of-options 'HEAD^{commit}')" \
  || inspection_error "git rev-parse failed to resolve HEAD to a commit; check the repository's HEAD."

if [[ -n "$BASE" ]]; then
  BASE_COMMIT="$(git rev-parse --verify --end-of-options "${BASE}^{commit}")" \
    || inspection_error "git rev-parse failed for --base '$BASE'; supply a ref resolving to a commit."
else
  # A failed parent lookup is not evidence of a root commit. Only a successful query may select
  # that fallback; use the first parent to preserve the default HEAD~1 comparison on merges.
  PARENTS="$(git rev-list --parents -n 1 "$HEAD_COMMIT")" \
    || inspection_error "git rev-list failed to inspect HEAD's parents; check the repository history."
  read -r -a COMMITS <<< "$PARENTS"
  BASE_COMMIT="${COMMITS[1]:-$HEAD_COMMIT}"
fi

# `--base HEAD` (and the no-parent-commit case) means "inspect the working tree", not "diff HEAD
# against itself" — the latter is always empty and would make the gate silently pass on every
# uncommitted change. Untracked files count too: a brand-new script IS new public surface.
compare_worktree=0
DIFF_REFS=("$BASE_COMMIT")
if [[ "$BASE_COMMIT" == "$HEAD_COMMIT" ]]; then
  compare_worktree=1
else
  DIFF_REFS+=("$HEAD_COMMIT")
fi

# Check Git's status before filtering added lines: no matches is normal, a failed diff is not.
# Resolved commit IDs plus -- also prevent refs from being interpreted as options or paths.
CHANGED="$(git diff --name-only "${DIFF_REFS[@]}" --)" \
  || inspection_error "git diff --name-only failed for ${DIFF_REFS[*]}; fix the comparison and retry."
PATCH="$(git diff --unified=0 "${DIFF_REFS[@]}" --)" \
  || inspection_error "git diff --unified=0 failed for ${DIFF_REFS[*]}; fix the comparison and retry."
ADDED="$(sed -n '/^+++/d; /^+/p' <<< "$PATCH")"
if [[ "$compare_worktree" -eq 1 ]]; then
  UNTRACKED="$(git ls-files --others --exclude-standard)" \
    || inspection_error "git ls-files --others --exclude-standard failed; check the worktree and retry."
  CHANGED+=$'\n'"$UNTRACKED"
  while IFS= read -r u; do
    [[ -n "$u" && -f "$u" ]] || continue
    ADDED+=$'\n'"$(sed 's/^/+/' "$u")" \
      || inspection_error "could not read untracked file '$u'; check the file and retry."
  done <<< "$UNTRACKED"
fi

if [[ -z "${CHANGED//[[:space:]]/}" ]]; then
  echo "doc-sync: no changes to inspect."
  echo "doc-sync: GREEN"
  exit 0
fi

is_doc_path() {
  case "$1" in
    docs/*|references/*|README.md|SKILL.md|CONTRIBUTING.md|companions/*/SKILL.md) return 0 ;;
  esac
  local g
  for g in ${EXTRA_DOCS[@]+"${EXTRA_DOCS[@]}"}; do
    # shellcheck disable=SC2053  # glob match is intentional here.
    [[ "$1" == $g ]] && return 0
  done
  return 1
}

DOC_TOUCHED=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if is_doc_path "$f"; then DOC_TOUCHED=1; fi
done <<< "$CHANGED"

SURFACE=()

# New CLI flags: a case arm like `--foo)` or a help line documenting `--foo`, added under scripts/.
while IFS= read -r flag; do
  [[ -n "$flag" ]] && SURFACE+=("new CLI flag: $flag")
done < <(printf '%s\n' "$ADDED" | grep -oE '^\+[[:space:]]*(#[[:space:]]+)?(--[a-z][a-z0-9-]+)' \
  | grep -oE '\-\-[a-z][a-z0-9-]+' | sort -u)

# New shell functions declared at column 0.
while IFS= read -r fn; do
  [[ -n "$fn" ]] && SURFACE+=("new function: $fn")
done < <(printf '%s\n' "$ADDED" | grep -oE '^\+[a-z_][a-z0-9_]*\(\)' | sed 's/^+//; s/()//' | sort -u)

# A successful tree listing distinguishes absent files from Git errors. cat-file -e cannot: both
# an absent path and an inspection failure return nonzero, which used to become "new file".
BASE_FILES="$(git ls-tree -r --name-only "$BASE_COMMIT")" \
  || inspection_error "git ls-tree failed for base commit '$BASE_COMMIT'; check the repository and retry."
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  case "$f" in
    scripts/*.sh|scripts/*.ps1|*.yml|*.yaml|*.toml|*.json)
      grep -qFx -- "$f" <<< "$BASE_FILES" || SURFACE+=("new file: $f")
      ;;
  esac
done <<< "$CHANGED"

if [[ ${#SURFACE[@]} -eq 0 ]]; then
  echo "doc-sync: no new public surface in this diff."
  echo "doc-sync: GREEN"
  exit 0
fi

if [[ "$DOC_TOUCHED" -eq 1 ]]; then
  printf 'ok:   %s new public surface item(s) added, and documentation was touched.\n' "${#SURFACE[@]}"
  echo "doc-sync: GREEN"
  exit 0
fi

printf 'New public surface added, no doc file touched — confirm intentional or add a follow-up task:\n' >&2
for s in "${SURFACE[@]}"; do printf '  - %s\n' "$s" >&2; done

if [[ "$WARN" -eq 1 ]]; then
  echo "doc-sync: WARN (advisory; exit 0)" >&2
  exit 0
fi
echo "doc-sync: RED" >&2
exit 1
