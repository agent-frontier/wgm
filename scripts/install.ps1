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
  Install into <Dir>\wgm explicitly (overrides -User/-Project/-Client). Skill only: a bare path
  names no host, so no role-agent scan path is guessed.

.PARAMETER Method
  copy | symlink (default: copy). symlink uses a directory junction; falls back to copy if it fails.

.PARAMETER DryRun
  Print what would happen; change nothing.

.PARAMETER Uninstall
  Remove the wgm skill from the resolved targets.

.PARAMETER Force
  Overwrite/replace an existing install.

.PARAMETER NoCompanions
  Do NOT install the teach-me / quiz-me / rugged companion skills alongside wgm.

.PARAMETER NoAgents
  Do NOT install the role-agent adapters. wgm's twelve role subagents are authored once in the
  Copilot custom-agent format and derived per host by scripts/sync-agent-adapters.sh
  (compatibility\agent-adapters.json). When a host client is selected they are installed where that
  host actually scans: copilot user -> ~\.copilot\agents, project -> .github\agents; claude user ->
  ~\.claude\agents, project -> .claude\agents. The generic `.agents` client gets none, because the
  Agent Skills standard defines skills, not subagents. Only files recorded in a per-directory
  receipt (.wgm-adapters) are ever refreshed or removed.

.PARAMETER Ref
  Ref to self-fetch when run piped via `irm … | iex`: a branch/tag/sha, or "latest" for the newest
  published release (default: main). A tag (vX.Y[.Z]) or "latest" installs the matching GitHub
  release tarball; any other ref uses the codeload source archive.

.PARAMETER NoWsl
  Do not delegate to WSL even if a distro is detected; perform a native-Windows install.

.PARAMETER WslDistro
  When delegating to WSL, use this distro (default: your default WSL distro).

