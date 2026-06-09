#!/usr/bin/env bash
#
# wgm/install.sh — install the wgm Agent Skill into a skills directory.
#
# Installs the skill folder as <skills-dir>/wgm so a skills-compatible agent (Claude, Copilot CLI,
# VS Code agent mode, or any .agents/skills client) can discover it. Defaults to a USER-level
# (global) install, so wgm is available across all your projects — not just the current one.
#
# Usage:
#   ./scripts/install.sh [flags]
#
# Flags:
#   --user            install into your home dir (DEFAULT): ~/.agents/skills/wgm (+ detected clients)
#   --project         install into the current project:     ./.agents/skills/wgm (+ ./.claude)
#   --client NAME     agents | claude | copilot | all | auto   (default: auto)
#                       auto = agents + any client whose home dir exists (~/.claude, ~/.copilot)
#                       all  = agents + claude + copilot
#   --dir PATH        install into PATH/wgm explicitly (overrides --user/--project/--client)
#   --method M        copy | symlink   (default: copy)
#   --dry-run         print what would happen; change nothing
#   --uninstall       remove the wgm skill from the resolved targets
#   --force           overwrite/replace an existing install
#   --ref REF         git ref (branch/tag/sha) to self-fetch when piped (default: main)
#   -h | --help       show this help
#
# Self-fetch: when run via `curl … | bash` with no local checkout, the script downloads the repo
# itself. Override the source with env vars:
#   WGM_REPO          owner/name to fetch        (default: agent-frontier/wgm)
#   WGM_REF           branch/tag/sha to fetch    (default: main; same as --ref)
#   WGM_TARBALL_URL   explicit .tar.gz URL       (advanced/offline; e.g. file://…)
#
# Supported OS: Linux, macOS, and WSL. On native Windows PowerShell, use scripts/install.ps1.

set -euo pipefail

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

# ----- resolve source (repo root = parent of this script's dir) -------------
# In "clone mode" the skill tree sits next to this script. When piped (curl … | bash) there is no
# local file, so SRC_DIR stays empty and we self-fetch later ("bootstrap mode").
SRC_DIR=""
_self="${BASH_SOURCE[0]:-}"
if [[ -n "$_self" && -f "$_self" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"
  _candidate="$(cd "$SCRIPT_DIR/.." && pwd)"
  [[ -f "$_candidate/SKILL.md" ]] && SRC_DIR="$_candidate"
fi

# ----- defaults -------------------------------------------------------------
SCOPE="user"
CLIENT="auto"
EXPLICIT_DIR=""
METHOD="copy"
DRY_RUN=0
UNINSTALL=0
FORCE=0
WGM_REPO="${WGM_REPO:-agent-frontier/wgm}"
WGM_REF="${WGM_REF:-main}"
WGM_TARBALL_URL="${WGM_TARBALL_URL:-}"

# ----- parse args -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)      SCOPE="user"; shift ;;
    --project)   SCOPE="project"; shift ;;
    --client)    [[ $# -ge 2 ]] || { echo "--client requires a name" >&2; exit 2; }; CLIENT="$2"; shift 2 ;;
    --dir)       [[ $# -ge 2 ]] || { echo "--dir requires a path" >&2; exit 2; }; EXPLICIT_DIR="$2"; shift 2 ;;
    --method)    [[ $# -ge 2 ]] || { echo "--method requires copy|symlink" >&2; exit 2; }; METHOD="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --force)     FORCE=1; shift ;;
    --ref)       [[ $# -ge 2 ]] || { echo "--ref requires a value" >&2; exit 2; }; WGM_REF="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$CLIENT" in agents|claude|copilot|all|auto) ;; *) echo "Invalid --client: $CLIENT" >&2; exit 2 ;; esac
case "$METHOD" in copy|symlink) ;; *) echo "Invalid --method: $METHOD" >&2; exit 2 ;; esac

# ----- resolve / fetch source ----------------------------------------------
BOOTSTRAP=0
TMP_FETCH=""
_cleanup_fetch() { [[ -n "$TMP_FETCH" && -d "$TMP_FETCH" ]] && rm -rf "$TMP_FETCH"; }

fetch_source() {
  # Download the wgm repo into $1 and set SRC_DIR to the extracted skill root (the dir with SKILL.md).
  local dest="$1"
  local url="${WGM_TARBALL_URL:-https://codeload.github.com/$WGM_REPO/tar.gz/$WGM_REF}"
  printf '%s\n' "  fetching: $WGM_REPO@$WGM_REF" >&2
  local got=0
  if command -v tar >/dev/null 2>&1; then
    if command -v curl >/dev/null 2>&1; then
      if curl -fsSL "$url" | tar -xz -C "$dest"; then got=1; fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -qO- "$url" | tar -xz -C "$dest"; then got=1; fi
    fi
  fi
  if [[ "$got" -eq 1 ]]; then
    # A GitHub codeload tarball unpacks to a single <repo>-<ref>/ wrapper dir.
    local d
    for d in "$dest"/*/; do
      [[ -d "$d" ]] || continue
      if [[ -f "${d}SKILL.md" ]]; then SRC_DIR="${d%/}"; return 0; fi
    done
    if [[ -f "$dest/SKILL.md" ]]; then SRC_DIR="$dest"; return 0; fi
  fi
  # Fallback: shallow git clone (handles odd tarball layouts or a missing curl/tar).
  if command -v git >/dev/null 2>&1; then
    printf '%s\n' "  tarball fetch unavailable — trying git clone" >&2
    if git clone --depth 1 --branch "$WGM_REF" "https://github.com/$WGM_REPO" "$dest/clone" >/dev/null 2>&1; then
      if [[ -f "$dest/clone/SKILL.md" ]]; then SRC_DIR="$dest/clone"; return 0; fi
    fi
  fi
  echo "Failed to fetch wgm ($WGM_REPO@$WGM_REF)." >&2
  echo "  tried tarball: $url" >&2
  echo "Install from a clone instead: git clone https://github.com/$WGM_REPO && cd \"\${WGM_REPO##*/}\" && ./scripts/install.sh" >&2
  exit 1
}

if [[ -n "$SRC_DIR" ]]; then
  : # clone mode — local skill tree found next to this script
elif [[ "$UNINSTALL" -eq 1 ]]; then
  : # uninstall removes target dirs only; no source tree needed
else
  # Bootstrap mode: piped (e.g. curl … | bash) with no local checkout — self-fetch the repo.
  BOOTSTRAP=1
  if [[ "$METHOD" == "symlink" ]]; then
    echo "note: --method symlink ignored in bootstrap mode (no local checkout) — using copy." >&2
    METHOD="copy"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    SRC_DIR="<fetched $WGM_REPO@$WGM_REF>"   # preview only — no network in a dry run
  else
    trap _cleanup_fetch EXIT
    TMP_FETCH="$(mktemp -d "${TMPDIR:-/tmp}/wgm-install.XXXXXX")"
    fetch_source "$TMP_FETCH"
  fi
fi

# ----- environment ----------------------------------------------------------
HOME_DIR="${HOME:-$(cd ~ && pwd)}"
IS_WSL=0
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
  IS_WSL=1
fi

# ----- resolve client list --------------------------------------------------
CLIENTS=()
case "$CLIENT" in
  agents)  CLIENTS=(agents) ;;
  claude)  CLIENTS=(claude) ;;
  copilot) CLIENTS=(copilot) ;;
  all)     CLIENTS=(agents claude copilot) ;;
  auto)
    CLIENTS=(agents)
    [[ -d "$HOME_DIR/.claude"  ]] && CLIENTS+=(claude)
    [[ -d "$HOME_DIR/.copilot" ]] && CLIENTS+=(copilot)
    ;;
