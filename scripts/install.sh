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
#   --dir PATH        install into PATH/wgm explicitly (overrides --user/--project/--client).
#                       Skill only — a bare path names no host, so no role adapters are installed.
#   --method M        copy | symlink   (default: copy)
#   --dry-run         print what would happen; change nothing
#   --uninstall       remove the wgm skill from the resolved targets
#   --force           overwrite/replace an existing install
#   --no-companions   do NOT install the teach-me / quiz-me / rugged companion skills alongside wgm
#   --no-agents       do NOT install the role-agent adapters (.github/agents, .claude/agents); the
#                       portable skill and its explicit inline fallback still install
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
# Role-agent adapters: wgm's twelve role subagents are authored once in the Copilot custom-agent
# format and derived per host by scripts/sync-agent-adapters.sh (see compatibility/agent-adapters.json).
# When a host client is selected, this installer also drops that host's role files where the host
# actually scans for them:
#   copilot  user -> ~/.copilot/agents/     project -> .github/agents/
#   claude   user -> ~/.claude/agents/      project -> .claude/agents/
# The generic `.agents` client gets NO adapters: the Agent Skills standard defines skills, not
# subagents, so wgm falls back to scripts/audit.sh and inline sequential review passes there.
# Ownership is proven, never inferred: every adapter wgm writes ends with a `wgm-role-agent-adapter`
# marker comment naming the host, the canonical source file, and the adapter version. Ownership is
# structural, not textual — the marker must be the file's LAST non-blank line (CRLF tolerated), and
# its `host=` and `source=` must be exactly this host and the canonical path for that basename. A
# file that merely quotes the token in prose, carries another host's marker, or names another role's
# source is somebody else's file: it is never refreshed, pruned, removed, or listed in the receipt.
# A path is only ever processed by its own host. The per-directory `.wgm-adapters` receipt is a
# convenience index (written atomically, host-stamped), not the proof. A source directory that ships
# no roles at all is read as incomplete (truncated download, bad ref), so it installs nothing and
# prunes nothing; only an explicit uninstall removes a whole set.
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
NO_COMPANIONS=0
NO_AGENTS=0
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
    --no-companions) NO_COMPANIONS=1; shift ;;
    --no-agents) NO_AGENTS=1; shift ;;
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

# ----- compute role-adapter target dirs -------------------------------------
# A role adapter only makes sense where a host actually scans for one. `agents` (the Agent Skills
# standard) has no subagent format, and `--dir` names a bare path rather than a host, so neither
# gets an adapter — they get the portable skill and wgm's explicit inline fallback instead.
AGENT_HOSTS=()
AGENT_DIRS=()
AGENT_NOTES=()

adapter_dir_for() {
  # $1 = client id, $2 = base dir, $3 = scope. Echoes the host's agent dir, or nothing.
  case "$1:$3" in
    copilot:user)    printf '%s\n' "$2/.copilot/agents" ;;
    copilot:project) printf '%s\n' "$2/.github/agents" ;;
    claude:user)     printf '%s\n' "$2/.claude/agents" ;;
    claude:project)  printf '%s\n' "$2/.claude/agents" ;;
  esac
}

collect_agent_targets() {
  # $1 = base dir, $2 = scope, then the client ids. Appends to AGENT_HOSTS/AGENT_DIRS.
  local base="$1" scope="$2"; shift 2
  local c d
  for c in "$@"; do
    d="$(adapter_dir_for "$c" "$base" "$scope")"
    [[ -n "$d" ]] || continue
    AGENT_HOSTS+=("$c")
    AGENT_DIRS+=("$d")
  done
}

if [[ "$NO_AGENTS" -eq 0 ]]; then
  if [[ -n "$EXPLICIT_DIR" ]]; then
    AGENT_NOTES+=("--dir installs the skill only: a bare path names no host, so no agent scan path can be guessed. Re-run with --user or --project and --client copilot|claude|all to install the role adapters.")
  else
    if [[ "$SCOPE" == "user" ]]; then AGENT_BASE="$HOME_DIR"; else AGENT_BASE="$(pwd)"; fi
    collect_agent_targets "$AGENT_BASE" "$SCOPE" "${CLIENTS[@]}"
    for c in "${CLIENTS[@]}"; do
      [[ "$c" == "agents" ]] || continue
      AGENT_NOTES+=("the .agents client gets no role adapters: the Agent Skills standard defines skills, not subagents. wgm falls back to scripts/audit.sh and inline sequential review passes there.")
    done
  fi
