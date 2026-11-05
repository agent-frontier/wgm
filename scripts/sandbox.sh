#!/usr/bin/env bash
#
# wgm/sandbox.sh — the sandbox decision, mount policy and launch helper shared by loop.sh, swarm.sh
# and devcontainer.sh. Executed, it exposes ONE subcommand; sourced, it only defines functions
# (`sandbox_exec` and its helpers) and runs nothing.
#
# Boundary (D1): the AGENT and its gate/validation commands run in a container; wgm's own loop/swarm
# machinery (guards, git bookkeeping, telemetry) stays on the host. See docs/reference/cli-loop.md.
#
# Usage:
#   scripts/sandbox.sh preflight [--project DIR] [--agent-cmd CMD]... [--agent-exe PATH]... [--gate-cmd CMD]...
#                                [--interactive auto|yes|no] [--devcontainer|--no-devcontainer]
#                                [--devcontainer-image TAG] [--devcontainer-mount HOST]...
#                                [--dry-run]
#
# Output (stdout, key=value lines): sandbox=on|off|inside engine=podman|docker|none reason=<word>
#   agent=<name> mount=<host>:<container>:<ro|rw> env=<NAME> image=<tag> record=<path>
#   plus copy=<host dir> / token=<host file>:<container path> (credential sources that are COPIED into
#   a throwaway dir, never bound), path=<dir> (PATH prefix inside) and smoke=override.
# Exit: 0 decision made · 2 fail closed (nothing started; fix-it text on stderr) · 1 internal error.
# --dry-run is NON-MUTATING: no prompt, no record/overlay write, no readiness probe, no smoke, no container.
#
# The operator-owned record lives OUTSIDE the repository:
#   ${XDG_CONFIG_HOME:-$HOME/.config}/wgm/sandbox/<repo-key>.yml   (0600, in a 0700 dir; never mounted)

