#!/usr/bin/env bash
#
# wgm/sync-agent-adapters.sh — derive the host agent adapters from the canonical role definitions.
#
# wgm authors each role once, in the Copilot custom-agent format under `.github/agents/*.agent.md`.
# Every other host needs the same role in its own format, and a hand-maintained second copy drifts
# the moment one side is edited. This script is the deterministic mapping between them:
#
#   .github/agents/<role>.agent.md   ->   adapters/claude/agents/<role>.md
#
# The translation is intentionally conservative — Claude Code's documented subagent format is
# frontmatter `name` + `description` with the body as the system prompt, so that is all wgm emits.
# No tool or model keys are invented, because wgm has not verified them against a live Claude Code
# run (see references/harness-portability.md's evidence tiers; the Claude adapter is `Expected`).
#
# Usage:
#   scripts/sync-agent-adapters.sh            # regenerate the adapters in place
#   scripts/sync-agent-adapters.sh --check    # fail if any adapter differs from its canonical source
#   scripts/sync-agent-adapters.sh --help
#
# Exit 0 = adapters are in sync (or were regenerated). Exit 1 = drift (with --check). Exit 2 = usage
# or a canonical file wgm cannot translate safely.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

CANON_DIR=".github/agents"
CLAUDE_DIR="adapters/claude/agents"

CHECK=0
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

FAIL=0
note() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }

# Read one frontmatter field ($2) out of file $1. Only the leading `---` block is inspected, so a
# later line in the prose can never be mistaken for frontmatter.
frontmatter_field() {
  awk -v key="$2" '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && $0 == "---" { exit }
    infm {
      k = key ":"
      if (index($0, k) == 1) { v = substr($0, length(k) + 1); sub(/^[[:space:]]+/, "", v); print v; exit }
    }
  ' "$1"
}

# Everything after the closing `---` of the frontmatter block, with leading blank lines removed.
body_after_frontmatter() {
  awk '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && $0 == "---" { infm = 0; started = 1; next }
    started {
      if (!seen && $0 ~ /^[[:space:]]*$/) next
      seen = 1
      print
    }
  ' "$1"
}

# A YAML plain scalar cannot carry ": " or start with an indicator character. wgm's descriptions are
# prose and never do — but if one ever does, fail loudly rather than emit a file that parses wrong.
assert_plain_scalar_safe() {
  local value="$1" where="$2"
  case "$value" in
    *": "*|*" #"*) note "$where: description needs YAML quoting (contains ': ' or ' #'); fix the canonical file"; return 1 ;;
    [-\?:,\[\]\{\}\#\&\*\!\|\>\'\"%@\`]*) note "$where: description starts with a YAML indicator character"; return 1 ;;
  esac
  return 0
}

render_claude_adapter() {
  # $1 = canonical file path, $2 = role slug
  local src="$1" slug="$2" desc
  desc="$(frontmatter_field "$src" description)"
  [[ -n "$desc" ]] || { note "$src: no description frontmatter to translate"; return 1; }
  assert_plain_scalar_safe "$desc" "$src" || return 1
  printf -- '---\n'
  printf 'name: %s\n' "$slug"
  printf 'description: %s\n' "$desc"
  printf -- '---\n\n'
  printf '<!-- wgm-adapter: generated from %s/%s by scripts/sync-agent-adapters.sh. Do not edit by hand. -->\n' \
    "$CANON_DIR" "$(basename "$src")"
  printf '<!-- wgm-adapter-status: Expected — Claude Code'"'"'s documented subagent format, not verified against a live run. -->\n\n'
  body_after_frontmatter "$src"
}

[[ -d "$CANON_DIR" ]] || { echo "missing canonical dir: $CANON_DIR" >&2; exit 2; }

shopt -s nullglob
CANON_FILES=("$CANON_DIR"/*.agent.md)
shopt -u nullglob
if [[ ${#CANON_FILES[@]} -eq 0 ]]; then
  echo "no canonical agent files in $CANON_DIR" >&2
  exit 2
fi

[[ "$CHECK" -eq 1 ]] || mkdir -p "$CLAUDE_DIR"

WROTE=0
EXPECTED=()
for src in "${CANON_FILES[@]}"; do
  base="$(basename "$src")"
  slug="${base%.agent.md}"
  dest="$CLAUDE_DIR/$slug.md"
  EXPECTED+=("$slug.md")
  rendered="$(render_claude_adapter "$src" "$slug")" || continue
  if [[ "$CHECK" -eq 1 ]]; then
    if [[ ! -f "$dest" ]]; then
      note "missing adapter: $dest (run scripts/sync-agent-adapters.sh)"
    elif [[ "$rendered" != "$(cat "$dest")" ]]; then
      note "adapter drifted from its canonical source: $dest (run scripts/sync-agent-adapters.sh)"
    fi
  else
    printf '%s\n' "$rendered" > "$dest"
    WROTE=$((WROTE + 1))
  fi
done

# An adapter with no canonical source is drift too: a deleted role must not linger in a host dir.
shopt -s nullglob
for existing in "$CLAUDE_DIR"/*.md; do
  eb="$(basename "$existing")"
  found=0
  for e in ${EXPECTED[@]+"${EXPECTED[@]}"}; do [[ "$e" == "$eb" ]] && found=1; done
  if [[ "$found" -eq 0 ]]; then
    if [[ "$CHECK" -eq 1 ]]; then
      note "orphan adapter with no canonical source: $existing"
    else
      rm -f "$existing"
      printf 'removed orphan: %s\n' "$existing"
    fi
  fi
done
shopt -u nullglob

if [[ "$FAIL" -ne 0 ]]; then
  echo "agent-adapters sync: RED" >&2
  exit 1
fi

if [[ "$CHECK" -eq 1 ]]; then
  printf 'ok:   %s claude adapter(s) match their canonical source\n' "${#CANON_FILES[@]}"
else
  printf 'ok:   wrote %s claude adapter(s) into %s\n' "$WROTE" "$CLAUDE_DIR"
fi
echo "agent-adapters sync: GREEN"
