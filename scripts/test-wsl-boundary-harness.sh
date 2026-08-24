#!/usr/bin/env bash
#
# wgm/test-wsl-boundary-harness.sh — deterministic backpressure for the WSL/Windows boundary check.
#
# scripts/test-wsl-windows-boundary.sh can only produce real evidence on a Windows host running WSL,
# so it can never be a CI gate by itself. This harness is the portable half: it runs anywhere and
# proves the parts that must hold *before* anyone trusts a boundary result —
#
#   A  usage/flag handling (help, unknown flag, bad --timeout).
#   B  an unsupported host fails loudly and NONZERO (exit 3), never silently "passes".
#   C  the anti-fake guard: a synthetic powershell.exe on the Linux filesystem is rejected.
#   D  a shim that IS in the right place but reports a non-Windows origin is rejected as evidence —
#      a same-side simulation can never be relabeled as Windows-origin evidence ([learn] #101).
#   E  scripts/test-wsl-reachability.ps1 rejects a bad URL (exit 2), reports an unreachable endpoint
#      as a failure (exit 1), fetches a live local fixture (exit 0), honours -RequireWebSocket in
#      both directions, and ignores a bogus system proxy — skipped when no pwsh.
#   F  the accept path, the seam policy and the required-failure paths, driven by a SIMULATED
#      Windows PowerShell that speaks the probe's output contract with CRLF line endings: a genuine
#      `Win32NT\r` must be parsed and accepted, yet — because these runs override detection seams —
#      the result must be labeled SIMULATED/UNVERIFIED with a nonzero exit and never a bare GREEN.
#      A page that is 200 while the client asset or the WebSocket fails must end RED, an
#      unavailable WebSocket client type must be reported (not folded into a pass), a probe with no
#      observation must be UNKNOWN rather than a confirmed boundary, and a wedged probe must be
#      diagnosed as a timeout rather than as a non-Windows origin.
#
# ON THE TEST DOUBLES IN SECTION F: they exist ONLY to exercise this orchestrator's parsing and
# verdict logic, and they announce themselves (`origin-host=SIMULATED-...`). They reach the probe
# path solely because this harness redirects WGM_WSL_WINDOWS_MOUNT_ROOT at a scratch directory —
# something no real run does. A GREEN from a simulated double is a statement about the harness, and
# NEVER field evidence about a real Windows -> WSL boundary; only a run on a real Windows+WSL host
# can produce that (see [learn] issue agent-frontier/wgm#101, which remains open until one is).
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOUNDARY="$ROOT/scripts/test-wsl-windows-boundary.sh"
PROBE="$ROOT/scripts/test-wsl-reachability.ps1"

FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wgm-wsl-boundary-test.XXXXXX")"
FIXTURE_PID=""
trap '
  [[ -n "$FIXTURE_PID" ]] && kill "$FIXTURE_PID" 2>/dev/null
  rm -rf "$TMP"
' EXIT

[[ -f "$BOUNDARY" ]] || { fail "missing $BOUNDARY"; exit 1; }
[[ -f "$PROBE" ]]    || { fail "missing $PROBE"; exit 1; }

OUT=""; RC=0
run_boundary() {  # invoke the orchestrator, capturing combined output + exit code
  OUT="$(env "$@" bash "$BOUNDARY" 2>&1)"; RC=$?
}

# A pretend WSL kernel banner and a pretend interop registration, so the preflight ordering can be
# driven deterministically on any host (including a real WSL box, where the real /proc would
# otherwise let these cases through).
NOT_WSL="$TMP/proc-version-linux"
IS_WSL="$TMP/proc-version-wsl"
printf 'Linux version 6.8.0-generic (gcc)\n' >"$NOT_WSL"
printf 'Linux version 5.15.0-microsoft-standard-WSL2 (oe-user@oe-host)\n' >"$IS_WSL"

BINFMT_EMPTY="$TMP/binfmt-empty"; mkdir -p "$BINFMT_EMPTY"
BINFMT_OK="$TMP/binfmt-ok";       mkdir -p "$BINFMT_OK"; : >"$BINFMT_OK/WSLInterop"

