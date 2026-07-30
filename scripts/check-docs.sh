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
#   7. Every .github/agents/*.agent.md file has required frontmatter (name, description) and
#      required sections (a "**Mission**:" statement and an "### Integration" section).
#   8. Every references/*.md filename is enumerated in README.md's repository-layout tree-comment
#      line, so a new reference doc can't silently drift out of that 1:1 index again (this defect
#      class regressed twice before being caught by a manual audit pass each time — see
#      docs/audit/2026-07-09T0113Z_pr62-65-post-merge-audit.md, Agent action #3).
#
#   9. No UTF-8 double-encoding (mojibake) survives from a multi-agent merge.
#  10. Every get-started / companions / reference page ends with a "What to do next" section, so
#      navigation never dead-ends.
#  11. docs/README.md still links the style guide that documents all of the above.
#
# Exit 0 = green (all checks pass). Exit 1 = red (one or more failures, listed).
# Scope: docs/**/*.md, references/**/*.md, README.md, SKILL.md, CONTRIBUTING.md,
# SECURITY.md, CODE_OF_CONDUCT.md, .github/agents/*.agent.md, and launch-facing GitHub templates.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

FAIL=0
note() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }
ok()   { printf 'ok:   %s\n' "$*"; }

REQUIRED=(
  "docs/README.md"
  "docs/style-guide.md"
  "docs/get-started/README.md"
  "docs/get-started/requirements.md"
  "docs/get-started/first-build.md"
  "docs/operator/README.md"
  "docs/operator/installation.md"
  "docs/operator/running-the-loop.md"
  "docs/operator/containers.md"
  "docs/operator/devcontainers.md"
  "docs/operator/troubleshooting.md"
  "docs/operator/playbook.md"
  "docs/companions/README.md"
  "docs/reference/README.md"
  "docs/reference/cli-loop.md"
  "docs/reference/cli-swarm.md"
  "docs/reference/cli-install.md"
  "docs/reference/gates.md"
  "docs/reference/artifacts.md"
  "docs/agent/lifecycle.md"
  "docs/agent/attractor-loop.md"
  "docs/agent/scenarios-and-scoring.md"
  "docs/agent/stall-recovery.md"
  "docs/agent/gene-transfusion.md"
)

# 1 + 2 — structure & required files
# Four audience-scoped sections: a get-started journey, operator tasks, agent concepts, and lookup
# reference. Keeping them distinct is what stops a page from becoming half tutorial, half man page.
[[ -d docs ]]              || note "docs/ directory is missing"
[[ -d docs/get-started ]]  || note "docs/get-started/ directory is missing"
[[ -d docs/operator ]]     || note "docs/operator/ directory is missing"
[[ -d docs/agent ]]        || note "docs/agent/ directory is missing"
[[ -d docs/reference ]]    || note "docs/reference/ directory is missing"
for f in "${REQUIRED[@]}"; do
  [[ -f "$f" ]] || note "required doc is missing: $f"
done

# Gather the Markdown files to lint (docs/ + README.md).
mapfile -t MD < <(
  find docs references companions -name '*.md' 2>/dev/null | sort
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
  "docs/operator/playbook.md"
  "docs/operator/installation.md"
  "docs/operator/running-the-loop.md"
  "docs/operator/containers.md"
  "docs/operator/devcontainers.md"
  "docs/operator/troubleshooting.md"
)
for f in "${OPERATOR_DOCS[@]}"; do
  [[ -f "$f" ]] || continue   # a missing file is already reported by check 2
  if ! grep -qE '^##[[:space:]]+Executive overview' "$f"; then
    note "operator doc lacks an '## Executive overview' section: $f"
  fi
done

# 7 — every custom agent file carries required frontmatter + sections.
shopt -s nullglob
AGENT_FILES=(.github/agents/*.agent.md)
shopt -u nullglob
for f in "${AGENT_FILES[@]}"; do
  grep -qE '^name:' "$f"            || note "agent file missing 'name:' frontmatter: $f"
  grep -qE '^description:' "$f"     || note "agent file missing 'description:' frontmatter: $f"
  grep -q '\*\*Mission\*\*:' "$f"   || note "agent file missing a '**Mission**:' statement: $f"
  grep -qE '^### Integration' "$f"  || note "agent file missing an '### Integration' section: $f"
done
if (( ${#AGENT_FILES[@]} == 0 )); then
  note ".github/agents/*.agent.md — no custom agent files found"
fi

# 8 — every references/*.md file is named in README.md's repository-layout tree-comment line.
if [[ -f README.md ]]; then
  tree_line="$(grep -E '^├── references/' README.md || true)"
  if [[ -z "$tree_line" ]]; then
    note "README.md has no '├── references/' repository-layout tree-comment line to check"
  else
    for f in references/*.md; do
      [[ -f "$f" ]] || continue
      name="$(basename "$f" .md)"
      if ! grep -qF "$name" <<< "$tree_line"; then
        note "README.md's references/ tree-comment line is missing '$name' (add it to the enumeration)"
      fi
    done
  fi
fi

# 10 — every get-started, companions, and reference page ends by telling the reader where to go next.
# A page that dead-ends forces the reader back to guessing, which is the failure the section split
# exists to prevent (docs/style-guide.md, "Every page ends with What to do next").
for f in docs/get-started/*.md docs/companions/*.md docs/reference/*.md; do
  [[ -f "$f" ]] || continue
  grep -qE '^## (What to do next|Quick answers)' "$f" \
    || note "missing a '## What to do next' section: $f"
done

# 11 — the docs style guide is the one page that must describe the forbidden patterns without
# containing them; checks 5 and 9 already enforce that, so just assert it stayed present and linked.
if [[ -f docs/README.md ]]; then
  grep -q 'style-guide.md' docs/README.md || note "docs/README.md no longer links the style guide"
fi

# 9 — UTF-8 double-encoding (mojibake) sweep.
# When several independent agents each write Markdown and their output is concatenated or merged,
# a UTF-8 string re-decoded as CP1252 and re-encoded produces `Â·` for `·`, `Ã—` for `×`, and so on.
# No single lane can see it — it only shows up after consolidation — so it belongs in a standing
# gate rather than a manual post-merge cleanup ([learn] issue #67).
# Detection: a `Â` (C3 82) or `Ã` (C3 83) immediately followed by another non-ASCII sequence — the
# signature of the doubled encoding. A lone Â/Ã in prose is left alone, so ordinary accented text
# and legitimate Latin-1 characters do not trip the gate.
for f in "${MD[@]}"; do
  # LC_ALL=C keeps \xNN a BYTE match; in a UTF-8 locale PCRE reads it as a character and the
  # doubled-encoding signature never matches — a silently-passing gate.
  if hits=$(LC_ALL=C grep -cP '\xc3[\x82\x83][\xc2\xc3\xe2]' "$f" 2>/dev/null) && (( hits > 0 )); then
    note "UTF-8 double-encoding (mojibake) in $f — ${hits} line(s); re-encode as UTF-8"
  fi
done

if (( FAIL == 0 )); then
  ok "docs check passed (${#MD[@]} files, ${MERMAID_TOTAL} mermaid diagram(s), ${#AGENT_FILES[@]} agent file(s))"
  echo "docs: GREEN"
  exit 0
else
  echo "docs: RED" >&2
  exit 1
fi
