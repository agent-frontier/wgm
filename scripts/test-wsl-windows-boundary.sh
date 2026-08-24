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
#      /health, /ws echo) twice: once bound to WSL loopback, once bound to all interfaces.
#   3. Sanity-checks each bind from the Linux side, explicitly labeled `same-side` — never counted
#      as Windows-origin evidence.
#   4. Invokes scripts/test-wsl-reachability.ps1 as a Windows process against BOTH the Windows
#      localhost endpoint and the WSL IPv4 endpoint for BOTH binds, and refuses any probe output
#      that does not report a Windows origin platform.
#   5. Prints a per-endpoint matrix with the observed result, then a verdict.
#
# Usage:
#   scripts/test-wsl-windows-boundary.sh [--timeout SEC] [--keep] [-h|--help]
#
# Flags:
#   --timeout SEC   per-probe timeout in seconds (default 5)
#   --keep          keep the temporary fixture directory (prints its path) for debugging
#   -h | --help     show this help
#
# Environment seams (also used by scripts/test-wsl-boundary-harness.sh to drive failure paths):
#   WGM_WSL_PROC_VERSION_FILE   kernel version file to inspect         (default /proc/version)
#   WGM_WSL_BINFMT_DIR          binfmt_misc dir holding WSLInterop*    (default /proc/sys/fs/binfmt_misc)
#   WGM_WSL_WINDOWS_MOUNT_ROOT  DrvFs mount root for Windows drives    (default /mnt)
#   WGM_WSL_PWSH                explicit Windows PowerShell executable (default: auto-detect)
#   WGM_WSL_IPV4                explicit WSL IPv4 address             (default: auto-detect)
#
# Exit 0 = green (Windows-origin probe ran and the all-interfaces bind was reachable).
# Exit 1 = red (a required probe failed, or a probe did not originate on Windows).
# Exit 2 = usage error.
# Exit 3 = unsupported host (not WSL, no Windows interop, or no usable Windows PowerShell).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_PS1="$ROOT/scripts/test-wsl-reachability.ps1"

TIMEOUT=5
KEEP=0

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

probe_windows() {  # $1 = leg label, $2 = endpoint host, $3 = port, $4 = websocket (0|1)
  local leg="$1" host="$2" port="$3" want_ws="$4"
  local url="http://$host:$port/"
  local out rc origin http_outcome ws_outcome
  local -a args=(-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PROBE_WIN_PATH"
                 -Url "$url" -AssetPath "assets/client.js" -TimeoutSec "$TIMEOUT")
  if [[ "$want_ws" -eq 1 ]]; then
    args+=(-WebSocketUrl "ws://$host:$port/ws")
  fi

  out="$("$PWSH" "${args[@]}" 2>&1)"; rc=$?

  origin="$(printf '%s\n' "$out" | sed -n 's/^origin-platform=//p' | head -n1)"
  http_outcome="$(printf '%s\n' "$out" | sed -n "s|^result endpoint=$url .*outcome=\([a-z]*\).*|\1|p" | head -n1)"
  ws_outcome="$(printf '%s\n' "$out" | sed -n 's|^result endpoint=ws://.* outcome=\([a-z]*\).*|\1|p' | head -n1)"
  [[ -n "$http_outcome" ]] || http_outcome="none"
  [[ -n "$ws_outcome" ]] || ws_outcome="not-requested"

  if [[ "$origin" != "Win32NT" ]]; then
    fail "probe for $leg $url did not originate on Windows (origin-platform='${origin:-missing}', rc=$rc). Refusing to record a same-side result as Windows-origin evidence."
    printf '%s\n' "$out" | sed 's/^/      /' >&2
    FAILED=1
    RESULTS+=("$leg|$url|origin=NOT-WINDOWS|http=$http_outcome|ws=$ws_outcome|rc=$rc")
    return 1
  fi

  WINDOWS_ORIGIN_SEEN=1
  RESULTS+=("$leg|$url|origin=windows|http=$http_outcome|ws=$ws_outcome|rc=$rc")
  note "$(printf '%-19s' "$leg") endpoint=$url  windows-origin=yes  http=$http_outcome  websocket=$ws_outcome  probe-rc=$rc"
  [[ "$rc" -eq 0 ]]
}

outcome_for() {  # $1 = recorded row prefix — echoes that row's http outcome
  local row
  for row in ${RESULTS[@]+"${RESULTS[@]}"}; do
    if [[ "$row" == "$1"* ]]; then
      printf '%s' "$row" | sed -n 's/.*|http=\([a-z-]*\)|.*/\1/p'
      return 0
    fi
  done
  printf 'missing'
}

run_leg() {  # $1 = leg label, $2 = bind address
  local leg="$1" bind="$2" port
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

  probe_windows "$leg" "127.0.0.1" "$port" 0 || true
  probe_windows "$leg" "$WSL_IPV4" "$port" 1 || true

  stop_fixture
}

note "fixture: stdlib HTTP+WebSocket service, disposable, bound only to this machine's interfaces"
run_leg "loopback-bind" "127.0.0.1"
run_leg "all-interfaces-bind" "0.0.0.0"

# ---- 3. verdict --------------------------------------------------------------------------------
echo
echo "wsl-boundary: observed matrix (leg | endpoint | probe origin | http | websocket | probe rc)"
for row in ${RESULTS[@]+"${RESULTS[@]}"}; do
  printf '  %s\n' "${row//|/ | }"
done
echo

if [[ "$WINDOWS_ORIGIN_SEEN" -eq 0 ]]; then
  fail "no probe ran as a Windows process — nothing here is boundary evidence"
  echo "wsl-boundary: RED" >&2
  exit 1
fi

LOOPBACK_WSLIP="$(outcome_for "loopback-bind|http://$WSL_IPV4:")"
ALLIF_WSLIP="$(outcome_for "all-interfaces-bind|http://$WSL_IPV4:")"

note "loopback bind, probed from Windows at the WSL IPv4 address: http=${LOOPBACK_WSLIP:-missing}"
note "all-interfaces bind, probed from Windows at the WSL IPv4 address: http=${ALLIF_WSLIP:-missing}"

if [[ "$ALLIF_WSLIP" != "ok" ]]; then
  fail "the all-interfaces bind was NOT reachable from Windows at http://$WSL_IPV4/ — the documented working configuration is broken on this host (firewall, WSL networking mode, or the fixture)."
  FAILED=1
fi

if [[ "$LOOPBACK_WSLIP" == "ok" ]]; then
  note "note: the loopback bind was ALSO reachable at the WSL IPv4 address on this host — this distro is not using the NAT networking mode that produced [learn] #101 (mirrored networking, or a forwarder). The boundary caveat still applies to hosts that are."
else
  note "boundary confirmed: a WSL-loopback bind is invisible to a Windows-origin consumer at the WSL IPv4 address ([learn] agent-frontier/wgm#101). Publish on all interfaces and consume at the WSL IPv4 address."
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "wsl-boundary: GREEN"
  exit 0
fi
echo "wsl-boundary: RED" >&2
exit 1
