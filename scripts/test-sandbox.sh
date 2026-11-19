#!/usr/bin/env bash
#
# wgm/test-sandbox.sh — deterministic backpressure for scripts/sandbox.sh and the sandboxed loop.sh.
#
# Covers every decision-order branch of `sandbox.sh preflight`, every mount-policy refusal, the
# operator-owned record, the decision-file hand-off, the host-trusts-nothing rules (safe writes,
# git pointer/config pinning, env allowlist, plumbing-only host git) and the container lifecycle.
# Most cases use STUB engines on PATH (a stub `podman`/`docker` that logs argv and runs the command
# natively); the credential-copy / readiness / commit cases use a REAL engine when one exists and
# print a visible "skip: no container engine" otherwise. Everything runs against a throwaway HOME
# AND a throwaway XDG_CONFIG_HOME (approvals are written there); only XDG_DATA_HOME stays real so
# rootless Podman still finds its image store. No network, no model, no real credentials.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$ROOT/scripts/sandbox.sh"
LOOP="$ROOT/scripts/loop.sh"
DC="$ROOT/scripts/devcontainer.sh"
TEST_TAG="localhost/wgm-devcontainer-base-sandbox-test:latest"

FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

unset WGM_DEVCONTAINER WGM_IN_DEVCONTAINER WGM_SANDBOX_DECISION WGM_SANDBOX_DECISION_OWNED \
      WGM_HOST_ENV_CLEAN WGM_TRUSTED_RUNNER WGM_TRUSTED_RUNNER_OWNED WGM_DEVCONTAINER_IMAGE WGM_AGENT \
      WGM_FRUGAL_AGENT WGM_MOUNTINFO WGM_DEBUG_HOST_ENV 2>/dev/null || true

# ISOLATION FIRST — before ANY engine or tool call: a throwaway HOME / XDG_CONFIG_HOME / TMPDIR so nothing (not even the
# engine probe below) reads or writes the operator's real config; only XDG_DATA_HOME stays real (rootless engine storage).
REAL_HOME="$HOME"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$REAL_HOME/.local/share}"
REAL_PATH="$PATH"
REAL_GIT="$(command -v git)"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/cfg" TMPDIR="$TMP/tmp"
mkdir -p "$HOME" "$TMPDIR" "$TMP/cfg"

ENGINE=""
if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then ENGINE="podman"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then ENGINE="docker"
fi
# shellcheck disable=SC2317,SC2329  # invoked indirectly (EXIT trap)
cleanup() {
  cd /
  # a fixture may have left a user-namespace-chowned (foreign-owned) file behind: map it back to us before removing TMP
  if [[ -n "${CHOWN51:-}" ]]; then PATH="$REAL_PATH" podman unshare chown -R 0:0 "$TMP" >/dev/null 2>&1 || true; fi
  chmod -R u+rwx "$TMP" 2>/dev/null || true
  if [[ -n "$ENGINE" ]]; then
    "$ENGINE" ps -a --filter "label=wgm.devcontainer=1" --filter "ancestor=$TEST_TAG" --format '{{.ID}}' 2>/dev/null \
      | xargs -r "$ENGINE" rm -f >/dev/null 2>&1 || true
    "$ENGINE" rmi -f "$TEST_TAG" >/dev/null 2>&1 || true
    if [[ -n "${UNREL:-}" ]]; then "$ENGINE" rm -f -t 0 "$UNREL" >/dev/null 2>&1 || true; fi
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---- stub engines: log argv, answer info/ps/rm, run the command natively (no isolation) ---------
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/podman" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "${WGM_STUB_TRACE:-/dev/null}"
case "${1:-}" in
  --version) [[ "$(basename "$0")" == docker ]] && echo "Docker version 29.8.0" || echo "podman version 4.9.3"; exit 0 ;;
  info) [[ "${WGM_STUB_INFO_FAIL:-0}" == 1 ]] && exit 1
        [[ "$(basename "$0")" == podman && "${WGM_STUB_PODMAN_FAIL:-0}" == 1 ]] && exit 1
        exit 0 ;;
  image) exit 0 ;;
  ps) [[ "${WGM_STUB_PS_HANG:-0}" == 1 ]] && sleep 25
      [[ "${WGM_STUB_PS_FAIL:-0}" == 1 ]] && exit 1
      [[ -f "${WGM_STUB_LIVE:-/nonexistent}" ]] && cat "$WGM_STUB_LIVE"; exit 0 ;;
  rm) [[ "${WGM_STUB_RM_HANG:-0}" == 1 ]] && sleep 25
      [[ "${WGM_STUB_RM_FAIL:-0}" == 1 ]] && exit 1
      n="${*: -1}"
      if [[ -f "${WGM_STUB_LIVE:-/nonexistent}" ]]; then grep -vFx "$n" "$WGM_STUB_LIVE" > "$WGM_STUB_LIVE.n" || true; mv "$WGM_STUB_LIVE.n" "$WGM_STUB_LIVE"; fi
      exit 0 ;;
  run) shift ;;
  *) exit 0 ;;
esac
name=""; wd=""; envs=()
while (( $# )); do
  case "$1" in
    --rm|--init|-i|--userns=*) shift ;;
    --label|--user|--mount) shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --env|-e) envs+=("$2"); shift 2 ;;
    -w) wd="$2"; shift 2 ;;
    *) break ;;
  esac
done
shift  # the image tag
for e in "${envs[@]}"; do
  if [[ "$e" == PATH=* ]]; then export PATH="$PATH:${e#PATH=}"   # the stub has no image: keep host tools reachable
  elif [[ "$e" == *=* ]]; then export "$e"; fi
done
cd "$wd"
if [[ "${WGM_STUB_LATE:-0}" == 1 && "$*" == *touch*WGM_TEST_MARK* ]]; then
  # late launch: the "container" only comes into existence AFTER the loop was told to stop
  trap '[[ -n "${WGM_STUB_LIVE:-}" ]] && echo "$name" >> "$WGM_STUB_LIVE"; exit 143' TERM
  sleep 30 & wait $!
  exit 0
fi
[[ -n "${WGM_STUB_LIVE:-}" ]] && echo "$name" >> "$WGM_STUB_LIVE"
"$@" <&0 &
child=$!
trap 'kill "$child" 2>/dev/null; exit 143' TERM
rc=0; wait "$child" || rc=$?
if [[ -n "${WGM_STUB_LIVE:-}" && -f "$WGM_STUB_LIVE" ]]; then grep -vFx "$name" "$WGM_STUB_LIVE" > "$WGM_STUB_LIVE.n" || true; mv "$WGM_STUB_LIVE.n" "$WGM_STUB_LIVE"; fi
exit "$rc"
EOF
chmod +x "$STUB/podman"; cp "$STUB/podman" "$STUB/docker"
STUBPATH="$STUB:$REAL_PATH"
export PATH="$STUBPATH"
export WGM_STUB_TRACE="$TMP/trace"; : > "$WGM_STUB_TRACE"

# ---- helpers ---------------------------------------------------------------------------------------
newproj() {  # newproj NAME → canonical path of a fresh git project with a plan
  local d="$TMP/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . && git config user.email t@example.com && git config user.name t \
    && printf '# plan\n\n- seed\n' > IMPLEMENTATION_PLAN.md && git add -A && git commit -qm seed )
  printf '%s' "$d/.git" | sha256sum | cut -c1-8 >> "$TMP/key8s"   # the container-name key of this project (and its worktrees)
  printf '%s' "$d"
}
# RUN-SPECIFIC container accounting (never a global `wgm-` filter: unrelated containers — or those of another operator
# loop/swarm — must neither fail a case nor be removed). Containers of THIS run are named wgm-<key8 of a test project>-…;
# the key8s of every project this harness created are recorded by newproj.
: > "$TMP/key8s"
my_containers() {  # my_containers [ENGINE] → names of this harness's containers
  local eng="${1:-$ENGINE}" re
  re="$(paste -sd'|' "$TMP/key8s")"; [[ -n "$re" ]] || return 0
  "$eng" ps -a --filter name=wgm- --format '{{.Names}}' 2>/dev/null | grep -E "^wgm-(${re})-" || true
}
my_container_count() { my_containers "$@" | wc -l; }
my_containers_rm() { local eng="${1:-$ENGINE}"; my_containers "$eng" | xargs -r "$eng" rm -f -t 0 >/dev/null 2>&1 || true; }
OUTO=""; ERR=""; RC=0
pf() {  # pf PROJECT ARGS… → OUTO (stdout), ERR (stderr), RC
  local d="$1"; shift
  set +e
  OUTO="$(cd "$d" && "$SB" preflight "$@" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
  set -e
}
has() { grep -Fq -- "$1" <<<"$2"; }
rec_of() { sed -n 's/^record=//p' <<<"$OUTO" | head -1; }
write_rec() {  # write_rec FILE agents env-names… (a headless-provisioned approval record)
  local f="$1" agents="$2"; shift 2
  mkdir -p "$(dirname "$f")"; chmod 700 "$(dirname "$f")"
  { echo "# wgm sandbox decisions — operator-owned; never inside a repository"
    echo "engine_declined: false"; echo "declined_at: "; echo "agents: $agents"; echo "image: "
    echo "tokens:"; echo "copies:"; echo "mounts:"; echo "env:"
    local n; for n in "$@"; do echo "  - $n"; done
  } > "$f"
  chmod 600 "$f"
}
pty() {  # pty 'answers' CMD → output with CRs stripped; the answers are typed into a pseudo-terminal
  local answers="$1" cmd="$2"
  set +e
  OUTO="$(script -qec "$cmd" /dev/null < <(printf '%b' "$answers"; sleep 4) 2>&1 | tr -d '\r')"; RC=$?
  set -e
}
mkstub() {  # mkstub PREFIX NAME BODY — an agent CLI at PREFIX/bin/NAME
  mkdir -p "$1/bin"; printf '#!/usr/bin/env bash\n%s\n' "$3" > "$1/bin/$2"; chmod +x "$1/bin/$2"
}

# ---- 1-3) decision order: inside, conflicts, opt-outs ----------------------------------------------
P="$(newproj p1)"
WGM_IN_DEVCONTAINER=1 pf "$P"
if [[ "$RC" -eq 0 ]] && has "sandbox=inside" "$OUTO"; then pass "step 1: WGM_IN_DEVCONTAINER → sandbox=inside"; else fail "inside not reported (rc=$RC): $OUTO"; fi

pf "$P" --devcontainer --no-devcontainer
if [[ "$RC" -eq 2 ]] && has "conflicting sandbox choices" "$ERR"; then pass "step 2: --devcontainer with --no-devcontainer → exit 2"; else fail "flag conflict not refused (rc=$RC)"; fi
WGM_DEVCONTAINER=0 pf "$P" --devcontainer
if [[ "$RC" -eq 2 ]] && has "conflicting sandbox choices" "$ERR"; then pass "step 2: --devcontainer against WGM_DEVCONTAINER=0 → exit 2"; else fail "flag/env conflict not refused (rc=$RC)"; fi
WGM_DEVCONTAINER=1 pf "$P" --no-devcontainer
if [[ "$RC" -eq 2 ]]; then pass "step 2: --no-devcontainer against WGM_DEVCONTAINER=1 → exit 2"; else fail "flag/env conflict (2) not refused (rc=$RC)"; fi

pf "$P" --no-devcontainer
if [[ "$RC" -eq 0 ]] && has "sandbox=off" "$OUTO" && has "reason=operator-flag" "$OUTO"; then pass "step 3: --no-devcontainer → off/operator-flag"; else fail "operator-flag (rc=$RC): $OUTO"; fi
WGM_DEVCONTAINER=0 pf "$P"
if [[ "$RC" -eq 0 ]] && has "reason=operator-env" "$OUTO"; then pass "step 3: WGM_DEVCONTAINER=0 → off/operator-env"; else fail "operator-env (rc=$RC): $OUTO"; fi

# ---- 4-6) engine detection, forced, recorded decline ------------------------------------------------
WGM_STUB_INFO_FAIL=1 pf "$P" --devcontainer
if [[ "$RC" -eq 2 ]]; then pass "step 4: forced sandbox without a working engine → exit 2"; else fail "forced without engine (rc=$RC)"; fi

WGM_STUB_INFO_FAIL=1 pf "$P"
if [[ "$RC" -eq 2 ]] && has "Install" "$ERR" && [[ ! -e "$XDG_CONFIG_HOME/wgm/sandbox" ]]; then
  pass "step 6: headless with no engine fails closed with install guidance and records nothing"
else fail "headless no-engine (rc=$RC, record dir exists? $([[ -e $XDG_CONFIG_HOME/wgm/sandbox ]] && echo yes || echo no)): $ERR"; fi

pty 'n\n' "cd '$P' && WGM_STUB_INFO_FAIL=1 '$SB' preflight --interactive yes"
if has "no decision recorded" "$OUTO" && ! has "recorded-decline" "$OUTO" && ! compgen -G "$XDG_CONFIG_HOME/wgm/sandbox/*.yml" >/dev/null; then pass "step 6: answering n refuses and records nothing"; else fail "n answer mishandled (rc=$RC)"; fi