# A shim on the LINUX filesystem — the shape of a fake that must never be accepted.
FAKE_LINUX_PWSH="$TMP/fake-bin/powershell.exe"
mkdir -p "$(dirname "$FAKE_LINUX_PWSH")"
printf '#!/usr/bin/env bash\necho "origin-platform=Win32NT"\necho "probe-exit=0"\n' >"$FAKE_LINUX_PWSH"
chmod +x "$FAKE_LINUX_PWSH"

# A shim under a *simulated* Windows mount root: it passes the location check, but it honestly
# reports a Unix origin, so the orchestrator must refuse to count it.
FAKE_MOUNT_ROOT="$TMP/mnt"
FAKE_MOUNT_PWSH="$FAKE_MOUNT_ROOT/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
mkdir -p "$(dirname "$FAKE_MOUNT_PWSH")"
printf '#!/usr/bin/env bash\necho "origin-platform=Unix"\necho "origin-host=linux-sim"\necho "probe-exit=0"\n' >"$FAKE_MOUNT_PWSH"
chmod +x "$FAKE_MOUNT_PWSH"

# ---- A: usage & flags --------------------------------------------------------------------------
OUT="$(bash "$BOUNDARY" --help 2>&1)"; RC=$?
if [[ "$RC" -eq 0 ]] && grep -q "wgm/test-wsl-windows-boundary.sh" <<<"$OUT"; then
  pass "A1 --help shows usage and exits 0"
else
  fail "A1 --help did not show usage (rc=$RC)"
fi

OUT="$(bash "$BOUNDARY" --frobnicate 2>&1)"; RC=$?
if [[ "$RC" -eq 2 ]] && grep -q "Unknown flag" <<<"$OUT"; then
  pass "A2 an unknown flag exits 2"
else
  fail "A2 unknown flag not rejected with exit 2 (rc=$RC)"
fi

OUT="$(bash "$BOUNDARY" --timeout 0 2>&1)"; RC=$?
if [[ "$RC" -eq 2 ]] && grep -q "must be an integer" <<<"$OUT"; then
  pass "A3 an out-of-range --timeout exits 2"
else
  fail "A3 bad --timeout not rejected with exit 2 (rc=$RC)"
fi

OUT="$(bash "$BOUNDARY" extra-arg 2>&1)"; RC=$?
if [[ "$RC" -eq 2 ]]; then
  pass "A4 an unexpected positional argument exits 2"
else
  fail "A4 positional argument not rejected with exit 2 (rc=$RC)"
fi

# ---- B: unsupported host is loud and nonzero ----------------------------------------------------
run_boundary "WGM_WSL_PROC_VERSION_FILE=$NOT_WSL" "WGM_WSL_BINFMT_DIR=$BINFMT_OK"
if [[ "$RC" -eq 3 ]] && grep -q "not running inside WSL" <<<"$OUT" && grep -q "UNSUPPORTED HOST" <<<"$OUT"; then
  pass "B1 a non-WSL host exits 3 with a visible reason"
else
  fail "B1 non-WSL host did not exit 3 with a clear message (rc=$RC): $OUT"
fi

run_boundary "WGM_WSL_PROC_VERSION_FILE=$IS_WSL" "WGM_WSL_BINFMT_DIR=$BINFMT_EMPTY"
if [[ "$RC" -eq 3 ]] && grep -q "interop is not registered" <<<"$OUT"; then
  pass "B2 WSL without Windows interop exits 3"
else
  fail "B2 missing interop did not exit 3 (rc=$RC): $OUT"
fi

run_boundary "WGM_WSL_PROC_VERSION_FILE=$IS_WSL" "WGM_WSL_BINFMT_DIR=$BINFMT_OK" \
             "WGM_WSL_WINDOWS_MOUNT_ROOT=$FAKE_MOUNT_ROOT" "WGM_WSL_PWSH=$TMP/does-not-exist.exe"
if [[ "$RC" -eq 3 ]] && grep -q "no Windows PowerShell found" <<<"$OUT"; then
  pass "B3 a missing Windows PowerShell exits 3"
else
  fail "B3 missing PowerShell did not exit 3 (rc=$RC): $OUT"
fi

