<#
.SYNOPSIS
  Rebuilds the isolated REA kit inside THIS folder and verifies every piece
  against the pins in kit\versions.json.

  - No admin rights, no global installs, no changes to the PATH registry,
    ~/.npmrc, ~/.claude.json or any other agent's configuration.
  - Downloads only from nodejs.org, registry.npmjs.org and (with -WithFrida)
    github.com/frida; each file is checked against a pinned SHA256 first.
  - Never runs npm lifecycle scripts (--ignore-scripts).
  - Takes a snapshot of the state OUTSIDE the folder before and after, and
    reports any difference.

.PARAMETER WithFrida
  Also installs frida's native binding from the pinned release tarball (the
  audited alternative to frida's install script). Needed only for Frida tools.
.PARAMETER VerifyOnly
  Downloads and installs nothing; only verifies what is present.
.PARAMETER Reinstall
  Deletes node_modules and runs "npm ci" again.
.PARAMETER SkipNetworkChecks
  Skips "npm audit signatures" and "npm audit" (both query registry.npmjs.org).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -WithFrida
  powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -VerifyOnly
#>
param(
  [switch]$WithFrida,
  [switch]$VerifyOnly,
  [switch]$Reinstall,
  [switch]$SkipNetworkChecks
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is very slow with the progress bar on PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = $PSScriptRoot
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

function Step($m) { Write-Host "[bootstrap] $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  OK   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  WARN $m" -ForegroundColor Yellow; $script:Warnings.Add($m) }
function Bad($m) { Write-Host "  FAIL $m" -ForegroundColor Red; $script:Failures.Add($m) }
function Sha256($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }

# Windows PowerShell 5.1 turns native stderr lines into errors, which would
# abort the script under ErrorActionPreference=Stop. Native tools run here and
# are judged by their exit code ($LASTEXITCODE) instead.
function Invoke-Native([scriptblock]$Block) {
  $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & $Block } finally { $ErrorActionPreference = $saved }
}

# Every path this script writes to goes through here.
function Assert-Inside([string]$Path) {
  $full = [IO.Path]::GetFullPath($Path)
  if (-not $full.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to write outside the kit folder: $full"
  }
  return $full
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  [IO.File]::WriteAllText((Assert-Inside $Path), $Text, (New-Object Text.UTF8Encoding $false))
}

# Downloads $Url to $Dest only if the cached copy is missing or wrong, and
# accepts it only when its SHA256 equals the pin.
function Get-Verified([string]$Url, [string]$Dest, [string]$Sha) {
  $Dest = Assert-Inside $Dest
  if (Test-Path -LiteralPath $Dest) {
    if ((Sha256 $Dest) -eq $Sha) { Ok "cached $(Split-Path $Dest -Leaf) (sha256 ok)"; return $Dest }
    Warn "cached $(Split-Path $Dest -Leaf) has a wrong hash; downloading again"
    Remove-Item -LiteralPath $Dest -Force
  }
  if (-not $Url.StartsWith('https://')) { throw "Refusing non-HTTPS URL: $Url" }
  New-Item -ItemType Directory -Force (Split-Path $Dest) | Out-Null
  $partial = "$Dest.partial"
  Write-Host "  ...  downloading $Url"
  Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -MaximumRedirection 5
  $got = Sha256 $partial
  if ($got -ne $Sha) {
    Remove-Item -LiteralPath $partial -Force
    throw "SHA256 mismatch for $Url`n  expected $Sha`n  got      $got"
  }
  Move-Item -LiteralPath $partial -Destination $Dest -Force
  Ok "downloaded $(Split-Path $Dest -Leaf) (sha256 matches the pin)"
  return $Dest
}

# Extracts a zip after checking that every entry stays under $Prefix (no
# absolute paths, no "..", no drive letters).
function Expand-ZipSafe([string]$Zip, [string]$DestDir, [string]$Prefix) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $DestDir = Assert-Inside $DestDir
  $z = [IO.Compression.ZipFile]::OpenRead($Zip)
  try {
    foreach ($e in $z.Entries) {
      $n = $e.FullName -replace '\\', '/'
      if (-not $n.StartsWith($Prefix) -or $n -match '(^|/)\.\.(/|$)' -or $n.Contains(':')) {
        throw "Unsafe entry in $(Split-Path $Zip -Leaf): $($e.FullName)"
      }
    }
  } finally { $z.Dispose() }
  [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $DestDir)
}

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) {
  throw 'This kit targets Windows x64 (portable Node win-x64 and REA native/windows).'
}

