#!/usr/bin/env bash
#
# wgm/test-devcontainer.sh — deterministic backpressure for scripts/devcontainer.sh.
#
# Exercises init/build-base/run/prune against a REAL podman or docker engine when one is available —
# a dry-run-only harness would only prove the flags parse, not that a command actually executes
# sandboxed (the same "de-risk an unusual runtime" principle as references/ralph-loop.md). Uses a
# dedicated test tag (never the default shared tag) so this harness never touches or rebuilds an
# operator's real cached image. Gracefully skips the real-engine cases (with a note) when neither
# podman nor docker is installed — the flag-parsing/scaffolding cases still run everywhere.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DC="$ROOT/scripts/devcontainer.sh"
CONTAINERFILE="$ROOT/assets/devcontainer/Containerfile.template"
QUALIFIED_BASE="docker.io/library/debian:bookworm-slim"
TEST_TAG="localhost/wgm-devcontainer-base-test:latest"

FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

ENGINE=""
if command -v podman >/dev/null 2>&1; then ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then ENGINE="docker"
fi

TMP="$(mktemp -d)"
# Isolate the caller's HOME and config (throwaway); only XDG_DATA_HOME stays real so rootless Podman finds its image store.
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/cfg"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
trap '
  cd /
  if [[ -n "$ENGINE" ]]; then
    "$ENGINE" ps -a --filter "label=wgm.devcontainer=1" --filter "ancestor=$TEST_TAG" --format "{{.ID}}" 2>/dev/null \
      | xargs -r "$ENGINE" rm -f >/dev/null 2>&1 || true
    "$ENGINE" rmi -f "$TEST_TAG" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
' EXIT

cd "$TMP"

OUT=""; RC=0
run() {  # invoke devcontainer.sh, capturing combined output + exit code without tripping set -e
  set +e
  OUT="$("$DC" "$@" 2>&1)"; RC=$?
  set -e
}

# 1) --help shows usage
run --help
if [[ "$RC" -eq 0 ]] && grep -q "wgm/devcontainer.sh" <<<"$OUT"; then
  pass "--help shows usage"
else
  fail "--help did not show usage (rc=$RC)"
fi

# 2) an unknown subcommand is rejected
run frobnicate
if [[ "$RC" -eq 2 ]] && grep -q "Unknown subcommand" <<<"$OUT"; then
  pass "unknown subcommand is rejected"
else
  fail "unknown subcommand not rejected (rc=$RC)"
fi

# 3) init --dry-run creates nothing
run init --dry-run
if [[ "$RC" -eq 0 ]] && grep -q "would create" <<<"$OUT" && [[ ! -e .devcontainer/devcontainer.json ]]; then
  pass "init --dry-run creates nothing"
else
  fail "init --dry-run misbehaved (rc=$RC)"
fi

# 4) init scaffolds devcontainer.json referencing the shared image
run init
if [[ "$RC" -eq 0 ]] && [[ -f .devcontainer/devcontainer.json ]] \
   && grep -q "localhost/wgm-devcontainer-base:latest" .devcontainer/devcontainer.json; then
  pass "init scaffolds devcontainer.json referencing the shared image"
else
  fail "init did not scaffold devcontainer.json correctly (rc=$RC)"
fi

# 5) init refuses to clobber an existing devcontainer.json
run init
if [[ "$RC" -eq 1 ]] && grep -q "Refusing to overwrite" <<<"$OUT"; then
  pass "init refuses to clobber an existing devcontainer.json"
else
  fail "init did not refuse to clobber (rc=$RC)"
fi
rm -rf .devcontainer

# 6) an invalid --container value is rejected
run init --container bogus --dry-run
if [[ "$RC" -eq 2 ]] && grep -q "Invalid --container" <<<"$OUT"; then
  pass "an invalid --container value is rejected"
else
  fail "invalid --container not rejected (rc=$RC)"
fi

