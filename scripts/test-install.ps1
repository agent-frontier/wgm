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
#   E  bootstrap source-URL resolver: latest/tag -> release asset, a branch -> codeload (dry-run).
#   F  companion skills install as siblings with matching names, uninstall cleanly, and honor
#      -NoCompanions.
#   G  role-agent adapters land in ~/.copilot/agents and ~/.claude/agents, refresh only what wgm
#      recorded as its own, uninstall by receipt, and honor -NoAgents.
#   H  -Dir installs the skill alone: a bare path names no host, so no agent dir is guessed.
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

  # ---- E: bootstrap source-URL resolver picks release assets for tags/latest ----
  # A copied install.ps1 (no SKILL.md sibling) forces bootstrap mode; -DryRun echoes the URL it would
  # fetch without any network, so we can assert the resolver without a live release.
  $bootE = Join-Path $work 'e'
  New-Item -ItemType Directory -Force -Path $bootE | Out-Null
  Copy-Item $installPs (Join-Path $bootE 'install.ps1')
  $bootPs = Join-Path $bootE 'install.ps1'
  $env:WGM_REPO = 'acme/wgm'
  try {
    $env:WGM_REF = 'latest'
    $eLatest = (& pwsh -NoProfile -File $bootPs -NoWsl -Dir (Join-Path $work 'eL') -Client agents -DryRun 2>&1 | Out-String)
    $env:WGM_REF = 'v1.2.3'
    $eTag = (& pwsh -NoProfile -File $bootPs -NoWsl -Dir (Join-Path $work 'eT') -Client agents -DryRun 2>&1 | Out-String)
    $env:WGM_REF = 'main'
    $eMain = (& pwsh -NoProfile -File $bootPs -NoWsl -Dir (Join-Path $work 'eM') -Client agents -DryRun 2>&1 | Out-String)
  }
  finally { $env:WGM_REF = $null; $env:WGM_REPO = $null }
  if (($eLatest -match 'https://github\.com/acme/wgm/releases/latest/download/wgm\.tar\.gz') -and
      ($eTag -match 'https://github\.com/acme/wgm/releases/download/v1\.2\.3/wgm-v1\.2\.3\.tar\.gz') -and
      ($eMain -match 'https://codeload\.github\.com/acme/wgm/zip/main')) {
    Ok 'E source-URL resolver: release asset for latest/tag, codeload source for a branch'
  }
  else { Bad "E resolver picked the wrong URL (latest=$eLatest tag=$eTag main=$eMain)" }
  # ---- F: companion skills install as siblings, and -NoCompanions opts out ----
  $dirF = Join-Path $work 'f'
  New-Item -ItemType Directory -Force -Path $dirF | Out-Null
  & pwsh -NoProfile -File $installPs -NoWsl -Dir $dirF -Client agents -Force *> $null
  if ((Test-Path (Join-Path $dirF 'teach-me/SKILL.md')) -and (Test-Path (Join-Path $dirF 'quiz-me/SKILL.md')) -and (Test-Path (Join-Path $dirF 'rugged/SKILL.md'))) {
    Ok 'F1 companions install as sibling skill dirs next to wgm'
  }
  else { Bad 'F1 expected teach-me/, quiz-me/, and rugged/ beside wgm under the -Dir target' }

  $dirG = Join-Path $work 'g'
  New-Item -ItemType Directory -Force -Path $dirG | Out-Null
  & pwsh -NoProfile -File $installPs -NoWsl -Dir $dirG -Client agents -Force -NoCompanions *> $null
  if ((Test-Path (Join-Path $dirG 'wgm/SKILL.md')) -and
      -not (Test-Path (Join-Path $dirG 'teach-me')) -and
      -not (Test-Path (Join-Path $dirG 'quiz-me')) -and
      -not (Test-Path (Join-Path $dirG 'rugged'))) {
    Ok 'F2 -NoCompanions installs wgm without the companion skills'
  }
  else { Bad 'F2 -NoCompanions still installed companion skills' }

  # -Dir intentionally cannot be uninstalled because it may sit outside a skills/ path. Exercise
  # companion names and the uninstall allow-list through a sandboxed native user-scope install.
  $sandboxF = Join-Path $work 'homeF'
  New-Item -ItemType Directory -Force -Path $sandboxF | Out-Null
  $env:HOME = $sandboxF
  $env:USERPROFILE = $sandboxF
  try {
    & pwsh -NoProfile -File $installPs -NoWsl -User -Client agents -Force *> $null
    $skillsF = Join-Path $sandboxF '.agents/skills'
    $namesMatch =
      ((Get-Content -Raw (Join-Path $skillsF 'teach-me/SKILL.md')) -match '(?m)^name:\s*teach-me\s*$') -and
      ((Get-Content -Raw (Join-Path $skillsF 'quiz-me/SKILL.md')) -match '(?m)^name:\s*quiz-me\s*$') -and
      ((Get-Content -Raw (Join-Path $skillsF 'rugged/SKILL.md')) -match '(?m)^name:\s*rugged\s*$')
    & pwsh -NoProfile -File $installPs -NoWsl -User -Client agents -Uninstall *> $null
    $allRemoved =
      -not (Test-Path (Join-Path $skillsF 'wgm')) -and
      -not (Test-Path (Join-Path $skillsF 'teach-me')) -and
      -not (Test-Path (Join-Path $skillsF 'quiz-me')) -and
      -not (Test-Path (Join-Path $skillsF 'rugged'))
  }
  finally {
    $env:HOME = $savedHome
    $env:USERPROFILE = $savedUserProfile
  }
  if ($namesMatch -and $allRemoved) {
    Ok 'F3 user-scope companions have matching names and uninstall cleanly'
  }
  else { Bad 'F3 expected matching companion names and complete user-scope uninstall' }

  # ---- G: role-agent adapters land in the host dirs that are actually scanned ----
  # The canonical .github/agents tree used to be copied inside SKILLS_DIR/wgm, where no host looks.
  # These checks pin the real scan paths, the opt-out, and the receipt-scoped ownership rule.
  $sandboxG = Join-Path $work 'homeG'
  New-Item -ItemType Directory -Force -Path $sandboxG | Out-Null
  $env:HOME = $sandboxG
  $env:USERPROFILE = $sandboxG
  try {
    & pwsh -NoProfile -File $installPs -NoWsl -User -Client all *> $null
    $copilotG = Join-Path $sandboxG '.copilot/agents'
    $claudeG = Join-Path $sandboxG '.claude/agents'
    $g1 =
      (Test-Path (Join-Path $copilotG 'wgm-implementer.agent.md')) -and
      (Test-Path (Join-Path $claudeG 'wgm-implementer.md')) -and
      ((Get-Content -Raw (Join-Path $copilotG 'wgm-implementer.agent.md')) -match '(?m)^name:\s*WGM Implementer\s*$') -and
      ((Get-Content -Raw (Join-Path $claudeG 'wgm-implementer.md')) -match '(?m)^name:\s*wgm-implementer\s*$')
    if ($g1) { Ok 'G1 role adapters land in ~/.copilot/agents and ~/.claude/agents with host-correct names' }
    else { Bad 'G1 expected host-format role adapters in the user-scope agent dirs' }

    # A host agent directory is shared property: an unrelated agent, and even a foreign file that
    # happens to share a wgm role name, can predate wgm. Seed both BEFORE wgm installs here.
    $sandboxG2 = Join-Path $work 'homeG2'
    $copilotG2 = Join-Path $sandboxG2 '.copilot/agents'
    New-Item -ItemType Directory -Force -Path $copilotG2 | Out-Null
    Set-Content -Path (Join-Path $copilotG2 'my-team.agent.md') -Value "---`nname: My Own Agent`ndescription: not wgm`n---`nkeep me"
    Set-Content -Path (Join-Path $copilotG2 'wgm-validator.agent.md') -Value "---`nname: Someone Elses Validator`ndescription: not wgm`n---`nkeep me too"
    $env:HOME = $sandboxG2
    $env:USERPROFILE = $sandboxG2
    $outG = (& pwsh -NoProfile -File $installPs -NoWsl -User -Client copilot 2>&1 | Out-String)
    # Then tamper with a file wgm DOES own: the receipt is what makes it recoverable on a re-run.
    Set-Content -Path (Join-Path $copilotG2 'wgm-implementer.agent.md') -Value 'tampered'
    & pwsh -NoProfile -File $installPs -NoWsl -User -Client copilot *> $null
    $canonImpl = Get-Content -Raw (Join-Path $root '.github/agents/wgm-implementer.agent.md')
    $g2 =
      ((Get-Content -Raw (Join-Path $copilotG2 'wgm-implementer.agent.md')) -eq $canonImpl) -and
      ((Get-Content -Raw (Join-Path $copilotG2 'my-team.agent.md')) -match 'keep me') -and
      ((Get-Content -Raw (Join-Path $copilotG2 'wgm-validator.agent.md')) -match 'Someone Elses Validator') -and
      ($outG -match "exists and is not wgm's")
    if ($g2) { Ok 'G2 a re-run refreshes wgm-owned adapters and clobbers no one else' }
    else { Bad 'G2 re-run must refresh only the files wgm recorded as its own' }

    & pwsh -NoProfile -File $installPs -NoWsl -User -Client copilot -Uninstall *> $null
    $g3 =
      -not (Test-Path (Join-Path $copilotG2 'wgm-implementer.agent.md')) -and
      -not (Test-Path (Join-Path $copilotG2 '.wgm-adapters')) -and
      (Test-Path (Join-Path $copilotG2 'my-team.agent.md')) -and
      (Test-Path (Join-Path $copilotG2 'wgm-validator.agent.md'))
    if ($g3) { Ok 'G3 uninstall removes only the receipt-listed adapters' }
    else { Bad 'G3 uninstall removed files it had no receipt for, or missed its own' }

    $sandboxH = Join-Path $work 'homeH'
    New-Item -ItemType Directory -Force -Path $sandboxH | Out-Null
    $env:HOME = $sandboxH
    $env:USERPROFILE = $sandboxH
    & pwsh -NoProfile -File $installPs -NoWsl -User -Client all -NoAgents *> $null
    $g4 =
      (Test-Path (Join-Path $sandboxH '.copilot/skills/wgm/SKILL.md')) -and
      -not (Test-Path (Join-Path $sandboxH '.copilot/agents')) -and
      -not (Test-Path (Join-Path $sandboxH '.claude/agents'))
    if ($g4) { Ok 'G4 -NoAgents installs the portable skill and no adapters' }
    else { Bad 'G4 -NoAgents still produced adapter directories' }
  }
  finally {
    $env:HOME = $savedHome
    $env:USERPROFILE = $savedUserProfile
  }

  # ---- H: -Dir names no host, so it guesses no agent path -------------------
  $dirH = Join-Path $work 'h'
  New-Item -ItemType Directory -Force -Path $dirH | Out-Null
  $outH = (& pwsh -NoProfile -File $installPs -NoWsl -Dir $dirH -Client all 2>&1 | Out-String)
  if ((Test-Path (Join-Path $dirH 'wgm/SKILL.md')) -and
      -not (Test-Path (Join-Path $dirH 'agents')) -and
      ($outH -match '-Dir installs the skill only')) {
    Ok 'H -Dir installs the skill only and reports that no host agent path can be guessed'
  }
  else { Bad 'H -Dir should install the skill alone and explain the limit' }
}
finally {
  $env:WSL_FAKE_LOG = $null
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "ps install tests: $script:pass passed, $script:fail failed"
if ($script:fail -eq 0) { Write-Host 'ps-install: GREEN'; exit 0 } else { Write-Error 'ps-install: RED'; exit 1 }
