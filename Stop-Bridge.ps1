#requires -Version 5.1
[CmdletBinding()]
param([switch]$Emergency)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'src\Lifecycle.psm1') -Force
$runtime=Join-Path $PSScriptRoot 'runtime'
$statePath=Join-Path $runtime 'state.json'
if (-not (Test-Path -LiteralPath $runtime)) { Write-Host 'Nothing to stop.'; return }
[IO.File]::WriteAllText((Join-Path $runtime 'stop.request'), 'stop')
if (-not (Test-Path -LiteralPath $statePath)) { Write-Host 'Stop requested; no owned core recorded.'; return }
$state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.Schema -ne 1 -or $state.Root -ne $PSScriptRoot) { throw 'Ownership state mismatch. Refusing to stop unrelated processes.' }
if (-not $Emergency) {
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline -and (Test-P2TStamp $state.Owner)) { Start-Sleep -Milliseconds 250 }
}
# The watcher may have changed child/adapter while the stop request was delivered.
$state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.Schema -ne 1 -or $state.Root -ne $PSScriptRoot) { throw 'Ownership state changed unexpectedly.' }
if ((Test-P2TStamp $state.Owner) -or ($state.Child -and (Test-P2TStamp $state.Child))) {
    if (-not (Test-P2TAdministrator)) { throw 'Stop requested. For forced cleanup, run Stop-Bridge.cmd as administrator.' }
    Initialize-P2TNative
    if (Test-P2TStamp $state.Owner) {
        $owner=Get-CimInstance Win32_Process -Filter ('ProcessId={0}' -f $state.Owner.Id)
        if ($owner -and (Test-P2TStamp $state.Owner)) {
            if (-not $owner.CommandLine -or $owner.CommandLine.IndexOf((Join-Path $PSScriptRoot 'Start-Bridge.ps1'),[StringComparison]::OrdinalIgnoreCase) -lt 0) { throw 'Watcher command identity mismatch; refusing forced stop.' }
            if (-not [Proxy2Tun.OwnedProcess]::StopVerified($state.Owner.Id,[long]$state.Owner.StartFileTime,$state.Owner.Path) -and (Test-P2TStamp $state.Owner)) { throw 'Could not stop verified watcher.' }
        }
    }
    if ($state.Child -and (Test-P2TStamp $state.Child)) {
        $core=Get-CimInstance Win32_Process -Filter ('ProcessId={0}' -f $state.Child.Id)
        if ($core -and (Test-P2TStamp $state.Child)) {
            if (-not $core.CommandLine -or $core.CommandLine.IndexOf((Join-Path $runtime 'config.json'),[StringComparison]::OrdinalIgnoreCase) -lt 0) { throw 'Core command identity mismatch; refusing forced stop.' }
            if (-not [Proxy2Tun.OwnedProcess]::StopVerified($state.Child.Id,[long]$state.Child.StartFileTime,$state.Child.Path) -and (Test-P2TStamp $state.Child)) { throw 'Could not stop verified core.' }
        }
    }
}
if ($state.AdapterGuid) {
    if (-not (Test-P2TAdministrator)) { throw 'Run Stop-Bridge.cmd as administrator to verify adapter cleanup.' }
    Remove-P2TOwnedNetwork -State $state
}
$state.Status='Stopped'; $state.Child=$null; $state.AdapterGuid=$null
Write-P2TState -State $state -Path $statePath
Write-Host 'AutoBridge stopped. Original proxy client and unrelated adapters were preserved.'