pty 'y\n' "cd '$P' && WGM_STUB_INFO_FAIL=1 '$SB' preflight --interactive yes"
REC="$(compgen -G "$XDG_CONFIG_HOME/wgm/sandbox/*.yml" | head -1 || true)"
if has "reason=recorded-decline" "$OUTO" && [[ -n "$REC" ]] && grep -q '^engine_declined: true' "$REC" \
   && grep -Eq '^declined_at: [0-9]{4}-' "$REC" && [[ "$(stat -c %a "$REC")" == 600 ]] && [[ "$(stat -c %a "$(dirname "$REC")")" == 700 ]]; then
  pass "step 6: interactive y records the decline (0600 file in a 0700 dir)"
else fail "interactive decline not recorded (rc=$RC): $OUTO"; fi
WGM_STUB_INFO_FAIL=1 pf "$P"
if [[ "$RC" -eq 0 ]] && has "sandbox=off" "$OUTO" && has "reason=recorded-decline" "$OUTO"; then pass "a recorded decline is reused headless while no engine exists"; else fail "recorded decline not reused (rc=$RC)"; fi
WGM_STUB_INFO_FAIL=1 pf "$P" --devcontainer
if [[ "$RC" -eq 2 ]]; then pass "a recorded decline never turns a forced run off"; else fail "forced run turned off by the decline (rc=$RC)"; fi
pf "$P"
if [[ "$RC" -eq 0 ]] && has "sandbox=on" "$OUTO" && has "engine=podman" "$OUTO"; then pass "step 5: a detected engine always wins over a recorded decline"; else fail "engine did not win over decline (rc=$RC): $ERR"; fi

# ---- 8) the ON decision: mounts, overlays, image, record ---------------------------------------------
P="$(newproj p8)"
pf "$P" --agent-cmd bash
if [[ "$RC" -eq 0 ]] && has "layout=$P:$P:rw" "$OUTO" && has "layout=$P/.git/hooks:$P/.git/hooks:ro" "$OUTO" \
   && has "layout=$P/.git/config:$P/.git/config:ro" "$OUTO" && has "layout=$P/.git/info:$P/.git/info:ro" "$OUTO" \
   && has "layout=$P/.git/objects/info:$P/.git/objects/info:ro" "$OUTO" && has "layout=$P/.git/config.worktree:$P/.git/config.worktree:ro" "$OUTO" \
   && has "image=localhost/wgm-devcontainer-base:latest" "$OUTO" && has "agent=bash" "$OUTO" && has "record=$XDG_CONFIG_HOME/wgm/sandbox/" "$OUTO" \
   && [[ -f "$P/.git/config.worktree" ]]; then
  pass "ON decision reports the layout (derived per launch): project rw + read-only config/hooks/info/objects-info overlays (missing files created empty)"
else fail "ON decision wrong (rc=$RC): $OUTO / $ERR"; fi
if grep -q 'gitconfig' <<<"$OUTO"; then fail "the host gitconfig file must not be mounted"; else pass "no host gitconfig mount is proposed"; fi

WGM_STUB_PODMAN_FAIL=1 pf "$P" --agent-cmd bash
if [[ "$RC" -eq 0 ]] && has "engine=docker" "$OUTO"; then pass "a broken Podman falls back to a working Docker"; else fail "docker fallback (rc=$RC): $OUTO"; fi

# image precedence: flag > env > record > default (the record is provisioned by hand)
RECF="$(rec_of)"
write_rec "$RECF" ""; sed -i 's|^image: .*|image: rec/img:1|' "$RECF"
pf "$P" --agent-cmd bash; has "image=rec/img:1" "$OUTO" && a=1 || a=0
WGM_DEVCONTAINER_IMAGE=env/img:2 pf "$P" --agent-cmd bash; has "image=env/img:2" "$OUTO" && b=1 || b=0
pf "$P" --agent-cmd bash --devcontainer-image flag/img:3; has "image=flag/img:3" "$OUTO" && c=1 || c=0
if [[ "$a$b$c" == 111 ]]; then pass "image order: --devcontainer-image, WGM_DEVCONTAINER_IMAGE, record, shared base"; else fail "image precedence ($a$b$c)"; fi

# ---- record gates --------------------------------------------------------------------------------------
P="$(newproj p9)"
mkdir -p "$P/.wgm"; printf 'engine_declined: true\n' > "$P/.wgm/sandbox.yml"
WGM_STUB_INFO_FAIL=1 pf "$P"
if [[ "$RC" -eq 2 ]]; then pass "a repository-shipped .wgm/sandbox.yml has no effect"; else fail "project-shipped record honoured (rc=$RC)"; fi

pf "$P" --agent-cmd bash; RECF="$(rec_of)"
mkdir -p "$(dirname "$RECF")"; write_rec "$RECF" ""
chmod 664 "$RECF"
pf "$P" --agent-cmd bash
if [[ "$RC" -eq 2 ]] && has "group/world-writable" "$ERR"; then pass "a group-writable record is refused"; else fail "writable record accepted (rc=$RC): $ERR"; fi
chmod 600 "$RECF"; mv "$RECF" "$RECF.real"; ln -s "$RECF.real" "$RECF"
pf "$P" --agent-cmd bash
if [[ "$RC" -eq 2 ]] && has "symlink" "$ERR"; then pass "a symlinked record is refused"; else fail "symlink record accepted (rc=$RC): $ERR"; fi
rm -f "$RECF"; mv "$RECF.real" "$RECF"
printf 'this is not a record\n' > "$RECF"; chmod 600 "$RECF"
pf "$P" --agent-cmd bash
if [[ "$RC" -eq 0 ]] && has "malformed" "$ERR"; then pass "a malformed record is treated as absent with a message"; else fail "malformed record (rc=$RC): $ERR"; fi
WGM_STUB_INFO_FAIL=1 pf "$P"
if [[ "$RC" -eq 2 ]]; then pass "a malformed record never counts as a decline"; else fail "malformed record counted as decline (rc=$RC)"; fi

XDG_CONFIG_HOME="$P/cfgin" pf "$P" --agent-cmd bash
if [[ "$RC" -eq 2 ]] && has "record" "$ERR"; then pass "a record directory inside a mount is refused"; else fail "record dir inside the project accepted (rc=$RC): $ERR"; fi

# ---- dry run is non-mutating; credentials approval gate; agent-set union ----------------------------
mkstub "$TMP/stubs/claude" claude 'echo "claude stub 1.0"'
mkstub "$TMP/stubs/codex" codex 'echo "codex stub 1.0"'
P="$(newproj p10)"
rm -rf "$XDG_CONFIG_HOME/wgm"
ANTHROPIC_API_KEY=SENTINEL-VALUE-9f3 PATH="$TMP/stubs/claude/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd claude
if [[ "$RC" -eq 2 ]] && [[ ! -e "$XDG_CONFIG_HOME/wgm" ]] && [[ ! -e "$P/.git/config.worktree" ]]; then
  pass "--dry-run with an unresolved prerequisite fails without writing a record or overlays"
else fail "dry-run mutated or accepted (rc=$RC)"; fi
ANTHROPIC_API_KEY=SENTINEL-VALUE-9f3 PATH="$TMP/stubs/claude/bin:$STUBPATH" pf "$P" --agent-cmd claude
if [[ "$RC" -eq 2 ]] && has "approval" "$ERR"; then pass "unapproved credentials fail closed headless with guidance"; else fail "unapproved credentials (rc=$RC): $ERR"; fi

# T17 (decision part): an approved env NAME travels by name only
ANTHROPIC_API_KEY=SENTINEL-VALUE-9f3 PATH="$TMP/stubs/claude/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd bash
RECF="$(rec_of)"; write_rec "$RECF" "claude" ANTHROPIC_API_KEY
ANTHROPIC_API_KEY=SENTINEL-VALUE-9f3 PATH="$TMP/stubs/claude/bin:$STUBPATH" pf "$P" --agent-cmd claude
if [[ "$RC" -eq 0 ]] && has "env=ANTHROPIC_API_KEY" "$OUTO" && ! has "SENTINEL" "$OUTO" && has "mount=$TMP/stubs/claude:$TMP/stubs/claude:ro" "$OUTO" \
   && has "path=$TMP/stubs/claude/bin" "$OUTO"; then
  pass "an approved env NAME is reported by name only; the agent's install prefix is one ro mount"
else fail "env approval (rc=$RC): $OUTO / $ERR"; fi

# agent set (F1/T1 shape): a different set asks again; headless → exit 2; the union is approved as a set
ANTHROPIC_API_KEY=x PATH="$TMP/stubs/claude/bin:$TMP/stubs/codex/bin:$STUBPATH" pf "$P" --agent-cmd claude --agent-cmd codex
if [[ "$RC" -eq 2 ]] && has "agent set" "$ERR"; then pass "adding a frugal agent changes the approved set → exit 2 headless"; else fail "agent-set change accepted (rc=$RC): $ERR"; fi
write_rec "$RECF" "claude codex" ANTHROPIC_API_KEY
ANTHROPIC_API_KEY=x PATH="$TMP/stubs/claude/bin:$TMP/stubs/codex/bin:$STUBPATH" pf "$P" --agent-cmd claude --agent-cmd codex
if [[ "$RC" -eq 0 ]] && has "agent=claude" "$OUTO" && has "agent=codex" "$OUTO"; then pass "the approved agent SET (main + frugal) is accepted"; else fail "agent union (rc=$RC): $ERR"; fi
ANTHROPIC_API_KEY=x PATH="$TMP/stubs/claude/bin:$STUBPATH" pf "$P" --agent-cmd claude
if [[ "$RC" -eq 2 ]]; then pass "T1 recovery: removing an agent from the run asks again / exits 2 headless"; else fail "set shrink accepted (rc=$RC)"; fi
ANTHROPIC_API_KEY="" PATH="$TMP/stubs/claude/bin:$STUBPATH" pf "$P" --agent-cmd claude
write_rec "$RECF" "claude" ANTHROPIC_API_KEY
ANTHROPIC_API_KEY="" PATH="$TMP/stubs/claude/bin:$STUBPATH" pf "$P" --agent-cmd claude
if [[ "$RC" -eq 2 ]] && has "credential ANTHROPIC_API_KEY not reachable" "$ERR"; then pass "an approved env name that is empty is 'not reachable' (tier b)"; else fail "empty approved env (rc=$RC): $ERR"; fi

# ---- 18) mount policy ----------------------------------------------------------------------------------
P="$(newproj p18)"
X="$TMP/extra"; mkdir -p "$X"; echo data > "$X/f"
pf "$P" --agent-cmd bash --devcontainer-mount "$X:$X:rw"
if [[ "$RC" -eq 2 ]] && has "read-only" "$ERR"; then pass "policy: an rw explicit mount is refused"; else fail "rw mount accepted (rc=$RC)"; fi
pf "$P" --agent-cmd bash --devcontainer-mount "$X"
if [[ "$RC" -eq 0 ]] && has "mount=$X:$X:ro" "$OUTO"; then pass "policy: an explicit mount is read-only"; else fail "ro explicit mount (rc=$RC): $ERR"; fi
SOCKD="$TMP/sockdir"; mkdir -p "$SOCKD"
python3 - "$SOCKD/s" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])
PY
pf "$P" --agent-cmd bash --devcontainer-mount "$SOCKD/s"
a=$RC
pf "$P" --agent-cmd bash --devcontainer-mount "$SOCKD"
if [[ "$a" -eq 2 && "$RC" -eq 2 ]] && has "socket" "$ERR"; then pass "policy: a socket, and a directory containing one, are refused"; else fail "socket mounts accepted ($a/$RC): $ERR"; fi
FIFOD="$TMP/fifodir"; mkdir -p "$FIFOD"; mkfifo "$FIFOD/q"
pf "$P" --agent-cmd bash --devcontainer-mount "$FIFOD"
if [[ "$RC" -eq 2 ]]; then pass "policy: a directory containing a FIFO is refused"; else fail "fifo dir accepted (rc=$RC)"; fi
pf "$P" --agent-cmd bash --devcontainer-mount "$HOME"
a=$RC
pf "$P" --agent-cmd bash --devcontainer-mount "$TMP"
if [[ "$a" -eq 2 && "$RC" -eq 2 ]]; then pass "policy: \$HOME and a parent of \$HOME are refused"; else fail "HOME/parent accepted ($a/$RC)"; fi
mkdir -p "$HOME/.ssh"; ln -s "$HOME/.ssh" "$TMP/sshlink"
pf "$P" --agent-cmd bash --devcontainer-mount "$TMP/sshlink"
if [[ "$RC" -eq 2 ]] && has ".ssh" "$ERR"; then pass "policy: a symlink to ~/.ssh is refused after canonicalization"; else fail "symlink to ~/.ssh accepted (rc=$RC)"; fi
pf "$P" --agent-cmd bash --devcontainer-mount /run
if [[ "$RC" -eq 2 ]] && has "runtime" "$ERR"; then pass "policy: a runtime tree is refused"; else fail "/run accepted (rc=$RC)"; fi
pf "$P" --agent-cmd bash --devcontainer-mount "$P/IMPLEMENTATION_PLAN.md"
if [[ "$RC" -eq 2 ]] && has "one destination per source" "$ERR"; then pass "policy: a mount lying inside the project is refused (one destination per source)"; else fail "inside-project mount accepted (rc=$RC): $ERR"; fi

# T9: a mount point strictly inside the project / an extra dir
mkdir -p "$P/sub"; BEFORE="$(wc -l < "$WGM_STUB_TRACE")"
printf '36 35 98:0 / %s rw - ext3 /dev/x rw\n' "$P/sub" > "$TMP/mountinfo"
WGM_MOUNTINFO="$TMP/mountinfo" pf "$P" --agent-cmd bash
if [[ "$RC" -eq 2 ]] && has "$P/sub" "$ERR" && ! tail -n +"$((BEFORE + 1))" "$WGM_STUB_TRACE" | grep -q ' run '; then
  pass "T9: a mount point inside the project is refused by name; no container launched"
else fail "mountinfo seam (rc=$RC): $ERR"; fi
: > "$TMP/mountinfo"
WGM_MOUNTINFO="$TMP/mountinfo" pf "$P" --agent-cmd bash
if [[ "$RC" -eq 0 ]]; then pass "T9 recovery: removing the mount-point line lets the decision succeed"; else fail "T9 recovery (rc=$RC): $ERR"; fi
printf '36 35 98:0 / %s rw - ext3 /dev/x rw\n' "$X/deep" > "$TMP/mountinfo"; mkdir -p "$X/deep"
WGM_MOUNTINFO="$TMP/mountinfo" pf "$P" --agent-cmd bash --devcontainer-mount "$X"
if [[ "$RC" -eq 2 ]] && has "$X/deep" "$ERR"; then pass "T9: a mount point inside an extra dir is refused by name"; else fail "mountinfo inside extra (rc=$RC): $ERR"; fi

# T13: include.path into the project tree
echo '[x]' > "$P/inc.cfg"; git -C "$P" config include.path "$P/inc.cfg"
pf "$P" --agent-cmd bash
if [[ "$RC" -eq 2 ]] && has "$P/inc.cfg" "$ERR"; then pass "T13: a config include inside the project is refused naming the target"; else fail "include accepted (rc=$RC): $ERR"; fi
mv "$P/inc.cfg" "$TMP/inc.cfg"; git -C "$P" config include.path "$TMP/inc.cfg"
pf "$P" --agent-cmd bash
if [[ "$RC" -eq 0 ]]; then pass "T13 recovery: moving the include outside every writable mount succeeds"; else fail "T13 recovery (rc=$RC): $ERR"; fi
git -C "$P" config --unset include.path
# hard links in a writable mount (R7-F1)
ln "$P/IMPLEMENTATION_PLAN.md" "$P/hl"
pf "$P" --agent-cmd bash
if [[ "$RC" -eq 2 ]] && has "hard link" "$ERR"; then pass "policy: a hard-linked file in the writable project is refused"; else fail "hard link accepted (rc=$RC): $ERR"; fi
rm -f "$P/hl"

# ---- T16: where the agent binary lives decides its mounts ------------------------------------------------
P="$(newproj p16)"
mkdir -p "$P/bin"; printf '#!/usr/bin/env bash\necho agent\n' > "$P/bin/agent"; chmod +x "$P/bin/agent"
# (the host's own `node` may add its prefix mount; nothing for the AGENT may appear)
extra_for_agent() { grep '^mount=' <<<"$OUTO" | grep -E "mount=(${P}/bin|${TMP}[^/]*:|${TMP}/[^:]*:)" | grep -v "^mount=${P}[:/]" | grep -q .; }
pf "$P" --agent-cmd ./bin/agent; a=$RC; extra_for_agent && ax=1 || ax=0
pf "$P" --agent-cmd "$P/bin/agent"; b=$RC; extra_for_agent && bx=1 || bx=0
if [[ "$a" -eq 0 && "$b" -eq 0 && "$ax" -eq 0 && "$bx" -eq 0 ]]; then
  pass "T16a: an in-project agent (relative and absolute) gets no extra mount"
else fail "T16a extra mounts for an in-project agent: $OUTO"; fi
mkdir -p "$TMP/npmx/bin" "$TMP/npmx/lib/node_modules/x"
printf '#!/usr/bin/env bash\necho x\n' > "$TMP/npmx/lib/node_modules/x/cli.js"; chmod +x "$TMP/npmx/lib/node_modules/x/cli.js"
ln -s ../lib/node_modules/x/cli.js "$TMP/npmx/bin/x"
PATH="$TMP/npmx/bin:$STUBPATH" pf "$P" --agent-cmd x
if [[ "$RC" -eq 0 ]] && [[ "$(grep -c "^mount=$TMP/npmx:" <<<"$OUTO")" -eq 1 ]] && has "mount=$TMP/npmx:$TMP/npmx:ro" "$OUTO"; then
  pass "T16b: an npm-style CLI symlink yields exactly one read-only mount of its prefix"
else fail "T16b prefix mount (rc=$RC): $OUTO / $ERR"; fi
mkdir -p "$HOME/bin"; printf '#!/usr/bin/env bash\necho h\n' > "$HOME/bin/hx"; chmod +x "$HOME/bin/hx"
PATH="$HOME/bin:$STUBPATH" pf "$P" --agent-cmd hx
if [[ "$RC" -eq 2 ]] && has "hx" "$ERR" && has "$HOME" "$ERR"; then pass "T16c: a CLI whose prefix is \$HOME is refused, naming binary and prefix"; else fail "T16c (rc=$RC): $ERR"; fi

# ---- T11/T12: host git never fetches / runs transport helpers --------------------------------------------
# shellcheck source=scripts/sandbox.sh
source "$SB"
SRC="$TMP/psrc"; git init -q "$SRC"; ( cd "$SRC" && git config user.email t@e && git config user.name t && echo blob-content > f && git add f && git commit -qm b \
  && git config uploadpack.allowFilter true && git config uploadpack.allowAnySHA1InWant true )
BLOB="$(git -C "$SRC" rev-parse HEAD:f)"
for n in 1 2 3; do git clone -q --no-checkout --filter=blob:none "file://$SRC" "$TMP/pclone$n" 2>/dev/null; git -C "$TMP/pclone$n" config protocol.file.allow always; done
git -C "$TMP/pclone1" cat-file -p "$BLOB" >/dev/null 2>&1 && ctl=1 || ctl=0   # POSITIVE CONTROL: plain git lazily fetches
objs() { find "$1/.git/objects" -type f | wc -l; }
before="$(objs "$TMP/pclone2")"
if [[ "$ctl" -eq 1 ]] && ! wgm_host_git -C "$TMP/pclone2" cat-file -p "$BLOB" >/dev/null 2>&1 && [[ "$(objs "$TMP/pclone2")" -eq "$before" ]]; then
  pass "T11: plain git lazily fetches a missing blob (control); wgm's host-git helper fails with it still absent"
else fail "T11 lazy fetch (control=$ctl)"; fi
mkdir -p "$TMP/helpers"; printf '#!/usr/bin/env bash\ntouch "%s"\nexit 1\n' "$TMP/sentinel" > "$TMP/helpers/git-remote-wgmx"; chmod +x "$TMP/helpers/git-remote-wgmx"
git -C "$TMP/pclone3" remote set-url origin "wgmx::fixture"
PATH="$TMP/helpers:$PATH" GIT_ALLOW_PROTOCOL=wgmx git -C "$TMP/pclone3" cat-file -p "$BLOB" >/dev/null 2>&1 || true
[[ -e "$TMP/sentinel" ]] && ctl=1 || ctl=0; rm -f "$TMP/sentinel"
PATH="$TMP/helpers:$PATH" wgm_host_git -C "$TMP/pclone3" cat-file -p "$BLOB" >/dev/null 2>&1 && w=1 || w=0
if [[ "$ctl" -eq 1 && "$w" -eq 0 && ! -e "$TMP/sentinel" ]]; then
  pass "T12: a git-remote-<name> helper runs when its name is allowed (control) and never through wgm's host-git helper"
else fail "T12 transport helper (control=$ctl, helper-read=$w, sentinel=$([[ -e $TMP/sentinel ]] && echo yes || echo no))"; fi

# ---- U7(2)/U30: the executable-config pin is GIT-FREE raw bytes: a symlinked config is REFUSED (uninspectable); a regular
# config's edit, a NEW include line and an edit of the include target each change the digest -----------------------------
PINC="$TMP/pincommon"; mkdir -p "$PINC/hooks" "$PINC/info" "$PINC/objects/info" "$TMP/pinref"
printf '[core]\n' > "$TMP/pinref/real-config"; ln -s "$TMP/pinref/real-config" "$PINC/config"
SB_COMMON="$PINC"; SB_PROJECT="$TMP"
PIN1="$(sb_pin_config)"
rm -f "$PINC/config"; printf '[core]\n' > "$PINC/config"
PIN2="$(sb_pin_config)"
printf '[alias]\n x = !touch /tmp/pwn\n' >> "$PINC/config"
PIN3="$(sb_pin_config)"
printf '[core]\n' > "$PINC/config"; printf '[include]\n path = %s/inc.cfg\n' "$TMP/pinref" >> "$PINC/config"; echo '[a]' > "$TMP/pinref/inc.cfg"
SB_PIN_INC=("$TMP/pinref/inc.cfg")   # (the canonical set sb_pin_capture resolves with git once; verify never re-parses)
PIN4="$(sb_pin_config)"
echo '[a] b = !touch /tmp/pwn2' >> "$TMP/pinref/inc.cfg"
PIN5="$(sb_pin_config)"
SB_COMMON=""; SB_PROJECT=""; SB_PIN_INC=()
if [[ "$PIN1" == __UNINSPECTABLE__* && "$PIN2" != __UNINSPECTABLE__* && "$PIN2" != "$PIN3" && "$PIN3" != "$PIN4" && "$PIN4" != "$PIN5" && "$PIN2" != "$PIN4" ]]; then
  pass "U7(2): a symlinked config is refused; raw-bytes digests change on a config edit, a new include line and an edit of a stored include target (no git involved)"
else fail "U7(2): pins [${PIN1:0:30}] [${PIN2:0:12}] [${PIN3:0:12}] [${PIN4:0:12}] [${PIN5:0:12}]"; fi

# ---- U9 / T6: the record is always complete (old or new), written only under a lock --------------------
LK="$TMP/lockrec"; mkdir -p "$LK"; chmod 700 "$LK"
SB_RECORD="$LK/rec.yml"
t6_save() { local REC_AGENTS="$1"; sb_record_save; }   # one writer (run in a background subshell)
t6_unit() {  # t6_unit LABEL — 30 rounds of two concurrent writers (different agent sets), one SIGKILLed mid-flight
  local label="$1" r bad=0 agents
  REC_DECLINED=false; REC_DECLINED_AT=""; REC_IMAGE=""; REC_MOUNTS=(); REC_COPIES=(); REC_TOKENS=()
  REC_ENV=(); for r in $(seq 1 200); do REC_ENV+=("ENV_NAME_$r"); done
  REC_AGENTS="seed"; sb_record_save
  for r in $(seq 1 30); do
    t6_save alpha 2>/dev/null & wa=$!
    t6_save beta 2>/dev/null & wb=$!
    sleep "0.0$((r % 7))"
    if (( r % 2 )); then kill -9 "$wa" 2>/dev/null || true; else kill -9 "$wb" 2>/dev/null || true; fi
    wait "$wa" "$wb" 2>/dev/null || true
    sb_record_load 2> "$TMP/t6.load"; out="$(cat "$TMP/t6.load")"
    agents="$REC_AGENTS"
    [[ "$out" != *malformed* && "$REC_PRESENT" -eq 1 && ( "$agents" == alpha || "$agents" == beta || "$agents" == seed ) && "${#REC_ENV[@]}" -eq 200 ]] || bad=$((bad + 1))
  done
  # a lock left behind by a killed writer (mkdir path) must be detected as stale and the next save must work
  REC_AGENTS="final"; sb_record_save; sb_record_load
  if [[ "$bad" -eq 0 && "$REC_AGENTS" == final ]]; then pass "T6 ($label): 30 rounds of concurrent/killed writers always leave a complete record; a later save still works"; else fail "T6 ($label): $bad incomplete reads (agents=$REC_AGENTS)"; fi
}
t6_unit "flock"
WGM_NO_FLOCK=1 t6_unit "mkdir lock"
# lock policy: a live holder makes the save fail (exit 2, names the lock); a dead holder's lock is broken
sleep 30 & HOLD=$!; printf '%s %s\n' "$HOLD" "$(sb_proc_start "$HOLD")" > "$LK/.lock.own"
rc=0; out="$( WGM_NO_FLOCK=1 WGM_LOCK_TRIES=5 bash -c 'source "$1"; SB_RECORD="$2"; REC_DECLINED=false; REC_DECLINED_AT=""; REC_AGENTS=x; REC_IMAGE=""; sb_record_save' _ "$SB" "$LK/rec.yml" 2>&1)" || rc=$?
kill "$HOLD" 2>/dev/null || true; wait "$HOLD" 2>/dev/null || true
if [[ "$rc" -eq 2 && "$out" == *".lock.own"* ]]; then pass "T6 lock policy: a live lock holder makes the save fail with exit 2 naming the lock (no silent unlocked write)"; else fail "T6 lock failure (rc=$rc): $out"; fi
rc=0; WGM_NO_FLOCK=1 WGM_LOCK_TRIES=5 bash -c 'source "$1"; SB_RECORD="$2"; REC_DECLINED=false; REC_DECLINED_AT=""; REC_AGENTS=y; REC_IMAGE=""; sb_record_save' _ "$SB" "$LK/rec.yml" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 && ! -e "$LK/.lock.own" ]] && grep -q '^agents: y$' "$LK/rec.yml"; then pass "T6 lock policy: a stale lock (dead owner) is broken and the save proceeds"; else fail "T6 stale lock (rc=$rc)"; fi
# U12: the lock names the REAL holder ($BASHPID + start time). A holder SUBSHELL SIGKILLed while holding the
# lock leaves a stale lock (its pid is dead) that the next save breaks at once — not after the 120 s age bound.
rm -rf "$LK/.lock.own" "$LK/held"
( WGM_NO_FLOCK=1 sb_lock_acquire "$LK"; : > "$LK/held"; sleep 60 ) & HOLDER=$!
for _i in $(seq 1 100); do [[ -e "$LK/held" ]] && break; sleep 0.1; done
kill -9 "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
t0=$SECONDS; rc=0
WGM_NO_FLOCK=1 bash -c 'source "$1"; SB_RECORD="$2"; REC_DECLINED=false; REC_DECLINED_AT=""; REC_AGENTS=u12; REC_IMAGE=""; sb_record_save' _ "$SB" "$LK/rec.yml" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 && $((SECONDS - t0)) -lt 5 ]] && grep -q '^agents: u12$' "$LK/rec.yml"; then pass "U12: a lock holder (subshell) SIGKILLed while holding the mkdir lock is detected as stale at once (save succeeded in $((SECONDS - t0))s)"; else fail "U12 killed subshell holder (rc=$rc, $((SECONDS - t0))s)"; fi
# the lock file records the holder's own pid (not the parent's) and its start time
rm -rf "$LK/.lock.own"
( WGM_NO_FLOCK=1 sb_lock_acquire "$LK"; echo "$BASHPID" > "$LK/holder-pid"; : > "$LK/held2"; sleep 5 ) & HOLDER=$!
for _i in $(seq 1 100); do [[ -e "$LK/held2" ]] && break; sleep 0.1; done
read -r lp_pid lp_start < "$LK/.lock.own"
if [[ "$lp_pid" == "$(cat "$LK/holder-pid")" && "$lp_pid" != "$$" && -n "$lp_start" ]]; then pass "U12: the lock file records the real holder's \$BASHPID and start time"; else fail "U12 lock owner record: '$lp_pid' vs holder $(cat "$LK/holder-pid") parent $$"; fi
# a live holder still blocks (exit 2 naming the lock)
rc=0; out="$( WGM_NO_FLOCK=1 WGM_LOCK_TRIES=5 bash -c 'source "$1"; SB_RECORD="$2"; REC_DECLINED=false; REC_DECLINED_AT=""; REC_AGENTS=x; REC_IMAGE=""; sb_record_save' _ "$SB" "$LK/rec.yml" 2>&1)" || rc=$?
if [[ "$rc" -eq 2 && "$out" == *".lock.own"* ]]; then pass "U12: a live holder (matching pid and start time) still blocks and then exits 2 naming the lock"; else fail "U12 live holder (rc=$rc): $out"; fi
kill -9 "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
# a pid file naming a live but DIFFERENT process (start time mismatch = reused pid) is broken
rm -rf "$LK/.lock.own"; sleep 30 & OTHER=$!
printf '%s %s\n' "$OTHER" "1" > "$LK/.lock.own"
t0=$SECONDS; rc=0
WGM_NO_FLOCK=1 bash -c 'source "$1"; SB_RECORD="$2"; REC_DECLINED=false; REC_DECLINED_AT=""; REC_AGENTS=reused; REC_IMAGE=""; sb_record_save' _ "$SB" "$LK/rec.yml" >/dev/null 2>&1 || rc=$?
kill "$OTHER" 2>/dev/null || true; wait "$OTHER" 2>/dev/null || true
if [[ "$rc" -eq 0 && $((SECONDS - t0)) -lt 5 ]] && grep -q '^agents: reused$' "$LK/rec.yml"; then pass "U12: a lock whose pid is alive but whose start time differs (reused pid) is broken"; else fail "U12 reused pid (rc=$rc)"; fi

# U16 (a): a holder SIGKILLed at every acquire stage never wedges the fallback lock (before ln / right after ln)
for stage in before-ln after-ln; do
  rm -f "$LK/.lock.own" "$LK/.paused"
  ( WGM_NO_FLOCK=1 WGM_LOCK_PAUSE="$stage" sb_lock_acquire "$LK" ) & HOLDER=$!
  for _i in $(seq 1 100); do [[ -e "$LK/.paused" ]] && break; sleep 0.1; done
  kill -9 "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
  t0=$SECONDS; rc=0
  WGM_NO_FLOCK=1 bash -c 'source "$1"; SB_RECORD="$2"; REC_DECLINED=false; REC_DECLINED_AT=""; REC_AGENTS=stage; REC_IMAGE=""; sb_record_save' _ "$SB" "$LK/rec.yml" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 && $((SECONDS - t0)) -lt 5 ]]; then pass "U16(a): a holder SIGKILLed $stage does not wedge the lock (next save in $((SECONDS - t0))s)"; else fail "U16(a) $stage (rc=$rc, $((SECONDS - t0))s)"; fi
done
# U16 (b): 50 rounds of 3 concurrent writers with random SIGKILLs: no spurious exit 2, never two live holders inside the
# critical section, and the lock is usable afterwards
t16_writer() {  # three acquire / critical-section / release cycles
  local i ip
  for i in 1 2 3; do
    sb_lock_acquire "$LK"
    if [[ -s "$LK/inside" ]]; then ip="$(cat "$LK/inside")"; if [[ "$ip" != "$BASHPID" ]] && kill -0 "$ip" 2>/dev/null; then echo viol >> "$LK/viol"; fi; fi
    echo "$BASHPID" > "$LK/inside"; sleep "0.0$((RANDOM % 4))"; : > "$LK/inside"
    sb_lock_release
  done
}
rm -f "$LK/.lock.own" "$LK/inside" "$LK/viol"; spurious=0
for r in $(seq 1 50); do
  WGM_NO_FLOCK=1 t16_writer 2>/dev/null & w1=$!
  WGM_NO_FLOCK=1 t16_writer 2>/dev/null & w2=$!
  WGM_NO_FLOCK=1 t16_writer 2>/dev/null & w3=$!
  sleep "0.0$((RANDOM % 6))"
  case $((r % 3)) in 0) kill -9 "$w1" 2>/dev/null || true ;; 1) kill -9 "$w2" 2>/dev/null || true ;; *) ;; esac
  for w in "$w1" "$w2" "$w3"; do rc=0; wait "$w" 2>/dev/null || rc=$?; [[ "$rc" -eq 0 || "$rc" -eq 137 ]] || spurious=$((spurious + 1)); done
done
rc=0; WGM_NO_FLOCK=1 bash -c 'source "$1"; SB_RECORD="$2"; REC_DECLINED=false; REC_DECLINED_AT=""; REC_AGENTS=after; REC_IMAGE=""; sb_record_save' _ "$SB" "$LK/rec.yml" >/dev/null 2>&1 || rc=$?
if [[ "$spurious" -eq 0 && ! -e "$LK/viol" && "$rc" -eq 0 ]]; then pass "U16(b): 50 rounds x 3 concurrent writers with random SIGKILLs: no spurious exit 2, never two live holders in the critical section, lock still usable"; else fail "U16(b): spurious=$spurious viol=$([[ -e $LK/viol ]] && wc -l < "$LK/viol" || echo 0) final-rc=$rc"; fi

exec 7>"$LK/.lock"; flock -n 7
rc=0; out="$( WGM_LOCK_TRIES=5 bash -c 'source "$1"; SB_RECORD="$2"; REC_DECLINED=false; REC_DECLINED_AT=""; REC_AGENTS=z; REC_IMAGE=""; sb_record_save' _ "$SB" "$LK/rec.yml" 2>&1)" || rc=$?
exec 7>&-
if [[ "$rc" -eq 2 && "$out" == *".lock"* ]] && ! grep -q '^agents: z$' "$LK/rec.yml"; then pass "T6 lock policy: a held flock makes the save fail with exit 2 and the record is untouched"; else fail "T6 flock failure (rc=$rc): $out"; fi
SB_RECORD=""

# two real concurrent interactive preflights approving DIFFERENT agent sets for one repo (stub engine + pty)
P="$(newproj t6)"
mkstub "$TMP/stubs/claude" claude 'echo "claude stub 1.0"'; mkstub "$TMP/stubs/codex" codex 'echo "codex stub 1.0"'
rm -rf "$XDG_CONFIG_HOME/wgm"
T6PATH="$TMP/stubs/claude/bin:$TMP/stubs/codex/bin:$STUBPATH"
( script -qec "cd '$P' && ANTHROPIC_API_KEY=a OPENAI_API_KEY=o PATH='$T6PATH' '$SB' preflight --interactive yes --agent-cmd claude" /dev/null < <(printf 'y\n'; sleep 6) > "$TMP/t6a.out" 2>&1 ) &
wa=$!
( script -qec "cd '$P' && ANTHROPIC_API_KEY=a OPENAI_API_KEY=o PATH='$T6PATH' '$SB' preflight --interactive yes --agent-cmd codex" /dev/null < <(printf 'y\n'; sleep 6) > "$TMP/t6b.out" 2>&1 ) &
wb=$!
wait "$wa" "$wb" 2>/dev/null || true
T6REC="$(compgen -G "$XDG_CONFIG_HOME/wgm/sandbox/*.yml" | head -1 || true)"
if [[ -n "$T6REC" ]] && grep -Eq '^agents: (claude|codex)$' "$T6REC" && grep -q '^env:$' "$T6REC" && [[ "$(grep -c '^  - ' "$T6REC")" -ge 1 ]]; then
  pass "T6: two concurrent interactive preflights with different agent sets leave one complete record ($(grep '^agents:' "$T6REC"))"
else fail "T6 concurrent preflights: $(cat "$T6REC" 2>/dev/null)"; fi
# partial/malformed record: headless → exit 2 (treated as absent); interactive → re-asked and rewritten whole
head -c 70 "$T6REC" > "$T6REC.cut"; mv "$T6REC.cut" "$T6REC"; chmod 600 "$T6REC"; printf '  - /ho' >> "$T6REC"
ANTHROPIC_API_KEY=a PATH="$T6PATH" pf "$P" --agent-cmd claude
a=$RC; has "malformed" "$ERR" && m=1 || m=0
pty 'y\n' "cd '$P' && ANTHROPIC_API_KEY=a PATH='$T6PATH' '$SB' preflight --interactive yes --agent-cmd claude"
if [[ "$a" -eq 2 && "$m" -eq 1 ]] && has "Mount these into the sandbox" "$OUTO" && has "sandbox=on" "$OUTO" && grep -q '^agents: claude$' "$T6REC" && grep -q '^env:$' "$T6REC"; then
  pass "T6 recovery: a partial record is treated as absent (headless exit 2); interactive re-asks and rewrites a complete record"
else fail "T6 recovery (headless rc=$a, malformed-msg=$m): $(tail -3 <<<"$OUTO")"; fi

# ---- U11: no HOST git call runs a repository-configured command (filters, textconv, diff.external, …) ------
P="$(newproj l97)"; NC="$P/.git/custom"; mkdir -p "$NC"
for h in clean smudge textconv ext; do printf '#!/bin/sh\ntouch "%s/fired-%s"\ncat\n' "$TMP" "$h" > "$NC/$h.sh"; chmod +x "$NC/$h.sh"; done
git -C "$P" config filter.wgmc.clean "$NC/clean.sh"; git -C "$P" config filter.wgmc.smudge "$NC/smudge.sh"
git -C "$P" config diff.wgmc.textconv "$NC/textconv.sh"; git -C "$P" config diff.external "$NC/ext.sh"
git -C "$P" config filter.wgmc.required false
echo '*.wgm filter=wgmc diff=wgmc' > "$P/.gitattributes"; echo one > "$P/a.wgm"; git -C "$P" add -A; git -C "$P" -c filter.wgmc.clean= commit -qm filtered
stale() { rm -f "$TMP"/fired-*; touch "$P/a.wgm"; echo "edit $RANDOM" >> "$P/a.wgm"; }   # stat change forces re-hashing / a real diff
stale; git -C "$P" status >/dev/null 2>&1 || true; git -C "$P" diff >/dev/null 2>&1 || true
ctl=0; for h in clean ext; do [[ -e "$TMP/fired-$h" ]] && ctl=$((ctl + 1)); done
stale; git -C "$P" diff --no-ext-diff >/dev/null 2>&1 || true; [[ -e "$TMP/fired-textconv" ]] && ctl=$((ctl + 1))
stale
wgm_host_git -C "$P" status >/dev/null 2>&1 || true
wgm_host_git -C "$P" diff >/dev/null 2>&1 || true
wgm_host_git -C "$P" diff --no-ext-diff >/dev/null 2>&1 || true
wgm_host_git -C "$P" ls-files -m >/dev/null 2>&1 || true
wgm_host_git -C "$P" add -n a.wgm >/dev/null 2>&1 || true
fired="$( { ls "$TMP"/fired-* 2>/dev/null || true; } | wc -l)"
if [[ "$ctl" -eq 3 && "$fired" -eq 0 ]]; then pass "U11: plain git fires the configured clean/textconv/diff.external helpers (control); wgm_host_git never does (even status/diff/add -n)"; else fail "U11 (control=$ctl/3, fired-by-wgm_host_git=$fired)"; fi
sb_git_neutralizers "$P"
if [[ " ${SB_NEUT[*]} " == *" filter.wgmc.clean= "* && " ${SB_NEUT[*]} " == *" filter.wgmc.smudge= "* && " ${SB_NEUT[*]} " == *" filter.wgmc.required=false "* \
   && " ${SB_NEUT[*]} " == *" diff.wgmc.textconv= "* && " ${SB_NEUT[*]} " == *" diff.external= "* && " ${SB_NEUT[*]} " == *" core.pager=cat "* ]]; then
  pass "U11: sb_git_neutralizers emits the empty-command pairs for every configured filter/diff driver"
else fail "U11 neutralizers: ${SB_NEUT[*]}"; fi
# the cache is recomputed when the repo config changes
git -C "$P" config filter.other.clean "$NC/clean.sh"
sb_git_neutralizers "$P"
if [[ " ${SB_NEUT[*]} " == *" filter.other.clean= "* ]]; then pass "U11: the neutralizer cache is recomputed when the repo config changes"; else fail "U11 stale cache: ${SB_NEUT[*]}"; fi

# ---- U13: host git never reads THROUGH agent-planted symlinks/special files in the writable git dir ---------
if command -v strace >/dev/null 2>&1 && strace -f --seccomp-bpf -qq -e trace=openat -o /dev/null true 2>/dev/null; then
  have_strace=1; else have_strace=0; fi
# shellcheck disable=SC2016  # the body expands inside the child shell
hostgit_in_child() { bash -c 'source "$1"; shift; wgm_host_git "$@"' _ "$SB" "$@"; }   # a fresh process, as swarm's helpers are
# shellcheck disable=SC2016  # the body expands inside the child shell
strace_hostgit() { local out="$1"; shift; strace -f --seccomp-bpf -y -e trace=openat -o "$out" bash -c 'source "$1"; shift; wgm_host_git "$@"' _ "$SB" "$@"; }
resolved_opens() {  # resolved_opens TRACEFILE CANARY → number of SUCCESSFUL opens whose fd resolves to the canary
  { grep -E "= [0-9]+<[^>]*$2>" "$1" || true; } | wc -l
}
P="$(newproj l98)"; echo "canary-content" > "$TMP/canary98"
git -C "$P" worktree add -q "$TMP/lane98" -b lane98
ADM="$P/.git/worktrees/lane98"
# (3) a normal repo and a normal worktree are unaffected
if wgm_host_git -C "$P" rev-parse HEAD >/dev/null 2>&1 && wgm_host_git -C "$TMP/lane98" rev-parse HEAD >/dev/null 2>&1 && wgm_host_git -C "$TMP/lane98" status >/dev/null 2>&1; then
  pass "U13(3): a normal repo and worktree pass the git-dir guard (host git works)"; else fail "U13(3): guard broke a normal repo"; fi
# positive control: plain git DOES open the referent of a symlinked index
rm -f "$ADM/index"; ln -s "$TMP/canary98" "$ADM/index"
if [[ "$have_strace" -eq 1 ]]; then
  strace -f --seccomp-bpf -y -e trace=openat -o "$TMP/u13.ctl" git -C "$TMP/lane98" status >/dev/null 2>&1 || true
  [[ "$(resolved_opens "$TMP/u13.ctl" canary98)" -ge 1 ]] && ctl=1 || ctl=0
  strace_hostgit "$TMP/u13.out" -C "$TMP/lane98" status >"$TMP/u13.msg" 2>&1 || true
  n="$(resolved_opens "$TMP/u13.out" canary98)"
else ctl=1; n=0; hostgit_in_child -C "$TMP/lane98" status >"$TMP/u13.msg" 2>&1 || true; fi
rc=0; hostgit_in_child -C "$TMP/lane98" status >/dev/null 2>&1 || rc=$?
if [[ "$ctl" -eq 1 && "$n" -eq 0 && "$rc" -eq 2 ]] && grep -q "worktrees/lane98/index" "$TMP/u13.msg"; then
  pass "U13(1): a symlinked worktree admin index is refused (exit 2, names it) with zero opens of the referent (plain git opens it: control)"
else fail "U13(1) (control=$ctl, opens=$n, rc=$rc): $(cat "$TMP/u13.msg")"; fi
rm -f "$ADM/index"; git -C "$TMP/lane98" reset -q
# (2) a symlinked loose ref and a symlinked packed-refs in the common dir
for kind in loose packed; do
  if [[ "$kind" == loose ]]; then ln -s "$TMP/canary98" "$P/.git/refs/heads/evil"; else printf 'x\n' > "$P/.git/packed-refs.real"; ln -s "$TMP/canary98" "$P/.git/packed-refs"; fi
  if [[ "$have_strace" -eq 1 ]]; then strace_hostgit "$TMP/u13.$kind" -C "$P" for-each-ref >"$TMP/u13.msg" 2>&1 || true; n="$(resolved_opens "$TMP/u13.$kind" canary98)"
  else hostgit_in_child -C "$P" for-each-ref >"$TMP/u13.msg" 2>&1 || true; n=0; fi
  rc=0; hostgit_in_child -C "$P" for-each-ref >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 2 && "$n" -eq 0 ]] && grep -q "refused" "$TMP/u13.msg"; then pass "U13(2): a symlinked $kind ref store is refused before any open of the referent"; else fail "U13(2) $kind (rc=$rc opens=$n): $(cat "$TMP/u13.msg")"; fi
  rm -f "$P/.git/refs/heads/evil" "$P/.git/packed-refs" "$P/.git/packed-refs.real"
done
# a special file (FIFO) in the git dir is refused too, and the full scan covers objects/
mkfifo "$P/.git/objects/info/evil-fifo"
rc=0; bash -c 'source "$1"; sb_gitdir_guard "$2" full' _ "$SB" "$P" >/dev/null 2>&1 || rc=$?
rc2=0; bash -c 'source "$1"; sb_gitdir_guard "$2"' _ "$SB" "$P" >/dev/null 2>&1 || rc2=$?
rm -f "$P/.git/objects/info/evil-fifo"
if [[ "$rc" -eq 2 && "$rc2" -eq 0 ]]; then pass "U13: a FIFO under objects/ is caught by the full (phase-boundary) scan, not by the cheap per-call one"; else fail "U13 objects scan (full rc=$rc cheap rc=$rc2)"; fi

# U14: --expect-common refuses a redirected common dir BEFORE scanning anything
P="$(newproj l99)"; git -C "$P" worktree add -q "$TMP/lane99" -b lane99
OTHER="$TMP/other99"; git init -q "$OTHER"
rc=0; out="$(bash -c 'source "$1"; sb_gitdir_guard "$2" --expect-common "$3"' _ "$SB" "$TMP/lane99" "$OTHER/.git" 2>&1)" || rc=$?
rc2=0; bash -c 'source "$1"; sb_gitdir_guard "$2" --expect-common "$3"' _ "$SB" "$TMP/lane99" "$P/.git" >/dev/null 2>&1 || rc2=$?
if [[ "$rc" -eq 2 && "$out" == *"were redirected"* && "$rc2" -eq 0 ]]; then pass "U14: sb_gitdir_guard --expect-common refuses a common dir other than the expected one before any scan, and accepts the right one"; else fail "U14 --expect-common (rc=$rc/$rc2): $out"; fi

# U18 (S55): a replaced INTERMEDIATE `<common>/worktrees` symlink is refused naming it, with zero opens of the outside copy
if [[ "$have_strace" -eq 1 ]]; then
  P="$(newproj l103)"; git -C "$P" worktree add -q "$TMP/lane103" -b lane103
  OUTW="$TMP/outwt103"; rm -rf "$OUTW"; cp -a "$P/.git/worktrees" "$OUTW"
  mv "$P/.git/worktrees" "$P/.git/worktrees.moved"; ln -s "$OUTW" "$P/.git/worktrees"
  opens_in2() { { grep -E "= [0-9]+<$2/" "$1" || true; } | wc -l; }
  strace -f --seccomp-bpf -y -e trace=openat -o "$TMP/u18.ctl" git -C "$TMP/lane103" status >/dev/null 2>&1 || true
  [[ "$(opens_in2 "$TMP/u18.ctl" "$OUTW")" -ge 1 ]] && ctl=1 || ctl=0
  # shellcheck disable=SC2016  # expands in the child shell
  strace -f --seccomp-bpf -y -e trace=openat -o "$TMP/u18.out" bash -c 'source "$1"; sb_gitdir_guard "$2" full --expect-common "$3"' _ "$SB" "$TMP/lane103" "$P/.git" >"$TMP/u18.msg" 2>&1 && rc=0 || rc=$?
  n="$(opens_in2 "$TMP/u18.out" "$OUTW")"
  if [[ "$ctl" -eq 1 && "$rc" -eq 2 && "$n" -eq 0 ]] && grep -q "$P/.git/worktrees" "$TMP/u18.msg"; then
    pass "U18(1): sb_gitdir_guard --expect-common refuses a symlinked <common>/worktrees naming it, with zero opens of the outside copy (plain git opens it: control)"
  else fail "U18(1) (control=$ctl rc=$rc opens=$n): $(cat "$TMP/u18.msg")"; fi
  rm -f "$P/.git/worktrees"; mv "$P/.git/worktrees.moved" "$P/.git/worktrees"
  # a normal worktree is unaffected
  rc=0; bash -c 'source "$1"; sb_gitdir_guard "$2" full --expect-common "$3"' _ "$SB" "$TMP/lane103" "$P/.git" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then pass "U18: a normal worktree passes the ancestor-aware guard"; else fail "U18 normal worktree (rc=$rc)"; fi
fi

# ---- U5: entries vanishing during a scan are not inspection failures; real failures still refuse ----
RACE="$TMP/race"; mkdir -p "$RACE/hooks" "$RACE/info" "$RACE/objects/info" "$RACE/sub"
( while :; do for i in 1 2 3 4 5 6 7 8; do : > "$RACE/sub/f$i"; : > "$RACE/hooks/h$i"; rm -f "$RACE/sub/f$i" "$RACE/hooks/h$i"; done; done ) &
WRITER=$!
refusals=0
for _i in $(seq 1 220); do
  ( sb_scan "$RACE" "hard links" -type f -links +1 >/dev/null 2>&1 ) || refusals=$((refusals + 1))
done
SB_COMMON="$RACE"
for _i in $(seq 1 60); do
  out="$(sb_pin_config)"; [[ "$out" != __UNINSPECTABLE__* ]] || refusals=$((refusals + 1))
done
SB_COMMON=""
kill "$WRITER" 2>/dev/null || true; wait "$WRITER" 2>/dev/null || true
if [[ "$refusals" -eq 0 ]]; then pass "U5(1): 220 scans + 60 pin listings of a dir under constant create/delete churn never refuse"; else fail "U5(1): $refusals spurious refusals under churn"; fi
rc=0; ( sb_scan "$TMP/no-such-root" "hard links" -type f -links +1 >/dev/null 2>&1 ) || rc=$?
if [[ "$rc" -eq 2 ]]; then pass "U5(3): a missing scan root still refuses (exit 2)"; else fail "U5(3): missing root gave rc=$rc"; fi
# classification: only ENOENT strictly below the root is ignorable
if [[ -z "$(sb_real_errors "find: '$RACE/sub/x': No such file or directory" "$RACE")" ]] \
   && [[ -n "$(sb_real_errors "find: '$RACE': No such file or directory" "$RACE")" ]] \
   && [[ -n "$(sb_real_errors "find: '$RACE/sub': Permission denied" "$RACE")" ]]; then
  pass "U5: only 'No such file' strictly below the root is ignorable; the root itself and other errors are not"
else fail "U5 classification"; fi

# ---- the sandboxed loop (stub engine) ------------------------------------------------------------------
# shellcheck disable=SC2016
AG_PROGRESS='if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- step\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"'
LOUT=""; LRC=0
lp() {  # lp PROJECT ARGS… → LOUT, LRC
  local d="$1"; shift
  set +e
  LOUT="$(cd "$d" && "$LOOP" "$@" 2>&1)"; LRC=$?
  set -e
}

# ---- U17: a scanner that fails SILENTLY (non-zero, no diagnostics) or is killed is NOT "inspected, nothing found" ----
REAL_FIND="$(command -v find)"
rc=0; ( find() { return 73; }; SB_FIND_IRR=no; sb_scan "$TMP" "hard links" -type f -links +1 >/dev/null 2>&1 ) || rc=$?
rc2=0; ( find() { kill -9 "$BASHPID"; }; SB_FIND_IRR=no; sb_scan "$TMP" "hard links" -type f -links +1 >/dev/null 2>&1 ) || rc2=$?
rc3=0
# shellcheck disable=SC2317,SC2329  # find() is the stub invoked indirectly by the function under test
( find() { return 73; }; SB_COMMON="$PINC"; SB_PROJECT="$TMP"; out="$(sb_pin_config)"; [[ "$out" == __UNINSPECTABLE__* ]] ) || rc3=$?
rc4=0
# shellcheck disable=SC2317,SC2329  # find() is the stub invoked indirectly by the function under test
( find() { return 73; }; sb_gitdir_guard "$(newproj l100)" >/dev/null 2>&1 ) || rc4=$?
ok0=0; ( sb_scan "$TMP" "hard links" -type f -links +1 >/dev/null 2>&1 ) && ok0=1
if [[ "$rc" -eq 2 && "$rc2" -eq 2 && "$rc3" -eq 0 && "$rc4" -eq 2 && "$ok0" -eq 1 ]]; then
  pass "U17: a find that exits 73 silently, or is SIGKILLed mid-scan, makes sb_scan / the git-dir guard refuse and sb_pin_config report __UNINSPECTABLE__; a healthy scan still passes"
else fail "U17 fault injection (scan73=$rc scanKILL=$rc2 pin=$rc3 guard=$rc4 healthy=$ok0)"; fi
# qualified vanished-entry ENOENT with a non-zero status IS evidence; the same status without diagnostics is not
if sb_find_ok 1 "find: '$TMP/x/y': No such file or directory" "$TMP/x" && ! sb_find_ok 1 "" "$TMP/x" && ! sb_find_ok 73 "" "$TMP/x" \
   && ! sb_find_ok 1 "find: '$TMP/x': No such file or directory" "$TMP/x" && ! sb_find_ok 1 "find: '$TMP/x/y': Permission denied" "$TMP/x"; then
  pass "U17: sb_find_ok accepts only exit 0 or a non-zero exit explained entirely by below-root ENOENT lines"
else fail "U17 sb_find_ok classification"; fi
# a sandboxed loop whose preflight hard-link scan fails silently launches NO container; a silent failure of the
# post-agent pin listing exits 2 as well
mkdir -p "$TMP/findshim"
cat > "$TMP/findshim/find" <<SHIM
#!/usr/bin/env bash
if [[ "\$*" == *-links* && -e "$TMP/find-fail-links" ]]; then exit 73; fi
if [[ "\$*" == *objects/info* && -e "$TMP/find-fail-pin" ]]; then exit 73; fi
exec "$REAL_FIND" "\$@"
SHIM
chmod +x "$TMP/findshim/find"
P="$(newproj l101)"; : > "$WGM_STUB_TRACE"; touch "$TMP/find-fail-links"
PATH="$TMP/findshim:$STUBPATH" lp "$P" analyze --max-retries 0 -- bash -c 'true' _
rm -f "$TMP/find-fail-links"
if [[ "$LRC" -eq 2 ]] && has "could not inspect" "$LOUT" && ! grep -q ' run ' "$WGM_STUB_TRACE"; then pass "U17: a silently failing preflight scan exits 2 and launches NO container (engine trace has no run)"; else fail "U17 preflight silent scan failure (rc=$LRC, runs=$(grep -c ' run ' "$WGM_STUB_TRACE")): $(grep -v dropped <<<"$LOUT" | tail -2)"; fi
P="$(newproj l102)"; rm -f "$TMP/find-fail-pin"
# shellcheck disable=SC2016  # expands in the agent shell
WGM_TEST_FLAG="$TMP/find-fail-pin" PATH="$TMP/findshim:$STUBPATH" lp "$P" analyze --max-retries 0 -- bash -c 'touch "$WGM_TEST_FLAG"' _
rm -f "$TMP/find-fail-pin"
if [[ "$LRC" -eq 2 ]] && has "could not inspect the git directory" "$LOUT"; then pass "U17: a post-agent silent failure of the pin listing exits 2"; else fail "U17 post-agent silent pin failure (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -2)"; fi

# ---- U21 (G7 spec compliance) ------------------------------------------------------------------------------
# B1: ONE destination per CANONICAL source for every extra mount (aliases included)
P="$(newproj l110)"; X21="$TMP/x21"; mkdir -p "$X21/tmp"; echo d > "$X21/f"; ln -sfn "$X21" "$TMP/x21alias"
pf "$P" --agent-cmd bash --devcontainer-mount "$X21:/a" --devcontainer-mount "$X21:/b"; a=$RC; has "two destinations" "$ERR" && am=1 || am=0
pf "$P" --agent-cmd bash --devcontainer-mount "$X21:/a" --devcontainer-mount "$TMP/x21alias:/b"; b=$RC; has "two destinations" "$ERR" && bm=1 || bm=0
pf "$P" --agent-cmd bash --devcontainer-mount "$X21:/a"; c=$RC
if [[ "$a" -eq 2 && "$am" -eq 1 && "$b" -eq 2 && "$bm" -eq 1 && "$c" -eq 0 ]]; then pass "U21/B1: the same canonical source (or a symlink alias) at two destinations is refused naming both; a single mount passes"; else fail "U21/B1 ($a/$am $b/$bm $c): $ERR"; fi
# B2: private run artifacts must lie outside EVERY mount (here TMPDIR inside an approved read-only extra mount)
TMPDIR="$X21/tmp" pf "$P" --agent-cmd bash --devcontainer-mount "$X21"
if { [[ "$RC" -eq 0 ]] || { [[ "$RC" -eq 2 ]] && has "lies inside the mount" "$ERR"; }; } && ! compgen -G "$X21/tmp/wgm-*" >/dev/null; then pass "U21/B2: with TMPDIR inside an approved extra mount no private run artifact is created there (fall back to a safe location, or a named exit 2)"; else fail "U21/B2 (rc=$RC, leftovers: $(ls "$X21/tmp")): $ERR"; fi
SB_PROJECT="$P"; SB_COMMON=""; SB_LAYOUT=(); SB_MOUNTS=(); SB_COPYSRC=(); SB_EXTRA_MOUNTS=("$X21")
if ! sb_outside_all_mounts "$X21/tmp" && [[ "$SB_INSIDE_OF" == "$X21" ]] && sb_outside_all_mounts "$TMP/elsewhere21" && [[ "$(TMPDIR="$X21/tmp" sb_private_base)" == /tmp ]]; then
  pass "U21/B2: sb_outside_all_mounts / sb_private_base (the helper swarm calls) reject a path inside an extra mount and fall back to /tmp"
else fail "U21/B2 helper"; fi
SB_EXTRA_MOUNTS=(); SB_PROJECT=""
# B5: EVERY failing smoke prints the project-image recipe (here a gate that exits 1)
pf "$P" --agent-cmd bash --gate-cmd 'exit 1'
if [[ "$RC" -eq 2 ]] && has ".devcontainer/Containerfile" "$ERR" && has "--devcontainer-image <tag>" "$ERR" && has "exited 1" "$ERR"; then pass "U21/B5: a smoke failing with status 1 still prints the project-image recovery recipe"; else fail "U21/B5 (rc=$RC): $ERR"; fi
# B7a: no external tool before the host environment is sanitized (project awk wrapper first on PATH; --max-cost used to run awk)
P="$(newproj l111)"; mkdir -p "$P/bin"; printf '#!/usr/bin/env bash\ntouch "%s/awk-ran"\nexec "%s" "$@"\n' "$TMP" "$(command -v awk)" > "$P/bin/awk"; chmod +x "$P/bin/awk"
rm -f "$TMP/awk-ran"
PATH="$P/bin:$STUBPATH" lp "$P" analyze --max-cost 5 --max-retries 0 -- bash -c 'true' _
[[ -e "$TMP/awk-ran" ]] && ran1=1 || ran1=0
# ...and an OUTSIDE PATH dir whose awk is a symlink into the project is refused before anything runs it
mkdir -p "$TMP/pathq"; ln -sf "$P/bin/awk" "$TMP/pathq/awk"; rm -f "$TMP/awk-ran"
PATH="$TMP/pathq:$STUBPATH" lp "$P" analyze --max-cost 5 --max-retries 0 -- bash -c 'true' _
[[ -e "$TMP/awk-ran" ]] && ran2=1 || ran2=0
if [[ "$ran1" -eq 0 && "$ran2" -eq 0 && "$LRC" -eq 2 ]] && has "pathq/awk" "$LOUT"; then pass "U21/B7a: a project awk wrapper never runs before sanitization (--max-cost); an outside-dir symlink to it is refused first"; else fail "U21/B7a (ran=$ran1/$ran2 rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -2)"; fi
# B7b: only the APPROVED credential env names survive the host re-exec
mkstub "$TMP/stubs/claude21" claude 'echo v'
P="$(newproj l112)"
PATH="$TMP/stubs/claude21/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd bash; write_rec "$(rec_of)" "claude" ANTHROPIC_API_KEY
ANTHROPIC_API_KEY=a OPENAI_API_KEY=o PATH="$TMP/stubs/claude21/bin:$STUBPATH" WGM_DEBUG_HOST_ENV="$TMP/hostenv21" lp "$P" analyze --max-retries 0 --agent claude
if [[ "$LRC" -eq 0 ]] && grep -qx ANTHROPIC_API_KEY "$TMP/hostenv21" && ! grep -qx OPENAI_API_KEY "$TMP/hostenv21"; then pass "U21/B7b: the re-exec'd host environment keeps the approved credential name only (not every table name)"; else fail "U21/B7b (rc=$LRC): $(grep -E 'API_KEY' "$TMP/hostenv21" | tr '\n' ' ')"; fi
# B7c: host tools are BOUND — PATH leads with a private dir of links to the verified canonical targets
bound="$(bash -c 'source "$1"; sb_bootstrap_host_env "$2"; p="$(command -v git)"; printf "%s|%s" "$p" "$(readlink -f "$p")"' _ "$SB" "$P" 2>/dev/null)"
if [[ "${bound%%|*}" == */wgm-bin.*/git && "${bound##*|}" == "$(readlink -f "$(command -v git)")" ]]; then pass "U21/B7c: after bootstrap git resolves through the private bound-tools dir to the verified canonical target"; else fail "U21/B7c: $bound"; fi
P="$(newproj l112b)"   # (fresh project: the claude-only approval above would — correctly — ask about the changed agent set)
# B7d: a system-prefix agent is visibly NOT mounted; a forbidden node prefix is a named exit 2 (never skipped)
pf "$P" --agent-cmd bash
has "OS-owned prefix" "$ERR" && sysnote=1 || sysnote=0
mkdir -p "$HOME/bin"; printf '#!/usr/bin/env bash\necho n\n' > "$HOME/bin/node"; chmod +x "$HOME/bin/node"
PATH="$HOME/bin:$STUBPATH" pf "$P" --agent-cmd bash
if [[ "$sysnote" -eq 1 && "$RC" -eq 2 ]] && has "node" "$ERR" && has "$HOME" "$ERR"; then pass "U21/B7d: an OS-owned prefix is reported (not silently dropped) and a forbidden node prefix is refused naming it"; else fail "U21/B7d (sysnote=$sysnote rc=$RC): $ERR"; fi
rm -f "$HOME/bin/node"

