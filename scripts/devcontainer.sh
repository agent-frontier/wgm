#!/usr/bin/env bash
#
# wgm/devcontainer.sh — OPTIONAL local devcontainer sandbox for running the Ralph loop itself.
#
# This is NOT the scenario-validation container (`loop.sh --container`, references/validation-env.md)
# which runs the app UNDER TEST. This runs the AGENT LOOP itself sandboxed — isolating an autonomous
# `scripts/loop.sh` run from the host filesystem beyond the mounted project.
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
#                                        [--name NAME] [--env VAR]... [--dry-run] -- <cmd...>
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
#                         sandbox — used when re-invoking loop.sh itself inside the container
#   --mount HOST[:CONTAINER]  (run) ALSO bind-mount HOST read-write at CONTAINER (default: same
#                         path as HOST) — repeatable. Opt-in only: use it for a specific agent
#                         CLI's auth/config dir (e.g. --mount ~/.copilot); mounting your whole
#                         $HOME defeats the sandbox's isolation value, so wgm never does that by
#                         default (see references/devcontainers.md).
#   --name NAME           (run) container name (default: let the engine auto-generate one)
#   --env VAR             (run) forward the host's $VAR into the container by name (repeatable).
#                         Never bakes a value into the image — passed at run time only.
#   --dry-run             print the command(s) that WOULD run; do nothing
#   -h | --help           show this help
#
# Safety:
#   * Never bakes secrets/credentials into the shared image — only --env/--mount-forwarded at run
#     time.
#   * Rootless-friendly: runs as the CALLING host user's UID:GID (not the image's baked UID 1000),
#     so bind-mounted files keep their real host permissions; adds Podman's --userns=keep-id too
#     (rootless Podman otherwise remaps the caller to a different apparent UID — Docker needs no
#     such flag). See Containerfile.template for the image's own baked non-root user.
#   * `run` always binds only the current directory + optional --skill-dir/--mount, never wider.
#   * `prune` only ever touches resources carrying the wgm.devcontainer=1 label.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$HERE/../assets/devcontainer"
LABEL="wgm.devcontainer=1"
DEFAULT_TAG="localhost/wgm-devcontainer-base:latest"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

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
    --mount) [[ $# -ge 2 ]] || { echo "--mount requires HOST[:CONTAINER]" >&2; exit 2; }; EXTRA_MOUNTS+=("$2"); shift 2 ;;
    --name) [[ $# -ge 2 ]] || { echo "--name requires a value" >&2; exit 2; }; NAME="$2"; shift 2 ;;
    --env) [[ $# -ge 2 ]] || { echo "--env requires a variable name" >&2; exit 2; }; ENV_VARS+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; CMD_ARGV=("$@"); break ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *) echo "Unexpected argument: $1" >&2; exit 2 ;;
  esac
done

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
cmd_run() {
  [[ ${#CMD_ARGV[@]} -ge 1 ]] || { echo "run requires a command after --. See --help." >&2; exit 2; }

  local -a mount_args=(-v "$(pwd):/workspace:rw")
  if [[ -n "$SKILL_DIR" ]]; then
    [[ -d "$SKILL_DIR" ]] || { echo "--skill-dir not found: $SKILL_DIR" >&2; exit 2; }
    mount_args+=(-v "$(cd "$SKILL_DIR" && pwd):/opt/wgm-skill:ro")
  fi
  if [[ -f "$HOME/.gitconfig" ]]; then
    mount_args+=(-v "$HOME/.gitconfig:/home/wgm/.gitconfig:ro")
  fi
  for m in "${EXTRA_MOUNTS[@]}"; do
    local host_path="${m%%:*}" container_path="${m#*:}"
    [[ "$container_path" == "$m" ]] && container_path="$host_path"   # no ":CONTAINER" given
    [[ -e "$host_path" ]] || { echo "--mount source not found: $host_path" >&2; exit 2; }
    mount_args+=(-v "$(cd "$(dirname "$host_path")" && pwd)/$(basename "$host_path"):${container_path}:rw")
  done
  # Best-effort: bring an already-installed agent CLI in via the host's npm global prefix, mounted
  # read-only at the same path so PATH resolution matches. Native addons in that CLI may still not
  # work across a different base distro — this is a convenience, not a guarantee (see
  # references/devcontainers.md).
  local npm_prefix=""
  npm_prefix="$(command -v npm >/dev/null 2>&1 && npm config get prefix 2>/dev/null || true)"
  # Every container this launches IS, by definition, a wgm devcontainer sandbox — set this
  # unconditionally so anything running inside (e.g. a re-exec'd loop.sh --devcontainer) can detect
  # it's already sandboxed and never try to nest another container from within this one.
  local -a env_args=(-e "WGM_IN_DEVCONTAINER=1")
  if [[ -n "$npm_prefix" && -d "$npm_prefix" ]]; then
    mount_args+=(-v "${npm_prefix}:${npm_prefix}:ro")
    env_args+=(-e "PATH=${npm_prefix}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
  fi
  for v in "${ENV_VARS[@]}"; do
    env_args+=(-e "${v}=${!v-}")
  done

  local -a name_args=()
  [[ -n "$NAME" ]] && name_args=(--name "$NAME")

  # Run as the CALLING host user's UID:GID (not the image's baked "wgm" UID 1000) so bind-mounted
  # files/dirs keep their real host permissions inside the sandbox — otherwise a mode-0700 project
  # dir (e.g. from `mktemp -d`, or simply not world-readable) is unreadable to a mismatched UID.
  # Rootless Podman additionally user-namespaces the caller to a *different* apparent UID inside the
  # container by default, so --userns=keep-id is required there too; plain Docker needs no such flag
  # (no remapping happens unless the operator has opted into userns-remap themselves).
  local -a userns_args=(--user "$(id -u):$(id -g)")
  [[ "$CONTAINER" == "podman" ]] && userns_args+=(--userns=keep-id)

  local need_build=0
  if [[ "$DRY_RUN" -eq 0 ]] && ! image_exists; then need_build=1; fi

  local run_cmd=("$CONTAINER" run --rm --label "$LABEL" "${userns_args[@]}" "${name_args[@]}" "${mount_args[@]}" "${env_args[@]}" -w /workspace "$TAG" "${CMD_ARGV[@]}")
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "== wgm devcontainer run (dry run) =="
    echo "container=${CONTAINER} tag=${TAG} skill_dir=${SKILL_DIR:-none} env=${ENV_VARS[*]:-none} extra_mounts=${#EXTRA_MOUNTS[@]}"
    if ! image_exists 2>/dev/null; then echo "(would build-base first — $TAG not found locally)"; fi
    echo "${run_cmd[*]}"
    return 0
  fi
  if [[ "$need_build" -eq 1 ]]; then
    echo "Image $TAG not found locally — building it once (subsequent runs reuse it)..." >&2
    cmd_build_base
  fi
  "${run_cmd[@]}"
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
