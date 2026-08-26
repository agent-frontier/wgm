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

  # 12) run actually executes inside the sandbox: proves the bind-mount + non-root user
  echo "marker-file-contents" > proof.txt
  run run --container "$ENGINE" --tag "$TEST_TAG" -- sh -c 'whoami; cat /workspace/proof.txt'
  if [[ "$RC" -eq 0 ]] && grep -q "^wgm$" <<<"$OUT" && grep -q "marker-file-contents" <<<"$OUT"; then
    pass "run executes the command sandboxed with the workspace bind-mounted"
  else
    fail "run did not execute correctly inside the sandbox (rc=$RC): $OUT"
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
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "devcontainer harness: GREEN"
  exit 0
else
  echo "devcontainer harness: RED" >&2
  exit 1
fi