SB_SELF="${BASH_SOURCE[0]}"
# (bash builtins only: no external tool may run before the host environment/PATH has been sanitized)
_sb_d="$SB_SELF"; if [[ "$_sb_d" == */* ]]; then _sb_d="${_sb_d%/*}"; else _sb_d=.; fi
SB_DIR="$(cd "$_sb_d" && pwd)"; unset _sb_d
SB_DEFAULT_IMAGE="localhost/wgm-devcontainer-base:latest"
SB_CONT_HOME="/home/wgm"
SB_DC="${SB_DC:-$SB_DIR/devcontainer.sh}"

# --- decision / run state (globals shared by preflight and sandbox_exec) ---------------------------
SB_MODE=""; SB_ENGINE="none"; SB_REASON=""; SB_IMAGE=""; SB_RECORD=""; SB_SMOKE_OVERRIDE=0
SB_AGENTS=(); SB_MOUNTS=(); SB_ENVS=(); SB_COPYSRC=(); SB_TOKENS=(); SB_PATHS=()
SB_PROJECT=""; SB_COMMON=""; SB_IS_GIT=0; SB_KEY8=""; SB_RECORD_DIR_CANON=""
SB_RUN_MOUNTS=(); SB_COPYROOT=""; SB_SEQ=0; SB_LIVE=""; SB_CHILD=""; SB_TIMEOUT=()
SB_PIN_PTR=""; SB_PIN_CFG=""; SB_PIN_INC=(); SB_INC_ERR=""; SB_OVERLAYS=(); SB_INCLUDES=()
SB_SNAPSHOT=""; SB_OWNED_DECISION=""; SB_LAYOUT=(); SB_HOSTTMP=""

# A refusal inside a $(...) subshell must still stop the whole run: when the owner installed a USR1 trap
# (SB_DIE_PROPAGATE=1, loop.sh) the subshell signals the main shell, which exits 2.
SB_DIE_PROPAGATE=""
# SB_ERRFD: the ORIGINAL stderr. Preflight redirects the output of its contained launches into files; refusals,
# notes and `retained container` lines must still reach the operator/caller, so they go to this descriptor.
SB_ERRFD=2
sb_die() {
  printf 'sandbox: %s\n' "$*" >&"$SB_ERRFD"
  if [[ -n "$SB_DIE_PROPAGATE" && "$BASHPID" != "$$" ]]; then kill -USR1 "$$" 2>/dev/null || true; fi
  exit 2
}
sb_note() { printf 'sandbox: %s\n' "$*" >&"$SB_ERRFD"; }

sb_under() {  # sb_under PATH ROOT — PATH equals or lies inside ROOT
  [[ "$2" == "/" ]] && return 0
  [[ "$1" == "$2" || "$1" == "$2"/* ]]
}
sb_canon() {  # canonical path, symlinks resolved, missing tail tolerated
  local c
  c="$(readlink -m -- "$1" 2>/dev/null)" || c=""
  [[ -n "$c" ]] || c="$(readlink -f -- "$1" 2>/dev/null)" || c="$1"
  printf '%s' "$c"
}
sb_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }
# stat, GNU or BSD flavour chosen ONCE (a GNU `stat -f` on a missing file prints filesystem junk, so the flavour
# is never probed by fallthrough). sb_stat GNUFMT BSDFMT FILE → value, or failure when FILE is unreadable/missing.
SB_STAT_GNU=""
sb_stat() {
  if [[ -z "$SB_STAT_GNU" ]]; then if stat -c %Y / >/dev/null 2>&1; then SB_STAT_GNU=1; else SB_STAT_GNU=0; fi; fi
  if [[ "$SB_STAT_GNU" == 1 ]]; then stat -c "$1" -- "$3" 2>/dev/null; else stat -f "$2" -- "$3" 2>/dev/null; fi
}
sb_mtime() { sb_stat %Y %m "$1" || date +%s; }
sb_stat_id() { sb_stat '%d:%i' '%d:%i' "$1" || echo "?"; }
sb_stat_owner() { sb_stat '%u' '%u' "$1" || echo "?"; }
sb_stat_mode() { sb_stat '%a' '%Lp' "$1" || echo "?"; }

# Host git helper (GIT SPLIT): plumbing only, execution-capable config neutralized, transports blocked.
# GIT_ALLOW_PROTOCOL is an ALLOWLIST overriding every protocol.<name>.allow policy: it must be SET AND
# EMPTY so no transport (and no git-remote-<name> helper on PATH) is permitted.
# The base call: fixed protections, NO repository inspection (used to read the config itself).
sb_git_base() {
  GIT_ALLOW_PROTOCOL='' GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat GIT_EDITOR=: \
    git -c core.fsmonitor=false -c core.hooksPath=/dev/null -c protocol.allow=never "$@"
}

# NO HOST GIT CALL EVER RUNS A REPOSITORY-CONFIGURED COMMAND. Besides hooks/fsmonitor/transports, git runs
# configured filter drivers (clean/smudge/process), diff drivers (textconv/command), diff.external, credential
# helpers, pagers and editors. `sb_git_neutralizers DIR` reads the EFFECTIVE config of the repo/worktree at DIR
# once (`git config --includes --get-regexp`, with the base protections) and fills SB_NEUT with `-c key=` pairs
# that EMPTY every configured command: filter.<d>.{clean,smudge,process}= and required=false, diff.<d>.textconv=
# (and diff.<d>.command= / diff.external= when configured: an empty value there makes git die "external diff
# died", which is the intended fail-closed outcome — emitting them unconditionally would break every diff),
# plus credential.helper=, core.pager=cat, core.editor=:, sequence.editor=: (and GIT_PAGER=cat, GIT_EDITOR=:
# in the environment). An empty filter command means "no filter" on git >= 2.x (verified empirically in
# test-sandbox.sh). TRADE-OFF: with filters disabled a filtered file whose stat changed can read as MODIFIED
# (it is hashed without its clean filter); callers treat such results as failure, never as success. The result
# is cached per directory and recomputed when the repo's config files change (stat signature).
# CALL CONTRACT: `source scripts/sandbox.sh` and run every host git call through `wgm_host_git [-C DIR] ARGS…`
# (it finds the repo from the last -C / --git-dir / cwd); callers needing the raw pairs use sb_git_neutralizers.
SB_NEUT=()
declare -gA SB_NEUT_CACHE=()
sb_neut_sig() {  # stat signature of the config files that can define commands for DIR
  local dir="$1" common gitdir f out=""
  common="$(sb_git_base -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  gitdir="$(sb_git_base -C "$dir" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  for f in "$common/config" "$gitdir/config.worktree" "$HOME/.gitconfig" "${XDG_CONFIG_HOME:-$HOME/.config}/git/config" /etc/gitconfig "$dir/.gitattributes"; do
    out+="$f:$(sb_stat '%Y.%s.%i' '%m.%z.%i' "$f" || echo none);"
  done
  printf '%s' "$out"
}
sb_git_neutralizers() {
  local dir="${1:-.}" sig key val name var
  [[ -d "$dir" ]] || dir="."
  dir="$(cd "$dir" && pwd -P)"
  sig="$(sb_neut_sig "$dir")"
  if [[ -n "${SB_NEUT_CACHE[$dir]+x}" && "${SB_NEUT_CACHE[$dir]%%$'\x01'*}" == "$sig" ]]; then
    SB_NEUT=(); [[ -n "${SB_NEUT_CACHE[$dir]#*$'\x01'}" ]] && mapfile -t SB_NEUT <<<"${SB_NEUT_CACHE[$dir]#*$'\x01'}"
    return 0
  fi
  local -A nseen=()
  local -a out=(-c credential.helper= -c core.pager=cat -c core.editor=: -c sequence.editor=:)
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    key="${key%% *}"
    case "$key" in
      filter.*.*) name="${key#filter.}"; var="${name##*.}"; name="${name%.*}"
        [[ -n "${nseen[f:$name]:-}" ]] || { nseen[f:$name]=1; out+=(-c "filter.$name.clean=" -c "filter.$name.smudge=" -c "filter.$name.process=" -c "filter.$name.required=false"); } ;;
      diff.external) out+=(-c "diff.external=") ;;
      diff.*.*) name="${key#diff.}"; var="${name##*.}"; name="${name%.*}"
        case "$var" in textconv|command) [[ -n "${nseen[d:$name:$var]:-}" ]] || { nseen[d:$name:$var]=1; out+=(-c "diff.$name.$var="); } ;; esac ;;
    esac
  done < <(sb_git_base -C "$dir" config --includes --get-regexp '^(filter|diff)\..*' 2>/dev/null || true)
  SB_NEUT=("${out[@]}")
  val="$(printf '%s\n' "${out[@]}")"
  SB_NEUT_CACHE[$dir]="$sig"$'\x01'"$val"
}
# HOST GIT MUST NEVER READ THROUGH AGENT-PLANTED SYMLINKS/SPECIAL FILES IN THE WRITABLE GIT DIR (index, HEAD,
# refs, packed-refs, logs, objects… of the worktree's admin dir AND the common dir). sb_gitdir_guard DIR [full]
# locates them WITHOUT git (parsing `.git`/`commondir` in bash; `rev-parse --git-path` would resolve symlinks)
# and checks without following symlinks that every entry git may open is a regular file or a real directory:
# top-level entries of both dirs, refs/, logs/, info/ (recursive), worktrees/*/ (top level), and — in `full`
# mode — all of objects/ (incl. info/alternates). Any symlink/special file → exit 2 naming it; recovery: remove
# the LINK itself (`rm <path>`, never its target; for an index then `git reset` in that checkout). It reuses
# sb_scan's fail-closed rules (vanishing entries below the root are not failures; anything uninspectable
# refuses). wgm_host_git runs the cheap mode on every call; sandbox_exec runs `full` after every contained
# command returns; swarm should call `sb_gitdir_guard DIR full` before its cleanup/guard batches.
# RESIDUAL (not closable here): a sibling lane's agent running CONCURRENTLY can swap an entry between this scan
# and git's open (deferred follow-up W7-F1, shared-git quiescence).
SB_GA=""; SB_GC=""
sb_lexnorm() {  # purely lexical path normalization (no filesystem access, no symlink following)
  local p="$1" c
  local -a parts=() out=()
  IFS=/ read -r -a parts <<<"$p"
  for c in "${parts[@]}"; do
    case "$c" in ""|.) ;; ..) [[ ${#out[@]} -gt 0 ]] && unset 'out[${#out[@]}-1]' ;; *) out+=("$c") ;; esac
  done
  local IFS=/; printf '/%s' "${out[*]}"
}
# ANCESTOR-AWARE: every admin-path read (`worktrees`, `worktrees/<name>`, `commondir`, `gitdir`…) is preceded by
# sb_chain_ok from the ROOT — the EXPECTED/pinned common dir when given (2nd argument), else the common dir
# implied by the admin path itself (`<common>/worktrees/<name>`), computed lexically — so a symlink anywhere on
# the way (e.g. a replaced `<common>/worktrees`) is refused, naming it, before anything below it is read.
sb_gitdir_resolve() {  # DIR [EXPECTED_COMMON] → SB_GA (admin dir), SB_GC (common dir); status 1 when DIR is not in a repo
  local d="$1" expect="${2:-}" g ptr c root bad
  SB_GA=""; SB_GC=""
  while :; do
    g="$d/.git"
    [[ -L "$g" ]] && sb_die "host git refused: $g is a symlink (agent-planted?). Recovery: remove the link itself (rm $g), never its target."
    if [[ -d "$g" ]]; then SB_GA="$g"; SB_GC="$g"; return 0
    elif [[ -f "$g" ]]; then
      read -r ptr < "$g" || ptr=""; ptr="${ptr#gitdir: }"; [[ "$ptr" == /* ]] || ptr="$d/$ptr"
      ptr="$(sb_lexnorm "$ptr")"
      if [[ -n "$expect" ]]; then
        root="$expect"
        [[ "$ptr" == "$root"/* ]] || sb_die "host git refused: the worktree admin dir $ptr is not under the expected common dir $root — the pointers were redirected (agent-written?). Nothing was read."
      elif [[ "$ptr" == */worktrees/* ]]; then root="${ptr%/worktrees/*}"
      else root="${ptr%/*}"; fi
      if ! bad="$(sb_chain_ok "$ptr" "$root")"; then sb_die "host git refused: $bad (on the path to the worktree admin dir) is a symlink (agent-planted?). Recovery: remove that LINK itself (rm '$bad'), never its target. Nothing was read."; fi
      [[ -d "$ptr" ]] || return 1
      SB_GA="$ptr"; SB_GC="$ptr"
      if ! bad="$(sb_chain_ok "$ptr/commondir" "$root")"; then sb_die "host git refused: $bad is a symlink (agent-planted?). Recovery: remove that LINK itself, never its target. Nothing was read."; fi
      if [[ -f "$ptr/commondir" ]]; then
        read -r c < "$ptr/commondir" || c=""; [[ "$c" == /* ]] || c="$ptr/$c"
        SB_GC="$(sb_lexnorm "$c")"
      fi
      return 0
    elif [[ -f "$d/HEAD" && -d "$d/objects" && -d "$d/refs" ]]; then SB_GA="$d"; SB_GC="$d"; return 0; fi
    [[ "$d" == / || -z "$d" ]] && return 1
    d="${d%/*}"; [[ -n "$d" ]] || d=/
  done
}
# one scan; a failed/uninspectable scan or any hit refuses with exit 2 (even where errexit is off)
sb_guard_scan() {  # sb_guard_scan ROOT LABEL FINDARGS…
  local h
  h="$(sb_scan "$@")" || exit 2
  [[ -z "$h" ]] || sb_trust_die "$h" "host git refused: $h is a symlink or special file inside the git dir (agent-planted?). Recovery: remove the LINK itself (rm '$h'), never its target; for an index run 'git reset' in that checkout afterwards."
}
# sb_gitdir_guard DIR [full] [--expect-common DIR]: with an expectation (explicit, or the pinned common dir
# when DIR lies inside the pinned project) a resolved common/admin dir that differs is refused (exit 2)
# BEFORE anything is scanned — a redirected `commondir` must never make the guard walk another repository.
sb_gitdir_guard() {
  local dir="${1:-$PWD}" mode="cheap" expect="" r root
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in full) mode=full ;; cheap) ;; --expect-common) expect="${2:-}"; shift ;; esac
    shift
  done
  if [[ -z "$expect" && -n "$SB_PIN_GC" && -n "$SB_PROJECT" ]] && sb_under "$dir" "$SB_PROJECT"; then expect="$SB_PIN_GC"; fi
  local ec=""
  [[ -n "$expect" ]] && ec="$(cd "$expect" 2>/dev/null && pwd -P || printf '%s' "$expect")"
  sb_gitdir_resolve "$dir" "$ec" || return 0
  if [[ -n "$expect" ]]; then
    [[ "$SB_GC" == "$ec" ]] || sb_trust_die "$SB_GC" "host git refused: the common git dir resolves to $SB_GC but $ec was expected — the worktree's pointers were redirected (agent-written?). Nothing was scanned or opened."
  fi
  local -a roots=("$SB_GA"); [[ "$SB_GC" == "$SB_GA" ]] || roots+=("$SB_GC")
  for root in "${roots[@]}"; do
    sb_guard_scan "$root" "agent-planted links in the git dir" -maxdepth 1 -mindepth 1 ! -type f ! -type d
    for r in refs logs info; do
      if [[ -e "$root/$r" || -L "$root/$r" ]]; then sb_guard_scan "$root/$r" "agent-planted links in the git dir" ! -type f ! -type d; fi
    done
  done
  if [[ -e "$SB_GC/worktrees" || -L "$SB_GC/worktrees" ]]; then
    sb_guard_scan "$SB_GC/worktrees" "agent-planted links in worktree admin dirs" -maxdepth 2 ! -type f ! -type d
  fi
  if [[ "$mode" == full && ( -e "$SB_GC/objects" || -L "$SB_GC/objects" ) ]]; then
    sb_guard_scan "$SB_GC/objects" "agent-planted links among the objects" ! -type f ! -type d
  fi
  return 0
}
wgm_host_git() {
  local dir="$PWD" i
  local -a a=("$@")
  for ((i = 0; i < ${#a[@]}; i++)); do
    case "${a[i]}" in
      -C) [[ $((i + 1)) -lt ${#a[@]} ]] && { [[ "${a[i+1]}" == /* ]] && dir="${a[i+1]}" || dir="$dir/${a[i+1]}"; } ;;
      --git-dir=*) dir="${a[i]#--git-dir=}" ;;
    esac
  done
  sb_gitdir_guard "$dir"
  # EVERY host git call, once pins have been captured for the repository it touches (the project or its git common
  # dir), first verifies them — pointer contents, then the raw-bytes executable-config digests including the stored
  # include targets (git-free, no-follow) — and a mismatch takes the trust-loss path (exit 2, `trust lost <path>` in
  # WGM_TRUST_LOST_FILE) BEFORE git runs. Nothing is cached between calls: an agent-reachable file is re-read each time.
  if [[ -n "$SB_PIN_PTR" && -n "$SB_PROJECT" ]]; then
    if sb_under "$dir" "$SB_PROJECT" || { [[ -n "$SB_COMMON" ]] && sb_under "$dir" "$SB_COMMON"; } || sb_dir_store_is "$dir" "$SB_PIN_GC"; then sb_verify_pins; fi
  elif [[ -n "${WGM_PIN_FILE:-}" ]]; then
    # PINS IN ANY PROCESS: no in-memory pins here (e.g. swarm captured them in a subshell) but WGM_PIN_FILE names a pin
    # file (sb_pin_capture_to format): load it and verify before EVERY host git call that touches its repository —
    # git-free, no-follow, exact bytes, nothing cached, and without clobbering this process's own SB_* state
    sb_verify_pin_file_for "$WGM_PIN_FILE" "$dir"
  fi
  sb_git_neutralizers "$dir"
  sb_git_base "${SB_NEUT[@]}" "$@"
}

# Host git protections for wgm's WHOLE host process tree (helper scripts, lane loops, git spawned by jj):
# a caller-local function or argv `-c` reaches none of those, the environment reaches all of them.
# CALL CONTRACT — `sb_export_git_env`: source scripts/sandbox.sh, call it once early in any host process that
# did not inherit the environment (swarm-parent-guard.sh, swarm.sh before it runs git/jj). It APPENDS
# core.fsmonitor=false, core.hooksPath=/dev/null and protocol.allow=never to GIT_CONFIG_COUNT/KEY_<i>/VALUE_<i>
# (existing entries are kept), and exports GIT_ALLOW_PROTOCOL (set, EMPTY), GIT_NO_LAZY_FETCH=1 and
# GIT_TERMINAL_PROMPT=0. Idempotent (WGM_GIT_ENV_APPLIED=1). The clean-env re-exec applies it for you. It
# must NEVER reach a container: sandbox_exec forwards only named variables and excludes all of these.
sb_git_env_pairs() {  # sb_git_env_pairs START_COUNT → NAME=VALUE lines
  local n="${1:-0}"
  printf '%s\n' "GIT_CONFIG_KEY_$n=core.fsmonitor" "GIT_CONFIG_VALUE_$n=false" \
    "GIT_CONFIG_KEY_$((n + 1))=core.hooksPath" "GIT_CONFIG_VALUE_$((n + 1))=/dev/null" \
    "GIT_CONFIG_KEY_$((n + 2))=protocol.allow" "GIT_CONFIG_VALUE_$((n + 2))=never" \
    "GIT_CONFIG_COUNT=$((n + 3))" "GIT_ALLOW_PROTOCOL=" "GIT_NO_LAZY_FETCH=1" "GIT_TERMINAL_PROMPT=0" "GIT_PAGER=cat" "GIT_EDITOR=:" "WGM_GIT_ENV_APPLIED=1"
}
# The marker is NEVER trusted alone: sb_git_env_ok verifies that every protection is actually in the environment
# (the LAST occurrence of each key among GIT_CONFIG_KEY_i/VALUE_i < GIT_CONFIG_COUNT carries the expected value —
# git applies them in order — plus GIT_ALLOW_PROTOCOL set and empty, GIT_NO_LAZY_FETCH=1, GIT_TERMINAL_PROMPT=0,
# GIT_PAGER=cat, GIT_EDITOR=:). A process started with the marker but without the variables (the C7 allowlist
# unsets the GIT_* variables and may drop the marker, a shell may hand down a stale marker) is re-protected.
sb_git_env_ok() {
  local n="${GIT_CONFIG_COUNT:-}" i k v fsm="" hooks="" proto=""
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  for ((i = 0; i < n; i++)); do
    k="GIT_CONFIG_KEY_$i"; v="GIT_CONFIG_VALUE_$i"
    case "${!k:-}" in core.fsmonitor) fsm="${!v:-}" ;; core.hooksPath) hooks="${!v:-}" ;; protocol.allow) proto="${!v:-}" ;; esac
  done
  [[ "$fsm" == false && "$hooks" == /dev/null && "$proto" == never ]] || return 1
  [[ "${GIT_ALLOW_PROTOCOL+set}" == set && -z "${GIT_ALLOW_PROTOCOL}" ]] || return 1
  [[ "${GIT_NO_LAZY_FETCH:-}" == 1 && "${GIT_TERMINAL_PROMPT:-}" == 0 && "${GIT_PAGER:-}" == cat && "${GIT_EDITOR:-}" == : ]]
}
sb_export_git_env() {
  sb_git_env_ok && { export WGM_GIT_ENV_APPLIED=1; return 0; }
  local n="${GIT_CONFIG_COUNT:-0}" kv
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  while IFS= read -r kv; do declare -gx "${kv%%=*}=${kv#*=}"; done < <(sb_git_env_pairs "$n")   # APPENDS: foreign entries are kept
}

# ---------------------------------------------------------------------------------------------------
# Record (D2)
# ---------------------------------------------------------------------------------------------------
sb_init_record_dir() {
  local base="${XDG_CONFIG_HOME:-$HOME/.config}"
  SB_RECORD_DIR_CANON="$(sb_canon "$base/wgm/sandbox")"
}
# The EFFECTIVE (canonical, every symlink resolved) record directory must neither lie inside nor contain the project or
# the git common dir: a record reachable from agent-writable space could be forged to authorize an unsandboxed run. A
# symlinked ancestor under an XDG base that is itself outside the project is exactly the case this catches. Called by
# sb_repo_layout AND immediately before every record load and save (it re-resolves, so a re-pointed link is caught
# too), on every preflight path: exit 2 naming the directory, before any read or write.
sb_record_dir_guard() {
  local base="${XDG_CONFIG_HOME:-$HOME/.config}" d w
  d="$(sb_canon "$base/wgm/sandbox")"
  [[ -z "$SB_RECORD_DIR_CANON" || "$d" == "$SB_RECORD_DIR_CANON" ]] || sb_die "the effective sandbox record directory changed from $SB_RECORD_DIR_CANON to $d during this run — refusing to read or write the record"
  for w in "$SB_PROJECT" "$SB_COMMON"; do
    [[ -n "$w" ]] || continue
    if sb_under "$d" "$w" || sb_under "$w" "$d"; then
      sb_die "the effective sandbox record directory $d (from $base/wgm/sandbox) overlaps ${w}, which the agent can write; the operator-owned record must live outside every mount. Recovery: point XDG_CONFIG_HOME at a directory outside the project and the git directory and make sure no component of \$XDG_CONFIG_HOME/wgm/sandbox is a symlink into them."
    fi
  done
}

sb_repo_layout() {  # sets SB_PROJECT, SB_COMMON, SB_IS_GIT, SB_KEY8, SB_RECORD (project = $1 or cwd)
  SB_PROJECT="$(cd "${1:-.}" && pwd -P)"
  SB_COMMON=""; SB_IS_GIT=0
  local c="" keysrc
  sb_gitdir_guard "$SB_PROJECT"   # visible refusal (the git calls below discard stderr)
  c="$(wgm_host_git -C "$SB_PROJECT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || c=""
  if [[ -z "$c" ]]; then
    c="$(wgm_host_git -C "$SB_PROJECT" rev-parse --git-common-dir 2>/dev/null)" || c=""
    [[ -n "$c" && "$c" != /* ]] && c="$SB_PROJECT/$c"
  fi
  if [[ -z "$c" && -e "$SB_PROJECT/.git" ]]; then
    sb_die "the git common directory of $SB_PROJECT is unreachable (cannot resolve it). Fix the repository (git -C $SB_PROJECT rev-parse --git-common-dir must work) or pass --no-devcontainer."
  fi
  keysrc="$SB_PROJECT"
  if [[ -n "$c" ]]; then SB_COMMON="$(sb_canon "$c")"; SB_IS_GIT=1; keysrc="$SB_COMMON"; [[ -d "$SB_COMMON" ]] || sb_die "git common directory $SB_COMMON is unreachable"; fi
  SB_KEY8="$(printf '%s' "$keysrc" | sb_sha256)"
  SB_KEY8="${SB_KEY8:0:16}"
  sb_init_record_dir
  sb_record_dir_guard
  SB_RECORD="$SB_RECORD_DIR_CANON/$SB_KEY8.yml"
  SB_KEY8="${SB_KEY8:0:8}"
}

REC_PRESENT=0; REC_DECLINED="false"; REC_DECLINED_AT=""; REC_AGENTS=""; REC_IMAGE=""
REC_TOKENS=(); REC_COPIES=(); REC_MOUNTS=(); REC_ENV=()

sb_record_check_file() {  # permission / ownership / symlink gate shared by the record and a decision file
  local f="$1" what="$2" m
  [[ -L "$f" ]] && sb_die "$what $f is a symlink — refusing to follow"
  [[ -f "$f" ]] || sb_die "$what $f is not a regular file"
  [[ "$(sb_stat_owner "$f")" == "$(id -u)" ]] || sb_die "$what $f is not owned by the operator"
  m="$(sb_stat_mode "$f")"
  if ! [[ "$m" =~ ^[0-7]+$ ]] || (( (8#$m & 8#022) != 0 )); then sb_die "$what $f is group/world-writable (mode $m); chmod 600 it"; fi
}

# The record DIRECTORY gets the same ownership gate as the record file: a directory owned by another user (or writable by
# group/world) lets someone else replace the approval record, so it is refused (exit 2) naming it — before any load or save.
sb_record_dir_check() {
  local d="${SB_RECORD%/*}" m
  [[ -n "$SB_RECORD" && -e "$d" ]] || return 0
  [[ -L "$d" ]] && sb_die "record directory $d is a symlink — refusing to follow"
  [[ -d "$d" ]] || sb_die "record directory $d is not a directory"
  [[ "$(sb_stat_owner "$d")" == "$(id -u)" ]] || sb_die "record directory $d is not owned by the operator"
  m="$(sb_stat_mode "$d")"
  if ! [[ "$m" =~ ^[0-7]+$ ]] || (( (8#$m & 8#022) != 0 )); then sb_die "record directory $d is group/world-writable (mode $m); chmod 700 it"; fi
}
sb_record_load() {
  REC_PRESENT=0; REC_DECLINED="false"; REC_DECLINED_AT=""; REC_AGENTS=""; REC_IMAGE=""
  REC_TOKENS=(); REC_COPIES=(); REC_MOUNTS=(); REC_ENV=()
  sb_record_dir_guard
  sb_record_dir_check
  [[ -e "$SB_RECORD" || -L "$SB_RECORD" ]] || return 0
  sb_record_check_file "$SB_RECORD" "record"
  local line section="" ok=1 saw_decl=0 v
  local -a a_t=() a_c=() a_m=() a_e=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      ""|\#*) ;;
      "engine_declined: "*) v="${line#engine_declined: }"; [[ "$v" == true || "$v" == false ]] || ok=0; REC_DECLINED="$v"; saw_decl=1; section="" ;;
      "declined_at:"*) REC_DECLINED_AT="${line#declined_at:}"; REC_DECLINED_AT="${REC_DECLINED_AT# }"; section="" ;;
      "agents:"*) REC_AGENTS="${line#agents:}"; REC_AGENTS="${REC_AGENTS# }"; section="" ;;
      "image:"*) REC_IMAGE="${line#image:}"; REC_IMAGE="${REC_IMAGE# }"; section="" ;;
      "tokens:") section=t ;; "copies:") section=c ;; "mounts:") section=m ;; "env:") section=e ;;
      "  - "?*)
        v="${line#  - }"
        case "$section" in t) a_t+=("$v") ;; c) a_c+=("$v") ;; m) a_m+=("$v") ;; e) a_e+=("$v") ;; *) ok=0 ;; esac ;;
      *) ok=0 ;;
    esac
  done < "$SB_RECORD"
  if [[ "$ok" -ne 1 || "$saw_decl" -ne 1 ]]; then
    sb_note "record $SB_RECORD is malformed — treating it as absent"
    REC_DECLINED="false"; REC_DECLINED_AT=""; REC_AGENTS=""; REC_IMAGE=""
    return 0
  fi
  REC_PRESENT=1; REC_TOKENS=("${a_t[@]}"); REC_COPIES=("${a_c[@]}"); REC_MOUNTS=("${a_m[@]}"); REC_ENV=("${a_e[@]}")
}

# The record is NEVER written without a lock (C10: ONE interoperable lock). EVERY writer takes the owner-record
# lock FILE `<dir>/.lock.own`, created atomically together with its owner record (see below); where `flock` exists
# (WGM_NO_FLOCK=1 hides it, a test seam) the writer ADDITIONALLY holds `flock <dir>/.lock`, taken second. Writers with
# and without flock therefore exclude each other through `.lock.own`. A lock whose owner is dead, whose pid was
# reused, or that is older than 120 s, is stale and broken. Failure to take either lock → exit 2 naming it.
SB_LOCKFD=""
# Start time of PID (an opaque token) so a REUSED pid is not mistaken for the lock holder.
sb_proc_start() {
  local st
  local -a f=()
  if [[ -r "/proc/$1/stat" ]]; then
    st="$(cat "/proc/$1/stat" 2>/dev/null || true)"; st="${st##*) }"   # drop "pid (comm) " (comm may hold spaces)
    read -r -a f <<<"$st"; printf '%s' "${f[19]:-}"                    # field 22 overall = 20th word after "(comm)"
    return 0
  fi
  ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' || true
}
# The mkdir-less fallback lock is a FILE (`<dir>/.lock.own`) that is created atomically WITH its owner record:
# `<BASHPID> <start time>` is written to a unique temp file which is then hard-linked to `.lock.own` (atomic; fails
# if it exists). The lock therefore never exists without its owner, so a holder killed at ANY stage is either not
# holding anything (killed before `ln`) or holding a lock that names it (and is judged stale at once).
# Stale breaking happens only under a short breaker mutex (atomic mkdir, itself broken when > 5 s old) and
# RE-READS the owner record inside it: a fresh lock is never deleted, a second breaker leaves what the first
# replaced. (Residual: a holder that is alive but older than 120 s could release and be replaced inside the
# breaker's check→rm window; only the age rule can hit it.) Release removes the file only if it is still OURS.
SB_LOCKFILE=""; SB_LOCKTOK=""
# alive = signalable AND not a zombie (a SIGKILLed holder whose parent has not reaped it yet still answers kill -0)
sb_proc_alive() {
  local st
  kill -0 "$1" 2>/dev/null || return 1
  if [[ -r "/proc/$1/stat" ]]; then
    st="$(cat "/proc/$1/stat" 2>/dev/null || true)"; st="${st##*) }"; [[ "${st%% *}" != Z ]]
  else
    st="$(ps -o stat= -p "$1" 2>/dev/null || true)"; [[ "$st" != Z* ]]
  fi
}
sb_lock_is_stale() {  # sb_lock_is_stale DIR → 0 when the CURRENT lock record is stale
  local lockf="$1/.lock.own" pid pstart age
  [[ -f "$lockf" ]] || return 1
  read -r pid pstart < "$lockf" 2>/dev/null || return 1
  age=$(( $(date +%s) - $(sb_mtime "$lockf") ))
  [[ -n "$pid" ]] && ! sb_proc_alive "$pid" && return 0
  [[ -n "$pid" && -n "$pstart" && "$(sb_proc_start "$pid")" != "$pstart" ]] && return 0
  [[ "$age" -gt 120 ]] && return 0
  return 1
}
sb_lock_break() {
  local dir="$1" i age
  for i in $(seq 1 100); do
    if mkdir "$dir/.lock.break" 2>/dev/null; then
      if sb_lock_is_stale "$dir"; then rm -f "$dir/.lock.own"; fi
      rmdir "$dir/.lock.break" 2>/dev/null || true
      find "$dir" -maxdepth 1 -name '.lock.tmp.*' -mmin +2 -exec rm -f {} + 2>/dev/null || true   # junk of killed writers
      return 0
    fi
    age=$(( $(date +%s) - $(sb_mtime "$dir/.lock.break") ))
    [[ "$age" -gt 5 ]] && rm -rf "$dir/.lock.break"
    sleep 0.05
  done
  return 1
}
sb_lock_acquire() {  # sb_lock_acquire DIR
  local dir="$1" pid me tmp tok tries="${WGM_LOCK_TRIES:-300}"   # WGM_LOCK_TRIES / WGM_LOCK_PAUSE: test seams
  # C10: ONE interoperable lock. EVERY writer takes the owner-record lock `.lock.own` (below); where flock exists the
  # writer ALSO holds `flock <dir>/.lock` (always taken second, released first). Writers with and without flock
  # therefore exclude each other through `.lock.own`.
  me="$BASHPID"   # captured first: inside $(...) BASHPID would be the substitution's own pid
  tok="$me $(sb_proc_start "$me")"
  tmp="$(mktemp "$dir/.lock.tmp.XXXXXX")" || sb_die "cannot create a lock temp file in $dir"
  printf '%s\n' "$tok" > "$tmp"
  if [[ "${WGM_LOCK_PAUSE:-}" == before-ln ]]; then : > "$dir/.paused"; sleep 60; fi
  for _i in $(seq 1 "$tries"); do
    if ln "$tmp" "$dir/.lock.own" 2>/dev/null; then
      rm -f "$tmp"; SB_LOCKFILE="$dir/.lock.own"; SB_LOCKTOK="$tok"
      if [[ "${WGM_LOCK_PAUSE:-}" == after-ln ]]; then : > "$dir/.paused"; sleep 60; fi
      if command -v flock >/dev/null 2>&1 && [[ -z "${WGM_NO_FLOCK:-}" ]]; then
        exec {SB_LOCKFD}>"$dir/.lock" || { sb_lock_release; sb_die "cannot open the record lock $dir/.lock"; }
        flock -w "$(( (tries + 9) / 10 ))" "$SB_LOCKFD" || { sb_lock_release; sb_die "could not take the record lock $dir/.lock (another preflight holds it)"; }
      fi
      return 0
    fi
    if sb_lock_is_stale "$dir"; then sb_lock_break "$dir"; continue; fi
    sleep 0.1
  done
  rm -f "$tmp"
  read -r pid _ < "$dir/.lock.own" 2>/dev/null || pid=""
  sb_die "could not take the record lock $dir/.lock.own (held by pid ${pid:-unknown}); remove it if that process is gone"
}
sb_lock_release() {
  if [[ -n "$SB_LOCKFD" ]]; then exec {SB_LOCKFD}>&-; SB_LOCKFD=""; fi
  if [[ -n "$SB_LOCKFILE" ]]; then
    [[ "$(cat "$SB_LOCKFILE" 2>/dev/null || true)" == "$SB_LOCKTOK" ]] && rm -f "$SB_LOCKFILE"
    SB_LOCKFILE=""; SB_LOCKTOK=""
  fi
}
sb_record_save() {  # atomic (temp + rename) under a lock; keeps the file 0600 in a 0700 dir
  local dir tmp
  sb_record_dir_guard
  dir="$(dirname "$SB_RECORD")"
  ( umask 077; mkdir -p "$dir" ) || sb_die "cannot create the record directory $dir"
  [[ -L "$dir" ]] && sb_die "record directory $dir is a symlink — refusing to follow"
  [[ "$(sb_stat_owner "$dir")" != "$(id -u)" ]] || chmod 700 "$dir" 2>/dev/null || true   # (tighten OUR directory; a foreign one is refused below)
  sb_record_dir_check
  sb_lock_acquire "$dir"
  tmp="$(umask 077; mktemp "$dir/.rec.XXXXXX")" || sb_die "cannot write the record in $dir"
  {
    echo "# wgm sandbox decisions — operator-owned; never inside a repository"
    echo "engine_declined: $REC_DECLINED"
    echo "declined_at: $REC_DECLINED_AT"
    echo "agents: $REC_AGENTS"
    echo "image: $REC_IMAGE"
    echo "tokens:"; local x; for x in "${REC_TOKENS[@]}"; do echo "  - $x"; done
    echo "copies:"; for x in "${REC_COPIES[@]}"; do echo "  - $x"; done
    echo "mounts:"; for x in "${REC_MOUNTS[@]}"; do echo "  - $x"; done
    echo "env:"; for x in "${REC_ENV[@]}"; do echo "  - $x"; done
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$SB_RECORD"
  sb_lock_release
}

# ---------------------------------------------------------------------------------------------------
# Mount policy (one policy for EVERY mount)
# ---------------------------------------------------------------------------------------------------
sb_forbidden_reason() {  # canonical path → reason on stdout, status 0 when forbidden
  local c="$1" home s d
  home="$(sb_canon "$HOME")"
  [[ "$c" == "/" ]] && { echo "is the filesystem root"; return 0; }
  [[ "$c" == "$home" ]] && { echo "is \$HOME"; return 0; }
  sb_under "$home" "$c" && { echo "is a parent of \$HOME"; return 0; }
  for d in .ssh .gnupg .aws; do
    s="$(sb_canon "$HOME/$d")"
    if sb_under "$c" "$s" || sb_under "$s" "$c"; then echo "overlaps ~/$d"; return 0; fi
  done
  if [[ -n "$SB_RECORD_DIR_CANON" ]] && { sb_under "$c" "$SB_RECORD_DIR_CANON" || sb_under "$SB_RECORD_DIR_CANON" "$c"; }; then
    echo "overlaps the sandbox record directory $SB_RECORD_DIR_CANON (set XDG_CONFIG_HOME outside every mount)"; return 0
  fi
  return 1
}

# Inspection that feeds a safety decision FAILS CLOSED: "inspected, nothing found" is told apart from
# "could not inspect". sb_scan DIR LABEL FINDARGS… → hits on stdout (first only); any find error or
# non-zero status refuses the launch (exit 2) naming the uninspectable path(s).
# find's own `-ignore_readdir_race` is used when supported (probed once); either way the stderr is
# classified: ONLY "No such file or directory" for a path strictly BELOW a scanned root is ignorable
# (an entry that vanished between readdir and stat cannot be a link or special file any more; the shared
# git dir always has writers). Everything else — permission/I-O errors, a missing/unreadable root — refuses.
SB_FIND_IRR=""
sb_find_irr() {
  if [[ -z "$SB_FIND_IRR" ]]; then
    if find / -maxdepth 0 -ignore_readdir_race >/dev/null 2>&1; then SB_FIND_IRR=yes; else SB_FIND_IRR=no; fi
  fi
  [[ "$SB_FIND_IRR" == yes ]]
}
sb_real_errors() {  # sb_real_errors ERRTEXT ROOT… → the error lines that are NOT ignorable vanished entries
  local errs="$1" line path r ok; shift
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ok=0
    if [[ "$line" == *": No such file or directory" ]]; then
      path="${line#find: }"; path="${path%: No such file or directory}"
      path="${path#[\'\"‘]}"; path="${path%[\'\"’]}"
      for r in "$@"; do [[ "$path" == "$r"/* ]] && ok=1; done
    fi
    [[ "$ok" -eq 1 ]] || printf '%s\n' "$line"
  done <<<"$errs"
}
# EVIDENCE RULE: a find run counts as "inspected" ONLY if it exited 0, or exited non-zero AND it printed at least
# one `find:` diagnostic AND every diagnostic is a qualified vanished-entry ENOENT strictly below a scanned root.
# Anything else — silent non-zero exits, kills by signal, exit 73, unqualified diagnostics — is NOT evidence.
sb_find_ok() {  # sb_find_ok RC OUTPUT ROOT… → 0 when the run counts as inspected
  local rc="$1" ftxt="$2" lines; shift 2
  [[ "$rc" -eq 0 ]] && return 0
  lines="$(grep '^find: ' <<<"$ftxt" || true)"
  [[ -n "$lines" ]] || return 1
  [[ -z "$(sb_real_errors "$lines" "$@")" ]]
}
# sb_scan DIR LABEL FINDARGS… → first hit on stdout; refuses (exit 2) when the scan could not be completed.
sb_scan() {
  local dir="$1" label="$2"; shift 2
  local out rc=0 errs hits
  local -a opts=(-xdev)
  if [[ ! -d "$dir" || ! -r "$dir" || ! -x "$dir" ]]; then
    sb_die "launch refused: could not inspect $dir for $label (the root is missing or unreadable). Recovery: restore read/execute permission for the owner or move the path out of the project."
  fi
  sb_find_irr && opts=(-ignore_readdir_race -xdev)
  out="$(find "$dir" "${opts[@]}" "$@" -print -quit 2>&1)" || rc=$?
  errs="$(sb_real_errors "$(grep '^find: ' <<<"$out" || true)" "$dir")"
  hits="$(grep -v '^find: ' <<<"$out" || true)"
  if ! sb_find_ok "$rc" "$out" "$dir"; then
    [[ -n "$errs" ]] || errs="no diagnostics: find failed silently or was killed"
    sb_die "launch refused: could not inspect $dir for $label (find exited $rc): $errs. Recovery: restore read/execute permission for the owner (e.g. chmod u+rwx on the path named above) or move that path out of the project."
  fi
  printf '%s' "$hits"
}

sb_policy_check() {  # sb_policy_check PATH LABEL — exit 2 naming the refusal
  local p="$1" label="$2" c r rt hit mp
  [[ -e "$p" ]] || sb_die "$label: $p does not exist"
  c="$(sb_canon "$p")"
  if r="$(sb_forbidden_reason "$c")"; then sb_die "mount refused ($label): $c $r"; fi
  if [[ -d "$c" ]]; then
    for rt in "${XDG_RUNTIME_DIR:-}" /run /var/run /proc /sys /dev; do
      [[ -n "$rt" ]] || continue
      rt="$(sb_canon "$rt")"
      if sb_under "$c" "$rt" || sb_under "$rt" "$c"; then sb_die "mount refused ($label): $c lies in or contains the runtime tree $rt"; fi
    done
    hit="$(sb_scan "$c" "sockets, devices and FIFOs" \( -type s -o -type b -o -type c -o -type p \))"
    [[ -z "$hit" ]] || sb_die "mount refused ($label): $c contains a socket, device or FIFO ($hit); read-only does not stop connecting to a socket"
    # A non-recursive bind exposes what lies UNDER a mount point inside the tree: refuse such trees.
    local mi="${WGM_MOUNTINFO:-/proc/self/mountinfo}" _a _b _c2 _d
    [[ -z "${WGM_MOUNTINFO:-}" ]] || sb_safe_path "$mi"   # an env-named file the host reads: no-follow guard when it lies in a writable root
    if [[ ! -r "$mi" && -d /proc/self ]]; then sb_die "launch refused: cannot read $mi, so mount points inside $c cannot be inspected"; fi
    if [[ -r "$mi" ]]; then
      while read -r _a _b _c2 _d mp _; do
        sb_unescape_mountinfo "$mp"; mp="$SB_UNESC"
        if [[ "$mp" != "$c" ]] && sb_under "$mp" "$c"; then sb_die "mount refused ($label): $c contains the mount point $mp (a non-recursive bind would expose what lies under it)"; fi
      done < "$mi"
    fi
  else
    [[ -f "$c" ]] || sb_die "mount refused ($label): $c is not a regular file or directory (sockets, devices and FIFOs are refused)"
  fi
}

# /proc/self/mountinfo escapes space, tab, newline and backslash (and any other special byte) as a 3-digit octal `\ooo`
# (\040 \011 \012 \134 …). Decode EVERY such escape, in one left-to-right pass, before comparing a mount point with a path.
sb_unescape_mountinfo() {  # sb_unescape_mountinfo ESCAPED → decoded path in SB_UNESC (not stdout: $(…) would eat a trailing newline)
  local s="$1" out="" ch
  while [[ "$s" =~ ^([^\\]*)\\([0-7]{3})(.*)$ ]]; do
    out+="${BASH_REMATCH[1]}"
    printf -v ch '%b' "\\0${BASH_REMATCH[2]}"
    out+="$ch"; s="${BASH_REMATCH[3]}"
  done
  SB_UNESC="$out$s"
}
SB_UNESC=""

sb_hardlink_check() {  # writable trees must not share inodes with files outside every mount
  local c hit
  c="$(sb_canon "$1")"
  [[ -d "$c" ]] || return 0
  hit="$(sb_scan "$c" "hard links" -type f -links +1)"
  [[ -z "$hit" ]] || sb_die "launch refused: $hit has more than one hard link inside the writable mount $c, so the agent could modify an inode shared with a file outside every mount. Fix: for objects hard-linked by a local clone run 'git repack -a -d && git prune-packed'; otherwise re-copy the file (cp f f.new && mv f.new f)."
}

# ---------------------------------------------------------------------------------------------------
# Static discovery (no host node/npm is ever run)
# ---------------------------------------------------------------------------------------------------
SB_D_PREFIX=""; SB_D_PATHDIR=""
# C6: OS-owned prefixes are NEVER bind-mounted (they would overlay the image's own userland). A CLI whose canonical
# binary lies under one must be provided by the image; the readiness probe (`<cli> --version` inside) proves it,
# else exit 2 with the project-image recipe.
sb_is_system_path() {  # sb_is_system_path CANONICAL_PATH
  local r
  for r in /usr /bin /sbin /lib /lib32 /lib64 /libx32; do sb_under "$1" "$r" && return 0; done
  return 1
}
sb_discover() {  # sb_discover WORD → SB_D_PREFIX (a prefix to mount ro, or "") and SB_D_PATHDIR
  local w="$1" bin canon pfx="" pdir=""
  SB_D_PREFIX=""; SB_D_PATHDIR=""
  if [[ "$w" == */* ]]; then bin="$w"; else bin="$(command -v -- "$w" 2>/dev/null || true)"; fi
  [[ -n "$bin" && -e "$bin" ]] || return 0
  [[ "$bin" == */* ]] || return 0
  canon="$(sb_canon "$bin")"
  if sb_under "$canon" "$SB_PROJECT" || { [[ -n "$SB_COMMON" ]] && sb_under "$canon" "$SB_COMMON"; }; then return 0; fi
  if [[ "$canon" == */lib/node_modules/* ]]; then pfx="${canon%%/lib/node_modules/*}"
  elif [[ "$(basename "$(dirname "$canon")")" == "bin" ]]; then pfx="$(dirname "$(dirname "$canon")")"
  else pfx="$(dirname "$canon")"; fi
  [[ "$w" == */* ]] || pdir="$(dirname "$(sb_abs "$bin")")"
  if sb_is_system_path "$canon"; then
    sb_note "static discovery: $w ($canon) lives under an OS-owned prefix; never mounted — the sandbox image must provide it (the readiness probe runs it inside)"
    pfx=""; pdir=""
  fi
  SB_D_PREFIX="$pfx"; SB_D_PATHDIR="$pdir"
}
sb_abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }

# ---------------------------------------------------------------------------------------------------
# Credentials table (per agent)
# ---------------------------------------------------------------------------------------------------
SB_T_TOKEN=""; SB_T_DIR=""; SB_T_ENV=""
sb_agent_table() {
  SB_T_TOKEN=""; SB_T_DIR=""; SB_T_ENV=""
  case "$1" in
    pi)      SB_T_TOKEN=".pi/agent/auth.json"; SB_T_DIR=".pi/agent" ;;
    claude)  SB_T_TOKEN=".claude/.credentials.json"; SB_T_DIR=".claude"; SB_T_ENV="ANTHROPIC_API_KEY" ;;
    codex)   SB_T_TOKEN=".codex/auth.json"; SB_T_DIR=".codex"; SB_T_ENV="OPENAI_API_KEY" ;;
    gh)      SB_T_TOKEN=".config/gh/hosts.yml"; SB_T_DIR=".config/gh"; SB_T_ENV="GH_TOKEN GITHUB_TOKEN" ;;
    copilot) SB_T_DIR=".copilot"; SB_T_ENV="GH_TOKEN GITHUB_TOKEN COPILOT_GITHUB_TOKEN" ;;
  esac
}
sb_all_cred_env_names() { echo "ANTHROPIC_API_KEY OPENAI_API_KEY GH_TOKEN GITHUB_TOKEN COPILOT_GITHUB_TOKEN"; }

