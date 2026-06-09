<#
.SYNOPSIS
  Install the wgm Agent Skill into a skills directory (user-level by default).

.DESCRIPTION
  Installs the skill folder as <skills-dir>\wgm so a skills-compatible agent (Claude, Copilot CLI,
  VS Code agent mode, or any .agents/skills client) can discover it. Defaults to a USER-level
  (global) install, so wgm is available across all your projects — not just the current one.

  Native Windows companion to scripts/install.sh (use install.sh on Linux, macOS, and WSL).

.PARAMETER User
  Install into your home dir (DEFAULT): ~\.agents\skills\wgm (+ detected clients).

.PARAMETER Project
  Install into the current project: .\.agents\skills\wgm (+ .\.claude).

.PARAMETER Client
  agents | claude | copilot | all | auto (default: auto). auto = agents + any client whose home dir
  exists (~\.claude, ~\.copilot). all = agents + claude + copilot.

.PARAMETER Dir
  Install into <Dir>\wgm explicitly (overrides -User/-Project/-Client).

.PARAMETER Method
  copy | symlink (default: copy). symlink uses a directory junction; falls back to copy if it fails.

.PARAMETER DryRun
  Print what would happen; change nothing.

.PARAMETER Uninstall
  Remove the wgm skill from the resolved targets.

.PARAMETER Force
  Overwrite/replace an existing install.

.PARAMETER Ref
  Git ref (branch/tag/sha) to self-fetch when run piped via `irm … | iex` (default: main).

.NOTES
  Self-fetch: when run via `irm … | iex` (no local checkout) the script downloads the repo itself.
  Override the source with env vars: WGM_REPO (default agent-frontier/wgm), WGM_REF (default main;
  same as -Ref), WGM_TARBALL_URL (explicit .zip/.tar.gz URL; advanced/offline, e.g. file://…).

.EXAMPLE
  pwsh scripts/install.ps1 -Client all

.EXAMPLE
  powershell -File scripts\install.ps1 -Project

.EXAMPLE
  pwsh scripts/install.ps1 -DryRun
#>
[CmdletBinding()]
param(
  [switch]$User,
  [switch]$Project,
  [ValidateSet('agents', 'claude', 'copilot', 'all', 'auto')]
  [string]$Client = 'auto',
  [string]$Dir,
  [ValidateSet('copy', 'symlink')]
  [string]$Method = 'copy',
  [switch]$DryRun,
  [switch]$Uninstall,
  [switch]$Force,
  [string]$Ref
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scope = if ($Project) { 'project' } else { 'user' }

$repo = if ($env:WGM_REPO) { $env:WGM_REPO } else { 'agent-frontier/wgm' }
$ref = if ($Ref) { $Ref } elseif ($env:WGM_REF) { $env:WGM_REF } else { 'main' }
$tarballUrl = $env:WGM_TARBALL_URL

# ----- resolve source (repo root = parent of this script's dir) -------------
# Clone mode: SKILL.md sits next to this script. When run via `irm … | iex` there is no script file
# ($PSCommandPath is empty), so SRC stays unresolved and we self-fetch into a temp dir ("bootstrap").
$srcDir = $null
if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
  $candidate = (Resolve-Path (Join-Path (Split-Path -Parent $PSCommandPath) '..')).Path
  if (Test-Path (Join-Path $candidate 'SKILL.md')) { $srcDir = $candidate }
}

function Get-WgmSource {
  param([string]$Dest)
  $url = if ($tarballUrl) { $tarballUrl } else { "https://codeload.github.com/$repo/zip/$ref" }
  Write-Host "  fetching: $repo@$ref"
  $ok = $false
  try {
    $isTar = $url -match '\.tar\.gz$|\.tgz$'
    $archive = Join-Path $Dest ($(if ($isTar) { 'wgm.tar.gz' } else { 'wgm.zip' }))
    if ($url -like 'file://*' -or (Test-Path -LiteralPath $url -ErrorAction SilentlyContinue)) {
      Copy-Item -LiteralPath ($url -replace '^file://', '') -Destination $archive -Force
    }
    else {
      Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
    }
    if ($isTar) {
      if (Get-Command tar -ErrorAction SilentlyContinue) { tar -xzf $archive -C $Dest; $ok = $true }
    }
    else {
      Expand-Archive -Path $archive -DestinationPath $Dest -Force; $ok = $true
    }
  }
  catch {
    Write-Warning "  archive fetch failed: $($_.Exception.Message)"
  }
  if ($ok) {
    # A GitHub codeload archive unpacks to a single <repo>-<ref>/ wrapper dir.
    $inner = Get-ChildItem -LiteralPath $Dest -Directory -ErrorAction SilentlyContinue |
      Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } | Select-Object -First 1
    if ($inner) { return $inner.FullName }
    if (Test-Path (Join-Path $Dest 'SKILL.md')) { return $Dest }
  }
  if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Host "  archive fetch unavailable - trying git clone"
    $clone = Join-Path $Dest 'clone'
    & git clone --depth 1 --branch $ref "https://github.com/$repo" $clone 2>$null
    if (Test-Path (Join-Path $clone 'SKILL.md')) { return $clone }
  }
  if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest -ErrorAction SilentlyContinue }
  Write-Error "Failed to fetch wgm ($repo@$ref). Tried $url. Install from a clone: git clone https://github.com/$repo"
  exit 1
}

