#requires -Version 5.1
[CmdletBinding()]
param([string]$SingBoxPath)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
if ($SingBoxPath) { $SingBoxPath=(Resolve-Path -LiteralPath $SingBoxPath).Path }
$files=@(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') -and $_.FullName -notmatch '\\runtime\\' })
foreach ($file in $files) {
    $tokens=$null; $parseErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count) { throw ($file.Name + ': ' + ($parseErrors.Message -join '; ')) }
}
Write-Host ('PASS syntax: {0} PowerShell files' -f $files.Count)
& (Join-Path $PSScriptRoot 'Test-Encoding.ps1')
& (Join-Path $PSScriptRoot 'Test-DiscoveryConfig.ps1') -SingBoxPath $SingBoxPath
& (Join-Path $PSScriptRoot 'Test-ConfigTransaction.ps1') -SingBoxPath $SingBoxPath
& (Join-Path $PSScriptRoot 'Test-Health.ps1')
& (Join-Path $PSScriptRoot 'Test-Lifecycle.ps1')
& (Join-Path $PSScriptRoot 'Test-NetworkCleanup.ps1')
& (Join-Path $PSScriptRoot 'Test-Watcher.ps1')
if ($SingBoxPath) {
    & (Join-Path $PSScriptRoot 'Test-Install.ps1') -SingBoxPath $SingBoxPath
}
Write-Host 'PASS all requested local checks. No TUN was created by this suite.'