# Proposal for the agents in SB_AGENTS: P_TOKENS "canonical:container", P_DIRS "canonical:container", P_ENV names.
P_TOKENS=(); P_DIRS=(); P_ENV=(); P_ENV_ALL=()
sb_has() { local x n="$1"; shift; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }
sb_proposal() {
  P_TOKENS=(); P_DIRS=(); P_ENV=(); P_ENV_ALL=()
  local a t d e
  for a in "${SB_AGENTS[@]}"; do
    sb_agent_table "$a"
    if [[ -n "$SB_T_TOKEN" && -f "$HOME/$SB_T_TOKEN" ]]; then
      t="$(sb_canon "$HOME/$SB_T_TOKEN"):$SB_CONT_HOME/$SB_T_TOKEN"; sb_has "$t" "${P_TOKENS[@]}" || P_TOKENS+=("$t")
    fi
    if [[ -n "$SB_T_DIR" && -d "$HOME/$SB_T_DIR" ]]; then
      d="$(sb_canon "$HOME/$SB_T_DIR"):$SB_CONT_HOME/$SB_T_DIR"; sb_has "$d" "${P_DIRS[@]}" || P_DIRS+=("$d")
    fi
    for e in $SB_T_ENV; do
      sb_has "$e" "${P_ENV_ALL[@]}" || P_ENV_ALL+=("$e")
      if [[ -n "${!e:-}" ]]; then sb_has "$e" "${P_ENV[@]}" || P_ENV+=("$e"); fi
    done
  done
}