if grep -q "GREEN" <<<"$OUT"; then
  fail "B4 an unsupported host printed GREEN — a simulation must never be reported as evidence"
else
  pass "B4 no unsupported-host path ever prints GREEN"
fi

# ---- C: anti-fake guard ------------------------------------------------------------------------
run_boundary "WGM_WSL_PROC_VERSION_FILE=$IS_WSL" "WGM_WSL_BINFMT_DIR=$BINFMT_OK" \
             "WGM_WSL_WINDOWS_MOUNT_ROOT=$FAKE_MOUNT_ROOT" "WGM_WSL_PWSH=$FAKE_LINUX_PWSH"
if [[ "$RC" -eq 3 ]] && grep -q "not field evidence" <<<"$OUT"; then
  pass "C1 a synthetic powershell.exe on the Linux filesystem is refused (exit 3)"
else
  fail "C1 synthetic PowerShell was not refused (rc=$RC): $OUT"
fi

# ---- D: same-side simulation is never relabeled as Windows-origin evidence ----------------------
# A stub `wslpath` lets this case run off WSL too: the point under test is what the orchestrator does
# with a probe that reports a NON-Windows origin, not whether this host ships the WSL toolchain.
mkdir -p "$TMP/shim"
printf '#!/usr/bin/env bash\nprintf "C:\\\\stub\\\\probe.ps1\\n"\n' >"$TMP/shim/wslpath"
chmod +x "$TMP/shim/wslpath"

if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  run_boundary "PATH=$TMP/shim:$PATH" \
               "WGM_WSL_PROC_VERSION_FILE=$IS_WSL" "WGM_WSL_BINFMT_DIR=$BINFMT_OK" \
               "WGM_WSL_WINDOWS_MOUNT_ROOT=$FAKE_MOUNT_ROOT" "WGM_WSL_PWSH=$FAKE_MOUNT_PWSH" \
               "WGM_WSL_IPV4=127.0.0.1"
  if [[ "$RC" -ne 0 ]] && grep -q "did not originate on Windows" <<<"$OUT"; then
    pass "D1 a non-Windows probe origin fails nonzero and is not counted as evidence"
  else
    fail "D1 a non-Windows probe origin was not rejected (rc=$RC): $OUT"
  fi

  if grep -q "origin=NOT-WINDOWS" <<<"$OUT" && ! grep -q "GREEN" <<<"$OUT"; then
    pass "D2 the matrix marks the simulated run NOT-WINDOWS and the run ends RED"
  else
    fail "D2 a same-side simulation was not clearly marked in the matrix: $OUT"
  fi

  if grep -q "same-side(linux) sanity" <<<"$OUT" && grep -q "NOT Windows-origin evidence" <<<"$OUT"; then
    pass "D3 the Linux-side readiness check is labeled as NOT Windows-origin evidence"
  else
    fail "D3 the same-side sanity check was not labeled: $OUT"
  fi
else
  printf 'note: python3/curl missing — skipping the simulated-origin cases (D1-D3).\n'
fi

# ---- F: accept path and required-failure path (SIMULATED Windows PowerShell) --------------------
# One env-driven double covers every case. It emits CRLF exactly like a real Windows process, and
# counts its invocations so it can answer differently per leg: the orchestrator always probes the
# loopback bind first (2 calls: windows-localhost, then wsl-ipv4) and the all-interfaces bind second.
SIM_PWSH="$FAKE_MOUNT_ROOT/c/simulated-powershell.exe"
cat >"$SIM_PWSH" <<'SIMEOF'
#!/usr/bin/env bash
# HARNESS TEST DOUBLE — a SIMULATED Windows PowerShell. Its output is never field evidence.
url=""; ws=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -Url) url="$2"; shift 2 ;;
    -WebSocketUrl) ws="$2"; shift 2 ;;
    *) shift ;;
  esac
done

