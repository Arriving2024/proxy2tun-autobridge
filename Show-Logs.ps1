#requires -Version 5.1
[CmdletBinding()]
param([switch]$Core)
$path=Join-Path $PSScriptRoot 'runtime\bridge.log'
if ($Core) { $item=Get-ChildItem (Join-Path $PSScriptRoot 'runtime\core-*.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($item) { $path=$item.FullName } }
if (-not (Test-Path -LiteralPath $path)) { Write-Host 'No log yet. Start AutoBridge first.'; return }
Get-Content -LiteralPath $path -Tail 40 -Wait