# ----- resolve / fetch source ----------------------------------------------
$bootstrap = $false
$tmpFetch = $null
if (-not $srcDir -and -not $Uninstall) {
  $bootstrap = $true
  if ($Method -eq 'symlink') {
    Write-Warning "  -Method symlink ignored in bootstrap mode (no local checkout) - using copy."
    $Method = 'copy'
  }
  if ($DryRun) {
    $srcDir = "<fetched $repo@$ref>"   # preview only - no network in a dry run
  }
  else {
    $tmpFetch = Join-Path ([System.IO.Path]::GetTempPath()) ('wgm-install-' + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $tmpFetch | Out-Null
    $srcDir = Get-WgmSource -Dest $tmpFetch
  }
}

$homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($HOME) { $HOME } else { (Resolve-Path '~').Path }

# ----- resolve client list --------------------------------------------------
$clients = switch ($Client) {
  'agents' { @('agents') }
  'claude' { @('claude') }
  'copilot' { @('copilot') }
  'all' { @('agents', 'claude', 'copilot') }
  'auto' {
    $list = [System.Collections.Generic.List[string]]::new()
    $list.Add('agents')
    if (Test-Path (Join-Path $homeDir '.claude')) { $list.Add('claude') }
    if (Test-Path (Join-Path $homeDir '.copilot')) { $list.Add('copilot') }
    $list.ToArray()
  }
}

# ----- compute target dirs --------------------------------------------------
$targets = [System.Collections.Generic.List[string]]::new()
if ($Dir) {
  $targets.Add((Join-Path $Dir 'wgm'))
}
else {
  $base = if ($scope -eq 'user') { $homeDir } else { (Get-Location).Path }
  foreach ($c in $clients) {
    if ($scope -eq 'project' -and $c -eq 'copilot') {
      Write-Warning "Copilot CLI has no project-level skills dir; .agents/skills covers it - skipping copilot for -Project."
      continue
    }
    $targets.Add((Join-Path $base ".$c" 'skills' 'wgm'))
  }
}
if ($targets.Count -eq 0) { Write-Error 'No install targets resolved.'; exit 1 }

# ----- helpers --------------------------------------------------------------
function Copy-Tree {
  param([string]$Src, [string]$Dst)
  New-Item -ItemType Directory -Force -Path $Dst | Out-Null
  Copy-Item -Path (Join-Path $Src '*') -Destination $Dst -Recurse -Force
  $git = Join-Path $Dst '.git'
  if (Test-Path $git) { Remove-Item -Recurse -Force $git }
}

function Install-One {
  param([string]$Target)
  if (Test-Path $Target) {
    if ($Force) {
      Write-Host "  replacing existing: $Target"
      if (-not $DryRun) { Remove-Item -Recurse -Force $Target }
    }
    else {
      Write-Host "  exists - skipping (use -Force to replace): $Target"
      return
    }
  }
  if ($DryRun) {
    if ($Method -eq 'symlink') { Write-Host "  would link: $Target -> $srcDir" }
    else { Write-Host "  would copy: $srcDir -> $Target (excluding .git)" }
    return
  }
  $parent = Split-Path -Parent $Target
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  if ($Method -eq 'symlink') {
    try {
      New-Item -ItemType Junction -Path $Target -Value $srcDir | Out-Null
    }
    catch {
      Write-Warning "  junction failed ($($_.Exception.Message)); falling back to copy."
      Copy-Tree -Src $srcDir -Dst $Target
    }
  }
  else {
    Copy-Tree -Src $srcDir -Dst $Target
  }
  Write-Host "  installed: $Target"
}

function Uninstall-One {
  param([string]$Target)
  if ($Target -notmatch '[\\/]skills[\\/]wgm$') {
    Write-Warning "  refusing to remove unexpected path: $Target"
    return
  }
  if (Test-Path $Target) {
    if ($DryRun) { Write-Host "  would remove: $Target" }
    else { Remove-Item -Recurse -Force $Target; Write-Host "  removed: $Target" }
  }
  else {
    Write-Host "  not present: $Target"
  }
}

# ----- run ------------------------------------------------------------------
try {
Write-Host "wgm installer"
if ($srcDir) { Write-Host "  source : $srcDir" } else { Write-Host "  source : (none - uninstall)" }
if ($bootstrap) { Write-Host "  fetched: $repo@$ref" }
Write-Host "  scope  : $scope"
Write-Host "  client : $Client"
Write-Host "  method : $Method"
if ($DryRun) { Write-Host "  (dry run - no changes will be made)" }
Write-Host ""

if ($Uninstall) {
  Write-Host "Uninstalling wgm from:"
  foreach ($t in $targets) { Uninstall-One -Target $t }
}
else {
  Write-Host "Installing wgm to:"
  foreach ($t in $targets) { Install-One -Target $t }
}

Write-Host ""
Write-Host "Done. Targets:"
foreach ($t in $targets) { Write-Host "  - $t" }
Write-Host ""
Write-Host "Verify your agent can see it (e.g. /skills), then invoke /wgm."
}
finally {
  if ($tmpFetch -and (Test-Path $tmpFetch)) { Remove-Item -Recurse -Force $tmpFetch -ErrorAction SilentlyContinue }
}
