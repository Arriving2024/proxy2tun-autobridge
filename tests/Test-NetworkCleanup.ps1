#requires -Version 5.1
# Only module-scoped mocks are called. No actual network cmdlet executes.
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot '..\src\Lifecycle.psm1') -Force -PassThru
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('p2t-cleanup-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
try {
    & $module {
        $script:fixtureMode = 'AdapterError'; $script:mutations = 0
        function script:Get-NetAdapter {
            param([switch]$IncludeHidden,$ErrorAction)
            if ($script:fixtureMode -eq 'AdapterError') { throw 'Fixture inspection denied' }
            [pscustomobject]@{Name='p2t-0123456789';InterfaceGuid=[guid]'22222222-2222-2222-2222-222222222222';ifIndex=9999}
            [pscustomobject]@{Name='unrelated';InterfaceGuid=[guid]'33333333-3333-3333-3333-333333333333';ifIndex=8888}
        }
        function script:Get-NetRoute {
            param($ErrorAction)
            if ($script:fixtureMode -eq 'RouteError') { throw 'Fixture route inspection denied' }
            [pscustomobject]@{InterfaceIndex=9999;DestinationPrefix='0.0.0.0/1'}
            [pscustomobject]@{InterfaceIndex=8888;DestinationPrefix='0.0.0.0/0'}
        }
        function script:Remove-NetRoute {
            [CmdletBinding(SupportsShouldProcess)]param([Parameter(ValueFromPipeline)]$InputObject)
            process { if ($InputObject.InterfaceIndex -ne 9999) { throw 'Unrelated route touched' }; $script:mutations++ }
        }
        function script:Disable-NetAdapter {
            [CmdletBinding(SupportsShouldProcess)]param([Parameter(ValueFromPipeline)]$InputObject)
            process { if ($InputObject.ifIndex -ne 9999) { throw 'Unrelated adapter touched' }; $script:mutations++ }
        }
    }
    foreach ($mode in @('AdapterError','RouteError')) {
        & $module { param($Mode) $script:fixtureMode=$Mode } $mode
        $state = [ordered]@{Child=@{Id=1};InterfaceName='p2t-0123456789';AdapterGuid='22222222-2222-2222-2222-222222222222';Status='Running'}
        $failed = $false
        try { Stop-P2TOwnedChild -Child $null -State $state -StatePath (Join-Path $scratch 'state.json') -LogPath (Join-Path $scratch 'bridge.log') } catch { $failed = $true }
        if (-not $failed -or -not $state.AdapterGuid -or -not $state.Child -or $state.Status -ne 'Running') { throw ('Inspection error incorrectly cleared ownership: ' + $mode) }
        if ((& $module { $script:mutations }) -ne 0) { throw 'Inspection error mutated networking' }
    }
    & $module { $script:fixtureMode='Success' }
    $state = [ordered]@{Child=$null;InterfaceName='p2t-0123456789';AdapterGuid='22222222-2222-2222-2222-222222222222';Status='Running'}
    Stop-P2TOwnedChild -Child $null -State $state -StatePath (Join-Path $scratch 'state.json') -LogPath (Join-Path $scratch 'bridge.log')
    if ($state.AdapterGuid -or $state.Status -ne 'Waiting' -or (& $module { $script:mutations }) -ne 2) { throw 'Verified cleanup did not finish scoped mutations' }
    Write-Host 'PASS cleanup: adapter/route inspection errors preserve ownership; only verified route and adapter mutate'
} finally {
    Remove-Module $module.Name -Force
    Remove-Item -LiteralPath (Join-Path $scratch 'state.json') -Force -ErrorAction SilentlyContinue
    if (@(Get-ChildItem -LiteralPath $scratch -Force).Count -eq 0) { Remove-Item -LiteralPath $scratch }
}