.NOTES
  WSL bridge: on Windows with a WSL distro present, a user-scope install is delegated to the bash
  installer inside WSL (the "linux-y way"), which installs into the WSL home AND mirrors into your
  Windows home — so both sides are covered no matter which installer you launch. Use -NoWsl to force
  a native-Windows install.
  Self-fetch: when run via `irm … | iex` (no local checkout) the script downloads the repo itself.
  Override the source with env vars: WGM_REPO (default agent-frontier/wgm), WGM_REF (default main;
  same as -Ref; a tag or "latest" pulls the release tarball), WGM_TARBALL_URL (explicit .zip/.tar.gz
  URL; advanced/offline, e.g. file://…).

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
  [string]$Ref,
  [switch]$NoWsl,
  [switch]$NoCompanions,
  [switch]$NoAgents,
  [string]$WslDistro
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

# ----- WSL delegation (Windows host with a WSL distro) ----------------------
# On Windows, if WSL is present, hand a user-scope install to the bash installer inside WSL: it
# installs into the WSL home AND mirrors into the Windows home, so both sides end up covered.
function Test-WslAvailable {
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
  try {
    $raw = (& wsl.exe -l -q 2>$null) -join "`n"
    $raw = $raw -replace "`0", ''                       # wsl -l -q can emit UTF-16 with NULs
    $distros = @($raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    return ($distros.Count -gt 0)
  }
  catch { return $false }
}

function Invoke-WslDelegation {
  # Returns $true if the install was handled inside WSL (caller should exit), else $false.
  $bashArgs = @()
  if ($scope -eq 'project') { $bashArgs += '--project' } else { $bashArgs += '--user' }
  $bashArgs += @('--client', $Client, '--method', $Method, '--ref', $ref)
  if ($DryRun) { $bashArgs += '--dry-run' }
  if ($Uninstall) { $bashArgs += '--uninstall' }
  if ($Force) { $bashArgs += '--force' }
  if ($NoCompanions) { $bashArgs += '--no-companions' }
  if ($NoAgents) { $bashArgs += '--no-agents' }

  $distroArgs = @()
  if ($WslDistro) { $distroArgs = @('-d', $WslDistro) }

  Write-Host "  WSL detected - delegating to the bash installer inside WSL (use -NoWsl for a native-Windows install)."

  $shWin = if ($PSCommandPath) { Join-Path (Split-Path -Parent $PSCommandPath) 'install.sh' } else { $null }
  try {
    if ($shWin -and (Test-Path $shWin)) {
      $shWsl = ((& wsl.exe @distroArgs wslpath -u "$shWin") -join '') -replace "`0", ''
      & wsl.exe @distroArgs bash "$($shWsl.Trim())" @bashArgs
    }
    else {
      $rawUrl = "https://raw.githubusercontent.com/$repo/$ref/scripts/install.sh"
      $joined = ($bashArgs | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
      $cmd = "curl -fsSL '$rawUrl' | WGM_REPO='$repo' WGM_REF='$ref' bash -s -- $joined"
      & wsl.exe @distroArgs bash -lc $cmd
    }
  }
  catch {
    Write-Warning "  WSL delegation failed: $($_.Exception.Message). Falling back to a native-Windows install."
    return $false
  }
  if ($LASTEXITCODE -eq 0) { return $true }
  Write-Warning "  WSL delegation exited $LASTEXITCODE. Falling back to a native-Windows install."
  return $false
}

if (-not $NoWsl -and -not $Dir -and $scope -eq 'user' -and (Test-WslAvailable)) {
  if (Invoke-WslDelegation) { exit 0 }
}

function Resolve-WgmSourceUrl {
  # Primary archive URL for $repo/$ref. WGM_TARBALL_URL always wins; a *released* ref — the literal
  # "latest" or a vX.Y[.Z] tag — uses the published release .tar.gz asset so the validated tarball is
  # installed; any other ref (branch/sha, incl. the default "main") uses the codeload source .zip.
  if ($tarballUrl) { return $tarballUrl }
  if ($ref -eq 'latest') { return "https://github.com/$repo/releases/latest/download/wgm.tar.gz" }
  if ($ref -match '^v[0-9]') { return "https://github.com/$repo/releases/download/$ref/wgm-$ref.tar.gz" }
  return "https://codeload.github.com/$repo/zip/$ref"
}

function Expand-WgmArchive {
  # Fetch $Url into $Dest and return the extracted skill root (the dir with SKILL.md), or $null on a
  # miss — handling both a codeload <repo>-<ref>/ wrapper and a flat release tarball.
  param([string]$Url, [string]$Dest)
  try {
    $isTar = $Url -match '\.tar\.gz$|\.tgz$'
    $archive = Join-Path $Dest ($(if ($isTar) { 'wgm.tar.gz' } else { 'wgm.zip' }))
    if ($Url -like 'file://*' -or (Test-Path -LiteralPath $Url -ErrorAction SilentlyContinue)) {
      Copy-Item -LiteralPath ($Url -replace '^file://', '') -Destination $archive -Force
    }
    else {
      Invoke-WebRequest -Uri $Url -OutFile $archive -UseBasicParsing
    }
    if ($isTar) {
      if (-not (Get-Command tar -ErrorAction SilentlyContinue)) { return $null }
      tar -xzf $archive -C $Dest
    }
    else {
      Expand-Archive -Path $archive -DestinationPath $Dest -Force
    }
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
  }
  catch {
    Write-Warning "  archive fetch failed: $($_.Exception.Message)"
    return $null
  }
  $inner = @(Get-ChildItem -LiteralPath $Dest -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') }) | Select-Object -First 1
  if ($inner) { return $inner.FullName }
  if (Test-Path (Join-Path $Dest 'SKILL.md')) { return $Dest }
  return $null
}

function Get-WgmSource {
  param([string]$Dest)
  Write-Host "  fetching: $repo@$ref"
  # Candidate URLs, tried in order: a tag prefers the release asset, with the codeload source archive
  # as a fallback (e.g. a tag pushed before its release finished publishing).
  $urls = @(Resolve-WgmSourceUrl)
  if ($ref -ne 'latest') {
    $cl = "https://codeload.github.com/$repo/zip/$ref"
    if ($urls[0] -ne $cl) { $urls += $cl }
  }
  $i = 0
  foreach ($u in $urls) {
    $sub = Join-Path $Dest ("try$i"); $i++
    New-Item -ItemType Directory -Force -Path $sub | Out-Null
    Write-Host "  trying: $u"
    $root = Expand-WgmArchive -Url $u -Dest $sub
    if ($root) { return $root }
    Remove-Item -Recurse -Force $sub -ErrorAction SilentlyContinue
  }
  if (($ref -ne 'latest') -and (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  archive fetch unavailable - trying git clone"
    $clone = Join-Path $Dest 'clone'
    & git clone --depth 1 --branch $ref "https://github.com/$repo" $clone 2>$null
    if (Test-Path (Join-Path $clone 'SKILL.md')) { return $clone }
  }
  if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest -ErrorAction SilentlyContinue }
  $hint = if ($ref -eq 'latest') { ' (no published release yet? use WGM_REF=main for bleeding edge.)' } else { '' }
  Write-Error "Failed to fetch wgm ($repo@$ref). Tried $($urls -join ', ').$hint Install from a clone: git clone https://github.com/$repo"
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
    Write-Host "  would fetch: $(Resolve-WgmSourceUrl)"
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
# ----- compute role-adapter target dirs -------------------------------------
# A role adapter only makes sense where a host actually scans for one. `agents` (the Agent Skills
# standard) defines skills, not subagents, and -Dir names a bare path rather than a host, so neither
# gets an adapter - they get the portable skill and wgm's explicit inline fallback instead.
$agentTargets = [System.Collections.Generic.List[object]]::new()
$agentNotes = [System.Collections.Generic.List[string]]::new()

function Get-AdapterDir {
  param([string]$ClientId, [string]$Base, [string]$Scope)
  switch ("$ClientId/$Scope") {
    'copilot/user' { return (Join-Path $Base '.copilot' 'agents') }
    'copilot/project' { return (Join-Path $Base '.github' 'agents') }
    'claude/user' { return (Join-Path $Base '.claude' 'agents') }
    'claude/project' { return (Join-Path $Base '.claude' 'agents') }
    default { return $null }
  }
}

if (-not $NoAgents) {
  if ($Dir) {
    $agentNotes.Add("-Dir installs the skill only: a bare path names no host, so no agent scan path can be guessed. Re-run with -User or -Project and -Client copilot|claude|all to install the role adapters.")
  }
  else {
    $agentBase = if ($scope -eq 'user') { $homeDir } else { (Get-Location).Path }
    foreach ($c in $clients) {
      $d = Get-AdapterDir -ClientId $c -Base $agentBase -Scope $scope
      if ($d) { $agentTargets.Add([pscustomobject]@{ Host = $c; Dir = $d }) }
      elseif ($c -eq 'agents') {
        $agentNotes.Add("the .agents client gets no role adapters: the Agent Skills standard defines skills, not subagents. wgm falls back to scripts/audit.sh and inline sequential review passes there.")
      }
    }
  }
}

# A skills target is not the only reason to run: -Project -Client copilot resolves no skills
# directory (Copilot has none at project level) but still has real work to do in .github\agents.
if ($targets.Count -eq 0 -and $agentTargets.Count -eq 0) { Write-Error 'No install targets resolved.'; exit 1 }

# ----- helpers --------------------------------------------------------------
function Copy-Tree {
  param([string]$Src, [string]$Dst)
  New-Item -ItemType Directory -Force -Path $Dst | Out-Null
  Copy-Item -Path (Join-Path $Src '*') -Destination $Dst -Recurse -Force
  $git = Join-Path $Dst '.git'
  if (Test-Path $git) { Remove-Item -Recurse -Force $git }
}

function Test-WgmInstall {
  # True if $Path already holds a wgm skill (its SKILL.md frontmatter says name: wgm).
  param([string]$Path)
  $skill = Join-Path $Path 'SKILL.md'
  if (-not (Test-Path $skill)) { return $false }
  return ((Get-Content -Raw $skill) -match '(?m)^\s*name:\s*wgm\s*$')
}

function Install-One {
  param([string]$Target)
  if (Test-Path $Target) {
    if ($Force) {
      Write-Host "  replacing existing: $Target"
      if (-not $DryRun) { Remove-Item -Recurse -Force $Target }
    }
    elseif (Test-WgmInstall $Target) {
      Write-Host "  updating existing wgm install: $Target"
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
  if ($Target -notmatch '[\\/]skills[\\/](wgm|teach-me|quiz-me|rugged)$') {
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

# ----- role-agent adapters --------------------------------------------------
# Each host scans a flat directory of agent files that it does NOT own exclusively: a user's own
# agents live there too. So wgm never treats the directory as its own - it installs individual files
# and records exactly which ones it wrote in a per-directory receipt, and only those are ever
# refreshed or removed. Nothing else in the directory is read, moved, or deleted.
$adapterReceipt = '.wgm-adapters'

function Get-AdapterSourceDir {
  param([string]$HostId)
  switch ($HostId) {
    'copilot' { return (Join-Path (Join-Path $srcDir '.github') 'agents') }
    'claude' { return (Join-Path (Join-Path (Join-Path $srcDir 'adapters') 'claude') 'agents') }
    default { return $null }
  }
}

function Get-AdapterFilter {
  param([string]$HostId)
  if ($HostId -eq 'copilot') { return '*.agent.md' } else { return '*.md' }
}

function Get-AgentName {
  # The `name:` frontmatter value of an agent file (leading --- block only), or ''.
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  $inFm = $false
  foreach ($line in (Get-Content -LiteralPath $Path)) {
    if (-not $inFm) { if ($line -eq '---') { $inFm = $true; continue } else { return '' } }
    if ($line -eq '---') { return '' }
    if ($line -match '^name:\s*(.*?)\s*$') { return $Matches[1] }
  }
  return ''
}

function Install-Agents {
  param([string]$HostId, [string]$Dir)
  $src = Get-AdapterSourceDir -HostId $HostId
  if (-not $src -or -not (Test-Path $src)) {
    Write-Host "  no $HostId role adapters in this source, skipping: $Dir"
    return
  }
  # wgm's own checkout already IS the Copilot project agent dir; copying it onto itself is a no-op
  # at best and a self-inflicted delete at worst.
  $srcFull = (Resolve-Path $src).Path
  $dstFull = if (Test-Path $Dir) { (Resolve-Path $Dir).Path } else { $Dir }
  if ($srcFull -eq $dstFull) {
    Write-Host "  already the canonical source, skipping: $Dir"
    return
  }
  Write-Host "  role agents ($HostId): $Dir"
  if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
  # A prior receipt is wgm's own record of what it installed here last time. It is what lets a
  # re-run refresh a file wgm owns even after the file was edited beyond recognition, without
  # widening the claim to anything wgm never wrote.
  $receiptPath = Join-Path $Dir $adapterReceipt
  $prior = @()
  if (Test-Path $receiptPath) {
    $prior = @(Get-Content -LiteralPath $receiptPath | Where-Object { $_ -and -not $_.StartsWith('#') })
  }
  $written = [System.Collections.Generic.List[string]]::new()
  $wrote = 0
  foreach ($file in (Get-ChildItem -LiteralPath $src -Filter (Get-AdapterFilter -HostId $HostId) -File | Sort-Object Name)) {
    $dest = Join-Path $Dir $file.Name
    if ((Test-Path $dest) -and -not $Force) {
      if (($prior -notcontains $file.Name) -and ((Get-AgentName -Path $dest) -ne (Get-AgentName -Path $file.FullName))) {
        Write-Host "    exists and is not wgm's - skipping (use -Force to replace): $dest"
        continue
      }
    }
    $written.Add($file.Name)
    if ($DryRun) { Write-Host "    would install: $dest"; continue }
    Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
    $wrote++
  }
  if ($DryRun) { return }
  # The receipt is what makes uninstall safe: it is the only list of files wgm claims to own here.
  $lines = @("# wgm role-agent adapters - $HostId. Removing this file makes -Uninstall skip them.") + $written
  Set-Content -LiteralPath $receiptPath -Value $lines
  Write-Host "    installed $wrote file(s)"
}

function Uninstall-Agents {
  param([string]$HostId, [string]$Dir)
  if ($Dir -notmatch '[\\/]agents$') {
    Write-Warning "  refusing to touch unexpected agent dir: $Dir"
    return
  }
  $receiptPath = Join-Path $Dir $adapterReceipt
  if (-not (Test-Path $receiptPath)) {
    Write-Host "  no wgm adapter receipt, leaving untouched: $Dir"
    return
  }
  $removed = 0
  foreach ($base in (Get-Content -LiteralPath $receiptPath)) {
    if (-not $base -or $base.StartsWith('#') -or $base -match '[\\/]') { continue }
    $dest = Join-Path $Dir $base
    if (-not (Test-Path $dest)) { continue }
    if ($DryRun) { Write-Host "    would remove: $dest"; continue }
    Remove-Item -LiteralPath $dest -Force
    $removed++
  }
  if ($DryRun) { Write-Host "  would remove the $HostId adapter receipt: $receiptPath"; return }
  Remove-Item -LiteralPath $receiptPath -Force
  Write-Host "  removed $removed $HostId adapter file(s) from: $Dir"
}

# Companion skills ship beside wgm as their own sibling skill dirs, because a skills client
# discovers one skill per directory: companions\teach-me -> <skills-dir>\teach-me.
$companions = @('teach-me', 'quiz-me', 'rugged')

function Get-CompanionTargets {
  param([string]$WgmTarget)
  $parent = Split-Path -Parent $WgmTarget
  return $companions | ForEach-Object { Join-Path $parent $_ }
}

function Test-CompanionInstall {
  param([string]$Path, [string]$Name)
  $skill = Join-Path $Path 'SKILL.md'
  if (-not (Test-Path $skill)) { return $false }
  return ((Get-Content -Raw $skill) -match "(?m)^\s*name:\s*$Name\s*$")
}

function Install-Companions {
  param([string]$WgmTarget)
  if ($NoCompanions) { return }
  $parent = Split-Path -Parent $WgmTarget
  foreach ($name in $companions) {
    $src = Join-Path (Join-Path $srcDir 'companions') $name
    $target = Join-Path $parent $name
    # An older wgm tarball has no companions dir; that is a skip, never an install failure.
    if (-not (Test-Path $src)) { Write-Host "  companion not in this source, skipping: $name"; continue }
    if (Test-Path $target) {
      if ($Force) {
        Write-Host "  replacing existing: $target"
        if (-not $DryRun) { Remove-Item -Recurse -Force $target }
      }
      elseif (Test-CompanionInstall -Path $target -Name $name) {
        Write-Host "  updating existing $name install: $target"
        if (-not $DryRun) { Remove-Item -Recurse -Force $target }
      }
      else {
        Write-Host "  exists - skipping (use -Force to replace): $target"
        continue
      }
    }
    if ($DryRun) { Write-Host "  would copy: $src -> $target"; continue }
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Copy-Tree -Src $src -Dst $target
    Write-Host "  installed: $target"
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
  foreach ($t in $targets) {
    Uninstall-One -Target $t
    foreach ($ct in (Get-CompanionTargets -WgmTarget $t)) { Uninstall-One -Target $ct }
  }
  foreach ($a in $agentTargets) { Uninstall-Agents -HostId $a.Host -Dir $a.Dir }
}
else {
  Write-Host "Installing wgm to:"
  foreach ($t in $targets) { Install-One -Target $t; Install-Companions -WgmTarget $t }
  foreach ($a in $agentTargets) { Install-Agents -HostId $a.Host -Dir $a.Dir }
}
foreach ($n in $agentNotes) { Write-Host "  note: $n" }

Write-Host ""
Write-Host "Done. Targets:"
foreach ($t in $targets) {
  Write-Host "  - $t"
  if (-not $NoCompanions) {
    foreach ($ct in (Get-CompanionTargets -WgmTarget $t)) { Write-Host "  - $ct  (companion)" }
  }
}
foreach ($a in $agentTargets) { Write-Host "  - $($a.Dir)  ($($a.Host) role agents)" }
Write-Host ""
Write-Host "Verify your agent can see it (e.g. /skills), then invoke /wgm."
if (-not $NoCompanions) {
  Write-Host "Companions: /teach-me to learn a repo, /quiz-me to be tested on it, /rugged to stress-test a design."
}
if ($NoAgents) {
  Write-Host "Role agents: skipped (-NoAgents). wgm runs the review passes inline and sequentially instead."
}
elseif ($agentTargets.Count -eq 0) {
  Write-Host "Role agents: none installed - no host with a subagent format was selected. wgm falls back to scripts/audit.sh and inline sequential review passes."
}
}
finally {
  if ($tmpFetch -and (Test-Path $tmpFetch)) { Remove-Item -Recurse -Force $tmpFetch -ErrorAction SilentlyContinue }
}
