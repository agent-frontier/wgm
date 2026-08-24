#!/usr/bin/env bash
#
# wgm/test-agent-adapters.sh — deterministic backpressure for the role-agent adapters.
#
# wgm authors twelve role subagents once, in the Copilot custom-agent format under
# `.github/agents/*.agent.md`. Before this harness existed, an install copied that directory inside
# `SKILLS_DIR/wgm/.github/agents/` — a path no host scans after an install — so the swarm was
# shipped and undiscoverable at the same time. These checks pin both halves of the fix: the
# canonical -> host mapping recorded in `compatibility/agent-adapters.json`, and the installer
# behaviour that puts each host's files where that host actually looks.
#
# Static checks (mapping + doc sync):
#   A1  the manifest is valid JSON with the keys the installers and docs rely on.
#   A2  manifest roles and `.github/agents/*.agent.md` are a 1:1 set — no role invented or dropped.
#   A3  every role has a Claude adapter whose slug name is valid and DISTINCT from the Copilot name,
#       and whose description matches the canonical source.
#   A4  the adapters are derivable: scripts/sync-agent-adapters.sh --check reports no drift.
#   A5  the shipped install paths appear in the docs that promise them.
#   A6  compatibility/harnesses.json agrees with the manifest about adapter status.
#
# Install checks (throwaway HOME / project dirs only — the real home is never touched):
#   B1  user scope: Copilot files land in ~/.copilot/agents, Claude files in ~/.claude/agents.
#   B2  project scope: Copilot files land in .github/agents, Claude files in .claude/agents.
#   B3  a generic `.agents` client invents no adapter directory, and says why.
#   B4  --dir installs the skill only and reports that no host agent path can be guessed.
#   B5  --no-agents installs the skill and no adapters at all.
#   B6  a re-run refreshes wgm-owned adapters, leaves an unrelated agent alone, and refuses to
#       clobber a foreign file that merely shares one of wgm's names.
#   B7  uninstall removes only the receipt-listed wgm adapters; everything else survives.
#   B8  uninstall with no receipt touches nothing.
#   B9  the WSL mirror installs adapters into both homes and escapes neither.
#   B10 wgm's own checkout is never installed onto itself as a project Copilot target.
#
# Exit 0 = green (all checks pass). Exit 1 = red (failures listed). Exit 2 = jq missing.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
SYNC="$ROOT/scripts/sync-agent-adapters.sh"
MANIFEST="$ROOT/compatibility/agent-adapters.json"
CANON_DIR="$ROOT/.github/agents"
CLAUDE_DIR="$ROOT/adapters/claude/agents"

