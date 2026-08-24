#!/usr/bin/env bash
#
# wgm/test-wsl-windows-boundary.sh — deterministic Windows-process -> WSL reachability boundary check.
#
# A service published inside WSL can be perfectly healthy from the guest and still be unreachable
# from the Windows side: publishing on WSL **loopback** hides it from the Windows interop path,
# while publishing on **all interfaces** exposes it at the distro's WSL IPv4 address. A Linux-side
# `curl` never crosses that boundary, so it cannot observe the difference — it is a same-side probe
# ([learn] issue agent-frontier/wgm#101).
#
# This orchestrator runs the check end to end:
#   1. Refuses to run (exit 3, loudly) unless it is really inside WSL with a real Windows interop
#      path to a real Windows PowerShell. A synthetic wsl.exe / powershell.exe on the Linux
#      filesystem is rejected — it is never treated as field evidence.
#   2. Starts a disposable stdlib-only HTTP + WebSocket fixture (index page, generated client asset,
#      /health, /ws echo) twice: once bound to WSL loopback, once bound to 0.0.0.0 — which publishes
#      it on ALL LOCAL INTERFACES (LAN-reachable) for the few seconds that leg runs, by design,
#      since that bind is the configuration under test. Static test content only, ephemeral port,
#      torn down immediately afterwards.
#   3. Sanity-checks each bind from the Linux side, explicitly labeled `same-side` — never counted
#      as Windows-origin evidence.
#   4. Invokes scripts/test-wsl-reachability.ps1 as a Windows process against BOTH the Windows
#      localhost route and the WSL IPv4 route for BOTH binds, and refuses any probe output that
#      does not report a Windows origin platform. Probe output is CRLF-normalized before parsing,
#      because a genuine Windows process reports "origin-platform=Win32NT\r". Each invocation runs
#      under a hard `timeout` when GNU coreutils is present — (3 x --timeout) + a named
#      PWSH_STARTUP_ALLOWANCE for Windows PowerShell/interop/AV cold start — and otherwise under the
#      probe's own -TimeoutSec, so no leg can hang the run indefinitely.
#   5. Prints a per-route matrix with the observed result, then a verdict.
#
# Which results are REQUIRED (a failure here is RED) vs OBSERVATIONAL (either answer is data):
#   * REQUIRED — the all-interfaces bind over the wsl-ipv4 route: page, generated client asset AND
#     the WebSocket leg. That is the documented working configuration; if it does not serve a
#     Windows-origin consumer, the run is RED. A WebSocket `unsupported` counts only when the
#     Windows host lacks the ClientWebSocket type and nothing else failed.
#   * OBSERVATIONAL — the loopback bind (its failure over wsl-ipv4 IS the boundary from #101) and
#     every windows-localhost route (localhost forwarding depends on the distro's networking mode).
#     A missing/unknown observation is never reported as a confirmed boundary.
#
# Usage:
#   scripts/test-wsl-windows-boundary.sh [--timeout SEC] [--keep] [-h|--help]
#
# Flags:
#   --timeout SEC   per-NETWORK-OPERATION budget in seconds, handed to the probe (default 5)
#   --keep          keep the temporary fixture directory (prints its path) for debugging
#   -h | --help     show this help
#
# Timeouts: each Windows probe is killed after (3 x --timeout) + PWSH_STARTUP_ALLOWANCE seconds.
# The allowance (default 20s, override with WGM_WSL_PWSH_STARTUP_ALLOWANCE=1..600) covers Windows
# PowerShell / interop / antivirus COLD START, not the network — it is not a detection seam, so it
# never marks a run simulated. Without GNU timeout there is no outer kill and the probe's own
# per-operation -TimeoutSec is the only (cooperative) bound; the run says so explicitly.
#
# Environment seams (also used by scripts/test-wsl-boundary-harness.sh to drive failure paths):
#   WGM_WSL_PROC_VERSION_FILE   kernel version file to inspect         (default /proc/version)
#   WGM_WSL_BINFMT_DIR          binfmt_misc dir holding WSLInterop*    (default /proc/sys/fs/binfmt_misc)
#   WGM_WSL_WINDOWS_MOUNT_ROOT  DrvFs mount root for Windows drives    (default /mnt)
#   WGM_WSL_PWSH                explicit Windows PowerShell executable (default: auto-detect)
#   WGM_WSL_IPV4                explicit WSL IPv4 address             (default: auto-detect)
#
# SEAMS AND EVIDENCE: the WGM_WSL_* variables above exist so the harness can drive failure paths on
# any host. Setting ANY of them makes the run a SIMULATION: the script prints a stable
# `seams-overridden=<comma-list>` line, and can then never print a bare `wsl-boundary: GREEN` nor
# exit 0. Only a run with `seams-overridden=none` — a real WSL distro, real interop, a real Windows
# PowerShell found on its own — can produce GREEN and count as field evidence for #101.
#
# Exit 0 = green (no seams overridden, a Windows-origin probe ran, every REQUIRED check passed).
# Exit 1 = red (a required probe failed, timed out, or did not originate on Windows).
# Exit 2 = usage error.
# Exit 3 = unsupported host (not WSL, no Windows interop, or no usable Windows PowerShell).
# Exit 4 = simulated / unverified: detection seams were overridden, so the checks that passed are
#          harness coverage only and this run is NOT field evidence.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_PS1="$ROOT/scripts/test-wsl-reachability.ps1"