# Copy the approved credential sources into a run-private 0700 dir OUTSIDE every mount.
# Mount list entries become "copydir:containerpath:rw:copy".
sb_make_copies() {
  local m src cp mode kind idx=0 f base tok root tmpbase csrc
  SB_RUN_MOUNTS=()
  for m in "${SB_MOUNTS[@]}"; do
    src="${m%%:*}"; rest="${m#*:}"; cp="${rest%%:*}"; mode="${rest#*:}"
    csrc="$(sb_canon "$src")"
    if sb_under "$csrc" "$SB_PROJECT" || sb_under "$SB_PROJECT" "$csrc" \
       || { [[ -n "$SB_COMMON" ]] && { sb_under "$csrc" "$SB_COMMON" || sb_under "$SB_COMMON" "$csrc"; }; }; then
      sb_die "decision refused: it names the mount $m, which is the project, the git directory or one of their overlays; those are derived from the working tree at every launch"
    fi
    kind=plain
    if sb_has "$src" "${SB_COPYSRC[@]}" && [[ "$mode" == rw ]]; then
      if [[ -z "$SB_COPYROOT" ]]; then
        tmpbase="$(sb_private_base)" || exit 2
        SB_COPYROOT="$(umask 077; mktemp -d "$tmpbase/wgm-cred.XXXXXX")" || sb_die "cannot create a credential copy dir under $tmpbase"
        chmod 700 "$SB_COPYROOT"
        root="$SB_COPYROOT"   # (sb_private_base already proved $tmpbase lies outside every mount)
      fi
      idx=$((idx + 1)); local dst="$SB_COPYROOT/c$idx"
      mkdir -p "$dst"; chmod 700 "$dst"
      for f in "$src"/* "$src"/.[!.]*; do
        [[ -f "$f" && ! -L "$f" && ! -x "$f" ]] || continue
        cat -- "$f" > "$dst/$(basename "$f")" 2>/dev/null || true
      done
      for tok in "${SB_TOKENS[@]}"; do
        base="${tok#*:}"
        if [[ "$(dirname "$base")" == "$cp" ]]; then
          [[ -r "${tok%%:*}" ]] || sb_die "credential ${tok%%:*} not reachable (unreadable on the host)"
          cat -- "${tok%%:*}" > "$dst/$(basename "$base")" || sb_die "credential ${tok%%:*} not reachable"
        fi
      done
      # skill mount points nested in this copy are created HERE, as the operator: an engine-created mount point
      # can be owned by a mapped uid and make the throwaway copy undeletable
      local sm
      sb_skill_mounts
      for sm in "${SB_SKILL_MOUNTS[@]}"; do
        sm="${sm#*:}"
        [[ "$sm" == "$cp"/* ]] && mkdir -p "$dst/${sm#"$cp"/}"
      done
      chmod -R go-rwx "$dst" 2>/dev/null || true
      SB_RUN_MOUNTS+=("$dst:$cp:rw:copy")
    else
      SB_RUN_MOUNTS+=("$src:$cp:$mode:plain")
    fi
  done
  for tok in "${SB_TOKENS[@]}"; do
    [[ -r "${tok%%:*}" ]] || sb_die "credential ${tok%%:*} not reachable (unreadable on the host)"
  done
}

sb_remove_copies() {
  [[ -n "$SB_COPYROOT" ]] || return 0
  rm -rf -- "$SB_COPYROOT" 2>/dev/null || true
  if [[ -e "$SB_COPYROOT" ]]; then printf 'retained credential copy %s\n' "$SB_COPYROOT" >&2; fi
  SB_COPYROOT=""
}

# ---------------------------------------------------------------------------------------------------
# Git layout: overlays, includes, pins
# ---------------------------------------------------------------------------------------------------
sb_overlay_list() {  # → SB_OVERLAYS entries "path:kind" (kind f|d)
  SB_OVERLAYS=()
  [[ "$SB_IS_GIT" -eq 1 ]] || return 0
  local C="$SB_COMMON" w
  SB_OVERLAYS=("$C/config:f" "$C/config.worktree:f" "$C/hooks:d" "$C/info:d" "$C/objects/info:d")
  for w in "$C"/worktrees/*/; do
    [[ -d "$w" ]] || continue
    SB_OVERLAYS+=("${w%/}/config.worktree:f")
  done
  # the CURRENT worktree's own admin dir (a lane): its config.worktree is executable configuration too
  local g="$SB_PROJECT/.git" admin
  if [[ -f "$g" ]]; then
    admin="$(sed -n 's/^gitdir: *//p' "$g" | head -1)"
    [[ "$admin" == /* ]] || admin="$SB_PROJECT/$admin"
    admin="$(sb_canon "$admin")"
    if sb_under "$admin" "$C" && [[ -d "$admin" ]] && ! sb_has "$admin/config.worktree:f" "${SB_OVERLAYS[@]}"; then SB_OVERLAYS+=("$admin/config.worktree:f"); fi
  fi
}
sb_ensure_overlays() {  # missing files/dirs are created empty on the host so they can be overlaid
  local o p k
  sb_overlay_list
  for o in "${SB_OVERLAYS[@]}"; do
    p="${o%:*}"; k="${o##*:}"
    if [[ "$k" == d ]]; then [[ -e "$p" ]] || mkdir -p "$p"; else [[ -e "$p" ]] || : > "$p"; fi
  done
}

# STEP-BY-STEP resolution of an include path, like a manual realpath (every component, every symlink hop, `..` taken on
# the already-resolved directory, restart from / after each hop). Prints "<first offending hop> lands at <path> inside
# <root>" and returns 1 as soon as ANY intermediate resolution lands inside a writable root (project, git common dir),
# even when the chain later leaves it again (outside → inside → outside is exactly the retargetable shape). Git-free.
sb_include_hops() {  # sb_include_hops PATH
  local rest="${1#/}" cur="/" comp next tgt r hop="" n=0
  while [[ -n "$rest" ]]; do
    comp="${rest%%/*}"; if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    case "$comp" in
      ""|.) continue ;;
      ..) cur="${cur%/*}"; [[ -n "$cur" ]] || cur=/; continue ;;
    esac
    next="${cur%/}/$comp"
    if [[ -L "$next" ]]; then
      if (( ++n > 40 )); then printf '%s (too many symbolic links)' "$next"; return 1; fi
      tgt="$(readlink -- "$next")" || tgt=""
      [[ -n "$tgt" ]] || { printf '%s (unreadable link)' "$next"; return 1; }
      [[ "$tgt" == /* ]] || tgt="${cur%/}/$tgt"
      hop="$next"; cur="/"; rest="${tgt#/}${rest:+/$rest}"
      continue
    fi
    cur="$next"
    for r in "$SB_PROJECT" "$SB_COMMON"; do
      [[ -n "$r" && "$r" != / ]] || continue
      if sb_under "$cur" "$r"; then printf '%s lands at %s inside %s' "${hop:-$1}" "$cur" "$r"; return 1; fi
    done
  done
  return 0
}
sb_collect_includes() {  # sb_collect_includes CFGFILE DEPTH → appends canonical targets to SB_INCLUDES
  local f="$1" depth="$2" line val t
  [[ -f "$f" && "$depth" -lt 10 ]] || return 0
  local inc_out irc=0
  inc_out="$(wgm_host_git config --file "$f" --get-regexp '^(include|includeif\..*)\.path$' 2>&1)" || irc=$?
  if [[ "$irc" -gt 1 ]]; then SB_INC_ERR="could not read $f ($inc_out)"; return 0; fi   # 1 = no include lines
  [[ "$irc" -eq 0 ]] || inc_out=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    val="${line#* }"
    [[ -n "$val" ]] || continue
    case "$val" in \~/*) val="$HOME/${val#\~/}" ;; /*) ;; *) val="$(dirname "$f")/$val" ;; esac
    # REFUSAL (chosen over pinning the whole resolution chain: no legitimate layout needs an include that lives in
    # agent-writable space, and a chain pin would still leave the include file itself agent-editable): an include
    # whose path as written — or whose resolved target — lies inside the project or the git common dir is refused
    # here (capture AND launch policy share this resolver), exit 2 naming it. That covers a symlink or file inside the
    # project/common dir, whatever it points at, and an outside symlink that points into them. Chains that stay
    # entirely outside both roots (e.g. dotfile symlinks under $HOME) are operator-owned and pinned by their
    # canonical target.
    t="$(sb_canon "$val")"
    local lx hopmsg; lx="$(sb_lexnorm "$val")"
    local r
    if ! hopmsg="$(sb_include_hops "$val")"; then
      sb_die "launch refused: repository configuration (${f}) includes $val; its resolution passes through a writable mount — ${hopmsg}. An agent could retarget that hop. Move the included file (and every symlink on its path) outside the project and the git directory."
    fi
    for r in "$SB_PROJECT" "$SB_COMMON"; do
      [[ -n "$r" ]] || continue
      if sb_under "$lx" "$r" || sb_under "$t" "$r"; then
        sb_die "launch refused: repository configuration (${f}) includes $val${t:+ (resolves to $t)}, which lies inside the writable mount $r — an agent could edit or retarget it. Move the included file (and every symlink on its path) outside the project and the git directory."
      fi
    done
    sb_has "$t" "${SB_INCLUDES[@]}" && continue
    SB_INCLUDES+=("$t")
    sb_collect_includes "$t" $((depth + 1))
  done <<<"$inc_out"
}
# THE canonical include set (git's own include/includeIf semantics: inline comments, quoting, continuations, ~/ and
# relative paths): resolved with git exactly here — by the launch policy (sb_check_includes) and by the pin capture
# (sb_pin_capture), the SAME function — before any contained command runs, i.e. from trusted state. Sets SB_INCLUDES
# (canonical targets) and SB_INC_ERR. Needs SB_COMMON (and a bound host git).
sb_resolve_includes() {
  SB_INCLUDES=(); SB_INC_ERR=""
  [[ -n "$SB_COMMON" ]] || return 0
  local f
  for f in "$SB_COMMON/config" "$SB_COMMON/config.worktree" "$SB_COMMON"/worktrees/*/config.worktree; do
    sb_collect_includes "$f" 0
  done
}
sb_check_includes() {
  [[ "$SB_IS_GIT" -eq 1 ]] || { SB_INCLUDES=(); SB_INC_ERR=""; return 0; }
  local t
  sb_resolve_includes
  [[ -z "$SB_INC_ERR" ]] || sb_die "launch refused: configuration includes could not be inspected: $SB_INC_ERR. Recovery: restore read permission for the owner on that file."
  for t in "${SB_INCLUDES[@]}"; do
    if sb_under "$t" "$SB_PROJECT" || sb_under "$t" "$SB_COMMON"; then
      sb_die "launch refused: repository configuration includes $t, which lies inside a writable mount (repository configuration must not be agent-editable through an include). Move the included file outside the project and the git directory."
    fi
  done
}

# Content pin of one path. A SYMLINK is pinned by its link text AND the content of its canonical referent
# (the choice: pin, not refuse), so retargeting the link or editing what it points to is detected even on
# engines whose read-only overlay resolves to the referent.
sb_file_sig() {
  if [[ -L "$1" ]]; then
    local ref; ref="$(sb_canon "$1")"
    if [[ -f "$ref" ]]; then printf 'L:%s:%s:%s' "$(readlink "$1")" "$ref" "$(sb_sha256 < "$ref")"
    else printf 'L:%s:%s:%s' "$(readlink "$1")" "$ref" "$([[ -e "$ref" ]] && echo other || echo dangling)"; fi
  elif [[ -f "$1" ]]; then sb_sha256 < "$1"
  elif [[ -e "$1" ]]; then echo "other"
  else echo "absent"; fi
}
# POINTER-FIRST (U14): the files that REDIRECT git (the worktree `.git` file, the admin `gitdir`/`commondir`,
# `objects/info/alternates`) are compared against the pins using ONLY bash builtins, no-follow and
# regular-file checked, from the PINNED layout paths (SB_PIN_GA/SB_PIN_GC captured before the first contained
# command) — before any directory resolution, scan, config signature, include collection or host git call.
SB_PIN_GA=""; SB_PIN_GC=""
# lstat-style check of EVERY component from ROOT (inclusive) down to PATH: none may be a symlink. Prints the
# offending component and fails — before anything under it is read (a replaced admin dir / ancestor must never
# make a pointer read resolve outside the repo).
sb_chain_ok() {  # sb_chain_ok PATH ROOT
  local p="$1" root="$2" rel cur comp
  local -a comps=()
  if [[ -n "$root" && "$p" == "$root"/* ]]; then
    rel="${p#"$root"/}"; cur="$root"
    if [[ -L "$cur" ]]; then printf '%s' "$cur"; return 1; fi
  else rel="${p#/}"; cur=""; fi
  IFS=/ read -r -a comps <<<"$rel"
  for comp in "${comps[@]}"; do
    cur="$cur/$comp"
    if [[ -L "$cur" ]]; then printf '%s' "$cur"; return 1; fi
  done
  return 0
}
sb_ptr_read() {  # FILE [ROOT] → "file:sha256:<digest of the raw bytes>" | symlink | other | absent  (never follows a symlink, never reads a FIFO)
  local bad
  if ! bad="$(sb_chain_ok "$1" "${2:-}")"; then sb_trust_die "$bad" "git metadata changed by the agent: $bad (on the path to $1) is a symlink — refusing to read through it. Recovery: remove that LINK itself, never its target."; fi
  if [[ -L "$1" ]]; then printf 'symlink'
  elif [[ -f "$1" ]]; then printf 'file:sha256:%s' "$(sb_sha256 < "$1")"   # the EXACT bytes (a `$(<file)` read would drop trailing newlines)
  elif [[ -e "$1" ]]; then printf 'other'
  else printf 'absent'; fi
}
sb_pointer_sig() {
  local g="$SB_PROJECT/.git"
  if [[ -L "$g" ]]; then echo "git:symlink"
  elif [[ -f "$g" ]]; then echo "git:$(sb_ptr_read "$g" "$SB_PROJECT")"
  elif [[ -d "$g" ]]; then echo "git:dir:$(sb_stat_id "$g")"
  else echo "git:absent"; fi
  echo "ga:$SB_PIN_GA"; echo "gc:$SB_PIN_GC"
  if [[ -n "$SB_PIN_GA" && "$SB_PIN_GA" != "$SB_PIN_GC" ]]; then
    echo "gitdir:$(sb_ptr_read "$SB_PIN_GA/gitdir" "$SB_PIN_GC")"; echo "commondir:$(sb_ptr_read "$SB_PIN_GA/commondir" "$SB_PIN_GC")"
  fi
  if [[ -n "$SB_PIN_GC" ]]; then
    echo "alt:$(sb_ptr_read "$SB_PIN_GC/objects/info/alternates" "$SB_PIN_GC")"; echo "httpalt:$(sb_ptr_read "$SB_PIN_GC/objects/info/http-alternates" "$SB_PIN_GC")"
  fi
}
sb_verify_pointers() {
  [[ -n "$SB_PIN_PTR" ]] || return 0
  [[ "$(sb_pointer_sig)" == "$SB_PIN_PTR" ]] || sb_trust_die "${SB_PIN_GA:-$SB_PROJECT/.git}" "git metadata changed by the agent — refusing to continue (inspect .git, its worktree admin files gitdir/commondir and objects/info/alternates)"
}
# EXECUTABLE-CONFIG CONTENT PIN — computed and compared WITHOUT git (host git must not consume possibly-changed
# configuration before the verdict exists). Raw-bytes sha256 digests, no-follow and regular-file checked, of
# <common>/config, <common>/config.worktree, <common>/worktrees/*/config.worktree and every include target found by
# the include targets of the CANONICAL include set SB_PIN_INC, which sb_pin_capture resolved with git ONCE (before any
# contained command; see sb_resolve_includes) and stores with the pin. At verify time nothing is re-parsed: the raw
# digests of the including files catch any include-line change, and the stored target list is re-digested without git.
# The hooks/, info/, objects/info/ listing digests as before. A symlinked or non-regular config/included file is
# `__UNINSPECTABLE__` (refused); a target that does not exist yet is pinned as absent (creating it changes the digest).
sb_raw_sig() {  # sb_raw_sig FILE → sha256 | absent | UNINSPECTABLE:<why>
  if [[ -L "$1" ]]; then printf 'UNINSPECTABLE:%s is a symlink' "$1"
  elif [[ -f "$1" ]]; then sb_sha256 < "$1"
  elif [[ -e "$1" ]]; then printf 'UNINSPECTABLE:%s is not a regular file' "$1"
  else printf 'absent'; fi
}
sb_pin_config() {
  [[ -n "$SB_COMMON" ]] || { echo none; return 0; }
  local C="$SB_COMMON" f t lst lrc=0 body sig bad=""
  local -a fo=(); sb_find_irr && fo=(-ignore_readdir_race)
  lst="$(cd "$C" && find hooks info objects/info "${fo[@]}" \( -type f -o -type l -o -type d \) 2>&1)" || lrc=$?
  local perr; perr="$(sb_real_errors "$(grep '^find: ' <<<"$lst" || true)" hooks info objects/info)"
  if ! sb_find_ok "$lrc" "$lst" hooks info objects/info; then
    [[ -n "$perr" ]] || perr="no diagnostics: find failed silently or was killed"
    echo "__UNINSPECTABLE__ $(head -3 <<<"$perr" | tr '\n' ' ')(find exited $lrc)"; return 0
  fi
  lst="$(grep -v '^find: ' <<<"$lst" || true)"
  body="$(
    for f in "$C/config" "$C/config.worktree"; do echo "$f:$(sb_raw_sig "$f")"; done
    echo "admins:$(for f in "$C"/worktrees/*; do [[ -e "$f" ]] && basename "$f"; done | LC_ALL=C sort | tr '\n' ' ')"
    for f in "$C"/worktrees/*/config.worktree; do [[ -e "$f" || -L "$f" ]] && echo "$f:$(sb_raw_sig "$f")"; done
    while IFS= read -r f; do [[ -n "$f" ]] && echo "$f:$(sb_file_sig "$C/$f")"; done < <(printf '%s\n' "$lst" | LC_ALL=C sort)
    for t in "${SB_PIN_INC[@]}"; do echo "include:$t:$(sb_raw_sig "$t")"; done
  )"
  bad="$(grep -m1 -o 'UNINSPECTABLE:.*' <<<"$body" || true)"
  if [[ -n "$bad" ]]; then echo "__UNINSPECTABLE__ ${bad#UNINSPECTABLE:}"; return 0; fi
  sb_sha256 <<<"$body"
}
sb_pin_uninspectable() {
  [[ "$1" != __UNINSPECTABLE__* ]] || sb_die "launch refused: could not inspect the git directory (${1#__UNINSPECTABLE__ }). Recovery: restore read/execute permission for the owner on the path named above, or move it out of the project."
}
sb_pin_capture() {
  local WGM_PIN_FILE=""   # (resolving the include set below runs host git: not against another pin file)
  SB_PIN_PTR=""   # a (re)capture resolves the include set with host git: it must not be checked against the OLD pins
  if sb_gitdir_resolve "$SB_PROJECT"; then SB_PIN_GA="$SB_GA"; SB_PIN_GC="$SB_GC"; else SB_PIN_GA=""; SB_PIN_GC=""; fi
  sb_resolve_includes
  [[ -z "$SB_INC_ERR" ]] || sb_die "launch refused: configuration includes could not be inspected: $SB_INC_ERR. Recovery: restore read permission for the owner on that file."
  SB_PIN_INC=("${SB_INCLUDES[@]}")
  SB_PIN_PTR="$(sb_pointer_sig)"; SB_PIN_CFG="$(sb_pin_config)"; sb_pin_uninspectable "$SB_PIN_CFG"
}
# Order after every contained command: (1) pointer files vs pins (builtins only), (2) the git-dir type guard
# from the pinned layout (+ full objects/ scan when asked), (3) the config pins. Nothing earlier may touch git.
# TRUST-LOST contract (for swarm.sh): when WGM_TRUST_LOST_FILE names a file, a pin/guard violation APPENDS exactly
# one line `trust lost <path>` (the offending git-dir path, or the git dir itself for a content change) to it BEFORE the
# process exits 2 — created 0600, never through a symlink; the caller must then refuse any further host git for that
# tree. The same refusal text is printed on stderr.
sb_trust_lost() {  # sb_trust_lost PATH
  local f="${WGM_TRUST_LOST_FILE:-}"
  [[ -n "$f" ]] || return 0
  if [[ -L "$f" || ( -e "$f" && ! -f "$f" ) ]]; then return 0; fi
  # inside a writable root the no-follow guard covers EVERY component (an agent-planted symlinked ancestor included)
  ( sb_safe_path "$f" ) >/dev/null 2>&1 || { sb_note "WGM_TRUST_LOST_FILE $f lies in a writable root through a symlink — not written"; return 0; }
  ( umask 077; printf 'trust lost %s\n' "$1" >> "$f" ) 2>/dev/null || true
}
sb_trust_die() {  # sb_trust_die PATH MESSAGE…
  local p="$1"; shift
  sb_trust_lost "$p"
  sb_die "$*"
}
sb_verify_pins() {  # sb_verify_pins [full] — exit 2 when the agent changed git metadata/configuration (NO host git before the verdict)
  [[ -n "$SB_PIN_PTR" ]] || return 0
  sb_verify_pointers
  sb_gitdir_guard "$SB_PROJECT" "${1:-cheap}" --expect-common "$SB_PIN_GC"
  local c
  c="$(sb_pin_config)"
  if [[ "$c" == __UNINSPECTABLE__* ]]; then sb_trust_lost "$SB_PIN_GC"; fi
  sb_pin_uninspectable "$c"
  if [[ "$c" != "$SB_PIN_CFG" ]]; then sb_trust_die "$SB_PIN_GC" "git configuration changed by the agent — refusing to continue (inspect config, config.worktree, worktrees/*/config.worktree, their includes, hooks/, info/ in the git directory)"; fi
}
# Pin persistence for callers that cannot keep shell state across the agent run (swarm): capture ONCE before any
# container, verify before the post-run host git. FILE format (0600): PROJECT=<dir> / GA= / GC= / CFG=<digest> / one
# INC=<canonical include target> per resolved include and the pointer signature between PTR_BEGIN and PTR_END.
# Capture needs NO preflight state (only a bound host git, which it uses ONCE to resolve the include set — call it
# before any contained command); verify is git-free; `sb_pin_capture_to FILE [PROJECT]`
# defaults PROJECT to the cwd; `sb_pin_verify_from FILE` exits 2 on ANY mismatch (and appends `trust lost <path>` to
# WGM_TRUST_LOST_FILE when set).
# WGM_PIN_FILE (CONTRACT for swarm.sh and any helper process): `sb_pin_capture_to FILE LANE_DIR` BEFORE any container (a
# subshell is fine), then export WGM_PIN_FILE=FILE for every process that runs host git on that lane — wgm_host_git
# then verifies the pins before each call (exit 2 + `trust lost <path>` in WGM_TRUST_LOST_FILE on any mismatch; a named but
# missing/symlinked/unreadable pin file is itself a refusal). Explicit `sb_pin_verify_from FILE` before the post-run git
# stays as before. (sb_pin_capture / sb_pin_capture_to ignore WGM_PIN_FILE for their own git calls.)
# The repository ACTUALLY targeted, wherever its working tree lives: resolve DIR's git store (common dir) git-free and
# no-follow (sb_gitdir_resolve, in a subshell so SB_GA/SB_GC of the caller are untouched). `sb_dir_store_is DIR GC`
# succeeds when that store equals GC; a store that cannot be resolved SAFELY (a planted symlink, redirected pointers) is a
# refusal (exit 2); a directory that is in no repository at all is simply "not that store" (git itself will fail on it).
sb_dir_store_is() {  # sb_dir_store_is DIR GC
  local out rc=0
  [[ -n "$2" ]] || return 1
  out="$( sb_gitdir_resolve "$1" && printf '%s' "$SB_GC" )" || rc=$?
  if [[ "$rc" -eq 0 ]]; then [[ "$(sb_lexnorm "$out")" == "$(sb_lexnorm "$2")" ]]; return; fi
  [[ "$rc" -eq 1 ]] && return 1
  sb_die "host git refused: the git store of $1 cannot be resolved safely, so the pins cannot be associated with it"
}
sb_verify_pin_file_for() {  # sb_verify_pin_file_for FILE DIR
  local file="$1" dir="$2" line proj="" gc=""
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] || sb_die "WGM_PIN_FILE $file is missing, a symlink or unreadable — refusing host git (the pins it holds cannot be verified)"
  while IFS= read -r line; do
    case "$line" in PROJECT=*) proj="${line#PROJECT=}" ;; GC=*) gc="${line#GC=}" ;; PTR_BEGIN) break ;; esac
  done < "$file"
  if { [[ -n "$proj" ]] && sb_under "$dir" "$proj"; } || { [[ -n "$gc" ]] && sb_under "$dir" "$gc"; } || sb_dir_store_is "$dir" "$gc"; then
    # verified in a SUBSHELL (sb_pin_verify_from loads the file into SB_* globals); its exit status is the verdict
    ( sb_pin_verify_from "$file" ) || exit "$?"
  fi
}
# sb_pin_recapture_to FILE [PROJECT] — RE-PIN after an AUTHORIZED change wgm itself made to the pinned repository (e.g.
# removing a lane worktree, which legitimately changes the admin listing the pins cover), so callers never have to disable
# verification. CONTRACT: call `sb_pin_verify_from FILE` (or just run a wgm_host_git call, which verifies) IMMEDIATELY
# BEFORE the authorized operation, perform ONLY that wgm-owned operation, then recapture immediately after — no contained
# command may run in between. It rewrites FILE atomically (0600) from the current state of PROJECT (default: the project
# recorded in FILE); verification stays on for every later call.
sb_pin_recapture_to() {
  local file="$1" proj="${2:-}" line tmp
  if [[ -z "$proj" ]]; then
    [[ -f "$file" && ! -L "$file" ]] || sb_die "pin file $file is missing or a symlink — cannot re-pin"
    while IFS= read -r line; do case "$line" in PROJECT=*) proj="${line#PROJECT=}"; break ;; esac; done < "$file"
  fi
  [[ -n "$proj" ]] || sb_die "pin file $file names no project — cannot re-pin"
  tmp="$file.new.$$"
  ( sb_pin_capture_to "$tmp" "$proj" ) || { rm -f "$tmp"; exit 2; }   # (subshell: the caller's own SB_* state is not clobbered)
  mv -f "$tmp" "$file"
}
sb_pin_capture_to() {
  local WGM_PIN_FILE=""
  local file="$1" proj="${2:-.}" i
  SB_PROJECT="$(cd "$proj" && pwd -P)"
  SB_COMMON=""; if sb_gitdir_resolve "$SB_PROJECT"; then SB_COMMON="$SB_GC"; fi
  sb_pin_capture
  ( umask 077
    { printf 'PROJECT=%s\nGA=%s\nGC=%s\nCFG=%s\n' "$SB_PROJECT" "$SB_PIN_GA" "$SB_PIN_GC" "$SB_PIN_CFG"
      for i in "${SB_PIN_INC[@]}"; do printf 'INC=%s\n' "$i"; done
      printf 'PTR_BEGIN\n%s\nPTR_END\n' "$SB_PIN_PTR"; } > "$file" ) || sb_die "cannot write the pin file $file"
}
sb_pin_verify_from() {
  local file="$1" line mode=""
  [[ -f "$file" && ! -L "$file" ]] || sb_die "pin file $file is missing or a symlink"
  SB_PIN_PTR=""; SB_PIN_INC=()
  while IFS= read -r line; do
    case "$mode:$line" in
      :PROJECT=*) SB_PROJECT="${line#PROJECT=}" ;; :GA=*) SB_PIN_GA="${line#GA=}" ;; :GC=*) SB_PIN_GC="${line#GC=}"; SB_COMMON="$SB_PIN_GC" ;;
      :CFG=*) SB_PIN_CFG="${line#CFG=}" ;; :INC=*) SB_PIN_INC+=("${line#INC=}") ;; :PTR_BEGIN) mode=ptr ;;
      ptr:PTR_END) mode="" ;;
      ptr:*) SB_PIN_PTR+="${SB_PIN_PTR:+$'\n'}$line" ;;
    esac
  done < "$file"
  [[ -n "$SB_PIN_PTR" ]] || sb_die "pin file $file is malformed"
  sb_verify_pins full
}

# SAFE HOST WRITES / READS under the project: refuse agent-written symlinks anywhere on the path.
# EVERY agent-writable root: the project, the git common dir (inside the project, or EXTERNAL as for a worktree — the
# agent writes there too) and the host side of any other rw mount in the plan. The no-follow guards cover all of them.
sb_writable_roots() {  # prints one root per line
  local m h
  [[ -n "$SB_PROJECT" ]] && printf '%s\n' "$SB_PROJECT"
  [[ -n "$SB_COMMON" ]] && printf '%s\n' "$SB_COMMON"
  for m in "${SB_MOUNTS[@]}"; do
    [[ "$m" == *:rw ]] || continue
    h="${m%%:*}"; [[ -n "$h" && "$h" != "$SB_PROJECT" && "$h" != "$SB_COMMON" ]] && printf '%s\n' "$h"
  done
  return 0
}
sb_safe_path() {  # sb_safe_path FILE [read] — exit 2 on a symlink at/above FILE inside ANY agent-writable root
  local f="$1" abs can d root hit=0
  [[ -n "$f" && -n "$SB_PROJECT" ]] || return 0
  abs="$(sb_abs "$f")"
  can="$(sb_canon "$abs")"
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    if sb_under "$abs" "$root"; then
      hit=1
      d="$abs"
      while [[ "$d" != "$root" && "$d" != "/" && -n "$d" ]]; do
        if [[ -L "$d" ]]; then sb_die "agent-written symlink at $d — refusing to follow"; fi
        d="$(dirname "$d")"
      done
    elif sb_under "$can" "$root"; then
      # the destination lies inside the writable root only THROUGH a link outside it: it cannot be guarded component by
      # component from the root down, so it is refused rather than followed
      sb_die "host path $f resolves to $can inside the agent-writable root $root through a symlink outside it — refusing (give the path as it appears under $root)"
    fi
  done < <(sb_writable_roots)
  if [[ "$hit" -eq 1 && -e "$abs" && ! -f "$abs" ]]; then sb_die "agent-written symlink at $abs — refusing to follow (not a regular file)"; fi
  return 0
}

