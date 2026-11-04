# Snapshot (read-only) of state OUTSIDE the kit folder, to prove isolation.
# Stores only names, hashes and the PATH; no secret contents.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\snapshot-outside.ps1 [-Label baseline]
param([string]$Label = "snapshot")

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root "logs\isolation"
New-Item -ItemType Directory -Force $outDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out = Join-Path $outDir "$Label-$stamp.json"

function Hash($p) {
  if (Test-Path -LiteralPath $p -PathType Leaf) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } else { $null }
}
function TopLevel($dir) {
  if (Test-Path -LiteralPath $dir) {
    Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.Name }
  } else { @() }
}

$h = $env:USERPROFILE

# Agent / tool config files (hash only). ~/.claude.json is handled separately
# because Claude Code rewrites it constantly (stats); only MCP names are compared there.
$watched = @(
  "$h\.npmrc",
  "$h\.claude\settings.json",
  "$h\.claude\settings.local.json",
  "$h\.claude\CLAUDE.md",
  "$h\.codex\config.toml",
  "$h\.codex\AGENTS.md",
  "$h\.cursor\mcp.json",
  "$h\.gemini\settings.json",
  "$h\.config\opencode\opencode.json",
  "$h\.codeium\windsurf\mcp_config.json",
  "$env:APPDATA\Claude\claude_desktop_config.json",
  "$env:APPDATA\Code\User\settings.json",
  "$env:APPDATA\Code\User\mcp.json",
  "$h\.gitconfig"
)
$hashes = [ordered]@{}
foreach ($f in $watched) { $hashes[$f] = Hash $f }

# MCP server names registered in ~/.claude.json (user scope + this project's local scope)
$mcpNames = $null
$claudeJson = "$h\.claude.json"
if (Test-Path $claudeJson) {
  $nodeVer = (Get-Content -LiteralPath (Join-Path $root ".nvmrc") -Raw).Trim()
  $nodeExe = Join-Path $root ".tools\node-v$nodeVer-win-x64\node.exe"
  if (-not (Test-Path -LiteralPath $nodeExe)) { $nodeExe = "node" }
  $mcpNames = (& $nodeExe (Join-Path $PSScriptRoot "claude-mcp-names.cjs") $claudeJson $root) | ConvertFrom-Json
}

# Commands reachable on PATH
$cmds = [ordered]@{}
foreach ($c in @("rea","rea-agents","node","npm","npx")) {
  $g = Get-Command $c -ErrorAction SilentlyContinue | Select-Object -First 1
  $cmds[$c] = if ($g) { $g.Source } else { $null }
}

# Global npm packages (system prefix, ignoring any session override)
$savedPrefix = $env:npm_config_prefix; $env:npm_config_prefix = $null
Push-Location $env:TEMP
$globalPrefix = (& npm prefix -g 2>$null)
$globalPkgs = (& npm ls -g --depth=0 --json 2>$null) | Out-String
Pop-Location
$env:npm_config_prefix = $savedPrefix
$globalNames = @()
try { $globalNames = @((($globalPkgs | ConvertFrom-Json).dependencies.PSObject.Properties) | ForEach-Object { $_.Name }) } catch {}

$snap = [ordered]@{
  label            = $Label
  timestamp        = (Get-Date).ToString("o")
  pathUser         = [Environment]::GetEnvironmentVariable("Path", "User")
  pathMachine      = [Environment]::GetEnvironmentVariable("Path", "Machine")
  fileHashes       = $hashes
  claudeMcpNames   = $mcpNames
  claudeSkillsDir  = @(TopLevel "$h\.claude\skills")
  claudeAgentsDir  = @(TopLevel "$h\.claude\agents")
  commandsOnPath   = $cmds
  npmGlobalPrefix  = $globalPrefix
  npmGlobalPkgs    = $globalNames
  homeTopLevel     = @(TopLevel $h)
  appDataTopLevel  = @(TopLevel $env:APPDATA)
  localAppDataTop  = @(TopLevel $env:LOCALAPPDATA)
}
$snap | ConvertTo-Json -Depth 6 | Out-File -Encoding utf8 $out
Write-Output "Snapshot written: $out"