TIMEOUT=5
KEEP=0

# Two different budgets, deliberately separate:
#   * --timeout      the NETWORK budget the caller controls, applied per operation by the probe
#                    (page, client asset, WebSocket) — see -TimeoutSec in test-wsl-reachability.ps1.
#   * this allowance the wall-clock grace for everything that is NOT network: Windows PowerShell's
#                    own cold start over interop (\\wsl.localhost path resolution, .NET/CLR load,
#                    profile-less engine init) plus on-access antivirus scanning of powershell.exe
#                    and the script. On a warm machine that is well under a second; on a cold one
#                    with real-time AV it is routinely several seconds, so 20s is a deliberately
#                    generous default that still bounds a wedged interop path.
# The outer kill is therefore (3 network operations x --timeout) + PWSH_STARTUP_ALLOWANCE, which
# always exceeds the probe's own cooperative bound and never fires before the probe can report.
# WGM_WSL_PWSH_STARTUP_ALLOWANCE only tunes this grace; it cannot fabricate a result, so it is not a
# detection seam and does not mark a run simulated.
PWSH_STARTUP_ALLOWANCE="${WGM_WSL_PWSH_STARTUP_ALLOWANCE:-20}"
[[ "$PWSH_STARTUP_ALLOWANCE" =~ ^[0-9]+$ ]] && [[ "$PWSH_STARTUP_ALLOWANCE" -ge 1 ]] && [[ "$PWSH_STARTUP_ALLOWANCE" -le 600 ]] \
  || { echo "WGM_WSL_PWSH_STARTUP_ALLOWANCE must be an integer 1..600 (seconds)" >&2; exit 2; }

PROC_VERSION_FILE="${WGM_WSL_PROC_VERSION_FILE:-/proc/version}"
BINFMT_DIR="${WGM_WSL_BINFMT_DIR:-/proc/sys/fs/binfmt_misc}"
MOUNT_ROOT="${WGM_WSL_WINDOWS_MOUNT_ROOT:-/mnt}"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

die_unsupported() {
  printf 'wsl-boundary: UNSUPPORTED HOST — %s\n' "$*" >&2
  printf 'wsl-boundary: this check requires a real WSL distro with Windows interop; it cannot be simulated.\n' >&2
  exit 3
}

