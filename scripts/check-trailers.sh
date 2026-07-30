#!/usr/bin/env bash
#
# wgm/check-trailers.sh — deterministic backpressure for commit-message governance.
#
# Deterministic PRODUCT gates (tests, lint, build, holdouts) cannot see commit-message policy, so a
# run can reach a fully green exact-tree gate and still ship a non-compliant history. The classic
# way this happens is a GENERATED merge commit: every head commit carries the required trailers,
# then `gh pr merge --merge` synthesises a merge commit with none of them ([learn] issue #82).
#
# This audits EVERY commit introduced on the current branch — merge commits explicitly included —
# for the trailers the repository mandates.
#
# Usage:
#   scripts/check-trailers.sh [--base REF] [--trailer NAME]... [--allow-empty]
#
# Flags:
#   --base REF      audit REF..HEAD (default: origin/HEAD, else origin/main, else main)
#   --trailer NAME  a required trailer key; repeatable. Overrides the config file.
#   --allow-empty   exit 0 when no trailers are mandated (default: exit 0 with a notice anyway)
#   -h | --help     show this help
#
# Config: when no --trailer is given, required keys are read one-per-line from the first of
#   .wgm/required-trailers  |  .github/required-trailers
# (blank lines and # comments ignored). With neither present and no flag, nothing is mandated and
# the check is a no-op — this is opt-in governance, not an imposed policy.
#
# Fixing a non-compliant merge that is ALREADY PUBLISHED: do not rewrite shared history. Build a
# replacement two-parent merge from the same parents with the trailers present, and prove
# `old^{tree} == replacement^{tree}` before promoting it.
#
# Exit 0 = every introduced commit complies (GREEN). Exit 1 = one or more do not (RED, listed).

set -uo pipefail

BASE=""
ALLOW_EMPTY=0
REQUIRED=()

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --base) [[ $# -ge 2 ]] || { echo "--base requires a ref" >&2; exit 2; }; BASE="$2"; shift 2 ;;
    --trailer) [[ $# -ge 2 ]] || { echo "--trailer requires a name" >&2; exit 2; }; REQUIRED+=("$2"); shift 2 ;;
    --allow-empty) ALLOW_EMPTY=1; shift ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *) echo "Unexpected argument: $1" >&2; exit 2 ;;
  esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Not inside a git repository." >&2; exit 2; }

if [[ ${#REQUIRED[@]} -eq 0 ]]; then
  for cfg in .wgm/required-trailers .github/required-trailers; do
    [[ -f "$cfg" ]] || continue
    while IFS= read -r line; do
      line="${line%%#*}"
      line="$(printf '%s' "$line" | tr -d '[:space:]')"
      [[ -n "$line" ]] && REQUIRED+=("$line")
    done < "$cfg"
    break
  done
fi

if [[ ${#REQUIRED[@]} -eq 0 ]]; then
  echo "trailers: no required trailers configured (see --trailer or .wgm/required-trailers); nothing to audit."
  [[ "$ALLOW_EMPTY" -eq 1 ]] && exit 0
  echo "trailers: GREEN"
  exit 0
fi

if [[ -z "$BASE" ]]; then
  for cand in origin/HEAD origin/main main; do
    if git rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then BASE="$cand"; break; fi
  done
fi
[[ -n "$BASE" ]] || { echo "Could not resolve a base ref; pass --base REF." >&2; exit 2; }

MERGE_BASE="$(git merge-base "$BASE" HEAD 2>/dev/null || true)"
[[ -n "$MERGE_BASE" ]] || { echo "No merge base between $BASE and HEAD; pass --base REF." >&2; exit 2; }

FAIL=0
COUNT=0
MERGES=0

# rev-list includes merge commits by default; that is the point — a generated merge is a
# first-class governed commit, not an exempt artifact of the merge button.
while IFS= read -r sha; do
  [[ -n "$sha" ]] || continue
  COUNT=$((COUNT + 1))
  parents="$(git rev-list --parents -n 1 "$sha" | wc -w)"
  is_merge=0
  (( parents > 2 )) && { is_merge=1; MERGES=$((MERGES + 1)); }
  body="$(git show -s --format=%B "$sha")"
  missing=()
  for key in "${REQUIRED[@]}"; do
    grep -qiE "^${key}:[[:space:]]*[^[:space:]]" <<<"$body" || missing+=("$key")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    subject="$(git show -s --format=%s "$sha")"
    printf 'FAIL: %s %s%s — missing trailer(s): %s\n' \
      "${sha:0:9}" "$subject" "$( ((is_merge)) && printf ' [merge commit]')" "${missing[*]}" >&2
    FAIL=1
  fi
done < <(git rev-list "${MERGE_BASE}..HEAD")

if (( FAIL == 0 )); then
  printf 'ok:   %s commit(s) audited (%s merge) — all carry: %s\n' "$COUNT" "$MERGES" "${REQUIRED[*]}"
  echo "trailers: GREEN"
  exit 0
else
  echo "trailers: RED" >&2
  echo "For a generated merge, re-run 'gh pr merge --merge' with explicit --subject/--body whose" >&2
  echo "final block carries the required trailers. If it is already published, do not rewrite shared" >&2
  echo "history: build a replacement two-parent merge and prove old^{tree} == replacement^{tree}." >&2
  exit 1
fi
