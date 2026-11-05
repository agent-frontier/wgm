#!/usr/bin/env bash
#
# wgm/devcontainer.sh — the local devcontainer launcher behind the loop's DEFAULT sandbox.
#
# This is NOT the scenario-validation container (`loop.sh --container`, references/validation-env.md)
# which runs the app UNDER TEST. `scripts/loop.sh` stays on the HOST (guards, git bookkeeping, telemetry);
# only the AGENT, the gate/validation commands, the agent's git commits and operator callbacks run in a container
# started by `run --same-path`, isolating an autonomous run from the host filesystem beyond the mounted project.
#
# Disk-conscious by design: the whole point is ONE shared, prebuilt base image reused across every
# project (never a per-project build), plus bind-mounts instead of COPY, so running this on N
# projects costs one image's disk, not N. See references/devcontainers.md for the full rationale.
#
# Podman-first, Docker fallback — same convention as loop.sh's --container flag. Talks to
# podman/docker directly (no dependency on the separate @devcontainers/cli), though the
# devcontainer.json it scaffolds is a standards-compliant containers.dev artifact any devcontainer
# CLI or VS Code can also open.
#
# Usage:
#   ./scripts/devcontainer.sh init       [--dir DIR]
#   ./scripts/devcontainer.sh build-base [--container podman|docker] [--tag TAG] [--force] [--dry-run]
#   ./scripts/devcontainer.sh run        [--container podman|docker] [--tag TAG] [--skill-dir DIR]
#                                        [--name NAME] [--env VAR]... [--same-path]
#                                        [--mount HOST[:CONTAINER][:ro|rw]]... [--copy-mount HOST:CONTAINER]...
#                                        [--git-common-mount DIR] [--overlay-mount PATH]... [--skill-mount SRC:DST]...
#                                        [--path-prepend DIR]... [-i] [--dry-run] -- <cmd...>
#   ./scripts/devcontainer.sh prune      [--container podman|docker] [--dry-run]
#
# Subcommands:
#   init        scaffold .devcontainer/devcontainer.json into DIR (default: .), referencing the
#               shared base image ("image", never "build"). Refuses to clobber an existing file.
#   build-base  build (idempotently) the ONE shared base image from
#               assets/devcontainer/Containerfile.template, tagged TAG. Skipped if TAG already
#               exists locally unless --force is given — rebuilding a shared image on every run
#               would defeat the point of sharing it.
#   run         bind-mount the current directory to /workspace and execute <cmd...> inside the
#               sandbox (auto-builds the base image on first use if missing). Every created
#               container is labeled and removed on exit (--rm) — nothing lingers by default.
#   prune       report disk usage (`system df`) and remove only wgm-labeled stopped containers /
#               dangling images. Never touches anything without the wgm.devcontainer label.
#
# Flags:
#   --container ENGINE  podman | docker (default: auto-detect podman, then docker)
#   --tag TAG            image tag (default: localhost/wgm-devcontainer-base:latest)
#   --dir DIR            (init) target project dir to scaffold into (default: .)
#   --force               (build-base) rebuild even if the tag already exists locally
#   --skill-dir DIR       (run) also bind-mount DIR read-only at /opt/wgm-skill inside the
#                         sandbox (legacy /workspace mode only; the loop itself never runs inside)
#   --mount HOST[:CONTAINER][:ro|rw]  (run) ALSO bind-mount HOST at CONTAINER (default: same path
#                         as HOST) — repeatable. Default mode: rw without --same-path (legacy), ro with
#                         it. Opt-in only; mounting your whole $HOME defeats the sandbox's isolation
#                         value, so wgm never does that (see references/devcontainers.md).
#   --same-path           (run) the sandbox boundary used by loop.sh: bind the CURRENT directory (the
#                         project) read-write at its own absolute path, make it the working dir, apply
#                         the mount policy to EVERY mount (refuse $HOME and its parents, ~/.ssh, ~/.gnupg,
#                         ~/.aws, runtime trees, sockets/devices/FIFOs, mount points inside a bound tree,
#                         hard-linked files in writable trees), bind everything non-recursively, pass the
#                         git identity as GIT_AUTHOR_*/GIT_COMMITTER_* and disable git auto-gc.
#   --copy-mount HOST:CONTAINER  (run, --same-path) bind a private throwaway COPY read-write
#   --git-common-mount DIR (run, --same-path) the ONE distinguished read-write allowance: the repository's common git
#                         dir at its own path (policy + hard-link scan apply). Extra `--mount`s stay read-only:
#                         `--mount …:rw` is refused with --same-path.
#   --overlay-mount PATH  (run, --same-path) a D3 read-only overlay of executable git configuration (config, hooks/,
#                         info/, objects/info/, worktrees/*/config.worktree) at its own path. The ONLY mounts
#                         allowed to lie inside the project / common dir.
#   --skill-mount SRC:DST (run, --same-path) the running wgm skill bundle, read-only; the only mounts allowed to share
#                         one canonical source across several destinations (host path + conventional skills dirs).
#   --path-prepend DIR    (run) prepend DIR to PATH inside (repeatable)
#   -i                    (run) pass stdin through to the command
#   --name NAME           (run) container name (default: let the engine auto-generate one)
#   --env VAR             (run) forward the host's $VAR into the container BY NAME (`--env VAR`; the
#                         value is inherited from this process's environment, never written to a
#                         command line or file; repeatable). Never baked into the image.
#   --dry-run             print the command(s) that WOULD run; do nothing
#   -h | --help           show this help
#
# Safety:
#   * Never bakes secrets/credentials into the shared image — only --env/--mount-forwarded at run
#     time. The host's ~/.gitconfig is never mounted: the commit identity travels as GIT_* env.
#   * wgm never runs npm/node on the host: an installed agent CLI's prefix is derived statically.
#   * Rootless-friendly: runs as the CALLING host user's UID:GID (not the image's baked UID 1000),
#     so bind-mounted files keep their real host permissions; adds Podman's --userns=keep-id too
#     (rootless Podman otherwise remaps the caller to a different apparent UID — Docker needs no
#     such flag). See Containerfile.template for the image's own baked non-root user.
#   * `run` always binds only the current directory + optional --skill-dir/--mount, never wider.
#   * `prune` only ever touches resources carrying the wgm.devcontainer=1 label.