n=1
if [[ -n "${FAKE_COUNTER:-}" ]]; then
  n=$(( $(cat "$FAKE_COUNTER" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$n" >"$FAKE_COUNTER"
fi

crlf() { printf '%s\r\n' "$*"; }
crlf "origin-platform=Win32NT"
crlf "origin-host=SIMULATED-WINDOWS-DOUBLE"

asset="${url}assets/client.js"
rc=0
case "${FAKE_MODE:-all-ok}" in
  boundary)
    # Calls 1-2 are the loopback bind: unreachable from "Windows", which IS the #101 observation.
    if [[ "$n" -le 2 ]]; then
      crlf "result endpoint=$url kind=http status=none outcome=fail detail=webexception:refused"
      crlf "result endpoint=$asset kind=http status=none outcome=fail detail=webexception:refused"
      [[ -n "$ws" ]] && crlf "result endpoint=$ws kind=websocket status=none outcome=fail detail=exception:refused"
      rc=1
    else
      crlf "result endpoint=$url kind=http status=200 outcome=ok detail=bytes=60"
      crlf "result endpoint=$asset kind=http status=200 outcome=ok detail=bytes=80"
      [[ -n "$ws" ]] && crlf "result endpoint=$ws kind=websocket status=101 outcome=ok detail=echo=wgm-probe"
    fi
    ;;
  asset-fail)
    crlf "result endpoint=$url kind=http status=200 outcome=ok detail=bytes=60"
    crlf "result endpoint=$asset kind=http status=404 outcome=fail detail=unexpected-status"
    [[ -n "$ws" ]] && crlf "result endpoint=$ws kind=websocket status=101 outcome=ok detail=echo=wgm-probe"
    rc=1
    ;;
  ws-fail)
    crlf "result endpoint=$url kind=http status=200 outcome=ok detail=bytes=60"
    crlf "result endpoint=$asset kind=http status=200 outcome=ok detail=bytes=80"
    [[ -n "$ws" ]] && crlf "result endpoint=$ws kind=websocket status=none outcome=fail detail=exception:upgrade-refused"
    [[ -n "$ws" ]] && rc=1
    ;;
  hang)
    # Only the first invocation wedges, so the harness pays one hard-timeout wait, not four.
    if [[ "$n" -eq 1 ]]; then sleep 60; fi
    crlf "result endpoint=$url kind=http status=200 outcome=ok detail=bytes=60"
    crlf "result endpoint=$asset kind=http status=200 outcome=ok detail=bytes=80"
    [[ -n "$ws" ]] && crlf "result endpoint=$ws kind=websocket status=101 outcome=ok detail=echo=wgm-probe"
    ;;
  silent)
    # Windows origin, but no observation at all: the orchestrator must call this UNKNOWN.
    :
    ;;
  ws-unsupported)
    crlf "result endpoint=$url kind=http status=200 outcome=ok detail=bytes=60"
    crlf "result endpoint=$asset kind=http status=200 outcome=ok detail=bytes=80"
    [[ -n "$ws" ]] && crlf "result endpoint=$ws kind=websocket status=none outcome=unsupported detail=ClientWebSocket-type-unavailable-on-this-host"
    ;;
  *)
    crlf "result endpoint=$url kind=http status=200 outcome=ok detail=bytes=60"
    crlf "result endpoint=$asset kind=http status=200 outcome=ok detail=bytes=80"
    [[ -n "$ws" ]] && crlf "result endpoint=$ws kind=websocket status=101 outcome=ok detail=echo=wgm-probe"
    ;;
esac
crlf "probe-exit=$rc"
exit "$rc"
SIMEOF
chmod +x "$SIM_PWSH"

sim_boundary() {  # $1 = FAKE_MODE, remaining args = extra orchestrator flags
  local mode="$1"; shift
  : >"$TMP/fake-counter"
  OUT="$(env "PATH=$TMP/shim:$PATH" "FAKE_MODE=$mode" "FAKE_COUNTER=$TMP/fake-counter" \
             "WGM_WSL_PROC_VERSION_FILE=$IS_WSL" "WGM_WSL_BINFMT_DIR=$BINFMT_OK" \
             "WGM_WSL_WINDOWS_MOUNT_ROOT=$FAKE_MOUNT_ROOT" "WGM_WSL_PWSH=$SIM_PWSH" \
             "WGM_WSL_IPV4=127.0.0.1" \
             bash "$BOUNDARY" "$@" 2>&1)"; RC=$?
}

