# Compares two snapshots written by snapshot-outside.ps1 and prints one line
# per change detected OUTSIDE the kit folder (nothing printed = no changes).
# Usage: powershell -NoProfile -File scripts\compare-snapshots.ps1 -Before <json> -After <json>
param(
  [Parameter(Mandatory)][string]$Before,
  [Parameter(Mandatory)][string]$After
)
$ErrorActionPreference = 'Stop'
$b = Get-Content -LiteralPath $Before -Raw | ConvertFrom-Json
$a = Get-Content -LiteralPath $After -Raw | ConvertFrom-Json
$iso = New-Object System.Collections.Generic.List[string]
if ($a.pathUser -cne $b.pathUser) { $iso.Add('User PATH changed') }
if ($a.pathMachine -cne $b.pathMachine) { $iso.Add('Machine PATH changed') }
if (($a.claudeMcpNames | ConvertTo-Json -Compress) -ne ($b.claudeMcpNames | ConvertTo-Json -Compress)) { $iso.Add('MCP servers in ~/.claude.json changed') }
if (($a.claudeSkillsDir -join ',') -ne ($b.claudeSkillsDir -join ',')) { $iso.Add('~/.claude/skills changed') }
if (($a.claudeAgentsDir -join ',') -ne ($b.claudeAgentsDir -join ',')) { $iso.Add('~/.claude/agents changed') }
foreach ($p in $b.fileHashes.PSObject.Properties) { if ($a.fileHashes.($p.Name) -ne $p.Value) { $iso.Add("file changed: $($p.Name)") } }
if ($a.commandsOnPath.rea -or $a.commandsOnPath.'rea-agents') { $iso.Add("rea on PATH: $($a.commandsOnPath.rea) $($a.commandsOnPath.'rea-agents')") }
if (($a.npmGlobalPkgs -join ',') -ne ($b.npmGlobalPkgs -join ',')) { $iso.Add('global npm packages changed') }
foreach ($pair in @(@('homeTopLevel', '%USERPROFILE%'), @('appDataTopLevel', '%APPDATA%'), @('localAppDataTop', '%LOCALAPPDATA%'))) {
  $new = @($a.($pair[0]) | Where-Object { @($b.($pair[0])) -notcontains $_ })
  if ($new.Count) { $iso.Add("new in $($pair[1]): $($new -join ', ')") }
}
$iso