[[ -f "$INSTALL" ]]   || { echo "cannot find install.sh at $INSTALL" >&2; exit 2; }
[[ -f "$MANIFEST" ]]  || { echo "cannot find the adapter manifest at $MANIFEST" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required but not found on PATH" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { printf 'ok:   %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

contains() { printf '%s\n' "$1" | grep -qF -- "$2"; }
count_files() { find "$1" -maxdepth 1 -name "$2" 2>/dev/null | wc -l | tr -d ' '; }
TILDE='~'   # documented paths are written with a literal tilde; keep shellcheck from "helping".

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wgm-adapters-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Frontmatter `name:` of a file, leading --- block only.
name_of() {
  awk 'NR==1 && $0=="---" {infm=1; next} infm && $0=="---" {exit}
       infm && index($0,"name:")==1 { v=substr($0,6); sub(/^[[:space:]]+/,"",v); print v; exit }' "$1"
}
desc_of() {
  awk 'NR==1 && $0=="---" {infm=1; next} infm && $0=="---" {exit}
       infm && index($0,"description:")==1 { v=substr($0,13); sub(/^[[:space:]]+/,"",v); print v; exit }' "$1"
}

# ---- A1: manifest shape ----------------------------------------------------
if jq -e '
      (.manifest_version | type == "string")
  and (.receipt_file | type == "string")
  and (.canonical.source_dir == ".github/agents")
  and (.canonical.file_suffix == ".agent.md")
  and (.hosts | type == "array" and length >= 3)
  and (.fallback.docs_audit | test("audit.sh"))
  and (.roles | type == "array" and length > 0)
  and ([.hosts[] | select(.id == "copilot")] | length == 1)
  and ([.hosts[] | select(.id == "claude")] | length == 1)
  and ([.hosts[] | select(.id == "agents")] | length == 1)
  and ([.hosts[] | select(.id == "agents") | .user_dir, .project_dir] | all(. == null))
  and ([.hosts[] | select(.id == "agents") | .status] == ["no-adapter"])
' "$MANIFEST" >/dev/null 2>&1; then
  ok "A1 adapter manifest is valid JSON with the canonical/host/role/fallback contract"
else
  bad "A1 compatibility/agent-adapters.json does not satisfy the manifest contract"
fi

# ---- A2: manifest roles == canonical files (1:1) ---------------------------
canon_list="$(find "$CANON_DIR" -maxdepth 1 -name '*.agent.md' -printf '%f\n' | sort)"
manifest_list="$(jq -r '.roles[].canonical_file' "$MANIFEST" | sort)"
if [[ "$canon_list" == "$manifest_list" && -n "$canon_list" ]]; then
  ok "A2 manifest roles and .github/agents/*.agent.md are a 1:1 set ($(printf '%s\n' "$canon_list" | wc -l | tr -d ' ') roles)"
else
  bad "A2 role set mismatch between the manifest and $CANON_DIR"
  diff <(printf '%s\n' "$canon_list") <(printf '%s\n' "$manifest_list") >&2 || true
fi

# ---- A3: Claude adapters exist, are valid, and are distinctly named --------
a3=0
while IFS=$'\t' read -r canon_file copilot_name claude_file claude_name; do
  cpath="$CANON_DIR/$canon_file"
  apath="$CLAUDE_DIR/$claude_file"
  [[ -f "$cpath" ]] || { bad "A3 canonical file missing: $cpath"; a3=1; continue; }
  [[ -f "$apath" ]] || { bad "A3 claude adapter missing: $apath"; a3=1; continue; }
  # The host identifier must be a slug, and it must NOT be the Copilot display name: two hosts, two
  # naming rules, and a copied-over title-case name is exactly the drift this asserts against.
  [[ "$claude_name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { bad "A3 not a valid host slug: $claude_name"; a3=1; }
  [[ "$claude_name" != "$copilot_name" ]] || { bad "A3 claude name is not distinct from the copilot name: $claude_name"; a3=1; }
  [[ "$(name_of "$cpath")" == "$copilot_name" ]] || { bad "A3 canonical name drifted from the manifest: $canon_file"; a3=1; }
  [[ "$(name_of "$apath")" == "$claude_name" ]] || { bad "A3 adapter name drifted from the manifest: $claude_file"; a3=1; }
  [[ "$(desc_of "$apath")" == "$(desc_of "$cpath")" ]] || { bad "A3 adapter description drifted from canonical: $claude_file"; a3=1; }
  grep -q 'wgm-adapter-status: Expected' "$apath" || { bad "A3 adapter does not carry its Expected status marker: $claude_file"; a3=1; }
done < <(jq -r '.roles[] | [.canonical_file, .copilot_name, .claude_file, .claude_name] | @tsv' "$MANIFEST")
[[ "$a3" -eq 0 ]] && ok "A3 every role has a valid, distinctly named Claude adapter labelled Expected"

# ---- A4: adapters are derivable, not hand-maintained -----------------------
if [[ -f "$SYNC" ]] && bash "$SYNC" --check >/dev/null 2>&1; then
  ok "A4 claude adapters match what scripts/sync-agent-adapters.sh derives from canonical"
else
  bad "A4 adapter drift: run scripts/sync-agent-adapters.sh"
fi

# ---- A5: the promised install paths are documented -------------------------
a5=0
for doc in docs/reference/cli-install.md docs/operator/installation.md docs/operator/troubleshooting.md \
           references/subagents.md references/harness-portability.md; do
  [[ -f "$ROOT/$doc" ]] || { bad "A5 missing doc: $doc"; a5=1; continue; }
done
for path in "${TILDE}/.copilot/agents" "${TILDE}/.claude/agents" ".claude/agents"; do
  grep -qF -- "$path" "$ROOT/docs/reference/cli-install.md" \
    || { bad "A5 docs/reference/cli-install.md does not document the install path $path"; a5=1; }
done
grep -qF -- '--no-agents' "$ROOT/docs/reference/cli-install.md" \
  || { bad "A5 docs/reference/cli-install.md does not document --no-agents"; a5=1; }
grep -qF -- '-NoAgents' "$ROOT/docs/reference/cli-install.md" \
  || { bad "A5 docs/reference/cli-install.md does not document -NoAgents"; a5=1; }
grep -qF -- 'adapters/claude/agents' "$ROOT/references/subagents.md" \
  || { bad "A5 references/subagents.md does not name the Claude adapter directory"; a5=1; }
grep -qF -- 'agent-adapters.json' "$ROOT/references/harness-portability.md" \
  || { bad "A5 references/harness-portability.md does not link the adapter manifest"; a5=1; }
grep -qF -- 'agents' "$ROOT/docs/operator/troubleshooting.md" \
  || { bad "A5 docs/operator/troubleshooting.md says nothing about agent dirs"; a5=1; }
[[ "$a5" -eq 0 ]] && ok "A5 install paths, the opt-out, and the adapter status are documented"

# ---- A6: harness record agrees with the manifest ---------------------------
HARNESSES="$ROOT/compatibility/harnesses.json"
if jq -e '
      ([.harnesses[] | select(.id=="copilot-cli") | .adapter.status] == ["adapter-shipped"])
  and ([.harnesses[] | select(.id=="claude-code") | .adapter.status] == ["adapter-shipped"])
  and ([.harnesses[] | select(.id=="claude-code") | .adapter.notes | test("adapters/claude/agents")] == [true])
  and ([.harnesses[] | select(.id=="pi") | .adapter.status] == ["adapter-needed"])
' "$HARNESSES" >/dev/null 2>&1; then
  ok "A6 harnesses.json records the shipped Copilot/Claude adapters and Pi's remaining gap"
else
  bad "A6 compatibility/harnesses.json adapter statuses disagree with the shipped adapters"
fi

# ---- B1: user scope lands both hosts in their real scan paths --------------
h="$WORK/b1"; mkdir -p "$h"
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client all >/dev/null 2>&1
if [[ -f "$h/.copilot/agents/wgm-implementer.agent.md" && -f "$h/.claude/agents/wgm-implementer.md" ]] \
   && [[ "$(name_of "$h/.copilot/agents/wgm-implementer.agent.md")" == "WGM Implementer" ]] \
   && [[ "$(name_of "$h/.claude/agents/wgm-implementer.md")" == "wgm-implementer" ]] \
   && [[ "$(count_files "$h/.copilot/agents" '*.agent.md')" -eq "$(count_files "$CANON_DIR" '*.agent.md')" ]] \
   && [[ "$(count_files "$h/.claude/agents" '*.md')" -eq "$(count_files "$CLAUDE_DIR" '*.md')" ]]; then
  ok "B1 user scope: every role landed in ~/.copilot/agents and ~/.claude/agents with host-correct names"
else
  bad "B1 expected all roles under $h/.copilot/agents and $h/.claude/agents"
fi

# ---- B2: project scope lands in .github/agents and .claude/agents ----------
proj="$WORK/b2-proj"; ph="$WORK/b2-home"; mkdir -p "$proj" "$ph"
( cd "$proj" && HOME="$ph" WGM_FORCE_WSL=0 bash "$INSTALL" --project --client all >/dev/null 2>&1 )
if [[ -f "$proj/.github/agents/wgm-validator.agent.md" && -f "$proj/.claude/agents/wgm-validator.md" ]]; then
  ok "B2 project scope: Copilot roles in .github/agents, Claude roles in .claude/agents"
else
  bad "B2 expected project agent dirs at $proj/.github/agents and $proj/.claude/agents"
fi

# ---- B3: a generic .agents client invents no adapter -----------------------
h="$WORK/b3"; mkdir -p "$h"
out="$(HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client agents 2>&1)"
if [[ -f "$h/.agents/skills/wgm/SKILL.md" ]] \
   && [[ ! -e "$h/.agents/agents" && ! -e "$h/.claude/agents" && ! -e "$h/.copilot/agents" ]] \
   && contains "$out" "the Agent Skills standard defines skills, not subagents"; then
  ok "B3 generic .agents client gets the skill plus a named fallback, and no invented adapter dir"
else
  bad "B3 the .agents client must not grow an adapter directory"
fi

# ---- B4: --dir installs the skill only, and says so ------------------------
d="$WORK/b4-dir"; h="$WORK/b4-home"; mkdir -p "$d" "$h"
out="$(HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --dir "$d" --client all 2>&1)"
if [[ -f "$d/wgm/SKILL.md" ]] \
   && [[ ! -e "$d/agents" && ! -e "$h/.copilot/agents" && ! -e "$h/.claude/agents" ]] \
   && contains "$out" "--dir installs the skill only"; then
  ok "B4 --dir never guesses a host agent path; it installs the skill and reports the limit"
else
  bad "B4 --dir should install the skill only and explain that no host was named"
fi

# ---- B5: --no-agents opts out entirely -------------------------------------
h="$WORK/b5"; mkdir -p "$h"
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client all --no-agents >/dev/null 2>&1
if [[ -f "$h/.copilot/skills/wgm/SKILL.md" && ! -e "$h/.copilot/agents" && ! -e "$h/.claude/agents" ]]; then
  ok "B5 --no-agents installs the portable skill and no adapters"
else
  bad "B5 --no-agents still produced adapter directories under $h"
fi

# ---- B6/B7: refresh, no-clobber, and receipt-scoped uninstall --------------
# A host agent directory is shared property: the user's own agents live there, and one of them may
# even share a name with a wgm role. So seed both BEFORE wgm has ever installed here.
h="$WORK/b6"; adir="$h/.copilot/agents"; mkdir -p "$adir"
printf -- '---\nname: My Own Agent\ndescription: not wgm\n---\nkeep me\n' > "$adir/my-team.agent.md"
printf -- '---\nname: Someone Elses Validator\ndescription: not wgm\n---\nkeep me too\n' > "$adir/wgm-validator.agent.md"
out="$(HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot 2>&1)"
# Then tamper with a file wgm DOES own and re-run: the receipt is what makes that file recoverable.
printf 'tampered\n' > "$adir/wgm-implementer.agent.md"
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot >/dev/null 2>&1
if cmp -s "$adir/wgm-implementer.agent.md" "$CANON_DIR/wgm-implementer.agent.md" \
   && grep -q 'keep me' "$adir/my-team.agent.md" \
   && [[ "$(name_of "$adir/wgm-validator.agent.md")" == "Someone Elses Validator" ]] \
   && contains "$out" "exists and is not wgm's"; then
  ok "B6 re-run refreshes wgm-owned adapters, leaves an unrelated agent alone, and refuses a pre-existing name collision"
else
  bad "B6 re-run must refresh only wgm's own files and clobber nothing else"
fi

HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot --uninstall >/dev/null 2>&1
if [[ ! -e "$adir/wgm-implementer.agent.md" && ! -e "$adir/.wgm-adapters" ]] \
   && [[ -f "$adir/my-team.agent.md" ]] \
   && [[ -f "$adir/wgm-validator.agent.md" && "$(name_of "$adir/wgm-validator.agent.md")" == "Someone Elses Validator" ]] \
   && [[ -d "$adir" ]]; then
  ok "B7 uninstall removes only the receipt-listed adapters and leaves the directory and its other agents"
else
  bad "B7 uninstall removed the wrong files in $adir"
fi

# ---- B8: no receipt, no removal --------------------------------------------
h="$WORK/b8"; mkdir -p "$h/.copilot/agents"
printf -- '---\nname: WGM Implementer\ndescription: looks like wgm but wgm never installed it\n---\n' \
  > "$h/.copilot/agents/wgm-implementer.agent.md"
out="$(HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot --uninstall 2>&1)"
if [[ -f "$h/.copilot/agents/wgm-implementer.agent.md" ]] && contains "$out" "no wgm adapter receipt"; then
  ok "B8 uninstall without a wgm receipt removes nothing, even from a wgm-looking file"
else
  bad "B8 uninstall must not delete files it has no receipt for"
fi

# ---- B9: the WSL mirror covers both homes and escapes neither --------------
lh="$WORK/b9-lin"; wh="$WORK/b9-win"; mkdir -p "$lh" "$wh"
out="$(HOME="$lh" WGM_FORCE_WSL=1 bash "$INSTALL" --user --client claude --windows-home "$wh" 2>&1)"
# Every adapter directory the installer reports must sit inside one of the two throwaway homes:
# a mirror that resolves anywhere else is exactly the WSL boundary bug this guards against.
planned="$(printf '%s\n' "$out" | grep -F '(claude role agents)' | sed 's/^ *- //; s/  (claude role agents)$//')"
escaped="$(printf '%s\n' "$planned" | grep -v -e "^$lh/" -e "^$wh/" || true)"
if [[ -f "$lh/.claude/agents/wgm-implementer.md" && -f "$wh/.claude/agents/wgm-implementer.md" ]] \
   && [[ "$(printf '%s\n' "$planned" | grep -c .)" -eq 2 ]] \
   && [[ -z "${escaped//[[:space:]]/}" ]]; then
  ok "B9 WSL mirror installs adapters into both homes and resolves no directory outside them"
else
  bad "B9 WSL adapter mirror escaped its homes or missed one (planned: ${planned:-none})"
fi

# ---- B10: wgm's own checkout is never installed onto itself ----------------
# Dry-run from the repo root: the guard fires before anything is written, so this changes nothing.
h="$WORK/b10"; mkdir -p "$h"
out="$( cd "$ROOT" && HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --project --client copilot --dry-run 2>&1 )"
if contains "$out" "already the canonical source, skipping"; then
  ok "B10 a project install inside wgm's own checkout refuses to copy .github/agents onto itself"
else
  bad "B10 expected the canonical-source guard to fire for a project Copilot install at the repo root"
fi

echo ""
echo "agent-adapter tests: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -eq 0 ]]; then echo "agent-adapters: GREEN"; exit 0; else echo "agent-adapters: RED" >&2; exit 1; fi
