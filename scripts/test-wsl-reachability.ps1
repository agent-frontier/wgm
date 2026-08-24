#!/usr/bin/env pwsh
#
# wgm/test-wsl-reachability.ps1 — Windows-origin reachability probe for a service published in WSL.
#
# This script is the *consumer* half of the WSL <-> Windows boundary check driven by
# scripts/test-wsl-windows-boundary.sh. It must run as a real Windows process: a Linux-side curl
# against the same URL proves nothing about that boundary, because it never leaves the guest
# ([learn] issue agent-frontier/wgm#101 — a service published on WSL loopback was unreachable from
# Windows while the same service published on all interfaces was reachable at the WSL IPv4 address).
#
# It fetches the URL, optionally fetches generated client assets, and optionally opens a WebSocket,
# then reports every observation on a stable, greppable line format. It writes nothing outside its
# own stdout, installs nothing, and needs no third-party module: HTTP uses HttpWebRequest and the
# WebSocket leg uses System.Net.WebSockets.ClientWebSocket when that type exists (Windows PowerShell
# 5.1 and PowerShell 7+ both ship it). When the type is missing the WebSocket check reports
# `outcome=unsupported` instead of pretending it passed.
#
# Output contract (one observation per line, consumed by the orchestrator):
#   origin-platform=<Win32NT|Unix|...>      the OS this probe actually ran on
#   origin-host=<hostname>
#   result endpoint=<url> kind=<http|websocket> status=<code|none> outcome=<ok|fail|unsupported> detail=<text>
#   probe-exit=<code>
#
# Exit 0 = every required check passed. Exit 1 = a required check failed. Exit 2 = bad input.

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Url,
  [string[]]$AssetPath = @(),
  [string]$WebSocketUrl = '',
  [int]$TimeoutSec = 5,
  [switch]$RequireWebSocket
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failed = 0

# Every observation goes straight to the console stream, never the PowerShell pipeline: a function
# that "writes" to the pipeline would have its text captured by its own caller as a return value,
# which silently swallowed both the report and the pass/fail boolean.
function Write-Line {
  param([string]$Text)
  [Console]::Out.WriteLine($Text)
}

function Write-Result {
  param([string]$Endpoint, [string]$Kind, [string]$Status, [string]$Outcome, [string]$Detail)
  Write-Line ("result endpoint={0} kind={1} status={2} outcome={3} detail={4}" -f $Endpoint, $Kind, $Status, $Outcome, $Detail)
}

function Exit-Probe {
  param([int]$Code)
  Write-Line ("probe-exit={0}" -f $Code)
  exit $Code
}

# ---- origin ---------------------------------------------------------------------------------
# Printed FIRST and unconditionally: the orchestrator refuses to count this run as field evidence
# unless it sees a Windows platform here, so a same-side (Linux) invocation can never be relabeled.
$platform = [string][System.Environment]::OSVersion.Platform
$hostName = try { [System.Net.Dns]::GetHostName() } catch { 'unknown' }
Write-Line ("origin-platform={0}" -f $platform)
Write-Line ("origin-host={0}" -f $hostName)

# ---- input validation -----------------------------------------------------------------------
if ($TimeoutSec -lt 1 -or $TimeoutSec -gt 120) {
  Write-Line "probe-error=invalid-timeout detail=TimeoutSec must be 1..120"
  Exit-Probe 2
}

$uri = $null
if (-not [uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
  Write-Line ("probe-error=invalid-url detail=not-an-absolute-uri:{0}" -f $Url)
  Exit-Probe 2
}
if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') {
  Write-Line ("probe-error=invalid-url detail=unsupported-scheme:{0}" -f $uri.Scheme)
  Exit-Probe 2
}
if ($uri.Port -le 0) {
  Write-Line ("probe-error=invalid-url detail=missing-port:{0}" -f $Url)
  Exit-Probe 2
}

$wsUri = $null
if ($WebSocketUrl -ne '') {
  if (-not [uri]::TryCreate($WebSocketUrl, [System.UriKind]::Absolute, [ref]$wsUri)) {
    Write-Line ("probe-error=invalid-url detail=not-an-absolute-uri:{0}" -f $WebSocketUrl)
    Exit-Probe 2
  }
  if ($wsUri.Scheme -ne 'ws' -and $wsUri.Scheme -ne 'wss') {
    Write-Line ("probe-error=invalid-url detail=unsupported-websocket-scheme:{0}" -f $wsUri.Scheme)
    Exit-Probe 2
  }
}

