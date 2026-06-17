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
#   --no-windows      (WSL only) do NOT mirror into your Windows home
#   --windows-home P  (WSL only) mirror into Windows home P (default: auto-detect via /mnt)
#   --ref REF         ref to self-fetch when piped: a branch/tag/sha, or "latest" for the newest
#                       published release (default: main)
#   -h | --help       show this help
#
# Self-fetch: when run via `curl … | bash` with no local checkout, the script downloads the repo
# itself. Override the source with env vars:
#   WGM_REPO          owner/name to fetch        (default: agent-frontier/wgm)
#   WGM_REF           branch/tag/sha or "latest" (default: main; same as --ref). A tag (vX.Y[.Z]) or
#                       "latest" installs the matching GitHub *release* tarball published by the
#                       release CI; any other ref uses the codeload source tarball.
#   WGM_TARBALL_URL   explicit .tar.gz URL       (advanced/offline; e.g. file://…)
#   WGM_WINDOWS_HOME  WSL: Windows home to mirror into (same as --windows-home)
#
# WSL bridge: inside WSL this ALSO mirrors the skill into your Windows home (reachable at
# /mnt/c/Users/…) so native-Windows agents see wgm too. Re-running updates a prior wgm install in
# place (no --force needed) and adds the mirror. Disable with --no-windows. Advanced/testing
# overrides: WGM_FORCE_WSL=0|1 (force WSL detection) and WGM_WIN_AUTODETECT=0|1 (toggle Windows-home
# autodetect).
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
NO_WINDOWS=0
WINDOWS_HOME="${WGM_WINDOWS_HOME:-}"
WIN_UNRESOLVED=0
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
    --no-windows)   NO_WINDOWS=1; shift ;;
    --windows-home) [[ $# -ge 2 ]] || { echo "--windows-home requires a path" >&2; exit 2; }; WINDOWS_HOME="$2"; shift 2 ;;
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

# Resolve the archive URL for the current WGM_REPO/WGM_REF. An explicit WGM_TARBALL_URL always wins.
# A *released* ref — the literal "latest", or a vX.Y[.Z] tag — resolves to the release ASSET the
# release CI publishes, so the validated tarball is what gets installed; any other ref (a branch or
# sha, including the default "main") uses the codeload source tarball. Echoes the URL.
resolve_source_url() {
  if [[ -n "$WGM_TARBALL_URL" ]]; then printf '%s\n' "$WGM_TARBALL_URL"; return 0; fi
  case "$WGM_REF" in
    latest)  printf '%s\n' "https://github.com/$WGM_REPO/releases/latest/download/wgm.tar.gz" ;;
    v[0-9]*) printf '%s\n' "https://github.com/$WGM_REPO/releases/download/$WGM_REF/wgm-$WGM_REF.tar.gz" ;;
    *)       printf '%s\n' "https://codeload.github.com/$WGM_REPO/tar.gz/$WGM_REF" ;;
  esac
}