fi

# A skills target is not the only reason to run: `--project --client copilot` resolves no skills
# directory (Copilot has none at project level) but still has real work to do in .github/agents.
if [[ ${#TARGETS[@]} -eq 0 && ${#AGENT_DIRS[@]} -eq 0 ]]; then
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
    if [[ "$NO_AGENTS" -eq 0 ]]; then
      collect_agent_targets "$WIN_HOME" user "${WIN_CLIENTS[@]}"
    fi
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

# Companion skills ship beside wgm as their own sibling skill dirs, because a skills client
# discovers one skill per directory: companions/teach-me -> <skills-dir>/teach-me.
COMPANIONS=(teach-me quiz-me rugged)

is_companion_install() {  # $1 = dir, $2 = companion name
  [[ -f "$1/SKILL.md" ]] || return 1
  grep -qE "^[[:space:]]*name:[[:space:]]*$2[[:space:]]*$" "$1/SKILL.md" 2>/dev/null
}

# Companion targets are derived from wgm's own: <skills-dir>/wgm -> <skills-dir>/<companion>.
companion_targets_for() {
  local wgm_target="$1" parent name
  parent="$(dirname "$wgm_target")"
  for name in "${COMPANIONS[@]}"; do printf '%s/%s\n' "$parent" "$name"; done
}

install_companions() {
  local wgm_target="$1" method="${2:-$METHOD}" name src target
  [[ "$NO_COMPANIONS" -eq 1 ]] && return 0
  for name in "${COMPANIONS[@]}"; do
    src="$SRC_DIR/companions/$name"
    target="$(dirname "$wgm_target")/$name"
    # An older wgm tarball has no companions/ dir; that is a skip, never an install failure.
    [[ -d "$src" ]] || { say "  companion not in this source, skipping: $name"; continue; }
    if [[ -e "$target" || -L "$target" ]]; then
      if [[ "$FORCE" -eq 1 ]]; then
        say "  replacing existing: $target"
        [[ "$DRY_RUN" -eq 1 ]] || rm -rf "$target"
      elif is_companion_install "$target" "$name"; then
        say "  updating existing $name install: $target"
        [[ "$DRY_RUN" -eq 1 ]] || rm -rf "$target"
      else
        say "  exists — skipping (use --force to replace): $target"
        continue
      fi
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      if [[ "$method" == "symlink" ]]; then say "  would symlink: $target -> $src"
      else say "  would copy:    $src -> $target"; fi
      continue
    fi
    mkdir -p "$(dirname "$target")"
    if [[ "$method" == "symlink" ]]; then ln -sfn "$src" "$target"; else copy_tree "$src" "$target"; fi
    say "  installed: $target"
  done
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
    */skills/wgm|*/skills/teach-me|*/skills/quiz-me|*/skills/rugged) ;;
    *) echo "  refusing to remove unexpected path: $target" >&2; return 0 ;;
  esac
  if [[ -e "$target" || -L "$target" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then say "  would remove: $target"
    else rm -rf "$target"; say "  removed: $target"; fi
  else
    say "  not present: $target"
  fi
}

# ----- role-agent adapters --------------------------------------------------
# Each host scans a flat directory of agent files that it does NOT own exclusively: your own agents
# live there too, and one of them may already carry a wgm role name. Name resemblance is therefore
# never evidence of ownership. wgm proves ownership instead: every file it writes ENDS with a marker
# comment carrying the token below plus the host, the canonical source file, and the adapter version.
#
# That proof is structural, not a substring search. A file is wgm's, for this host, only when:
#   * its basename is one of this host's adapter names (Claude never claims a `.agent.md` file), and
#   * its last non-blank line (trailing CR/whitespace stripped) IS the marker comment, and
#   * that marker's `host=` is this host, and its `source=` is the canonical path for that basename,
#     and it carries a non-empty `version=`.
# Anything else — prose that quotes the token, a marker buried mid-file, another host's marker copied
# in, a marker naming a different role — is somebody else's file. Nothing else in the directory is
# moved, rewritten, or deleted, and the directory itself is never removed.
#
# The host scoping matters because agent directories get shared: `~/.copilot/agents` may be a symlink
# to `~/.claude/agents`, and Claude's `*.md` glob also matches Copilot's `*.agent.md` files. A Claude
# marker must never read as Copilot ownership, so every check is asked about one specific host.
#
# The per-directory `.wgm-adapters` receipt is an index of what the last install wrote, written
# temp-then-rename so it is never half a list, and stamped with the host it describes. It narrows
# what wgm looks at; the marker is what authorises a delete. A missing, partial, or foreign-host
# receipt therefore loses no safety and creates no false claim: wgm can still recover its own files
# by their marker, and still cannot touch yours.
ADAPTER_RECEIPT=".wgm-adapters"
ADAPTER_MARKER="wgm-role-agent-adapter"   # ownership token; only ever written into files wgm creates
ADAPTER_TMP_PREFIX=".wgm-adapter.tmp."
ADAPTER_RECEIPT_TMP_PREFIX=".wgm-adapters.tmp."   # note the plural: NOT matched by the prefix above
ADAPTER_VERSION=""

adapter_version() {
  # The adapter manifest version travels with the source tree, so a stamped file records exactly
  # which mapping produced it. Unknown is honest when the manifest is absent (e.g. a partial source).
  local f v=""
  f="$SRC_DIR/compatibility/agent-adapters.json"
  if [[ -n "$SRC_DIR" && -f "$f" ]]; then
    v="$(sed -n 's/.*"manifest_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n 1)"
  fi
  printf '%s\n' "${v:-unknown}"
}

adapter_source_dir() {  # $1 = host id
  case "$1" in
    copilot) printf '%s\n' "$SRC_DIR/.github/agents" ;;
    claude)  printf '%s\n' "$SRC_DIR/adapters/claude/agents" ;;
  esac
}