# ---------------------------------------------------------------------------------------------------
# Host environment = ALLOWLIST (re-exec under env -i)
# ---------------------------------------------------------------------------------------------------
sb_clean_path() {  # sanitized PATH on stdout; dropped entries reported on stderr unless quiet
  local quiet="$1" e out="" c w ok
  local IFS=':'
  for e in $PATH; do
    ok=1
    if [[ -z "$e" || "$e" != /* ]]; then ok=0
    else
      c="$(sb_canon "$e")"
      for w in "${SB_WRITABLE[@]}"; do [[ -n "$w" ]] && sb_under "$c" "$w" && ok=0; done
    fi
    if [[ "$ok" -eq 1 ]]; then out="${out:+$out:}$e"; else [[ "$quiet" == 1 ]] || sb_note "host env: dropped PATH entry ${e:-<empty>}"; fi
  done
  printf '%s' "$out"
}

SB_WRITABLE=()
SB_PATH_DROPPED=()
# Pure-bash first pass: drop empty/relative PATH entries and entries textually inside ROOT, so no
# project-planted wrapper can run before the full (canonicalizing) sanitization. Result in SB_CLEAN_PATH.
SB_CLEAN_PATH=""
sb_path_text_clean() {
  local root="$1" e out="" IFS=':'
  SB_PATH_DROPPED=()
  for e in $PATH; do
    if [[ -z "$e" || "$e" != /* ]] || { [[ -n "$root" ]] && sb_under "$e" "$root"; }; then SB_PATH_DROPPED+=("${e:-<empty>}")
    else out="${out:+$out:}$e"; fi
  done
  SB_CLEAN_PATH="$out"
}
# ONE in-process VALUE filter (spec: a variable whose VALUE points into a writable mount is not trusted): every
# engine/config path variable — TMPDIR, CONTAINER_HOST, CONTAINERS_CONF, CONTAINERS_STORAGE_CONF, DOCKER_HOST,
# DOCKER_CONFIG, XDG_RUNTIME_DIR, XDG_DATA_HOME, XDG_CONFIG_HOME (relative values resolved against the cwd), and the
# retained TZ / LANG / LC_* / TERM when their value contains a `/` (colon lists element-wise) — whose canonical value equals or lies inside any of
# THIS invocation's CURRENT writable roots (SB_WRITABLE: project, git common dir) is unset and REPORTED
# (always, quiet or not); XDG_CONFIG_HOME inside one is a named exit 2 (the operator-owned record must live outside
# every mount). It runs on EVERY entry path, at the end of sb_bootstrap_host_env (direct devcontainer.sh, standalone
# loop.sh, preflight, and lane loops that INHERIT a clean environment, whose roots differ from the parent's) and
# before any engine use; sb_clean_env_exec calls it too. Needs SB_WRITABLE set and tools bound. (devcontainer.sh, which
# keeps no record, sets SB_FILTER_SOFT=1: XDG_CONFIG_HOME is then dropped and reported instead of refused.)
# THE retained-variable inventory (the allowlist-completeness test asserts every name the allowlists keep is in one of
# these lists or the shell/credential/protocol set below):
#   SB_ENV_PATHVARS  — value IS a path (a relative one resolves against the cwd): value-filtered
#   SB_ENV_NAMEVARS  — value is a name OR a path (checked only when it contains a `/`): value-filtered; DOCKER_CONTEXT
#                      additionally resolves through the context store ${DOCKER_CONFIG:-$HOME/.docker}/contexts
#   JUSTIFIED (not filtered, on purpose): PWD OLDPWD SHLVL _ (shell-maintained, rewritten); PATH (sanitized by the
#   bootstrap, never trusted as given); HOME USER LOGNAME (the operator's identity root — HOME is not a loader path and
#   the record directory derived from it is guarded by sb_record_dir_guard); WGM_* (wgm's own protocol, validated where
#   used); approved credential names (forwarded by NAME to the container, never read by a host engine process).
SB_ENV_PATHVARS=(TMPDIR CONTAINER_HOST CONTAINERS_CONF CONTAINERS_STORAGE_CONF DOCKER_HOST DOCKER_CONFIG XDG_RUNTIME_DIR XDG_DATA_HOME XDG_CONFIG_HOME)
SB_ENV_NAMEVARS=(TZ LANG TERM DOCKER_CONTEXT)   # (+ every LC_*)
# shellcheck disable=SC2034  # read by the allowlist-completeness test (test-sandbox.sh)
SB_ENV_JUSTIFIED=(PWD OLDPWD SHLVL _ PATH HOME USER LOGNAME)
# RUNTIME-TREE POLICY against the ORIGINAL runtime locations, captured before any value filtering can drop them: the
# XDG_RUNTIME_DIR as given, /run/user/<uid> and the directory of a `unix://` engine socket named by CONTAINER_HOST /
# DOCKER_HOST. If any of them lies inside, or contains, a writable root (project, git common dir) the run is refused (exit 2,
# naming the runtime tree and the variable) before any container — the value filter may still drop the variable afterwards
# for host hygiene, but it can no longer hide the condition from the contract ("a mount that contains or lies in a runtime
# tree is refused"). Runs at the start of sb_filter_env_values, i.e. on every entry path, with this invocation's roots.
sb_runtime_tree_check() {
  local w rt src v e
  local -a cands=()
  [[ -n "${XDG_RUNTIME_DIR:-}" ]] && cands+=("XDG_RUNTIME_DIR:${XDG_RUNTIME_DIR}")
  cands+=("/run/user/$UID:/run/user/$UID")
  for e in CONTAINER_HOST DOCKER_HOST; do
    v="${!e:-}"; [[ "$v" == unix://* ]] || continue
    v="${v#unix://}"; [[ "$v" == /* ]] && cands+=("$e:${v%/*}")
  done
  for src in "${cands[@]}"; do
    v="${src#*:}"; [[ "$v" == /* ]] || v="$PWD/$v"
    rt="$(sb_canon "$v")"
    for w in "${SB_WRITABLE[@]}"; do
      [[ -n "$w" ]] || continue
      if sb_under "$rt" "$w" || sb_under "$w" "$rt"; then
        sb_die "mount refused (writable mount): $w lies in or contains the runtime tree $rt (${src%%:*}); the agent must not be able to reach a runtime/socket directory. Move the project or point ${src%%:*} elsewhere."
      fi
    done
  done
}
sb_filter_env_values() {
  sb_runtime_tree_check
  local n v e w hit el p ctxdir
  local -a els=() cand=()
  # (a) engine/config path variables: values are paths; a RELATIVE value is resolved against the current directory
  # (b) every other retained variable whose value can name a path — TZ (also `:path`), LANG, LC_*, TERM — only when
  #     the value contains a `/` (a plain zone/locale/terminal name is not a path); a relative TZ is also resolved
  #     against the zoneinfo directory, as libc does. Colon-separated values are checked element-wise.
  # Everything else the allowlist keeps (HOME, USER, LOGNAME) is identity, not a loader path; any other path-bearing
  # variable (TERMINFO*, LOCPATH, NLSPATH, SSL_CERT_*, GCONV_PATH, …) is not on the allowlist at all and is dropped.
  for n in "${SB_ENV_PATHVARS[@]}" "${SB_ENV_NAMEVARS[@]}" $(compgen -e -X '!LC_*'); do
    [[ -n "${!n:-}" ]] || continue
    if [[ "$n" == DOCKER_CONTEXT ]]; then
      # a context NAME resolves through the context store; if that store lies inside a writable root its endpoint/metadata
      # are agent-controlled: drop the selection (docker then uses its default context)
      ctxdir="${DOCKER_CONFIG:-$HOME/.docker}/contexts"
      for w in "${SB_WRITABLE[@]}"; do
        [[ -n "$w" ]] || continue
        if sb_under "$(sb_canon "$ctxdir")" "$w"; then
          sb_note "host env: dropped DOCKER_CONTEXT (its context store $ctxdir lies inside the writable mount $w)"; unset DOCKER_CONTEXT; break
        fi
      done
      [[ -n "${DOCKER_CONTEXT:-}" ]] || continue
    fi
    v="${!n}"; e="${v#unix://}"
    [[ "$e" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]] && continue    # tcp://, ssh://… — not a filesystem path
    IFS=: read -r -a els <<<"$e"
    hit=""
    for el in "${els[@]}"; do
      [[ -n "$el" ]] || continue
      case "$n" in
        TZ|LANG|LC_*|TERM|DOCKER_CONTEXT) [[ "$el" == */* ]] || continue ;;
      esac
      cand=()
      if [[ "$el" == /* ]]; then cand=("$el"); else
        cand=("$PWD/$el")
        [[ "$n" == TZ && "$el" != ./* && "$el" != ../* ]] && cand=("/usr/share/zoneinfo/$el")
        [[ "$n" == TZ && ( "$el" == ./* || "$el" == ../* ) ]] && cand+=("/usr/share/zoneinfo/$el")
      fi
      for p in "${cand[@]}"; do
        for w in "${SB_WRITABLE[@]}"; do
          [[ -n "$w" ]] || continue
          if sb_under "$(sb_canon "$p")" "$w"; then hit="$w"; break 3; fi
        done
      done
    done
    [[ -n "$hit" ]] || continue
    [[ "$n" == XDG_CONFIG_HOME && "${SB_FILTER_SOFT:-0}" != 1 ]] && sb_die "XDG_CONFIG_HOME ($v) lies inside the writable mount $hit; the operator-owned record must live outside every mount (set XDG_CONFIG_HOME elsewhere)"
    sb_note "host env: dropped $n (its value $v lies inside the writable mount $hit)"
    unset "$n"
  done
}
# C7 TWO-PHASE HOST ENVIRONMENT. PHASE 1 — the FIRST host action of loop.sh / sandbox.sh preflight /
# devcontainer.sh (swarm.sh: call it first too): `sb_env_allowlist_inproc [EXTRA_NAME…]`, bash builtins only,
# unsets every exported variable and exported function that is not on the allowlist — WGM_*, the essential
# variables, the engine-selection variables, every credential-TABLE name as a CANDIDATE (values never go on an
# argv) and any EXTRA_NAME — before ANY external tool runs. `sb_sandbox_may_be_on "$@"` (builtins) says whether
# the invocation may become sandboxed (no --no-devcontainer, WGM_DEVCONTAINER!=0, not already inside); an
# unsandboxed run must keep its environment. PHASE 2 — once the DECISION exists: `sb_apply_decision_env`
# (call after sb_parse_decision / preflight) unsets every credential name the decision did not approve, before any
# agent or other host work, and sets SB_KEEP_ENV (the approved names) for the host re-exec. Contract for swarm:
# call sb_env_allowlist_inproc first, sb_bootstrap_host_env next, run preflight, then sb_apply_decision_env with the
# decision parsed; carry the approved names (the decision's env= lines) through swarm's own re-exec into every lane.
# Usage text from a script's leading comment block — BASH BUILTINS ONLY. Help/usage/early-exit paths run before the host
# environment is allowlisted and the tools are bound, so a PATH-resolved awk/sed/cat (a project bin/ first on PATH) must
# never be reachable from them. (Same output as the old `awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}'`.)
sb_usage_from() {  # sb_usage_from FILE
  local l n=0
  while IFS= read -r l; do
    n=$((n + 1)); (( n > 1 )) || continue
    [[ "$l" == "#"* ]] || break
    l="${l#"#"}"; l="${l# }"
    printf '%s\n' "$l"
  done < "$1"
}
sb_sandbox_may_be_on() {
  local a
  [[ -z "${WGM_IN_DEVCONTAINER:-}" && "${WGM_DEVCONTAINER:-}" != 0 ]] || return 1
  for a in "$@"; do [[ "$a" == --no-devcontainer ]] && return 1; [[ "$a" == -- ]] && break; done
  return 0
}
sb_env_allowlist_inproc() {  # sb_env_allowlist_inproc [EXTRA_NAME…]
  local n fn _d1 _d2 keep dropped=""
  keep=" $(sb_all_cred_env_names) $* "
  for n in $(compgen -e); do
    case "$n" in
      PWD|OLDPWD|SHLVL|_|PATH|HOME|USER|LOGNAME|LANG|LC_*|TZ|TERM|TMPDIR|XDG_RUNTIME_DIR|XDG_DATA_HOME|XDG_CONFIG_HOME) continue ;;
      WGM_GIT_ENV_APPLIED) ;;   # dropped with the GIT_* variables it vouches for (re-applied by sb_export_git_env)
      CONTAINER_HOST|CONTAINERS_CONF|CONTAINERS_STORAGE_CONF|DOCKER_HOST|DOCKER_CONFIG|DOCKER_CONTEXT|WGM_*) continue ;;
    esac
    [[ "$keep" == *" $n "* ]] && continue
    if unset "$n" 2>/dev/null; then dropped+="$n "; fi
  done
  while read -r _d1 _d2 fn; do unset -f "$fn" 2>/dev/null || true; done < <(declare -Fx)
  if [[ "${WGM_HOST_ENV_QUIET:-0}" != 1 ]]; then for n in $dropped; do sb_note "host env: dropped $n"; done; fi
}
sb_apply_decision_env() {
  local n
  SB_KEEP_ENV=("${SB_ENVS[@]}")
  for n in $(sb_all_cred_env_names); do sb_has "$n" "${SB_ENVS[@]}" || unset "$n"; done
}
# sb_clean_env_exec QUIET SCRIPT ARGS… — never returns on success. SPEC C8: the clean host environment is built
# IN-PROCESS (the C7 allowlist: unset every non-allowlisted variable and exported function) and the runner then
# re-executes itself with a PLAIN `exec bash script args…` — NEVER `env -i NAME=value … bash …`, which would put
# credential VALUES on the host command line (SHA-bound probe S46). No NAME=value argument exists anywhere.
sb_clean_env_exec() {
  local quiet="$1" script="$2"; shift 2
  local n v w drop envbin extra fn _d1 _d2
  sb_filter_env_values
  # only the credential env NAMES actually APPROVED survive (SB_KEEP_ENV); preflight, which does not know the
  # approvals before it has read the record, sets SB_KEEP_ALL_CRED=1 and strips the unapproved names itself
  # (in-process) as soon as the approvals are known and before any container launches
  if [[ "${SB_KEEP_ALL_CRED:-0}" == 1 ]]; then extra=" $(sb_all_cred_env_names) "; else extra=" ${SB_KEEP_ENV[*]:-} "; fi
  for n in $(compgen -e); do
    case "$n" in PWD|OLDPWD|SHLVL|_|PATH) continue ;; esac
    v="${!n}"; drop=0
    case "$n" in
      HOME|USER|LOGNAME|LANG|LC_*|TZ|TERM|TMPDIR|XDG_RUNTIME_DIR|XDG_DATA_HOME|XDG_CONFIG_HOME) ;;
      CONTAINER_HOST|CONTAINERS_CONF|CONTAINERS_STORAGE_CONF|DOCKER_HOST|DOCKER_CONFIG|DOCKER_CONTEXT) ;;
      WGM_*) ;;
      *) if [[ "$extra" == *" $n "* ]]; then :; else drop=1; fi ;;
    esac
    if [[ "$drop" -eq 1 ]]; then
      [[ "$quiet" == 1 ]] || sb_note "host env: dropped $n"
      unset "$n" 2>/dev/null || true
    fi
  done
  # The clean environment is built IN-PROCESS (unset everything off the allowlist, then exec): no
  # NAME=value argument ever exists, so a credential VALUE never appears in any observable argv.
  while read -r _d1 _d2 fn; do unset -f "$fn" 2>/dev/null || true; done < <(declare -Fx)   # exported functions
  PATH="$(sb_clean_path "$quiet")"; export PATH
  export WGM_HOST_ENV_CLEAN=1
  # the whole host process tree gets the git protections (none of GIT_* survived the allowlist, so count starts at 0)
  while IFS= read -r v; do declare -gx "${v%%=*}=${v#*=}"; done < <(sb_git_env_pairs 0)
  # (the bound-tools dir deliberately SURVIVES the exec: the same pid keeps owning it)
  # SHELLOPTS/BASHOPTS are readonly: if the caller exported them, strip them for the new shell by NAME only
  envbin=/usr/bin/env; [[ -x "$envbin" ]] || envbin="$(command -v env)"
  if [[ -n "$(compgen -e | grep -E '^(SHELLOPTS|BASHOPTS)$' || true)" ]]; then
    exec "$envbin" -u SHELLOPTS -u BASHOPTS "$BASH" "$script" "$@"
  fi
  exec "$BASH" "$script" "$@"
}

# HOST TOOLS ARE BOUND, NOT JUST CHECKED. `sb_bootstrap_host_env PROJECT` is the FIRST thing loop.sh / swarm.sh /
# sandbox.sh preflight do in sandbox mode: using only bash builtins it (1) drops relative/empty/project-inside PATH
# entries, (2) finds the writable roots (project + common dir, parsed in bash), (3) runs the host-tool check with
# the system's absolute find/readlink as the only bootstrap tools, and (4) builds a private dir of symlinks to the
# VERIFIED canonical targets of every tool wgm invokes and prepends it to PATH — so later invocations execute
# exactly the files that were checked (tools outside the list still resolve through the sanitized PATH).
# Callers (swarm.sh): call it before any other external command; `sb_cleanup` removes SB_BINDIR.
SB_BINDIR=""; SB_BOOT_FIND=""; SB_BOOT_RM=""
# THE inventory of external commands the owned scripts may run (bound by sb_bootstrap_host_env, checked by
# sb_check_host_tools). test-sandbox.sh statically scans loop.sh/sandbox.sh/devcontainer.sh for external commands at
# command position and fails if one is missing here — add new tools HERE (fallback and helper paths included).
# `gh` is OPTIONAL: bound only when it resolves (the loop below skips what is absent); harvest-hive.sh — the host-side
# Ship/Handoff hook, run by loop.sh and swarm.sh — resolves it through PATH, so the bound, verified copy must be what runs.
SB_BOUND_TOOLS=(git date find mktemp sha1sum sha256sum shasum cksum readlink stat sed awk grep cat cp mv rm mkdir chmod head tail tr sort comm dirname basename id uname sleep seq flock env bash jj podman docker timeout gtimeout ls wc cut xargs touch ln rmdir tee ps gh)
sb_boot_tool() { local d; for d in /usr/bin /bin; do [[ -x "$d/$1" ]] && { printf '%s' "$d/$1"; return 0; }; done; return 1; }
sb_bootstrap_host_env() {  # sb_bootstrap_host_env PROJECT
  local proj="$1" tb mk ln rl name p c pe
  proj="$(cd "$proj" && pwd -P)"
  sb_path_text_clean "$proj"; PATH="$SB_CLEAN_PATH"; export PATH
  if [[ "${WGM_HOST_ENV_QUIET:-0}" != 1 ]]; then for pe in "${SB_PATH_DROPPED[@]}"; do sb_note "host env: dropped PATH entry $pe"; done; fi
  SB_PROJECT="$proj"; SB_COMMON=""
  if sb_gitdir_resolve "$proj"; then SB_COMMON="$SB_GC"; fi
  SB_WRITABLE=("$proj" "$SB_COMMON")
  SB_BOOT_FIND="$(sb_boot_tool find)" || SB_BOOT_FIND=""
  rl="$(sb_boot_tool readlink)" || rl=""
  mk="$(sb_boot_tool mktemp)" || mk=""; ln="$(sb_boot_tool ln)" || ln=""; SB_BOOT_RM="$(sb_boot_tool rm)" || SB_BOOT_RM=""
  if [[ -z "$SB_BOOT_FIND" || -z "$rl" || -z "$mk" || -z "$ln" ]]; then sb_die "cannot bootstrap the host tool check: find/readlink/mktemp/ln were not found under /usr/bin or /bin"; fi
  sb_check_host_tools
  # one bound-tools dir per RUN: passes (first pass, preflight child, re-exec) reuse it; only the process that
  # created it (same $$, preserved across exec) removes it
  if [[ -n "${WGM_BINDIR:-}" && -d "$WGM_BINDIR" && -O "$WGM_BINDIR" && -n "${WGM_TOOLCHK_KEY:-}" ]]; then
    local reuse=1
    for p in "${SB_WRITABLE[@]}"; do [[ -n "$p" ]] && sb_under "$WGM_BINDIR" "$p" && reuse=0; done
    if [[ "$reuse" -eq 1 ]]; then
      SB_BINDIR="$WGM_BINDIR"
      [[ ":$PATH:" == *":$WGM_BINDIR:"* ]] || PATH="$WGM_BINDIR:$PATH"
      export PATH; trap 'sb_cleanup' EXIT
      sb_filter_env_values
      return 0
    fi
  fi
  tb="${TMPDIR:-/tmp}"; [[ -d "$tb" ]] && tb="$(cd "$tb" && pwd -P)" || tb=/tmp
  for p in "${SB_WRITABLE[@]}"; do [[ -n "$p" ]] && sb_under "$tb" "$p" && tb=/tmp; done
  for p in "${SB_EXTRA_MOUNTS[@]}"; do
    [[ -e "${p%%:*}" ]] && { c="$(cd "${p%%:*}" 2>/dev/null && pwd -P)" || c=""; [[ -n "$c" ]] && sb_under "$tb" "$c" && tb=/tmp; }
  done
  SB_BINDIR="$(umask 077; "$mk" -d "$tb/wgm-bin.XXXXXX")" || sb_die "cannot create the private host-tool dir under $tb"
  for name in "${SB_BOUND_TOOLS[@]}"; do
    p="$(command -v "$name" 2>/dev/null)" || continue
    [[ "$p" == /* ]] || continue
    c="$("$rl" -m -- "$p" 2>/dev/null)" || continue
    "$ln" -s "$c" "$SB_BINDIR/$name"
  done
  PATH="$SB_BINDIR:$PATH"; export PATH
  export WGM_BINDIR="$SB_BINDIR" WGM_BINDIR_OWNER="$$"
  trap 'sb_cleanup' EXIT
  sb_filter_env_values
}
# sb_ensure_trusted_runner SCRIPT ARGS… — the reusable FIRST step of loop.sh/swarm.sh (CALL CONTRACT).
# Call it before preflight and before ANY container or contained command (readiness, probe, smoke,
# dry-run included), passing the script's own path and its original argv. When the skill dir lies inside
# the project or its git dir (the only writable mounts) it copies scripts/ + assets/ into a run-private 0700
# dir outside every mount and `exec`s SCRIPT from there with WGM_TRUSTED_RUNNER=<dir> and
# WGM_TRUSTED_RUNNER_OWNED=1 (the re-exec'd process removes it: set SB_SNAPSHOT from them and run
# sb_cleanup on EXIT). Otherwise it returns 0 and does nothing. Pure bash until PATH is trusted.
sb_ensure_trusted_runner() {
  [[ -z "${WGM_TRUSTED_RUNNER:-}" && -z "${WGM_IN_DEVCONTAINER:-}" && "${WGM_DEVCONTAINER:-}" != 0 ]] || return 0
  local script="$1"; shift
  local skill proj g admin cdir tb hit=0 r c
  local -a roots=()
  skill="$(cd "$SB_DIR/.." && pwd -P)"; proj="$(pwd -P)"; roots=("$proj")
  g="$proj/.git"
  if [[ -f "$g" ]]; then
    admin=""; while IFS= read -r r; do [[ "$r" == gitdir:* ]] && admin="${r#gitdir: }"; done < "$g"
    [[ "$admin" == /* ]] || admin="$proj/$admin"
    if [[ -d "$admin" ]]; then
      cdir="$admin"
      if [[ -f "$admin/commondir" && ! -L "$admin/commondir" ]] && sb_chain_ok "$admin/commondir" "${admin%/worktrees/*}" >/dev/null; then read -r r < "$admin/commondir"; cdir="$admin/$r"; fi
      [[ -d "$cdir" ]] && roots+=("$(cd "$cdir" && pwd -P)")
    fi
  fi
  for r in "${roots[@]}"; do sb_under "$skill" "$r" && hit=1; done
  [[ "$hit" -eq 1 ]] || return 0
  sb_path_text_clean "$proj"; PATH="$SB_CLEAN_PATH"; export PATH
  tb="${TMPDIR:-/tmp}"; [[ -d "$tb" ]] && tb="$(cd "$tb" && pwd -P)"
  for r in "${roots[@]}"; do sb_under "$tb" "$r" && tb=/tmp; done
  # nor inside an already-known extra mount (CLI --devcontainer-mount); the record's mounts are re-checked once the
  # decision exists (loop.sh refuses a snapshot that lies inside an approved mount)
  for r in "${SB_EXTRA_MOUNTS[@]}"; do
    [[ -e "${r%%:*}" ]] && { c="$(cd "${r%%:*}" 2>/dev/null && pwd -P)" || c=""; [[ -n "$c" ]] && sb_under "$tb" "$c" && tb=/tmp; }
  done
  local snap
  snap="$(umask 077; mktemp -d "$tb/wgm-runner.XXXXXX")" || sb_die "cannot create the trusted runner snapshot"
  chmod 700 "$snap"; mkdir -p "$snap/scripts" "$snap/assets"
  cp -R "$skill/scripts/." "$snap/scripts/" || { rm -rf "$snap"; sb_die "cannot snapshot the skill scripts"; }
  [[ -d "$skill/assets" ]] && cp -R "$skill/assets/." "$snap/assets/"
  # the agent must still be able to USE the skill from the snapshot: SKILL.md + references travel with it
  [[ -f "$skill/SKILL.md" ]] && cp "$skill/SKILL.md" "$snap/SKILL.md"
  [[ -d "$skill/references" ]] && cp -R "$skill/references" "$snap/references"
  export WGM_TRUSTED_RUNNER="$snap" WGM_TRUSTED_RUNNER_OWNED=1
  exec "$BASH" "$snap/scripts/$(basename "$script")" "$@"
}

# Host executables must resolve OUTSIDE writable mounts. The directory filter above is not enough: a PATH
# dir outside every mount can hold symlinks (even dangling ones) whose targets lie inside the project or its
# git dir, which the agent can rewrite. sb_check_host_tools (a) resolves every symlink in each surviving PATH
# dir to its canonical target WITHOUT requiring existence (`readlink -m`, full chain; one batched call per
# dir; regular files in an outside dir are outside, project-side hard links are refused by the hard-link
# scan) and (b) checks that each tool wgm invokes by name resolves outside too. Call it after SB_WRITABLE is
# set, before any container. RESIDUAL (not analyzed): a wrapper SCRIPT in an outside dir that itself runs
# project files; only symlink authority is checked.
sb_check_host_tools() {
  local rl d c t w name p i links tgts
  rl=/usr/bin/readlink; [[ -x "$rl" ]] || rl=/bin/readlink; [[ -x "$rl" ]] || rl="$(command -v readlink || true)"
  [[ -n "$rl" ]] || return 0
  local -a roots=()
  for w in "${SB_WRITABLE[@]}"; do [[ -n "$w" ]] && roots+=("$w"); done
  [[ ${#roots[@]} -gt 0 ]] || return 0
  local -a dirs=()
  IFS=':' read -r -a dirs <<<"$PATH"
  # The scan is expensive on PATHs with thousands of links, and a run passes through several processes (first
  # pass, preflight, re-exec): a marker keyed by the PATH (minus our own bound-tools dirs) and the writable roots
  # lets the later passes skip an identical, already-passed check.
  local key="" kd
  for d in "${dirs[@]}"; do [[ "$d" == */wgm-bin.* ]] || key+="$d:"; done
  key+="|${roots[*]}"
  [[ "${WGM_TOOLCHK_KEY:-}" != "$key" ]] || return 0
  for d in "${dirs[@]}"; do
    [[ -n "$d" && -d "$d" ]] || continue
    links=(); tgts=()
    # an unsearchable PATH dir cannot hold runnable tools; for any other dir a failed listing/resolution refuses
    [[ -r "$d" && -x "$d" ]] || continue
    local flist frc=0 rtgts rrc=0
    flist="$("${SB_BOOT_FIND:-find}" "$d" -maxdepth 1 -type l 2>&1)" || frc=$?
    sb_find_ok "$frc" "$flist" "$d" || sb_die "launch refused: could not list the symlinks in PATH dir $d (find exited $frc). Recovery: fix the directory's permissions or drop it from PATH for wgm."
    while IFS= read -r p; do [[ -n "$p" && "$p" != find:* ]] && links+=("$p"); done <<<"$flist"
    [[ ${#links[@]} -gt 0 ]] || continue
    rtgts="$("$rl" -m -- "${links[@]}" 2>/dev/null)" || rrc=$?
    [[ "$rrc" -eq 0 ]] || sb_die "launch refused: could not resolve the symlinks in PATH dir $d (readlink exited $rrc). Recovery: fix or remove the broken entries, or drop the directory from PATH for wgm."
    while IFS= read -r t; do tgts+=("$t"); done <<<"$rtgts"
    for i in "${!links[@]}"; do
      t="${tgts[$i]:-}"; [[ -n "$t" ]] || continue
      for w in "${roots[@]}"; do
        if sb_under "$t" "$w"; then
          sb_die "launch refused: host tool ${links[$i]} -> $t resolves inside the writable mount $w, which the agent can rewrite. Recovery: remove that link, or drop $d from PATH for wgm."
        fi
      done
    done
  done
  kd="$key"
  for name in "${SB_BOUND_TOOLS[@]}"; do
    p="$(command -v "$name" 2>/dev/null || true)"
    [[ -n "$p" && "$p" == /* ]] || continue
    c="$("$rl" -m -- "$p" 2>/dev/null || true)"
    for w in "${roots[@]}"; do
      if [[ -n "$c" ]] && sb_under "$c" "$w"; then
        sb_die "launch refused: host tool $name ($p) resolves to $c inside the writable mount $w. Recovery: remove that link/file, or drop its directory from PATH for wgm."
      fi
    done
  done
  export WGM_TOOLCHK_KEY="$kd"   # passed: later passes of this run with the same PATH/roots skip the scan
}

# Trusted runner: when the skill dir lies inside a writable mount, run from a private snapshot.
sb_trusted_snapshot() {  # prints the snapshot's scripts dir or nothing
  local skill_root="$1" canon tmp
  canon="$(sb_canon "$skill_root")"
  local w hit=0
  for w in "${SB_WRITABLE[@]}"; do [[ -n "$w" ]] && sb_under "$canon" "$w" && hit=1; done
  [[ "$hit" -eq 1 ]] || return 0
  tmp="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/wgm-runner.XXXXXX")" || sb_die "cannot create the trusted runner snapshot"
  chmod 700 "$tmp"
  mkdir -p "$tmp/scripts" "$tmp/assets"
  cp -R "$canon/scripts/." "$tmp/scripts/"
  [[ -d "$canon/assets" ]] && cp -R "$canon/assets/." "$tmp/assets/"
  [[ -f "$canon/SKILL.md" ]] && cp "$canon/SKILL.md" "$tmp/SKILL.md"
  [[ -d "$canon/references" ]] && cp -R "$canon/references" "$tmp/references"
  printf '%s' "$tmp"
}

# ---------------------------------------------------------------------------------------------------
# Decision text (preflight output == decision file) and its consumer
# ---------------------------------------------------------------------------------------------------
# THE AGENT HAS ITS SKILL: the RUNNING wgm skill bundle (the trusted-runner snapshot when one exists, else the
# skill dir — SB_DIR is already the snapshot's scripts dir then) is mounted READ-ONLY (non-recursive, mount
# policy applies) at (a) its host absolute path — unless that lies inside the project/git dir, which is already
# mounted — and (b) the conventional skills dirs under the container HOME: ~/.agents/skills/wgm always, plus the
# detected agent's own (pi ~/.pi/agent/skills/wgm, claude ~/.claude/skills/wgm, copilot ~/.copilot/skills/wgm).
SB_SKILL_MOUNTS=()
sb_skill_mounts() {
  local root a
  root="$(cd "$SB_DIR/.." && pwd -P)"
  SB_SKILL_MOUNTS=()
  if [[ -n "$SB_PROJECT" ]] && sb_under "$root" "$SB_PROJECT"; then :
  elif [[ -n "$SB_COMMON" ]] && sb_under "$root" "$SB_COMMON"; then :
  else SB_SKILL_MOUNTS+=("$root:$root"); fi
  SB_SKILL_MOUNTS+=("$root:$SB_CONT_HOME/.agents/skills/wgm")
  for a in "${SB_AGENTS[@]}"; do
    case "$a" in
      pi) SB_SKILL_MOUNTS+=("$root:$SB_CONT_HOME/.pi/agent/skills/wgm") ;;
      claude) SB_SKILL_MOUNTS+=("$root:$SB_CONT_HOME/.claude/skills/wgm") ;;
      copilot) SB_SKILL_MOUNTS+=("$root:$SB_CONT_HOME/.copilot/skills/wgm") ;;
    esac
  done
  SB_SKILL_ROOT="$root"
}
SB_SKILL_ROOT=""
sb_emit() {
  local a m e c t p
  sb_skill_mounts
  for m in "${SB_SKILL_MOUNTS[@]}"; do echo "skill=$m:ro"; done   # informational: re-derived at every launch
  echo "sandbox=$SB_MODE"; echo "engine=$SB_ENGINE"; echo "reason=$SB_REASON"
  for a in "${SB_AGENTS[@]}"; do echo "agent=$a"; done
  for m in "${SB_LAYOUT[@]}"; do echo "layout=$m"; done   # informational: re-derived at every launch
  for m in "${SB_MOUNTS[@]}"; do echo "mount=$m"; done
  for c in "${SB_COPYSRC[@]}"; do echo "copy=$c"; done
  for t in "${SB_TOKENS[@]}"; do echo "token=$t"; done
  for p in "${SB_PATHS[@]}"; do echo "path=$p"; done
  for e in "${SB_ENVS[@]}"; do echo "env=$e"; done
  echo "image=$SB_IMAGE"
  [[ "$SB_SMOKE_OVERRIDE" -eq 1 ]] && echo "smoke=override"
  echo "record=$SB_RECORD"
  return 0
}
sb_parse_decision() {  # reads decision text on stdin
  SB_MODE=""; SB_ENGINE="none"; SB_REASON=""; SB_IMAGE=""; SB_RECORD=""; SB_SMOKE_OVERRIDE=0
  SB_AGENTS=(); SB_MOUNTS=(); SB_ENVS=(); SB_COPYSRC=(); SB_TOKENS=(); SB_PATHS=()
  local line k v
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      sandbox) SB_MODE="$v" ;; engine) SB_ENGINE="$v" ;; reason) SB_REASON="$v" ;; image) SB_IMAGE="$v" ;;
      record) SB_RECORD="$v" ;; agent) SB_AGENTS+=("$v") ;; mount) SB_MOUNTS+=("$v") ;; env) SB_ENVS+=("$v") ;;
      copy) SB_COPYSRC+=("$v") ;; token) SB_TOKENS+=("$v") ;; path) SB_PATHS+=("$v") ;; smoke) [[ "$v" == override ]] && SB_SMOKE_OVERRIDE=1 ;;
    esac
  done
  [[ "$SB_MODE" == on || "$SB_MODE" == off || "$SB_MODE" == inside ]] || sb_die "decision has no valid sandbox= line"
}
sb_load_decision_file() {  # same permission/ownership checks as the record; outside every mount
  local f="$1" d
  sb_record_check_file "$f" "decision file"
  d="$(dirname "$f")"
  [[ "$(sb_stat_mode "$d")" =~ ^[0-7]*00$ ]] || sb_die "decision directory $d must be private (0700)"
  [[ "$(sb_stat_owner "$d")" == "$(id -u)" ]] || sb_die "decision directory $d is not owned by the operator"
  sb_parse_decision < "$f"
}

# ---------------------------------------------------------------------------------------------------
# Containers: sandbox_exec
# ---------------------------------------------------------------------------------------------------
# Every engine call in a signal/cleanup/sweep path runs under a wall-clock bound (`timeout -k 2`, a manual
# watchdog when no timeout binary exists) and, during a signal, under the handler's global deadline, so a hung
# engine client can neither stall the exit nor hide the container: a timeout leaves the name "retained".
SB_DEADLINE=0
# SHARED OWNERSHIP of container handles (CONTRACT, also for swarm.sh): the first process to call sb_host_tmp_init (the
# supervisor: loop.sh, a standalone preflight, swarm.sh) creates a run-private live-container REGISTRY — a DIRECTORY
# `<private dir>/reg` (0700, outside every mount) holding `live/<name>` (one empty entry per live container),
# `retained/<name>` (names already printed as retained) and `engine` — and exports its path as WGM_LIVE_REGISTRY; every
# child (the preflight child, lane loops) inherits it. There is NO read-modify-write on a shared file: register = create
# `live/<name>` exclusively (noclobber, O_EXCL), deregister = remove THAT entry only, reap = list the directory — so a
# concurrent registration by another process can never be lost. sandbox_exec in ANY process registers each name BEFORE
# launch and deregisters it after confirmed absence (sb_reap success); a name that could not be confirmed stays in
# `live/`, is printed as `retained container <name>`, gets a `retained/<name>` entry, and the owner's dir keeps a
# `retained` marker (it is then kept as the ownership record). A signal handler spends at most SB_CLEANUP_DEADLINE
# seconds on container cleanup; a SUPERVISOR must give a child at least SB_CHILD_GRACE seconds (deadline + margin)
# before KILLing it, and when it does kill it, it reaps every name left in `live/` itself. No handle is ever lost.
SB_CLEANUP_DEADLINE=16
SB_CHILD_GRACE="${WGM_CHILD_GRACE:-$((SB_CLEANUP_DEADLINE + 8))}"   # (WGM_CHILD_GRACE: test seam — forces the supervisor-kills-child path)
SB_CALL_BOUND="${WGM_ENGINE_CALL_BOUND:-5}"
sb_bounded() {  # sb_bounded SECS CMD… → CMD's status, 124 on timeout/deadline
  local secs="$1" rem rc=0 p w; shift
  if [[ "$SB_DEADLINE" -gt 0 ]]; then
    rem=$((SB_DEADLINE - SECONDS)); [[ "$rem" -ge 1 ]] || return 124
    [[ "$secs" -le "$rem" ]] || secs="$rem"
  fi
  if command -v timeout >/dev/null 2>&1; then timeout -k 2 "$secs" "$@"; return $?
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout -k 2 "$secs" "$@"; return $?; fi
  "$@" & p=$!
  ( sleep "$secs"; kill -TERM "$p" 2>/dev/null; sleep 2; kill -KILL "$p" 2>/dev/null ) & w=$!
  wait "$p" || rc=$?
  kill "$w" 2>/dev/null || true; wait "$w" 2>/dev/null || true
  return "$rc"
}
# Remove a container by name with ZERO grace (no SIGTERM wait: PID 1 may ignore it).
sb_rm_now() {
  if [[ "$SB_ENGINE" == podman ]]; then sb_bounded "$SB_CALL_BOUND" "$SB_ENGINE" rm -f -t 0 "$1" >/dev/null 2>&1 || true
  else sb_bounded "$SB_CALL_BOUND" "$SB_ENGINE" rm -f "$1" >/dev/null 2>&1 || true; fi
}
# CONTAINMENT-LOSS CONTRACT (for swarm.sh / any caller): when the environment variable WGM_CONTAINMENT_LOST_FILE
# names a file, every container whose ABSENCE could not be confirmed (sb_reap giving up — in the terminal stop of
# a contained command, in a signal handler, in preflight's readiness/probe/smoke launches, anywhere) is recorded
# by APPENDING exactly one line `retained container <name>` (no other text, one line per container, no
# duplicates) BEFORE the process exits 2 / 130 / 143. The file is created 0600 and is NEVER written through a
# symlink (a symlink or non-regular target is skipped with a note on stderr); it must live in the caller's private
# 0700 dir. The same line is always printed on stderr, followed (terminal stop) by the exact recovery command.
# A caller can therefore learn the handles from the file even when it discards the child's stderr.
SB_RETAINED_SEEN=" "
sb_record_retained() {  # sb_record_retained NAME
  local n="$1" f="${WGM_CONTAINMENT_LOST_FILE:-}"
  [[ "$SB_RETAINED_SEEN" != *" $n "* ]] || return 0
  SB_RETAINED_SEEN+="$n "
  printf 'retained container %s\n' "$n" >&"$SB_ERRFD"
  local rf; rf="$(sb_registry_dir)"
  if [[ -n "$rf" ]]; then : > "$rf/retained/$n" 2>/dev/null || true; : > "${rf%/*}/retained" 2>/dev/null || true; fi   # keep the owner's dir: it is the ownership record
  [[ -n "$f" ]] || return 0
  if [[ -L "$f" || ( -e "$f" && ! -f "$f" ) ]]; then sb_note "WGM_CONTAINMENT_LOST_FILE $f is a symlink or not a regular file — not written"; return 0; fi
  ( sb_safe_path "$f" ) >/dev/null 2>&1 || { sb_note "WGM_CONTAINMENT_LOST_FILE $f lies in a writable root through a symlink — not written"; return 0; }
  ( umask 077; printf 'retained container %s\n' "$n" >> "$f" ) 2>/dev/null || sb_note "could not write WGM_CONTAINMENT_LOST_FILE $f"
  return 0
}
sb_reap() {  # remove a container by name; print "retained container <name>" when absence can't be confirmed
  local name="$1" out unknown of
  for _try in 1 2 3; do
    unknown=0
    # output goes to a FILE: a hung client's orphaned children must not keep a $(...) pipe open
    of="$(mktemp "${SB_HOSTTMP:-${TMPDIR:-/tmp}}/ps.XXXXXX")" || of=/dev/null
    sb_bounded "$SB_CALL_BOUND" "$SB_ENGINE" ps -a --filter "name=^${name}\$" --format '{{.Names}}' > "$of" 2>/dev/null || unknown=1
    out="$(cat "$of" 2>/dev/null || true)"; [[ "$of" == /dev/null ]] || rm -f "$of"
    if [[ "$unknown" -eq 0 ]] && ! grep -Fxq "$name" <<<"$out"; then sb_registry_del "$name"; return 0; fi
    [[ "$SB_DEADLINE" -gt 0 && "$SECONDS" -ge "$SB_DEADLINE" ]] && break
    sb_rm_now "$name"
    sleep 0.2
  done
  sb_record_retained "$name"
  return 1
}
sb_retained_terminal() {  # the container named $1 could not be confirmed absent: record it and stop
  local n="$1" rm_cmd="podman rm -f -t 0 $1"
  [[ "$SB_ENGINE" == docker ]] && rm_cmd="docker rm -f $1"
  [[ -n "$SB_HOSTTMP" ]] && : > "$SB_HOSTTMP/retained"    # sb_cleanup keeps the registry dir (the ownership record)
  SB_LIVE=""
  sb_record_retained "$n"   # (no-op if sb_reap already recorded it)
  sb_die "container $n could not be confirmed absent, so NOTHING agent-writable may be trusted or read; stopping. Recovery: run '$rm_cmd', then verify it is gone ($SB_ENGINE ps -a --filter name=^$n\$ must print nothing). The ownership record is kept in ${SB_HOSTTMP:-<none>}/live."
}
sb_on_signal() {  # sb_on_signal EXITCODE
  local code="$1" regd
  trap '' INT TERM
  SB_DEADLINE=$((SECONDS + SB_CLEANUP_DEADLINE))   # the whole handler finishes within ~20 s whatever the engine does
  local reg_names="" rn
  regd="$(sb_registry_dir)"
  reg_names="$(sb_registry_list)"
  if [[ "$SB_ENGINE" != podman && "$SB_ENGINE" != docker && -n "$regd" && -f "$regd/engine" ]]; then
    local reng; reng="$(cat "$regd/engine" 2>/dev/null || true)"
    case "$reng" in podman|docker) SB_ENGINE="$reng" ;; esac
  fi
  if [[ "$SB_ENGINE" == podman || "$SB_ENGINE" == docker ]]; then
    while IFS= read -r rn; do [[ -n "$rn" ]] && sb_rm_now "$rn"; done <<<"$reg_names"
  fi
  [[ -n "$SB_LIVE" ]] && sb_rm_now "$SB_LIVE"
  if [[ -n "$SB_CHILD" ]]; then
    kill -TERM "$SB_CHILD" 2>/dev/null || true
    local _w killed=0
    # the child's own handler needs up to SB_CLEANUP_DEADLINE: wait at least SB_CHILD_GRACE (deadline + margin)
    for _w in $(seq 1 $((SB_CHILD_GRACE * 10))); do kill -0 "$SB_CHILD" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$SB_CHILD" 2>/dev/null; then kill -KILL "$SB_CHILD" 2>/dev/null; killed=1; fi
    wait "$SB_CHILD" 2>/dev/null || true
    # a killed child may have left handles behind: this supervisor reaps whatever the registry still lists (fresh budget)
    [[ "$killed" -eq 1 ]] && SB_DEADLINE=$((SECONDS + SB_CLEANUP_DEADLINE))
  fi
  if [[ "$SB_ENGINE" == podman || "$SB_ENGINE" == docker ]]; then
    # names the registry still holds (the child's included) that nobody has already printed as retained
    reg_names="$(sb_registry_list)"
    while IFS= read -r rn; do
      [[ -n "$rn" && "$rn" != "$SB_LIVE" ]] || continue
      if [[ -n "$regd" && -e "$regd/retained/$rn" ]]; then continue; fi
      sb_reap "$rn" || true
    done <<<"$reg_names"
  fi
  if [[ -n "$SB_LIVE" ]]; then sb_reap "$SB_LIVE" || true; SB_LIVE=""; fi
  exit "$code"
}
# EVERY private run artifact (credential copies, the run-private scratch/registry dir, decision files) must lie
# OUTSIDE every mount: the project, the git common dir, every layout overlay, every install prefix, every
# approved extra mount (CLI + record) and the skill bundle. `sb_mount_sources` collects the canonical sources
# known so far into SB_MSRC; `sb_outside_all_mounts PATH` succeeds only if the canonical PATH is not inside (or
# equal to) any of them (SB_INSIDE_OF names the offender); `sb_private_base` prints the base dir for a new private
# artifact — $TMPDIR, else /tmp — or exits 2 naming the problem. CONTRACT FOR swarm.sh: call
# `sb_private_base` (after the decision/mounts are known — SB_MOUNTS/SB_EXTRA_MOUNTS filled by
# sb_parse_decision / preflight) for the decision file's directory and check any other private path with
# `sb_outside_all_mounts PATH`.
SB_MSRC=(); SB_INSIDE_OF=""
SB_MSRC_SKIP_SKILL=0
sb_mount_sources() {
  local m h
  SB_MSRC=()
  [[ -n "$SB_PROJECT" ]] && SB_MSRC+=("$SB_PROJECT")
  [[ -n "$SB_COMMON" ]] && SB_MSRC+=("$SB_COMMON")
  for m in "${SB_LAYOUT[@]}" "${SB_MOUNTS[@]}"; do
    h="${m%%:*}"; sb_has "$h" "${SB_COPYSRC[@]}" && continue   # credential SOURCES are copied, never bound
    SB_MSRC+=("$(sb_canon "$h")")
  done
  for m in "${SB_EXTRA_MOUNTS[@]}"; do h="${m%%:*}"; [[ -e "$h" ]] && SB_MSRC+=("$(sb_canon "$h")"); done
  [[ "$SB_MSRC_SKIP_SKILL" -eq 1 ]] || SB_MSRC+=("$(cd "$SB_DIR/.." && pwd -P)")   # the skill bundle (or its snapshot)
}
sb_outside_all_mounts() {  # sb_outside_all_mounts PATH
  local c m
  sb_mount_sources
  c="$(sb_canon "$1")"; SB_INSIDE_OF=""
  for m in "${SB_MSRC[@]}"; do
    [[ -n "$m" ]] || continue
    if sb_under "$c" "$m"; then SB_INSIDE_OF="$m"; return 1; fi
  done
  if [[ -n "${WGM_SWARM_PARENT_ROOT:-}" ]] && sb_under "$c" "$(sb_canon "$WGM_SWARM_PARENT_ROOT")"; then SB_INSIDE_OF="$WGM_SWARM_PARENT_ROOT"; return 1; fi
  return 0
}
sb_private_base() {
  local b
  for b in "${TMPDIR:-/tmp}" /tmp; do
    [[ -d "$b" ]] || continue
    if sb_outside_all_mounts "$b"; then printf '%s' "$b"; return 0; fi
  done
  sb_die "no safe location for private run artifacts: TMPDIR (${TMPDIR:-unset}) and /tmp both lie inside the mount $SB_INSIDE_OF. Set TMPDIR to a directory outside every mount."
}
sb_assert_private_outside() {  # exit 2 naming a private dir that lies inside a mount
  local d
  for d in "$SB_HOSTTMP" "$SB_COPYROOT"; do
    [[ -n "$d" ]] || continue
    sb_outside_all_mounts "$d" || sb_die "the private run directory $d lies inside the mount $SB_INSIDE_OF, so a container could read it. Set TMPDIR to a directory outside every mount."
  done
}
# Run-private 0700 dir outside every mount: scratch files AND the live-container registry.
sb_host_tmp_init() {
  [[ -z "$SB_HOSTTMP" ]] || return 0
  local tb
  tb="$(sb_private_base)" || exit 2
  SB_HOSTTMP="$(umask 077; mktemp -d "$tb/wgm-loop.XXXXXX")" || sb_die "cannot create a private scratch dir"
  # the first owner creates the shared registry directory; a valid inherited one (a supervisor's) is kept
  if [[ -z "${WGM_LIVE_REGISTRY:-}" || ! -d "$WGM_LIVE_REGISTRY/live" || -L "$WGM_LIVE_REGISTRY" ]]; then
    ( umask 077; mkdir -p "$SB_HOSTTMP/reg/live" "$SB_HOSTTMP/reg/retained" )
    export WGM_LIVE_REGISTRY="$SB_HOSTTMP/reg"
  fi
}
# The registry directory in use: an inherited WGM_LIVE_REGISTRY that is a real (non-symlink) directory we own, holding
# live/ and retained/, outside the project and git dir (never agent-reachable); else this process's own `<private dir>/reg`.
sb_registry_dir() {
  local d="${WGM_LIVE_REGISTRY:-}"
  if [[ -n "$d" && -d "$d/live" && -d "$d/retained" && ! -L "$d" && -O "$d" ]]; then
    if { [[ -z "$SB_PROJECT" ]] || ! sb_under "$d" "$SB_PROJECT"; } && { [[ -z "$SB_COMMON" ]] || ! sb_under "$d" "$SB_COMMON"; }; then printf '%s' "$d"; return 0; fi
  fi
  if [[ -n "$SB_HOSTTMP" ]]; then
    [[ -d "$SB_HOSTTMP/reg/live" ]] || ( umask 077; mkdir -p "$SB_HOSTTMP/reg/live" "$SB_HOSTTMP/reg/retained" )
    printf '%s' "$SB_HOSTTMP/reg"
  fi
  return 0
}
sb_registry_list() {  # names of the live entries, one per line (a directory listing: no shared file is read-modify-written)
  local d f; d="$(sb_registry_dir)"
  [[ -n "$d" ]] || return 0
  for f in "$d/live"/*; do [[ -e "$f" ]] && printf '%s\n' "${f##*/}"; done
  return 0
}
# test seam: a barrier between a registry operation's start and its effect (WGM_REGISTRY_SEAM_DIR; creates <point>.reached
# and waits for <point>.go, at most 20 s)
sb_registry_seam() {
  local sd="${WGM_REGISTRY_SEAM_DIR:-}" i
  [[ -n "$sd" && -d "$sd" ]] || return 0
  : > "$sd/$1.reached"
  for i in $(seq 1 200); do [[ -e "$sd/$1.go" ]] && return 0; sleep 0.1; done
  return 0
}
sb_registry_add() {
  local d; d="$(sb_registry_dir)"
  [[ -n "$d" && "$1" =~ ^[A-Za-z0-9_.-]+$ ]] || return 0
  sb_registry_seam add-start
  ( set -C; : > "$d/live/$1" ) 2>/dev/null || true   # noclobber = O_EXCL create of THIS name's entry only
  # the engine the names belong to travels with the registry: a supervisor that never chose an engine itself (the
  # preflight child did) still knows which one to reap with
  case "$SB_ENGINE" in podman|docker) ( set -C; printf '%s\n' "$SB_ENGINE" > "$d/engine" ) 2>/dev/null || true ;; esac
  return 0
}
sb_registry_del() {
  local d; d="$(sb_registry_dir)"
  [[ -n "$d" && "$1" =~ ^[A-Za-z0-9_.-]+$ ]] || return 0
  sb_registry_seam del-start
  rm -f -- "$d/live/$1"   # exactly this name's entry
}
sb_cleanup() {
  if [[ -n "$SB_HOSTTMP" ]]; then
    if [[ -e "$SB_HOSTTMP/retained" ]]; then printf 'sandbox: ownership record kept: %s/reg/live\n' "$SB_HOSTTMP" >&2; else rm -rf -- "$SB_HOSTTMP"; fi
  fi
  sb_remove_copies
  [[ -n "$SB_SNAPSHOT" ]] && rm -rf -- "$SB_SNAPSHOT"
  [[ -n "$SB_OWNED_DECISION" ]] && rm -rf -- "$(dirname "$SB_OWNED_DECISION")"
  # the bound-tools dir goes LAST and is removed with the ABSOLUTE rm (its own links are inside it)
  if [[ -n "$SB_BINDIR" ]]; then
    [[ "${WGM_BINDIR_OWNER:-}" == "$$" ]] && "${SB_BOOT_RM:-/bin/rm}" -rf -- "$SB_BINDIR" 2>/dev/null
    SB_BINDIR=""
  fi
  return 0
}

# sandbox_exec [-i] ARGV… — run ARGV in a fresh container (cwd = project, same path), return its status.
sandbox_exec() {
  local stdin_mode=0
  [[ "${1:-}" == "-i" ]] && { stdin_mode=1; shift; }
  [[ "$SB_IS_GIT" -eq 1 && -z "$SB_PIN_PTR" ]] && sb_pin_capture   # pins exist before the FIRST contained command
  SB_SEQ=$((SB_SEQ + 1))
  local name="wgm-${SB_KEY8}-$$-${SB_SEQ}" m n rc=0
  local -a cmd=("$SB_DC" run --same-path --container "$SB_ENGINE" --tag "$SB_IMAGE" --name "$name")
  local src cp mode kind rest
  if [[ "$SB_IS_GIT" -eq 1 ]]; then
    sb_gitdir_guard "$SB_PROJECT" cheap --expect-common "${SB_PIN_GC:-$SB_COMMON}"   # no host write into the git dir through a planted link
    sb_ensure_overlays
    sb_under "$SB_COMMON" "$SB_PROJECT" || cmd+=(--git-common-mount "$SB_COMMON")
    for m in "${SB_OVERLAYS[@]}"; do cmd+=(--overlay-mount "${m%:*}"); done
  fi
  for m in "${SB_RUN_MOUNTS[@]}"; do
    src="${m%%:*}"; rest="${m#*:}"; cp="${rest%%:*}"; rest="${rest#*:}"; mode="${rest%%:*}"; kind="${rest#*:}"
    [[ "$src" == "$SB_PROJECT" && "$cp" == "$SB_PROJECT" ]] && continue
    if [[ "$kind" == copy ]]; then cmd+=(--copy-mount "$src:$cp"); else cmd+=(--mount "$src:$cp:$mode"); fi
  done
  sb_skill_mounts
  for m in "${SB_SKILL_MOUNTS[@]}"; do cmd+=(--skill-mount "$m"); done
  for m in "${SB_PATHS[@]}"; do cmd+=(--path-prepend "$m"); done
  for n in "${SB_ENVS[@]}"; do cmd+=(--env "$n"); done
  while IFS= read -r n; do
    case "$n" in WGM_LIVE_REGISTRY|WGM_GIT_ENV_APPLIED|WGM_TOOLCHK_KEY|WGM_BINDIR|WGM_BINDIR_OWNER|WGM_CONTAINMENT_LOST_FILE|WGM_SANDBOX_DECISION|WGM_SANDBOX_DECISION_OWNED|WGM_HOST_ENV_*|WGM_DEBUG_*|WGM_MOUNTINFO|WGM_TRUSTED_RUNNER|WGM_IN_DEVCONTAINER|WGM_DEVCONTAINER*) continue ;; esac
    cmd+=(--env "$n")
  done < <(compgen -e | grep '^WGM_' || true)
  [[ "$stdin_mode" -eq 1 ]] && cmd+=(-i)
  cmd+=(-- "$@")
  SB_LIVE="$name"
  sb_registry_add "$name"
  if [[ "$stdin_mode" -eq 1 ]]; then
    "${SB_TIMEOUT[@]}" "${cmd[@]}" <&0 &
  else
    "${SB_TIMEOUT[@]}" "${cmd[@]}" </dev/null &
  fi
  SB_CHILD=$!
  wait "$SB_CHILD" || rc=$?
  SB_CHILD=""
  if [[ "$rc" -ge 124 ]]; then
    # CONTAINER ABSENCE IS THE PREREQUISITE for every host check of agent-writable state: if it cannot be
    # confirmed, stop TERMINALLY — keep the ownership record, print the handle and the exact recovery, exit 2 at
    # once (no pin verification, no git-dir scan, no host git, no retry, no further iteration).
    if ! sb_reap "$name"; then sb_retained_terminal "$name"; fi
  fi
  SB_LIVE=""
  sb_registry_del "$name"
  # phase boundary: the contained command has exited; pointers first, then the full git-dir scan, then config pins
  if [[ "$SB_IS_GIT" -eq 1 && -z "$SB_PIN_PTR" ]]; then sb_gitdir_guard "$SB_PROJECT" full; fi
  sb_verify_pins full
  return "$rc"
}

# ---------------------------------------------------------------------------------------------------
# Plan the mounts for an ON decision (policy refusals happen here, before anything starts)
# ---------------------------------------------------------------------------------------------------
sb_install_guidance() {
  local id="" like="" os
  os="$(uname -s 2>/dev/null || echo unknown)"
  # shellcheck disable=SC1091  # os-release is host data
  if [[ -r /etc/os-release ]]; then id="$(. /etc/os-release; echo "${ID:-}")"; like="$(. /etc/os-release; echo "${ID_LIKE:-}")"; fi
  echo "No working container engine (podman or docker) was found. wgm runs agents sandboxed by default."
  echo "Install one (Podman recommended), then rerun:"
  case "$os:$id:$like" in
    Darwin:*) echo "  brew install podman && podman machine init && podman machine start    # or Docker Desktop" ;;
    *:debian:*|*:ubuntu:*|*::*debian*|*::*ubuntu*) echo "  sudo apt-get update && sudo apt-get install -y podman" ;;
    *:fedora:*|*:rhel:*|*:centos:*|*::*fedora*|*::*rhel*) echo "  sudo dnf install -y podman" ;;
    *:arch:*|*::*arch*) echo "  sudo pacman -S podman" ;;
    *:alpine:*) echo "  sudo apk add podman" ;;
    *:opensuse*:*|*:sles:*|*::*suse*) echo "  sudo zypper install podman" ;;
    *) echo "  see https://podman.io/docs/installation (or https://docs.docker.com/engine/install/)" ;;
  esac
  [[ -n "${WSL_DISTRO_NAME:-}" ]] && echo "  (WSL: install inside the distro; field validation on WSL is a follow-up)"
  return 0
}