# 7) the template names Docker Hub explicitly; checking before the build prevents a cached base
# image or host short-name alias from hiding a source regression.
qualified_from_count=0
from_count=0
if [[ -f "$CONTAINERFILE" ]]; then
  qualified_from_count="$(grep -Fxc "FROM $QUALIFIED_BASE" "$CONTAINERFILE" || true)"
  from_count="$(grep -Ec '^FROM[[:space:]]+' "$CONTAINERFILE" || true)"
fi
if [[ "$qualified_from_count" == "1" ]] && [[ "$from_count" == "1" ]]; then
  pass "Containerfile uses exactly one qualified Docker Hub base source"
else
  fail "Containerfile must contain exactly 'FROM $QUALIFIED_BASE' as its only base source"
fi

if [[ -z "$ENGINE" ]]; then
  echo "skip: no podman/docker found on PATH — skipping real build-base/run/prune cases"
else
  # 8) run without a trailing command after -- is rejected
  run run --container "$ENGINE"
  if [[ "$RC" -eq 2 ]] && grep -qi "requires a command" <<<"$OUT"; then
    pass "run without a trailing command is rejected"
  else
    fail "run without a command not rejected (rc=$RC)"
  fi

  # 9) build-base --dry-run prints the plan without building
  run build-base --container "$ENGINE" --tag "$TEST_TAG" --dry-run
  if [[ "$RC" -eq 0 ]] && grep -q "${ENGINE} build" <<<"$OUT" && ! "$ENGINE" image inspect "$TEST_TAG" >/dev/null 2>&1; then
    pass "build-base --dry-run prints the plan without building"
  else
    fail "build-base --dry-run misbehaved (rc=$RC)"
  fi

  # 10) build-base actually builds the (dedicated, test-only) tagged image
  run build-base --container "$ENGINE" --tag "$TEST_TAG"
  if [[ "$RC" -eq 0 ]] && "$ENGINE" image inspect "$TEST_TAG" >/dev/null 2>&1; then
    pass "build-base builds the test-tagged image"
  else
    fail "build-base did not produce $TEST_TAG (rc=$RC): $OUT"
  fi

  # 11) build-base is idempotent: a second call skips the rebuild
  run build-base --container "$ENGINE" --tag "$TEST_TAG"
  if [[ "$RC" -eq 0 ]] && grep -q "already built" <<<"$OUT"; then
    pass "build-base skips an unnecessary rebuild"
  else
    fail "build-base did not skip the rebuild (rc=$RC)"
  fi

  # 12) Preserve the caller's numeric identity and writable mount, not the image's username.
  echo "marker-file-contents" > proof.txt
  run run --container "$ENGINE" --tag "$TEST_TAG" -- sh -c '
    printf "uid="; id -u
    printf "gid="; id -g
    cat /workspace/proof.txt
    printf "sandbox-write\n" > /workspace/written.txt'
  if [[ "$RC" -eq 0 ]] && grep -Fxq "uid=$(id -u)" <<<"$OUT" && grep -Fxq "gid=$(id -g)" <<<"$OUT" \
     && grep -Fxq "marker-file-contents" <<<"$OUT" \
     && [[ -O written.txt && -G written.txt ]] && grep -Fxq "sandbox-write" written.txt; then
    pass "run preserves host UID:GID and a writable workspace bind-mount"
  else
    fail "run did not preserve host UID:GID and writable mount (expected=$(id -u):$(id -g), rc=$RC): $OUT"
  fi

  # 13) run propagates the sandboxed command's own exit code
  set +e
  "$DC" run --container "$ENGINE" --tag "$TEST_TAG" -- sh -c 'exit 7'
  inner_rc=$?
  set -e
  if [[ "$inner_rc" -eq 7 ]]; then
    pass "run propagates the sandboxed command's exit code"
  else
    fail "run did not propagate exit code 7 (got $inner_rc)"
  fi

  # 14) run --dry-run shows the assembled command without executing it
  run run --container "$ENGINE" --tag "$TEST_TAG" --dry-run -- echo should-not-run
  if [[ "$RC" -eq 0 ]] && grep -q "${ENGINE} run" <<<"$OUT" && grep -q "$TEST_TAG" <<<"$OUT"; then
    pass "run --dry-run shows the assembled command without executing"
  else
    fail "run --dry-run misbehaved (rc=$RC)"
  fi

  # 15) prune --dry-run reports disk usage without removing anything
  run prune --container "$ENGINE" --dry-run
  if [[ "$RC" -eq 0 ]] && grep -qi "disk usage" <<<"$OUT"; then
    pass "prune --dry-run reports disk usage without removing anything"
  else
    fail "prune --dry-run misbehaved (rc=$RC)"
  fi

  # 16) prune actually removes a labeled STOPPED container (created directly, bypassing --rm)
  "$ENGINE" run --label wgm.devcontainer=1 --name wgm-test-prune-target "$TEST_TAG" true >/dev/null 2>&1 || true
  run prune --container "$ENGINE"
  still_there="$("$ENGINE" ps -a --filter "name=wgm-test-prune-target" --format '{{.ID}}' 2>/dev/null || true)"
  if [[ "$RC" -eq 0 ]] && [[ -z "$still_there" ]]; then
    pass "prune removes a labeled stopped container"
  else
    fail "prune did not remove the labeled stopped container (rc=$RC)"
  fi

  # 17) prune never touches a container from an UNRELATED image (safety invariant: label-scoped
  # removal only — note the shared base image's own Containerfile LABEL means every container
  # derived from *that* image is fair game for prune, by design; the real safety boundary this
  # checks is that prune never reaches into a container from a totally different image).
  "$ENGINE" tag docker.io/library/debian:bookworm-slim "localhost/wgm-test-unrelated:latest" >/dev/null 2>&1
  "$ENGINE" run --name wgm-test-unrelated-sentinel "localhost/wgm-test-unrelated:latest" true >/dev/null 2>&1 || true
  run prune --container "$ENGINE"
  sentinel_still_there="$("$ENGINE" ps -a --filter "name=wgm-test-unrelated-sentinel" --format '{{.ID}}' 2>/dev/null || true)"
  if [[ -n "$sentinel_still_there" ]]; then
    pass "prune leaves a container from an unrelated image untouched"
  else
    fail "prune removed a container it should never have touched (label-scoping regression)"
  fi
  "$ENGINE" rm -f wgm-test-unrelated-sentinel >/dev/null 2>&1 || true
  "$ENGINE" rmi "localhost/wgm-test-unrelated:latest" >/dev/null 2>&1 || true

  # ---- run --same-path: the sandbox boundary loop.sh uses -----------------------------------------
  SP="$TMP/same-path-project"
  mkdir -p "$SP" && ( cd "$SP" && git init -q . && git config user.name "Sandbox Tester" && git config user.email tester@example.com \
    && echo tracked > f && git add f && git -c core.hooksPath=/dev/null commit -qm seed )
  sprun() { set +e; OUT="$(cd "$SP" && "$DC" run --same-path --container "$ENGINE" --tag "$TEST_TAG" "$@" 2>&1)"; RC=$?; set -e; }

  # 18) the project is bind-mounted rw at its OWN absolute path (the working dir), the commit identity
  # travels as GIT_* env (no ~/.gitconfig mount), and git auto-gc is disabled