adapter_glob_suffix() { case "$1" in copilot) printf '%s\n' ".agent.md" ;; claude) printf '%s\n' ".md" ;; esac; }

adapter_canonical_rel() {  # $1 = host id, $2 = basename — the source path recorded in the marker
  case "$1" in
    copilot) printf '%s\n' ".github/agents/$2" ;;
    claude)  printf '%s\n' "adapters/claude/agents/$2" ;;
  esac
}

adapter_name_for_host() {
  # True when basename $2 is one of host $1's adapter file names. Claude's suffix (`.md`) is a
  # superset of Copilot's (`.agent.md`), so Claude must explicitly disclaim Copilot's names: in a
  # shared or symlinked agent directory that difference is the whole cross-host boundary.
  case "$1" in
    copilot) [[ "$2" == *".agent.md" ]] ;;
    claude)  [[ "$2" == *".md" && "$2" != *".agent.md" ]] ;;
    *) return 1 ;;
  esac
}

adapter_marker_line() {
  # The last non-blank line of file $1, with a trailing CR and trailing blanks stripped. A host that
  # rewrote the file's newlines, or left blank lines after the marker, still reads correctly.
  [[ -f "$1" ]] || return 1
  awk '{ sub(/\r$/, ""); sub(/[[:space:]]+$/, ""); if ($0 ~ /[^[:space:]]/) last = $0 }
       END { if (last != "") print last }' "$1" 2>/dev/null
}

