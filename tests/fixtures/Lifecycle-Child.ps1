#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Idle','Owner')][string]$Mode = 'Idle',
    [Parameter(Mandatory=$true)][string]$ReadyPath,
    [string]$ChildReadyPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\Lifecycle.psm1') -Force
if ($Mode -eq 'Idle') {
    Write-P2TState -State (Get-P2TProcessStamp -ProcessId $PID) -Path $ReadyPath
    while ($true) { Start-Sleep -Seconds 1 }
}
Initialize-P2TNative
$powershell = Join-Path $PSHOME 'powershell.exe'
$arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Idle -ReadyPath "{1}"' -f $PSCommandPath, $ChildReadyPath
$owned = New-Object Proxy2Tun.OwnedProcess($powershell, $arguments, $PSScriptRoot)
try {
    $record = [ordered]@{
        Owner = (Get-P2TProcessStamp -ProcessId $PID)
        Child = [ordered]@{ Id=$owned.Id; Path=$powershell; StartFileTime=$owned.StartFileTime.ToString() }
    }
    Write-P2TState -State $record -Path $ReadyPath
    while ($true) { Start-Sleep -Seconds 1 }
} finally {
    $owned.Dispose()
}