# ---- U22 (G7 r22) ----------------------------------------------------------------------------------------------
# B1/C7: the in-process allowlist is the FIRST host action — no execve after loop.sh's own start sees a
# non-allowlisted variable; an UNAPPROVED credential never reaches an engine process; the approved one does.
if command -v strace >/dev/null 2>&1 && strace -f --seccomp-bpf -qq -e trace=execve -o /dev/null true 2>/dev/null; then
  P="$(newproj l120)"; mkstub "$TMP/stubs/claude22" claude 'echo v'
  PATH="$TMP/stubs/claude22/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd bash; write_rec "$(rec_of)" "claude" ANTHROPIC_API_KEY
  set +e
  ( cd "$P" && GIT_SSH_COMMAND=poison-U22 ANTHROPIC_API_KEY=sec-a-U22 OPENAI_API_KEY=sec-o-U22 PATH="$TMP/stubs/claude22/bin:$STUBPATH" \
      strace -f --seccomp-bpf -v -s 8192 -e trace=execve -o "$TMP/u22.exec" "$LOOP" analyze --max-retries 0 --agent claude > "$TMP/u22.log" 2>&1 )
  src=$?; set -e
  # everything after loop.sh's own initial (successful) exec: that exec, and the PATH search before it, necessarily see
  # the operator's environment (bash starts before any wgm code)
  # (the first successful exec is loop.sh via its `#!/usr/bin/env bash` shebang, the second is bash itself)
  awk '{ if (n >= 2) print; if ($0 ~ / = 0$/) n++ }' "$TMP/u22.exec" > "$TMP/u22.rest"
  poison="$(grep -c 'poison-U22' "$TMP/u22.rest" || true)"
  # container launches (`run`) happen after the decision: only the approved credential may be in their environment
  unappr="$(grep -E 'execve\("[^"]*(podman|docker)", \["[^"]*", "run"' "$TMP/u22.rest" | grep -c 'sec-o-U22' || true)"
  appr="$(grep -E 'execve\("[^"]*(podman|docker)", \["[^"]*", "run"' "$TMP/u22.rest" | grep -c 'sec-a-U22' || true)"
  if [[ "$src" -eq 0 && "$poison" -eq 0 && "$unappr" -eq 0 && "$appr" -ge 1 ]]; then pass "U22/B1: no external tool ever saw a non-allowlisted variable; the unapproved credential never reached an engine process, the approved one did"; else fail "U22/B1 (rc=$src poison=$poison unapproved=$unappr approved=$appr): $(tail -2 "$TMP/u22.log")"; fi
else echo "skip: no strace — skipping the U22 execve allowlist audit"; fi
# B2: a SUPPLIED decision inside an approved extra mount is refused; the trusted-runner snapshot never lands in one
P="$(newproj l121)"; X22="$TMP/x22"; mkdir -p "$X22/dec" "$X22/tmp"; chmod 700 "$X22/dec"
pf "$P" --agent-cmd bash --devcontainer-mount "$X22"; printf '%s\\n' "$OUTO" > "$X22/dec/decision"; chmod 600 "$X22/dec/decision"
WGM_SANDBOX_DECISION="$X22/dec/decision" lp "$P" analyze --max-retries 0 -- bash -c 'true' _
if [[ "$LRC" -eq 2 ]] && has "lies inside the mount" "$LOUT" && has "$X22" "$LOUT"; then pass "U22/B2: a supplied decision file inside an approved extra mount is refused"; else fail "U22/B2 decision (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -2)"; fi
P="$(newproj l122)"; mkdir -p "$P/skill"; cp -R "$ROOT/scripts" "$P/skill/scripts"; cp -R "$ROOT/assets" "$P/skill/assets"
set +e; LOUT="$(cd "$P" && TMPDIR="$X22/tmp" "$P/skill/scripts/loop.sh" analyze --max-retries 0 --devcontainer-mount "$X22" -- bash -c 'true' _ 2>&1)"; LRC=$?; set -e
snap="$(grep -o 'snapshot [^ ]*' <<<"$LOUT" | head -1 | awk '{print $2}' || true)"
if [[ "$LRC" -eq 0 && -n "$snap" && "$snap" != "$X22"/* ]] && ! compgen -G "$X22/tmp/wgm-*" >/dev/null; then pass "U22/B2: the trusted-runner snapshot avoids an approved extra mount (TMPDIR inside it falls back)"; else fail "U22/B2 snapshot (rc=$LRC snap='$snap'): $(grep -v dropped <<<"$LOUT" | tail -2)"; fi
# B3: ONE overlap policy at preflight too: nested extra mounts are refused
mkdir -p "$TMP/nest22/inner"
pf "$P" --agent-cmd bash --devcontainer-mount "$TMP/nest22" --devcontainer-mount "$TMP/nest22/inner"
if [[ "$RC" -eq 2 ]] && has "overlap" "$ERR"; then pass "U22/B3: nested/overlapping extra mounts are refused at preflight (one overlap policy)"; else fail "U22/B3 (rc=$RC): $ERR"; fi
# B5/C6: a CLI under an OS-owned prefix is never mounted (even under /usr/local), and says so; readiness proves it inside
mkdir -p "$TMP/fakeusr"
pf "$P" --agent-cmd bash
if ! grep -Eq '^mount=(/usr|/bin|/sbin|/lib)' <<<"$OUTO" && has "OS-owned prefix" "$ERR"; then pass "U22/C6: a CLI under /usr or /bin is never mounted (visible note; the image must provide it)"; else fail "U22/C6: $OUTO / $ERR"; fi
# approval fixtures: a canonical token-target change and a config-directory symlink both force re-approval (headless exit 2)
P="$(newproj l123)"; mkstub "$TMP/stubs/gh22" gh 'echo gh'
mkdir -p "$HOME/.config/gh" "$TMP/tokA" "$TMP/tokB"; echo a > "$TMP/tokA/hosts.yml"; echo b > "$TMP/tokB/hosts.yml"
ln -sf "$TMP/tokA/hosts.yml" "$HOME/.config/gh/hosts.yml"
PATH="$TMP/stubs/gh22/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd bash; RECF="$(rec_of)"
mkdir -p "$(dirname "$RECF")"; chmod 700 "$(dirname "$RECF")"
{ echo "engine_declined: false"; echo "declined_at: "; echo "agents: gh"; echo "image: "; echo "tokens:"; echo "  - $TMP/tokA/hosts.yml"; echo "copies:"; echo "  - $(readlink -f "$HOME/.config/gh")"; echo "mounts:"; echo "env:"; } > "$RECF"; chmod 600 "$RECF"
PATH="$TMP/stubs/gh22/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd gh; ok_same=$RC
ln -sf "$TMP/tokB/hosts.yml" "$HOME/.config/gh/hosts.yml"
PATH="$TMP/stubs/gh22/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd gh; tgt=$RC; has "not approved" "$ERR" && tgtm=1 || tgtm=0
# U43: retarget to a DANGLING file while the old approved target stays readable → still no silent pass
ln -sf "$TMP/tokMissing/hosts.yml" "$HOME/.config/gh/hosts.yml"
PATH="$TMP/stubs/gh22/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd gh; dang=$RC; dangerr="$ERR"
rm -f "$HOME/.config/gh/hosts.yml"
PATH="$TMP/stubs/gh22/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd gh; gone=$RC; goneerr="$ERR"
ln -sf "$TMP/tokMissing/hosts.yml" "$HOME/.config/gh/hosts.yml"
pty 'n\n' "cd '$P' && PATH='$TMP/stubs/gh22/bin:$STUBPATH' '$SB' preflight --interactive yes --agent-cmd gh"; askn=$RC; askout="$OUTO"
pty 'y\n' "cd '$P' && PATH='$TMP/stubs/gh22/bin:$STUBPATH' '$SB' preflight --interactive yes --agent-cmd gh"; asky=$RC; askyout="$OUTO"
if [[ "$dang" -eq 2 && "$gone" -eq 2 ]] && has "$TMP/tokMissing/hosts.yml" "$dangerr" && has "no longer the target of any configured token path" "$dangerr" && has "$TMP/tokA/hosts.yml" "$dangerr" && has "no longer the target" "$goneerr" \
   && has "credentials not approved" "$askout" && ! has "sandbox=on" "$askout" && has "sandbox=on" "$askyout" && ! grep -q "tokA/hosts.yml" "$RECF" && { PATH="$TMP/stubs/gh22/bin:$STUBPATH" pf "$P" --agent-cmd gh >/dev/null; t2="$(grep '\[2/3\]' <<<"$ERR")"; has "[2/3]" "$t2" && ! has "token file" "$t2" && ! has "tokA" "$t2"; }; then
  pass "U43: a token path retargeted to a DANGLING file (old target still readable), or removed, forces re-approval (headless exit 2 naming the path and the old token; interactive asks — declining stops, approving drops it from the record); readiness never claims it"
else fail "U43 dangling/removed token (rc=$dang/$gone ask=$askn/$asky): [$dangerr] [$goneerr] [$(tail -3 <<<"$askout")] rec=$(tr '\n' ' ' < "$RECF")"; fi
ln -sf "$TMP/tokA/hosts.yml" "$HOME/.config/gh/hosts.yml"
{ echo "engine_declined: false"; echo "declined_at: "; echo "agents: gh"; echo "image: "; echo "tokens:"; echo "  - $TMP/tokA/hosts.yml"; echo "copies:"; echo "  - $(readlink -f "$HOME/.config/gh")"; echo "mounts:"; echo "env:"; } > "$RECF"; chmod 600 "$RECF"
mv "$HOME/.config/gh" "$HOME/.config/gh.real"; ln -s "$HOME/.config/gh.real" "$HOME/.config/gh"
PATH="$TMP/stubs/gh22/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd gh; dirsym=$RC; has "not approved" "$ERR" && dsm=1 || dsm=0
rm -f "$HOME/.config/gh"; mv "$HOME/.config/gh.real" "$HOME/.config/gh"; rm -rf "$HOME/.config/gh"
if [[ "$ok_same" -eq 0 && "$tgt" -eq 2 && "$tgtm" -eq 1 && "$dirsym" -eq 2 && "$dsm" -eq 1 ]]; then pass "U22/B4: a changed canonical token target, and a config directory that became a symlink, each force re-approval (exit 2 headless)"; else fail "U22/B4 approval fixtures (same=$ok_same target=$tgt/$tgtm dirlink=$dirsym/$dsm)"; fi

# ---- U28 ---------------------------------------------------------------------------------------------------------
# B4: STATIC COMPLETENESS — every external command the owned scripts can run (helper and fallback paths included) is in
# the host-tool inventory (SB_BOUND_TOOLS). The scanner finds words at command position (comments, heredocs and quoted
# text stripped; bash builtins, keywords and the scripts' own functions excluded) that resolve to an external file.
cat > "$TMP/scan-cmds.py" <<'PYSCAN'
import re, sys
files = sys.argv[1:]
BUILTINS = set("""alias bg bind break builtin caller cd command compgen complete compopt continue declare dirs disown echo enable eval exec exit export false fc fg getopts hash help history jobs kill let local logout mapfile popd printf pushd pwd read readarray readonly return set shift shopt source suspend test times trap true type typeset ulimit umask unalias unset wait : . [ [[ ]] ]]""".split())
KEYWORDS = set("if then else elif fi case esac for select while until do done in function time { } ! (( ))".split())
src = {f: open(f).read() for f in files}
funcs = set()
for t in src.values():
    for m in re.finditer(r'^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_:.-]*)\s*\(\)\s*\{', t, re.M):
        funcs.add(m.group(1))
def strip(t):
    out=[]; i=0; n=len(t); inheredoc=None
    lines=t.split('\n'); res=[]
    for ln in lines:
        if inheredoc is not None:
            if ln.strip()==inheredoc: inheredoc=None
            continue
        m=re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", ln)
        s=ln
        # drop full-line comments
        if re.match(r'^\s*#', s): continue
        res.append(s)
        if m: inheredoc=m.group(2)
    return '\n'.join(res)
found={}
for f,t in src.items():
    t=strip(t)
    # remove quoted strings and comments crudely, but keep $( ... ) contents: replace quoted text except $(...) segments
    # tokenise by scanning
    s=t; i=0; n=len(s); cur=[]; 
    # build a version where single-quoted strings are blanked, double-quoted strings keep $(...) only
    out=[]; 
    while i<n:
        c=s[i]
        if c=="'":
            j=s.find("'",i+1); j=n-1 if j<0 else j
            out.append(' '); i=j+1; continue
        if c=='"':
            j=i+1; buf=[]
            while j<n and s[j]!='"':
                if s[j]=='\\': j+=2; continue
                if s[j]=='$' and j+1<n and s[j+1]=='(':
                    depth=0; k=j+1
                    while k<n:
                        if s[k]=='(': depth+=1
                        elif s[k]==')':
                            depth-=1
                            if depth==0: break
                        k+=1
                    buf.append(s[j:k+1]); j=k+1; continue
                j+=1
            out.append(' '+' '.join(buf)+' '); i=j+1; continue
        if c=='#' and (i==0 or s[i-1] in ' \t\n;('): 
            j=s.find('\n',i); j=n if j<0 else j
            i=j; continue
        out.append(c); i+=1
    s=''.join(out)
    # command-position words
    for m in re.finditer(r'(?:^|[;&|(`{]|\$\()\s*(?:(?:then|do|else|elif|if|while|until|time|!)\s+)*((?:[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=\S*\s+)*)([A-Za-z0-9_./~${}\[\]:@%+-][^\s;&|()<>"`]*)', s, re.M):
        w=m.group(2)
        if w in BUILTINS or w in KEYWORDS or w in funcs: continue
        if w.startswith('$') or w.startswith('${') or '=' in w: continue
        if w.startswith('-') or w.isdigit(): continue
        if re.match(r'^[A-Za-z_][A-Za-z0-9_]*\+?=',w): continue
        found.setdefault(w,set()).add(f)
for w in sorted(found): print(w, ','.join(sorted(x.split('/')[-1] for x in found[w])))
PYSCAN
scan_externals() { python3 "$TMP/scan-cmds.py" "$@" | while read -r w _; do type -P "$w" >/dev/null 2>&1 && printf '%s\n' "$w"; done; }
# words that are NOT commands (case-pattern labels / agent names / option values the heuristic also sees)
NONCMD=" init pi copilot claude codex mount yes "
missing=""
while read -r w; do
  [[ "$NONCMD" == *" $w "* ]] && continue
  sb_has "$w" "${SB_BOUND_TOOLS[@]}" || missing+="$w "
done < <(scan_externals "$ROOT/scripts/sandbox.sh" "$ROOT/scripts/loop.sh" "$ROOT/scripts/devcontainer.sh" "$ROOT/scripts/harvest-hive.sh" "$ROOT/scripts/swarm-parent-guard.sh" | sort -u)
# positive control: a script that runs cksum/sha1sum at command position is flagged against an inventory that lacks them
# shellcheck disable=SC2016  # the fixture script text is meant literally
printf '#!/usr/bin/env bash\nif command -v sha1sum >/dev/null; then sha1sum "$1" | awk "{print 1}"\nelse cksum "$1"; fi\n' > "$TMP/scan-fixture.sh"
ctl="$(scan_externals "$TMP/scan-fixture.sh" | tr '\n' ' ')"
if [[ -z "$missing" && "$ctl" == *sha1sum* && "$ctl" == *cksum* ]]; then pass "U28/B4: every external command at command position in loop.sh/sandbox.sh/devcontainer.sh is in the host-tool inventory (scanner control: it finds sha1sum and cksum)"; else fail "U28/B4: missing from SB_BOUND_TOOLS: [$missing] (scanner control saw: $ctl)"; fi
# B3(a): a missing APPROVED token refuses with the record path, the exact token line and the recovery
P="$(newproj l130)"; mkstub "$TMP/stubs/pi28" pi 'echo pi'
PATH="$TMP/stubs/pi28/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd pi; RECF="$(rec_of)"
mkdir -p "$(dirname "$RECF")"; chmod 700 "$(dirname "$RECF")"
{ echo "engine_declined: false"; echo "declined_at: "; echo "agents: pi"; echo "image: "; echo "tokens:"; echo "  - $TMP/gone28/auth.json"; echo "copies:"; echo "mounts:"; echo "env:"; } > "$RECF"; chmod 600 "$RECF"
PATH="$TMP/stubs/pi28/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd pi
if [[ "$RC" -eq 2 ]] && has "$RECF" "$ERR" && has "'  - $TMP/gone28/auth.json'" "$ERR" && has "remove that exact line" "$ERR" && has "--interactive yes" "$ERR"; then
  pass "U28/B3(a): a missing approved token refuses naming the record path, the exact token line and the recovery"
else fail "U28/B3(a) (rc=$RC): $ERR"; fi

# ---- U29: ONE in-process VALUE filter against each invocation's CURRENT writable roots, on every entry path -----------
P="$(newproj l140)"; mkdir -p "$P/dcfg"; printf '[engine]\n' > "$P/containers.conf"
# standalone preflight
DOCKER_CONFIG="$P/dcfg" CONTAINERS_CONF="$P/containers.conf" pf "$P" --dry-run --agent-cmd bash
if [[ "$RC" -eq 0 ]] && has "dropped DOCKER_CONFIG" "$ERR" && has "dropped CONTAINERS_CONF" "$ERR" && has "lies inside the writable mount" "$ERR"; then pass "U29: preflight drops and reports engine/config variables whose value points into the project"; else fail "U29 preflight (rc=$RC): $ERR"; fi
# a lane-style loop that INHERITS a clean environment (WGM_HOST_ENV_CLEAN=1 skips the re-exec): the value pointing into ITS OWN tree is dropped and reported before the engine
rm -f "$TMP/hostenv40"
DOCKER_CONFIG="$P/dcfg" CONTAINERS_STORAGE_CONF="$P/dcfg/storage.conf" WGM_HOST_ENV_CLEAN=1 WGM_DEBUG_HOST_ENV="$TMP/hostenv40" lp "$P" analyze --max-retries 0 -- bash -c 'true' _
if [[ "$LRC" -eq 0 ]] && has "dropped DOCKER_CONFIG" "$LOUT" && has "dropped CONTAINERS_STORAGE_CONF" "$LOUT" && [[ -s "$TMP/hostenv40" ]] && ! grep -qx 'DOCKER_CONFIG\\|CONTAINERS_STORAGE_CONF' "$TMP/hostenv40"; then
  pass "U29: a lane-style loop with an inherited clean environment drops and reports values pointing into its own tree before any engine use"
else fail "U29 inherited-clean loop (rc=$LRC): $(grep -v 'dropped [A-Z_]*$' <<<"$LOUT" | tail -3)"; fi

# ---- U30 ---------------------------------------------------------------------------------------------------------
# B1(a): the executable-config pin is verified WITHOUT git: after the agent appends an include line to .git/config no host
# git call may precede the exit-2 verdict (git shim log shared with the agent's marker line); trust-lost is recorded.
P="$(newproj l150)"; : > "$TMP/u30.log"; rm -f "$TMP/u30.lost"
cat > "$TMP/gitshim30" <<SHIM
#!/usr/bin/env bash
echo "GIT \$*" >> "$TMP/u30.log"
exec "$REAL_GIT" "\$@"
SHIM
mkdir -p "$TMP/gs30"; mv "$TMP/gitshim30" "$TMP/gs30/git"; chmod +x "$TMP/gs30/git"
# shellcheck disable=SC2016  # runs in the agent shell
A30='echo AGENT-DONE >> "$WGM_TEST_LOG"; printf "[include]\n path = /tmp/wgm-u30.inc\n" >> .git/config'
WGM_TEST_LOG="$TMP/u30.log" WGM_TRUST_LOST_FILE="$TMP/u30.lost" PATH="$TMP/gs30:$STUBPATH" lp "$P" analyze --max-retries 0 -- bash -c "$A30" _
after="$(awk '/^AGENT-DONE/ { f = 1; next } f' "$TMP/u30.log" | grep -c '^GIT' || true)"
if [[ "$LRC" -eq 2 && "$after" -eq 0 ]] && has "git configuration changed by the agent" "$LOUT" && grep -qx "trust lost $P/.git" "$TMP/u30.lost"; then
  pass "U30/B1(a): a changed executable config (new include line) is caught by the raw digest with ZERO host git calls after the agent ran; trust-lost line written"
else fail "U30/B1(a) (rc=$LRC git-after-agent=$after lost=[$(cat "$TMP/u30.lost" 2>/dev/null)]): $(grep -v dropped <<<"$LOUT" | tail -2)"; fi
# B1(b): pin persistence helpers for swarm: capture once, verify later — git-free, exit 2 + trust-lost on ANY change
PQ="$(newproj l151)"; PF30="$TMP/pin30.txt"
( sb_pin_capture_to "$PF30" "$PQ" )
rc0=0; ( sb_pin_verify_from "$PF30" ) >/dev/null 2>&1 || rc0=$?
printf '[include]\n path = /tmp/wgm-u30b.inc\n' >> "$PQ/.git/config"
rc1=0; ( WGM_TRUST_LOST_FILE="$TMP/u30b.lost" sb_pin_verify_from "$PF30" ) >/dev/null 2>&1 || rc1=$?
if [[ "$rc0" -eq 0 && "$rc1" -eq 2 && "$(stat -c %a "$PF30")" == 600 ]] && grep -qx "trust lost $PQ/.git" "$TMP/u30b.lost"; then
  pass "U30/B1(b): sb_pin_capture_to / sb_pin_verify_from — unchanged passes, a config change exits 2 and appends 'trust lost <git dir>' (file 0600)"
else fail "U30/B1(b) (rc0=$rc0 rc1=$rc1 lost=[$(cat "$TMP/u30b.lost" 2>/dev/null)])"; fi
# B2: an existing approval for ANOTHER agent set must ask again / exit 2 even when this run proposes no credentials
P="$(newproj l152)"; mkstub "$TMP/stubs/claude30" claude 'echo v'
PATH="$TMP/stubs/claude30/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd bash; write_rec "$(rec_of)" "claude" ANTHROPIC_API_KEY
pf "$P" --agent-cmd bash
if [[ "$RC" -eq 2 ]] && has "agent set" "$ERR" && has "'claude'" "$ERR" && has "'bash'" "$ERR"; then pass "U30/B2: an env-only 'claude' approval, then a headless preflight for 'bash' → exit 2 naming the changed agent set"; else fail "U30/B2 headless (rc=$RC): $ERR"; fi
pty 'y\n' "cd '$P' && '$SB' preflight --interactive yes --agent-cmd bash"
if has "differs from this run" "$OUTO" && has "Mount these into the sandbox" "$OUTO" && has "sandbox=on" "$OUTO"; then pass "U30/B2: interactively the changed agent set is asked about and, once approved, the run proceeds"; else fail "U30/B2 interactive: $(tail -4 <<<"$OUTO")"; fi

# ---- U31 ---------------------------------------------------------------------------------------------------------
# B1: the include set is resolved by GIT once at capture (comments, quoting, continuations), stored with the pin, and its
# targets' raw bytes are re-digested at verify with no re-parse and no git: each spelling's target content change → exit 2
# before any host git call after the agent ran.
mkdir -p "$TMP/u31out"
for v in comment quote contin; do
  P="$(newproj "l16$v")"; T31="$TMP/u31out/$v.cfg"; printf '[x]\n' > "$T31"
  case "$v" in
    comment) printf '[include]\n\tpath = %s # trailing comment\n' "$T31" >> "$P/.git/config" ;;
    quote)   printf '[include]\n\tpath = "%s"\n' "$T31" >> "$P/.git/config" ;;
    contin)  printf '[include]\n\tpath = %s\\\n%s\n' "${T31%/*}/" "${T31##*/}" >> "$P/.git/config" ;;
  esac
  : > "$TMP/u31.log"; rm -f "$TMP/u31.lost"
  # shellcheck disable=SC2016  # runs in the agent shell
  A31='echo AGENT-DONE >> "$WGM_TEST_LOG"; printf "[alias]\n x = !touch /tmp/wgm-u31\n" >> "$WGM_TEST_TARGET"'
  WGM_TEST_TARGET="$T31" WGM_TEST_LOG="$TMP/u31.log" WGM_TRUST_LOST_FILE="$TMP/u31.lost" PATH="$TMP/gs30:$STUBPATH" lp "$P" analyze --max-retries 0 -- bash -c "$A31" _
  after="$(awk '/^AGENT-DONE/ { f = 1; next } f' "$TMP/u31.log" | grep -c '^GIT' || true)"
  if [[ "$LRC" -eq 2 && "$after" -eq 0 ]] && has "git configuration changed by the agent" "$LOUT" && [[ -s "$TMP/u31.lost" ]]; then
    pass "U31/B1: a $v include path whose target content the agent changed → exit 2 with zero host git calls after the agent ran"
  else fail "U31/B1 $v (rc=$LRC git-after-agent=$after): $(grep -v dropped <<<"$LOUT" | tail -2)"; fi
done
# the stored include list round-trips through the pin file and capture needs no preflight state
PQ="$(newproj l165)"; T31="$TMP/u31out/rt.cfg"; printf '[x]\n' > "$T31"; printf '[include]\n\tpath = %s # c\n' "$T31" >> "$PQ/.git/config"
( sb_pin_capture_to "$TMP/pin31.txt" "$PQ" )
rc0=0; ( sb_pin_verify_from "$TMP/pin31.txt" ) >/dev/null 2>&1 || rc0=$?
echo '[y]' >> "$T31"; rc1=0; ( sb_pin_verify_from "$TMP/pin31.txt" ) >/dev/null 2>&1 || rc1=$?
if [[ "$rc0" -eq 0 && "$rc1" -eq 2 ]] && grep -qx "INC=$T31" "$TMP/pin31.txt"; then pass "U31/B1: the pin file stores the git-resolved include target (INC=…); changing its content exits 2 at verify"; else fail "U31/B1 roundtrip (rc0=$rc0 rc1=$rc1)"; fi
# B2 helper: preflight itself honours WGM_TRUST_LOST_FILE (its readiness command — the agent CLI — edits the git config)
P="$(newproj l166)"
# shellcheck disable=SC2016  # the stub body runs later
mkstub "$TMP/stubs/claude31" claude 'echo v; printf "[alias]\n y = !touch /tmp/wgm-u31b\n" >> "$WGM_TEST_PROJ/.git/config"'
PATH="$TMP/stubs/claude31/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd claude; write_rec "$(rec_of)" "claude" ANTHROPIC_API_KEY; rm -f "$TMP/u31c.lost"
PATH="$TMP/stubs/claude31/bin:$STUBPATH" WGM_TEST_PROJ="$P" WGM_TRUST_LOST_FILE="$TMP/u31c.lost" ANTHROPIC_API_KEY=x pf "$P" --agent-cmd claude
if [[ "$RC" -eq 2 ]] && has "git configuration changed" "$ERR" && grep -qx "trust lost $P/.git" "$TMP/u31c.lost"; then pass "U31/B2: preflight appends 'trust lost <git dir>' before its integrity-refusal exit 2"; else fail "U31/B2 preflight (rc=$RC lost=[$(cat "$TMP/u31c.lost" 2>/dev/null)]): $ERR"; fi

# R1: the gates file is read through the no-follow guard: a readiness command swaps wgm.yml for a symlink to an outside
# canary → exit 2 naming it, and (strace -y observer, with positive control) the canary is never opened
P="$(newproj l167)"; printf 'gates:\n  - true\n' > "$P/wgm.yml"; printf 'gates:\n  - echo CANARY-LEAK\n' > "$TMP/canary31.yml"
# shellcheck disable=SC2016  # the stub body runs later
mkstub "$TMP/stubs/claude32" claude 'echo v; rm -f "$WGM_TEST_PROJ/wgm.yml"; ln -s "$WGM_TEST_CANARY" "$WGM_TEST_PROJ/wgm.yml"'
PATH="$TMP/stubs/claude32/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd claude; write_rec "$(rec_of)" "claude" ANTHROPIC_API_KEY
if [[ "$have_strace" -eq 1 ]]; then
  printf 'x\n' > "$TMP/ctl31.txt"; strace -f --seccomp-bpf -y -e trace=openat -o "$TMP/ctl31.st" cat "$TMP/ctl31.txt" >/dev/null 2>&1 || true
  rm -f "$P/wgm.yml"; printf 'gates:\n  - true\n' > "$P/wgm.yml"
  set +e; ( cd "$P" && PATH="$TMP/stubs/claude32/bin:$STUBPATH" WGM_TEST_PROJ="$P" WGM_TEST_CANARY="$TMP/canary31.yml" ANTHROPIC_API_KEY=x strace -f --seccomp-bpf -y -e trace=openat -o "$TMP/gates31.st" "$LOOP" analyze --max-retries 0 --agent claude 2>&1 ) > "$TMP/gates31.out"; GRC=$?; set -e
  if grep -q 'ctl31.txt' "$TMP/ctl31.st" && [[ "$GRC" -eq 2 ]] && ! grep -q 'canary31.yml' "$TMP/gates31.st" && ! grep -q CANARY-LEAK "$TMP/gates31.out" && has "gates file refused" "$(<"$TMP/gates31.out")" && has "wgm.yml" "$(<"$TMP/gates31.out")"; then
    pass "R1: a gates file swapped for a symlink to an outside canary during readiness → exit 2 naming it; the canary is never opened (strace -y, positive control seen)"
  else fail "R1 (rc=$GRC ctl=$(grep -c ctl31.txt "$TMP/ctl31.st") canary-opens=$(grep -c canary31.yml "$TMP/gates31.st" || true)): $(grep -v "host env: dropped" "$TMP/gates31.out" | tail -3)"; fi
else echo "skip: no usable strace — skipping the R1 gates-file no-follow observation"; fi
# ---- U32 ---------------------------------------------------------------------------------------------------------
# B1: an include whose path (or resolution chain) lies in a writable mount is REFUSED — a symlink inside the project that
# points at an outside file would otherwise pin only the outside target while the agent retargets the link
P="$(newproj l170)"; mkdir -p "$TMP/u32out"; printf '[x]\n' > "$TMP/u32out/real.cfg"; ln -s "$TMP/u32out/real.cfg" "$P/include.cfg"
git -C "$P" config include.path "$P/include.cfg"
pf "$P" --agent-cmd bash
rcp=$RC; errp="$ERR"
rm -f "$TMP/u32.marker"
# shellcheck disable=SC2016  # runs in the agent shell
lp "$P" analyze --max-retries 0 -- bash -c 'touch "$0"' "$TMP/u32.marker"
rcc=0; ( sb_pin_capture_to "$TMP/pin32.txt" "$P" ) >/dev/null 2>&1 || rcc=$?
if [[ "$rcp" -eq 2 && "$rcc" -eq 2 && "$LRC" -eq 2 && ! -e "$TMP/u32.marker" ]] && has "$P/include.cfg" "$errp" && has "writable mount" "$errp"; then
  pass "U32/B1: an include that is (or goes through) a symlink inside the project is refused naming it — preflight, loop (agent never ran) and pin capture"
else fail "U32/B1 (pf=$rcp loop=$LRC capture=$rcc marker=$([[ -e $TMP/u32.marker ]] && echo yes || echo no)): $errp"; fi
# ...while an operator-owned chain entirely OUTSIDE both roots is still accepted (pinned by its canonical target)
git -C "$P" config include.path "$TMP/u32out/link.cfg"; ln -sf "$TMP/u32out/real.cfg" "$TMP/u32out/link.cfg"; rm -f "$P/include.cfg"
pf "$P" --agent-cmd bash
if [[ "$RC" -eq 0 ]]; then pass "U32/B1: an include chain that stays outside the project and git dir (dotfile-style symlink) is still accepted"; else fail "U32/B1 outside chain (rc=$RC): $ERR"; fi
# B2: an outside XDG base whose wgm/sandbox is a symlink INTO the project → exit 2, no read, no write (headless and interactive)
P="$(newproj l171)"; mkdir -p "$P/recin" "$TMP/u32xdg/wgm"; ln -s "$P/recin" "$TMP/u32xdg/wgm/sandbox"
XDG_CONFIG_HOME="$TMP/u32xdg" pf "$P" --agent-cmd bash
rch=$RC; errh="$ERR"
pty 'y\n' "cd '$P' && XDG_CONFIG_HOME='$TMP/u32xdg' '$SB' preflight --interactive yes --agent-cmd bash"
if [[ "$rch" -eq 2 ]] && has "effective sandbox record directory" "$errh" && has "$P/recin" "$errh" && [[ -z "$(ls -A "$P/recin")" ]] && ! has "sandbox=on" "$OUTO"; then
  pass "U32/B2: the canonical record directory (an XDG-outside base with an inward symlink) is refused naming it before any record load or save"
else fail "U32/B2 (rc=$rch files=[$(ls -A "$P/recin")]): $errh"; fi

# ---- U33 ---------------------------------------------------------------------------------------------------------
# B1: an include resolved STEP BY STEP — outside alias → writable dir → writable symlink → outside file passes a
# lexical-plus-final-target check but the agent can retarget the writable hop: refused naming the first hop
P="$(newproj l180)"; O33="$TMP/u33o"; mkdir -p "$O33" "$P/includes"; printf '[x]\n' > "$O33/original.cfg"
ln -s "$O33/original.cfg" "$P/includes/current.cfg"; ln -s "$P/includes" "$O33/alias"
git -C "$P" config include.path "$O33/alias/current.cfg"
pf "$P" --agent-cmd bash
rcp=$RC; errp="$ERR"
rm -f "$TMP/u33.marker"
# shellcheck disable=SC2016  # runs in the agent shell
lp "$P" analyze --max-retries 0 -- bash -c 'touch "$0"' "$TMP/u33.marker"
rcc=0; ( sb_pin_capture_to "$TMP/pin33.txt" "$P" ) >/dev/null 2>&1 || rcc=$?
if [[ "$rcp" -eq 2 && "$rcc" -eq 2 && "$LRC" -eq 2 && ! -e "$TMP/u33.marker" ]] && has "$O33/alias" "$errp" && has "passes through a writable mount" "$errp"; then
  pass "U33/B1: an outside→inside→outside include chain is refused naming the first hop — preflight, loop (agent never ran) and capture"
else fail "U33/B1 (pf=$rcp loop=$LRC capture=$rcc): $errp"; fi
# B2: relative values resolved against the cwd; TZ (also :path) and other path-bearing retained variables are filtered
P="$(newproj l181)"; mkdir -p "$P/x" "$P/zone"
DOCKER_CONFIG=./x TZ="$P/zone" pf "$P" --agent-cmd bash
r1=$RC; e1="$ERR"
TZ=":$P/zone" CONTAINERS_CONF=x/c.conf pf "$P" --agent-cmd bash
r2=$RC; e2="$ERR"
TZ=Europe/Paris LANG=C.UTF-8 pf "$P" --agent-cmd bash
r3=$RC; e3="$ERR"
if [[ "$r1" -eq 0 && "$r2" -eq 0 && "$r3" -eq 0 ]] && has "dropped DOCKER_CONFIG" "$e1" && has "dropped TZ" "$e1" && has "dropped TZ" "$e2" && has "dropped CONTAINERS_CONF" "$e2" && ! has "dropped TZ" "$e3" && ! has "dropped LANG" "$e3"; then
  pass "U33/B2: a relative DOCKER_CONFIG/CONTAINERS_CONF, TZ=/project/zone and TZ=:/project/zone resolving into the project are dropped and reported; plain TZ/LANG names are kept"
else fail "U33/B2 (rc=$r1/$r2/$r3): [$e1] [$e2] [$e3]"; fi

# ---- U34 ---------------------------------------------------------------------------------------------------------
# B1: an argv-supplied executable is an OPAQUE pathname (identity = basename of the whole path; discovery/readiness get
# the whole path); only shell-command TEXT is split, with shell-word semantics
P="$(newproj l190)"; O34="$TMP/bin tools"; mkdir -p "$O34" "$P/bin tools"
# shellcheck disable=SC2016  # stub bodies run later
for d in "$O34" "$P/bin tools"; do printf '#!/usr/bin/env bash\necho "ran:$0 $*" >> "$WGM_TEST_MARK"\necho v\n' > "$d/pi"; chmod +x "$d/pi"; done
mkdir -p "$HOME/.pi/agent"; printf '{}\n' > "$HOME/.pi/agent/auth.json"; chmod 600 "$HOME/.pi/agent/auth.json"
pf "$P" --dry-run --agent-exe "$O34/pi"
if [[ "$RC" -eq 2 ]] && has "pi" "$ERR" && has ".pi/agent/auth.json" "$ERR" && ! has "(bin)" "$ERR"; then pass "U34/B1: an absolute executable whose path has a space is identified as 'pi' and pi's credentials are proposed"; else fail "U34/B1 absolute (rc=$RC): $ERR"; fi
rm -rf "$HOME/.pi"
pf "$P" --dry-run --agent-exe "$O34/pi"; write_rec "$(rec_of)" "pi"
: > "$TMP/u34.mark"
WGM_TEST_MARK="$TMP/u34.mark" pf "$P" --agent-exe "$O34/pi"
r1=$RC; o1="$OUTO"
WGM_TEST_MARK="$TMP/u34.mark" pf "$P" --agent-exe "./bin tools/pi"
r2=$RC; o2="$OUTO"
if [[ "$r1" -eq 0 && "$r2" -eq 0 ]] && has "agent=pi" "$o1" && has "agent=pi" "$o2" && grep -qF "ran:$O34/pi --version" "$TMP/u34.mark" && grep -q "ran:./bin tools/pi --version" "$TMP/u34.mark"; then
  pass "U34/B1: absolute and relative executables with spaces → agent=pi and the readiness probe ran the configured executable itself"
else fail "U34/B1 readiness (rc=$r1/$r2): $(cat "$TMP/u34.mark") // $ERR"; fi
# shell-command TEXT is still split like the shell does
pf "$P" --dry-run --agent-cmd "'$O34/pi' -p --flag"
a1="$OUTO"; pf "$P" --dry-run --agent-cmd "pi -p"; a2="$OUTO"; pf "$P" --dry-run --agent-cmd "\"$O34/pi\" -p"; a3="$OUTO"
pf "$P" --dry-run --agent-cmd "$O34/pi -p"; a4="$OUTO"
if has "agent=pi" "$a1" && has "agent=pi" "$a2" && has "agent=pi" "$a3" && ! has "agent=pi" "$a4"; then pass "U34/B1: a WGM_AGENT-style string keeps shell-word semantics (quoted path with a space → pi; an unquoted space ends the word)"; else fail "U34/B1 text: [$a1] [$a2] [$a3] [$a4]"; fi
# the loop passes argv[0] as an opaque executable
rm -f "$TMP/u34.mark2"
WGM_TEST_MARK="$TMP/u34.mark" lp "$P" analyze --max-retries 0 -- "$O34/pi" -p
if [[ "$LRC" -eq 0 ]] && grep -qF "ran:$O34/pi -p" "$TMP/u34.mark"; then pass "U34/B1: loop.sh -- \"<path with space>/pi\" is preflighted as 'pi' and executed"; else fail "U34/B1 loop (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi

# ---- U35 ---------------------------------------------------------------------------------------------------------
# B1: help / usage / early-exit paths run BEFORE the allowlist and host-tool binding, so they use bash builtins only. A
# logging shim for every common external first on PATH (the shape of a project bin/ first on PATH) must never run on
# those paths; positive control: the same shims DO log when called.
SH35="$TMP/shim35"; mkdir -p "$SH35"; P="$(newproj l200)"
for t in awk sed grep cat date dirname basename readlink mktemp stat find sort tr head tail cut wc env id uname ls rm mkdir touch git podman docker; do
  printf '#!/bin/sh\necho %s >> "%s/LOG"\n: > "%s/SENTINEL"\nexit 0\n' "$t" "$SH35" "$SH35" > "$SH35/$t"; chmod +x "$SH35/$t"
done
: > "$SH35/LOG"; PATH="$SH35:$PATH" awk x; ctl35=$(wc -l < "$SH35/LOG")
rm -f "$SH35/LOG" "$SH35/SENTINEL"; : > "$SH35/LOG"; bad35=""; shown35=0
for c in "$LOOP --help" "$LOOP --bogus-flag" "$LOOP --container zz" "$LOOP --max-retries x" "$DC --help" "$DC" "$DC zz" "$DC run --bogus" "$DC run --help" "$SB --help" "$SB"; do
  read -r -a c35 <<<"$c"
  set +e; out35="$(cd "$P" && PATH="$SH35:$PATH" bash "${c35[@]}" 2>&1)"; set -e
  case "$c" in *"--help"*) [[ "$out35" == *Usage* || "$out35" == *usage* || "$out35" == *"--"* ]] && shown35=$((shown35 + 1)) ;; esac
  [[ -s "$SH35/LOG" ]] && { bad35+="[$c ran: $(tr '\n' ' ' < "$SH35/LOG")] "; : > "$SH35/LOG"; }
done
if [[ "$ctl35" -eq 1 && -z "$bad35" && ! -e "$SH35/SENTINEL" && "$shown35" -ge 4 ]]; then
  pass "U35/B1: --help, usage and early-exit paths of loop.sh, devcontainer.sh and sandbox.sh run no external command (shim control seen; help printed)"
else fail "U35/B1 (control=$ctl35 help-shown=$shown35): $bad35"; fi
# static guard: no usage definition may reintroduce an external reader
if ! grep -nE '^[[:space:]]*usage\(\)[^#]*\b(awk|sed|cat|head|grep)\b' "$LOOP" "$DC" "$SB" >/dev/null && ! grep -nE '^[[:space:]]*-h\|--help[^#]*\b(awk|sed|cat|head)\b' "$SB" >/dev/null; then
  pass "U35/B1: no usage()/--help definition in the three scripts calls awk/sed/cat/head/grep"
else fail "U35/B1: a usage definition calls an external reader"; fi

# ---- U36 ---------------------------------------------------------------------------------------------------------
# B1: the no-follow guard covers EVERY agent-writable root — here a worktree's EXTERNAL git common dir: the agent plants
# <common>/wgm-state/metrics.tsv as a symlink to an outside non-existent file; the host must refuse, not create it
M36="$(newproj l210)"; W36="$TMP/wt36"; git -C "$M36" worktree add -q -b wt36 "$W36" >/dev/null 2>&1
C36="$(git -C "$M36" rev-parse --absolute-git-dir)"; OUT36="$TMP/u36out"; mkdir -p "$OUT36"; rm -f "$OUT36/created.tsv"
# shellcheck disable=SC2016  # runs in the agent shell
A36='mkdir -p "$0/wgm-state" && ln -sf "$1" "$0/wgm-state/metrics.tsv"'
lp "$W36" analyze --max-retries 0 --metrics "$C36/wgm-state/metrics.tsv" -- bash -c "$A36" "$C36" "$OUT36/created.tsv"
if [[ "$LRC" -eq 2 && ! -e "$OUT36/created.tsv" ]] && has "agent-written symlink" "$LOUT"; then
  pass "U36/B1: a metrics file under a worktree's EXTERNAL git common dir that the agent made a symlink → exit 2, the outside target is never created"
else fail "U36/B1 (rc=$LRC created=$([[ -e $OUT36/created.tsv ]] && echo yes || echo no)): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
# a destination that reaches a writable root only through a link OUTSIDE it cannot be guarded component by component → refused
ln -sfn "$C36/wgm-state" "$TMP/alias36"; rm -f "$C36/wgm-state/metrics.tsv"
lp "$W36" analyze --max-retries 0 --metrics "$TMP/alias36/metrics.tsv" -- bash -c true
if [[ "$LRC" -eq 2 ]] && has "agent-writable root" "$LOUT" && [[ ! -e "$C36/wgm-state/metrics.tsv" ]]; then pass "U36/B1: a host destination inside a writable root reached through an outside symlink is refused (cannot be guarded)"; else fail "U36/B1 alias (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
# control: a regular metrics file under the external common dir still works
rm -rf "$C36/wgm-state"
lp "$W36" analyze --max-retries 0 --metrics "$C36/wgm-state/metrics.tsv" -- bash -c true
if [[ "$LRC" -eq 0 && -s "$C36/wgm-state/metrics.tsv" ]]; then pass "U36/B1 control: a regular metrics file under the external common dir is still written"; else fail "U36/B1 control (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi

# ---- U37 ---------------------------------------------------------------------------------------------------------
# B2: DOCKER_CONTEXT (retained) is value-filtered: a path-valued selection inside the project, and a context NAME whose
# store ${DOCKER_CONFIG:-$HOME/.docker}/contexts lies inside a writable root, are dropped and reported
P="$(newproj l220)"; mkdir -p "$P/ctx"
DOCKER_CONTEXT="./ctx/evil" pf "$P" --agent-cmd bash
e1="$ERR"; r1=$RC
# (HOME inside the project is already a mount-policy refusal end to end, so the context-store rule is exercised on the filter itself)
# shellcheck disable=SC2016  # the bash -c bodies are single-quoted on purpose
e2="$(env -u DOCKER_CONFIG HOME="$P/hm" DOCKER_CONTEXT=mine bash -c 'source "$1"; SB_WRITABLE=("$2"); sb_filter_env_values; echo "left=${DOCKER_CONTEXT:-gone}"' _ "$SB" "$P" 2>&1)"; r2=0
DOCKER_CONTEXT="mine" pf "$P" --agent-cmd bash
e3="$ERR"; r3=$RC
if [[ "$r1" -eq 0 && "$r2" -eq 0 && "$r3" -eq 0 ]] && has "dropped DOCKER_CONTEXT" "$e1" && has "dropped DOCKER_CONTEXT" "$e2" && has "context store" "$e2" && has "left=gone" "$e2" && ! has "dropped DOCKER_CONTEXT" "$e3"; then
  pass "U37/B2: DOCKER_CONTEXT as a path into the project, or a name whose context store lies in a writable root, is dropped and reported; a plain name with an outside store is kept"
else fail "U37/B2 (rc=$r1/$r2/$r3): [$e1] [$e2] [$e3]"; fi
# allowlist completeness: EVERY variable either allowlist retains is value-filtered (SB_ENV_PATHVARS / SB_ENV_NAMEVARS) or
# explicitly justified (SB_ENV_JUSTIFIED, LC_*, WGM_*, approved credential names) — statically over both case tables and
# dynamically over the in-process allowlist with a broad candidate set exported
cand37="$(sed -n '/^sb_env_allowlist_inproc() {/,/^}/p;/^sb_clean_env_exec() {/,/^}/p' "$SB" | grep -E '^[[:space:]]+[A-Za-z_*|0-9]+\)' | sed -E 's/\).*//' | tr '|' '\n' | tr -d ' ' | grep -E '^[A-Z_][A-Z0-9_]*$' | sort -u || true)"
union37=" $(bash -c 'source "$1"; echo "${SB_ENV_PATHVARS[*]} ${SB_ENV_NAMEVARS[*]} ${SB_ENV_JUSTIFIED[*]}"' _ "$SB") "
unc37=""; for n in $cand37; do
  case "$n" in WGM_*|LC_*) continue ;; esac
  [[ "$union37" == *" $n "* ]] || unc37+="$n "
done
extra37="DOCKER_CONTEXT DOCKER_BUILDKIT BUILDAH_ISOLATION CONTAINER_CONNECTION REGISTRY_AUTH_FILE XDG_CACHE_HOME XDG_STATE_HOME XDG_DATA_DIRS XDG_CONFIG_DIRS SSL_CERT_FILE SSL_CERT_DIR TERMINFO TERMINFO_DIRS LOCPATH NLSPATH GCONV_PATH LD_PRELOAD LD_LIBRARY_PATH BASH_ENV ENV SHELL EDITOR PAGER GIT_DIR PYTHONPATH NODE_OPTIONS"
IFS=$' \n' read -r -d '' -a names37 <<<"$cand37 $extra37" || true
# shellcheck disable=SC2016  # (single-quoted bash -c body)
surv37="$(env -i PATH="$PATH" HOME="$HOME" bash -c 'source "$1"; shift; for n in "$@"; do export "$n=/x/$n"; done; export LC_ALL=C TZ=UTC; WGM_HOST_ENV_QUIET=1 sb_env_allowlist_inproc; compgen -e' _ "$SB" "${names37[@]}")"
unj37=""; for n in $surv37; do
  case "$n" in WGM_*|LC_*) continue ;; esac
  [[ "$union37" == *" $n "* ]] || unj37+="$n "