# Download $1 (a .tar.gz URL) into $2 and, on success, point SRC_DIR at the extracted skill root —
# handling both a codeload <repo>-<ref>/ wrapper and a flat release tarball (SKILL.md at the top).
# Returns non-zero on any fetch/unpack miss so the caller can try the next candidate.
_extract_into() {
  local url="$1" dest="$2" got=0
  command -v tar >/dev/null 2>&1 || return 1
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" | tar -xz -C "$dest" && got=1
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url" | tar -xz -C "$dest" && got=1
  fi
  [[ "$got" -eq 1 ]] || return 1
  local d
  for d in "$dest"/*/; do
    [[ -d "$d" && -f "${d}SKILL.md" ]] || continue
    SRC_DIR="${d%/}"; return 0
  done
  [[ -f "$dest/SKILL.md" ]] && { SRC_DIR="$dest"; return 0; }
  return 1
}

fetch_source() {
  # Download the wgm repo into $1 and set SRC_DIR to the extracted skill root (the dir with SKILL.md).
  local dest="$1"
  printf '%s\n' "  fetching: $WGM_REPO@$WGM_REF" >&2
  # Candidate URLs, tried in order. For a tag the release asset is preferred, with the codeload
  # source tarball as a fallback (e.g. a tag pushed before its release finished publishing).
  local urls=() u i=0
  urls+=("$(resolve_source_url)")
  if [[ "$WGM_REF" != "latest" ]]; then
    local cl="https://codeload.github.com/$WGM_REPO/tar.gz/$WGM_REF"
    if [[ "${urls[0]}" != "$cl" ]]; then urls+=("$cl"); fi
  fi
  for u in "${urls[@]}"; do
    local sub="$dest/try$i"; i=$((i + 1)); mkdir -p "$sub"
    printf '%s\n' "  trying: $u" >&2
    if _extract_into "$u" "$sub"; then return 0; fi
    rm -rf "$sub"
  done
  # Fallback: shallow git clone (handles a missing curl/tar or an odd layout). "latest" is not a ref.
  if [[ "$WGM_REF" != "latest" ]] && command -v git >/dev/null 2>&1; then
    printf '%s\n' "  archive fetch unavailable — trying git clone" >&2
    if git clone --depth 1 --branch "$WGM_REF" "https://github.com/$WGM_REPO" "$dest/clone" >/dev/null 2>&1; then
      if [[ -f "$dest/clone/SKILL.md" ]]; then SRC_DIR="$dest/clone"; return 0; fi
    fi
  fi
  echo "Failed to fetch wgm ($WGM_REPO@$WGM_REF)." >&2
  echo "  tried: ${urls[*]}" >&2
  if [[ "$WGM_REF" == "latest" ]]; then
    echo "  (no published release yet? install bleeding-edge with WGM_REF=main)" >&2
  fi
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
    printf '%s\n' "  would fetch: $(resolve_source_url)" >&2
  else
    trap _cleanup_fetch EXIT
    TMP_FETCH="$(mktemp -d "${TMPDIR:-/tmp}/wgm-install.XXXXXX")"
    fetch_source "$TMP_FETCH"
  fi
fi

# ----- environment ----------------------------------------------------------
HOME_DIR="${HOME:-$(cd ~ && pwd)}"
IS_WSL=0
if [[ -n "${WGM_FORCE_WSL:-}" ]]; then
  IS_WSL="${WGM_FORCE_WSL}"          # explicit override (advanced/testing)
elif grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
  IS_WSL=1
fi

# Resolve the WSL path to the Windows user profile so we can mirror the skill there. Echoes the path
# on success, or nothing if it can't be resolved. Order: explicit override → cmd.exe → wslvar → scan.
resolve_win_home() {
  local up="" wp="" drive rest d base
  if [[ -n "$WINDOWS_HOME" ]]; then printf '%s' "${WINDOWS_HOME%/}"; return 0; fi
  [[ "${WGM_WIN_AUTODETECT:-1}" == "0" ]] && return 0
  if command -v cmd.exe >/dev/null 2>&1; then
    up="$( { cd /mnt/c 2>/dev/null && cmd.exe /c 'echo %USERPROFILE%'; } 2>/dev/null | tr -d '\r\n' || true )"
  fi
  if [[ -z "$up" ]] && command -v wslvar >/dev/null 2>&1; then
    up="$( wslvar USERPROFILE 2>/dev/null | tr -d '\r\n' || true )"
  fi
  if [[ -n "$up" ]]; then
    if command -v wslpath >/dev/null 2>&1; then
      wp="$( wslpath -u "$up" 2>/dev/null || true )"
    else
      drive="$( printf '%s' "$up" | cut -c1 | tr '[:upper:]' '[:lower:]' )"
      rest="$( printf '%s' "$up" | cut -c3- | tr '\134' '/' )"
      wp="/mnt/${drive}${rest}"
    fi
  fi
  if [[ -z "$wp" || ! -d "$wp" ]]; then
    wp=""
    if [[ -d /mnt/c/Users ]]; then
      for d in /mnt/c/Users/*/; do
        base="$( basename "$d" )"
        case "$base" in Public|Default|"Default User"|"All Users"|defaultuser0) continue ;; esac
        if [[ "$base" == "${USER:-}" || -d "${d}.agents" || -d "${d}.claude" || -d "${d}.copilot" ]]; then
          wp="${d%/}"; break
        fi
      done
    fi
  fi
  [[ -n "$wp" && -d "$wp" ]] && printf '%s' "${wp%/}"
  return 0
}

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

