<#
.SYNOPSIS
  Runs a REA analysis while recording the network activity of the WHOLE REA
  process tree, then reports any connection to a host other than localhost,
  registry.npmjs.org or github.com as POSSIBLE EXFILTRATION.

  Windows adaptation of run-monitored.sh: Windows has no `ss`/`lsof`, so this
  uses Get-NetTCPConnection / Get-NetUDPEndpoint (no admin needed) plus a DNS
  client cache diff. Node resolves names through the Windows DNS Client
  service, so DNS queries do not appear under REA's PID; the cache diff is the
  way to see them. That diff is system-wide, so it also includes other apps.

.LIMITS
  Polling (default every 200 ms) can miss connections shorter than the
  interval. Connections in TIME_WAIT after a process exits lose their PID.
  For full capture use an admin trace (pktmon) or Wireshark in parallel.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\run-monitored.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File .\run-monitored.ps1 -Mode mcp
  powershell -NoProfile -ExecutionPolicy Bypass -File .\run-monitored.ps1 -Target targets\otra-app
#>
param(
  [ValidateSet('cli', 'mcp')][string]$Mode = 'cli',
  [string]$Target = 'targets\sample-js-app',
  [int]$IntervalMs = 200,
  [int]$TimeoutSec = 900
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$nodeVersion = (Get-Content -LiteralPath (Join-Path $Root '.nvmrc') -Raw).Trim()
$node = Join-Path $Root ".tools\node-v$nodeVersion-win-x64\node.exe"
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $Root "logs\run-$stamp-$Mode"
New-Item -ItemType Directory -Force $runDir | Out-Null

# --- Target must live under .\targets
$targetsRoot = (Resolve-Path (Join-Path $Root 'targets')).Path
$targetAbs = (Resolve-Path (Join-Path $Root $Target)).Path
if (-not $targetAbs.StartsWith($targetsRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw "The target must be under $targetsRoot"
}
$targetName = Split-Path $targetAbs -Leaf
$outDir = Join-Path $Root "projects\$targetName"
New-Item -ItemType Directory -Force $outDir | Out-Null

function Write-Step($m) { Write-Host "[run-monitored] $m" -ForegroundColor Cyan }

# --- 1. State before
Write-Step "snapshot before (outside the folder)"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\snapshot-outside.ps1') -Label "run-$stamp-before" | Out-Null
$snapBefore = Get-ChildItem (Join-Path $Root "logs\isolation\run-$stamp-before-*.json") | Select-Object -Last 1
$dnsBefore = @{}
Get-DnsClientCache -ErrorAction SilentlyContinue | ForEach-Object { $dnsBefore["$($_.Entry)|$($_.Data)"] = $true }
$realTemp = [Environment]::GetEnvironmentVariable('TEMP', 'User'); if (-not $realTemp) { $realTemp = $env:TEMP }
$tempBefore = @(Get-ChildItem -LiteralPath $realTemp -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'rea-*' -or $_.Name -like 'playwright*' -or $_.Name -like 'asar-*' } | ForEach-Object Name)

# --- 2. Start REA (always through the isolated launcher)
if ($Mode -eq 'cli') {
  $argLine = "`"$(Join-Path $Root 'scripts\rea-isolated.mjs')`" analyze-javascript-application `"$targetAbs`" --json"
  $stdoutFile = Join-Path $outDir "analysis-cli-$stamp.json"
} else {
  $argLine = "`"$(Join-Path $Root 'scripts\mcp-smoke.mjs')`" `"$targetAbs`""
  $stdoutFile = Join-Path $outDir "analysis-mcp-$stamp.json"
}
$stderrFile = Join-Path $runDir 'rea-stderr.log'
Write-Step "starting: node $argLine"
$started = Get-Date
$proc = Start-Process -FilePath $node -ArgumentList $argLine -WorkingDirectory $Root -NoNewWindow -PassThru `
  -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
$null = $proc.Handle  # keeps ExitCode readable in PowerShell 5.1

# --- 3. Monitor the process tree
$tree = @{ [int]$proc.Id = $true }
$procRows = New-Object System.Collections.Generic.List[object]
$connRows = New-Object System.Collections.Generic.List[object]
$seenProc = @{}; $seenConn = @{}
$deadline = $started.AddSeconds($TimeoutSec)

function Poll {
  $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine -ErrorAction SilentlyContinue)
  do {
    $added = $false
    foreach ($p in $all) {
      if (-not $tree.ContainsKey([int]$p.ProcessId) -and $tree.ContainsKey([int]$p.ParentProcessId)) {
        $tree[[int]$p.ProcessId] = $true; $added = $true
      }
    }
  } while ($added)
  foreach ($p in $all) {
    $id = [int]$p.ProcessId
    if ($tree.ContainsKey($id) -and -not $seenProc.ContainsKey($id)) {
      $seenProc[$id] = $true
      $cmd = [string]$p.CommandLine; if ($cmd.Length -gt 400) { $cmd = $cmd.Substring(0, 400) + '...' }
      $procRows.Add([pscustomobject]@{ time = (Get-Date).ToString('o'); pid = $id; ppid = [int]$p.ParentProcessId; name = $p.Name; command = $cmd })
    }
  }
  $tcp = @(Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $tree.ContainsKey([int]$_.OwningProcess) })
  foreach ($c in $tcp) {
    $key = "tcp|$($c.LocalAddress)|$($c.LocalPort)|$($c.RemoteAddress)|$($c.RemotePort)|$($c.State)|$($c.OwningProcess)"
    if (-not $seenConn.ContainsKey($key)) {
      $seenConn[$key] = $true
      $connRows.Add([pscustomobject]@{ time = (Get-Date).ToString('o'); proto = 'tcp'; pid = [int]$c.OwningProcess; local = "$($c.LocalAddress):$($c.LocalPort)"; remoteAddress = [string]$c.RemoteAddress; remotePort = [int]$c.RemotePort; state = [string]$c.State })
    }
  }
  $udp = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $tree.ContainsKey([int]$_.OwningProcess) })
  foreach ($u in $udp) {
    $key = "udp|$($u.LocalAddress)|$($u.LocalPort)|$($u.OwningProcess)"
    if (-not $seenConn.ContainsKey($key)) {
      $seenConn[$key] = $true
      $connRows.Add([pscustomobject]@{ time = (Get-Date).ToString('o'); proto = 'udp'; pid = [int]$u.OwningProcess; local = "$($u.LocalAddress):$($u.LocalPort)"; remoteAddress = ''; remotePort = 0; state = 'Endpoint' })
    }
  }
}

$polls = 0
while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
  Poll; $polls++
  Start-Sleep -Milliseconds $IntervalMs
}
Poll; $polls++
if (-not $proc.HasExited) { Write-Step "timeout: stopping REA"; Stop-Process -Id $proc.Id -Force }
$proc.WaitForExit()
$exitCode = $proc.ExitCode
$elapsed = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)

# --- 4. State after
Write-Step "snapshot after"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\snapshot-outside.ps1') -Label "run-$stamp-after" | Out-Null
$snapAfter = Get-ChildItem (Join-Path $Root "logs\isolation\run-$stamp-after-*.json") | Select-Object -Last 1
$dnsNew = @(Get-DnsClientCache -ErrorAction SilentlyContinue | Where-Object { -not $dnsBefore.ContainsKey("$($_.Entry)|$($_.Data)") } |
  Select-Object Entry, Data, @{ n = 'Type'; e = { $_.Type } }, @{ n = 'Status'; e = { $_.Status } } | Sort-Object Entry -Unique)
$tempAfter = @(Get-ChildItem -LiteralPath $realTemp -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'rea-*' -or $_.Name -like 'playwright*' -or $_.Name -like 'asar-*' } | ForEach-Object Name)
$tempNew = @($tempAfter | Where-Object { $tempBefore -notcontains $_ })

# --- 5. Classification
$allowedHosts = @('localhost', 'registry.npmjs.org', 'github.com')
$allowedIps = @{}
foreach ($h in @('registry.npmjs.org', 'github.com')) {
  try { Resolve-DnsName $h -ErrorAction Stop | Where-Object { $_.IPAddress } | ForEach-Object { $allowedIps[$_.IPAddress] = $h } } catch {}
}
function Test-Loopback($a) { return ($a -like '127.*' -or $a -eq '::1' -or $a -eq '::ffff:127.0.0.1') }
function Test-Unspecified($a) { return ($a -eq '0.0.0.0' -or $a -eq '::' -or $a -eq '') }

$classified = foreach ($c in $connRows) {
  $verdict = $null; $hostName = ''
  if ($c.proto -eq 'udp') {
    $la = ($c.local -replace ':\d+$', '')
    if (Test-Loopback $la) { $verdict = 'OK (UDP local)' } else { $verdict = 'Revisar (UDP endpoint not on loopback)' }
  } elseif ($c.state -eq 'Listen') {
    $la = ($c.local -replace ':\d+$', '')
    if (Test-Loopback $la) { $verdict = 'OK (local listener)' } else { $verdict = 'Revisar (listening on all interfaces)' }
  } elseif (Test-Loopback $c.remoteAddress) { $verdict = 'OK (localhost)'; $hostName = 'localhost' }
  elseif (Test-Unspecified $c.remoteAddress) { $verdict = 'OK (no remote)' }
  elseif ($allowedIps.ContainsKey($c.remoteAddress)) { $hostName = $allowedIps[$c.remoteAddress]; $verdict = "OK (allowed: $hostName)" }
  else {
    try { $hostName = (Resolve-DnsName $c.remoteAddress -Type PTR -ErrorAction Stop | Select-Object -First 1).NameHost } catch { $hostName = '?' }
    $verdict = 'POSSIBLE EXFILTRATION'
  }
  $c | Add-Member -NotePropertyName host -NotePropertyValue $hostName -PassThru | Add-Member -NotePropertyName verdict -NotePropertyValue $verdict -PassThru
}
$suspicious = @($classified | Where-Object { $_.verdict -like 'POSSIBLE*' -or $_.verdict -like 'Revisar*' })

$dnsRows = foreach ($d in $dnsNew) {
  $name = [string]$d.Entry
  $ok = $false
  foreach ($h in $allowedHosts) { if ($name -eq $h) { $ok = $true } }
  $verdict = 'not allowed (system-wide, not attributable)'; if ($ok) { $verdict = 'allowed' }
  [pscustomobject]@{ entry = $name; data = [string]$d.Data; status = [string]$d.Status; verdict = $verdict }
}
$invalidLookups = @($dnsRows | Where-Object { $_.entry -like '*example.invalid*' })

# --- 6. Isolation diff (outside the folder)
$iso = New-Object System.Collections.Generic.List[string]
foreach ($i in @(& (Join-Path $Root 'scripts\compare-snapshots.ps1') -Before $snapBefore.FullName -After $snapAfter.FullName)) { $iso.Add([string]$i) }
foreach ($t in $tempNew) { $iso.Add("new in real %TEMP%: $t") }

# --- 7. Write logs and report
$procRows | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $runDir 'processes.csv')
@($classified) | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $runDir 'connections.csv')
@($dnsRows) | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $runDir 'dns-new.csv')
$runtimeFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root '.rea-runtime') -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } |
  ForEach-Object { $_.FullName.Substring($Root.Length + 1) })

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# REA monitored run: $stamp ($Mode)")
$lines.Add('')
$lines.Add("- Target: ``$targetAbs``")
$lines.Add("- Output: ``$stdoutFile``")
$lines.Add("- Exit code: $exitCode; duration: ${elapsed}s; polls: $polls every ${IntervalMs}ms")
$lines.Add("- Processes in the REA tree: $($procRows.Count)")
$lines.Add("- Connections/endpoints observed: $($connRows.Count)")
$lines.Add('')
$lines.Add('## Network (REA process tree)')
if ($connRows.Count -eq 0) { $lines.Add('No TCP connection or UDP endpoint observed.') }
foreach ($c in $classified) { $lines.Add("- [$($c.verdict)] $($c.proto) pid=$($c.pid) $($c.local) -> $($c.remoteAddress):$($c.remotePort) $($c.state) $($c.host)") }
$lines.Add('')
$lines.Add('## New DNS cache entries (WHOLE system, not attributable)')
if (-not $dnsRows) { $lines.Add('None.') }
foreach ($d in $dnsRows) { $lines.Add("- [$($d.verdict)] $($d.entry) -> $($d.data) ($($d.status))") }
$lines.Add('')
$lines.Add("Lookups of the target's never-contacted host (*.example.invalid): $($invalidLookups.Count)")
$lines.Add('')
$lines.Add('## Isolation (outside the folder, before vs after)')
if ($iso.Count -eq 0) { $lines.Add('No changes.') } else { foreach ($i in $iso) { $lines.Add("- $i") } }
$lines.Add('')
$lines.Add('## Written by REA in .rea-runtime')
if ($runtimeFiles.Count -eq 0) { $lines.Add('(no files)') } else { foreach ($f in ($runtimeFiles | Select-Object -First 50)) { $lines.Add("- $f") } }
$lines.Add('')
$verdictLine = 'NO POSSIBLE EXFILTRATION: every connection of the REA tree was local or allowed.'
if ($suspicious.Count) { $verdictLine = "WARNING: $($suspicious.Count) connection(s) to review or POSSIBLE EXFILTRATION (see above)." }
$lines.Add("**Verdict:** $verdictLine")
$lines | Out-File -Encoding utf8 (Join-Path $runDir 'report.md')

Write-Host ''
$lines | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Step "logs in $runDir"
exit ([int]($suspicious.Count -gt 0))
