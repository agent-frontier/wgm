#!/usr/bin/env bash
#
# wgm/check-docs.sh — deterministic backpressure for the docs/ workstream.
#
# Verifies the documentation set is structurally sound so the build loop has a real pass/fail
# signal (not just "it didn't crash"). Checks:
#   1. docs/ exists and is split into operator/ and agent/ concerns, with an index.
#   2. All required docs files are present.
#   3. Every ```mermaid code fence is balanced (opened and closed).
#   4. Internal relative Markdown links resolve to real files.
#   5. No leftover <placeholder> or TODO markers remain in docs/.
#   6. Every operator doc (docs/operator/*) opens with an "## Executive overview" section.
#
# Exit 0 = green (all checks pass). Exit 1 = red (one or more failures, listed).
# Scope: docs/**/*.md, references/**/*.md, README.md, SKILL.md, CONTRIBUTING.md,
# SECURITY.md, CODE_OF_CONDUCT.md, and launch-facing GitHub templates.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

FAIL=0
note() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }
ok()   { printf 'ok:   %s\n' "$*"; }

REQUIRED=(
  "docs/README.md"
  "docs/operator/README.md"
  "docs/operator/installation.md"
  "docs/operator/running-the-loop.md"
  "docs/operator/containers.md"
  "docs/operator/troubleshooting.md"
  "docs/agent/lifecycle.md"
  "docs/agent/attractor-loop.md"
  "docs/agent/scenarios-and-scoring.md"
  "docs/agent/stall-recovery.md"
  "docs/agent/gene-transfusion.md"
)

# 1 + 2 — structure & required files
[[ -d docs ]]          || note "docs/ directory is missing"
[[ -d docs/operator ]] || note "docs/operator/ directory is missing"
[[ -d docs/agent ]]    || note "docs/agent/ directory is missing"
for f in "${REQUIRED[@]}"; do
  [[ -f "$f" ]] || note "required doc is missing: $f"
done

# Gather the Markdown files to lint (docs/ + README.md).
mapfile -t MD < <(
  find docs references -name '*.md' 2>/dev/null | sort
  for f in README.md SKILL.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md .github/PULL_REQUEST_TEMPLATE.md .github/ISSUE_TEMPLATE/*.yml; do
    [[ -f "$f" ]] && echo "$f"
  done
)

# 3 — balanced Mermaid / code fences, and at least one Mermaid diagram in docs.
MERMAID_TOTAL=0
for f in "${MD[@]}"; do
  fences=$(grep -cE '^[[:space:]]*```' "$f" 2>/dev/null) || true; fences=${fences:-0}
  if (( fences % 2 != 0 )); then
    note "unbalanced code fence (\`\`\`) in $f"
  fi
  m=$(grep -cE '^[[:space:]]*```mermaid' "$f" 2>/dev/null) || true; m=${m:-0}
  MERMAID_TOTAL=$(( MERMAID_TOTAL + m ))
done
if (( ${#MD[@]} > 0 && MERMAID_TOTAL == 0 )); then
  note "no \`\`\`mermaid diagrams found in docs (user expects Mermaid)"
fi

# 4 — internal relative links resolve.
for f in "${MD[@]}"; do
  dir="$(dirname "$f")"
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    case "$target" in
      http://*|https://*|mailto:*|\#*) continue ;;   # external or pure anchor
    esac
    target="${target%%#*}"                            # drop #anchor
    target="${target%% *}"                            # drop optional "title"
    [[ -z "$target" ]] && continue
    if [[ "$target" = /* ]]; then resolved="${ROOT}${target}"; else resolved="${dir}/${target}"; fi
    if [[ ! -e "$resolved" ]]; then
      note "broken link in $f -> $target"
    fi
  done < <(grep -oE '\]\([^)]+\)' "$f" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//')
done

# 5 — no leftover placeholders / TODO markers in docs/.
for f in "${MD[@]}"; do
  [[ "$f" == docs/* ]] || continue
  if grep -nE '<[a-z][a-z0-9 _/-]*>|TODO|FIXME' "$f" >/dev/null 2>&1; then
    note "leftover placeholder/TODO in $f"
  fi
done

# 6 — every operator doc carries an executive overview to orient the reader.
OPERATOR_DOCS=(
  "docs/operator/README.md"
  "docs/operator/installation.md"
  "docs/operator/running-the-loop.md"
  "docs/operator/containers.md"
  "docs/operator/troubleshooting.md"
)
for f in "${OPERATOR_DOCS[@]}"; do
  [[ -f "$f" ]] || continue   # a missing file is already reported by check 2
  if ! grep -qE '^##[[:space:]]+Executive overview' "$f"; then
    note "operator doc lacks an '## Executive overview' section: $f"
  fi
done

if (( FAIL == 0 )); then
  ok "docs check passed (${#MD[@]} files, ${MERMAID_TOTAL} mermaid diagram(s))"
  echo "docs: GREEN"
  exit 0
else
  echo "docs: RED" >&2
  exit 1
fi
