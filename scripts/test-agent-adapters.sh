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
#   A1  the manifest is valid JSON with the keys the installers and docs rely on, including the
#       ownership marker token, its required terminal position, and its per-host scope.
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
#   B7  uninstall removes only the marked wgm adapters; everything else survives.
#   B8  uninstall with no receipt and no marked file touches nothing.
#   B9  the WSL mirror installs adapters into both homes and escapes neither.
#   B10 wgm's own checkout is never installed onto itself as a project Copilot target.
#   B11 every installed adapter is stamped with the ownership marker; the shipped tree never is.
#   B12 a tracked project file that shares a wgm role name is not modified, claimed, or removed.
#   B13 a CRLF receipt with no final newline uninstalls exactly wgm's files.
#   B14 a source with a role removed prunes only the marked stale file.
#   B15 lost, partial, and interrupted receipts stay safe, and normal installs leave no temp files.
#   B16 --force is the only way to take over a foreign name collision, and it stamps what it takes.
#   B17 a foreign file that merely quotes the marker token in prose is never adopted or removed.
#   B18 a shared/symlinked Copilot+Claude directory: neither host prunes, deletes, or claims the
#       other's adapters, and a copied marker naming the wrong host proves nothing.
#   B19 the marker must be terminal and must name this file's canonical source; CRLF and trailing
#       blank lines around a genuine marker are still tolerated.
#
# Exit 0 = green (all checks pass). Exit 1 = red (failures listed). Exit 2 = jq missing.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
SYNC="$ROOT/scripts/sync-agent-adapters.sh"
MANIFEST="$ROOT/compatibility/agent-adapters.json"
CANON_DIR="$ROOT/.github/agents"
CLAUDE_DIR="$ROOT/adapters/claude/agents"
MARKER="wgm-role-agent-adapter"   # the ownership token the installers stamp into every file they write

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
  and (.ownership.marker_token == "wgm-role-agent-adapter")
  and (.ownership.marker_form | test("LAST non-blank line"))
  and (.ownership.marker_position | test("^terminal"))
  and (.ownership.marker_host_scope | test("^per host"))
  and (.ownership.rule | test("never inferred from a matching file name"))
  and (.ownership.rule | test("never from the token appearing somewhere in the file"))
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
  ok "A1 adapter manifest is valid JSON with the canonical/host/role/fallback/ownership contract"
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

# ---- B6/B7: refresh, no-clobber, and marker-scoped uninstall ---------------
# A host agent directory is shared property: the user's own agents live there, and one of them may
# even share a name with a wgm role. So seed both BEFORE wgm has ever installed here.
h="$WORK/b6"; adir="$h/.copilot/agents"; mkdir -p "$adir"
printf -- '---\nname: My Own Agent\ndescription: not wgm\n---\nkeep me\n' > "$adir/my-team.agent.md"
printf -- '---\nname: Someone Elses Validator\ndescription: not wgm\n---\nkeep me too\n' > "$adir/wgm-validator.agent.md"
out="$(HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot 2>&1)"
# Then edit a file wgm DOES own, keeping its marker in the terminal position, and re-run: the marker
# is what makes that file refreshable. The foreign collision must also stay out of the receipt — wgm
# never claims it.
sed -i '$i local edit that will be overwritten' "$adir/wgm-implementer.agent.md"
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot >/dev/null 2>&1
if [[ "$(head -c "$(wc -c < "$CANON_DIR/wgm-implementer.agent.md")" "$adir/wgm-implementer.agent.md")" \
      == "$(cat "$CANON_DIR/wgm-implementer.agent.md")" ]] \
   && ! grep -q 'local edit that will be overwritten' "$adir/wgm-implementer.agent.md" \
   && grep -q 'keep me' "$adir/my-team.agent.md" \
   && [[ "$(name_of "$adir/wgm-validator.agent.md")" == "Someone Elses Validator" ]] \
   && ! grep -qxF 'wgm-validator.agent.md' "$adir/.wgm-adapters" \
   && contains "$out" "exists and is not wgm's"; then
  ok "B6 re-run refreshes marked adapters, leaves an unrelated agent alone, and neither clobbers nor claims a pre-existing name collision"
else
  bad "B6 re-run must refresh only wgm's own files, clobber nothing else, and claim nothing else"
fi

HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot --uninstall >/dev/null 2>&1
if [[ ! -e "$adir/wgm-implementer.agent.md" && ! -e "$adir/.wgm-adapters" ]] \
   && [[ -f "$adir/my-team.agent.md" ]] \
   && [[ -f "$adir/wgm-validator.agent.md" && "$(name_of "$adir/wgm-validator.agent.md")" == "Someone Elses Validator" ]] \
   && [[ -d "$adir" ]]; then
  ok "B7 uninstall removes only the marked adapters and leaves the directory and its other agents"
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

# ---- B11: every installed adapter is stamped; the shipped tree is not ------
# The marker is the ownership proof, so it has to be present, self-describing, and written ONLY into
# files wgm creates. A stamped source tree would let wgm claim a checkout it merely read.
h="$WORK/b11"; mkdir -p "$h"
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client all >/dev/null 2>&1
cop="$h/.copilot/agents/wgm-implementer.agent.md"
cla="$h/.claude/agents/wgm-implementer.md"
unstamped="$(grep -rlF -- "$MARKER" "$CANON_DIR" "$CLAUDE_DIR" 2>/dev/null || true)"
stamped_all=1
for f in "$h"/.copilot/agents/*.agent.md "$h"/.claude/agents/*.md; do
  grep -qF -- "$MARKER" "$f" || stamped_all=0
done
if [[ "$stamped_all" -eq 1 ]] \
   && grep -qE -- "$MARKER host=copilot source=\.github/agents/wgm-implementer\.agent\.md version=[^ ]+" "$cop" \
   && grep -qE -- "$MARKER host=claude source=adapters/claude/agents/wgm-implementer\.md version=[^ ]+" "$cla" \
   && [[ -z "$unstamped" ]]; then
  ok "B11 every installed adapter carries the ownership marker with host, canonical source, and version — and the shipped tree carries none"
else
  bad "B11 marker missing from an installed adapter, or stamped into the source tree (${unstamped:-none})"
fi

# ---- B12: a pre-existing project file with a wgm name is never adopted -----
# The dangerous case is a repository that already tracks .github/agents/wgm-validator.agent.md.
# wgm must not overwrite it, must not list it, and must leave the working tree clean for it.
proj="$WORK/b12-proj"; ph="$WORK/b12-home"; mkdir -p "$proj/.github/agents" "$ph"
printf -- '---\nname: Our Validator\ndescription: this repo owns this file\n---\nours\n' \
  > "$proj/.github/agents/wgm-validator.agent.md"
( cd "$proj" && git init -q . && git -c user.email=t@e -c user.name=t add .github/agents/wgm-validator.agent.md \
  && git -c user.email=t@e -c user.name=t commit -qm seed ) >/dev/null 2>&1
( cd "$proj" && HOME="$ph" WGM_FORCE_WSL=0 bash "$INSTALL" --project --client copilot >/dev/null 2>&1 )
tracked_dirty="$( cd "$proj" && git status --porcelain -- .github/agents/wgm-validator.agent.md )"
( cd "$proj" && HOME="$ph" WGM_FORCE_WSL=0 bash "$INSTALL" --project --client copilot --uninstall >/dev/null 2>&1 )
if [[ -z "$tracked_dirty" ]] \
   && [[ "$(name_of "$proj/.github/agents/wgm-validator.agent.md")" == "Our Validator" ]] \
   && ! grep -qF -- "$MARKER" "$proj/.github/agents/wgm-validator.agent.md" \
   && [[ ! -e "$proj/.github/agents/wgm-implementer.agent.md" ]]; then
  ok "B12 a tracked project file that merely shares a wgm role name is neither modified, claimed, nor removed"
else
  bad "B12 wgm adopted or disturbed a pre-existing project agent file in $proj/.github/agents"
fi

# ---- B13: a CRLF receipt with no final newline still uninstalls cleanly ----
# Receipts get edited, synced, and copied through Windows tooling. A stray \r must not turn a
# basename into an unrecognised entry, and must never widen what gets deleted.
h="$WORK/b13"; adir="$h/.copilot/agents"; mkdir -p "$h"
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot >/dev/null 2>&1
printf -- '---\nname: My Own Agent\ndescription: not wgm\n---\nkeep me\n' > "$adir/my-team.agent.md"
crlf="$(sed 's/$/\r/' "$adir/.wgm-adapters")"
printf '%s' "$crlf" > "$adir/.wgm-adapters"      # CRLF endings, and no newline on the last entry
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot --uninstall >/dev/null 2>&1
if [[ "$(count_files "$adir" '*.agent.md')" -eq 1 ]] \
   && [[ -f "$adir/my-team.agent.md" && ! -e "$adir/.wgm-adapters" && -d "$adir" ]]; then
  ok "B13 a CRLF receipt with no trailing newline uninstalls exactly wgm's files and nothing else"
else
  bad "B13 CRLF receipt handling removed the wrong set from $adir"
fi

# ---- B14: a source with a role removed prunes only what wgm owns -----------
# Roles get retired. The stale file must go, but only on wgm's own evidence: a file whose marker was
# deleted has been disowned by the user, and a foreign file was never wgm's to begin with.
src="$WORK/b14-src"; h="$WORK/b14"; adir="$h/.copilot/agents"; mkdir -p "$src" "$h"
tar -C "$ROOT" --exclude=.git -cf - . 2>/dev/null | tar -C "$src" -xf - 2>/dev/null
rm -f "$src/.github/agents/wgm-hermes.agent.md" "$src/adapters/claude/agents/wgm-hermes.md"
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot >/dev/null 2>&1
printf -- '---\nname: Not Wgm\ndescription: unlisted and unmarked\n---\nmine\n' > "$adir/wgm-extra.agent.md"
grep -vF -- "$MARKER" "$adir/wgm-griller.agent.md" > "$adir/.griller.tmp" && mv "$adir/.griller.tmp" "$adir/wgm-griller.agent.md"
crlf="$(sed 's/$/\r/' "$adir/.wgm-adapters")"; printf '%s' "$crlf" > "$adir/.wgm-adapters"
HOME="$h" WGM_FORCE_WSL=0 bash "$src/scripts/install.sh" --user --client copilot >/dev/null 2>&1
if [[ ! -e "$adir/wgm-hermes.agent.md" ]] \
   && [[ -f "$adir/wgm-griller.agent.md" ]] && ! grep -qF -- "$MARKER" "$adir/wgm-griller.agent.md" \
   && [[ -f "$adir/wgm-extra.agent.md" ]] \
   && [[ -f "$adir/wgm-validator.agent.md" ]] && grep -qF -- "$MARKER" "$adir/wgm-validator.agent.md" \
   && ! grep -qxF 'wgm-hermes.agent.md' "$adir/.wgm-adapters"; then
  ok "B14 a source that dropped a role prunes only the marked stale file; a disowned and a foreign file both survive"
else
  bad "B14 stale-role pruning removed the wrong files in $adir"
fi

# ---- B15: a lost, partial, or interrupted receipt is still safe ------------
# An install killed between the copy and the receipt write leaves marked files and no list; a
# half-written list names fewer files. Neither may strand wgm's own files or endanger anyone else's.
h="$WORK/b15"; adir="$h/.copilot/agents"; mkdir -p "$h"
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot >/dev/null 2>&1
leftovers="$(find "$adir" -maxdepth 1 -name '.wgm-adapter*.tmp.*' -o -maxdepth 1 -name '.wgm-adapters.tmp.*' 2>/dev/null)"
printf -- '---\nname: My Own Agent\ndescription: not wgm\n---\nkeep me\n' > "$adir/my-team.agent.md"
printf 'partial\n' > "$adir/.wgm-adapter.tmp.999.wgm-validator.agent.md"   # an interrupted copy
rm -f "$adir/.wgm-adapters"                                                # ... and a lost receipt
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot >/dev/null 2>&1
recovered="$(count_files "$adir" '*.agent.md')"
head -n 4 "$adir/.wgm-adapters" > "$adir/.partial" && mv "$adir/.partial" "$adir/.wgm-adapters"
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot --uninstall >/dev/null 2>&1
if [[ -z "$leftovers" ]] \
   && [[ ! -e "$adir/.wgm-adapter.tmp.999.wgm-validator.agent.md" ]] \
   && [[ "$recovered" -eq "$(( $(count_files "$CANON_DIR" '*.agent.md') + 1 ))" ]] \
   && [[ "$(count_files "$adir" '*.agent.md')" -eq 1 && -f "$adir/my-team.agent.md" ]] \
   && [[ ! -e "$adir/.wgm-adapters" && -d "$adir" ]]; then
  ok "B15 a normal install leaves no temp files, a lost receipt is re-established, and a partial receipt still removes only marked files"
else
  bad "B15 interrupted-install handling misbehaved in $adir (leftovers: ${leftovers:-none})"
fi

# ---- B16: --force is the only way to take over a foreign file --------------
h="$WORK/b16"; adir="$h/.copilot/agents"; mkdir -p "$adir"
printf -- '---\nname: Someone Elses Validator\ndescription: not wgm\n---\nkeep me\n' > "$adir/wgm-validator.agent.md"
printf -- '---\nname: My Own Agent\ndescription: not wgm\n---\nkeep me too\n' > "$adir/my-team.agent.md"
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot --force >/dev/null 2>&1
forced_ok=0
if [[ "$(name_of "$adir/wgm-validator.agent.md")" == "WGM Validator" ]] \
   && grep -qF -- "$MARKER" "$adir/wgm-validator.agent.md" \
   && grep -qxF 'wgm-validator.agent.md' "$adir/.wgm-adapters"; then forced_ok=1; fi
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot --uninstall >/dev/null 2>&1
if [[ "$forced_ok" -eq 1 ]] \
   && [[ ! -e "$adir/wgm-validator.agent.md" ]] \
   && [[ -f "$adir/my-team.agent.md" ]]; then
  ok "B16 --force replaces a foreign name collision, stamps and records the replacement, and uninstall takes it back out"
else
  bad "B16 --force takeover or its later removal did not behave in $adir"
fi

# ---- B17: quoting the marker token is not ownership ------------------------
# The token is a public string: it appears in wgm's own docs, and any agent file may quote it. Only
# a marker in the terminal position, naming this host and this file's canonical source, is proof.
h="$WORK/b17"; adir="$h/.copilot/agents"; mkdir -p "$adir"
{
  printf -- '---\nname: Our House Style\ndescription: documents how we handle wgm\n---\n'
  printf 'We do not install wgm adapters here. For reference, wgm stamps its own files with a\n'
  printf '%s comment that looks like this:\n\n' "$MARKER"
  printf '<!-- %s host=copilot source=.github/agents/wgm-validator.agent.md version=1 -->\n\n' "$MARKER"
  printf 'This file is ours, hand-written, and ends with this sentence.\n'
} > "$adir/wgm-validator.agent.md"
b17_before="$(cksum < "$adir/wgm-validator.agent.md")"
out="$(HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot 2>&1)"
b17_after="$(cksum < "$adir/wgm-validator.agent.md")"
b17_listed=0; grep -qxF 'wgm-validator.agent.md' "$adir/.wgm-adapters" && b17_listed=1
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot --uninstall >/dev/null 2>&1
if [[ "$b17_before" == "$b17_after" ]] \
   && [[ "$(cksum < "$adir/wgm-validator.agent.md")" == "$b17_before" ]] \
   && [[ "$b17_listed" -eq 0 ]] \
   && contains "$out" "exists and is not wgm's" \
   && [[ "$(count_files "$adir" '*.agent.md')" -eq 1 ]]; then
  ok "B17 a foreign file that quotes the marker token in prose is neither adopted, rewritten, claimed, nor removed"
else
  bad "B17 prose containing the ownership token was treated as ownership in $adir"
fi

# ---- B18: a shared or symlinked agent directory keeps its hosts apart ------
# ~/.copilot/agents and ~/.claude/agents are not guaranteed to be different directories: operators
# symlink them together, and Claude's `*.md` glob also matches Copilot's `*.agent.md` files. A path
# may only ever be processed by its own host's marker, so neither install nor uninstall may reach
# across — and a marker copied from the other host proves nothing at all.
h="$WORK/b18"; shared="$WORK/b18-shared/agents"; mkdir -p "$shared" "$h/.copilot" "$h/.claude"
ln -s "$shared" "$h/.copilot/agents"
ln -s "$shared" "$h/.claude/agents"
printf -- '---\nname: Ours\ndescription: not wgm\n---\nbody\n<!-- %s host=claude source=adapters/claude/agents/wgm-hermes.md version=1 -->\n' \
  "$MARKER" > "$shared/wgm-hermes.agent.md"
b18_foreign="$(cksum < "$shared/wgm-hermes.agent.md")"
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client claude >/dev/null 2>&1
# Copilot installs last, so the single shared receipt is Copilot's index. Claude must neither read
# it (its entries name files Claude does not own) nor delete it (it is Copilot's record).
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot >/dev/null 2>&1
claude_files() { find "$1" -maxdepth 1 -name '*.md' ! -name '*.agent.md' 2>/dev/null | wc -l | tr -d ' '; }
b18_cop_installed="$(count_files "$shared" '*.agent.md')"
b18_cla_installed="$(claude_files "$shared")"
out="$(HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client claude --uninstall 2>&1)"
b18_cop_after="$(count_files "$shared" '*.agent.md')"
b18_cla_after="$(claude_files "$shared")"
b18_receipt_kept=0
[[ -f "$shared/.wgm-adapters" ]] && grep -q 'host=copilot' "$shared/.wgm-adapters" && b18_receipt_kept=1
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot --uninstall >/dev/null 2>&1
if [[ "$b18_cop_installed" -eq "$(count_files "$CANON_DIR" '*.agent.md')" ]] \
   && [[ "$b18_cla_installed" -eq "$(count_files "$CLAUDE_DIR" '*.md')" ]] \
   && [[ "$b18_cop_after" -eq "$b18_cop_installed" && "$b18_cla_after" -eq 0 ]] \
   && [[ "$b18_receipt_kept" -eq 1 ]] \
   && contains "$out" "leaving another host's adapter receipt in place" \
   && [[ ! -e "$shared/.wgm-adapters" ]] \
   && [[ "$(count_files "$shared" '*.agent.md')" -eq 1 && "$(claude_files "$shared")" -eq 0 ]] \
   && [[ -f "$shared/wgm-hermes.agent.md" ]] \
   && [[ "$(cksum < "$shared/wgm-hermes.agent.md")" == "$b18_foreign" ]] \
   && [[ -d "$shared" ]]; then
  ok "B18 a shared Copilot/Claude directory: each host removes only its own marked files and its own receipt, and a copied wrong-host marker is never claimed"
else
  bad "B18 cross-host confusion in the shared agent dir $shared (copilot $b18_cop_installed->$b18_cop_after, claude $b18_cla_installed->$b18_cla_after)"
fi

# ---- B19: the marker must be terminal and must name this file --------------
# A marker buried above the operator's own trailing text is not a claim on that text, and a marker
# copied from another role names a source this file is not. Meanwhile a genuine adapter that a
# Windows tool rewrote with CRLF endings and trailing blank lines is still, unmistakably, wgm's.
h="$WORK/b19"; adir="$h/.copilot/agents"; mkdir -p "$adir"
fake_marker() { printf '<!-- %s host=copilot source=%s version=1 — installed by wgm. -->' "$MARKER" "$1"; }
{ printf -- '---\nname: Ours A\ndescription: not wgm\n---\nbody\n'
  fake_marker '.github/agents/wgm-validator.agent.md'
  printf '\nour own trailing note, added after the comment\n'; } > "$adir/wgm-validator.agent.md"
{ printf -- '---\nname: Ours B\ndescription: not wgm\n---\nbody\n'
  fake_marker '.github/agents/wgm-implementer.agent.md'
  printf '\n'; } > "$adir/wgm-hermes.agent.md"
b19_a="$(cksum < "$adir/wgm-validator.agent.md")"
b19_b="$(cksum < "$adir/wgm-hermes.agent.md")"
out="$(HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot 2>&1)"
b19_listed=0
grep -qxF 'wgm-validator.agent.md' "$adir/.wgm-adapters" && b19_listed=1
grep -qxF 'wgm-hermes.agent.md' "$adir/.wgm-adapters" && b19_listed=1
# A real adapter, mangled into CRLF with blank lines after the marker, must survive as wgm's own.
sed 's/$/\r/' "$adir/wgm-griller.agent.md" > "$adir/.crlf" && printf '\r\n\r\n' >> "$adir/.crlf" \
  && mv "$adir/.crlf" "$adir/wgm-griller.agent.md"
HOME="$h" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client copilot --uninstall >/dev/null 2>&1
if [[ "$b19_listed" -eq 0 ]] \
   && contains "$out" "exists and is not wgm's" \
   && [[ "$(cksum < "$adir/wgm-validator.agent.md")" == "$b19_a" ]] \
   && [[ "$(cksum < "$adir/wgm-hermes.agent.md")" == "$b19_b" ]] \
   && [[ ! -e "$adir/wgm-griller.agent.md" ]] \
   && [[ "$(count_files "$adir" '*.agent.md')" -eq 2 ]]; then
  ok "B19 a non-terminal or wrong-source marker is not ownership, while a CRLF-mangled genuine marker still is"
else
  bad "B19 marker position/source validation misbehaved in $adir"
fi

echo ""
echo "agent-adapter tests: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -eq 0 ]]; then echo "agent-adapters: GREEN"; exit 0; else echo "agent-adapters: RED" >&2; exit 1; fi