done
if [[ -z "$unc37" && -z "$unj37" && "$surv37" == *TZ* && "$surv37" == *DOCKER_CONTEXT* ]]; then
  pass "U37/B2: every variable the allowlists retain is value-filtered or explicitly justified (static table + dynamic survivors; DOCKER_CONTEXT is in the filter)"
else fail "U37/B2 inventory (uncovered-in-table=[$unc37] uncovered-survivors=[$unj37])"; fi

# ---- U38 ---------------------------------------------------------------------------------------------------------
# B1: the forced + no-engine refusal precedes ANY record consultation: a forced run with no engine AND a bad record
# (group-writable, then symlinked) exits with the engine/install guidance, not the record refusal
P="$(newproj l230)"; PATH="$TMP/stubs/none:$STUBPATH" pf "$P" --dry-run --agent-cmd bash; REC38="$(rec_of)"
write_rec "$REC38" ""; chmod 664 "$REC38"
WGM_STUB_INFO_FAIL=1 pf "$P" --devcontainer
e1="$ERR"; r1=$RC
rm -f "$REC38"; printf 'x\n' > "$TMP/u38.target"; ln -s "$TMP/u38.target" "$REC38"
WGM_STUB_INFO_FAIL=1 pf "$P" --devcontainer
e2="$ERR"; r2=$RC
WGM_STUB_INFO_FAIL=1 pf "$P"
e3="$ERR"; r3=$RC
if [[ "$r1" -eq 2 && "$r2" -eq 2 ]] && has "container engine is required" "$e1" && has "container engine is required" "$e2" && ! has "writable" "$e1" && ! has "symlink" "$e2" && [[ "$r3" -eq 2 ]] && has "symlink" "$e3"; then
  pass "U38/B1: forced + no engine + a group-writable or symlinked record → the engine/install guidance (not the record refusal); the record is still refused when it IS consulted"
else fail "U38/B1 (rc=$r1/$r2/$r3): [$e1] [$e2] [$e3]"; fi
rm -f "$REC38"
# B3 (C10): flock writers and WGM_NO_FLOCK writers contend on ONE interoperable lock — never both inside the critical
# section (shared counter), and the record is always whole
if command -v flock >/dev/null 2>&1; then
  LK38="$TMP/lk38"; mkdir -p "$LK38"; printf '0\n' > "$LK38/counter"; : > "$LK38/viol"
  # shellcheck disable=SC2016  # bash -c bodies, expanded by the child
  crit38='source "$1"; d="$2"
  for i in 1 2 3 4 5; do
    sb_lock_acquire "$d"
    [[ -e "$d/inside" ]] && echo "BOTH $$" >> "$d/viol"
    : > "$d/inside"; v="$(<"$d/counter")"; sleep 0.02; echo $((v + 1)) > "$d/counter"; rm -f "$d/inside"
    sb_lock_release
  done'
  pids38=()
  for k in 1 2 3; do
    bash -c "$crit38" _ "$SB" "$LK38" & pids38+=($!)
    WGM_NO_FLOCK=1 bash -c "$crit38" _ "$SB" "$LK38" & pids38+=($!)
  done
  wait "${pids38[@]}"
  # shellcheck disable=SC2016  # bash -c body, expanded by the child
  recw38='source "$1"; SB_RECORD="$2/rec.yml"; REC_DECLINED=false; REC_DECLINED_AT=""; REC_AGENTS="w$3"; REC_IMAGE=""; REC_TOKENS=(); REC_COPIES=(); REC_MOUNTS=(); REC_ENV=(A B); for i in 1 2 3; do sb_record_save; done'
  pids38=()
  for k in 1 2 3; do
    bash -c "$recw38" _ "$SB" "$LK38" "f$k" & pids38+=($!)
    WGM_NO_FLOCK=1 bash -c "$recw38" _ "$SB" "$LK38" "n$k" & pids38+=($!)
  done
  wait "${pids38[@]}"
  if [[ "$(<"$LK38/counter")" -eq 30 && ! -s "$LK38/viol" ]] && grep -qE '^agents: w[fn][1-3]$' "$LK38/rec.yml" && [[ "$(grep -c '^env:$' "$LK38/rec.yml")" -eq 1 && "$(grep -c '^  - ' "$LK38/rec.yml")" -eq 2 ]] && [[ ! -e "$LK38/.lock.own" ]]; then
    pass "U38/B3: flock and WGM_NO_FLOCK writers exclude each other through .lock.own (30/30 counter increments, never both inside; record whole; no lock left)"
  else fail "U38/B3 (counter=$(<"$LK38/counter") viol=[$(<"$LK38/viol")] rec=$(tr '\n' '|' < "$LK38/rec.yml" 2>/dev/null))"; fi
else echo "skip: no flock on this host — skipping the U38 flock/no-flock interoperability case"; fi

# ---- U40 ---------------------------------------------------------------------------------------------------------
# B1: every configured gate is smoked in EVERY mode — analyze mode with --gates whose gate fails inside the sandbox
P="$(newproj l240)"; printf 'gates:\n  - exit 3\n' > "$P/wgm.yml"
lp "$P" analyze --max-retries 0 -- bash -c true
if [[ "$LRC" -eq 2 ]] && has "sandbox smoke failed: gate [exit 3]" "$LOUT"; then pass "U40/B1: analyze mode smokes the configured gates too (a failing gate stops the run before any iteration)"; else fail "U40/B1 (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
# B2: the three readiness tiers are reported separately, never with a credential value
P="$(newproj l241)"
# shellcheck disable=SC2016  # stub body runs later
mkstub "$TMP/stubs/claude40" claude 'echo v'
PATH="$TMP/stubs/claude40/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd claude; write_rec "$(rec_of)" "claude" ANTHROPIC_API_KEY
ANTHROPIC_API_KEY=SECRET-VALUE-U40 PATH="$TMP/stubs/claude40/bin:$STUBPATH" pf "$P" --agent-cmd claude
if [[ "$RC" -eq 0 ]] && has "readiness [1/3] agent executable available in the container: claude" "$ERR" && has "readiness [2/3] approved credentials reachable" "$ERR" && has "ANTHROPIC_API_KEY" "$(grep '\[2/3\]' <<<"$ERR")" \
   && has "readiness [3/3] provider authentication: NOT verified by wgm" "$ERR" && ! has "SECRET-VALUE-U40" "$ERR$OUTO" && has "sandbox=on" "$OUTO"; then
  pass "U40/B2: preflight reports the three readiness tiers on separate lines (executable / credentials / authentication NOT verified); no credential value; decision output intact"
else fail "U40/B2 (rc=$RC): $ERR"; fi
# B4: the distinct readiness rejection paths — resolving executable exiting 126, exiting 127, and 'exec format error'
for kind in 126 127 fmt; do
  P="$(newproj "l242$kind")"
  case "$kind" in
    126) body='echo "permission denied" >&2; exit 126' ;;
    127) body='echo "not found" >&2; exit 127' ;;
    fmt) body='echo "bash: ./claude: cannot execute binary file: Exec format error" >&2; exit 1' ;;
  esac
  mkstub "$TMP/stubs/rdy$kind" claude "$body"
  PATH="$TMP/stubs/rdy$kind/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd claude; write_rec "$(rec_of)" "claude" ANTHROPIC_API_KEY
  ANTHROPIC_API_KEY=x PATH="$TMP/stubs/rdy$kind/bin:$STUBPATH" pf "$P" --agent-cmd claude
  case "$kind" in 126|127) want="is not executable inside the sandbox (exit $kind)" ;; fmt) want="exec format error" ;; esac
  if [[ "$RC" -eq 2 ]] && has "sandbox readiness failed" "$ERR" && has "agent CLI claude" "$ERR" && has "$want" "$ERR" && has "Fix: install the agent CLI in a project image" "$ERR"; then
    pass "U40/B4: a resolving executable that fails readiness as '$kind' → exit 2, names the failing piece and the project-image recovery"
  else fail "U40/B4 $kind (rc=$RC): $ERR"; fi