set -euo pipefail

_h="${BASH_SOURCE[0]}"; if [[ "$_h" == */* ]]; then _h="${_h%/*}"; else _h=.; fi
HERE="$(cd "$_h" && pwd)"; unset _h
ASSETS_DIR="$HERE/../assets/devcontainer"
# shellcheck source=scripts/sandbox.sh
source "$HERE/sandbox.sh"
LABEL="wgm.devcontainer=1"
DEFAULT_TAG="localhost/wgm-devcontainer-base:latest"

usage() { sb_usage_from "$0"; }   # builtins only (see sb_usage_from)

# ----- defaults --------------------------------------------------------------
SUBCOMMAND=""
CONTAINER=""
TAG="$DEFAULT_TAG"
DIR="."
FORCE=0
SKILL_DIR=""
NAME=""
ENV_VARS=()
EXTRA_MOUNTS=()
COPY_MOUNTS=()
GIT_COMMON_MOUNTS=()
OVERLAY_MOUNTS=()
SKILL_MOUNTS=()
PATH_PREPEND=()
SAME_PATH=0
STDIN_PASS=0
DRY_RUN=0
CMD_ARGV=()

if [[ $# -eq 0 ]]; then usage; exit 2; fi
case "$1" in
  -h|--help) usage; exit 0 ;;
  init|build-base|run|prune) SUBCOMMAND="$1"; shift ;;
  *) echo "Unknown subcommand: $1 (expected init|build-base|run|prune)" >&2; exit 2 ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --container) [[ $# -ge 2 ]] || { echo "--container requires podman|docker" >&2; exit 2; }; CONTAINER="$2"; shift 2 ;;
    --tag) [[ $# -ge 2 ]] || { echo "--tag requires a value" >&2; exit 2; }; TAG="$2"; shift 2 ;;
    --dir) [[ $# -ge 2 ]] || { echo "--dir requires a path" >&2; exit 2; }; DIR="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --skill-dir) [[ $# -ge 2 ]] || { echo "--skill-dir requires a path" >&2; exit 2; }; SKILL_DIR="$2"; shift 2 ;;
    --mount) [[ $# -ge 2 ]] || { echo "--mount requires HOST[:CONTAINER][:ro|rw]" >&2; exit 2; }; EXTRA_MOUNTS+=("$2"); shift 2 ;;
    --same-path) SAME_PATH=1; shift ;;
    --copy-mount) [[ $# -ge 2 ]] || { echo "--copy-mount requires HOST:CONTAINER" >&2; exit 2; }; COPY_MOUNTS+=("$2"); shift 2 ;;
    --git-common-mount) [[ $# -ge 2 ]] || { echo "--git-common-mount requires DIR" >&2; exit 2; }; GIT_COMMON_MOUNTS+=("$2"); shift 2 ;;
    --overlay-mount) [[ $# -ge 2 ]] || { echo "--overlay-mount requires PATH" >&2; exit 2; }; OVERLAY_MOUNTS+=("$2"); shift 2 ;;
    --skill-mount) [[ $# -ge 2 ]] || { echo "--skill-mount requires SRC:DST" >&2; exit 2; }; SKILL_MOUNTS+=("$2"); shift 2 ;;
    --path-prepend) [[ $# -ge 2 ]] || { echo "--path-prepend requires a directory" >&2; exit 2; }; PATH_PREPEND+=("$2"); shift 2 ;;
    -i) STDIN_PASS=1; shift ;;
    --name) [[ $# -ge 2 ]] || { echo "--name requires a value" >&2; exit 2; }; NAME="$2"; shift 2 ;;
    --env) [[ $# -ge 2 ]] || { echo "--env requires a variable name" >&2; exit 2; }; ENV_VARS+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; CMD_ARGV=("$@"); break ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *) echo "Unexpected argument: $1" >&2; exit 2 ;;
  esac
done

# C7 phase 1: before any external tool runs, keep only the allowlisted environment (+ the --env names asked for)
WGM_HOST_ENV_QUIET=1 sb_env_allowlist_inproc "${ENV_VARS[@]}"
# ...then, still before the first external command on EVERY entry path (direct use included): bind verified tools.
# Reused (not rebuilt) when sandbox_exec already bound them for this run; a project `bin/` first on PATH never runs.
SB_FILTER_SOFT=1 WGM_HOST_ENV_QUIET=1 sb_bootstrap_host_env "$PWD"

if [[ -n "$CONTAINER" ]]; then
  case "$CONTAINER" in podman|docker) ;; *) echo "Invalid --container: $CONTAINER (podman|docker)" >&2; exit 2 ;; esac
else
  if command -v podman >/dev/null 2>&1; then CONTAINER="podman"
  elif command -v docker >/dev/null 2>&1; then CONTAINER="docker"
  else echo "Neither podman nor docker found on PATH. Install one to use scripts/devcontainer.sh." >&2; exit 2
  fi
fi
command -v "$CONTAINER" >/dev/null 2>&1 || { echo "'$CONTAINER' not found on PATH." >&2; exit 2; }

image_exists() { "$CONTAINER" image inspect "$TAG" >/dev/null 2>&1; }

# ----- init -------------------------------------------------------------------
cmd_init() {
  local target="$DIR/.devcontainer" dest="$DIR/.devcontainer/devcontainer.json"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "== wgm devcontainer init (dry run) =="
    echo "would create: $dest (from ${ASSETS_DIR}/devcontainer.json.template)"
    [[ -e "$dest" ]] && echo "NOTE: already exists — a real run would refuse to overwrite it."
    return 0
  fi
  [[ -f "${ASSETS_DIR}/devcontainer.json.template" ]] || { echo "template missing: ${ASSETS_DIR}/devcontainer.json.template" >&2; exit 2; }
  if [[ -e "$dest" ]]; then
    echo "Refusing to overwrite existing $dest. Remove it first if you want to re-scaffold." >&2
    exit 1
  fi
  mkdir -p "$target"
  cp "${ASSETS_DIR}/devcontainer.json.template" "$dest"
  echo "Scaffolded $dest (references shared image: $TAG)"
  echo "Build the shared base image once with: $0 build-base"
}

# ----- build-base ---------------------------------------------------------------
cmd_build_base() {
  local cf="${ASSETS_DIR}/Containerfile.template"
  [[ -f "$cf" ]] || { echo "template missing: $cf" >&2; exit 2; }
  if [[ "$FORCE" -eq 0 ]] && [[ "$DRY_RUN" -eq 0 ]] && image_exists; then
    echo "$TAG already built (use --force to rebuild). Rebuilding a shared image on every run would defeat the point of sharing it."
    return 0
  fi
  local build_cmd=("$CONTAINER" build -t "$TAG" --label "$LABEL" -f "$cf" "$ASSETS_DIR")
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "== wgm devcontainer build-base (dry run) =="
    echo "${build_cmd[*]}"
    return 0
  fi
  "${build_cmd[@]}"
}

# ----- run -------------------------------------------------------------------
# Static (never executed) prefix of an installed binary, for the legacy /workspace mode.
legacy_npm_prefix() {
  local bin
  bin="$(command -v npm 2>/dev/null || true)"
  [[ -n "$bin" ]] || return 0
  sb_discover "$bin"
  printf '%s' "$SB_D_PREFIX"
}

# Non-recursive bind option for the engine; an engine that cannot do it is refused (exit 2).
nonrecursive_opt() {
  local v major
  v="$("$CONTAINER" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+' | head -1 || true)"
  major="${v%%.*}"
  if [[ "$CONTAINER" == "podman" ]]; then
    [[ -z "$major" || "$major" -ge 4 ]] || { echo "sandbox: $CONTAINER $v cannot bind non-recursively (need Podman >= 4); refusing." >&2; exit 2; }
    printf 'bind-nonrecursive=true'
  else
    [[ -z "$major" || "$major" -ge 25 ]] || { echo "sandbox: $CONTAINER $v cannot bind non-recursively (need Docker >= 25); refusing." >&2; exit 2; }
    printf 'bind-recursive=disabled'
  fi
}

cmd_run() {
  [[ ${#CMD_ARGV[@]} -ge 1 ]] || { echo "run requires a command after --. See --help." >&2; exit 2; }

  local -a mount_args=() env_args=() name_args=()
  local m host_path container_path mode
  env_args=(--env "WGM_IN_DEVCONTAINER=1")
  local -a pre_path=("${PATH_PREPEND[@]}")

  if [[ "$SAME_PATH" -eq 1 ]]; then
    local proj nr seen=" " cs
    local -A srcdest=()
    proj="$(pwd -P)"
    nr="$(nonrecursive_opt)"
    sb_init_record_dir
    bind() {  # bind SRC DST MODE — EVERY mount kind goes through here: a duplicate DESTINATION is refused (exit 2)
      if [[ "$seen" == *" $2 "* ]]; then echo "sandbox: two mounts would land on the same container path $2" >&2; exit 2; fi
      seen+="$2 "
      local o="type=bind,source=$1,destination=$2,$nr"
      [[ "$3" == ro ]] && o+=",ro=true"
      mount_args+=(--mount "$o")
    }
    sb_policy_check "$proj" "project"
    sb_hardlink_check "$proj"
    bind "$proj" "$proj" rw; srcdest["$proj"]="$proj"
    # ONE destination per CANONICAL source (symlink aliases included); the skill aliases are the only exception
    one_dest() {  # one_dest CANONICAL_SRC DST
      if [[ -n "${srcdest[$1]:-}" && "${srcdest[$1]}" != "$2" ]]; then
        echo "sandbox: mount refused: the source $1 would be mounted at two destinations (${srcdest[$1]} and $2); one destination per canonical source" >&2; exit 2
      fi
      srcdest["$1"]="$2"
    }
    for m in "${GIT_COMMON_MOUNTS[@]}"; do
      [[ -d "$m" ]] || { echo "--git-common-mount source not found: $m" >&2; exit 2; }
      cs="$(sb_canon "$m")"
      sb_policy_check "$cs" "git common directory"; sb_hardlink_check "$cs"
      one_dest "$cs" "$cs"
      bind "$cs" "$cs" rw
    done
    # ONE launcher-wide OVERLAP policy for every assembled source: an extra mount may not equal, contain or lie
    # inside the project, a git common mount, a copy mount or another extra mount (the D3 overlays and the C5 skill
    # aliases are the only exceptions and have their own flags)
    local -a srclist=("$proj")
    overlaps() {  # overlaps CANONICAL_SRC → refuse if it overlaps anything already assembled
      local a="$1" b
      for b in "${srclist[@]}"; do
        if sb_under "$a" "$b" || sb_under "$b" "$a"; then
          echo "sandbox: mount refused: $a equals, contains or lies inside the already assembled source $b (the project, the git dir or another mount)" >&2; exit 2
        fi
      done
    }
    for m in "${GIT_COMMON_MOUNTS[@]}"; do srclist+=("$(sb_canon "$m")"); done
    for m in "${COPY_MOUNTS[@]}"; do srclist+=("$(sb_canon "${m%%:*}")"); done
    for m in "${EXTRA_MOUNTS[@]}"; do
      mode=ro
      case "$m" in *:ro) m="${m%:ro}" ;; *:rw) echo "sandbox: mount refused: $m — with --same-path every extra --mount is read-only (the common git dir has its own --git-common-mount)" >&2; exit 2 ;; esac
      host_path="${m%%:*}"; container_path="${m#*:}"
      [[ "$container_path" == "$m" ]] && container_path="$host_path"
      [[ -e "$host_path" ]] || { echo "--mount source not found: $host_path" >&2; exit 2; }
      host_path="$(sb_canon "$host_path")"
      sb_policy_check "$host_path" "mount"
      one_dest "$host_path" "$container_path"
      overlaps "$host_path"; srclist+=("$host_path")
      bind "$host_path" "$container_path" "$mode"
    done
    for m in "${COPY_MOUNTS[@]}"; do
      host_path="${m%%:*}"; container_path="${m#*:}"
      [[ -d "$host_path" ]] || { echo "--copy-mount source not found: $host_path" >&2; exit 2; }
      host_path="$(sb_canon "$host_path")"
      sb_policy_check "$host_path" "credential copy"
      one_dest "$host_path" "$container_path"
      bind "$host_path" "$container_path" rw
    done
    for m in "${OVERLAY_MOUNTS[@]}"; do
      [[ -e "$m" ]] || { echo "--overlay-mount source not found: $m" >&2; exit 2; }
      host_path="$(sb_canon "$m")"
      sb_policy_check "$host_path" "git config overlay"
      bind "$host_path" "$host_path" ro
    done
    for m in "${SKILL_MOUNTS[@]}"; do
      host_path="${m%%:*}"; container_path="${m#*:}"
      [[ -d "$host_path" ]] || { echo "--skill-mount source not found: $host_path" >&2; exit 2; }
      host_path="$(sb_canon "$host_path")"
      sb_policy_check "$host_path" "wgm skill bundle"
      bind "$host_path" "$container_path" ro
    done
    # Commit identity from the host's git config (the ~/.gitconfig file itself is never mounted) and
    # no automatic gc/maintenance, so ordinary commits never need the read-only parts of the git dir.
    local gv
    for gv in "AUTHOR_NAME:user.name" "AUTHOR_EMAIL:user.email" "COMMITTER_NAME:user.name" "COMMITTER_EMAIL:user.email"; do
      local val; val="$(wgm_host_git config --get "${gv#*:}" 2>/dev/null || true)"
      [[ -n "$val" ]] && env_args+=(--env "GIT_${gv%%:*}=$val")
    done
    env_args+=(--env "GIT_CONFIG_COUNT=2" --env "GIT_CONFIG_KEY_0=gc.auto" --env "GIT_CONFIG_VALUE_0=0"
               --env "GIT_CONFIG_KEY_1=maintenance.auto" --env "GIT_CONFIG_VALUE_1=false" --env "HOME=$SB_CONT_HOME")
  else
    mount_args=(-v "$(pwd):/workspace:rw")
    if [[ -n "$SKILL_DIR" ]]; then
      [[ -d "$SKILL_DIR" ]] || { echo "--skill-dir not found: $SKILL_DIR" >&2; exit 2; }
      mount_args+=(-v "$(cd "$SKILL_DIR" && pwd):/opt/wgm-skill:ro")
    fi
    for m in "${EXTRA_MOUNTS[@]}"; do
      mode=rw
      case "$m" in *:ro) m="${m%:ro}"; mode=ro ;; *:rw) m="${m%:rw}" ;; esac
      host_path="${m%%:*}"; container_path="${m#*:}"
      [[ "$container_path" == "$m" ]] && container_path="$host_path"   # no ":CONTAINER" given
      [[ -e "$host_path" ]] || { echo "--mount source not found: $host_path" >&2; exit 2; }
      mount_args+=(-v "$(cd "$(dirname "$host_path")" && pwd)/$(basename "$host_path"):${container_path}:${mode}")
    done
    # Best-effort: bring an already-installed agent CLI in via its install prefix, DERIVED STATICALLY
    # (wgm never runs npm/node on the host), mounted read-only at the same path so PATH resolution matches.
    local npm_prefix=""
    npm_prefix="$(legacy_npm_prefix || true)"
    if [[ -n "$npm_prefix" && -d "$npm_prefix" ]]; then
      mount_args+=(-v "${npm_prefix}:${npm_prefix}:ro")
      pre_path+=("${npm_prefix}/bin")
    fi
    # Credentials/config no longer come from the host's ~/.gitconfig file: identity travels as env.
    local gv val
    for gv in "AUTHOR_NAME:user.name" "AUTHOR_EMAIL:user.email" "COMMITTER_NAME:user.name" "COMMITTER_EMAIL:user.email"; do
      val="$(git config --get "${gv#*:}" 2>/dev/null || true)"
      [[ -n "$val" ]] && env_args+=(--env "GIT_${gv%%:*}=$val")
    done
  fi
  if [[ ${#pre_path[@]} -gt 0 ]]; then
    local pp; pp="$(IFS=:; echo "${pre_path[*]}")"
    env_args+=(--env "PATH=${pp}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
  fi
  # Forward credentials/variables BY NAME only: the value is inherited from this process's environment.
  local v
  for v in "${ENV_VARS[@]}"; do
    [[ -n "${!v+x}" ]] && env_args+=(--env "$v")
  done

  [[ -n "$NAME" ]] && name_args=(--name "$NAME")

  # Run as the CALLING host user's UID:GID (not the image's baked "wgm" UID 1000) so bind-mounted
  # files/dirs keep their real host permissions inside the sandbox — otherwise a mode-0700 project
  # dir (e.g. from `mktemp -d`, or simply not world-readable) is unreadable to a mismatched UID.
  # Rootless Podman additionally user-namespaces the caller to a *different* apparent UID inside the
  # container by default, so --userns=keep-id is required there too; plain Docker needs no such flag
  # (no remapping happens unless the operator has opted into userns-remap themselves).
  local -a userns_args=(--user "$(id -u):$(id -g)")
  [[ "$CONTAINER" == "podman" ]] && userns_args+=(--userns=keep-id)
  local -a io_args=()
  [[ "$STDIN_PASS" -eq 1 ]] && io_args=(-i)

  local workdir=/workspace
  [[ "$SAME_PATH" -eq 1 ]] && workdir="$(pwd -P)"

  local need_build=0
  if [[ "$DRY_RUN" -eq 0 ]] && ! image_exists; then need_build=1; fi

  local run_cmd=("$CONTAINER" run --rm --init --label "$LABEL" "${io_args[@]}" "${userns_args[@]}" "${name_args[@]}" "${mount_args[@]}" "${env_args[@]}" -w "$workdir" "$TAG" "${CMD_ARGV[@]}")
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "== wgm devcontainer run (dry run) =="
    echo "container=${CONTAINER} tag=${TAG} skill_dir=${SKILL_DIR:-none} env=${ENV_VARS[*]:-none} extra_mounts=${#EXTRA_MOUNTS[@]} same_path=${SAME_PATH}"
    if ! image_exists 2>/dev/null; then echo "(would build-base first — $TAG not found locally)"; fi
    echo "${run_cmd[*]}"
    return 0
  fi
  if [[ "$need_build" -eq 1 ]]; then
    echo "Image $TAG not found locally — building it once (subsequent runs reuse it)..." >&2
    cmd_build_base >&2
  fi
  # exec: the engine client IS this process, so a TERM sent to it reaches the engine directly. A bound-tools dir
  # THIS process created (direct use) cannot outlive the exec through a trap: resolve the engine first, remove it.
  if [[ "${WGM_BINDIR_OWNER:-}" == "$$" && -n "$SB_BINDIR" ]]; then
    local eng
    eng="$(readlink -f "$(command -v "$CONTAINER")")" && run_cmd[0]="$eng"
    "${SB_BOOT_RM:-/bin/rm}" -rf -- "$SB_BINDIR" 2>/dev/null || true
    trap - EXIT
  fi
  exec "${run_cmd[@]}"
}

# ----- prune -------------------------------------------------------------------
cmd_prune() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "== wgm devcontainer prune (dry run) =="
    echo "-- disk usage (${CONTAINER} system df) --"
    "$CONTAINER" system df 2>/dev/null || true
    echo "-- would remove: stopped containers labeled ${LABEL} --"
    "$CONTAINER" ps -a --filter "label=${LABEL}" --filter "status=exited" --format '{{.ID}}  {{.Names}}' 2>/dev/null || true
    echo "-- would remove: dangling images labeled ${LABEL} --"
    "$CONTAINER" images --filter "label=${LABEL}" --filter "dangling=true" --format '{{.ID}}  {{.Repository}}' 2>/dev/null || true
    echo "(the tagged base image itself, $TAG, is never removed by prune — that's the image being shared)"
    return 0
  fi

  echo "-- disk usage before --"; "$CONTAINER" system df || true

  local removed=0
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    "$CONTAINER" rm "$cid" >/dev/null 2>&1 && removed=$((removed + 1))
  done < <("$CONTAINER" ps -a --filter "label=${LABEL}" --filter "status=exited" --format '{{.ID}}' 2>/dev/null || true)
  echo "Removed ${removed} stopped wgm-labeled container(s)."

  local pruned=0
  while IFS= read -r iid; do
    [[ -z "$iid" ]] && continue
    "$CONTAINER" rmi "$iid" >/dev/null 2>&1 && pruned=$((pruned + 1))
  done < <("$CONTAINER" images --filter "label=${LABEL}" --filter "dangling=true" --format '{{.ID}}' 2>/dev/null || true)
  echo "Removed ${pruned} dangling wgm-labeled image(s)."

  echo "-- disk usage after --"; "$CONTAINER" system df || true
}

case "$SUBCOMMAND" in
  init) cmd_init ;;
  build-base) cmd_build_base ;;
  run) cmd_run ;;
  prune) cmd_prune ;;
esac