# ----- compute Windows-mirror targets (WSL only, user scope) ----------------
WIN_TARGETS=()
WIN_HOME=""
if [[ -z "$EXPLICIT_DIR" && "$SCOPE" == "user" && "$IS_WSL" -eq 1 && "$NO_WINDOWS" -eq 0 ]]; then
  WIN_HOME="$(resolve_win_home)"
  if [[ -n "$WIN_HOME" ]]; then
    WIN_CLIENTS=()
    case "$CLIENT" in
      agents)  WIN_CLIENTS=(agents) ;;
      claude)  WIN_CLIENTS=(claude) ;;
      copilot) WIN_CLIENTS=(copilot) ;;
      all)     WIN_CLIENTS=(agents claude copilot) ;;
      auto)
        WIN_CLIENTS=(agents)
        [[ -d "$WIN_HOME/.claude"  ]] && WIN_CLIENTS+=(claude)
        [[ -d "$WIN_HOME/.copilot" ]] && WIN_CLIENTS+=(copilot)
        ;;
    esac
    for c in "${WIN_CLIENTS[@]}"; do
      WIN_TARGETS+=("$WIN_HOME/.$c/skills/wgm")
    done
  else
    WIN_UNRESOLVED=1
  fi
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

is_wgm_install() {
  # True if $1 already holds a wgm skill (its SKILL.md frontmatter says name: wgm). Follows symlinks.
  [[ -f "$1/SKILL.md" ]] || return 1
  grep -qE '^[[:space:]]*name:[[:space:]]*wgm[[:space:]]*$' "$1/SKILL.md" 2>/dev/null
}

install_one() {
  local target="$1"
  local method="${2:-$METHOD}"
  local parent
  parent="$(dirname "$target")"
  if [[ -e "$target" || -L "$target" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
      say "  replacing existing: $target"
      [[ "$DRY_RUN" -eq 1 ]] || rm -rf "$target"
    elif is_wgm_install "$target"; then
      say "  updating existing wgm install: $target"
      [[ "$DRY_RUN" -eq 1 ]] || rm -rf "$target"
    else
      say "  exists — skipping (use --force to replace): $target"
      return 0
    fi
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$method" == "symlink" ]]; then say "  would symlink: $target -> $SRC_DIR"
    else say "  would copy:    $SRC_DIR -> $target (excluding .git)"; fi
    return 0
  fi
  mkdir -p "$parent"
  if [[ "$method" == "symlink" ]]; then
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
if [[ "$IS_WSL" -eq 1 ]]; then
  if [[ ${#WIN_TARGETS[@]} -gt 0 ]]; then
    say "  note   : WSL detected — also mirroring into your Windows home ($WIN_HOME) so Windows-side agents see wgm (use --no-windows to skip)."
  elif [[ "$NO_WINDOWS" -eq 1 ]]; then
    say "  note   : WSL detected — Windows mirror disabled (--no-windows); installing into the Linux/WSL home only."
  elif [[ "$WIN_UNRESOLVED" -eq 1 ]]; then
    say "  note   : WSL detected — could not resolve your Windows home; installing on the Linux side only (pass --windows-home PATH to mirror to Windows)."
  fi
fi
[[ "$DRY_RUN" -eq 1 ]] && say "  (dry run — no changes will be made)"
say ""

if [[ "$UNINSTALL" -eq 1 ]]; then
  say "Uninstalling wgm from:"
  for t in "${TARGETS[@]}"; do uninstall_one "$t"; done
  if [[ ${#WIN_TARGETS[@]} -gt 0 ]]; then
    for t in "${WIN_TARGETS[@]}"; do uninstall_one "$t"; done
  fi
else
  say "Installing wgm to:"
  for t in "${TARGETS[@]}"; do install_one "$t" "$METHOD"; done
  if [[ ${#WIN_TARGETS[@]} -gt 0 ]]; then
    for t in "${WIN_TARGETS[@]}"; do install_one "$t" copy; done
  fi
fi

say ""
say "Done. Targets:"
for t in "${TARGETS[@]}"; do say "  - $t"; done
if [[ ${#WIN_TARGETS[@]} -gt 0 ]]; then
  for t in "${WIN_TARGETS[@]}"; do say "  - $t  (windows mirror)"; done
fi
say ""
say "Verify your agent can see it (e.g. /skills in VS Code or Copilot CLI), then invoke /wgm."
