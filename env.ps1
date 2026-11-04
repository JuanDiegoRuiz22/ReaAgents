# Activates the local toolchain ONLY for the current PowerShell session.
# Usage (from the kit root):   . .\env.ps1
# Changes nothing in the system: no PATH registry edits, no PowerShell
# profile changes. Closing the terminal undoes everything.

$ReaRoot = $PSScriptRoot
$nodeVersion = (Get-Content -LiteralPath (Join-Path $ReaRoot ".nvmrc") -Raw).Trim()
$nodeDir = Join-Path $ReaRoot ".tools\node-v$nodeVersion-win-x64"
if (-not (Test-Path -LiteralPath (Join-Path $nodeDir "node.exe"))) {
  throw "Local Node v$nodeVersion not found in $nodeDir. Run .\bootstrap.ps1 first."
}
$binDir = Join-Path $ReaRoot "node_modules\.bin"

# Prepend local Node (session only). node_modules\.bin is deliberately NOT
# added: its 'rea' would run REA without isolation. Use the 'rea' function below.
$clean = ($env:PATH -split ';') | Where-Object { $_ -and ($_ -ne $nodeDir) -and ($_ -ne $binDir) }
$env:PATH = (@($nodeDir) + $clean) -join ';'

# npm: cache, logs and prefix inside the folder even outside the project root.
$env:npm_config_cache    = Join-Path $ReaRoot ".npm-cache"
$env:npm_config_logs_dir = Join-Path $ReaRoot "logs\npm"
$env:npm_config_prefix   = Join-Path $ReaRoot ".npm-prefix"
$env:npm_config_ignore_scripts = "true"
$env:npm_config_update_notifier = "false"
$env:NO_UPDATE_NOTIFIER = "1"

# 'rea' always goes through the isolated launcher (minimal env, home/temp/caches
# redirected to .rea-runtime, setup/update/uninstall/mcp add blocked).
function global:rea {
  & (Join-Path $ReaRoot ".tools\node-v$((Get-Content -LiteralPath (Join-Path $ReaRoot '.nvmrc') -Raw).Trim())-win-x64\node.exe") (Join-Path $ReaRoot "scripts\rea-isolated.mjs") @args
}

Write-Host "[env] Node $(& (Join-Path $nodeDir 'node.exe') --version) from $nodeDir" -ForegroundColor Green
Write-Host "[env] npm prefix/cache -> $ReaRoot" -ForegroundColor Green