# ---- HTTP legs ------------------------------------------------------------------------------
function Invoke-HttpProbe {
  param([string]$Target)

  try {
    $req = [System.Net.HttpWebRequest]::Create($Target)
    $req.Method = 'GET'
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.AllowAutoRedirect = $false
    $req.UserAgent = 'wgm-wsl-reachability-probe'
    $resp = $req.GetResponse()
    try {
      $code = [int]$resp.StatusCode
      $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
      try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
      $len = $body.Length
      if ($code -ge 200 -and $code -lt 300) {
        Write-Result $Target 'http' $code 'ok' ("bytes={0}" -f $len)
        return $true
      }
      Write-Result $Target 'http' $code 'fail' ("unexpected-status bytes={0}" -f $len)
      return $false
    } finally {
      $resp.Dispose()
    }
  } catch [System.Net.WebException] {
    $status = 'none'
    $wex = $_.Exception
    if ($null -ne $wex.Response) { $status = [int]$wex.Response.StatusCode }
    $reason = ($wex.Message -replace '\s+', ' ')
    Write-Result $Target 'http' $status 'fail' ("webexception:{0}" -f $reason)
    return $false
  } catch {
    $reason = ($_.Exception.Message -replace '\s+', ' ')
    Write-Result $Target 'http' 'none' 'fail' ("exception:{0}" -f $reason)
    return $false
  }
}

if (-not (Invoke-HttpProbe -Target $uri.AbsoluteUri)) { $script:failed = 1 }

foreach ($asset in $AssetPath) {
  if ([string]::IsNullOrWhiteSpace($asset)) { continue }
  $assetUri = $null
  if (-not [uri]::TryCreate($uri, $asset, [ref]$assetUri)) {
    Write-Result $asset 'http' 'none' 'fail' 'asset-path-does-not-resolve'
    $script:failed = 1
    continue
  }
  if (-not (Invoke-HttpProbe -Target $assetUri.AbsoluteUri)) { $script:failed = 1 }
}

# ---- WebSocket leg --------------------------------------------------------------------------
if ($null -ne $wsUri) {
  $wsTarget = $wsUri.AbsoluteUri
  $clientType = 'System.Net.WebSockets.ClientWebSocket' -as [type]
  if ($null -eq $clientType) {
    Write-Result $wsTarget 'websocket' 'none' 'unsupported' 'ClientWebSocket-type-unavailable-on-this-host'
    if ($RequireWebSocket) { $script:failed = 1 }
  } else {
    $ws = $null
    try {
      $ws = New-Object System.Net.WebSockets.ClientWebSocket
      $cts = New-Object System.Threading.CancellationTokenSource ($TimeoutSec * 1000)
      $ws.ConnectAsync($wsUri, $cts.Token).GetAwaiter().GetResult() | Out-Null

      $payload = 'wgm-probe'
      $sendBuf = New-Object 'System.ArraySegment[byte]' (, [System.Text.Encoding]::UTF8.GetBytes($payload))
      $ws.SendAsync($sendBuf, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult() | Out-Null

      $recvBytes = New-Object byte[] 1024
      $recvBuf = New-Object 'System.ArraySegment[byte]' (, $recvBytes)
      $res = $ws.ReceiveAsync($recvBuf, $cts.Token).GetAwaiter().GetResult()
      $echo = [System.Text.Encoding]::UTF8.GetString($recvBytes, 0, $res.Count)

      if ($echo -eq $payload) {
        Write-Result $wsTarget 'websocket' '101' 'ok' ("echo={0}" -f $echo)
      } else {
        Write-Result $wsTarget 'websocket' '101' 'fail' ("unexpected-echo={0}" -f $echo)
        $script:failed = 1
      }
    } catch {
      $reason = ($_.Exception.Message -replace '\s+', ' ')
      Write-Result $wsTarget 'websocket' 'none' 'fail' ("exception:{0}" -f $reason)
      $script:failed = 1
    } finally {
      if ($null -ne $ws) { try { $ws.Dispose() } catch { } }
    }
  }
}

Exit-Probe $script:failed