done

# ---- U42 ---------------------------------------------------------------------------------------------------------
# B1: /proc/self/mountinfo escapes space, tab, newline AND backslash as octal; ALL are decoded before comparing, so a mount
# point under a bound directory is found whatever characters the paths hold (zero launches)
esc42() { local s="${1//\\/\\134}"; s="${s//$'\t'/\\011}"; s="${s//$'\n'/\\012}"; s="${s// /\\040}"; printf '%s' "$s"; }
P="$(newproj l250)"
XO="$TMP/od\\ir"$'\t'"x"$'\n'"y z"; mkdir -p "$XO/plain" "$XO/we\\ird"$'\t'"sub"
XP="$TMP/plain42"; mkdir -p "$XP"; XD="$XP/de\\ep"$'\t'"s"$'\n'"t"; mkdir -p "$XD"
runs42() { grep -c ' run ' "$WGM_STUB_TRACE" 2>/dev/null || true; }
printf '36 35 98:0 / %s rw - ext3 /dev/x rw\n' "$(esc42 "$TMP/elsewhere\\x")" > "$TMP/mountinfo42"
WGM_MOUNTINFO="$TMP/mountinfo42" pf "$P" --agent-cmd bash --devcontainer-mount "$XO"
rc0=$RC; e0="$ERR"
b42="$(runs42)"
printf '36 35 98:0 / %s rw - ext3 /dev/x rw\n' "$(esc42 "$XO/plain")" > "$TMP/mountinfo42"
WGM_MOUNTINFO="$TMP/mountinfo42" pf "$P" --agent-cmd bash --devcontainer-mount "$XO"
rca=$RC; ea="$ERR"
printf '36 35 98:0 / %s rw - ext3 /dev/x rw\n' "$(esc42 "$XO/we\\ird"$'\t'"sub")" > "$TMP/mountinfo42"
WGM_MOUNTINFO="$TMP/mountinfo42" pf "$P" --agent-cmd bash --devcontainer-mount "$XO"
rcb=$RC; eb="$ERR"
printf '36 35 98:0 / %s rw - ext3 /dev/x rw\n' "$(esc42 "$XD")" > "$TMP/mountinfo42"
WGM_MOUNTINFO="$TMP/mountinfo42" pf "$P" --agent-cmd bash --devcontainer-mount "$XP"
rcc=$RC; ec="$ERR"
if [[ "$rc0" -eq 0 && "$rca" -eq 2 && "$rcb" -eq 2 && "$rcc" -eq 2 && "$(runs42)" == "$b42" ]] && has "mount point" "$ea" && has "mount point" "$eb" && has "mount point" "$ec"; then
  pass "U42/B1: mount points found under a bound dir through escaped space/tab/newline/backslash (in the dir's own path and in the descendant) → exit 2, zero launches; an unrelated escaped mount point is fine"
else fail "U42/B1 (rc=$rc0/$rca/$rcb/$rcc): [$e0] [$ea] [$eb] [$ec]"; fi

# ---- U44 ---------------------------------------------------------------------------------------------------------
# B1: EVERY host git call verifies the captured pins first (pointer contents, then the git-free executable-config digests incl.
# stored include targets): the config (or an include target) changes between two host git calls with NO contained command
# in between (a host-side seam) → the next wgm_host_git call exits 2 before git runs (git shim: zero further calls)
mkdir -p "$TMP/gs44"; : > "$TMP/gs44.log"
printf '#!/usr/bin/env bash\necho "GIT $*" >> "%s"\nexec "%s" "$@"\n' "$TMP/gs44.log" "$REAL_GIT" > "$TMP/gs44/git"; chmod +x "$TMP/gs44/git"
mkdir -p "$TMP/u44out"
for kind in config include hooks; do
  P="$(newproj "l260$kind")"; : > "$TMP/gs44.log"; rm -f "$TMP/u44.lost"
  if [[ "$kind" == include ]]; then printf '[x]\n' > "$TMP/u44out/inc.cfg"; printf '[include]\n\tpath = %s # c\n' "$TMP/u44out/inc.cfg" >> "$P/.git/config"; fi
  r="$(PATH="$TMP/gs44:$PATH" WGM_TRUST_LOST_FILE="$TMP/u44.lost" bash -c '
    source "$1"; P="$2"; kind="$3"; log="$4"
    sb_pin_capture_to "$6" "$P" 2>/dev/null || exit 9
    cd "$P"
    wgm_host_git -C "$P" status --porcelain >/dev/null || exit 8          # call 1: pins intact → runs
    c1=$(wc -l < "$log")
    case "$kind" in
      config)  printf "[alias]\n x = !touch /tmp/wgm-u44\n" >> "$P/.git/config" ;;
      include) printf "[a]\n b = !touch /tmp/wgm-u44b\n" >> "$5" ;;
      hooks)   printf "#!/bin/sh\ntouch /tmp/wgm-u44c\n" > "$P/.git/hooks/pre-commit" ;;
    esac
    rc=0; ( wgm_host_git -C "$P" status --porcelain >/dev/null 2>&1 ) || rc=$?   # call 2: no contained command in between
    echo "rc=$rc c1=$c1 c2=$(wc -l < "$log")"
  ' _ "$SB" "$P" "$kind" "$TMP/gs44.log" "$TMP/u44out/inc.cfg" "$TMP/pin44.txt" 2>&1 | tail -1)"
  if [[ "$r" =~ ^rc=2\ c1=([0-9]+)\ c2=([0-9]+)$ && "${BASH_REMATCH[1]}" -eq "${BASH_REMATCH[2]}" ]] && grep -q "^trust lost " "$TMP/u44.lost"; then
    pass "U44/B1: a $kind change between two host git calls (no contained command) → the next wgm_host_git exits 2 before git runs (zero further git calls; trust-lost line written)"
  else fail "U44/B1 $kind: $r lost=[$(cat "$TMP/u44.lost" 2>/dev/null)]"; fi
done

# ---- U45 ---------------------------------------------------------------------------------------------------------
# B1: the pointer pins are the EXACT bytes (sha256), not newline-normalized text: a trailing newline or a CR appended to a
# pinned pointer file (worktree `.git` file, admin gitdir/commondir) between capture and verify → exit 2 (pointer-first)
P="$(newproj l270)"; res45=""
vrfy45() { local rc=0; ( sb_pin_verify_from "$TMP/pin45.txt" ) >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
for v in git-nl git-cr admin-gitdir-nl admin-commondir-cr; do
  W45="$TMP/wt45-$v"; git -C "$P" worktree add -q "$W45" -b "wt45-$v" >/dev/null 2>&1
  A45="$P/.git/worktrees/wt45-$v"
  ( sb_pin_capture_to "$TMP/pin45.txt" "$W45" ) >/dev/null 2>&1
  ctl45="$(vrfy45)"
  case "$v" in
    git-nl) printf '\n' >> "$W45/.git" ;;
    git-cr) printf '\r' >> "$W45/.git" ;;
    admin-gitdir-nl) printf '\n' >> "$A45/gitdir" ;;
    admin-commondir-cr) printf '\r' >> "$A45/commondir" ;;
  esac
  res45+="$v:$ctl45/$(vrfy45) "
done
if [[ "$res45" == "git-nl:0/2 git-cr:0/2 admin-gitdir-nl:0/2 admin-commondir-cr:0/2 " ]]; then
  pass "U45/B1: a trailing newline or CR appended to a pinned pointer file (worktree .git, admin gitdir, admin commondir) between capture and verify → exit 2 (exact-bytes pins); the unchanged control passes"
else fail "U45/B1 (control/after per case): $res45"; fi

# ---- U47 ---------------------------------------------------------------------------------------------------------
# B1 (the CLASS): every approved record category — token files, config-directory copies, extra mounts, env names — has its
# approved identity validated BEFORE missing-path filtering: a configured path that became a symlink (dangling or not), a
# non-directory/non-regular entry, was retargeted or removed → re-approval (interactive) / exit 2 (headless) naming it
for a47 in claude gh copilot; do mkstub "$TMP/stubs/a47-$a47" "$a47" 'echo v'; done
A47PATH="$TMP/stubs/a47-claude/bin:$TMP/stubs/a47-gh/bin:$TMP/stubs/a47-copilot/bin:$STUBPATH"
RECF47=""
rec47() {  # rec47 PROJECT AGENTS TOKENS COPIES MOUNTS ENVS — '|'-separated lists; (re)writes the approval record
  local P="$1" ag="$2" x
  PATH="$A47PATH" pf "$P" --dry-run --agent-cmd bash; RECF47="$(rec_of)"
  mkdir -p "$(dirname "$RECF47")"; chmod 700 "$(dirname "$RECF47")"
  { echo "engine_declined: false"; echo "declined_at: "; echo "agents: $ag"; echo "image: "
    echo "tokens:"; IFS='|' read -r -a l <<<"$3"; for x in "${l[@]}"; do [[ -n "$x" ]] && echo "  - $x"; done
    echo "copies:"; IFS='|' read -r -a l <<<"$4"; for x in "${l[@]}"; do [[ -n "$x" ]] && echo "  - $x"; done
    echo "mounts:"; IFS='|' read -r -a l <<<"$5"; for x in "${l[@]}"; do [[ -n "$x" ]] && echo "  - $x"; done
    echo "env:"; IFS='|' read -r -a l <<<"$6"; for x in "${l[@]}"; do [[ -n "$x" ]] && echo "  - $x"; done; } > "$RECF47"
  chmod 600 "$RECF47"
}
res47=""; add47() { res47+="$1 "; }
# row runner: run47 LABEL PROJECT AGENT SUBSTRING-EXPECTED-IN-HEADLESS-ERROR [ENVASSIGN…]
run47() {
  local label="$1" P="$2" ag="$3" want="$4"; shift 4
  local rc=0
  # shellcheck disable=SC2016  # bash -c body expanded by the child
  env "$@" PATH="$A47PATH" bash -c 'cd "$1" && "$2" preflight --agent-cmd "$3"' _ "$P" "$SB" "$ag" >/dev/null 2>"$TMP/e47" || rc=$?
  local err; err="$(<"$TMP/e47")"
  if [[ "$rc" -eq 2 && "$err" == *"$want"* ]]; then add47 "$label:refused"; else add47 "$label:FAIL(rc=$rc)[$(grep -v 'host env' <<<"$err" | tail -2 | tr '\n' ' ')]"; fi
}
# (1) config directory (copilot ~/.copilot, no token-file entry): dangling symlink / symlink to another real dir / regular file
mkdir -p "$HOME/.copilot" "$TMP/othercop"; echo cfg > "$HOME/.copilot/settings.json"; echo o > "$TMP/othercop/settings.json"
CANON47="$(readlink -f "$HOME/.copilot")"
for kind in dangling otherdir file; do
  P="$(newproj "l280$kind")"; rec47 "$P" copilot "" "$CANON47" "" ""
  PATH="$A47PATH" pf "$P" --agent-cmd copilot
  if [[ "$RC" -eq 0 ]]; then add47 "copies-$kind:control-ok"; else add47 "copies-$kind:CONTROL-FAIL"; fi
  rm -rf "$HOME/.copilot"
  case "$kind" in dangling) ln -s "$TMP/nonexistent47" "$HOME/.copilot" ;; otherdir) ln -s "$TMP/othercop" "$HOME/.copilot" ;; file) echo notadir > "$HOME/.copilot" ;; esac
  want47="$CANON47"; [[ "$kind" == otherdir ]] && want47="$(readlink -f "$TMP/othercop")"   # (a retarget to another real dir names the NEW directory)
  run47 "copies-$kind" "$P" copilot "$want47"
  # interactive: decline stops; approve proceeds and rewrites the record WITHOUT the stale directory
  pty 'n\n' "cd '$P' && PATH='$A47PATH' '$SB' preflight --interactive yes --agent-cmd copilot"
  if has "credentials not approved" "$OUTO" && ! has "sandbox=on" "$OUTO"; then add47 "copies-$kind:asked-declined"; else add47 "copies-$kind:ASK-FAIL"; fi
  pty 'y\n' "cd '$P' && PATH='$A47PATH' '$SB' preflight --interactive yes --agent-cmd copilot"
  rec_ok47=0
  if has "sandbox=on" "$OUTO"; then
    if [[ "$kind" == otherdir ]]; then grep -qF "$(readlink -f "$TMP/othercop")" "$RECF47" && ! grep -qF "$CANON47" "$RECF47" && rec_ok47=1
    else ! grep -qF "$CANON47" "$RECF47" && rec_ok47=1; fi
  fi
  if [[ "$rec_ok47" -eq 1 ]]; then add47 "copies-$kind:approved"; else add47 "copies-$kind:APPROVE-FAIL"; fi
  rm -rf "$HOME/.copilot"; mkdir -p "$HOME/.copilot"; echo cfg > "$HOME/.copilot/settings.json"
done
rm -rf "$HOME/.copilot"
# (2) token file (gh hosts.yml) → dangling target while the old approved target stays readable
mkdir -p "$HOME/.config/gh" "$TMP/t47"; echo a > "$TMP/t47/hosts.yml"; ln -sf "$TMP/t47/hosts.yml" "$HOME/.config/gh/hosts.yml"
P="$(newproj l280tok)"; rec47 "$P" gh "$TMP/t47/hosts.yml" "$(readlink -f "$HOME/.config/gh")" "" ""
ln -sf "$TMP/t47/missing.yml" "$HOME/.config/gh/hosts.yml"; run47 tokens "$P" gh "$TMP/t47/hosts.yml"
rm -rf "$HOME/.config/gh"
# (3) extra mount recorded in the approval: a directory that became a symlink / vanished
mkdir -p "$TMP/m47/real"; P="$(newproj l280mnt)"; rec47 "$P" claude "" "" "$TMP/m47/real" ""
PATH="$A47PATH" pf "$P" --agent-cmd claude
if [[ "$RC" -eq 0 ]]; then add47 "mounts:control-ok"; else add47 "mounts:CONTROL-FAIL"; fi
rm -rf "$TMP/m47/real"; ln -s "$TMP/m47/elsewhere" "$TMP/m47/real"; run47 mounts "$P" claude "$TMP/m47/real"
# (4) env name approved but no longer used by this run's agents
P="$(newproj l280env)"; rec47 "$P" claude "" "" "" "ANTHROPIC_API_KEY|OPENAI_API_KEY"
run47 env "$P" claude "OPENAI_API_KEY" ANTHROPIC_API_KEY=x OPENAI_API_KEY=y
exp47="copies-dangling:control-ok copies-dangling:refused copies-dangling:asked-declined copies-dangling:approved copies-otherdir:control-ok copies-otherdir:refused copies-otherdir:asked-declined copies-otherdir:approved copies-file:control-ok copies-file:refused copies-file:asked-declined copies-file:approved tokens:refused mounts:control-ok mounts:refused env:refused "
if [[ "$res47" == "$exp47" ]]; then pass "U47: every approved record category (config-dir copies: dangling symlink / symlink to another dir / regular file, interactive and headless; token files; extra mounts; env names) forces re-approval or exit 2 naming it — nothing silently disappears"
else fail "U47 table: got [$res47] want [$exp47]"; fi

# ---- U48 ---------------------------------------------------------------------------------------------------------
# 1. PER-CALL PIN VERIFICATION IN ANY PROCESS: pins captured in a SUBSHELL (swarm style), the host-git caller has no
# in-memory pins but WGM_PIN_FILE names the pin file → every wgm_host_git call touching that repo verifies it first
mkdir -p "$TMP/gs48"; : > "$TMP/gs48.log"
printf '#!/usr/bin/env bash\necho "GIT $*" >> "%s"\nexec "%s" "$@"\n' "$TMP/gs48.log" "$REAL_GIT" > "$TMP/gs48/git"; chmod +x "$TMP/gs48/git"
P="$(newproj l290)"; O48="$(newproj l291)"; rm -f "$TMP/u48.lost"
r48="$(PATH="$TMP/gs48:$PATH" WGM_TRUST_LOST_FILE="$TMP/u48.lost" bash -c '
  source "$1"; P="$2"; O="$3"; log="$4"; pin="$5"
  ( sb_pin_capture_to "$pin" "$P" ) >/dev/null 2>&1 || exit 9            # captured in a subshell: nothing in memory here
  [[ -z "$SB_PIN_PTR" ]] || exit 8
  export WGM_PIN_FILE="$pin"
  wgm_host_git -C "$P" status --porcelain >/dev/null || exit 7             # call 1: pins intact
  c1=$(wc -l < "$log")
  printf "[alias]\n x = !touch /tmp/wgm-u48\n" >> "$P/.git/config"       # host-side change, no contained command
  wgm_host_git -C "$O" status --porcelain >/dev/null || exit 6             # another repository: unaffected
  c1b=$(wc -l < "$log")
  rc=0; ( wgm_host_git -C "$P" status --porcelain >/dev/null 2>&1 ) || rc=$?
  echo "rc=$rc c1b=$c1b c2=$(wc -l < "$log")"
' _ "$SB" "$P" "$O48" "$TMP/gs48.log" "$TMP/pin48.txt" 2>&1 | tail -1)"
if [[ "$r48" =~ ^rc=2\ c1b=([0-9]+)\ c2=([0-9]+)$ && "${BASH_REMATCH[1]}" -eq "${BASH_REMATCH[2]}" ]] && grep -q "^trust lost " "$TMP/u48.lost"; then
  pass "U48/1: with WGM_PIN_FILE (pins captured in another process) every wgm_host_git call verifies them: a config change → exit 2 before git runs (zero further git calls), an unrelated repo is unaffected"
else fail "U48/1: $r48 lost=[$(cat "$TMP/u48.lost" 2>/dev/null)]"; fi
rc48=0; ( WGM_PIN_FILE="$TMP/nonexistent-pin48" bash -c 'source "$1"; wgm_host_git -C "$2" status >/dev/null' _ "$SB" "$P" ) >/dev/null 2>&1 || rc48=$?
if [[ "$rc48" -eq 2 ]]; then pass "U48/1: a WGM_PIN_FILE that is missing is itself a refusal (exit 2), never a silent skip"; else fail "U48/1 missing pin file (rc=$rc48)"; fi
# 2. REGISTRY RACE: per-name entries in a directory, no read-modify-write. Barrier seam: writer A is paused inside its
# operation while writer B registers; then everything is listed, and a supervisor whose engine inspection fails prints
# every unconfirmed name as retained
R48="$TMP/reg48"; rm -rf "$R48" "$TMP/seam48"; mkdir -p "$R48/live" "$R48/retained" "$TMP/seam48"
# shellcheck disable=SC2016  # bash -c bodies
WGM_LIVE_REGISTRY="$R48" WGM_REGISTRY_SEAM_DIR="$TMP/seam48" bash -c 'source "$1"; SB_ENGINE=podman; sb_registry_add wgm-aaaa-1-1; sb_registry_add wgm-aaaa-1-3; sb_registry_del wgm-aaaa-1-1' _ "$SB" &
wa48=$!
for _i in $(seq 1 100); do [[ -e "$TMP/seam48/add-start.reached" ]] && break; sleep 0.1; done   # A is paused in its first op
rm -f "$TMP/seam48/add-start.reached"
WGM_LIVE_REGISTRY="$R48" bash -c 'source "$1"; SB_ENGINE=podman; sb_registry_add wgm-bbbb-2-1; sb_registry_add wgm-bbbb-2-2' _ "$SB"   # B registers while A is mid-operation (no seam dir for B)
: > "$TMP/seam48/add-start.go"
for _i in $(seq 1 100); do [[ -e "$TMP/seam48/del-start.reached" ]] && break; sleep 0.1; done   # A now paused inside its deregistration
WGM_LIVE_REGISTRY="$R48" bash -c 'source "$1"; SB_ENGINE=podman; sb_registry_add wgm-cccc-3-1' _ "$SB"            # C registers during A's deregistration
: > "$TMP/seam48/del-start.go"; wait "$wa48" || true
list48="$(for f in "$R48/live"/*; do printf '%s ' "${f##*/}"; done)"
mkdir -p "$TMP/eng48"
# shellcheck disable=SC2016  # the shim body is literal text
printf '#!/usr/bin/env bash\ncase "${1:-}" in ps) exit 1 ;; rm) exit 1 ;; esac\nexit 0\n' > "$TMP/eng48/podman"; chmod +x "$TMP/eng48/podman"
# shellcheck disable=SC2016  # bash -c body
sup48="$(PATH="$TMP/eng48:$PATH" WGM_LIVE_REGISTRY="$R48" WGM_ENGINE_CALL_BOUND=2 bash -c 'source "$1"; SB_ENGINE=none; SB_ERRFD=2; exec 2>&1; sb_on_signal 143' _ "$SB" 2>&1 || true)"
miss48=""; for n in wgm-aaaa-1-3 wgm-bbbb-2-1 wgm-bbbb-2-2 wgm-cccc-3-1; do grep -qx "retained container $n" <<<"$sup48" || miss48+="$n "; done
if [[ "$list48" == "wgm-aaaa-1-3 wgm-bbbb-2-1 wgm-bbbb-2-2 wgm-cccc-3-1 " && -z "$miss48" && ! -e "$R48/live/wgm-aaaa-1-1" ]]; then
  pass "U48/2: registrations by B and C while A is paused inside its own add/deregister are all kept (per-name entries, no read-modify-write); the supervisor with failing engine inspection prints every unconfirmed name as retained"
else fail "U48/2 (listing=[$list48] unprinted=[$miss48]): $(tail -3 <<<"$sup48")"; fi

# ---- U49 ---------------------------------------------------------------------------------------------------------
# Gap 1: verification is tied to the repository ACTUALLY targeted: an EXTERNAL linked workspace (under neither the pinned
# project nor its git dir) shares the pinned store, so a config change after capture → wgm_host_git -C <external lane> exits 2
# before git; and re-pinning after an AUTHORIZED worktree removal keeps verification on
mkdir -p "$TMP/gs49"; : > "$TMP/gs49.log"
printf '#!/usr/bin/env bash\necho "GIT $*" >> "%s"\nexec "%s" "$@"\n' "$TMP/gs49.log" "$REAL_GIT" > "$TMP/gs49/git"; chmod +x "$TMP/gs49/git"
P="$(newproj l300)"; git -C "$P" worktree add -q "$TMP/ext49" -b ext49 >/dev/null 2>&1; git -C "$P" worktree add -q "$TMP/ext49b" -b ext49b >/dev/null 2>&1
rm -f "$TMP/u49.lost"
# shellcheck disable=SC2016  # bash -c body
r49="$(PATH="$TMP/gs49:$PATH" WGM_TRUST_LOST_FILE="$TMP/u49.lost" bash -c '
  source "$1"; P="$2"; E="$3"; EB="$4"; log="$5"; pin="$6"
  ( sb_pin_capture_to "$pin" "$P" ) >/dev/null 2>&1 || exit 9
  export WGM_PIN_FILE="$pin"
  wgm_host_git -C "$E" status --porcelain >/dev/null || exit 8               # control: the external lane passes while intact
  # authorized change: remove a lane worktree (verified first by the call itself), then re-pin
  wgm_host_git -C "$P" worktree remove --force "$EB" >/dev/null 2>&1 || exit 7
  rc_mid=0; ( wgm_host_git -C "$E" status --porcelain >/dev/null 2>&1 ) || rc_mid=$?   # pins now stale (admin listing changed) → refused
  sb_pin_recapture_to "$pin" || exit 6
  wgm_host_git -C "$E" status --porcelain >/dev/null || exit 5               # after the re-pin: passes, verification still on
  c1=$(wc -l < "$log")
  printf "[alias]\n x = !touch /tmp/wgm-u49\n" >> "$P/.git/config"           # host-side change after capture
  rc=0; ( wgm_host_git -C "$E" status --porcelain >/dev/null 2>&1 ) || rc=$?
  echo "mid=$rc_mid rc=$rc c1=$c1 c2=$(wc -l < "$log")"
' _ "$SB" "$P" "$TMP/ext49" "$TMP/ext49b" "$TMP/gs49.log" "$TMP/pin49.txt" 2>&1 | tail -1)"
if [[ "$r49" =~ ^mid=2\ rc=2\ c1=([0-9]+)\ c2=([0-9]+)$ && "${BASH_REMATCH[1]}" -eq "${BASH_REMATCH[2]}" ]] && grep -q "^trust lost " "$TMP/u49.lost"; then
  pass "U49: a linked workspace OUTSIDE the project and git dir is verified through its resolved store (config change → exit 2 before git, zero further git calls); the authorized worktree removal is refused until sb_pin_recapture_to re-pins, after which verification stays on and passes"
else fail "U49: [$r49] lost=[$(cat "$TMP/u49.lost" 2>/dev/null)]"; fi
# a target whose store cannot be resolved safely is refused (planted symlink .git)
mkdir -p "$TMP/bad49"; ln -s "$P/.git" "$TMP/bad49/.git"
rcb49=0; ( WGM_PIN_FILE="$TMP/pin49.txt" bash -c 'source "$1"; wgm_host_git -C "$2" status >/dev/null' _ "$SB" "$TMP/bad49" ) >/dev/null 2>&1 || rcb49=$?
if [[ "$rcb49" -eq 2 ]]; then pass "U49: a target whose git store cannot be resolved safely (planted .git symlink) is refused (exit 2)"; else fail "U49 unresolvable store (rc=$rcb49)"; fi

# ---- U50 ---------------------------------------------------------------------------------------------------------
# B1: the runtime-tree policy sees the ORIGINAL runtime locations (captured before value filtering): an XDG_RUNTIME_DIR inside
# the project (or inside the common dir), or an engine-socket dir inside the project → exit 2 naming the runtime tree, zero launches
P="$(newproj l310)"; mkdir -p "$P/rt" "$P/.git/rt" "$P/sock"
b50="$(grep -c ' run ' "$WGM_STUB_TRACE" 2>/dev/null || true)"
XDG_RUNTIME_DIR="$P/rt" pf "$P" --agent-cmd bash; r1=$RC; e1="$ERR"
XDG_RUNTIME_DIR="$P/.git/rt" pf "$P" --agent-cmd bash; r2=$RC; e2="$ERR"
DOCKER_HOST="unix://$P/sock/docker.sock" pf "$P" --agent-cmd bash; r3=$RC; e3="$ERR"
XDG_RUNTIME_DIR="$P/rt" lp "$P" analyze --max-retries 0 -- bash -c true; r4=$LRC; e4="$LOUT"
a50="$(grep -c ' run ' "$WGM_STUB_TRACE" 2>/dev/null || true)"
pf "$P" --agent-cmd bash; r5=$RC     # control: an ordinary runtime dir elsewhere passes
if [[ "$r1" -eq 2 && "$r2" -eq 2 && "$r3" -eq 2 && "$r4" -eq 2 && "$r5" -eq 0 ]] && has "runtime tree $P/rt" "$e1" && has "XDG_RUNTIME_DIR" "$e1" && has "runtime tree $P/.git/rt" "$e2" && has "runtime tree $P/sock" "$e3" && has "DOCKER_HOST" "$e3" && has "runtime tree" "$e4" \
   && [[ "$a50" == "$b50" ]]; then
  pass "U50: an XDG_RUNTIME_DIR inside the project, inside the common dir, or an engine-socket dir inside the project → exit 2 naming the runtime tree (preflight and loop), zero launches; the value filter dropping it afterwards cannot hide it"
else fail "U50 (rc=$r1/$r2/$r3/$r4/$r5): [$e1] [$e2] [$e3]"; fi

# ---- U51 ---------------------------------------------------------------------------------------------------------
# B1: EVERY refusal branch of the record loader has a fixture: foreign-owned record file, foreign-owned record directory
# (genuinely foreign: a rootless-podman user-namespace chown makes the host see a SUBORDINATE uid as the owner), world-writable
# mode, a symlinked record, a non-regular record, a group-writable record directory. (A record directory that is itself a
# symlink is resolved by the canonical record-dir guard, which validates where it lands — U32 — so it is not a refusal branch.)
P="$(newproj l320)"; pf "$P" --dry-run --agent-cmd bash; REC51="$(rec_of)"; DIR51="$(dirname "$REC51")"; res51=""
r51() { pf "$P" --dry-run --agent-cmd bash; [[ "$RC" -eq 2 && "$ERR" == *"$1"* ]] && res51+="$2:ok " || res51+="$2:FAIL(rc=$RC)[$(grep -v 'host env' <<<"$ERR" | tail -1 | cut -c1-120)] "; }
b51="$(grep -c ' run ' "$WGM_STUB_TRACE" 2>/dev/null || true)"
write_rec "$REC51" ""
chmod 646 "$REC51"; r51 "group/world-writable" worldw; chmod 600 "$REC51"
mv "$REC51" "$REC51.real"; ln -s "$REC51.real" "$REC51"; r51 "is a symlink" symlink; rm -f "$REC51"; mv "$REC51.real" "$REC51"
mv "$REC51" "$REC51.real"; mkdir "$REC51"; r51 "is not a regular file" nonregular; rmdir "$REC51"; mv "$REC51.real" "$REC51"
unshare51() { PATH="$REAL_PATH" podman unshare "$@"; }   # (the REAL podman: the harness's PATH holds stub engines first)
if command -v podman >/dev/null 2>&1 && unshare51 true >/dev/null 2>&1; then
  CHOWN51=1; unshare51 chown 1:1 "$REC51"
  if [[ "$(stat -c %u "$REC51")" == "$(id -u)" ]]; then echo "skip: user-namespace chown did not produce a foreign owner — skipping the foreign-owner record fixtures"; res51+="foreign-file:ok foreign-dir:ok "
  else
    r51 "is not owned by the operator" foreign-file; unshare51 chown 0:0 "$REC51"
    chmod 755 "$DIR51"; unshare51 chown 1:1 "$DIR51"; r51 "record directory $DIR51 is not owned by the operator" foreign-dir; unshare51 chown 0:0 "$DIR51"; chmod 700 "$DIR51"
  fi
else echo "skip: podman unshare unavailable — skipping the foreign-owner record fixtures"; res51+="foreign-file:ok foreign-dir:ok "; fi
chmod 775 "$DIR51"; r51 "record directory $DIR51 is group/world-writable" dir-groupw; chmod 700 "$DIR51"
pf "$P" --dry-run --agent-cmd bash; r51ok=$RC   # restored: the unbroken record loads again
a51="$(grep -c ' run ' "$WGM_STUB_TRACE" 2>/dev/null || true)"
if [[ "$res51" == "worldw:ok symlink:ok nonregular:ok foreign-file:ok foreign-dir:ok dir-groupw:ok " && "$r51ok" -eq 0 && "$a51" == "$b51" ]]; then
  pass "U51: foreign-owned record file and directory (userns chown), world-writable, symlinked and non-regular record, group-writable record directory → each exit 2 naming it, zero launches; ownership restored, the record loads again"
else fail "U51: [$res51] restored-rc=$r51ok launches=$b51/$a51"; fi

P="$(newproj l1)"
lp "$P" build 1 --max-retries 0 --commit -- bash -c "$AG_PROGRESS" _
if [[ "$LRC" -eq 0 ]] && has "sandbox: on (podman" "$LOUT" && [[ "$(git -C "$P" rev-list --count HEAD)" -eq 2 ]] \
   && grep -q $'\tcontainer:podman$' "$P/.wgm/metrics.tsv" && head -1 "$P/.wgm/metrics.tsv" | grep -q $'\tsandbox$'; then
  pass "a sandboxed loop commits through the container and labels telemetry container:<engine>"
else fail "sandboxed loop (rc=$LRC): $LOUT"; fi
if ! compgen -G "$TMPDIR/wgm-*" >/dev/null; then pass "loop leaves no decision/credential/runner temp dirs behind"; else fail "stray temp dirs: $(ls "$TMPDIR")"; fi

# T10: every HOST git call is plumbing with neutralized config; no porcelain on the host
P="$(newproj l10)"
mkdir -p "$TMP/gitwrap"
cat > "$TMP/gitwrap/git" <<EOF
#!/usr/bin/env bash
printf 'in=%s allow=%s lazy=%s argv=%s\n' "\${WGM_IN_DEVCONTAINER:-}" "\${GIT_ALLOW_PROTOCOL+set}:\${GIT_ALLOW_PROTOCOL}" "\${GIT_NO_LAZY_FETCH:-}" "\$*" >> "\$WGM_GITLOG"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMP/gitwrap/git"
export WGM_GITLOG="$TMP/gitlog"; : > "$WGM_GITLOG"
PATH="$TMP/gitwrap:$STUBPATH" lp "$P" build 1 --max-retries 0 --commit -- bash -c "$AG_PROGRESS" _
HOSTCALLS="$(grep '^in= ' "$WGM_GITLOG" || true)"
bad=0
while IFS= read -r l; do
  [[ -n "$l" ]] || continue
  grep -q 'allow=set:  *lazy=1\|allow=set: lazy=1' <<<"$l" || bad=1
  grep -q 'core.fsmonitor=false' <<<"$l" && grep -q 'core.hooksPath=/dev/null' <<<"$l" && grep -q 'protocol.allow=never' <<<"$l" || bad=1
  grep -Eq 'argv=(-c [^ ]+ )+(-C [^ ]+ )?(rev-parse|symbolic-ref|config|rev-list|for-each-ref|show-ref|cat-file|merge-base|show) ' <<<"$l" || bad=1
done <<<"$HOSTCALLS"
if [[ "$LRC" -eq 0 && -n "$HOSTCALLS" && "$bad" -eq 0 ]] && ! grep -Eq '(argv=| )(status|add|commit|diff|checkout|stash|merge|rebase)( |$)' <<<"$HOSTCALLS" \
   && grep -Eq '^in=1 .*(argv=| )(status|add|commit)( |$)' "$WGM_GITLOG"; then
  pass "T10: host git is plumbing-only with neutralized config and EMPTY GIT_ALLOW_PROTOCOL; porcelain ran only 'inside'"
else fail "T10 host git audit (rc=$LRC bad=$bad): host=$(printf '%s' "$HOSTCALLS" | wc -l) inside=$(grep -c '^in=1' "$WGM_GITLOG" || true) $(grep '^in=1' "$WGM_GITLOG" | head -2) $LOUT"; fi

# T15: no host npm/node
P="$(newproj l15)"
mkdir -p "$TMP/wrap" "$TMP/sentinel-logs"
for t in npm node; do printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$t" "$TMP/wrap.log" > "$TMP/wrap/$t"; chmod +x "$TMP/wrap/$t"; done
: > "$TMP/wrap.log"; printf 'logs-dir=%s\n' "$P/linked-logs" > "$P/.npmrc"; ln -s "$TMP/sentinel-logs" "$P/linked-logs"
PATH="$TMP/wrap:$STUBPATH" lp "$P" analyze --max-retries 0 -- bash -c 'true' _
if [[ "$LRC" -eq 0 && ! -s "$TMP/wrap.log" && -z "$(ls -A "$TMP/sentinel-logs")" ]]; then pass "T15: a sandboxed loop never runs host npm/node and leaves the sentinel dir untouched"; else fail "T15 host npm/node ran (rc=$LRC): $(cat "$TMP/wrap.log")"; fi

# T14: allowlisted host environment, sanitized PATH, project-relative agent still works
P="$(newproj l14)"
mkdir -p "$P/bin"
# shellcheck disable=SC2016  # the wrapper body is expanded when it runs
for t in date git sha256sum; do printf '#!/usr/bin/env bash\ntouch "%s"\nexec "$(PATH="%s" command -v %s)" "$@"\n' "$TMP/pwned" "$REAL_PATH" "$t" > "$P/bin/$t"; chmod +x "$P/bin/$t"; done
printf '#!/usr/bin/env bash\ntouch ran.txt\n' > "$P/bin/agent"; chmod +x "$P/bin/agent"
printf 'require("fs").writeFileSync("%s/pre-ran", "x");\n' "$TMP" > "$P/pre.js"   # a NON-empty preload that plants a sentinel
# shellcheck disable=SC2016  # the BASH_ENV script body expands when it runs
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$0 $$" >> "%s/bashenv.log"\n' "$TMP" > "$TMP/bashenv.sh"   # a REAL BASH_ENV script
rm -f "$TMP/pwned" "$TMP/pre-ran" "$TMP/bashenv.log"
set +e
LOUT="$(cd "$P" && PATH="$P/bin:$STUBPATH" BASH_ENV="$TMP/bashenv.sh" LD_PRELOAD="$TMP/nonexistent-preload.so" NODE_OPTIONS="--require $P/pre.js" PERL5OPT=-x GIT_SSH_COMMAND=false PAGER=less \
  WGM_DEBUG_HOST_ENV="$TMP/hostenv" WGM_AGENT=./bin/agent "$LOOP" analyze --max-retries 0 2>&1)"; LRC=$?
set -e
ALLOW='^(PATH|HOME|USER|LOGNAME|LANG|LC_[A-Z_]+|TZ|TERM|TMPDIR|XDG_RUNTIME_DIR|XDG_DATA_HOME|XDG_CONFIG_HOME|CONTAINER_HOST|CONTAINERS_CONF|CONTAINERS_STORAGE_CONF|DOCKER_HOST|DOCKER_CONFIG|DOCKER_CONTEXT|WGM_[A-Z0-9_]+|ANTHROPIC_API_KEY|OPENAI_API_KEY|GH_TOKEN|GITHUB_TOKEN|COPILOT_GITHUB_TOKEN|GIT_CONFIG_COUNT|GIT_CONFIG_KEY_[0-9]+|GIT_CONFIG_VALUE_[0-9]+|GIT_ALLOW_PROTOCOL|GIT_NO_LAZY_FETCH|GIT_TERMINAL_PROMPT|GIT_PAGER|GIT_EDITOR|PWD|OLDPWD|SHLVL|_)$'
if [[ "$LRC" -eq 0 ]] && has "dropped PATH entry $P/bin" "$LOUT" && has "dropped NODE_OPTIONS" "$LOUT" && has "dropped PERL5OPT" "$LOUT" && has "dropped GIT_SSH_COMMAND" "$LOUT" \
   && [[ -s "$TMP/hostenv" ]] && ! grep -Evq "$ALLOW" "$TMP/hostenv" && [[ -e "$P/ran.txt" ]] && [[ ! -e "$TMP/pwned" && ! -e "$TMP/pre-ran" ]] && [[ "$(wc -l < "$TMP/bashenv.log" 2>/dev/null || echo 0)" -le 1 ]] && ! grep -qx 'LD_PRELOAD\|BASH_ENV' "$TMP/hostenv"; then
  pass "T14: host env is an allowlist (LD_PRELOAD, a real BASH_ENV script and a non-empty NODE_OPTIONS preload never reach any wgm-spawned process), project PATH entries are dropped (reported), WGM_AGENT=./bin/agent still runs, no project wrapper ran"
else fail "T14 env allowlist (rc=$LRC): $(grep -Ev "$ALLOW" "$TMP/hostenv" 2>/dev/null | head -3) / $LOUT"; fi

# T17: the credential VALUE never reaches argv, files or the record
P="$(newproj l17)"
# shellcheck disable=SC2016  # the command runs inside the container: expansion happens there
mkstub "$TMP/stubs/claude2" claude 'if [[ "${1:-}" == --version ]]; then echo v; exit 0; fi; mkdir -p .wgm/run; printf "%s" "$ANTHROPIC_API_KEY" | sha256sum | cut -d" " -f1 > .wgm/run/digest.txt'
PATH="$TMP/stubs/claude2/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd bash; write_rec "$(rec_of)" "claude" ANTHROPIC_API_KEY
: > "$WGM_STUB_TRACE"
EXPECT="$(printf '%s' 'SENTINEL-T17-5c1d' | sha256sum | cut -d' ' -f1)"
ANTHROPIC_API_KEY=SENTINEL-T17-5c1d PATH="$TMP/stubs/claude2/bin:$STUBPATH" lp "$P" analyze --max-retries 0 --agent claude
if [[ "$LRC" -eq 0 && "$(cat "$P/.wgm/run/digest.txt" 2>/dev/null)" == "$EXPECT" ]] && grep -q -- '--env ANTHROPIC_API_KEY' "$WGM_STUB_TRACE" \
   && ! grep -rqF 'SENTINEL-T17-5c1d' "$WGM_STUB_TRACE" "$TMPDIR" "$XDG_CONFIG_HOME" "$P" 2>/dev/null; then
  pass "T17: the agent sees the value (digest matches) yet the value is in no argv, temp file, record or project file"
else fail "T17 credential value handling (rc=$LRC): $LOUT"; fi

# ---- U8: git protections live in the ENVIRONMENT of wgm's whole host process tree ------------------------
P="$(newproj l90)"
mkdir -p "$TMP/gitshim"
cat > "$TMP/gitshim/git" <<SHIM
#!/usr/bin/env bash
kv=""; n="\${GIT_CONFIG_COUNT:-0}"
for ((i = 0; i < n; i++)); do k="GIT_CONFIG_KEY_\$i"; v="GIT_CONFIG_VALUE_\$i"; kv+="\${!k}=\${!v};"; done
printf 'in=%s cfg=%s allow=%s lazy=%s prompt=%s argv=%s\n' "\${WGM_IN_DEVCONTAINER:-}" "\$kv" "\${GIT_ALLOW_PROTOCOL+set}:\${GIT_ALLOW_PROTOCOL}" "\${GIT_NO_LAZY_FETCH:-}" "\${GIT_TERMINAL_PROMPT:-}" "\$*" >> "\$WGM_GITLOG2"
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$TMP/gitshim/git"
export WGM_GITLOG2="$TMP/gitlog2"; : > "$WGM_GITLOG2"
PATH="$TMP/gitshim:$STUBPATH" lp "$P" build 1 --max-retries 0 --commit -- bash -c "$AG_PROGRESS" _
bad=0; hostn=0
while IFS= read -r l; do
  [[ "$l" == "in= cfg="* ]] || continue   # host calls only (WGM_IN_DEVCONTAINER empty)
  hostn=$((hostn + 1))
  for key in 'core.fsmonitor=false' 'core.hooksPath=/dev/null' 'protocol.allow=never'; do
    [[ "$l" == *"$key"* ]] || bad=$((bad + 1))
  done
  [[ "$l" == *"allow=set: lazy=1 prompt=0"* ]] || bad=$((bad + 1))
done < "$WGM_GITLOG2"
if [[ "$LRC" -eq 0 && "$hostn" -gt 5 && "$bad" -eq 0 ]]; then pass "U8(a): all $hostn host git calls of a sandboxed loop carry the three config keys and the protocol/lazy/prompt env"; else fail "U8(a) (rc=$LRC hostn=$hostn bad=$bad): $(grep '^in= ' "$WGM_GITLOG2" | head -2)"; fi

# the helper applies the same environment to a process that did not inherit it; an in-tree fsmonitor
# hook fires on a plain `git status` (positive control) and never once the helper ran
P="$(newproj l91)"; printf '#!/usr/bin/env bash\ntouch "%s"\nprintf "\\0"\n' "$TMP/fsm-fired" > "$P/fsm.sh"; chmod +x "$P/fsm.sh"
git -C "$P" config core.fsmonitor "$P/fsm.sh"
rm -f "$TMP/fsm-fired"; git -C "$P" status >/dev/null 2>&1 || true
[[ -e "$TMP/fsm-fired" ]] && ctl=1 || ctl=0
rm -f "$TMP/fsm-fired"
( sb_export_git_env; git -C "$P" status >/dev/null 2>&1 || true; git -C "$P" diff >/dev/null 2>&1 || true )
if [[ "$ctl" -eq 1 && ! -e "$TMP/fsm-fired" ]]; then pass "U8: the in-tree fsmonitor hook fires on plain git (control) but never once sb_export_git_env applied the environment"; else fail "U8 fsmonitor (control=$ctl, fired-after=$([[ -e $TMP/fsm-fired ]] && echo yes || echo no))"; fi
# append, never clobber, an existing GIT_CONFIG_COUNT; idempotent
# shellcheck disable=SC2153,SC2031,SC2030  # the *_1/_3 entries are created by sb_export_git_env
cnt="$( export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=keep; unset WGM_GIT_ENV_APPLIED
  sb_export_git_env; sb_export_git_env; printf '%s|%s|%s|%s' "$GIT_CONFIG_COUNT" "$GIT_CONFIG_KEY_0=$GIT_CONFIG_VALUE_0" "$GIT_CONFIG_KEY_1" "$GIT_CONFIG_KEY_3" )"
