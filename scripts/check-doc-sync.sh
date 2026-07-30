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
#                    uncommitted working tree instead, untracked files included.
#   --warn           report and exit 0 (advisory) instead of failing — the Record-step default
#   --doc-path GLOB  extra path prefix that counts as documentation; repeatable
#   -h | --help      show this help
#
# Doc paths by default: docs/, references/, README.md, SKILL.md, companions/**/SKILL.md, CONTRIBUTING.md.
#
# Exit 0 = no undocumented public surface (or --warn). Exit 1 = new surface with no doc touch.

set -uo pipefail

BASE=""
WARN=0
EXTRA_DOCS=()

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --base) [[ $# -ge 2 ]] || { echo "--base requires a ref" >&2; exit 2; }; BASE="$2"; shift 2 ;;
    --warn) WARN=1; shift ;;
    --doc-path) [[ $# -ge 2 ]] || { echo "--doc-path requires a glob" >&2; exit 2; }; EXTRA_DOCS+=("$2"); shift 2 ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *) echo "Unexpected argument: $1" >&2; exit 2 ;;
  esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Not inside a git repository." >&2; exit 2; }

if [[ -z "$BASE" ]]; then
  if git rev-parse --verify --quiet HEAD~1 >/dev/null 2>&1; then BASE="HEAD~1"; else BASE=""; fi
fi

# `--base HEAD` (and the no-parent-commit case) means "inspect the working tree", not "diff HEAD
# against itself" — the latter is always empty and would make the gate silently pass on every
# uncommitted change. Untracked files count too: a brand-new script IS new public surface.
compare_worktree=0
if [[ -z "$BASE" ]]; then
  compare_worktree=1
elif [[ "$(git rev-parse --verify --quiet "$BASE" 2>/dev/null)" == "$(git rev-parse HEAD 2>/dev/null)" ]]; then
  compare_worktree=1
fi

if [[ "$compare_worktree" -eq 0 ]]; then
  CHANGED="$(git diff --name-only "$BASE" HEAD)"
  ADDED="$(git diff --unified=0 "$BASE" HEAD | grep '^+' | grep -v '^+++' || true)"
else
  BASE=""
  CHANGED="$(
    git diff --name-only HEAD 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
  )"
  ADDED="$(
    { git diff --unified=0 HEAD 2>/dev/null || true; } | grep '^+' | grep -v '^+++' || true
    while IFS= read -r u; do
      [[ -n "$u" && -f "$u" ]] && sed 's/^/+/' "$u"
    done < <(git ls-files --others --exclude-standard 2>/dev/null || true)
  )"
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

# New scripts / config files. Existence is checked against the base ref, or against HEAD in
# working-tree mode — otherwise an untracked new file is never recognised as new.
EXIST_REF="${BASE:-HEAD}"
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  case "$f" in
    scripts/*.sh|scripts/*.ps1|*.yml|*.yaml|*.toml|*.json)
      git cat-file -e "${EXIST_REF}:${f}" 2>/dev/null || SURFACE+=("new file: $f")
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