if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  printf 'note: section F drives a SIMULATED Windows PowerShell — harness coverage only, never field evidence.\n'

  # F1 accept path: CRLF Win32NT is accepted, the required all-interfaces leg passes, and the
  # loopback leg's failure is reported as the boundary rather than as a harness fault.
  sim_boundary boundary
  if grep -q "origin=windows" <<<"$OUT" && ! grep -q "did not originate on Windows" <<<"$OUT"; then
    pass "F1 a CRLF 'Win32NT' origin is parsed and accepted internally"
  else
    fail "F1 CRLF Windows origin was not accepted (rc=$RC): $OUT"
  fi

  # The seam policy: everything passed, but the seams were overridden, so this can never look like
  # a verified boundary. Nonzero exit 4, an explicit SIMULATED/UNVERIFIED verdict, no bare GREEN.
  if [[ "$RC" -eq 4 ]] && grep -q "wsl-boundary: SIMULATED (UNVERIFIED)" <<<"$OUT" \
     && ! grep -qx "wsl-boundary: GREEN" <<<"$OUT"; then
    pass "F1b a seam-driven pass exits 4 as SIMULATED/UNVERIFIED and never prints a bare GREEN"
  else
    fail "F1b a seam-driven pass was not labeled simulated (rc=$RC): $OUT"
  fi

  if grep -q "seams-overridden=WGM_WSL_PROC_VERSION_FILE,WGM_WSL_BINFMT_DIR,WGM_WSL_WINDOWS_MOUNT_ROOT,WGM_WSL_PWSH,WGM_WSL_IPV4" <<<"$OUT"; then
    pass "F1c every overridden seam is disclosed on a stable seams-overridden= line"
  else
    fail "F1c the seams-overridden= disclosure is missing or incomplete: $OUT"
  fi

  if grep -q "NOT field evidence" <<<"$OUT" && grep -q "stays open until a run with seams-overridden=none" <<<"$OUT"; then
    pass "F1d a simulated run states it is not field evidence and that #101 stays open"
  else
    fail "F1d a simulated run did not disclaim field evidence: $OUT"
  fi

  if grep -q "boundary reproduced in SIMULATION" <<<"$OUT" && ! grep -q "boundary confirmed" <<<"$OUT"; then
    pass "F2 an observational loopback failure is reported as the boundary, and marked simulated"
  else
    fail "F2 the loopback observation was mislabeled: $OUT"
  fi

  # WGM_WSL_IPV4=127.0.0.1 makes both endpoint URLs identical, so the route label is the only thing
  # keeping them apart. Both routes must still be present for both legs (4 rows).
  rows="$(grep -c '| via=' <<<"$OUT" || true)"
  if [[ "$rows" -eq 4 ]] && grep -q "via=windows-localhost" <<<"$OUT" && grep -q "via=wsl-ipv4" <<<"$OUT"; then
    pass "F3 routes stay unambiguous when the WSL IPv4 equals 127.0.0.1 (4 labeled rows)"
  else
    fail "F3 route labels were ambiguous or incomplete (rows=$rows): $OUT"
  fi

  # F4 required client asset fails while the page is 200 — a root-page-only verdict would miss it.
  sim_boundary asset-fail
  if [[ "$RC" -ne 0 ]] && grep -q "wsl-boundary: RED" <<<"$OUT" && grep -q "required client-asset fetch failed" <<<"$OUT"; then
    pass "F4 a 200 page with a failing client asset ends RED"
  else
    fail "F4 a failing client asset did not end RED (rc=$RC): $OUT"
  fi

  # F5 required WebSocket leg fails while page and asset are fine.
  sim_boundary ws-fail
  if [[ "$RC" -ne 0 ]] && grep -q "wsl-boundary: RED" <<<"$OUT" && grep -q "required WebSocket leg failed" <<<"$OUT"; then
    pass "F5 a failing WebSocket leg ends RED even when page and asset are ok"
  else
    fail "F5 a failing WebSocket leg did not end RED (rc=$RC): $OUT"
  fi

  # F6 `unsupported` is tolerated ONLY as "the Windows host has no ClientWebSocket type".
  sim_boundary ws-unsupported
  if [[ "$RC" -eq 4 ]] && grep -q "websocket check UNSUPPORTED" <<<"$OUT" \
     && grep -q "not counted as a pass" <<<"$OUT" && ! grep -q "required WebSocket leg failed" <<<"$OUT"; then
    pass "F6 an unavailable WebSocket client type is nonfatal-but-reported when nothing else failed"
  else
    fail "F6 unsupported WebSocket handling is wrong (rc=$RC): $OUT"
  fi
  # F7 a probe that returns no observation must never be read as a confirmed boundary.
  sim_boundary silent
  if [[ "$RC" -ne 0 ]] && grep -q "boundary is UNKNOWN" <<<"$OUT" && ! grep -q "boundary confirmed" <<<"$OUT"; then
    pass "F7 a missing observation is reported UNKNOWN, never as a confirmed boundary"
  else
    fail "F7 a missing observation was not reported as UNKNOWN (rc=$RC): $OUT"
  fi
  # F8 a wedged interop path must be reported as a TIMEOUT, never as a non-Windows origin.
  if command -v timeout >/dev/null 2>&1 && timeout --version 2>/dev/null | head -n1 | grep -qi 'coreutils'; then
    sim_boundary hang --timeout 1
    if [[ "$RC" -ne 0 ]] && grep -q "TIMED OUT" <<<"$OUT" \
       && grep -q "NOT evidence that the process was non-Windows" <<<"$OUT" \
       && ! grep -q "did not originate on Windows" <<<"$OUT"; then
      pass "F8 a wedged probe is diagnosed as a timeout, not as a non-Windows origin"
    else
      fail "F8 a wedged probe was misdiagnosed (rc=$RC): $OUT"
    fi
  else
    printf 'note: GNU timeout not available — skipping the wedged-probe case (F8).\n'
  fi