# shellcheck disable=SC2016  # the command runs inside the container: expansion happens there
  sprun -- sh -c 'pwd; printf "name=%s\n" "$GIT_AUTHOR_NAME"; printf "home=%s\n" "$HOME"; echo from-container > written.txt; git config --get gc.auto'
  if [[ "$RC" -eq 0 ]] && grep -Fxq "$SP" <<<"$OUT" && grep -Fxq "name=Sandbox Tester" <<<"$OUT" && grep -Fxq "home=/home/wgm" <<<"$OUT" \
     && grep -Fxq "0" <<<"$OUT" && grep -Fxq "from-container" "$SP/written.txt"; then
    pass "run --same-path mounts the project rw at its own path with the host git identity and gc disabled"
  else
    fail "run --same-path misbehaved (rc=$RC): $OUT"
  fi

  # 19) a read-only overlay protects the git hooks inside while the project stays writable
  sprun --overlay-mount "$SP/.git/hooks" -- sh -c 'touch .git/hooks/x 2>&1; echo "rc=$?"; echo ok > fine.txt'
  if grep -q "Read-only file system" <<<"$OUT" && [[ ! -e "$SP/.git/hooks/x" ]] && [[ -f "$SP/fine.txt" ]]; then
    pass "an --overlay-mount makes the git hooks read-only inside the container"
  else
    fail "read-only overlay did not hold (rc=$RC): $OUT"
  fi

  # 20) binds are NON-RECURSIVE and --env forwards by NAME only (value never on the command line)
  sprun --dry-run --env WGM_TEST_SECRET -- true
  if grep -Eq 'bind-nonrecursive=true|bind-recursive=disabled' <<<"$OUT"; then
    pass "every same-path bind is non-recursive"
  else
    fail "binds are not non-recursive: $OUT"
  fi
  set +e; OUT="$(cd "$SP" && WGM_TEST_SECRET=top-secret-value "$DC" run --same-path --container "$ENGINE" --tag "$TEST_TAG" --dry-run --env WGM_TEST_SECRET -- true 2>&1)"; set -e
  if grep -q -- '--env WGM_TEST_SECRET' <<<"$OUT" && ! grep -q 'top-secret-value' <<<"$OUT"; then
    pass "--env forwards by name only: the value is not on the engine command line"
  else
    fail "--env leaked the value or dropped the name: $OUT"
  fi
  set +e
  # shellcheck disable=SC2016  # the command runs inside the container: expansion happens there
  OUT="$(cd "$SP" && WGM_TEST_SECRET=top-secret-value "$DC" run --same-path --container "$ENGINE" --tag "$TEST_TAG" --env WGM_TEST_SECRET -- sh -c 'echo "$WGM_TEST_SECRET"' 2>&1)"
  set -e
  if grep -Fxq "top-secret-value" <<<"$OUT"; then pass "a name-only --env still reaches the command inside"; else fail "name-only --env value missing inside: $OUT"; fi

  # 21) mount policy: $HOME, runtime trees, sockets and duplicate destinations are refused (exit 2)
  mkdir -p "$TMP/sockdir" && python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$TMP/sockdir/s"
  mkdir -p "$TMP/other1" "$TMP/other2"
  refused=0
  for spec in "$HOME" /run "$TMP/sockdir" "$TMP/sockdir/s"; do
    sprun --mount "$spec:$spec:ro" -- true
    if [[ "$RC" -eq 2 ]]; then refused=$((refused + 1)); else echo "not refused: $spec (rc=$RC) $OUT" >&2; fi
  done
  sprun --mount "$TMP/other1:/dup:ro" --mount "$TMP/other2:/dup:ro" -- true
  [[ "$RC" -eq 2 ]] && refused=$((refused + 1))
  if [[ "$refused" -eq 5 ]]; then pass "mount policy refuses \$HOME, a runtime tree, a socket (and its directory) and a duplicate destination"; else fail "mount policy refused only $refused of 5"; fi

  # 22) a hard-linked file inside a WRITABLE project tree is refused (it could alias a file outside every mount)
  ln "$SP/f" "$SP/f.hardlink"
  sprun -- true
  if [[ "$RC" -eq 2 ]] && grep -q "hard link" <<<"$OUT"; then pass "a hard-linked file in the writable project is refused"; else fail "hard link accepted (rc=$RC): $OUT"; fi
  rm -f "$SP/f.hardlink"

  # 23) a private --copy-mount is writable inside and the host original is untouched
  mkdir -p "$TMP/copy-src" && echo original > "$TMP/copy-src/token"
  sprun --copy-mount "$TMP/copy-src:/home/wgm/.cred" -- sh -c 'echo refreshed >> /home/wgm/.cred/token; cat /home/wgm/.cred/token'
  if [[ "$RC" -eq 0 ]] && grep -Fxq "refreshed" <<<"$OUT"; then pass "--copy-mount binds the (throwaway) copy read-write"; else fail "--copy-mount failed (rc=$RC): $OUT"; fi

  # 24) the git CONFIG (not only hooks) is immutable inside under a read-only overlay
  sprun --overlay-mount "$SP/.git/config" -- sh -c 'echo "[x] y=1" >> .git/config 2>&1; echo "rc=$?"; git config --get core.bare'
  if grep -q "Read-only file system" <<<"$OUT" && ! grep -q '^\[x\]' "$SP/.git/config"; then pass "an --overlay-mount makes .git/config read-only inside the container"; else fail "config overlay did not hold (rc=$RC): $OUT"; fi

  # 25) launcher-wide mount policy: with --same-path every extra --mount is READ-ONLY (rw refused); the common git dir
  # has its own distinguished --git-common-mount allowance
  sprun --mount "$TMP/other1:/other:rw" -- true
  rc25=$RC; ok25=0; grep -q "read-only" <<<"$OUT" && ok25=1
  sprun --git-common-mount "$SP/.git" -- sh -c 'echo ok > .git/wgm-write-probe && echo written'
  if [[ "$rc25" -eq 2 && "$ok25" -eq 1 && "$RC" -eq 0 ]] && grep -Fxq written <<<"$OUT"; then pass "run --same-path refuses an rw extra --mount; --git-common-mount is the one writable allowance"; else fail "mount policy rw/common (rc25=$rc25 ok25=$ok25 rc=$RC): $OUT"; fi
  rm -f "$SP/.git/wgm-write-probe"

  # 25b) ONE overlap policy: an extra --mount may not equal/contain/lie inside the project (or another mount)
  echo f > "$SP/inner.txt"; mkdir -p "$TMP/nest/inner"
  sprun --mount "$SP/inner.txt:/other:ro" -- true; o1=$RC
  sprun --mount "$TMP:/parent:ro" -- true; o2=$RC
  sprun --mount "$TMP/nest:/n1:ro" --mount "$TMP/nest/inner:/n2:ro" -- true; o3=$RC
  sprun --overlay-mount "$SP/.git/config" -- true; o4=$RC
  if [[ "$o1" -eq 2 && "$o2" -eq 2 && "$o3" -eq 2 && "$o4" -eq 0 ]]; then pass "extra mounts overlapping the project, a parent of it or each other are refused; the D3 overlay flag is the exception"; else fail "overlap policy ($o1/$o2/$o3/$o4)"; fi

  # 27) DIRECT use verifies/binds its tools before the first external command: a project bin/ first on PATH (engine,
  # grep and head wrappers touching a HOST sentinel) never runs
  mkdir -p "$SP/bin"; rm -f "$TMP/dc-pwned"
  for t in "$ENGINE" grep head; do
    real="$(command -v "$t")"
    printf '#!/usr/bin/env bash\ntouch "%s/dc-pwned"\nexec "%s" "$@"\n' "$TMP" "$real" > "$SP/bin/$t"; chmod +x "$SP/bin/$t"
  done
  mkdir -p "$TMP/dc-tmp"   # a PRIVATE TMPDIR for this case: leaks of other (possibly killed) runs cannot interfere
  set +e; OUT="$(cd "$SP" && TMPDIR="$TMP/dc-tmp" PATH="$SP/bin:$PATH" "$DC" run --same-path --container "$ENGINE" --tag "$TEST_TAG" -- sh -c 'echo ran-inside' 2>&1)"; RC=$?; set -e
  if [[ "$RC" -eq 0 && ! -e "$TMP/dc-pwned" ]] && grep -Fxq ran-inside <<<"$OUT" && ! compgen -G "$TMP/dc-tmp/wgm-bin.*" >/dev/null; then
    pass "direct 'run --same-path' with a project bin/ (engine/grep/head wrappers) first on PATH runs verified tools only; the bound-tools dir is cleaned up"
  else fail "direct run used a project wrapper or leaked (rc=$RC, sentinel=$([[ -e $TMP/dc-pwned ]] && echo yes || echo no)): $OUT"; fi
  rm -rf "${SP:?}/bin"

  # 26b) a duplicate DESTINATION is refused on EVERY mount kind (here: a repeated --git-common-mount, a repeated overlay)
  sprun --git-common-mount "$SP/.git" --git-common-mount "$SP/.git" -- true; d1=$RC; grep -q "same container path" <<<"$OUT" && d1m=1 || d1m=0
  sprun --overlay-mount "$SP/.git/config" --overlay-mount "$SP/.git/config" -- true; d2=$RC; grep -q "same container path" <<<"$OUT" && d2m=1 || d2m=0
  sprun --git-common-mount "$SP/.git" -- true; d3=$RC
  if [[ "$d1" -eq 2 && "$d1m" -eq 1 && "$d2" -eq 2 && "$d2m" -eq 1 && "$d3" -eq 0 ]]; then pass "a duplicate destination is refused (exit 2, named) for repeated git-common and overlay mounts; a single one passes"; else fail "duplicate destinations ($d1/$d1m $d2/$d2m $d3)"; fi

  # 28) the VALUE filter on the DIRECT entry path: engine/config variables pointing INTO the project are dropped and
  # reported before the engine runs (a CONTAINERS_CONF pointing at a project file would otherwise break/steer the engine)
  mkdir -p "$SP/dcfg"; printf '[bogus\n' > "$SP/containers.conf"
  set +e; OUT="$(cd "$SP" && DOCKER_CONFIG="$SP/dcfg" CONTAINERS_CONF="$SP/containers.conf" "$DC" run --same-path --container "$ENGINE" --tag "$TEST_TAG" -- sh -c 'echo ran-inside' 2>&1)"; RC=$?; set -e
  if [[ "$RC" -eq 0 ]] && grep -q "dropped DOCKER_CONFIG" <<<"$OUT" && grep -q "dropped CONTAINERS_CONF" <<<"$OUT" && grep -Fxq ran-inside <<<"$OUT"; then
    pass "direct 'run --same-path' drops and reports DOCKER_CONFIG/CONTAINERS_CONF values pointing into the project before the engine runs"
  else fail "direct run did not filter engine variables (rc=$RC): $OUT"; fi
  rm -rf "${SP:?}/dcfg" "$SP/containers.conf"

  # 26) ONE destination per CANONICAL source: the same source (or a symlink alias) at two destinations is refused
  ln -sfn "$TMP/other1" "$TMP/other1-alias"
  sprun --mount "$TMP/other1:/a" --mount "$TMP/other1:/b" -- true; r1=$RC
  sprun --mount "$TMP/other1:/a" --mount "$TMP/other1-alias:/b" -- true; r2=$RC
  sprun --mount "$TMP/other1:/a" -- true; r3=$RC
  if [[ "$r1" -eq 2 && "$r2" -eq 2 && "$r3" -eq 0 ]]; then pass "the same canonical source (or alias) at two destinations is refused; one mount passes"; else fail "one-destination-per-source ($r1/$r2/$r3)"; fi
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "devcontainer harness: GREEN"
  exit 0
else
  echo "devcontainer harness: RED" >&2
  exit 1
fi