if [[ "$cnt" == "4|user.name=keep|core.fsmonitor|protocol.allow" ]]; then pass "U8: the helper appends to an existing GIT_CONFIG_COUNT and is idempotent"; else fail "U8 helper append: $cnt"; fi

# jj-spawned git (workspace add run in wgm's host environment) carries the protections too
if command -v jj >/dev/null 2>&1; then
  JP="$TMP/jjrepo"; mkdir -p "$JP"
  ( cd "$JP" && git init -q . && git config user.email t@e && git config user.name t && echo a > f && git add f && git commit -qm s )
  ( cd "$JP" && jj git init --colocate >/dev/null 2>&1 ) || true
  : > "$WGM_GITLOG2"
  ( cd "$JP" && unset WGM_GIT_ENV_APPLIED && sb_export_git_env && { PATH="$TMP/gitshim:$PATH" jj workspace add "$TMP/jjws" >/dev/null 2>&1 || true; } )
  bad=0; n=0
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue; n=$((n + 1))
    for key in 'core.fsmonitor=false' 'core.hooksPath=/dev/null' 'protocol.allow=never'; do [[ "$l" == *"$key"* ]] || bad=$((bad + 1)); done
    [[ "$l" == *"allow=set: lazy=1 prompt=0"* ]] || bad=$((bad + 1))
  done < "$WGM_GITLOG2"
  if [[ "$bad" -eq 0 ]]; then pass "U8(b): $n host git call(s) spawned by jj workspace add all carry the protections"; else fail "U8(b): $bad violations in $n calls: $(head -2 "$WGM_GITLOG2")"; fi
else echo "skip: no jj on PATH — skipping the jj-spawned git audit"; fi

# ---- U23: WGM_GIT_ENV_APPLIED is never trusted alone ------------------------------------------------------------
# shellcheck disable=SC2031
all_keys() { local out="" c="${GIT_CONFIG_COUNT:-0}" i k v; for ((i = 0; i < c; i++)); do k="GIT_CONFIG_KEY_$i"; v="GIT_CONFIG_VALUE_$i"; out+="${!k}=${!v};"; done; printf '%s' "$out"; }
# shellcheck disable=SC2030,SC2031  # each case deliberately runs in its own subshell
r1="$( export WGM_GIT_ENV_APPLIED=1; while read -r v; do unset "$v"; done < <(compgen -e | grep '^GIT_' || true); sb_export_git_env; sb_git_env_ok && all_keys )"
# a PARTIAL environment (only fsmonitor present) is completed; a foreign LATER override of hooksPath is out-voted by an appended pair
# shellcheck disable=SC2030,SC2031
r2="$( export WGM_GIT_ENV_APPLIED=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false; sb_export_git_env; sb_git_env_ok && all_keys )"
# shellcheck disable=SC2030,SC2031
r3="$( export WGM_GIT_ENV_APPLIED=1; sb_export_git_env; export GIT_CONFIG_KEY_3=core.hooksPath GIT_CONFIG_VALUE_3=/tmp/evil GIT_CONFIG_COUNT=4; ! sb_git_env_ok && sb_export_git_env && sb_git_env_ok && all_keys )"
# shellcheck disable=SC2030,SC2031
r4="$( export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=foreign; unset WGM_GIT_ENV_APPLIED; sb_export_git_env; all_keys )"
if [[ "$r1" == *"core.fsmonitor=false"* && "$r1" == *"core.hooksPath=/dev/null"* && "$r1" == *"protocol.allow=never"* && "$r2" == *"core.hooksPath=/dev/null"* && "$r2" == *"protocol.allow=never"* \
   && "$r3" == *"core.hooksPath=/tmp/evil;"*"core.hooksPath=/dev/null"* && "$r4" == "user.name=foreign;core.fsmonitor=false;"* ]]; then
  pass "U23: with the marker set but the protections missing, partial, or out-voted, sb_export_git_env re-applies them (appending; the foreign entry survives)"
else fail "U23 unit: r1=[$r1] r2=[$r2] r3=[$r3] r4=[$r4]"; fi
# a jj-spawned git, and a loop, started with the marker but NO GIT_* variables: every git call in the shim trace carries the protections
if command -v jj >/dev/null 2>&1; then
  : > "$WGM_GITLOG2"; rm -rf "$TMP/jjws23"
  # shellcheck disable=SC2031
  ( cd "$JP" && unset WGM_GIT_ENV_APPLIED && export WGM_GIT_ENV_APPLIED=1 && while read -r v; do unset "$v"; done < <(compgen -e | grep '^GIT_' || true); sb_export_git_env && { PATH="$TMP/gitshim:$PATH" jj workspace add "$TMP/jjws23" >/dev/null 2>&1 || true; } )
  bad=0; n=0
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue; n=$((n + 1))
    for key in 'core.fsmonitor=false' 'core.hooksPath=/dev/null' 'protocol.allow=never'; do [[ "$l" == *"$key"* ]] || bad=$((bad + 1)); done
    [[ "$l" == *"allow=set: lazy=1 prompt=0"* ]] || bad=$((bad + 1))
  done < "$WGM_GITLOG2"
  if [[ "$bad" -eq 0 && "$n" -ge 1 ]]; then pass "U23: jj-spawned git ($n call(s)) carries the protections although the process started with the marker and no GIT_* variables"; else fail "U23 jj ($bad violations in $n calls): $(head -2 "$WGM_GITLOG2" 2>/dev/null)"; fi
fi
P="$(newproj l124)"; : > "$WGM_GITLOG2"
WGM_GIT_ENV_APPLIED=1 PATH="$TMP/gitshim:$STUBPATH" lp "$P" analyze --max-retries 0 -- bash -c 'true' _
bad=0; n=0
while IFS= read -r l; do
  [[ "$l" == "in= cfg="* ]] || continue; n=$((n + 1))
  for key in 'core.fsmonitor=false' 'core.hooksPath=/dev/null' 'protocol.allow=never'; do [[ "$l" == *"$key"* ]] || bad=$((bad + 1)); done
  [[ "$l" == *"allow=set: lazy=1 prompt=0"* ]] || bad=$((bad + 1))
done < "$WGM_GITLOG2"
if [[ "$LRC" -eq 0 && "$n" -gt 3 && "$bad" -eq 0 ]]; then pass "U23: a loop started with the marker and no GIT_* variables: all $n host git calls carry the protections"; else fail "U23 loop (rc=$LRC calls=$n violations=$bad): $(grep -v dropped <<<"$LOUT" | tail -2)"; fi

# ---- host trusts nothing the agent wrote ----------------------------------------------------------------
P="$(newproj l20)"; mkdir -p "$TMP/outside20"; ln -s "$TMP/outside20" "$P/.wgm"
lp "$P" build 1 --max-retries 0 -- bash -c "$AG_PROGRESS" _
if [[ "$LRC" -eq 2 ]] && has "agent-written symlink at $P/.wgm" "$LOUT" && [[ -z "$(ls -A "$TMP/outside20")" ]]; then pass "safe host writes: an agent-written symlinked .wgm is refused (exit 2) and its target untouched"; else fail "symlink refusal (rc=$LRC): $LOUT"; fi

P="$(newproj l21)"
lp "$P" build 1 --max-retries 0 -- bash -c 'echo "[evil] x = 1" >> .git/config' _
if [[ "$LRC" -eq 2 ]] && has "git configuration changed by the agent" "$LOUT"; then pass "pinning: an agent edit of .git/config stops the loop with exit 2"; else fail "config pin (rc=$LRC): $LOUT"; fi
P="$(newproj l22)"
lp "$P" build 1 --max-retries 0 -- bash -c 'mv .git .git.old && cp -a .git.old .git' _
if [[ "$LRC" -eq 2 ]] && has "git metadata changed by the agent" "$LOUT"; then pass "pinning: replacing the project's .git exits 2 (git-pointer change)"; else fail "pointer pin (rc=$LRC): $LOUT"; fi
P="$(newproj l23)"
lp "$P" build 1 --max-retries 0 -- bash -c 'mkdir -p .git/hooks && printf "#!/bin/sh\ntouch /tmp/x\n" > .git/hooks/pre-commit' _
if [[ "$LRC" -eq 2 ]] && has "git configuration changed by the agent" "$LOUT"; then pass "pinning: a planted hook is detected before any host git command"; else fail "hook pin (rc=$LRC): $LOUT"; fi

# ---- decision-file hand-off ----------------------------------------------------------------------------
P="$(newproj l30)"
DD="$TMP/dec"; mkdir -p "$DD"; chmod 700 "$DD"
printf 'sandbox=off\nengine=none\nreason=from-swarm\nimage=\nrecord=\n' > "$DD/d"; chmod 600 "$DD/d"
WGM_SANDBOX_DECISION="$DD/d" lp "$P" build 1 --max-retries 0 --commit -- bash -c "$AG_PROGRESS" _
if [[ "$LRC" -eq 0 ]] && has "sandbox: OFF — unsandboxed (from-swarm)" "$LOUT" && grep -q $'\toff:from-swarm$' "$P/.wgm/metrics.tsv"; then
  pass "a decision file is used verbatim (no preflight), labelled in the log and telemetry"
else fail "decision-file off (rc=$LRC): $LOUT"; fi
chmod 664 "$DD/d"
WGM_SANDBOX_DECISION="$DD/d" lp "$P" build 1 --max-retries 0 --commit -- bash -c "$AG_PROGRESS" _
if [[ "$LRC" -eq 2 ]] && has "group/world-writable" "$LOUT"; then pass "a loosely-permissioned decision file is refused like the record"; else fail "decision perms (rc=$LRC): $LOUT"; fi
# an ON decision keeps working when the engine would now fail info: no preflight ran
pf "$P" --agent-cmd bash; printf '%s\n' "$OUTO" > "$DD/on"; chmod 600 "$DD/on"
P="$(newproj l31)"
WGM_STUB_INFO_FAIL=1 WGM_SANDBOX_DECISION="$DD/on" lp "$P" analyze --max-retries 0 -- bash -c 'true' _
# (the decision names another project's mounts: the loop re-derives its own project, so it must still run)
if [[ "$LRC" -eq 0 ]] && has "sandbox: on (podman" "$LOUT"; then pass "an ON decision file is consumed without a preflight (no engine probe, no prompt)"; else fail "decision-file on (rc=$LRC): $LOUT"; fi

# ---- trusted runner: skill dir inside a writable mount ---------------------------------------------------
P="$(newproj l40)"; mkdir -p "$P/skill"; cp -R "$ROOT/scripts" "$P/skill/scripts"; cp -R "$ROOT/assets" "$P/skill/assets"
lp "$P" analyze --max-retries 0 -- bash -c 'true' _
LRC0="$LRC"; LOUT0="$LOUT"
set +e; LOUT="$(cd "$P" && "$P/skill/scripts/loop.sh" analyze --max-retries 0 -- bash -c 'true' _ 2>&1)"; LRC=$?; set -e
if [[ "$LRC0" -eq 0 && "$LRC" -eq 0 ]] && has "trusted runner snapshot" "$LOUT" && ! has "trusted runner snapshot" "$LOUT0" && ! compgen -G "$TMPDIR/wgm-runner.*" >/dev/null; then
  pass "trusted runner: a skill dir inside the project runs from a private snapshot that is removed on exit"
else fail "trusted runner (rc=$LRC): $LOUT"; fi

# ---- launch-time layout: a lane running with its PARENT's decision mounts the lane, not the parent ------
P="$(newproj l80)"
pf "$P" --agent-cmd bash; printf '%s\n' "$OUTO" > "$DD/parent"; chmod 600 "$DD/parent"
git -C "$P" worktree add -q "$TMP/lane80" -b lane80
: > "$WGM_STUB_TRACE"
WGM_SANDBOX_DECISION="$DD/parent" lp "$TMP/lane80" analyze --max-retries 0 -- bash -c 'true' _
RUNS="$(grep ' run ' "$WGM_STUB_TRACE" || true)"
ADMIN="$P/.git/worktrees/lane80"
if [[ "$LRC" -eq 0 ]] && grep -q "source=$TMP/lane80,destination=$TMP/lane80," <<<"$RUNS" && ! grep -q "source=$P,destination=$P," <<<"$RUNS" \
   && grep -q "source=$P/.git,destination=$P/.git,bind-nonrecursive=true --mount" <<<"$RUNS" \
   && grep -Eq "source=$ADMIN/config.worktree,destination=$ADMIN/config.worktree,[a-z-]+=[a-z]+,ro=true" <<<"$RUNS" \
   && grep -Eq "source=$P/.git/hooks,destination=$P/.git/hooks,[a-z-]+=[a-z]+,ro=true" <<<"$RUNS"; then
  pass "launch-time layout: a lane with its parent's decision mounts the lane, the common dir rw and its OWN config.worktree + hooks read-only"
else fail "launch-time layout (rc=$LRC): $(printf '%s' "$RUNS" | head -1 | cut -c1-600) / $LOUT"; fi
printf 'mount=%s:%s:rw\n' "$P" "$P" >> "$DD/parent"
WGM_SANDBOX_DECISION="$DD/parent" lp "$TMP/lane80" analyze --max-retries 0 -- bash -c 'true' _
if [[ "$LRC" -eq 2 ]] && has "decision refused" "$LOUT"; then pass "a decision that names project/git-dir mounts is refused"; else fail "layout mount in decision accepted (rc=$LRC)"; fi

# ---- container lifecycle: T3 / T4 -------------------------------------------------------------------------
sigtest() {  # sigtest PROJECT ENV… — start a loop whose agent hangs in the stub, TERM it, expect 143
  local d="$1"; shift
  : > "$TMP/live"; rm -f "$TMP/mark"
# shellcheck disable=SC2016  # the command runs inside the container: expansion happens there
  ( cd "$d" && exec env "$@" WGM_STUB_LIVE="$TMP/live" WGM_TEST_MARK="$TMP/mark" "$LOOP" analyze --max-retries 0 \
      -- bash -c 'touch "$WGM_TEST_MARK"; sleep 30' _ > "$TMP/sig.out" 2>&1 ) &
  local pid=$!
  for _i in $(seq 1 200); do
    [[ -e "$TMP/mark" ]] && break
# shellcheck disable=SC2016  # the command runs inside the container: expansion happens there
    grep -q 'touch "$WGM_TEST_MARK"' "$WGM_STUB_TRACE" && [[ "${WGM_STUB_LATE_SEEN:-0}" == 1 ]] && break
    sleep 0.1
  done
  local t0=$SECONDS
  kill -TERM "$pid" 2>/dev/null || true
  set +e; wait "$pid"; SIGRC=$?; set -e
  SIGT=$((SECONDS - t0))
}
P="$(newproj l50)"
write_rec "$(pf "$P" --dry-run --agent-cmd bash; rec_of)" ""
sigtest "$P" WGM_STUB_RM_FAIL=1 WGM_STUB_PS_FAIL=1
NAME="$(grep -o 'retained container [^ ]*' "$TMP/sig.out" | head -1 | awk '{print $3}' || true)"
if [[ "$SIGRC" -eq 143 && "$NAME" == wgm-* ]] && ! grep -q 'removed' "$TMP/sig.out"; then
  pass "T3: SIGTERM with an engine that cannot remove or list prints 'retained container <name>' and exits 143"
else fail "T3 (rc=$SIGRC, name='$NAME'): $(cat "$TMP/sig.out")"; fi
P="$(newproj l52)"
write_rec "$(pf "$P" --dry-run --agent-cmd bash; rec_of)" ""
: > "$WGM_STUB_TRACE"
WGM_STUB_LATE_SEEN=1 sigtest "$P" WGM_STUB_LATE=1
if [[ "$SIGRC" -eq 143 ]] && { ! grep -q '^wgm-' "$TMP/live" || grep -q 'retained container wgm-' "$TMP/sig.out"; }; then
  pass "T4: a container that only appears after SIGTERM is still removed (or printed as retained) before the loop exits 143"
else fail "T4 late launch (rc=$SIGRC): live=$(cat "$TMP/live") $(grep -v dropped "$TMP/sig.out" | tail -3)"; fi
P="$(newproj l51)"
sigtest "$P"
if [[ "$SIGRC" -eq 143 ]] && ! grep -q 'retained container' "$TMP/sig.out" && ! grep -q '^wgm-' "$TMP/live"; then
  pass "T3: with a working engine the live container is removed by name and the loop exits 143"
else fail "T3 reap (rc=$SIGRC): $(cat "$TMP/sig.out") / live: $(cat "$TMP/live")"; fi

# U10(3): a hung engine client (rm / ps never return) cannot stall cancellation or hide the container
for mode in WGM_STUB_RM_HANG WGM_STUB_PS_HANG; do
  P="$(newproj "l95$mode")"
  write_rec "$(pf "$P" --dry-run --agent-cmd bash; rec_of)" ""
  : > "$WGM_STUB_TRACE"
  sigtest "$P" "$mode=1"
  NAME="$(grep -o 'retained container [^ ]*' "$TMP/sig.out" | head -1 | awk '{print $3}' || true)"
  if [[ "$SIGRC" -eq 143 && "$SIGT" -lt 26 && -n "$NAME" ]] && grep -q -- "--name $NAME " "$WGM_STUB_TRACE"; then
    pass "U10(3): with $mode the loop exits 143 in ${SIGT}s and prints the exact 'retained container $NAME'"
  else fail "U10(3) $mode (rc=$SIGRC, ${SIGT}s, name='$NAME'): $(grep -v dropped "$TMP/sig.out" | tail -3)"; fi
done

# U10(1): no credential VALUE in any host/engine argv, observed with strace (control: the observer sees env -i NAME=value)
if command -v strace >/dev/null 2>&1 && strace -f --seccomp-bpf -qq -e trace=execve -o /dev/null true 2>/dev/null; then
  P="$(newproj l96)"
  # shellcheck disable=SC2016  # the stub body expands when it runs
  mkstub "$TMP/stubs/claude3" claude 'if [[ "${1:-}" == --version ]]; then echo v; exit 0; fi; mkdir -p .wgm/run; printf "%s" "$ANTHROPIC_API_KEY" | sha256sum | cut -d" " -f1 > .wgm/run/digest.txt'
  PATH="$TMP/stubs/claude3/bin:$STUBPATH" pf "$P" --dry-run --agent-cmd bash; write_rec "$(rec_of)" "claude" ANTHROPIC_API_KEY
  SECRET="SECRET-U10-8d2f41"
  strace -f --seccomp-bpf -qq -e trace=execve -s 8192 -o "$TMP/st.ctl" env -i "X=$SECRET" true
  grep -q "$SECRET" "$TMP/st.ctl" && ctl=1 || ctl=0
  set +e
  ( cd "$P" && ANTHROPIC_API_KEY="$SECRET" PATH="$TMP/stubs/claude3/bin:$STUBPATH" strace -f --seccomp-bpf -qq -e trace=execve -s 8192 -o "$TMP/st.out" "$LOOP" analyze --max-retries 0 --agent claude > "$TMP/st.log" 2>&1 )
  src=$?; set -e
  EXPECT="$(printf '%s' "$SECRET" | sha256sum | cut -d' ' -f1)"
  if [[ "$ctl" -eq 1 && "$src" -eq 0 && -s "$TMP/st.out" ]] && ! grep -q "$SECRET" "$TMP/st.out" && [[ "$(cat "$P/.wgm/run/digest.txt" 2>/dev/null)" == "$EXPECT" ]]; then
    pass "U10(1): the credential value is in no execve argv of the whole loop (strace control catches env -i NAME=value); the agent still gets the right value"
  else fail "U10(1) (control=$ctl, rc=$src): $(grep -c "$SECRET" "$TMP/st.out" 2>/dev/null) argv hits; $(tail -2 "$TMP/st.log")"; fi
else echo "skip: no strace — skipping the execve argv audit"; fi

# ---- metrics header migration -------------------------------------------------------------------------------
P="$(newproj l60)"
mkdir -p "$P/.wgm"
printf 'start_timestamp\tend_timestamp\titer\tmode\tagent\tduration_s\tplan_changed\tresult\tcost\tparent\n2020-01-01T00:00:00Z\t2020-01-01T00:00:01Z\t1\tbuild\tmain\t1\t1\tok\t\tnone\n' > "$P/.wgm/m.tsv"
WGM_DEVCONTAINER=0 lp "$P" build 1 --max-retries 0 --commit --metrics .wgm/m.tsv -- bash -c "$AG_PROGRESS" _
if [[ "$LRC" -eq 0 ]] && [[ "$(head -1 "$P/.wgm/m.tsv")" == *$'\tparent\tsandbox' ]] && [[ "$(sed -n 2p "$P/.wgm/m.tsv")" == *$'\tnone' ]] \
   && [[ "$(tail -1 "$P/.wgm/m.tsv")" == *$'\toff:operator-env' ]] && has "sandbox: OFF — unsandboxed (operator-env)" "$LOUT"; then
  pass "metrics: an old ledger gains a trailing sandbox header column in place; opt-out rows say off:<reason>"