else
  printf 'note: python3/curl missing — skipping the simulated accept/failure cases (F1-F8).\n'
fi

# ---- E: the Windows-origin probe itself ---------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
  OUT="$(pwsh -NoProfile -NonInteractive -File "$PROBE" -Url "ftp://example.invalid/" 2>&1)"; RC=$?
  if [[ "$RC" -eq 2 ]] && grep -q "unsupported-scheme" <<<"$OUT"; then
    pass "E1 the probe rejects a non-HTTP URL with exit 2"
  else
    fail "E1 probe did not reject a non-HTTP URL (rc=$RC): $OUT"
  fi

  OUT="$(pwsh -NoProfile -NonInteractive -File "$PROBE" -Url "not a url" 2>&1)"; RC=$?
  if [[ "$RC" -eq 2 ]] && grep -q "invalid-url" <<<"$OUT"; then
    pass "E2 the probe rejects a malformed URL with exit 2"
  else
    fail "E2 probe did not reject a malformed URL (rc=$RC): $OUT"
  fi

  OUT="$(pwsh -NoProfile -NonInteractive -File "$PROBE" -Url "http://127.0.0.1:1/" -TimeoutSec 2 2>&1)"; RC=$?
  if [[ "$RC" -eq 1 ]] && grep -q "outcome=fail" <<<"$OUT"; then
    pass "E3 the probe reports an unreachable endpoint as a failure (exit 1)"
  else
    fail "E3 probe did not fail on an unreachable endpoint (rc=$RC): $OUT"
  fi

  if command -v python3 >/dev/null 2>&1; then
    # Reuse the orchestrator's own fixture by extracting it, so the probe is exercised against the
    # exact service the boundary check serves. This is a SAME-SIDE run: it validates the probe's
    # HTTP/asset/WebSocket logic only, and proves nothing about the Windows boundary.
    awk '/^cat >"\$FIXTURE" <<.PYFIXTURE.$/{flag=1;next} /^PYFIXTURE$/{flag=0} flag' "$BOUNDARY" >"$TMP/fixture.py"
    PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
    python3 "$TMP/fixture.py" 127.0.0.1 "$PORT" >"$TMP/fixture.log" 2>&1 &
    FIXTURE_PID=$!
    ready=0
    for _ in $(seq 1 50); do
      if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then ready=1; break; fi
      sleep 0.1
    done

    if [[ "$ready" -eq 1 ]]; then
      OUT="$(pwsh -NoProfile -NonInteractive -File "$PROBE" -Url "http://127.0.0.1:$PORT/" \
              -AssetPath "assets/client.js" -WebSocketUrl "ws://127.0.0.1:$PORT/ws" -TimeoutSec 5 2>&1)"; RC=$?
      if [[ "$RC" -eq 0 ]] && grep -q "kind=http status=200 outcome=ok" <<<"$OUT"; then
        pass "E4 the probe fetches the page and the generated client asset (exit 0)"
      else
        fail "E4 probe did not fetch the live fixture (rc=$RC): $OUT"
      fi

      if grep -qE "kind=websocket .*outcome=(ok|unsupported)" <<<"$OUT"; then
        pass "E5 the WebSocket leg reports an explicit ok/unsupported outcome"
      else
        fail "E5 WebSocket leg reported neither ok nor unsupported: $OUT"
      fi

      if grep -q "^origin-platform=" <<<"$OUT"; then
        pass "E6 the probe always declares the platform it ran on"
      else
        fail "E6 probe did not declare origin-platform: $OUT"
      fi

      # E7 -RequireWebSocket must be wired: a reachable service with a working upgrade still exits 0.
      OUT="$(pwsh -NoProfile -NonInteractive -File "$PROBE" -Url "http://127.0.0.1:$PORT/" \
              -AssetPath "assets/client.js" -WebSocketUrl "ws://127.0.0.1:$PORT/ws" \
              -RequireWebSocket -TimeoutSec 5 2>&1)"; RC=$?
      if [[ "$RC" -eq 0 ]] && grep -q "kind=websocket status=101 outcome=ok" <<<"$OUT"; then
        pass "E7 -RequireWebSocket passes when the upgrade succeeds"
      else
        fail "E7 -RequireWebSocket failed on a working WebSocket (rc=$RC): $OUT"
      fi

      # E8 with -RequireWebSocket a refused upgrade is fatal, even though the page and asset are ok.
      OUT="$(pwsh -NoProfile -NonInteractive -File "$PROBE" -Url "http://127.0.0.1:$PORT/" \
              -AssetPath "assets/client.js" -WebSocketUrl "ws://127.0.0.1:1/ws" \
              -RequireWebSocket -TimeoutSec 2 2>&1)"; RC=$?
      if [[ "$RC" -eq 1 ]] && grep -q "kind=websocket .*outcome=fail" <<<"$OUT"; then
        pass "E8 -RequireWebSocket makes a refused upgrade fatal (exit 1)"
      else
        fail "E8 a refused required upgrade was not fatal (rc=$RC): $OUT"
      fi

      # E9 a bogus system proxy must not break a local boundary probe: the probe disables the proxy
      # for its own requests, and says so in any failure detail.
      OUT="$(env HTTP_PROXY="http://127.0.0.1:1" HTTPS_PROXY="http://127.0.0.1:1" \
              http_proxy="http://127.0.0.1:1" https_proxy="http://127.0.0.1:1" \
              pwsh -NoProfile -NonInteractive -File "$PROBE" -Url "http://127.0.0.1:$PORT/" \
              -AssetPath "assets/client.js" -TimeoutSec 5 2>&1)"; RC=$?
      if [[ "$RC" -eq 0 ]] && grep -q "kind=http status=200 outcome=ok" <<<"$OUT"; then
        pass "E9 an unreachable system proxy does not break the probe (proxy bypassed for it)"
      else
        fail "E9 the probe honored a bogus system proxy (rc=$RC): $OUT"
      fi
    else
      fail "E4 local fixture never became ready (see $TMP/fixture.log)"
    fi
    kill "$FIXTURE_PID" 2>/dev/null; FIXTURE_PID=""
  else
    printf 'note: python3 not found — skipping the live-fixture probe cases (E4-E6).\n'
  fi
else
  printf 'note: pwsh not found — skipping the PowerShell probe cases (E1-E6).\n'
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "wsl-boundary harness: GREEN"
  exit 0
fi
echo "wsl-boundary harness: RED" >&2
exit 1
