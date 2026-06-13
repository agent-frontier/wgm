#!/usr/bin/env pwsh
#
# wgm/test-install.ps1 — deterministic backpressure for the PowerShell installer.
#
# Runs scripts/install.ps1 against throwaway dirs and a fake wsl.exe so the build loop has a real
# pass/fail signal for the Windows-side behaviour. Covers:
#   A  native install lands SKILL.md, and a re-run idempotently updates it (no -Force).
#   B  an unrecognized directory is left intact without -Force (no clobber).
#   C  when WSL is "available" (fake wsl.exe), a user-scope install delegates to bash inside WSL.
#   D  -NoWsl forces a native install even when WSL is available.
#
# Exit 0 = green, 1 = red.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$installPs = Join-Path $root 'scripts/install.ps1'
if (-not (Test-Path $installPs)) { Write-Error "cannot find install.ps1 at $installPs"; exit 2 }

$script:pass = 0
$script:fail = 0
function Ok($m) { Write-Host "ok:   $m"; $script:pass++ }
function Bad($m) { Write-Warning "FAIL: $m"; $script:fail++ }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('wgm-pstest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
  # ---- A: native install + idempotent re-run --------------------------------
  $dirA = Join-Path $work 'a'
  New-Item -ItemType Directory -Force -Path $dirA | Out-Null
  & pwsh -NoProfile -File $installPs -NoWsl -Dir $dirA -Client agents *> $null
  if (Test-Path (Join-Path $dirA 'wgm/SKILL.md')) { Ok 'A1 native install landed SKILL.md' }
  else { Bad 'A1 expected SKILL.md under the -Dir target' }

  $outA = (& pwsh -NoProfile -File $installPs -NoWsl -Dir $dirA -Client agents 2>&1 | Out-String)
  if ($outA -match 'updating existing wgm install') { Ok 'A2 re-run idempotently updates a recognized install (no -Force)' }
  else { Bad 'A2 expected an "updating existing wgm install" line on re-run' }

  # ---- B: unrecognized directory is preserved without -Force ----------------
  $dirB = Join-Path $work 'b'
  New-Item -ItemType Directory -Force -Path (Join-Path $dirB 'wgm') | Out-Null
  Set-Content -Path (Join-Path $dirB 'wgm/SKILL.md') -Value 'name: not-wgm'
  Set-Content -Path (Join-Path $dirB 'wgm/sentinel.txt') -Value 'keep'
  $outB = (& pwsh -NoProfile -File $installPs -NoWsl -Dir $dirB -Client agents 2>&1 | Out-String)
  if (($outB -match 'skipping') -and (Test-Path (Join-Path $dirB 'wgm/sentinel.txt'))) { Ok 'B unrecognized directory left intact (skipped) without -Force' }
  else { Bad 'B a non-wgm directory must not be overwritten without -Force' }

  # ---- fake wsl.exe ---------------------------------------------------------
  $binDir = Join-Path $work 'bin'
  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  $fake = Join-Path $binDir 'wsl.exe'
  $fakeBody = @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WSL_FAKE_LOG"
a=("$@"); i=0
[[ "${a[0]:-}" == "-d" ]] && i=2
case "${a[$i]:-}" in
  -l) echo "Ubuntu" ;;
  wslpath) echo "/mnt/c/fake/scripts/install.sh" ;;
  bash) exit 0 ;;
  *) exit 0 ;;
esac
'@
  Set-Content -Path $fake -Value ($fakeBody -replace "`r`n", "`n") -NoNewline
  chmod +x $fake
  $savedPath = $env:PATH
  $savedHome = $env:HOME
  $savedUserProfile = $env:USERPROFILE

  # ---- C: WSL available -> delegate to bash ---------------------------------
  $logC = Join-Path $work 'wslC.log'
  $sandboxC = Join-Path $work 'homeC'
  New-Item -ItemType Directory -Force -Path $sandboxC | Out-Null
  $env:WSL_FAKE_LOG = $logC
  $env:PATH = $binDir + [IO.Path]::PathSeparator + $savedPath
  $env:HOME = $sandboxC
  $env:USERPROFILE = $sandboxC
  try { & pwsh -NoProfile -File $installPs -User -Client agents *> $null }
  finally { $env:PATH = $savedPath; $env:HOME = $savedHome; $env:USERPROFILE = $savedUserProfile }
  $loggedC = if (Test-Path $logC) { Get-Content -Raw $logC } else { '' }
  if ($loggedC -match '(^|\s)bash(\s|$)') { Ok 'C WSL detected -> delegated to the bash installer inside WSL' }
  else { Bad 'C expected a delegated "bash" call recorded by the fake wsl.exe' }

  # ---- D: -NoWsl forces a native install ------------------------------------
  $dirD = Join-Path $work 'd'
  $logD = Join-Path $work 'wslD.log'
  $env:WSL_FAKE_LOG = $logD
  $env:PATH = $binDir + [IO.Path]::PathSeparator + $savedPath
  try { & pwsh -NoProfile -File $installPs -NoWsl -Dir $dirD -Client agents *> $null }
  finally { $env:PATH = $savedPath }
  $loggedD = if (Test-Path $logD) { Get-Content -Raw $logD } else { '' }
  if (($loggedD -notmatch 'bash') -and (Test-Path (Join-Path $dirD 'wgm/SKILL.md'))) { Ok 'D -NoWsl forces a native install (no delegation)' }
  else { Bad 'D -NoWsl should bypass delegation and install natively' }
}
finally {
  $env:WSL_FAKE_LOG = $null
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "ps install tests: $script:pass passed, $script:fail failed"
if ($script:fail -eq 0) { Write-Host 'ps-install: GREEN'; exit 0 } else { Write-Error 'ps-install: RED'; exit 1 }
