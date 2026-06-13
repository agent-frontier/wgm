#!/usr/bin/env bash
#
# wgm/test-install.sh — deterministic backpressure for the installers (WSL <-> Windows bridge).
#
# Exercises scripts/install.sh end-to-end against throwaway HOME / Windows-home dirs so the build
# loop has a real pass/fail signal (not just "it didn't crash"). Covers:
#   T1  WSL + --windows-home  -> both Linux and Windows targets are planned (dry-run).
#   T2  --no-windows          -> the Windows target is suppressed.
#   T3  non-WSL               -> no Windows target even when --windows-home is given.
#   T4  real install          -> SKILL.md lands in BOTH homes (a real copy, not a symlink).
#   T5  re-run (no --force)    -> a recognized wgm install is refreshed in place ("updating ...").
#   T6  unrecognized target    -> left untouched without --force (no clobber).
#   T7  uninstall              -> removes BOTH homes.
#   T8  best-effort            -> WSL on but no resolvable Windows home: warn, still install Linux, rc 0.
#   T9  live resolver (WSL)    -> on a real WSL host, autodetect resolves a Windows home under /mnt.
#
# Testing/advanced override seams honoured by install.sh:
#   WGM_FORCE_WSL=0|1      force the WSL detection result (so we can simulate non-WSL on a WSL host).
#   WGM_WIN_AUTODETECT=0|1 disable/enable Windows-home autodetect (default 1).
#   WGM_WINDOWS_HOME=PATH  same as --windows-home.
#
# Exit 0 = green (all checks pass). Exit 1 = red (one or more failures, listed).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
[[ -f "$INSTALL" ]] || { echo "cannot find install.sh at $INSTALL" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { printf 'ok:   %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

contains() { printf '%s\n' "$1" | grep -qF -- "$2"; }   # contains HAYSTACK NEEDLE

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wgm-test.XXXXXX")"
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

WGM="wgm"   # installed dir basename
SUB=".agents/skills/$WGM"

# ---- T1: WSL + --windows-home -> both targets planned (dry-run) -------------
lh="$WORK/t1-lin"; wh="$WORK/t1-win"; mkdir -p "$lh" "$wh"
out="$(HOME="$lh" WGM_FORCE_WSL=1 bash "$INSTALL" --user --client agents --windows-home "$wh" --dry-run 2>&1)"
if contains "$out" "$lh/$SUB" && contains "$out" "$wh/$SUB"; then
  ok "T1 WSL dry-run plans both Linux ($lh/$SUB) and Windows ($wh/$SUB) targets"
else
  bad "T1 expected both Linux and Windows targets in dry-run output"
fi

# ---- T2: --no-windows suppresses the Windows target ------------------------
lh="$WORK/t2-lin"; wh="$WORK/t2-win"; mkdir -p "$lh" "$wh"
out="$(HOME="$lh" WGM_FORCE_WSL=1 bash "$INSTALL" --user --client agents --windows-home "$wh" --no-windows --dry-run 2>&1)"
if contains "$out" "$lh/$SUB" && ! contains "$out" "$wh/$SUB"; then
  ok "T2 --no-windows keeps Linux target and drops the Windows target"
else
  bad "T2 --no-windows should suppress the Windows target"
fi

# ---- T3: non-WSL -> no Windows target even with --windows-home -------------
lh="$WORK/t3-lin"; wh="$WORK/t3-win"; mkdir -p "$lh" "$wh"
out="$(HOME="$lh" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client agents --windows-home "$wh" --dry-run 2>&1)"
if contains "$out" "$lh/$SUB" && ! contains "$out" "$wh/$SUB"; then
  ok "T3 non-WSL never mirrors to Windows (macOS/Linux behaviour preserved)"
else
  bad "T3 non-WSL must not produce a Windows target"
fi

# ---- T4: real install lands SKILL.md in BOTH homes ------------------------
lh="$WORK/t4-lin"; wh="$WORK/t4-win"; mkdir -p "$lh" "$wh"
HOME="$lh" WGM_FORCE_WSL=1 bash "$INSTALL" --user --client agents --windows-home "$wh" --method copy >/dev/null 2>&1
if [[ -f "$lh/$SUB/SKILL.md" && ! -L "$lh/$SUB/SKILL.md" && -f "$wh/$SUB/SKILL.md" && ! -L "$wh/$SUB/SKILL.md" ]]; then
  ok "T4 real install copied SKILL.md into both the Linux and Windows homes"
else
  bad "T4 expected SKILL.md as a real file in both $lh/$SUB and $wh/$SUB"
fi

# ---- T5: re-run refreshes a recognized wgm install without --force --------
out="$(HOME="$lh" WGM_FORCE_WSL=1 bash "$INSTALL" --user --client agents --windows-home "$wh" 2>&1)"
if contains "$out" "updating existing wgm install"; then
  ok "T5 re-run idempotently updates the recognized wgm install (no --force needed)"
else
  bad "T5 expected an 'updating existing wgm install' line on re-run"
fi

# ---- T6: an unrecognized target is not clobbered without --force ----------
lh="$WORK/t6-lin"; mkdir -p "$lh/$SUB"
printf 'keep me\n' > "$lh/$SUB/sentinel.txt"
printf 'name: not-wgm\n' > "$lh/$SUB/SKILL.md"
out="$(HOME="$lh" WGM_FORCE_WSL=0 bash "$INSTALL" --user --client agents 2>&1)"
if contains "$out" "skipping" && [[ -f "$lh/$SUB/sentinel.txt" ]] && grep -q 'not-wgm' "$lh/$SUB/SKILL.md"; then
  ok "T6 unrecognized directory left intact (skipped) without --force"
else
  bad "T6 a non-wgm directory must not be overwritten without --force"
fi

# ---- T7: uninstall removes both homes -------------------------------------
lh="$WORK/t7-lin"; wh="$WORK/t7-win"; mkdir -p "$lh" "$wh"
HOME="$lh" WGM_FORCE_WSL=1 bash "$INSTALL" --user --client agents --windows-home "$wh" --method copy >/dev/null 2>&1
HOME="$lh" WGM_FORCE_WSL=1 bash "$INSTALL" --user --client agents --windows-home "$wh" --uninstall >/dev/null 2>&1
if [[ ! -e "$lh/$SUB" && ! -e "$wh/$SUB" ]]; then
  ok "T7 uninstall removed both the Linux and Windows copies"
else
  bad "T7 uninstall should remove both $lh/$SUB and $wh/$SUB"
fi

# ---- T8: best-effort when no Windows home resolves ------------------------
lh="$WORK/t8-lin"; mkdir -p "$lh"
out="$(HOME="$lh" WGM_FORCE_WSL=1 WGM_WIN_AUTODETECT=0 bash "$INSTALL" --user --client agents 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]] && [[ -f "$lh/$SUB/SKILL.md" ]] && contains "$out" "Windows home"; then
  ok "T8 unresolvable Windows home degrades gracefully (warns, installs Linux, rc 0)"
else
  bad "T8 best-effort: should warn, still install Linux, and exit 0 (rc=$rc)"
fi

# ---- T9: live resolver on a real WSL host (skipped off-WSL) ----------------
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && [[ -d /mnt/c ]]; then
  lh="$WORK/t9-lin"; mkdir -p "$lh"
  out="$(HOME="$lh" bash "$INSTALL" --user --client agents --dry-run 2>&1)"
  if printf '%s\n' "$out" | grep -qE '/mnt/.*\.agents/skills/wgm'; then
    ok "T9 live autodetect resolved a Windows home under /mnt and planned a mirror"
  else
    bad "T9 on real WSL, autodetect should resolve a Windows mirror target under /mnt"
  fi
else
  ok "T9 skipped (not a real WSL host)"
fi

echo ""
echo "install tests: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -eq 0 ]]; then echo "install: GREEN"; exit 0; else echo "install: RED" >&2; exit 1; fi