sb_engine_working() { command -v "$1" >/dev/null 2>&1 && sb_bounded 20 "$1" info >/dev/null 2>&1; }

# First word of shell-command TEXT (a WGM_AGENT / --agent string), with the shell's own word semantics for the part
# that matters here — single quotes, double quotes and backslash escapes keep a space inside the word, an unquoted blank
# ends it — i.e. the word `bash -c "$AGENT"` would run. (An argv-supplied executable is NEVER passed through this: it is
# an opaque pathname, see --agent-exe.)
sb_first_word_name() {
  local t="$1" w="" c q="" i n bs=$'\\'
  t="${t#"${t%%[![:space:]]*}"}"
  n=${#t}
  for (( i = 0; i < n; i++ )); do
    c="${t:i:1}"
    if [[ -n "$q" ]]; then
      if [[ "$c" == "$q" ]]; then q=""
      elif [[ "$q" == '"' && "$c" == "$bs" && $((i + 1)) -lt n ]]; then i=$((i + 1)); w+="${t:i:1}"
      else w+="$c"; fi
    else
      case "$c" in
        "'"|'"') q="$c" ;;
        "$bs") if (( i + 1 < n )); then i=$((i + 1)); w+="${t:i:1}"; fi ;;
        [[:space:]]) break ;;
        *) w+="$c" ;;
      esac
    fi
  done
  printf '%s' "$w"
}