esac

# ----- compute target dirs --------------------------------------------------
TARGETS=()
if [[ -n "$EXPLICIT_DIR" ]]; then
  TARGETS+=("${EXPLICIT_DIR%/}/wgm")
else
  if [[ "$SCOPE" == "user" ]]; then BASE="$HOME_DIR"; else BASE="$(pwd)"; fi
  for c in "${CLIENTS[@]}"; do
    if [[ "$SCOPE" == "project" && "$c" == "copilot" ]]; then
      echo "note: Copilot CLI has no project-level skills dir; .agents/skills covers it — skipping copilot for --project." >&2
      continue
    fi
    TARGETS+=("$BASE/.$c/skills/wgm")
  done
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No install targets resolved." >&2
  exit 1
fi

# ----- helpers --------------------------------------------------------------
say() { printf '%s\n' "$*"; }

copy_tree() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude='.git' "$src"/ "$dst"/
  else
    cp -R "$src"/. "$dst"/
    rm -rf "$dst/.git"
  fi
}

install_one() {
  local target="$1"
  local parent
  parent="$(dirname "$target")"
  if [[ -e "$target" || -L "$target" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
      say "  replacing existing: $target"
      [[ "$DRY_RUN" -eq 1 ]] || rm -rf "$target"
    else
      say "  exists — skipping (use --force to replace): $target"
      return 0
    fi
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$METHOD" == "symlink" ]]; then say "  would symlink: $target -> $SRC_DIR"
    else say "  would copy:    $SRC_DIR -> $target (excluding .git)"; fi
    return 0
  fi
  mkdir -p "$parent"
  if [[ "$METHOD" == "symlink" ]]; then
    ln -sfn "$SRC_DIR" "$target"
  else
    copy_tree "$SRC_DIR" "$target"
  fi
  say "  installed: $target"
}

uninstall_one() {
  local target="$1"
  case "$target" in
    */skills/wgm) ;;
    *) echo "  refusing to remove unexpected path: $target" >&2; return 0 ;;
  esac
  if [[ -e "$target" || -L "$target" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then say "  would remove: $target"
    else rm -rf "$target"; say "  removed: $target"; fi
  else
    say "  not present: $target"
  fi
}

# ----- run ------------------------------------------------------------------
say "wgm installer"
if [[ -n "$SRC_DIR" ]]; then say "  source : $SRC_DIR"; else say "  source : (none — uninstall)"; fi
[[ "$BOOTSTRAP" -eq 1 ]] && say "  fetched: $WGM_REPO@$WGM_REF"
say "  scope  : $SCOPE"
say "  client : $CLIENT"
say "  method : $METHOD"
[[ "$IS_WSL" -eq 1 ]] && say "  note   : WSL detected — WSL and Windows have separate homes; installing into the Linux/WSL home."
[[ "$DRY_RUN" -eq 1 ]] && say "  (dry run — no changes will be made)"
say ""

if [[ "$UNINSTALL" -eq 1 ]]; then
  say "Uninstalling wgm from:"
  for t in "${TARGETS[@]}"; do uninstall_one "$t"; done
else
  say "Installing wgm to:"
  for t in "${TARGETS[@]}"; do install_one "$t"; done
fi

say ""
say "Done. Targets:"
for t in "${TARGETS[@]}"; do say "  - $t"; done
say ""
say "Verify your agent can see it (e.g. /skills in VS Code or Copilot CLI), then invoke /wgm."