note() { printf 'wsl-boundary: %s\n' "$*"; }
fail() { printf 'wsl-boundary: FAIL — %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --timeout)
      [[ $# -ge 2 ]] || { echo "--timeout requires a value" >&2; exit 2; }
      [[ "$2" =~ ^[0-9]+$ ]] && [[ "$2" -ge 1 ]] && [[ "$2" -le 120 ]] \
        || { echo "--timeout must be an integer 1..120" >&2; exit 2; }
      TIMEOUT="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *) echo "Unexpected argument: $1" >&2; exit 2 ;;
  esac
done

# ---- 0. seam disclosure --------------------------------------------------------------------------
# Announced up front and unconditionally, so every transcript states whether this run could possibly
# be field evidence. A simulated run is still useful (it exercises this orchestrator); it is simply
# never allowed to look like a verified boundary.
SEAMS=()
for seam in WGM_WSL_PROC_VERSION_FILE WGM_WSL_BINFMT_DIR WGM_WSL_WINDOWS_MOUNT_ROOT WGM_WSL_PWSH WGM_WSL_IPV4; do
  [[ -n "${!seam:-}" ]] && SEAMS+=("$seam")
done
SIMULATED=0
if [[ "${#SEAMS[@]}" -gt 0 ]]; then
  SIMULATED=1
  printf 'wsl-boundary: seams-overridden=%s\n' "$(IFS=,; printf '%s' "${SEAMS[*]}")"
  note "SIMULATION MODE — detection seams are overridden, so this run is harness coverage and can never be field evidence for [learn] agent-frontier/wgm#101."
else
  printf 'wsl-boundary: seams-overridden=none\n'
fi

[[ -f "$PROBE_PS1" ]] || die_unsupported "missing Windows-origin probe: $PROBE_PS1"

# ---- 1. environment preflight ------------------------------------------------------------------
# Each of these is a hard stop. Half a boundary check is worse than none: it would report a green
# that only ever exercised the Linux side.

grep -qi 'microsoft' "$PROC_VERSION_FILE" 2>/dev/null \
  || die_unsupported "not running inside WSL (no 'microsoft' marker in $PROC_VERSION_FILE)"

interop_ok=0
for f in "$BINFMT_DIR"/WSLInterop "$BINFMT_DIR"/WSLInterop-late; do
  [[ -e "$f" ]] && interop_ok=1
done
[[ "$interop_ok" -eq 1 ]] \
  || die_unsupported "Windows interop is not registered (no WSLInterop entry under $BINFMT_DIR)"

PWSH="${WGM_WSL_PWSH:-}"
if [[ -z "$PWSH" ]]; then
  for candidate in \
    "$(command -v powershell.exe 2>/dev/null || true)" \
    "$(command -v pwsh.exe 2>/dev/null || true)" \
    "$MOUNT_ROOT/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  do
    [[ -n "$candidate" && -x "$candidate" ]] && { PWSH="$candidate"; break; }
  done
fi
[[ -n "$PWSH" && -x "$PWSH" ]] \
  || die_unsupported "no Windows PowerShell found (set WGM_WSL_PWSH to powershell.exe or pwsh.exe)"

# Anti-fake guard: a Windows PowerShell reached through interop lives on a Windows drive mounted at
# the DrvFs root. A shim sitting on the Linux filesystem may be a useful test double, but it is not
# a Windows process, so its output must never be recorded as boundary evidence.
PWSH_REAL="$(readlink -f "$PWSH" 2>/dev/null || printf '%s' "$PWSH")"
case "$PWSH_REAL/" in
  "$MOUNT_ROOT"/*) : ;;
  *) die_unsupported "refusing to use '$PWSH_REAL' as a Windows process: it does not live under the Windows mount root ($MOUNT_ROOT). A synthetic powershell.exe/wsl.exe on the Linux filesystem is not field evidence." ;;
esac

command -v python3 >/dev/null 2>&1 \
  || die_unsupported "python3 is required to run the disposable fixture service"
command -v wslpath >/dev/null 2>&1 \
  || die_unsupported "wslpath is required to hand the probe script to the Windows side"
command -v curl >/dev/null 2>&1 \
  || die_unsupported "curl is required for the same-side readiness sanity check"

WSL_IPV4="${WGM_WSL_IPV4:-}"
if [[ -z "$WSL_IPV4" ]]; then
  WSL_IPV4="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
fi
[[ -n "$WSL_IPV4" ]] \
  || die_unsupported "could not determine this distro's WSL IPv4 address (set WGM_WSL_IPV4)"

PROBE_WIN_PATH="$(wslpath -w "$PROBE_PS1" 2>/dev/null || true)"
[[ -n "$PROBE_WIN_PATH" ]] \
  || die_unsupported "wslpath could not translate $PROBE_PS1 to a Windows path"

note "environment: WSL detected, interop registered, windows-powershell=$PWSH_REAL, wsl-ipv4=$WSL_IPV4"

# ---- 2. disposable fixture ---------------------------------------------------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wgm-wsl-boundary.XXXXXX")"
SERVER_PID=""
trap '
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
  if [[ "$KEEP" -eq 1 ]]; then
    printf "wsl-boundary: kept fixture dir %s\n" "$TMP"
  else
    rm -rf "$TMP"
  fi
' EXIT

FIXTURE="$TMP/fixture.py"
cat >"$FIXTURE" <<'PYFIXTURE'
"""Disposable stdlib-only HTTP + WebSocket fixture for the WSL/Windows boundary check.

Serves an index page, a generated client asset, a health endpoint, and a /ws echo endpoint.
Binds exactly where it is told so the caller can contrast loopback with all-interfaces.
"""
import base64
import hashlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "WGM-WSL-BOUNDARY-FIXTURE"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
INDEX = "<!doctype html><title>%s</title><body>%s</body>" % (TOKEN, TOKEN)
CLIENT = "// %s generated client asset\nwindow.WGM_FIXTURE = '%s';\n" % (TOKEN, TOKEN)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep the orchestrator's output deterministic
        pass

    def _send(self, body, ctype):
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/ws":
            self._websocket()
        elif path in ("/", "/index.html"):
            self._send(INDEX, "text/html; charset=utf-8")
        elif path == "/assets/client.js":
            self._send(CLIENT, "application/javascript")
        elif path == "/health":
            self._send("ok", "text/plain; charset=utf-8")
        else:
            self.send_error(404, "not found")

    def _websocket(self):
        key = self.headers.get("Sec-WebSocket-Key")
        if not key:
            self.send_error(400, "missing Sec-WebSocket-Key")
            return
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.close_connection = True
        self.wfile.write(
            (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                "Sec-WebSocket-Accept: %s\r\n\r\n" % accept
            ).encode()
        )
        self.wfile.flush()
        try:
            payload = self._read_frame()
            if payload is not None:
                self._write_frame(payload)
        except OSError:
            pass

    def _read_frame(self):
        header = self.rfile.read(2)
        if len(header) < 2:
            return None
        opcode = header[0] & 0x0F
        masked = header[1] & 0x80
        length = header[1] & 0x7F
        if length == 126:
            length = int.from_bytes(self.rfile.read(2), "big")
        elif length == 127:
            length = int.from_bytes(self.rfile.read(8), "big")
        if length > 65536 or opcode == 0x8:
            return None
        mask = self.rfile.read(4) if masked else b"\x00\x00\x00\x00"
        data = self.rfile.read(length)
        return bytes(b ^ mask[i % 4] for i, b in enumerate(data))

    def _write_frame(self, payload):
        frame = bytearray([0x81])
        n = len(payload)
        if n < 126:
            frame.append(n)
        elif n < 65536:
            frame.append(126)
            frame += n.to_bytes(2, "big")
        else:
            frame.append(127)
            frame += n.to_bytes(8, "big")
        frame += payload
        self.wfile.write(bytes(frame))
        self.wfile.flush()


def main():
    if len(sys.argv) != 3:
        print("usage: fixture.py BIND_ADDRESS PORT", file=sys.stderr)
        return 2
    server = ThreadingHTTPServer((sys.argv[1], int(sys.argv[2])), Handler)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYFIXTURE

free_port() {
  python3 - <<'PYPORT'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PYPORT
}

RESULTS=()
FAILED=0
WINDOWS_ORIGIN_SEEN=0

start_fixture() {  # $1 = bind address, $2 = port
  python3 "$FIXTURE" "$1" "$2" >"$TMP/server.log" 2>&1 &
  SERVER_PID=$!
  local waited=0
  while (( waited < TIMEOUT * 10 )); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$2/health" >/dev/null 2>&1; then
      return 0
    fi
    kill -0 "$SERVER_PID" 2>/dev/null || return 1
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

stop_fixture() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
}

# Windows PowerShell writes CRLF and can block indefinitely if the interop path wedges. Both are
# handled here, once, so every parse below sees clean LF text and no probe can hang the run.
PWSH_TIMEOUT=()
PWSH_HARD_TIMEOUT="$((TIMEOUT * 3 + PWSH_STARTUP_ALLOWANCE))"
if command -v timeout >/dev/null 2>&1 && timeout --version 2>/dev/null | head -n1 | grep -qi 'coreutils'; then
  PWSH_TIMEOUT=(timeout --preserve-status -k 5 "$PWSH_HARD_TIMEOUT")
  note "probe hard timeout: ${PWSH_HARD_TIMEOUT}s = 3 network operations x --timeout=${TIMEOUT}s + pwsh-startup-allowance=${PWSH_STARTUP_ALLOWANCE}s (Windows PowerShell/interop/AV cold start)"
else
  note "note: GNU timeout not available — falling back to the probe's own cooperative bound (-TimeoutSec $TIMEOUT per network operation, applied to the page, the asset, and the WebSocket). Install coreutils for a hard wall-clock kill."
fi

run_pwsh() {  # invoke the Windows probe under a hard timeout when one is available
  ${PWSH_TIMEOUT[@]+"${PWSH_TIMEOUT[@]}"} "$PWSH" "$@"
}

parse_outcome() {  # $1 = probe output, $2 = endpoint — echoes that endpoint's outcome, or "none"
  local v
  v="$(printf '%s\n' "$1" | sed -n "s|^result endpoint=$2 .*outcome=\([a-z-]*\).*|\1|p" | head -n1)"
  printf '%s' "${v:-none}"
}

parse_detail() {  # $1 = probe output, $2 = endpoint — echoes that endpoint's detail, or ""
  printf '%s\n' "$1" | sed -n "s|^result endpoint=$2 .*detail=||p" | head -n1
}

probe_windows() {  # $1=leg $2=via-label $3=host $4=port $5=websocket(0|1) $6=required(0|1)
  local leg="$1" via="$2" host="$3" port="$4" want_ws="$5" required="$6"
  local url="http://$host:$port/"
  local asset_url="http://$host:$port/assets/client.js"
  local ws_url="ws://$host:$port/ws"
  local out rc origin http_outcome asset_outcome ws_outcome ws_detail
  local -a args=(-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PROBE_WIN_PATH"
                 -Url "$url" -AssetPath "assets/client.js" -TimeoutSec "$TIMEOUT")
  if [[ "$want_ws" -eq 1 ]]; then
    args+=(-WebSocketUrl "$ws_url")
    # On a REQUIRED leg the WebSocket is part of the claim, so the probe itself must treat it as
    # mandatory: -RequireWebSocket makes a failed upgrade exit 1, and reserves exit 3 for the one
    # tolerable case (the Windows host has no ClientWebSocket type at all).
    [[ "$required" -eq 1 ]] && args+=(-RequireWebSocket)
  fi

  out="$(run_pwsh "${args[@]}" 2>&1)"; rc=$?
  # Strip CR once, up front: a genuine Windows probe reports "origin-platform=Win32NT\r", and a
  # comparison against the un-normalized string would reject real field evidence as non-Windows.
  out="${out//$'\r'/}"

  origin="$(printf '%s\n' "$out" | sed -n 's/^origin-platform=//p' | head -n1)"
  http_outcome="$(parse_outcome "$out" "$url")"
  asset_outcome="$(parse_outcome "$out" "$asset_url")"
  if [[ "$want_ws" -eq 1 ]]; then
    ws_outcome="$(parse_outcome "$out" "$ws_url")"
    ws_detail="$(parse_detail "$out" "$ws_url")"
  else
    ws_outcome="not-requested"
    ws_detail=""
  fi

  # A killed probe produces no output, which would otherwise look exactly like "not a Windows
  # process". Say what actually happened: 124 is GNU timeout's own status, 137/143 are the kill
  # signals it forwards with --preserve-status.
  if [[ "$rc" -eq 124 || "$rc" -eq 137 || "$rc" -eq 143 ]]; then
    fail "probe for $leg ($via) $url TIMED OUT (rc=$rc) — the Windows interop path did not answer within the harness bound. This is a timeout, NOT evidence that the process was non-Windows."
    FAILED=1
    RESULTS+=("$leg|via=$via|$url|origin=timeout|http=timeout|asset=timeout|ws=timeout|rc=$rc|required=$required")
    return 1
  fi

  if [[ "$origin" != "Win32NT" ]]; then
    fail "probe for $leg ($via) $url did not originate on Windows (origin-platform='${origin:-missing}', rc=$rc). Refusing to record a same-side result as Windows-origin evidence."
    printf '%s\n' "$out" | sed 's/^/      /' >&2
    FAILED=1
    RESULTS+=("$leg|via=$via|$url|origin=NOT-WINDOWS|http=$http_outcome|asset=$asset_outcome|ws=$ws_outcome|rc=$rc|required=$required")
    return 1
  fi
  WINDOWS_ORIGIN_SEEN=1

  local -a problems=()

  # A probe-error is a harness/input fault, never an observation: fatal on every leg, required or
  # not, because it means the probe never actually measured anything.
  if grep -q '^probe-error=' <<<"$out"; then
    problems+=("probe reported an input error: $(printf '%s\n' "$out" | sed -n 's/^probe-error=//p' | head -n1)")
  fi

  # A WebSocket leg is allowed to come back `unsupported` ONLY when the client type is missing on
  # the Windows host and nothing else failed. Any other unsupported/fail is a real failure.
  # `unsupported` is nonfatal in exactly one situation: the Windows host has no ClientWebSocket
  # type AND every other check on this probe passed (probe exit 0, or 3 under -RequireWebSocket,
  # which is the probe's dedicated "required WebSocket unsupported, everything else fine" status).
  local ws_allowed=0 rc_allowed=0
  [[ "$rc" -eq 0 ]] && rc_allowed=1
  if [[ "$want_ws" -eq 1 ]]; then
    case "$ws_outcome" in
      ok) ws_allowed=1 ;;
      unsupported)
        if [[ "$ws_detail" == *ClientWebSocket-type-unavailable* ]] \
           && [[ "$http_outcome" == "ok" && "$asset_outcome" == "ok" ]] \
           && [[ "$rc" -eq 0 || "$rc" -eq 3 ]]; then
          ws_allowed=1
          rc_allowed=1
          note "$(printf '%-19s' "$leg") ($via) websocket check UNSUPPORTED on this Windows host (no ClientWebSocket type) — reported, not counted as a pass"
        fi
        ;;
    esac
  else
    ws_allowed=1
  fi

  if [[ "$required" -eq 1 ]]; then
    [[ "$http_outcome"  == "ok" ]] || problems+=("required page fetch failed: $url -> $http_outcome")
    [[ "$asset_outcome" == "ok" ]] || problems+=("required client-asset fetch failed: $asset_url -> $asset_outcome")
    [[ "$ws_allowed" -eq 1 ]]      || problems+=("required WebSocket leg failed: $ws_url -> $ws_outcome")
    [[ "$rc_allowed" -eq 1 ]]      || problems+=("required probe exited $rc")
  fi

  RESULTS+=("$leg|via=$via|$url|origin=windows|http=$http_outcome|asset=$asset_outcome|ws=$ws_outcome|rc=$rc|required=$required")
  note "$(printf '%-19s' "$leg") via=$(printf '%-16s' "$via") endpoint=$url  windows-origin=yes  http=$http_outcome  asset=$asset_outcome  websocket=$ws_outcome  probe-rc=$rc  required=$required"

  if [[ "${#problems[@]}" -gt 0 ]]; then
    local p
    for p in "${problems[@]}"; do
      fail "$leg ($via): $p"
    done
    FAILED=1
    return 1
  fi
  return 0
}

field_for() {  # $1 = row prefix, $2 = field name — echoes the recorded value, or "unknown"
  local row val
  for row in ${RESULTS[@]+"${RESULTS[@]}"}; do
    if [[ "$row" == "$1"* ]]; then
      val="$(printf '%s' "$row" | sed -n "s/.*|$2=\([a-z0-9-]*\).*/\1/p")"
      printf '%s' "${val:-unknown}"
      return 0
    fi
  done
  # No row at all means the probe never produced a recorded observation. That is an UNKNOWN, not a
  # negative result — reporting it as a confirmed boundary would invent evidence.
  printf 'unknown'
}

run_leg() {  # $1 = leg label, $2 = bind address, $3 = wsl-ipv4 route required (0|1)
  local leg="$1" bind="$2" required="$3" port
  port="$(free_port)"
  if [[ -z "$port" ]]; then
    fail "could not allocate a free port for $leg"
    FAILED=1
    return 1
  fi

  if ! start_fixture "$bind" "$port"; then
    fail "fixture did not become ready for $leg (bind=$bind port=$port)"
    sed 's/^/      /' "$TMP/server.log" >&2 || true
    stop_fixture
    FAILED=1
    return 1
  fi

  # Same-side sanity only: this proves the fixture is up inside WSL. It is NOT boundary evidence,
  # because it never leaves the guest — the exact blind spot [learn] #101 describes.
  if curl -fsS --max-time "$TIMEOUT" "http://127.0.0.1:$port/" >/dev/null 2>&1; then
    note "$(printf '%-19s' "$leg") same-side(linux) sanity: http://127.0.0.1:$port/ reachable from WSL (NOT Windows-origin evidence)"
  else
    fail "$leg fixture unreachable even from the same side (bind=$bind port=$port)"
    FAILED=1
  fi

  # `via=` labels the ROUTE, not the literal address, so the two endpoints stay distinguishable even
  # when they render identically (e.g. WGM_WSL_IPV4=127.0.0.1 on a lab host).
  # The Windows-localhost route is observational on both legs: whether WSL's localhost forwarding
  # covers it depends on the distro's networking mode, and either answer is informative.
  probe_windows "$leg" "windows-localhost" "127.0.0.1" "$port" 0 0
  # The WSL-IPv4 route on the ALL-INTERFACES bind is the documented working configuration, so its
  # page, client asset, and WebSocket are REQUIRED. probe_windows raises FAILED itself, so no
  # caller can `|| true` a required failure away. The same route on the LOOPBACK bind is the
  # observation under test — its failure is the boundary, not a harness fault.
  probe_windows "$leg" "wsl-ipv4" "$WSL_IPV4" "$port" 1 "$required"

  stop_fixture
}

# The second leg binds 0.0.0.0 on purpose: that is the configuration under test. Be aware that it
# publishes the disposable fixture on ALL LOCAL INTERFACES, so it is reachable from the local network
# for the few seconds the leg runs. The fixture serves only static test content on an ephemeral port
# and is torn down (with the temp dir) before the script exits.
note "fixture: stdlib HTTP+WebSocket service, disposable, ephemeral port; the second leg binds 0.0.0.0, which exposes it on ALL LOCAL INTERFACES (LAN-reachable) for the duration of that leg, then tears it down"
run_leg "loopback-bind" "127.0.0.1" 0
run_leg "all-interfaces-bind" "0.0.0.0" 1

# ---- 3. verdict --------------------------------------------------------------------------------
echo
echo "wsl-boundary: observed matrix (leg | route | endpoint | probe origin | http | asset | websocket | probe rc | required)"
for row in ${RESULTS[@]+"${RESULTS[@]}"}; do
  printf '  %s\n' "${row//|/ | }"
done
echo

finish() {  # single exit point: a seam-driven run can never end in a bare GREEN
  if [[ "$SIMULATED" -eq 1 ]]; then
    printf 'wsl-boundary: seams-overridden=%s\n' "$(IFS=,; printf '%s' "${SEAMS[*]}")"
    if [[ "$FAILED" -eq 0 ]]; then
      echo "wsl-boundary: SIMULATED (UNVERIFIED) — every check passed, but detection seams were overridden, so this run is harness coverage and NOT field evidence. [learn] agent-frontier/wgm#101 stays open until a run with seams-overridden=none on a real Windows+WSL host." >&2
      exit 4
    fi
    echo "wsl-boundary: RED (SIMULATED / UNVERIFIED — seams overridden; not field evidence)" >&2
    exit 1
  fi
  if [[ "$FAILED" -eq 0 ]]; then
    echo "wsl-boundary: GREEN"
    exit 0
  fi
  echo "wsl-boundary: RED" >&2
  exit 1
}

if [[ "$WINDOWS_ORIGIN_SEEN" -eq 0 ]]; then
  fail "no probe ran as a Windows process — nothing here is boundary evidence"
  FAILED=1
  finish
fi

LOOPBACK_WSLIP="$(field_for "loopback-bind|via=wsl-ipv4|" http)"
ALLIF_WSLIP="$(field_for "all-interfaces-bind|via=wsl-ipv4|" http)"
ALLIF_ASSET="$(field_for "all-interfaces-bind|via=wsl-ipv4|" asset)"
ALLIF_WS="$(field_for "all-interfaces-bind|via=wsl-ipv4|" ws)"

note "loopback bind      via=wsl-ipv4 (http://$WSL_IPV4/): http=$LOOPBACK_WSLIP"
note "all-interfaces bind via=wsl-ipv4 (http://$WSL_IPV4/): http=$ALLIF_WSLIP asset=$ALLIF_ASSET websocket=$ALLIF_WS"

if [[ "$ALLIF_WSLIP" != "ok" || "$ALLIF_ASSET" != "ok" ]] || [[ "$ALLIF_WS" != "ok" && "$ALLIF_WS" != "unsupported" ]]; then
  fail "the all-interfaces bind did not fully serve a Windows-origin consumer at http://$WSL_IPV4/ (http=$ALLIF_WSLIP asset=$ALLIF_ASSET websocket=$ALLIF_WS) — the documented working configuration is broken on this host (firewall, WSL networking mode, or the fixture)."
  FAILED=1
fi

case "$LOOPBACK_WSLIP" in
  ok)
    note "note: the loopback bind was ALSO reachable at the WSL IPv4 address on this host — this distro is not using the NAT networking mode that produced [learn] #101 (mirrored networking, or a forwarder). The boundary caveat still applies to hosts that are." ;;
  fail)
    if [[ "$SIMULATED" -eq 1 ]]; then
      note "boundary reproduced in SIMULATION (seams overridden — NOT field evidence): a WSL-loopback bind was not reachable by the probe at the WSL IPv4 address."
    else
      note "boundary confirmed: a WSL-loopback bind is invisible to a Windows-origin consumer at the WSL IPv4 address ([learn] agent-frontier/wgm#101). Publish on all interfaces and consume at the WSL IPv4 address."
    fi ;;
  *)
    fail "no usable observation for the loopback bind via wsl-ipv4 (http=$LOOPBACK_WSLIP) — the boundary is UNKNOWN on this host, not confirmed. Re-run once the probe can reach that endpoint."
    FAILED=1 ;;
esac

finish