else fail "metrics migration (rc=$LRC): $(cat "$P/.wgm/m.tsv")"; fi

# ---- dry run through loop.sh ---------------------------------------------------------------------------------
P="$(newproj l70)"
rm -rf "$XDG_CONFIG_HOME/wgm"
lp "$P" build --dry-run -- bash -c true
if [[ "$LRC" -eq 0 ]] && has "sandbox decision (dry run" "$LOUT" && has "sandbox=on" "$LOUT" && [[ ! -e "$XDG_CONFIG_HOME/wgm" ]] && [[ ! -e "$P/.wgm" ]] && ! tail -1 "$WGM_STUB_TRACE" | grep -q ' run '; then
  pass "loop --dry-run prints the sandbox decision and writes nothing (no record, no .wgm, no container)"
else fail "loop dry-run (rc=$LRC): $LOUT"; fi

# ---- REAL engine: credential copies, readiness, hooks, recovery block ---------------------------------------
if [[ -z "$ENGINE" ]]; then
  echo "skip: no container engine — skipping the real-engine credential-copy / readiness / commit cases"
else
  export PATH="$REAL_PATH"
  RP="$(newproj r1)"
  "$DC" build-base --container "$ENGINE" --tag "$TEST_TAG" >/dev/null 2>&1 || fail "could not build the test image $TEST_TAG"
  export WGM_DEVCONTAINER_IMAGE="$TEST_TAG"
  mkdir -p "$HOME/.pi/agent/extensions" "$HOME/.codex"
  echo '{"token":"pi-secret"}' > "$HOME/.pi/agent/auth.json"; echo '{"token":"codex-secret"}' > "$HOME/.codex/auth.json"
  echo '{"theme":"x"}' > "$HOME/.pi/agent/settings.json"; echo 'evil' > "$HOME/.pi/agent/extensions/evil.js"
  # shellcheck disable=SC2016
  AGENT_BODY='if [[ "${1:-}" == --version ]]; then echo stub; exit 0; fi
mkdir -p .wgm/run
{ ls -A "$HOME/.pi/agent" 2>&1; echo ---; ls -A "$HOME/.codex" 2>&1; } > .wgm/run/seen.txt
echo refreshed >> "$HOME/.pi/agent/auth.json"
if [[ -e .undeletable ]]; then mkdir -p "$HOME/.pi/agent/d"; : > "$HOME/.pi/agent/d/f"; chmod 500 "$HOME/.pi/agent/d"; fi'
  mkstub "$TMP/stubs/pi" pi "$AGENT_BODY"; mkstub "$TMP/stubs/codex" codex "$AGENT_BODY"
  export PATH="$TMP/stubs/pi/bin:$TMP/stubs/codex/bin:$REAL_PATH"
  pty 'y\n' "cd '$RP' && '$SB' preflight --interactive yes --agent-cmd pi --agent-cmd codex"
  RECF="$(compgen -G "$XDG_CONFIG_HOME/wgm/sandbox/*.yml" | grep -v '^$' | while read -r f; do grep -q '^agents: codex pi$' "$f" && echo "$f"; done | head -1 || true)"
  if [[ "$RC" -eq 0 ]] && [[ "$(grep -c 'Mount these into the sandbox' <<<"$OUTO")" -eq 1 ]] && [[ -n "$RECF" ]] \
     && grep -q "$HOME/.pi/agent/auth.json" "$RECF" && grep -q "$HOME/.codex/auth.json" "$RECF" && has "sandbox=on" "$OUTO"; then
    pass "T1: main pi + frugal codex — both token files proposed ONCE; record stores 'agents: codex pi'"
  else fail "T1 approval (rc=$RC): $(printf '%s' "$OUTO" | tail -15)"; fi
  lp "$RP" analyze --max-retries 0 --agent pi --frugal-agent codex
  SEEN="$(cat "$RP/.wgm/run/seen.txt" 2>/dev/null || true)"
  if [[ "$LRC" -eq 0 ]] && has "auth.json" "$SEEN" && has "settings.json" "$SEEN" && ! has "extensions" "$SEEN" \
     && [[ "$(cat "$HOME/.pi/agent/auth.json")" == '{"token":"pi-secret"}' ]] && ! compgen -G "$TMPDIR/wgm-cred.*" >/dev/null; then
    pass "credentials: the agent sees a throwaway COPY (top-level files only, union of agents); refreshes never reach the host; copies deleted"
  else fail "credential copies (rc=$LRC): seen=[$SEEN] $LOUT"; fi
  lp "$RP" analyze --max-retries 0 --agent pi
  if [[ "$LRC" -eq 2 ]] && has "agent set" "$LOUT"; then pass "T1 recovery: removing codex from the run exits 2 headless (re-ask)"; else fail "T1 recovery (rc=$LRC): $LOUT"; fi
  # T5: an undeletable credential copy is reported and the run status is unchanged
  touch "$RP/.undeletable"
  lp "$RP" analyze --max-retries 0 --agent pi --frugal-agent codex
  RET="$(grep -o 'retained credential copy [^ ]*' <<<"$LOUT" | awk '{print $4}' | head -1)"
  if [[ "$LRC" -eq 0 && -n "$RET" && -d "$RET" && "$(stat -c %a "$RET")" == 700 ]] && [[ "$RET" != "$RP"/* ]]; then
    pass "T5: an undeletable credential copy prints 'retained credential copy <path>' (0700, outside every mount); run status unchanged"
  else fail "T5 (rc=$LRC ret='$RET'): $LOUT"; fi
  chmod -R u+rwx "$TMPDIR" 2>/dev/null; rm -rf "$TMPDIR"/wgm-cred.* "$RP/.undeletable"

  # U21/B4 (T1): BOTH the frugal run and the escalated-main run see the union of the approved credential copies
  # shellcheck disable=SC2016  # the stub body expands inside the container
  T1BODY='if [[ "${1:-}" == --version ]]; then echo stub; exit 0; fi
if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
mkdir -p .wgm/run; { ls -A "$HOME/.pi/agent"; echo ---; ls -A "$HOME/.codex"; } > ".wgm/run/seen-$(basename "$0").txt"'
  mkstub "$TMP/stubs/pi2" pi "$T1BODY"; mkstub "$TMP/stubs/codex2" codex "$T1BODY"
  rm -f "$RP/.wgm/run/seen-"*.txt
  PATH="$TMP/stubs/pi2/bin:$TMP/stubs/codex2/bin:$REAL_PATH" lp "$RP" build 3 --max-retries 0 --max-no-progress-iterations 0 --escalate-after 1 --agent pi --frugal-agent codex
  sf="$(cat "$RP/.wgm/run/seen-codex.txt" 2>/dev/null || true)"; sm="$(cat "$RP/.wgm/run/seen-pi.txt" 2>/dev/null || true)"
  if has "escalating to main agent" "$LOUT" && has "auth.json" "$sf" && has "---" "$sf" && [[ "$(grep -c auth.json <<<"$sf")" -eq 2 ]] && [[ "$(grep -c auth.json <<<"$sm")" -eq 2 ]]; then
    pass "T1: the frugal (codex) run and the escalated main (pi) run each see BOTH approved credential copies"
  else fail "T1 frugal+escalated (rc=$LRC): frugal=[$sf] main=[$sm] $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
  rm -rf "$TMPDIR"/wgm-cred.* 2>/dev/null || true

  # readiness + commit with the real engine; hooks run INSIDE only
  RP="$(newproj r2)"
# shellcheck disable=SC2016  # the command runs inside the container: expansion happens there
  printf '#!/bin/sh\necho "$WGM_IN_DEVCONTAINER" > "%s/hook-env.txt"\n' "$RP" > "$RP/.git/hooks/pre-commit"; chmod +x "$RP/.git/hooks/pre-commit"
  export PATH="$REAL_PATH"
  lp "$RP" build 1 --max-retries 0 --commit -- bash -c "$AG_PROGRESS" _
  if [[ "$LRC" -eq 0 ]] && [[ "$(git -C "$RP" rev-list --count HEAD)" -eq 2 ]] && [[ "$(cat "$RP/hook-env.txt" 2>/dev/null)" == 1 ]] && [[ "$(stat -c %U "$RP/hook-env.txt")" == "$(id -un)" ]]; then
    pass "real engine: the commit's pre-commit hook ran INSIDE the container (WGM_IN_DEVCONTAINER=1), authored as the operator"
  else fail "real-engine commit/hook (rc=$LRC): $LOUT"; fi
  rm -f "$RP/hook-env.txt"

  # U39: an UNRELATED container named wgm-unrelated-<rand> exists for the whole real-engine section — no count may be
  # failed by it and no cleanup may remove it (it is checked, then removed, at the end of the section)
  UNREL="wgm-unrelated-$RANDOM$RANDOM"; UNREL_IMG="$("$ENGINE" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' | head -1 || true)"
  if [[ -n "$UNREL_IMG" ]] && "$ENGINE" create --name "$UNREL" "$UNREL_IMG" true >/dev/null 2>&1; then UNREL_MADE=1; else UNREL_MADE=0; echo "skip: could not create the unrelated sentinel container — the U39 survival check is skipped"; fi
  # cancellation (U1): a sleeping agent in a REAL container; SIGTERM → exit 143 quickly, container gone
  RP="$(newproj r4)"
  : > "$TMP/rmark"; rm -f "$TMP/rmark"
  # shellcheck disable=SC2016  # expanded inside the container
  ( cd "$RP" && exec env WGM_TEST_MARK="$TMP/rmark" "$LOOP" analyze --max-retries 0 -- bash -c 'touch "$WGM_TEST_MARK"; sleep 300' _ > "$TMP/rsig.out" 2>&1 ) &
  rpid=$!
  for _i in $(seq 1 300); do [[ -e "$TMP/rmark" ]] && break; sleep 0.2; done
  during="$(my_container_count "$ENGINE")"   # positive control: the run-specific filter DOES see this run's live container
  t0=$SECONDS; kill -TERM "$rpid" 2>/dev/null || true
  set +e; wait "$rpid"; rrc=$?; set -e
  left="$(my_container_count "$ENGINE")"
  if [[ "$rrc" -eq 143 && $((SECONDS - t0)) -lt 20 && "$left" -eq 0 && "$during" -ge 1 ]] && ! grep -q 'retained container' "$TMP/rsig.out"; then
    pass "cancellation: SIGTERM to a loop with a sleeping in-container agent exits 143 in <20s and leaves no container"
  else fail "cancellation (rc=$rrc, $((SECONDS - t0))s, left=$left, live-during=$during): $(grep -v dropped "$TMP/rsig.out" | tail -3)"; fi
  my_containers_rm "$ENGINE"

  # gate quoting (U1): gates reach `bash -c` inside as ONE argv element, each once for the smoke and once per iteration
  RP="$(newproj r5)"; mkdir -p "$RP/.wgm"
  cat > "$RP/.wgm/gates.yml" <<'GATES'
gates:
  - mkdir -p .wgm/obs
  - sh -c 'echo single-$WGM_IN_DEVCONTAINER >> .wgm/obs/g.txt'
  - echo "double $WGM_IN_DEVCONTAINER" >> .wgm/obs/g.txt && echo and-and >> .wgm/obs/g.txt
  - echo   spaced    args >> .wgm/obs/g.txt
GATES
  # shellcheck disable=SC2016
  GAG='if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- step\n" >> IMPLEMENTATION_PLAN.md'
  lp "$RP" build 1 --max-retries 0 -- bash -c "$GAG" _
  G="$RP/.wgm/obs/g.txt"
  if [[ "$LRC" -eq 0 ]] && [[ "$(grep -cFx 'single-1' "$G")" -eq 2 ]] && [[ "$(grep -cFx 'double 1' "$G")" -eq 2 ]] && [[ "$(grep -cFx 'and-and' "$G")" -eq 2 ]] \
     && [[ "$(grep -cFx 'spaced args' "$G")" -eq 2 ]]; then
    pass "gate quoting: single/double quotes, \$VAR, && and spaces run inside exactly as on the host, once for the smoke and once per iteration"
  else fail "gate quoting (rc=$LRC): $(tr '\n' '|' < "$G" 2>/dev/null) $(grep -v dropped <<<"$LOUT" | tail -4)"; fi

  # U2: no host-written temp has a predictable in-project name. The agent learns the loop PID from the
  # manifest name and plants PID-named symlinks at every legacy temp name; the outside sentinel must not change.
  RP="$(newproj r6)"; mkdir -p "$RP/.wgm"
  printf 'start_timestamp\tend_timestamp\titer\tmode\tagent\tduration_s\tplan_changed\tresult\tcost\tparent\n' > "$RP/.wgm/metrics.tsv"
  printf 'sentinel-original\n' > "$TMP/outside-sentinel"; SUM0="$(sha256sum "$TMP/outside-sentinel")"
  # shellcheck disable=SC2016
  PLANT='if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
pid="${WGM_OWNERSHIP_MANIFEST##*-}"
for n in .wgm/metrics.tsv.mig.$pid .wgm/run/.loop-status-$pid .wgm/run/.loop-owned-1-$pid .wgm/run/.loop-actual-1-$pid .wgm/run/.loop-staged-1-$pid; do ln -sf "$WGM_TEST_OUTSIDE" "$n"; done
printf -- "- step\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"'
  mkdir -p "$RP/.wgm/run"
  WGM_TEST_OUTSIDE="$TMP/outside-sentinel" lp "$RP" build 1 --max-retries 0 --commit -- bash -c "$PLANT" _
  if [[ "$(sha256sum "$TMP/outside-sentinel")" == "$SUM0" ]] && [[ "$(git -C "$RP" rev-list --count HEAD)" -eq 2 ]] && head -1 "$RP/.wgm/metrics.tsv" | grep -q $'\tsandbox$'; then
    pass "U2: agent-planted PID-named symlinks at legacy temp names cannot redirect a host write (outside file byte-identical)"
  else fail "U2 host temp write (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -4)"; fi

  # U3: the trusted runner is established BEFORE preflight. The skill dir lives inside the project and the
  # agent's own `--version` (readiness) and probe replace wgm's scripts with copies that touch a HOST marker.
  RP="$(newproj r7)"; mkdir -p "$RP/skill"; cp -R "$ROOT/scripts" "$RP/skill/scripts"; cp -R "$ROOT/assets" "$RP/skill/assets"
  HOSTMARK="$TMP/host-marker"; rm -f "$HOSTMARK"
  # shellcheck disable=SC2016
  mkstub "$TMP/stubs/evil" evil 'for f in loop sandbox devcontainer; do
  src="$PWD/skill/scripts/$f.sh"; [ -f "$src" ] || continue
  { sed -n 1p "$src"; echo "touch \"$WGM_TEST_HOSTMARK\""; sed -n "2,\$p" "$src"; } > "$src.new" && chmod +x "$src.new" && mv "$src.new" "$src"
done
if [ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; elif [ "${1:-}" != --version ]; then printf -- "- evil step\n" >> IMPLEMENTATION_PLAN.md; fi
exit 0'
  export PATH="$TMP/stubs/evil/bin:$REAL_PATH"
  set +e; LOUT="$(cd "$RP" && WGM_TEST_HOSTMARK="$HOSTMARK" "$RP/skill/scripts/loop.sh" plan --max-retries 0 -- evil 2>&1)"; LRC=$?; set -e
  if [[ "$LRC" -eq 0 && ! -e "$HOSTMARK" ]] && has "trusted runner snapshot" "$LOUT" && grep -q 'touch "' "$RP/skill/scripts/loop.sh"; then
    pass "U3: scripts replaced by the agent during readiness/probe never run on the host (snapshot taken before preflight); the run still works"
  else fail "U3 trusted runner (rc=$LRC, marker=$([[ -e $HOSTMARK ]] && echo yes || echo no)): $(grep -v dropped <<<"$LOUT" | tail -4)"; fi
  export PATH="$REAL_PATH"

  # U4: inspections fail CLOSED. An unreadable (mode 000) project subdir holding a hard link to a file
  # outside every mount must refuse the launch; otherwise the contained agent (same UID) could chmod it
  # back and modify the outside inode.
  RP="$(newproj r8)"
  printf 'outside-original\n' > "$TMP/outside-hl"; SUMH="$(sha256sum "$TMP/outside-hl")"
  mkdir "$RP/locked"; ln "$TMP/outside-hl" "$RP/locked/hl"; chmod 000 "$RP/locked"
  : > "$WGM_STUB_TRACE"
  # shellcheck disable=SC2016
  lp "$RP" analyze --max-retries 0 -- bash -c 'chmod 700 locked; echo pwned >> locked/hl' _
  if [[ "$LRC" -eq 2 ]] && has "locked" "$LOUT" && has "could not inspect" "$LOUT" && [[ "$(sha256sum "$TMP/outside-hl")" == "$SUMH" ]]; then
    pass "U4(1): an unreadable project subdir makes the hard-link scan refuse the launch (exit 2, names locked); outside file unchanged"
  else fail "U4(1) (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
  chmod 755 "$RP/locked"
  lp "$RP" analyze --max-retries 0 -- bash -c 'true' _
  if [[ "$LRC" -eq 2 ]] && has "hard link" "$LOUT"; then pass "U4(2): with permissions restored the hard link is found and refused"; else fail "U4(2) (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
  rm -f "$RP/locked/hl"
  lp "$RP" analyze --max-retries 0 -- bash -c 'true' _
  if [[ "$LRC" -eq 0 && "$(sha256sum "$TMP/outside-hl")" == "$SUMH" ]]; then pass "U4(3): with the hard link removed the loop runs"; else fail "U4(3) (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
  # a dir under the git dir's info/ that cannot be listed (pin listing) is refused too
  RP="$(newproj r9)"; mkdir "$RP/.git/info/sub"; chmod 000 "$RP/.git/info/sub"
  lp "$RP" analyze --max-retries 0 -- bash -c 'true' _
  if [[ "$LRC" -eq 2 ]] && has "could not inspect" "$LOUT" && has "info/sub" "$LOUT"; then pass "U4: an unreadable dir under the git dir's info/ is refused (fail closed)"; else fail "U4 pin listing (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
  chmod 755 "$RP/.git/info/sub"

  # U6: host tools must resolve OUTSIDE writable mounts. A PATH dir outside every mount whose entries are
  # symlinks into the project (or dangling ones) is refused before any container; a clean dir is fine.
  RP="$(newproj r10)"; mkdir -p "$RP/tools" "$TMP/pathx" "$TMP/pathy" "$TMP/pathz"
  HOSTMARK2="$TMP/host-marker2"; rm -f "$HOSTMARK2"
  # shellcheck disable=SC2016  # the wrapper body expands when it runs
  printf '#!/usr/bin/env bash\ntouch "%s"\nexec "$(PATH="%s" command -v date)" "$@"\n' "$HOSTMARK2" "/usr/bin:/bin" > "$RP/tools/date"; chmod +x "$RP/tools/date"
  ln -sf "$RP/tools/date" "$TMP/pathx/date"; ln -sf "$RP/tools/not-yet" "$TMP/pathx/mktemp"
  ln -sf "$RP/tools/not-yet" "$TMP/pathy/mktemp"
  ln -sf "$(command -v date)" "$TMP/pathz/date"; ln -sf "$(command -v git)" "$TMP/pathz/git"
  PATH="$TMP/pathx:$REAL_PATH" lp "$RP" analyze --max-retries 0 -- bash -c 'true' _
  if [[ "$LRC" -eq 2 ]] && has "host tool $TMP/pathx/" "$LOUT" && has "$RP/tools/" "$LOUT" && [[ ! -e "$HOSTMARK2" ]]; then
    pass "U6(1): PATH-dir symlinks into the writable project are refused before any container (names link -> target); no host marker"
  else fail "U6(1) (rc=$LRC, marker=$([[ -e $HOSTMARK2 ]] && echo yes || echo no)): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
  PATH="$TMP/pathy:$REAL_PATH" lp "$RP" analyze --max-retries 0 -- bash -c 'true' _
  if [[ "$LRC" -eq 2 ]] && has "$TMP/pathy/mktemp -> $RP/tools/not-yet" "$LOUT"; then pass "U6(2): a DANGLING link into the project is refused too"; else fail "U6(2) (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
  PATH="$TMP/pathz:$REAL_PATH" lp "$RP" analyze --max-retries 0 -- bash -c 'true' _
  if [[ "$LRC" -eq 0 ]]; then pass "U6(3): an outside PATH dir whose symlinks point outside every mount runs normally"; else fail "U6(3) (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi

  # U7(1): host reads of agent-writable paths refuse symlinks/non-regular files BEFORE reading or dispatching a helper
  RP="$(newproj r11)"; mkdir -p "$RP/.wgm"; printf 'host-secret\n' > "$TMP/host-secret"
  # shellcheck disable=SC2016
  MEMAG='if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
printf -- "- step\n" >> IMPLEMENTATION_PLAN.md; ln -sf "$WGM_TEST_OUTSIDE" .wgm/memories.md; touch .wgm/STOP'
  WGM_TEST_OUTSIDE="$TMP/host-secret" lp "$RP" build 1 --max-retries 0 -- bash -c "$MEMAG" _
  if [[ "$LRC" -eq 2 ]] && has "agent-written symlink at $RP/.wgm/memories.md" "$LOUT" && ! has "invoking consent-gated harvest" "$LOUT"; then
    pass "U7(1): an agent-planted memories.md symlink is refused (exit 2) before hashing or dispatching harvest-hive"
  else fail "U7(1) (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -4)"; fi

  # U7(3): cancellation of launches that happen inside captured-output contexts
  cancel_case() {  # cancel_case NAME PROJECT ARGS… — TERM the loop once the slow in-container command is running
    local nm="$1" d="$2"; shift 2
    rm -f "$TMP/cmark"
    ( cd "$d" && exec env WGM_TEST_MARK="$TMP/cmark" "$LOOP" "$@" > "$TMP/c.out" 2>&1 ) &
    local cpid=$!
    for _i in $(seq 1 300); do [[ -e "$TMP/cmark" ]] && break; sleep 0.2; done
    local t1=$SECONDS; kill -TERM "$cpid" 2>/dev/null || true
    set +e; wait "$cpid"; local crc=$?; set -e
    local left; left="$(my_container_count "$ENGINE")"
    if [[ "$crc" -eq 143 && $((SECONDS - t1)) -lt 20 && "$left" -eq 0 ]]; then pass "U7(3): SIGTERM during $nm exits 143 in <20s and leaves no container"
    else fail "U7(3) $nm (rc=$crc, $((SECONDS - t1))s, left=$left): $(grep -v dropped "$TMP/c.out" | tail -3)"; fi
    my_containers_rm "$ENGINE"
  }
  RP="$(newproj r12)"
  # shellcheck disable=SC2016
  cancel_case "a slow --cost-cmd" "$RP" build 1 --max-retries 0 --cost-cmd 'touch "$WGM_TEST_MARK"; sleep 300' -- bash -c "$GAG" _
  RP="$(newproj r13)"
  # shellcheck disable=SC2016
  mkstub "$TMP/stubs/slowv" slowv 'if [ "${1:-}" = --version ]; then touch "$WGM_TEST_MARK"; sleep 300; fi; exit 0'
  PATH="$TMP/stubs/slowv/bin:$REAL_PATH" cancel_case "a slow readiness --version (preflight)" "$RP" analyze --max-retries 0 -- slowv

  # U8: none of the host git protections leaks into a container
  RP="$(newproj r14)"
  # shellcheck disable=SC2016
  ENVAG='mkdir -p .wgm/run; env > .wgm/run/env.txt; if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; fi'
  lp "$RP" analyze --max-retries 0 -- bash -c "$ENVAG" _
  EV="$RP/.wgm/run/env.txt"
  if [[ "$LRC" -eq 0 && -s "$EV" ]] && ! grep -Eq '^(GIT_ALLOW_PROTOCOL|GIT_NO_LAZY_FETCH|GIT_TERMINAL_PROMPT|GIT_PAGER|GIT_EDITOR|WGM_GIT_ENV_APPLIED)=' "$EV" \
     && ! grep -E '^GIT_CONFIG_(KEY|VALUE)_[0-9]+=' "$EV" | grep -Eq 'core\.fsmonitor|core\.hooksPath|protocol\.allow|/dev/null'; then
    pass "U8: a contained command sees none of the host git-protection variables (GIT_ALLOW_PROTOCOL, GIT_NO_LAZY_FETCH, hooksPath/fsmonitor/protocol keys)"
  else fail "U8 container env (rc=$LRC): $(grep -E '^GIT_' "$EV" 2>/dev/null | tr '\n' ' ')"; fi

  # U9(1): a STANDALONE preflight (as swarm runs it) handles SIGTERM during a slow readiness: exit 143 fast, no container left
  RP="$(newproj r15)"
  rm -f "$TMP/pmark"
  ( cd "$RP" && exec env PATH="$TMP/stubs/slowv/bin:$REAL_PATH" WGM_TEST_MARK="$TMP/pmark" "$SB" preflight --agent-cmd slowv > "$TMP/p.out" 2>&1 ) &
  ppid_=$!
  for _i in $(seq 1 300); do [[ -e "$TMP/pmark" ]] && break; sleep 0.2; done
  t2=$SECONDS; kill -TERM "$ppid_" 2>/dev/null || true
  set +e; wait "$ppid_"; prc=$?; set -e
  left="$(my_container_count "$ENGINE")"
  if [[ "$prc" -eq 143 && $((SECONDS - t2)) -lt 20 && "$left" -eq 0 ]]; then pass "U9(1): SIGTERM to a standalone preflight during a slow readiness exits 143 in <20s and leaves no container"
  else fail "U9(1) (rc=$prc, $((SECONDS - t2))s, left=$left): $(grep -v dropped "$TMP/p.out" | tail -3)"; fi
  my_containers_rm "$ENGINE"

  # U10(2): an APPROVED token that no longer exists makes readiness fail (exit 2, named); restoring it runs again
  RP="$(newproj r16)"; mkdir -p "$HOME/.pi/agent"; echo '{"token":"pi-secret"}' > "$HOME/.pi/agent/auth.json"
  mkstub "$TMP/stubs/pi" pi 'echo pi-stub'
  pty 'y\n' "cd '$RP' && PATH='$TMP/stubs/pi/bin:$REAL_PATH' '$SB' preflight --interactive yes --agent-cmd pi"
  cp "$HOME/.pi/agent/auth.json" "$TMP/auth.bak"; rm -f "$HOME/.pi/agent/auth.json"
  PATH="$TMP/stubs/pi/bin:$REAL_PATH" lp "$RP" analyze --max-retries 0 --agent pi
  if [[ "$LRC" -eq 2 ]] && has "auth.json" "$LOUT" && has "not reachable" "$LOUT"; then pass "U10(2): a removed approved token → exit 2 naming auth.json with recovery text"; else fail "U10(2) removed token (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
  cp "$TMP/auth.bak" "$HOME/.pi/agent/auth.json"
  PATH="$TMP/stubs/pi/bin:$REAL_PATH" lp "$RP" analyze --max-retries 0 --agent pi
  if [[ "$LRC" -eq 0 ]]; then pass "U10(2): with the token restored the loop runs"; else fail "U10(2) restored (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi

  # U11 (real engine): the same repo (helpers under <common>/custom, writable by the agent) through a sandboxed loop:
  # no helper fires on the HOST (sentinels live outside every mount, so contained runs cannot create them either)
  RP="$(newproj r17)"; NC="$RP/.git/custom"; mkdir -p "$NC"
  for h in clean smudge textconv ext; do printf '#!/bin/sh\ntouch "%s/fired-%s"\ncat\n' "$TMP" "$h" > "$NC/$h.sh"; chmod +x "$NC/$h.sh"; done
  git -C "$RP" config filter.wgmc.clean "$NC/clean.sh"; git -C "$RP" config filter.wgmc.smudge "$NC/smudge.sh"
  git -C "$RP" config diff.wgmc.textconv "$NC/textconv.sh"; git -C "$RP" config diff.external "$NC/ext.sh"
  echo '*.wgm filter=wgmc diff=wgmc' > "$RP/.gitattributes"; echo one > "$RP/a.wgm"; git -C "$RP" add -A; git -C "$RP" -c filter.wgmc.clean= commit -qm filtered
  rm -f "$TMP"/fired-*; touch "$RP/a.wgm"; echo changed >> "$RP/a.wgm"
  lp "$RP" build 1 --max-retries 0 -- bash -c "$GAG" _
  wgm_host_git -C "$RP" status >/dev/null 2>&1 || true
  if [[ "$LRC" -eq 0 ]] && ! ls "$TMP"/fired-* >/dev/null 2>&1; then pass "U11: a sandboxed loop over a repo with configured filter/diff helpers (incl. one inside the shared git dir) runs none of them on the host"; else fail "U11 loop (rc=$LRC): fired=$(find "$TMP" -maxdepth 1 -name 'fired-*' | tr '\n' ' ')"; fi

  # U13 (S51 route): an operator's read-only post-commit hook delegates to a TRACKED helper the agent changed; the
  # contained commit replaces the lane's admin index with a symlink to an outside canary. The host must refuse
  # (exit 2, naming the index) and never open the canary.
  RP="$(newproj r18)"; echo "canary51" > "$TMP/canary51"
  git -C "$RP" worktree add -q "$TMP/lane18" -b lane18
  printf '#!/bin/sh\nexec sh ./helper.sh\n' > "$RP/.git/hooks/post-commit"; chmod +x "$RP/.git/hooks/post-commit"
  printf '#!/bin/sh\n:\n' > "$TMP/lane18/helper.sh"; git -C "$TMP/lane18" add helper.sh; git -C "$TMP/lane18" -c core.hooksPath=/dev/null commit -qm helper
  # shellcheck disable=SC2016
  AG18='if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- step\n" >> IMPLEMENTATION_PLAN.md; printf "#!/bin/sh\nadm=\"\$(git rev-parse --absolute-git-dir)\"\nrm -f \"\$adm/index\"; ln -s \"%s\" \"\$adm/index\"\n" "$WGM_TEST_OUTSIDE" > helper.sh; printf "IMPLEMENTATION_PLAN.md\nhelper.sh\n" > "$WGM_OWNERSHIP_MANIFEST"'
  if [[ "$have_strace" -eq 1 ]]; then
    set +e; LOUT="$(cd "$TMP/lane18" && strace -f --seccomp-bpf -y -e trace=openat -o "$TMP/u13.s51" env WGM_TEST_OUTSIDE="$TMP/canary51" "$LOOP" build 1 --max-retries 0 --commit -- bash -c "$AG18" _ 2>&1)"; LRC=$?; set -e
    n="$(resolved_opens "$TMP/u13.s51" canary51)"
  else WGM_TEST_OUTSIDE="$TMP/canary51" lp "$TMP/lane18" build 1 --max-retries 0 --commit -- bash -c "$AG18" _; n=0; fi
  if [[ "$LRC" -eq 2 && "$n" -eq 0 ]] && has "worktrees/lane18/index" "$LOUT" && has "host git refused" "$LOUT"; then
    pass "U13 (S51): the contained post-commit swap of the lane's admin index is refused by the phase-boundary scan (exit 2, names the index); the host never opened the canary"
  else fail "U13 S51 (rc=$LRC, resolved opens=$n): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi

  # U14 (S52 route): the contained agent REDIRECTS a worktree's pointer files to a SECOND repository outside every
  # mount. The host must reject the pointer mismatch FIRST: zero successful opens under the outside repo
  # (strace -f --seccomp-bpf -y; visible skip without strace), exit 2 "git metadata changed".
  if [[ "$have_strace" -eq 1 ]]; then
    OUTR="$TMP/outrepo"; git init -q "$OUTR"; ( cd "$OUTR" && git config user.email t@e && git config user.name t && echo o > o && git add o && git commit -qm o )
    opens_under() { { grep -E "= [0-9]+<$2/" "$1" || true; } | wc -l; }
    # positive control: plain git on a worktree whose commondir was redirected DOES open the outside repo
    RP="$(newproj r19c)"; git -C "$RP" worktree add -q "$TMP/lane19c" -b lane19c
    printf '%s\n' "$OUTR/.git" > "$RP/.git/worktrees/lane19c/commondir"
    strace -f --seccomp-bpf -y -e trace=openat -o "$TMP/u14.ctl" git -C "$TMP/lane19c" status >/dev/null 2>&1 || true
    [[ "$(opens_under "$TMP/u14.ctl" "$OUTR")" -ge 1 ]] && ctl=1 || ctl=0
    # shellcheck disable=SC2016  # the agent bodies expand inside the container
    s52_agent() {
      case "$1" in
        A) printf '%s' 'adm="$(git rev-parse --absolute-git-dir)"; printf "%s\n" "$WGM_TEST_OUTSIDE/.git" > "$adm/commondir"' ;;
        B) printf '%s' 'printf "gitdir: %s\n" "$WGM_TEST_OUTSIDE/.git" > .git' ;;
        C) printf '%s' 'adm="$(git rev-parse --absolute-git-dir)"; printf "%s\n" "$WGM_TEST_OUTSIDE/.git/HEAD" > "$adm/gitdir"' ;;
      esac
    }
    for v in A B C; do
      RP="$(newproj "r19$v")"; git -C "$RP" worktree add -q "$TMP/lane19$v" -b "lane19$v"
      set +e; LOUT="$(cd "$TMP/lane19$v" && env WGM_TEST_OUTSIDE="$OUTR" strace -f --seccomp-bpf -y -e trace=openat -o "$TMP/u14.$v" "$LOOP" analyze --max-retries 0 -- bash -c "$(s52_agent "$v")" _ 2>&1)"; LRC=$?; set -e
      n="$(opens_under "$TMP/u14.$v" "$OUTR")"
      if [[ "$ctl" -eq 1 && "$LRC" -eq 2 && "$n" -eq 0 ]] && has "git metadata changed" "$LOUT"; then
        pass "U14(S52-$v): a redirected worktree pointer ($v) is rejected first (exit 2, 'git metadata changed') with zero opens under the outside repo (plain git opens it: control)"
      else fail "U14(S52-$v) (control=$ctl rc=$LRC outside-opens=$n): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
    done
  else echo "skip: no strace — skipping the U14 pointer-first opens audit"; fi
  # a normal worktree is unaffected
  RP="$(newproj r19n)"; git -C "$RP" worktree add -q "$TMP/lane19n" -b lane19n
  lp "$TMP/lane19n" analyze --max-retries 0 -- bash -c 'true' _
  if [[ "$LRC" -eq 0 ]]; then pass "U14: a normal worktree lane runs unaffected by the pointer-first checks"; else fail "U14 normal worktree (rc=$LRC): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi

  # U15(1) (S53 route): the contained command renames the worktree's admin dir and puts a symlink to an OUTSIDE dir
  # (holding regular gitdir/commondir files) in its place. The host must refuse before reading ANYTHING under the
  # replaced ancestor: zero successful opens that resolve under the outside dir (strace -f --seccomp-bpf -y; control: plain git does).
  if [[ "$have_strace" -eq 1 ]]; then
    FAKE="$TMP/fakeadm"; rm -rf "$FAKE"
    opens_in() { { grep -E "= [0-9]+<$2/" "$1" || true; } | wc -l; }
    RP="$(newproj r20c)"; git -C "$RP" worktree add -q "$TMP/lane20c" -b lane20c
    mkdir -p "$FAKE"; printf '%s\n' "$TMP/lane20c/.git" > "$FAKE/gitdir"; printf '../..\n' > "$FAKE/commondir"; : > "$FAKE/HEAD"
    mv "$RP/.git/worktrees/lane20c" "$RP/.git/worktrees/lane20c.moved"; ln -s "$FAKE" "$RP/.git/worktrees/lane20c"
    strace -f --seccomp-bpf -y -e trace=openat -o "$TMP/u15.ctl" git -C "$TMP/lane20c" status >/dev/null 2>&1 || true
    [[ "$(opens_in "$TMP/u15.ctl" "$FAKE")" -ge 1 ]] && ctl=1 || ctl=0
    rm -rf "$FAKE"; mkdir -p "$FAKE"; printf '%s\n' "$TMP/lane20/.git" > "$FAKE/gitdir"; printf '../..\n' > "$FAKE/commondir"
    RP="$(newproj r20)"; git -C "$RP" worktree add -q "$TMP/lane20" -b lane20
    # shellcheck disable=SC2016  # expands inside the container
    S53='adm="$(git rev-parse --absolute-git-dir)"; mv "$adm" "$adm.moved" && ln -s "$WGM_TEST_OUTSIDE" "$adm"'
    set +e; LOUT="$(cd "$TMP/lane20" && env WGM_TEST_OUTSIDE="$FAKE" strace -f --seccomp-bpf -y -e trace=openat -o "$TMP/u15.out" "$LOOP" analyze --max-retries 0 -- bash -c "$S53" _ 2>&1)"; LRC=$?; set -e
    n="$(opens_in "$TMP/u15.out" "$FAKE")"
    if [[ "$ctl" -eq 1 && "$LRC" -eq 2 && "$n" -eq 0 ]] && has "symlink" "$LOUT"; then
      pass "U15(1): a replaced admin-dir ancestor (symlink to an outside dir) is refused (exit 2) with zero opens under the outside dir (plain git opens it: control)"
    else fail "U15(1) (control=$ctl rc=$LRC outside-opens=$n): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
  else echo "skip: no strace — skipping the U15 replaced-ancestor opens audit"; fi

  # U15(2) (S54 route): a normal home-level installation; the sandboxed agent must be able to READ the running skill
  # at its host path and at the conventional skills dirs (and not write them)
  SK="$HOME/.agents/skills/wgm"; mkdir -p "$SK"
  cp -R "$ROOT/scripts" "$SK/scripts"; cp -R "$ROOT/assets" "$SK/assets"; cp -R "$ROOT/references" "$SK/references"; cp "$ROOT/SKILL.md" "$SK/SKILL.md"
  RP="$(newproj r21)"
  # shellcheck disable=SC2016  # expands inside the container
  SKAG='mkdir -p .wgm/run; o=.wgm/run/skill.txt; : > "$o"
for f in "$WGM_TEST_SKILL/SKILL.md" /home/wgm/.agents/skills/wgm/SKILL.md; do head -c 20 "$f" > /dev/null 2>&1 && echo "read:$f" >> "$o"; (echo x >> "$f") 2>/dev/null && echo "WRITABLE:$f" >> "$o"; done; true'
  set +e; LOUT="$(cd "$RP" && env WGM_TEST_SKILL="$SK" "$SK/scripts/loop.sh" analyze --max-retries 0 -- bash -c "$SKAG" _ 2>&1)"; LRC=$?; set -e
  SKO="$(cat "$RP/.wgm/run/skill.txt" 2>/dev/null || true)"
  if [[ "$LRC" -eq 0 ]] && has "read:$SK/SKILL.md" "$SKO" && has "read:/home/wgm/.agents/skills/wgm/SKILL.md" "$SKO" && ! has "WRITABLE" "$SKO"; then
    pass "U15(2): a home-level skill install is READ-ONLY readable inside the sandbox at its host path and at ~/.agents/skills/wgm"
  else fail "U15(2) (rc=$LRC): [$SKO] $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
  # a skill INSIDE the project: the conventional path points at the read-only snapshot (the in-project copy stays the project's rw)
  RP="$(newproj r22)"; mkdir -p "$RP/skill"; cp -R "$SK/." "$RP/skill/"
  # shellcheck disable=SC2016  # expands inside the container
  SKAG2='mkdir -p .wgm/run; o=.wgm/run/skill.txt; : > "$o"; f=/home/wgm/.agents/skills/wgm/SKILL.md
head -c 20 "$f" > /dev/null 2>&1 && echo "read:$f" >> "$o"; (echo x >> "$f") 2>/dev/null && echo "WRITABLE:$f" >> "$o"; true'
  set +e; LOUT="$(cd "$RP" && "$RP/skill/scripts/loop.sh" analyze --max-retries 0 -- bash -c "$SKAG2" _ 2>&1)"; LRC=$?; set -e
  SKO="$(cat "$RP/.wgm/run/skill.txt" 2>/dev/null || true)"
  if [[ "$LRC" -eq 0 ]] && has "read:/home/wgm/.agents/skills/wgm/SKILL.md" "$SKO" && ! has "WRITABLE" "$SKO" && has "trusted runner snapshot" "$LOUT"; then
    pass "U15(2): a skill inside the project is served read-only from the trusted-runner snapshot at the conventional path"
  else fail "U15(2) in-project (rc=$LRC): [$SKO] $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
  rm -rf "$SK"

  # U18 (S55 via a sandboxed loop): the agent replaces <common>/worktrees with a symlink to an outside copy
  if [[ "$have_strace" -eq 1 ]]; then
    RP="$(newproj r23)"; git -C "$RP" worktree add -q "$TMP/lane23" -b lane23
    OUTX="$TMP/outwt23"; rm -rf "$OUTX"; cp -a "$RP/.git/worktrees" "$OUTX"   # pre-populated OUTSIDE the traced run (the agent opens nothing there)
    # shellcheck disable=SC2016  # expands inside the container
    S55='adm="$(git rev-parse --absolute-git-dir)"; common="${adm%/worktrees/*}"; mv "$common/worktrees" "$common/worktrees.moved" && ln -s "$WGM_TEST_OUTSIDE" "$common/worktrees"'
    # (stub engine: with a real engine the read-only overlays nested in worktrees/ make the rename itself fail EBUSY)
    set +e; LOUT="$(cd "$TMP/lane23" && env PATH="$STUBPATH" WGM_TEST_OUTSIDE="$OUTX" strace -f --seccomp-bpf -y -e trace=openat -o "$TMP/u18.loop" "$LOOP" analyze --max-retries 0 -- bash -c "$S55" _ 2>&1)"; LRC=$?; set -e
    n="$({ grep -E "= [0-9]+<$OUTX/" "$TMP/u18.loop" || true; } | wc -l)"
    if [[ "$LRC" -eq 2 && "$n" -eq 0 ]] && has "$RP/.git/worktrees" "$LOUT"; then
      pass "U18(2): a sandboxed loop (stub engine) in a worktree whose agent replaced <common>/worktrees exits 2 naming it, with zero opens under the outside copy"
    else fail "U18(2) (rc=$LRC outside-opens=$n): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
  fi

  # U19 (S56): a timed-out agent whose container cannot be removed (engine shim: rm fails, ps keeps reporting it) stops
  # the run TERMINALLY: exit 2, the exact handle + recovery, exactly ONE agent invocation, ZERO host git calls after
  # the first failed reap. The normal timeout path (absence confirmed) still retries.
  mkdir -p "$TMP/engshim"
  REAL_PODMAN="$(command -v podman || true)"
  if [[ -n "$REAL_PODMAN" ]]; then
    cat > "$TMP/engshim/podman" <<SHIM
#!/usr/bin/env bash
case "\${1:-}" in
  rm) echo "ENGINE rm \$*" >> "\$WGM_U19_LOG"; exit 1 ;;
  ps) if [[ "\$*" =~ name=\\^([^\\\$]+)\\\$ ]]; then printf '%s\\n' "\${BASH_REMATCH[1]}"; fi; exit 0 ;;
esac
exec "$REAL_PODMAN" "\$@"
SHIM
    chmod +x "$TMP/engshim/podman"
    cat > "$TMP/engshim/git" <<SHIM
#!/usr/bin/env bash
echo "GIT \$*" >> "\$WGM_U19_LOG"
exec "$REAL_GIT" "\$@"
SHIM
    chmod +x "$TMP/engshim/git"
    export WGM_U19_LOG="$TMP/u19.log"; : > "$WGM_U19_LOG"
    RP="$(newproj r24)"
    # shellcheck disable=SC2016  # expands inside the container
    SLOW='mkdir -p .wgm/run; echo x >> .wgm/run/inv.txt; sleep 300'
    set +e; LOUT="$(cd "$RP" && PATH="$TMP/engshim:$REAL_PATH" "$LOOP" analyze --max-retries 2 --agent-timeout-seconds 5 -- bash -c "$SLOW" _ 2>&1)"; LRC=$?; set -e
    inv="$(wc -l < "$RP/.wgm/run/inv.txt" 2>/dev/null || echo 0)"
    first_rm="$(grep -n '^ENGINE rm' "$WGM_U19_LOG" | head -1 | cut -d: -f1 || true)"
    after_git=0; [[ -n "$first_rm" ]] && after_git="$(tail -n +"$((first_rm + 1))" "$WGM_U19_LOG" | grep -c '^GIT' || true)"
    NAME="$(grep -o 'retained container [^ ]*' <<<"$LOUT" | head -1 | awk '{print $3}' || true)"
    if [[ "$LRC" -eq 2 && "$inv" -eq 1 && "$after_git" -eq 0 && -n "$NAME" ]] && has "podman rm -f -t 0 $NAME" "$LOUT"; then
      pass "U19: an unremovable timed-out container stops the run terminally (exit 2, one agent invocation, 0 host git calls after the first failed reap, exact handle + recovery $NAME)"
    else fail "U19 (rc=$LRC invocations=$inv git-after-reap=$after_git name='$NAME'): $(grep -v dropped <<<"$LOUT" | tail -4)"; fi
    my_containers_rm "$REAL_PODMAN"
    rm -rf "$TMPDIR"/wgm-loop.* 2>/dev/null || true
    # normal timeout path: absence confirmed → the agent is retried as before (1 try + 1 retry = 2 invocations)
    RP="$(newproj r25)"
    set +e; LOUT="$(cd "$RP" && "$LOOP" analyze --max-retries 1 --retry-base-delay 0 --agent-timeout-seconds 3 --max-consecutive-failures 1 -- bash -c "$SLOW" _ 2>&1)"; LRC=$?; set -e
    inv="$(wc -l < "$RP/.wgm/run/inv.txt" 2>/dev/null || echo 0)"
    if [[ "$inv" -eq 2 ]] && ! has "retained container" "$LOUT"; then pass "U19: the normal timeout path (container absence confirmed) still retries the agent ($inv invocations)"; else fail "U19 normal timeout retry (rc=$LRC invocations=$inv): $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
  # U20: containment loss is MACHINE-READABLE. With WGM_CONTAINMENT_LOST_FILE set, every container whose absence cannot be
  # confirmed is appended as exactly `retained container <name>` (once each) before the exit — for the loop (S56 route) and
  # for a standalone PREFLIGHT whose readiness launch exits 125 while rm fails and ps keeps reporting the container (S57b).
    RP="$(newproj r26)"; LOST="$TMP/lost26.txt"; rm -f "$LOST"; : > "$WGM_U19_LOG"
    set +e; LOUT="$(cd "$RP" && PATH="$TMP/engshim:$REAL_PATH" WGM_CONTAINMENT_LOST_FILE="$LOST" "$LOOP" analyze --max-retries 2 --agent-timeout-seconds 5 -- bash -c "$SLOW" _ 2>&1)"; LRC=$?; set -e
    NAME="$(grep -o 'retained container [^ ]*' <<<"$LOUT" | head -1 | awk '{print $3}' || true)"
    if [[ "$LRC" -eq 2 && -n "$NAME" && "$(cat "$LOST" 2>/dev/null)" == "retained container $NAME" && "$(stat -c %a "$LOST")" == 600 ]]; then
      pass "U20(1): the S56 route writes exactly 'retained container $NAME' (once, 0600) to WGM_CONTAINMENT_LOST_FILE"
    else fail "U20(1) (rc=$LRC name='$NAME'): file=[$(cat "$LOST" 2>/dev/null)]"; fi
    my_containers_rm "$REAL_PODMAN"
    # a symlinked loss file is never written through
    echo precious > "$TMP/precious26"; rm -f "$LOST"; ln -s "$TMP/precious26" "$LOST"
    set +e; LOUT="$(cd "$RP" && PATH="$TMP/engshim:$REAL_PATH" WGM_CONTAINMENT_LOST_FILE="$LOST" "$LOOP" analyze --max-retries 0 --agent-timeout-seconds 3 -- bash -c "$SLOW" _ 2>&1)"; LRC=$?; set -e
    if [[ "$LRC" -eq 2 && "$(cat "$TMP/precious26")" == precious ]] && has "retained container" "$LOUT"; then pass "U20: a symlinked WGM_CONTAINMENT_LOST_FILE is never written through (target untouched, handle still on stderr)"; else fail "U20 symlink loss file (rc=$LRC): $(cat "$TMP/precious26")"; fi
    my_containers_rm "$REAL_PODMAN"
    # preflight takes the same path: the readiness launch exits 125, rm fails, ps reports it
    cat > "$TMP/engshim/podman" <<SHIM
#!/usr/bin/env bash
case "\${1:-}" in
  run) exit 125 ;;
  rm) exit 1 ;;
  ps) if [[ "\$*" =~ name=\\^([^\\\$]+)\\\$ ]]; then printf '%s\\n' "\${BASH_REMATCH[1]}"; fi; exit 0 ;;
esac
exec "$REAL_PODMAN" "\$@"
SHIM
    chmod +x "$TMP/engshim/podman"
    RP="$(newproj r27)"; LOST="$TMP/lost27.txt"; rm -f "$LOST"
    set +e; LOUT="$(cd "$RP" && PATH="$TMP/engshim:$REAL_PATH" WGM_CONTAINMENT_LOST_FILE="$LOST" "$SB" preflight --agent-cmd bash 2>&1)"; LRC=$?; set -e
    NAME="$(grep -o 'retained container [^ ]*' <<<"$LOUT" | head -1 | awk '{print $3}' || true)"
    if [[ "$LRC" -eq 2 && -n "$NAME" && "$(cat "$LOST" 2>/dev/null)" == "retained container $NAME" ]] && has "podman rm -f -t 0 $NAME" "$LOUT"; then
      pass "U20(2): a preflight whose readiness launch exits 125 with rm failing and ps reporting it exits 2 at once, handle on stderr and in the loss file"
    else fail "U20(2) preflight (rc=$LRC name='$NAME'): file=[$(cat "$LOST" 2>/dev/null)] $(grep -v dropped <<<"$LOUT" | tail -3)"; fi
    rm -rf "$TMPDIR"/wgm-loop.* 2>/dev/null || true
  else echo "skip: no podman — skipping the U19 engine-shim cases"; fi

  # U27/B1: a FAILED iteration's disposal of the ownership manifest goes through the no-follow guard. The agent replaces
  # `.wgm/run` with an ABSOLUTE symlink to an outside dir holding a file named exactly like the manifest (the loop's pid
  # is stable across its re-exec, so the test pre-creates `.loop-touched-1-<pid>` there), then exits non-zero: the host
  # must refuse (exit 2) and the outside file must survive.
  RP="$(newproj r29)"; mkdir -p "$TMP/out27"; rm -f "$TMP"/out27/.loop-touched-*
  # shellcheck disable=SC2016  # expands inside the container
  A27='if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
mv .wgm/run .wgm/run.moved && ln -s "$WGM_TEST_OUT" .wgm/run; exit 1'
  ( cd "$RP" && exec env WGM_TEST_OUT="$TMP/out27" "$LOOP" build 1 --max-retries 0 --commit -- bash -c "$A27" _ > "$TMP/u27.out" 2>&1 ) &
  p27=$!
  echo precious > "$TMP/out27/.loop-touched-1-$p27"
  set +e; wait "$p27"; LRC=$?; set -e
  surv="$(cat "$TMP/out27/.loop-touched-1-$p27" 2>/dev/null || true)"
  if [[ "$LRC" -eq 2 && "$surv" == precious ]] && grep -q "agent-written symlink" "$TMP/u27.out"; then pass "U27/B1: a failed iteration whose agent redirected .wgm/run cannot make the host delete the outside file (exit 2, sentinel survives)"
  else fail "U27/B1 (rc=$LRC survivor='$surv'): $(grep -v dropped "$TMP/u27.out" | tail -3)"; fi

  # T7: readiness failure for a missing tool, then the published project-image recovery block
  RP="$(newproj r3)"
  pf "$RP" --agent-cmd wgm-missing-tool
  if [[ "$RC" -eq 2 ]] && has "build -t <tag> -f .devcontainer/Containerfile ." "$ERR" && has "--devcontainer-image <tag>" "$ERR" && has "wgm-missing-tool" "$ERR"; then
    pass "T7: a readiness failure names the missing agent CLI and prints the project-image recipe"
  else fail "T7 readiness message (rc=$RC): $ERR"; fi
  # The PUBLISHED recovery block (spec C9: ONE fenced bash block whose FIRST line is exactly
  # `ENGINE=podman; TAG=localhost/wgm-project:dev; CF=.devcontainer/Containerfile` and whose later commands use
  # "$ENGINE", "$TAG" and "$CF" only) is EXTRACTED from docs/operator/devcontainers.md; ONLY that first line is
  # replaced with fixture values (the engine under test, a disposable test tag, the fixture Containerfile); the block
  # is run; readiness then passes with THAT tag and THAT tag is removed in cleanup. (The doc is lane w's file: where
  # the block is absent this case is RED by design until lane w's change is stacked.)
  DOC="$ROOT/docs/operator/devcontainers.md"
  PROJ_TAG="localhost/wgm-sandbox-test-proj:latest"
  C9FIRST='ENGINE=podman; TAG=localhost/wgm-project:dev; CF=.devcontainer/Containerfile'
  BLOCK="$(awk -v first="$C9FIRST" '/^```/ { if (inb) { if (ok) { printf "%s", b; exit } inb = 0; b = ""; ok = 0; n = 0 } else { inb = 1; n = 0 } next }
                inb { n++; if (n == 1) { if ($0 == first) ok = 1; else ok = 0 } b = b $0 "\n" }' "$DOC" 2>/dev/null || true)"
  if [[ -z "$BLOCK" ]]; then
    fail "T7: no published image-recovery block (a fenced bash block whose first line is exactly '$C9FIRST') in docs/operator/devcontainers.md — lane w's file; RED until it is stacked"
  else
    EXEC_BLOCK="ENGINE=$ENGINE; TAG=$PROJ_TAG; CF=.devcontainer/Containerfile"$'\n'"$(tail -n +2 <<<"$BLOCK")"
    mkdir -p "$RP/.devcontainer"
    printf 'FROM %s\nUSER root\nRUN printf "#!/bin/sh\\necho tool\\n" > /usr/local/bin/wgm-missing-tool && chmod +x /usr/local/bin/wgm-missing-tool\nUSER wgm\n' "$TEST_TAG" > "$RP/.devcontainer/Containerfile"
    if ( cd "$RP" && bash -c "$EXEC_BLOCK" >/dev/null 2>&1 ) && "$ENGINE" image inspect "$PROJ_TAG" >/dev/null 2>&1; then
      pf "$RP" --agent-cmd wgm-missing-tool --devcontainer-image "$PROJ_TAG"
      if [[ "$RC" -eq 0 ]] && has "image=$PROJ_TAG" "$OUTO"; then pass "T7 recovery: executing the PUBLISHED recovery block (only its first line replaced by fixture values) builds $PROJ_TAG and the readiness probe passes with it"; else fail "T7 recovery (rc=$RC): $ERR"; fi
    else fail "T7: the published recovery block did not build the image: $EXEC_BLOCK"; fi
  fi
  # ---- U41: WGM_HIVE_DENYLIST (survives the env allowlist) is read by harvest-hive.sh ON THE HOST: inside the project it goes
  # through the no-follow guard before the hook runs (real engine; strace -f -y successful-open observer, positive control)
  HP="$(newproj r41)"; mkdir -p "$HP/.wgm"; printf -- '- lesson\n' > "$HP/.wgm/memories.md"; printf 'secret-term\n' > "$HP/hive-deny.txt"
  git -C "$HP" add -A; git -C "$HP" commit -qm hive
  echo canary41-content > "$TMP/canary41.txt"
  # shellcheck disable=SC2016  # runs inside the container
  A41='if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- step\n" >> IMPLEMENTATION_PLAN.md; mkdir -p .wgm; : > .wgm/STOP; if [[ -n "${WGM_PLANT:-}" ]]; then rm -f hive-deny.txt; ln -s "$WGM_PLANT" hive-deny.txt; fi; if [[ -n "${WGM_OWNERSHIP_MANIFEST:-}" ]]; then printf "IMPLEMENTATION_PLAN.md\nhive-deny.txt\n.wgm/STOP\n" > "$WGM_OWNERSHIP_MANIFEST"; fi'
  # a regular denylist inside the project still works
  rm -f "$HP/.wgm/STOP" "$HP/.wgm/.last-harvest-hash"
  WGM_HIVE_DENYLIST="$HP/hive-deny.txt" lp "$HP" build 1 --max-retries 0 -- bash -c "$A41" _
  rc41a=$LRC; out41a="$LOUT"
  git -C "$HP" checkout -q -- . 2>/dev/null || true; git -C "$HP" clean -fdq -e .wgm/memories.md 2>/dev/null || true; rm -f "$HP/.wgm/STOP" "$HP/.wgm/.last-harvest-hash"
  if [[ "$rc41a" -eq 0 ]] && has "invoking consent-gated harvest-hive hook" "$out41a"; then pass "U41: a regular WGM_HIVE_DENYLIST inside the project still works (the harvest hook runs)"; else fail "U41 regular denylist (rc=$rc41a): $(grep -v dropped <<<"$out41a" | tail -3)"; fi
  if [[ "$have_strace" -eq 1 ]]; then
    strace -f --seccomp-bpf -y -e trace=openat -o "$TMP/u41.ctl" cat "$TMP/canary41.txt" >/dev/null 2>&1 || true
    ctl41="$(resolved_opens "$TMP/u41.ctl" canary41.txt)"
    set +e; ( cd "$HP" && WGM_PLANT="$TMP/canary41.txt" WGM_HIVE_DENYLIST="$HP/hive-deny.txt" strace -f --seccomp-bpf -y -e trace=openat -o "$TMP/u41.st" "$LOOP" build 1 --max-retries 0 -- bash -c "$A41" _ > "$TMP/u41.out" 2>&1 ); rc41=$?; set -e
    n41="$(resolved_opens "$TMP/u41.st" canary41.txt)"
    if [[ "$ctl41" -ge 1 && "$rc41" -eq 2 && "$n41" -eq 0 ]] && has "agent-written symlink" "$(<"$TMP/u41.out")" && has "hive-deny.txt" "$(<"$TMP/u41.out")" && ! has "invoking consent-gated harvest-hive hook" "$(<"$TMP/u41.out")"; then
      pass "U41: a WGM_HIVE_DENYLIST the agent replaced with a symlink to an outside canary (memories regular, STOP created) → exit 2 naming it, zero host opens of the canary, the hook never ran (strace -f -y, control seen)"
    else fail "U41 planted denylist (rc=$rc41 ctl=$ctl41 opens=$n41): $(grep -v dropped "$TMP/u41.out" | tail -4)"; fi
  else echo "skip: no usable strace — skipping the U41 host-open observation of WGM_HIVE_DENYLIST"; fi

  # ---- U42/B2: harvest-hive.sh runs on the HOST and resolves `gh` through PATH: gh is in the bound-tool inventory, so a stub
  # first on PATH inside a writable root never runs, and a legitimate gh outside every writable root is the bound copy that runs.
  # (PATH is built WITHOUT any real gh so this test can never reach a real, authenticated gh.)
  NOGH_PATH=""; IFS=: read -r -a pe42 <<<"$REAL_PATH"
  for d42 in "${pe42[@]}"; do [[ -x "$d42/gh" ]] || NOGH_PATH+="${NOGH_PATH:+:}$d42"; done
  HP2="$(newproj r42)"; mkdir -p "$HP2/.wgm" "$HP2/.github" "$HP2/bin" "$TMP/ghbin"
  printf -- '- durable lesson about retries\n' > "$HP2/.wgm/memories.md"; printf 'consent: true\nauto_report: true\n' > "$HP2/.github/wgm-hive.yml"
  # shellcheck disable=SC2016  # the stub body runs later
  GHSTUB='#!/usr/bin/env bash
echo "gh $0 $*" >> "$WGM_TEST_GHLOG"
case "$1 $2" in "issue create") echo https://example.invalid/issues/1 ;; esac
exit 0'
  printf '%s\n' "$GHSTUB" > "$HP2/bin/gh"; printf '%s\n' "$GHSTUB" > "$TMP/ghbin/gh"; chmod +x "$HP2/bin/gh" "$TMP/ghbin/gh"
  git -C "$HP2" add -A; git -C "$HP2" commit -qm hive42
  # shellcheck disable=SC2016  # runs inside the container
  A42='if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- step\n" >> IMPLEMENTATION_PLAN.md; mkdir -p .wgm; : > .wgm/STOP'
  : > "$TMP/gh42.log"
  PATH="$HP2/bin:$NOGH_PATH" WGM_TEST_GHLOG="$TMP/gh42.log" lp "$HP2" build 1 --max-retries 0 -- bash -c "$A42" _
  rcg1=$LRC; outg1="$LOUT"; ran1="$(wc -l < "$TMP/gh42.log")"
  git -C "$HP2" checkout -q -- . 2>/dev/null || true; rm -f "$HP2/.wgm/STOP" "$HP2/.wgm/.last-harvest-hash"
  PATH="$TMP/ghbin:$NOGH_PATH" WGM_TEST_GHLOG="$TMP/gh42.log" lp "$HP2" build 1 --max-retries 0 -- bash -c "$A42" _
  rcg2=$LRC
  if [[ "$ran1" -eq 0 && "$rcg1" -eq 0 ]] && has "invoking consent-gated harvest-hive hook" "$outg1" \
     && [[ "$rcg2" -eq 0 ]] && grep -q "auth status" "$TMP/gh42.log" && grep -qE "^gh .*/wgm-bin\.[^ ]+/gh " "$TMP/gh42.log"; then
    pass "U42/B2: in the sandboxed harvest path a stub gh inside the project (first on PATH) never runs; a gh outside every writable root runs as the BOUND copy (wgm-bin/gh)"
  else fail "U42/B2 (rc=$rcg1/$rcg2 stub-in-project-ran=$ran1): log=[$(head -3 "$TMP/gh42.log")] $(grep -v dropped <<<"$outg1" | tail -2)"; fi

  # ---- U46: SHARED ownership of container handles. SIGTERM to the loop during a slow readiness `--version` in the preflight CHILD,
  # with an engine shim whose `rm` hangs and whose `ps` fails: bounded exit 143, and EVERY container name that was launched is
  # either confirmed gone or printed as `retained container <name>` (the child's registry is shared with the supervisor)
  if [[ -n "${REAL_PODMAN:-}" ]]; then
    mkdir -p "$TMP/engshim46"
    cat > "$TMP/engshim46/podman" <<SHIM