$pins = Get-Content -LiteralPath (Join-Path $Root 'kit\versions.json') -Raw | ConvertFrom-Json
$nodeVer = $pins.node.version
$nvmrc = (Get-Content -LiteralPath (Join-Path $Root '.nvmrc') -Raw).Trim()
if ($nvmrc -ne $nodeVer) { throw ".nvmrc ($nvmrc) and kit\versions.json ($nodeVer) disagree" }
$nodeDir = Join-Path $Root ".tools\node-v$nodeVer-win-x64"
$nodeExe = Join-Path $nodeDir 'node.exe'
$npmCmd = Join-Path $nodeDir 'npm.cmd'
$modeText = 'install'; if ($VerifyOnly) { $modeText = 'verify only' }
Step "kit: $Root ($modeText)"

# The script changes environment variables only for this process; they are
# restored at the end so the calling PowerShell session is left as it was.
$savedEnv = @{}
Get-ChildItem env: | ForEach-Object { $savedEnv[$_.Name] = $_.Value }
$hadReaFunction = Test-Path function:global:rea

try {
  # ---- 1. Portable Node
  Step "1/8 Node v$nodeVer (portable, pinned)"
  if (-not (Test-Path -LiteralPath $nodeExe)) {
    if ($VerifyOnly) { throw "Node not installed in $nodeDir (run without -VerifyOnly)" }
    $zipName = "node-v$nodeVer-win-x64.zip"
    $zip = Get-Verified $pins.node.url (Join-Path $Root ".tools\download\node-v$nodeVer\$zipName") $pins.node.zipSha256
    if (Test-Path -LiteralPath $nodeDir) { Remove-Item -LiteralPath (Assert-Inside $nodeDir) -Recurse -Force }  # partial extraction
    Expand-ZipSafe $zip (Join-Path $Root '.tools') "node-v$nodeVer-win-x64/"
  }
  if ((Sha256 $nodeExe) -ne $pins.node.nodeExeSha256) { throw "node.exe sha256 differs from the pin: $nodeExe" }
  Ok "node.exe $nodeVer (sha256 matches the pin)"

  # ---- 2. Session environment (same as ". .\env.ps1")
  Step '2/8 local environment (npm cache/prefix/logs inside the kit, no scripts)'
  . (Join-Path $Root 'env.ps1')
  foreach ($d in @('targets', 'projects', 'findings', 'logs', '.rea-runtime')) {
    New-Item -ItemType Directory -Force (Assert-Inside (Join-Path $Root $d)) | Out-Null
  }

  $snapBefore = $null
  if (-not $VerifyOnly) {
    & (Join-Path $Root 'scripts\snapshot-outside.ps1') -Label 'bootstrap-before' | Out-Null
    $snapBefore = Get-ChildItem (Join-Path $Root 'logs\isolation\bootstrap-before-*.json') | Sort-Object Name | Select-Object -Last 1
    Ok "snapshot of the state outside the folder: logs\isolation\$($snapBefore.Name)"
  }

  # ---- 3. npm ci (lockfile only, no lifecycle scripts)
  Step "3/8 rea-agents@$($pins.reaAgents.version) and dependencies from package-lock.json"
  $nm = Join-Path $Root 'node_modules'
  if ($Reinstall -and -not $VerifyOnly -and (Test-Path -LiteralPath $nm)) { Remove-Item -LiteralPath (Assert-Inside $nm) -Recurse -Force }
  if (Test-Path -LiteralPath (Join-Path $nm 'rea-agents\package.json')) {
    Ok 'node_modules present (use -Reinstall to rebuild it)'
  } elseif ($VerifyOnly) {
    Bad 'node_modules missing'
  } else {
    Push-Location $Root
    try {
      Invoke-Native { & $npmCmd ci --ignore-scripts --no-audit --no-fund }
      if ($LASTEXITCODE -ne 0) { throw "npm ci failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
    Ok 'npm ci --ignore-scripts'
  }

  # ---- 4. Registry signatures and advisories
  Step '4/8 registry signatures and known advisories'
  if ($SkipNetworkChecks) {
    Warn 'skipped (-SkipNetworkChecks)'
  } elseif (Test-Path -LiteralPath (Join-Path $nm 'rea-agents')) {
    Push-Location $Root
    try {
      $sig = Invoke-Native { & $npmCmd audit signatures 2>&1 | Out-String }
      if ($LASTEXITCODE -eq 0) { Ok (($sig -split "`r?`n" | Where-Object { $_ -match 'verified' }) -join '; ') }
      else { Bad "npm audit signatures failed:`n$sig" }
      $auditJson = Invoke-Native { & $npmCmd audit --json 2>$null | Out-String }
      # Compare advisory IDs with the ones reviewed in SECURITY_AUDIT.md section 4.
      $auditJson = [string]$auditJson
      $found = @([regex]::Matches($auditJson, 'GHSA(-[0-9a-z]{4}){3}') | ForEach-Object Value | Sort-Object -Unique)
      $accepted = @($pins.reaAgents.acceptedAdvisories)
      $new = @($found | Where-Object { $accepted -notcontains $_ })
      if (-not $auditJson.Contains('"auditReportVersion"')) { Warn 'npm audit did not return a report (network?)' }
      elseif ($new.Count) { Warn "NEW npm advisories not reviewed in SECURITY_AUDIT.md: $($new -join ', ') (run: npm audit)" }
      else { Ok "npm audit: $($found.Count) advisories, all already reviewed ($($found -join ', '))" }
    } finally { Pop-Location }
  }

  # ---- 5. Frida native binding (optional)
  Step '5/8 frida native binding'
  $fridaPkg = Join-Path $nm 'frida'
  $binding = Join-Path $fridaPkg 'build\frida_binding.node'
  if ((Test-Path -LiteralPath $binding) -and ((Sha256 $binding) -eq $pins.frida.bindingSha256)) {
    Ok 'already installed (sha256 matches the pin)'
  } elseif (-not $WithFrida -or $VerifyOnly) {
    Warn 'not installed: Frida tools will not work (use -WithFrida)'
  } else {
    $fridaVer = (Get-Content -LiteralPath (Join-Path $fridaPkg 'package.json') -Raw | ConvertFrom-Json).version
    if ($fridaVer -ne $pins.frida.version) { throw "node_modules has frida@$fridaVer but the pin is $($pins.frida.version)" }
    $tgzName = Split-Path $pins.frida.url -Leaf
    $tgz = Get-Verified $pins.frida.url (Join-Path $Root ".tools\download\frida-$fridaVer\$tgzName") $pins.frida.tarballSha256
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    $listed = @(Invoke-Native { & $tar -tzf $tgz } | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) { throw 'tar could not list the frida tarball' }
    if (($listed -join '|') -ne (@($pins.frida.tarballEntries) -join '|')) { throw "Unexpected entries in the frida tarball: $($listed -join ', ')" }
    $fridaDest = Assert-Inside $fridaPkg
    $entriesToExtract = @($pins.frida.tarballEntries)
    Invoke-Native { & $tar -xzf $tgz -C $fridaDest $entriesToExtract }
    if ($LASTEXITCODE -ne 0) { throw 'tar could not extract the frida binding' }
    if ((Sha256 $binding) -ne $pins.frida.bindingSha256) { Remove-Item -LiteralPath $binding -Force; throw 'frida binding sha256 differs from the pin (removed)' }
    Ok "frida@$fridaVer binding installed from the pinned tarball (install script not executed)"
  }

  # ---- 6. Project-scoped MCP registration (absolute paths of THIS machine)
  Step '6/8 .mcp.json (project scope, generated)'
  $launcher = Join-Path $Root 'scripts\rea-isolated.mjs'
  if ($VerifyOnly) {
    Ok 'not regenerated (verify only)'
  } else {
    $mcp = @"
{
  "mcpServers": {
    "rea": {
      "type": "stdio",
      "command": "$($nodeExe.Replace('\', '\\'))",
      "args": ["$($launcher.Replace('\', '\\'))"],
      "env": {}
    }
  }
}
"@
    Write-Utf8NoBom (Join-Path $Root '.mcp.json') ($mcp -replace "`r`n", "`n")
    Ok "rea -> $nodeExe $launcher"
  }

  # ---- 7. Skill = upstream skill + kit preamble
  Step '7/8 skill .claude\skills\reverse-engineer-anything (generated)'
  $srcSkill = Join-Path $nm 'rea-agents\skills\reverse-engineer-anything'
  $dstSkill = Join-Path $Root '.claude\skills\reverse-engineer-anything'
  if ($VerifyOnly) {
    Ok 'not regenerated (verify only)'
  } elseif (-not (Test-Path -LiteralPath (Join-Path $srcSkill 'SKILL.md'))) {
    Bad 'upstream skill not found in node_modules'
  } else {
    $upstream = [IO.File]::ReadAllText((Join-Path $srcSkill 'SKILL.md'))
    $m = [regex]::Match($upstream, '\A(---\r?\n.*?\r?\n---\r?\n)(.*)\z', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) { throw 'Unexpected SKILL.md format (no frontmatter)' }
    $preamble = [IO.File]::ReadAllText((Join-Path $Root 'kit\skill-preamble.md')) -replace "`r`n", "`n"
    $preamble = $preamble.Replace('{{REA_VERSION}}', $pins.reaAgents.version).Replace('{{NODE_VERSION}}', $nodeVer).Replace('{{SKILL_SHA256}}', $pins.reaAgents.skillSha256)
    if (Test-Path -LiteralPath $dstSkill) { Remove-Item -LiteralPath (Assert-Inside $dstSkill) -Recurse -Force }
    New-Item -ItemType Directory -Force (Assert-Inside (Split-Path $dstSkill)) | Out-Null
    Copy-Item -LiteralPath $srcSkill -Destination (Assert-Inside $dstSkill) -Recurse
    $composed = $m.Groups[1].Value + "`n" + $preamble.TrimEnd() + "`n`n" + $m.Groups[2].Value.TrimStart("`r", "`n")
    Write-Utf8NoBom (Join-Path $dstSkill 'SKILL.md') $composed
    Ok 'upstream skill copied and kit preamble inserted after its frontmatter'
  }

  # ---- 8. Verification
  Step '8/8 verification'
  Invoke-Native { & $nodeExe (Join-Path $Root 'scripts\kit-verify.mjs') }
  if ($LASTEXITCODE -ne 0) { Bad 'kit-verify.mjs reported failures (see above)' }

  # Nothing reachable from outside: rea not on the real PATH, not in user-scope configs.
  $realPath = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
  $onPath = foreach ($d in ($realPath -split ';' | Where-Object { $_ })) {
    foreach ($n in @('rea', 'rea.cmd', 'rea.ps1', 'rea.exe', 'rea-agents', 'rea-agents.cmd', 'rea-agents.ps1')) {
      $p = Join-Path ([Environment]::ExpandEnvironmentVariables($d)) $n
      if (Test-Path -LiteralPath $p) { $p }
    }
  }
  if ($onPath) { Bad "rea is reachable on the system PATH: $($onPath -join ', ')" } else { Ok 'rea is not on the system PATH (user + machine)' }

  $userHome = [Environment]::GetFolderPath('UserProfile')
  $claudeJson = Join-Path $userHome '.claude.json'
  if (Test-Path -LiteralPath $claudeJson) {
    $names = (Invoke-Native { & $nodeExe (Join-Path $Root 'scripts\claude-mcp-names.cjs') $claudeJson $Root }) | ConvertFrom-Json
    if (@($names.user | Where-Object { $_ -match 'rea' }).Count) { Bad "user-scope MCP server like 'rea' in ~/.claude.json: $($names.user -join ', ')" }
    else { Ok 'no REA server in user scope (~/.claude.json)' }
    if (@($names.thisProjectLocal).Count) { Warn "local-scope MCP servers for this folder in ~/.claude.json: $($names.thisProjectLocal -join ', ')" }
  }
  foreach ($d in @("$userHome\.claude\skills\reverse-engineer-anything", "$userHome\.agents\skills\reverse-engineer-anything")) {
    if (Test-Path -LiteralPath $d) { Warn "a global REA skill exists outside the kit: $d (not created by this kit)" }
  }

  if ($snapBefore) {
    & (Join-Path $Root 'scripts\snapshot-outside.ps1') -Label 'bootstrap-after' | Out-Null
    $snapAfter = Get-ChildItem (Join-Path $Root 'logs\isolation\bootstrap-after-*.json') | Sort-Object Name | Select-Object -Last 1
    $diff = @(& (Join-Path $Root 'scripts\compare-snapshots.ps1') -Before $snapBefore.FullName -After $snapAfter.FullName)
    if ($diff.Count -eq 0) { Ok 'no changes outside the folder (before vs after snapshot)' }
    else { foreach ($i in $diff) { Warn "outside the folder: $i (another app may have changed it; check)" } }
  }
} catch {
  Bad $_.Exception.Message
} finally {
  # Restore the caller's session environment.
  foreach ($k in @(Get-ChildItem env: | ForEach-Object Name)) {
    if (-not $savedEnv.ContainsKey($k)) { [Environment]::SetEnvironmentVariable($k, $null, 'Process') }
  }
  foreach ($k in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k], 'Process') }
  if (-not $hadReaFunction -and (Test-Path function:global:rea)) { Remove-Item function:global:rea }
}

Write-Host ''
if ($script:Failures.Count) {
  Write-Host "[bootstrap] $($script:Failures.Count) failure(s), $($script:Warnings.Count) warning(s). The kit is NOT ready." -ForegroundColor Red
  exit 1
}
Write-Host "[bootstrap] ready ($($script:Warnings.Count) warning(s))." -ForegroundColor Green
Write-Host '  Claude Code: open a NEW session in this folder and accept the workspace trust prompt.'
Write-Host '  CLI:         . .\env.ps1   then   rea analyze-javascript-application .\targets\<app> --json'
Write-Host '  Monitored:   powershell -NoProfile -ExecutionPolicy Bypass -File .\run-monitored.ps1 -Target targets\<app>'
exit 0