# sb_plan_mounts — fills SB_MOUNTS/SB_COPYSRC/SB_TOKENS/SB_PATHS/SB_ENVS from the approved credentials.
SB_AGENT_WORDS=(); SB_EXTRA_MOUNTS=()
sb_plan_mounts() {
  SB_MOUNTS=("$SB_PROJECT:$SB_PROJECT:rw"); SB_COPYSRC=(); SB_PATHS=()
  sb_policy_check "$SB_PROJECT" "project"
  sb_hardlink_check "$SB_PROJECT"
  if [[ "$SB_IS_GIT" -eq 1 ]]; then
    if ! sb_under "$SB_COMMON" "$SB_PROJECT"; then
      sb_under "$SB_PROJECT" "$SB_COMMON" && sb_die "mount refused (git dir): the project $SB_PROJECT lies inside the git directory $SB_COMMON"
      sb_policy_check "$SB_COMMON" "git common directory"
      sb_hardlink_check "$SB_COMMON"
      SB_MOUNTS+=("$SB_COMMON:$SB_COMMON:rw")
    else
      sb_policy_check "$SB_COMMON" "git directory"
    fi
    sb_check_includes
    [[ "$dry" -eq 1 ]] || sb_ensure_overlays
    sb_overlay_list
    for o in "${SB_OVERLAYS[@]}"; do
      p="${o%:*}"; [[ -e "$p" ]] && SB_MOUNTS+=("$p:$p:ro")
    done
  fi
  local nlayout=${#SB_MOUNTS[@]}
  # install prefixes (STATIC DISCOVERY)
  for w in "${SB_AGENT_WORDS[@]}" node; do
    [[ -n "$w" ]] || continue
    sb_discover "$w"
    pfx="$SB_D_PREFIX"
    [[ -n "$SB_D_PATHDIR" ]] && ! sb_has "$SB_D_PATHDIR" "${SB_PATHS[@]}" && SB_PATHS+=("$SB_D_PATHDIR")
    [[ -n "$pfx" ]] || continue
    sb_policy_check "$pfx" "install prefix of $w (derived from its binary; refusing a forbidden prefix is a named exit 2, never a silent skip)"
    m="$pfx:$pfx:ro"; sb_has "$m" "${SB_MOUNTS[@]}" || SB_MOUNTS+=("$m")
  done
  # explicit extra mounts: read-only regular files/dirs only
  for src in "${SB_EXTRA_MOUNTS[@]}"; do
    local hp="${src%%:*}" cpth mode="ro"
    cpth="${src#*:}"; [[ "$cpth" == "$src" ]] && cpth="$hp"
    case "$cpth" in
      rw|*:rw) sb_die "mount refused: $src — explicit mounts are read-only (rw is refused)" ;;
      ro) cpth="$hp" ;;
      *:ro) cpth="${cpth%:ro}" ;;
    esac
    [[ -e "$hp" ]] || sb_die "mount refused: $hp does not exist"
    k="$(sb_canon "$hp")"
    [[ -f "$k" || -d "$k" ]] || sb_die "mount refused: $k is not a regular file or directory (sockets, devices and FIFOs are refused)"
    sb_policy_check "$k" "explicit mount"
    if sb_under "$k" "$SB_PROJECT" || sb_under "$SB_PROJECT" "$k" || { [[ -n "$SB_COMMON" ]] && { sb_under "$k" "$SB_COMMON" || sb_under "$SB_COMMON" "$k"; }; }; then
      sb_die "mount refused: $k contains, equals or lies inside the project or the git directory (one destination per source)"
    fi
    SB_MOUNTS+=("$k:$cpth:$mode")
  done
  # credentials (copies): sources only; the copy is made at run time
  for d in "${P_DIRS[@]}"; do
    src="${d%%:*}"
    sb_has "$d" "${APPROVED_DIRS[@]}" || continue
    if r="$(sb_forbidden_reason "$src")"; then sb_die "credential source $src refused: $r"; fi
    SB_MOUNTS+=("$src:${d#*:}:rw"); SB_COPYSRC+=("$src")
  done
  for t in "${P_TOKENS[@]}"; do sb_has "$t" "${APPROVED_TOKENS[@]}" && SB_TOKENS+=("$t"); done
  # no two mounts on one container path, and ONE destination per CANONICAL source (symlink aliases included)
  local seen=" " cp2 csrc
  local -A srcdest=()
  for m in "${SB_MOUNTS[@]}"; do
    cp2="${m#*:}"; cp2="${cp2%:*}"
    [[ "$seen" == *" $cp2 "* ]] && sb_die "two mounts would land on the same container path $cp2"
    seen+="$cp2 "
    csrc="$(sb_canon "${m%%:*}")"
    if [[ -n "${srcdest[$csrc]:-}" && "${srcdest[$csrc]}" != "$cp2" ]]; then
      sb_die "mount refused: the source $csrc would be mounted at two destinations (${srcdest[$csrc]} and $cp2); one destination per canonical source (only the wgm skill aliases are exempt)"
    fi
    srcdest["$csrc"]="$cp2"
  done
  # ONE overlap policy for every assembled source: an extra mount / install prefix may not equal, contain or lie
  # inside the project, the common dir or another mount's source (the D3 overlays and the C5 skill aliases are
  # the only authorized exceptions and are not in this list)
  local i j a b
  local -a ms=()
  for ((i = nlayout; i < ${#SB_MOUNTS[@]}; i++)); do ms+=("$(sb_canon "${SB_MOUNTS[i]%%:*}")"); done
  for ((i = 0; i < ${#ms[@]}; i++)); do
    a="${ms[i]}"
    if sb_under "$a" "$SB_PROJECT" || sb_under "$SB_PROJECT" "$a" || { [[ -n "$SB_COMMON" ]] && { sb_under "$a" "$SB_COMMON" || sb_under "$SB_COMMON" "$a"; }; }; then
      sb_die "mount refused: $a equals, contains or lies inside the project or the git directory"
    fi
    for ((j = i + 1; j < ${#ms[@]}; j++)); do
      b="${ms[j]}"
      if [[ "$a" != "$b" ]] && { sb_under "$a" "$b" || sb_under "$b" "$a"; }; then sb_die "mount refused: $a and $b overlap (one contains the other)"; fi
    done
  done
  # the record directory must not overlap any mount source
  for m in "${SB_MOUNTS[@]}"; do
    src="${m%%:*}"
    if sb_under "$SB_RECORD_DIR_CANON" "$(sb_canon "$src")" || sb_under "$(sb_canon "$src")" "$SB_RECORD_DIR_CANON"; then
      sb_die "the effective record directory $SB_RECORD_DIR_CANON overlaps the mount $src; set XDG_CONFIG_HOME outside every mount"
    fi
  done
  # project / git dir / overlays are LAYOUT: derived from the working tree at every launch, never decided
  SB_LAYOUT=("${SB_MOUNTS[@]:0:nlayout}")
  SB_MOUNTS=("${SB_MOUNTS[@]:nlayout}")
}

APPROVED_TOKENS=(); APPROVED_DIRS=()

# ---------------------------------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------------------------------
sb_ask() {  # sb_ask PROMPT → answer on stdout
  local ans=""
  printf '%s ' "$1" >&2
  IFS= read -r ans || ans=""
  printf '%s' "$ans"
}

# shellcheck disable=SC2016  # runs inside the container; expansion must happen there
sb_ready_script='
fail() { echo "wgm-ready-fail:$1"; exit 1; }
proj="$1"; shift
cd "$proj" 2>/dev/null || fail "project path $proj is not the working directory"
if [ "$WGM_READY_GIT" = 1 ]; then git -C "$proj" rev-parse >/dev/null 2>&1 || fail "git -C $proj rev-parse"; fi
for a in "$@"; do
  command -v "$a" >/dev/null 2>&1 || fail "agent CLI $a is not found inside the sandbox"
  out="$("$a" --version 2>&1 </dev/null)"; rc=$?
  case "$out" in *"xec format error"*) fail "agent CLI $a: exec format error" ;; esac
  if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then fail "agent CLI $a is not executable inside the sandbox (exit $rc)"; fi
done
echo wgm-ready-ok
'

sb_cmd_preflight() {
  local project="." interactive=auto force=0 noforce=0 dry=0 image_flag=""
  local -a agent_cmds=() agent_exes=() gates=() orig=("$@")
  SB_EXTRA_MOUNTS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) [[ $# -ge 2 ]] || sb_die "--project requires DIR"; project="$2"; shift 2 ;;
      --agent-cmd) [[ $# -ge 2 ]] || sb_die "--agent-cmd requires CMD"; agent_cmds+=("$2"); shift 2 ;;
      --agent-exe) [[ $# -ge 2 ]] || sb_die "--agent-exe requires PATH"; [[ -n "$2" ]] || sb_die "--agent-exe: empty executable"; agent_exes+=("$2"); shift 2 ;;
      --gate-cmd) [[ $# -ge 2 ]] || sb_die "--gate-cmd requires CMD"; gates+=("$2"); shift 2 ;;
      --interactive) [[ $# -ge 2 ]] || sb_die "--interactive requires auto|yes|no"; interactive="$2"; shift 2 ;;
      --devcontainer) force=1; shift ;;
      --no-devcontainer) noforce=1; shift ;;
      --devcontainer-image) [[ $# -ge 2 ]] || sb_die "--devcontainer-image requires TAG"; image_flag="$2"; shift 2 ;;
      --devcontainer-mount) [[ $# -ge 2 ]] || sb_die "--devcontainer-mount requires HOST"; SB_EXTRA_MOUNTS+=("$2"); shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) sb_die "preflight: unknown argument $1" ;;
    esac
  done
  case "$interactive" in auto|yes|no) ;; *) sb_die "--interactive must be auto|yes|no" ;; esac
  SB_AGENTS=(); SB_MOUNTS=(); SB_ENVS=(); SB_COPYSRC=(); SB_TOKENS=(); SB_PATHS=(); SB_SMOKE_OVERRIDE=0

  # 1. already inside
  if [[ -n "${WGM_IN_DEVCONTAINER:-}" ]]; then SB_MODE=inside; SB_ENGINE=none; SB_REASON=inside; SB_IMAGE=""; SB_RECORD=""; sb_emit; return 0; fi
  # 2. conflicting explicit choices
  if [[ "$force" -eq 1 && "$noforce" -eq 1 ]] \
     || { [[ "$force" -eq 1 ]] && [[ "${WGM_DEVCONTAINER:-}" == 0 ]]; } \
     || { [[ "$noforce" -eq 1 ]] && [[ "${WGM_DEVCONTAINER:-}" == 1 ]]; }; then
    sb_die "conflicting sandbox choices: --devcontainer / --no-devcontainer / WGM_DEVCONTAINER disagree. Pass only one (unset WGM_DEVCONTAINER or drop the flag)."
  fi
  # 3. explicit opt-out
  if [[ "$noforce" -eq 1 ]]; then SB_MODE=off; SB_ENGINE=none; SB_REASON=operator-flag; SB_IMAGE=""; SB_RECORD=""; sb_emit; return 0; fi
  if [[ "${WGM_DEVCONTAINER:-}" == 0 ]]; then SB_MODE=off; SB_ENGINE=none; SB_REASON=operator-env; SB_IMAGE=""; SB_RECORD=""; sb_emit; return 0; fi
  [[ "$force" -eq 1 || "${WGM_DEVCONTAINER:-}" == 1 ]] && force=1

  sb_env_allowlist_inproc ""         # C7 phase 1: the FIRST host action (builtins only)
  sb_bootstrap_host_env "$project"
  sb_repo_layout "$project"
  SB_WRITABLE=("$SB_PROJECT" "$SB_COMMON")
  if [[ -z "${WGM_HOST_ENV_CLEAN:-}" ]]; then
    cd "$SB_PROJECT" && SB_KEEP_ALL_CRED=1 sb_clean_env_exec "${WGM_HOST_ENV_QUIET:-0}" "$SB_SELF" preflight "${orig[@]}" --project "$SB_PROJECT"
  fi

  sb_check_host_tools
  sb_host_tmp_init
  exec 8>&2; SB_ERRFD=8   # refusals / retained-container lines bypass the redirected launch outputs
  trap 'sb_cleanup' EXIT
  trap 'sb_on_signal 130' INT
  trap 'sb_on_signal 143' TERM
  local is_tty=0
  case "$interactive" in yes) is_tty=1 ;; auto) [[ -t 0 && -t 2 ]] && is_tty=1 ;; esac

  # 4/5. engine
  local eng="none"
  if sb_engine_working podman; then eng=podman; elif sb_engine_working docker; then eng=docker; fi
  # first-match order: the forced + no-engine refusal comes BEFORE any record consultation, so a bad record (symlinked,
  # group-writable…) can never replace the required engine/install guidance
  if [[ "$eng" == none && "$force" -eq 1 ]]; then sb_install_guidance >&2; sb_die "a working container engine is required (the sandbox was forced); a recorded decline never turns a forced run off"; fi
  sb_record_load
  if [[ "$eng" == none ]]; then
    # 6. no engine
    SB_ENGINE=none; SB_IMAGE=""
    if [[ "$REC_DECLINED" == true ]]; then SB_MODE=off; SB_REASON=recorded-decline; sb_emit; return 0; fi
    if [[ "$is_tty" -eq 1 && "$dry" -eq 0 ]]; then
      sb_install_guidance >&2
      local ans; ans="$(sb_ask "Proceed without a sandbox and remember this? [y/N]")"
      if [[ "$ans" == y || "$ans" == Y ]]; then
        REC_DECLINED=true; REC_DECLINED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; sb_record_save
        SB_MODE=off; SB_REASON=recorded-decline; sb_emit; return 0
      fi
      sb_die "no sandbox engine and no decision recorded; install Podman or Docker and rerun, or pass --no-devcontainer"
    fi
    sb_install_guidance >&2
    sb_die "no container engine and no recorded decision. Install one (above) or, to run unsandboxed, pass --no-devcontainer (headless runs never decide for you; run once interactively to record the choice)."
  fi
  SB_ENGINE="$eng"; SB_MODE=on; SB_REASON=engine-found; [[ "$force" -eq 1 ]] && SB_REASON=forced

  # 7. agents
  local c nm w
  SB_AGENT_WORDS=()
  # --agent-exe PATH is an argv[0]: an OPAQUE pathname end to end (identity = basename of the WHOLE path; static
  # discovery and the readiness probe get the whole path, spaces and all); --agent-cmd TEXT is shell-command text and
  # contributes its first shell word.
  local kind
  for kind in exe cmd; do
    local -a alist=()
    if [[ "$kind" == exe ]]; then alist=("${agent_exes[@]}"); else alist=("${agent_cmds[@]}"); fi
    for c in "${alist[@]}"; do
      if [[ "$kind" == exe ]]; then w="$c"; else w="$(sb_first_word_name "$c")"; fi
      [[ -n "$w" ]] || continue
      nm="${w##*/}"; [[ -n "$nm" ]] || nm="$w"
      sb_has "$nm" "${SB_AGENTS[@]}" || SB_AGENTS+=("$nm")
      sb_has "$w" "${SB_AGENT_WORDS[@]}" || SB_AGENT_WORDS+=("$w")
    done
  done
  local sorted_agents
  sorted_agents="$(printf '%s\n' "${SB_AGENTS[@]}" | LC_ALL=C sort | tr '\n' ' ')"; sorted_agents="${sorted_agents% }"
  # 8. credentials
  sb_proposal
  local need=0 reason_need="" x
  APPROVED_TOKENS=(); APPROVED_DIRS=()
  if [[ ${#P_TOKENS[@]} -gt 0 || ${#P_DIRS[@]} -gt 0 || ${#P_ENV[@]} -gt 0 ]]; then
    if [[ "$REC_PRESENT" -ne 1 || "$sorted_agents" != "$REC_AGENTS" ]]; then need=1; reason_need="the approved agent set ('${REC_AGENTS:-none}') differs from this run's ('$sorted_agents')"; fi
    for x in "${P_TOKENS[@]}"; do sb_has "${x%%:*}" "${REC_TOKENS[@]}" || { need=1; reason_need="token file ${x%%:*} is not approved"; }; done
    for x in "${P_DIRS[@]}"; do sb_has "${x%%:*}" "${REC_COPIES[@]}" || { need=1; reason_need="config dir ${x%%:*} is not approved (or changed)"; }; done
    for x in "${P_ENV[@]}"; do sb_has "$x" "${REC_ENV[@]}" || { need=1; reason_need="environment name $x is not approved"; }; done
  fi
  if [[ "$need" -eq 0 && "$REC_PRESENT" -eq 1 && -n "$REC_AGENTS" && "$sorted_agents" != "$REC_AGENTS" ]]; then
    # an existing approval is for ANOTHER agent set: ask again (interactive) / exit 2 (headless) even though this
    # run proposes no credentials
    need=1; reason_need="the approved agent set ('$REC_AGENTS') differs from this run's ('$sorted_agents')"
  fi
  # APPROVED-IDENTITY CHECK for EVERY record category (tokens, config-dir copies, extra mounts, env names), before any
  # missing-path filtering can hide an approved item: each approved identity must still be what is configured now. A path
  # that became a symlink (dangling or not), a non-directory/non-regular entry, was retargeted or removed leaves the
  # proposal without it; that must not pass silently (no approval, no copy, no readiness): re-approval (interactive) /
  # exit 2 (headless), naming the path and its state. (A missing/unreadable approved TOKEN FILE keeps its own refusal below.)
  SB_STALE_REC=()
  local pt dd ta tp tcanon dp hp detail=""
  local -a stale_t=() stale_c=() stale_m=() stale_e=()
  if [[ "$need" -eq 0 && "$REC_PRESENT" -eq 1 ]]; then
    for x in "${REC_TOKENS[@]}"; do
      [[ -f "$x" && -r "$x" ]] || continue
      pt=0; for t in "${P_TOKENS[@]}"; do [[ "${t%%:*}" == "$x" ]] && pt=1; done
      [[ "$pt" -eq 1 ]] || stale_t+=("$x")
    done
    for x in "${REC_COPIES[@]}"; do
      dd=0; for t in "${P_DIRS[@]}"; do [[ "${t%%:*}" == "$x" ]] && dd=1; done
      [[ "$dd" -eq 1 ]] || stale_c+=("$x")
    done
    for x in "${REC_MOUNTS[@]}"; do
      hp="${x%%:*}"
      if [[ -L "$hp" || ! -e "$hp" ]] || { [[ ! -d "$(sb_canon "$hp")" && ! -f "$(sb_canon "$hp")" ]]; }; then stale_m+=("$x"); fi
    done
    for x in "${REC_ENV[@]}"; do sb_has "$x" "${P_ENV_ALL[@]}" || stale_e+=("$x"); done
    if [[ ${#stale_t[@]} -gt 0 ]]; then
      for ta in "${SB_AGENTS[@]}"; do
        sb_agent_table "$ta"; [[ -n "$SB_T_TOKEN" ]] || continue
        tp="$HOME/$SB_T_TOKEN"
        if [[ -e "$tp" || -L "$tp" ]]; then tcanon="$(sb_canon "$tp")"; [[ -f "$tcanon" ]] || detail+="$tp resolves to $tcanon, which is missing or not a regular file; "; fi
      done
      SB_STALE_REC+=("the approved token ${stale_t[*]} is no longer the target of any configured token path (retargeted, removed or dangling)")
    fi
    if [[ ${#stale_c[@]} -gt 0 ]]; then
      for ta in "${SB_AGENTS[@]}"; do
        sb_agent_table "$ta"; [[ -n "$SB_T_DIR" ]] || continue
        dp="$HOME/$SB_T_DIR"
        if [[ -L "$dp" ]]; then
          tcanon="$(sb_canon "$dp")"
          if [[ -d "$tcanon" ]]; then detail+="$dp is a symlink to $tcanon; "; else detail+="$dp is a dangling symlink to $tcanon; "; fi
        elif [[ -e "$dp" && ! -d "$dp" ]]; then detail+="$dp is not a directory; "
        elif [[ ! -e "$dp" ]]; then detail+="$dp no longer exists; "; fi
      done
      SB_STALE_REC+=("the approved config directory ${stale_c[*]} is no longer the configured directory (replaced by a symlink or a file, retargeted or removed)")
    fi
    if [[ ${#stale_m[@]} -gt 0 ]]; then SB_STALE_REC+=("the approved extra mount ${stale_m[*]} is now a symlink, missing, or neither a directory nor a regular file"); fi
    if [[ ${#stale_e[@]} -gt 0 ]]; then SB_STALE_REC+=("the approved environment name ${stale_e[*]} is not used by this run's agents"); fi
    if [[ ${#SB_STALE_REC[@]} -gt 0 ]]; then
      need=1; reason_need="$(IFS='; '; printf '%s' "${SB_STALE_REC[*]}")"
      [[ -z "$detail" ]] || reason_need+=" — ${detail%; }"
    fi
  fi
  if [[ "$need" -eq 1 ]]; then
    local prop="Credentials the sandbox would use for agent(s) $sorted_agents (COPIED into a throwaway dir; nothing is written back):"
    for x in "${P_TOKENS[@]}"; do prop+=$'\n'"  token file  ${x%%:*}  ->  ${x#*:}"; done
    for x in "${P_DIRS[@]}"; do prop+=$'\n'"  config files (top-level, non-executable)  ${x%%:*}  ->  ${x#*:}"; done
    for x in "${P_ENV[@]}"; do prop+=$'\n'"  env name  $x (value forwarded by name only)"; done
    [[ ${#P_TOKENS[@]} -gt 0 || ${#P_DIRS[@]} -gt 0 || ${#P_ENV[@]} -gt 0 ]] || prop+=$'\n'"  (no credentials are proposed for this agent set)"
    if [[ "$is_tty" -eq 1 && "$dry" -eq 0 ]]; then
      printf '%s\n(%s)\n' "$prop" "$reason_need" >&2
      local ans; ans="$(sb_ask "Mount these into the sandbox? [Y/n]")"
      if [[ "$ans" == n || "$ans" == N ]]; then sb_die "credentials not approved; the agent cannot authenticate inside the sandbox. Re-run and approve, or pass --no-devcontainer."; fi
      REC_PRESENT=1; REC_AGENTS="$sorted_agents"
      REC_TOKENS=(); REC_COPIES=(); REC_ENV=()
      local -a keep_m=(); for x in "${REC_MOUNTS[@]}"; do sb_has "$x" "${stale_m[@]}" || keep_m+=("$x"); done; REC_MOUNTS=("${keep_m[@]}")   # approving drops the stale mounts only
      for x in "${P_TOKENS[@]}"; do REC_TOKENS+=("${x%%:*}"); done
      for x in "${P_DIRS[@]}"; do REC_COPIES+=("${x%%:*}"); done
      for x in "${P_ENV[@]}"; do REC_ENV+=("$x"); done
      sb_record_save
    else
      printf '%s\n' "$prop" >&2
      sb_die "credentials need approval (${reason_need}) and no one can be asked (headless${dry:+ / dry run}). Approve once interactively: scripts/sandbox.sh preflight --interactive yes --agent-cmd '<agent>'; or provision the record $SB_RECORD (plain lines: agents:, tokens:, copies:, env: — see docs/reference/cli-loop.md)."
    fi
  elif [[ "$REC_PRESENT" -ne 1 || "$sorted_agents" != "$REC_AGENTS" ]] && [[ "$dry" -eq 0 && ${#P_TOKENS[@]} -eq 0 && ${#P_DIRS[@]} -eq 0 && ${#P_ENV[@]} -eq 0 ]]; then
    :  # nothing to propose (unknown agent): nothing to ask, nothing to record
  fi
  # EVERY approved token must still be a reachable regular file on the host (not only those proposed now)
  for x in "${REC_TOKENS[@]}"; do
    if [[ ! -f "$x" || ! -r "$x" ]]; then
      sb_die "credential $x not reachable: the approved token file is missing, not a regular file, or unreadable. The approval record is $SB_RECORD and lists it as the line '  - $x' under tokens:. Recovery: restore that file, OR remove that exact line from the record (or delete the record file) and rerun interactively — scripts/sandbox.sh preflight --interactive yes --agent-cmd '<agent>' — to re-approve (a still-listed missing token refuses even interactively)."
    fi
  done
  for x in "${P_TOKENS[@]}"; do sb_has "${x%%:*}" "${REC_TOKENS[@]}" && APPROVED_TOKENS+=("$x"); done
  for x in "${P_DIRS[@]}"; do sb_has "${x%%:*}" "${REC_COPIES[@]}" && APPROVED_DIRS+=("$x"); done
  SB_ENVS=()
  for x in "${P_ENV_ALL[@]}"; do
    if sb_has "$x" "${REC_ENV[@]}"; then
      [[ -n "${!x:-}" ]] || sb_die "credential $x not reachable: the approved environment variable $x is empty/unset in this shell (export it, or re-approve without it)"
      SB_ENVS+=("$x")
    fi
  done
  # only APPROVED credential env names may stay in this process (and so in any engine child's environment)
  for x in $(sb_all_cred_env_names); do sb_has "$x" "${SB_ENVS[@]}" || unset "$x"; done
  # record's explicit mounts join the explicit set
  for x in "${REC_MOUNTS[@]}"; do SB_EXTRA_MOUNTS+=("$x"); done
  # 9. image
  if [[ -n "$image_flag" ]]; then SB_IMAGE="$image_flag"
  elif [[ -n "${WGM_DEVCONTAINER_IMAGE:-}" ]]; then SB_IMAGE="$WGM_DEVCONTAINER_IMAGE"
  elif [[ -n "$REC_IMAGE" ]]; then SB_IMAGE="$REC_IMAGE"
  else SB_IMAGE="$SB_DEFAULT_IMAGE"; fi

  sb_plan_mounts "$dry"
  sb_skill_mounts
  if ! sb_under "$SB_SKILL_ROOT" "$SB_PROJECT" && ! { [[ -n "$SB_COMMON" ]] && sb_under "$SB_SKILL_ROOT" "$SB_COMMON"; }; then sb_policy_check "$SB_SKILL_ROOT" "wgm skill bundle"; fi
  sb_assert_private_outside
  if [[ "$dry" -eq 1 ]]; then sb_emit; return 0; fi

  # pins/run state so the readiness probe and smoke use the real launch path
  sb_pin_capture
  sb_make_copies
  sb_assert_private_outside
  trap 'sb_cleanup' EXIT
  # 10. readiness
  local out rc=0 fix
  fix="install the agent CLI in a project image: \`$SB_ENGINE build -t <tag> -f .devcontainer/Containerfile .\` then \`--devcontainer-image <tag>\`"
  local gitflag=0; [[ "$SB_IS_GIT" -eq 1 ]] && gitflag=1
  local -a agent_names=("${SB_AGENT_WORDS[@]}")
  # captured via a FILE (not $(...)): a signal must interrupt the launch immediately, not after it finishes
  WGM_READY_GIT=$gitflag sandbox_exec bash -c "$sb_ready_script" _ "$SB_PROJECT" "${agent_names[@]}" > "$SB_HOSTTMP/ready.out" 2>&1 || rc=$?
  out="$(cat "$SB_HOSTTMP/ready.out")"
  if [[ "$rc" -ne 0 || "$out" != *wgm-ready-ok* ]]; then
    local piece; piece="$(grep -o 'wgm-ready-fail:.*' <<<"$out" | head -1 | sed 's/^wgm-ready-fail://')"
    [[ -n "$piece" ]] || piece="the container did not start: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    sb_die "sandbox readiness failed: $piece. Fix: $fix"
  fi
  # (b) credential reachability inside
  local tk
  for tk in "${SB_TOKENS[@]}"; do
    rc=0; sandbox_exec test -r "${tk#*:}" || rc=$?
    [[ "$rc" -eq 0 ]] || sb_die "credential ${tk%%:*} not reachable inside the sandbox (container path ${tk#*:} unreadable)"
  done
  # The three readiness TIERS, reported separately (one line each; names and paths only — never a credential value;
  # stderr, so the decision output format on stdout is unchanged)
  {
    echo "sandbox readiness [1/3] agent executable available in the container: ${agent_names[*]:-none} — OK (ran \`--version\` inside)"
    local cdesc="" ce
    for tk in "${SB_TOKENS[@]}"; do cdesc+="token file ${tk%%:*}, "; done
    [[ ${#SB_COPYSRC[@]} -gt 0 ]] && cdesc+="${#SB_COPYSRC[@]} config dir copy(ies), "
    for ce in "${SB_ENVS[@]}"; do cdesc+="env name ${ce%%=*}, "; done
    echo "sandbox readiness [2/3] approved credentials reachable (host and inside the sandbox): $(if [[ -n "$cdesc" ]]; then printf '%s — OK' "${cdesc%, }"; else printf 'none approved (nothing to reach)'; fi)"
    echo "sandbox readiness [3/3] provider authentication: NOT verified by wgm (a valid login/token for the provider is the operator's responsibility)"
  } >&2
  # 11. smoke: each gate runs once inside, as ONE argv element of `bash -c` (exactly as on the host)
  local gate
  for gate in "${gates[@]}"; do
    rc=0; sandbox_exec bash -c "$gate" > "$SB_HOSTTMP/smoke.out" 2>&1 || rc=$?
    out="$(cat "$SB_HOSTTMP/smoke.out")"
    if [[ "$rc" -ne 0 ]]; then
      printf 'sandbox smoke failed: gate [%s] inside the container exited %s:\n%s\n' "$gate" "$rc" "$(printf '%s' "$out" | tail -15)" >&2
      # the project-image recipe is printed for EVERY failing smoke (a missing toolchain commonly surfaces through
      # a build tool with status 1 or 2), before the interactive question
      echo "Is a gate toolchain missing in the image? Build a project image (scripts/devcontainer.sh init; add the toolchain to .devcontainer/Containerfile): $SB_ENGINE build -t <tag> -f .devcontainer/Containerfile . then --devcontainer-image <tag>" >&2
      [[ "$rc" -eq 126 || "$rc" -eq 127 ]] || echo "(the gate exited $rc: if it is a genuine test failure rather than a missing tool, fix it; nothing is recorded either way)" >&2
      if [[ "$is_tty" -eq 1 ]]; then
        local ans; ans="$(sb_ask "Proceed anyway (nothing is recorded)? [y/N]")"
        if [[ "$ans" == y || "$ans" == Y ]]; then SB_SMOKE_OVERRIDE=1; else sb_die "gate smoke failed inside the sandbox"; fi
      else
        sb_die "gate smoke failed inside the sandbox (headless: not proceeding)"
      fi
      break
    fi
  done
  sb_emit
}

# ---------------------------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  case "${1:-}" in
    preflight) shift; sb_cmd_preflight "$@" ;;
    -h|--help|"") sb_usage_from "$0"; [[ -n "${1:-}" ]] ;;
    *) echo "Unknown subcommand: $1 (expected preflight)" >&2; exit 1 ;;
  esac
fi