#!/usr/bin/env bash
case "\${1:-}" in
  run) a=("\$@"); for ((i = 0; i < \${#a[@]}; i++)); do [[ "\${a[i]}" == --name ]] && echo "\${a[i+1]}" >> "\$WGM_U46_LOG"; done ;;
  rm) sleep 300; exit 1 ;;
  ps) exit 1 ;;
esac
exec "$REAL_PODMAN" "\$@"
SHIM
    chmod +x "$TMP/engshim46/podman"
    export WGM_U46_LOG="$TMP/u46.log"; : > "$WGM_U46_LOG"
  for v46 in grace killed; do
    RP="$(newproj "r46$v46")"; rm -f "$TMP/u46mark"; : > "$WGM_U46_LOG"; g46=""; [[ "$v46" == killed ]] && g46=1
    # shellcheck disable=SC2016  # stub body runs later
    mkstub "$TMP/stubs/slowv46" slowv 'if [ "${1:-}" = --version ]; then touch "$WGM_TEST_MARK"; sleep 300; fi; exit 0'
    ( cd "$RP" && exec env WGM_CHILD_GRACE="$g46" PATH="$TMP/engshim46:$TMP/stubs/slowv46/bin:$REAL_PATH" WGM_TEST_MARK="$TMP/u46mark" "$LOOP" analyze --max-retries 0 -- slowv > "$TMP/u46.out" 2>&1 ) &
    p46=$!
    for _i in $(seq 1 300); do [[ -e "$TMP/u46mark" ]] && break; sleep 0.2; done
    t46=$SECONDS; kill -TERM "$p46" 2>/dev/null || true
    set +e; wait "$p46"; rc46=$?; set -e
    el46=$((SECONDS - t46))
    unacc46=""; n46=0
    while IFS= read -r nm46; do
      [[ -n "$nm46" ]] || continue; n46=$((n46 + 1))
      grep -qx "retained container $nm46" "$TMP/u46.out" || unacc46+="$nm46 "
    done < <(sort -u "$WGM_U46_LOG")
    if [[ "$rc46" -eq 143 && "$el46" -lt 100 && "$n46" -ge 1 && -z "$unacc46" ]]; then
      pass "U46($v46): SIGTERM during a slow preflight readiness (rm hangs, ps fails) → bounded exit 143 (${el46}s); all $n46 launched container(s) printed as 'retained container <name>' — no handle lost"
    else fail "U46($v46) (rc=$rc46, ${el46}s, launched=$n46, unaccounted=[$unacc46]): $(grep -v dropped "$TMP/u46.out" | tail -4)"; fi
    my_containers_rm "$REAL_PODMAN"
  done
    rm -f "$TMP/engshim46/podman"
  fi

  "$ENGINE" rmi -f "$PROJ_TAG" >/dev/null 2>&1 || true
  if [[ "${UNREL_MADE:-0}" -eq 1 ]]; then
    if [[ -n "$("$ENGINE" ps -a --filter "name=^${UNREL}\$" --format '{{.Names}}' 2>/dev/null)" ]]; then pass "U39: an unrelated wgm-unrelated-* container survived every count and cleanup of this harness (and no case was failed by it)"
    else fail "U39: the unrelated container $UNREL was removed by a harness cleanup"; fi
    "$ENGINE" rm -f -t 0 "$UNREL" >/dev/null 2>&1 || true
  fi
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "sandbox harness: GREEN"
  exit 0
else
  echo "sandbox harness: RED" >&2
  exit 1
fi