adapter_is_owned() {
  # True when file $1 is an adapter wgm wrote for host $2 — the only condition under which wgm may
  # refresh, prune, or delete it. Position and fields are both required, so a foreign file that
  # quotes the token in prose, buries a marker mid-file, carries another host's marker, or names a
  # different canonical source is never adopted.
  local file="$1" host="$2" base rel line ver
  [[ -f "$file" ]] || return 1
  base="$(basename "$file")"
  adapter_name_for_host "$host" "$base" || return 1
  rel="$(adapter_canonical_rel "$host" "$base")"
  [[ -n "$rel" ]] || return 1
  line="$(adapter_marker_line "$file")" || return 1
  [[ "$line" == "<!-- $ADAPTER_MARKER host=$host source=$rel version="* ]] || return 1
  [[ "$line" == *"-->" ]] || return 1
  ver="${line#*version=}"
  ver="${ver%%[[:space:]]*}"
  [[ -n "$ver" ]]
}

adapter_stamp_into() {
  # $1 = source file, $2 = dest, $3 = host, $4 = canonical source path.
  # Written temp-then-rename inside the destination directory: an interrupted install leaves either
  # the previous file or the complete new one, never a truncated agent definition.
  local src="$1" dest="$2" host="$3" rel="$4" dir base tmp
  dir="$(dirname "$dest")"; base="$(basename "$dest")"
  tmp="$dir/$ADAPTER_TMP_PREFIX$$.$base"
  {
    cat "$src"
    printf '\n<!-- %s host=%s source=%s version=%s — installed by wgm. wgm refreshes or removes only adapter files carrying this token; delete this comment to disown the file. -->\n' \
      "$ADAPTER_MARKER" "$host" "$rel" "$ADAPTER_VERSION"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}

adapter_write_receipt() {
  # $1 = dir, $2 = host, remaining args = basenames. Same-directory temp + rename, so a reader (or a
  # later uninstall) sees the old complete list or the new complete list and never a truncated one.
  # The header names the host the list describes; when Copilot and Claude share (or symlink) one
  # directory the most recent install owns the index, and the other host simply falls back to finding
  # its files by their markers — an index is a convenience, never the authority to delete.
  local dir="$1" host="$2" tmp base
  shift 2
  tmp="$dir/$ADAPTER_RECEIPT_TMP_PREFIX$$"
  {
    printf '# wgm role-agent adapters — host=%s version=%s. One basename per line, this directory only.\n' \
      "$host" "$ADAPTER_VERSION"
    printf '# This list is an index, not a claim: wgm removes a listed file only while it still carries\n'
    printf '# the ownership marker wgm stamped into it.\n'
    for base in "$@"; do printf '%s\n' "$base"; done
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dir/$ADAPTER_RECEIPT" || { rm -f "$tmp"; return 1; }
}

adapter_sweep_temp() {
  # Remove wgm's own interrupted-write leftovers from directory $1: adapter temps AND receipt temps.
  # Both prefixes are wgm's own, carry a pid, and are only ever created by these installers, so this
  # can never select a file wgm did not write. Nothing else in the directory is considered.
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  rm -f "$dir/$ADAPTER_TMP_PREFIX"* 2>/dev/null || true
  rm -f "$dir/$ADAPTER_RECEIPT_TMP_PREFIX"* 2>/dev/null || true
  return 0
}

adapter_receipt_host() {
  # The host id recorded in the receipt header of directory $1, if it declares one. Both installers
  # write `host=<id>` into the leading comment block, so a receipt always says who it describes.
  local dir="$1" line v
  [[ -f "$dir/$ADAPTER_RECEIPT" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in \#*) ;; *) continue ;; esac
    case "$line" in *host=*) ;; *) continue ;; esac
    v="${line#*host=}"
    v="${v%%[[:space:]]*}"
    [[ -n "$v" ]] || continue
    printf '%s\n' "$v"
    return 0
  done < "$dir/$ADAPTER_RECEIPT"
  return 1
}

adapter_receipt_is_host() {  # $1 = dir, $2 = host id — true when the receipt describes this host
  local rhost
  rhost="$(adapter_receipt_host "$1" 2>/dev/null)" || return 1
  [[ "$rhost" == "$2" ]]
}

adapter_receipt_entries() {
  # $1 = dir, $2 = host id. Echoes the receipt's validated basenames, one per line.
  # Tolerates CRLF and a final line with no newline; rejects comments, blank lines, anything with a
  # path separator, dotfiles (so `..` can never appear), and any name that is not one of this host's
  # adapter files. A receipt that names another host — the case when an agent directory is shared or
  # symlinked between Copilot and Claude — indexes files this host does not own, so it is ignored
  # entirely. A hand-edited, half-written, or foreign receipt can therefore only ever name fewer
  # files; it can never widen what gets deleted.
  local dir="$1" host="$2" line
  [[ -f "$dir/$ADAPTER_RECEIPT" ]] || return 0
  adapter_receipt_is_host "$dir" "$host" || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    case "$line" in \#*|.*|*/*|*\\*) continue ;; esac
    adapter_name_for_host "$host" "$line" || continue
    printf '%s\n' "$line"
  done < "$dir/$ADAPTER_RECEIPT"
}

install_agents_into() {
  # $1 = host id, $2 = target dir. Copies that host's role files, stamping each one, and records what
  # it wrote. Files it does not own are skipped; roles this source no longer ships are pruned, but
  # only when the file on disk still carries wgm's marker — and only when this source ships at least
  # one role for this host, because a source with none is incomplete, not emptied on purpose.
  local host="$1" dir="$2" src_dir suffix file base dest rel prior wrote=0 pruned=0
  local src_files=()
  src_dir="$(adapter_source_dir "$host")"
  if [[ -z "$src_dir" || ! -d "$src_dir" ]]; then
    say "  no $host role adapters in this source, skipping: $dir"
    return 0
  fi
  # wgm's own checkout already IS the Copilot project agent dir; copying it onto itself is a no-op
  # at best and a self-inflicted delete at worst.
  if [[ "$(cd "$src_dir" && pwd)" == "$(cd "$dir" 2>/dev/null && pwd || printf '%s' "$dir")" ]]; then
    say "  already the canonical source, skipping: $dir"
    return 0
  fi
  [[ -n "$ADAPTER_VERSION" ]] || ADAPTER_VERSION="$(adapter_version)"
  suffix="$(adapter_glob_suffix "$host")"
  # A source directory that exists but ships no role files for this host is not evidence that wgm
  # retired every role: a truncated download, an interrupted bootstrap extract, or a bad --ref all
  # look exactly like that. Installing nothing is right; pruning everything already installed is not,
  # so this returns before the receipt is read and before anything is written or removed. An
  # explicit --uninstall, and a source that genuinely dropped one role, both still behave as before.
  for file in "$src_dir"/*"$suffix"; do
    [[ -f "$file" ]] || continue
    adapter_name_for_host "$host" "$(basename "$file")" || continue
    src_files+=("$file")
  done
  if [[ "${#src_files[@]}" -eq 0 ]]; then
    say "  no $host role files in this source ($src_dir) — installing and pruning nothing: $dir"
    say "    a source with zero roles is treated as incomplete, not as a source that retired them all."
    return 0
  fi
  say "  role agents ($host): $dir"
  [[ "$DRY_RUN" -eq 1 ]] || mkdir -p "$dir"
  prior="$(adapter_receipt_entries "$dir" "$host")"
  # Clear wgm's own leftovers from an interrupted earlier run. Both prefixes are wgm's, so this can
  # only ever remove a temp file wgm itself created.
  [[ "$DRY_RUN" -eq 1 ]] || adapter_sweep_temp "$dir"
  local written=()
  for file in "${src_files[@]}"; do
    [[ -f "$file" ]] || continue
    base="$(basename "$file")"
    adapter_name_for_host "$host" "$base" || continue
    dest="$dir/$base"
    rel="$(adapter_canonical_rel "$host" "$base")"
    if [[ -d "$dest" ]]; then
      say "    a directory occupies that name — skipping: $dest"
      continue
    fi
    if [[ -e "$dest" ]] && ! adapter_is_owned "$dest" "$host"; then
      # No marker of this host's in the terminal position means wgm did not write this file for this
      # host, whatever it is called and whatever it quotes. A prior receipt entry does not override
      # that: the file on disk is somebody else's now.
      if [[ "$FORCE" -eq 0 ]]; then
        say "    exists and is not wgm's — skipping (use --force to replace): $dest"
        continue
      fi
      say "    --force: replacing a file wgm did not write: $dest"
    fi
    written+=("$base")
    if [[ "$DRY_RUN" -eq 1 ]]; then say "    would install: $dest"; continue; fi
    if ! adapter_stamp_into "$file" "$dest" "$host" "$rel"; then
      echo "  failed to write role adapter: $dest" >&2
      continue
    fi
    wrote=$((wrote + 1))
  done
  # Prune roles this source no longer ships. Only a file the last receipt named AND that still
  # carries this host's marker in the terminal position qualifies: a name that reappeared as somebody
  # else's agent, or a file marked for the other host in a shared directory, survives.
  local stale keep
  while IFS= read -r stale; do
    [[ -n "$stale" ]] || continue
    keep=0
    for base in ${written[@]+"${written[@]}"}; do [[ "$base" == "$stale" ]] && keep=1; done
    [[ "$keep" -eq 0 ]] || continue
    [[ -f "$dir/$stale" ]] || continue
    if ! adapter_is_owned "$dir/$stale" "$host"; then
      say "    not wgm's for $host any more (marker gone, moved, or another host's) — leaving: $dir/$stale"
      continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then say "    would remove (role no longer shipped): $dir/$stale"; continue; fi
    rm -f "$dir/$stale"
    pruned=$((pruned + 1))
  done <<< "$prior"
  if [[ "$DRY_RUN" -eq 1 ]]; then return 0; fi
  if ! adapter_write_receipt "$dir" "$host" ${written[@]+"${written[@]}"}; then
    echo "  failed to write the $host adapter receipt in: $dir" >&2
  fi
  if [[ "$pruned" -gt 0 ]]; then
    say "    installed $wrote file(s), pruned $pruned no longer shipped"
  else
    say "    installed $wrote file(s)"
  fi
}

uninstall_agents_from() {
  # $1 = host id, $2 = target dir. Removes only files this host's marker proves wgm wrote: the
  # receipt says where to look, the marker decides. The directory itself is never removed, and a
  # receipt belonging to the other host (a shared or symlinked agent dir) is neither read nor
  # deleted.
  local host="$1" dir="$2" suffix receipt base dest candidates f removed=0 kept=0
  case "$dir" in
    */agents) ;;
    *) echo "  refusing to touch unexpected agent dir: $dir" >&2; return 0 ;;
  esac
  if [[ ! -d "$dir" ]]; then
    say "  no $host agent directory to clean: $dir"
    return 0
  fi
  suffix="$(adapter_glob_suffix "$host")"
  receipt="$dir/$ADAPTER_RECEIPT"
  # An uninstall should not leave wgm's own interrupted-write leftovers behind either.
  [[ "$DRY_RUN" -eq 1 ]] || adapter_sweep_temp "$dir"
  local mine_receipt=0
  adapter_receipt_is_host "$dir" "$host" && mine_receipt=1
  candidates="$(adapter_receipt_entries "$dir" "$host")"
  # An install interrupted between the copy and the receipt write leaves stamped files and no list.
  # Scanning for this host's own marker recovers exactly those, and can never select somebody else's
  # file — including the other host's adapters, which Claude's wider `*.md` glob also sweeps up.
  for f in "$dir"/*"$suffix"; do
    [[ -f "$f" ]] || continue
    adapter_is_owned "$f" "$host" || continue
    candidates+="$(printf '\n%s' "$(basename "$f")")"
  done
  candidates="$(printf '%s\n' "$candidates" | grep -v '^[[:space:]]*$' | sort -u || true)"
  if [[ -z "$candidates" ]]; then
    say "  no wgm adapter receipt entries or marked adapter files, leaving untouched: $dir"
    if [[ -f "$receipt" && "$mine_receipt" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
      rm -f "$receipt"
      say "  removed the empty $host adapter receipt: $receipt"
    fi
    return 0
  fi
  while IFS= read -r base; do
    [[ -n "$base" ]] || continue
    dest="$dir/$base"
    [[ -f "$dest" ]] || continue
    if ! adapter_is_owned "$dest" "$host"; then
      say "    listed but not wgm's for $host (no terminal $host marker) — leaving: $dest"
      kept=$((kept + 1))
      continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then say "    would remove: $dest"; continue; fi
    rm -f "$dest"
    removed=$((removed + 1))
  done <<< "$candidates"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ -f "$receipt" && "$mine_receipt" -eq 1 ]]; then say "  would remove the $host adapter receipt: $receipt"; fi
    return 0
  fi
  # Only this host's own index is cleaned up. In a shared directory the other host's receipt is its
  # record of its own files, and removing it would strand them.
  if [[ "$mine_receipt" -eq 1 ]]; then
    rm -f "$receipt"
  elif [[ -f "$receipt" ]]; then
    say "  leaving another host's adapter receipt in place: $receipt"
  fi
  if [[ "$kept" -gt 0 ]]; then
    say "  removed $removed $host adapter file(s) from: $dir ($kept left in place — not wgm's any more)"
  else
    say "  removed $removed $host adapter file(s) from: $dir"
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
  for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
    uninstall_one "$t"
    while IFS= read -r ct; do uninstall_one "$ct"; done < <(companion_targets_for "$t")
  done
  if [[ ${#WIN_TARGETS[@]} -gt 0 ]]; then
    for t in "${WIN_TARGETS[@]}"; do
      uninstall_one "$t"
      while IFS= read -r ct; do uninstall_one "$ct"; done < <(companion_targets_for "$t")
    done
  fi
  if [[ ${#AGENT_DIRS[@]} -gt 0 ]]; then
    for i in "${!AGENT_DIRS[@]}"; do uninstall_agents_from "${AGENT_HOSTS[$i]}" "${AGENT_DIRS[$i]}"; done
  fi
else
  say "Installing wgm to:"
  for t in ${TARGETS[@]+"${TARGETS[@]}"}; do install_one "$t" "$METHOD"; install_companions "$t" "$METHOD"; done
  if [[ ${#WIN_TARGETS[@]} -gt 0 ]]; then
    for t in "${WIN_TARGETS[@]}"; do install_one "$t" copy; install_companions "$t" copy; done
  fi
  if [[ ${#AGENT_DIRS[@]} -gt 0 ]]; then
    for i in "${!AGENT_DIRS[@]}"; do install_agents_into "${AGENT_HOSTS[$i]}" "${AGENT_DIRS[$i]}"; done
  fi
fi
for n in ${AGENT_NOTES[@]+"${AGENT_NOTES[@]}"}; do say "  note: $n"; done

say ""
say "Done. Targets:"
for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
  say "  - $t"
  if [[ "$NO_COMPANIONS" -eq 0 ]]; then
    while IFS= read -r ct; do say "  - $ct  (companion)"; done < <(companion_targets_for "$t")
  fi
done
if [[ ${#WIN_TARGETS[@]} -gt 0 ]]; then
  for t in "${WIN_TARGETS[@]}"; do say "  - $t  (windows mirror)"; done
fi
if [[ ${#AGENT_DIRS[@]} -gt 0 ]]; then
  for i in "${!AGENT_DIRS[@]}"; do say "  - ${AGENT_DIRS[$i]}  (${AGENT_HOSTS[$i]} role agents)"; done
fi
say ""
say "Verify your agent can see it (e.g. /skills in VS Code or Copilot CLI), then invoke /wgm."
if [[ "$NO_COMPANIONS" -eq 0 ]]; then
  say "Companions: /teach-me to learn a repo, /quiz-me to be tested on it, /rugged to stress-test a design."
fi
if [[ "$NO_AGENTS" -eq 1 ]]; then
  say "Role agents: skipped (--no-agents). wgm runs the review passes inline and sequentially instead."
elif [[ ${#AGENT_DIRS[@]} -eq 0 ]]; then
  say "Role agents: none installed — no host with a subagent format was selected. wgm falls back to scripts/audit.sh and inline sequential review passes."
fi
