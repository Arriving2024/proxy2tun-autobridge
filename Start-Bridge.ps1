#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Detect','Generate','Watch')][string]$Mode='Watch',
    [string]$SingBoxPath,
    [string]$ProxyEndpoint,
    [string[]]$ExtraDirectProcessPath=@(),
    [switch]$AllowSystemDnsBootstrap,
    [ValidateRange(1,60)][int]$PollSeconds=3,
    [ValidateRange(1,10)][int]$LossThreshold=2,
    [ValidateRange(1,300)][int]$HealthIntervalSeconds=30,
    [ValidateRange(1,120)][int]$StartupGraceSeconds=15,
    [ValidateRange(1,60)][int]$NetworkDebounceSeconds=6,
    [ValidateRange(0,10)][int]$MaxRecoveryAttempts=3,
    [ValidateRange(1,120)][int]$RecoveryBaseSeconds=10,
    [ValidateRange(30,3600)][int]$HealthyResetSeconds=300
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $SingBoxPath){$SingBoxPath=Join-Path $PSScriptRoot 'bin\sing-box.exe'}
foreach($module in @('Discovery','Config','Lifecycle','Health')){Import-Module (Join-Path $PSScriptRoot ('src\'+$module+'.psm1')) -Force}
if(-not [Environment]::Is64BitProcess -or $env:OS -ne 'Windows_NT'){throw 'Use 64-bit Windows PowerShell on Windows 11 x64.'}
$selection=@{}
if($ProxyEndpoint){
    $endpoint=[uri]$ProxyEndpoint
    if($endpoint.Scheme -notin @('socks5','http') -or $endpoint.Host -notin @('127.0.0.1','localhost','[::1]','::1') -or $endpoint.Port -lt 1 -or $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment -or $endpoint.AbsolutePath -notin @('','/')){throw 'Use a no-auth loopback endpoint, e.g. socks5://127.0.0.1:10808. Credentials and remote endpoints are unsupported.'}
    $selection=@{ProxyHost=$endpoint.Host.Trim('[',']');ProxyPort=$endpoint.Port;ProxyProtocol=$endpoint.Scheme}
    if($selection.ProxyHost -eq 'localhost'){$selection.ProxyHost='127.0.0.1'}
}
if($Mode -eq 'Detect'){Get-P2TProxyCandidates @selection | Format-Table Protocol,Host,Port,ProcessId,ProcessName,ParentName,Source -AutoSize;return}
if(-not (Test-Path -LiteralPath $SingBoxPath -PathType Leaf)){throw 'sing-box.exe missing. Run install.ps1 or provide -SingBoxPath.'}
$SingBoxPath=(Resolve-Path -LiteralPath $SingBoxPath).Path
$version=(& $SingBoxPath version 2>&1 | Out-String)
if($LASTEXITCODE -ne 0 -or $version -notmatch 'sing-box version 1\.14\.2(?:\s|$)'){throw 'This release requires sing-box 1.14.2. Run install.ps1 for the pinned official dependency.'}
$runtime=Join-Path $PSScriptRoot 'runtime'
$null=New-Item -ItemType Directory -Force -Path $runtime
$configPath=Join-Path $runtime 'config.json'
if($Mode -eq 'Generate'){
    $candidate=Select-P2TProxyCandidate -Candidates @(Get-P2TProxyCandidates @selection) @selection
    if(-not $candidate){throw 'No compatible proxy detected. Start your proxy client and retry.'}
    $config=New-P2TSingBoxConfig -Candidate $candidate -InterfaceName ('p2t-'+[guid]::NewGuid().ToString('N').Substring(0,10)) -ExtraDirectProcessPath $ExtraDirectProcessPath -AllowSystemDnsBootstrap:$AllowSystemDnsBootstrap
    $null=Set-P2TSingBoxConfig -Config $config -Path (Join-Path $runtime 'preview.json') -SingBoxPath $SingBoxPath
    Write-Host 'Preview written to runtime\preview.json; syntax checked. No network changes.'
    return
}
if(-not (Test-P2TAdministrator)){throw 'Watch needs administrator rights. Right-click Start-Bridge.cmd and choose Run as administrator.'}
Initialize-P2TNative
$mutex=New-Object Threading.Mutex($false,'Global\Proxy2TUN.AutoBridge.v1')
$locked=$false;$child=$null;$state=$null;$lockFile=$null;$transaction=$null
$statePath=Join-Path $runtime 'state.json'
$logPath=Join-Path $runtime 'bridge.log'
$stopPath=Join-Path $runtime 'stop.request'
$recovery=New-P2TRecoveryState

function Write-RecoveryState {
    param([string]$Reason)
    Register-P2TRecoveryFailure -State $recovery -Reason $Reason -MaxAttempts $MaxRecoveryAttempts -BaseSeconds $RecoveryBaseSeconds
    $state.RecoveryFailures=$recovery.Failures
    if($recovery.Latched){
        $state.Status='RecoveryPaused'
        Write-P2TLog -Path $logPath -Message ('Recovery paused after {0} consecutive failures ({1}). Owned TUN released. Stop and start explicitly after checking runtime diagnostics.' -f $recovery.Failures,$Reason)
    }else{
        $state.Status='Backoff'
        Write-P2TLog -Path $logPath -Message ('Recovery {0}/{1}: {2}; retry in {3}s. Owned TUN released.' -f $recovery.Failures,$MaxRecoveryAttempts,$Reason,$recovery.DelaySeconds)
    }
    Write-P2TState -State $state -Path $statePath
}

try {
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Another AutoBridge watcher is running. Stop it from its own installation first.'}
    $lockFile=[IO.File]::Open((Join-Path $runtime 'watcher.lock'),'OpenOrCreate','ReadWrite','None')
    if(Test-Path -LiteralPath $statePath){
        $oldState=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if($oldState.Schema -ne 1 -or $oldState.Root -ne $PSScriptRoot){throw 'Previous ownership state mismatch. Refusing to clean unrelated network state.'}
        if($oldState.Child -and (Test-P2TStamp $oldState.Child)){throw 'Previous owned core is still running. Run Stop-Bridge.ps1 -Emergency first.'}
        Remove-P2TOwnedNetwork -State $oldState
    }
    if(Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue){throw 'An existing sing-box is running. Stop the other TUN through its own controls before starting AutoBridge.'}
    Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
    $state=[ordered]@{Schema=1;Root=$PSScriptRoot;Owner=(Get-P2TProcessStamp $PID);Child=$null;InterfaceName=$null;AdapterGuid=$null;Status='Waiting';RecoveryFailures=0}
    Write-P2TState -State $state -Path $statePath
    Write-P2TLog -Path $logPath -Message 'Proxy2TUN AutoBridge v0.2.1. Foreground watcher; DNS and HTTPS checks enabled. Ctrl+C or Stop-Bridge stops it.'
    $network=New-P2TNetworkObservation -Snapshot (Get-P2TNetworkFingerprint)
    $candidate=$null;$misses=0;$tunMisses=0;$forwardingMisses=0;$lastNotice='';$scanAt=[DateTime]::MinValue;$healthAt=[DateTime]::MinValue;$lastHealth=''
    while(-not (Test-Path -LiteralPath $stopPath)){
        if([DateTime]::UtcNow -lt $scanAt){Start-Sleep -Milliseconds 200;continue}
        $scanAt=[DateTime]::UtcNow.AddSeconds($PollSeconds)
        $snapshot=Get-P2TNetworkFingerprint -OwnedInterfaceName $state.InterfaceName
        $networkChanged=Update-P2TNetworkObservation -State $network -Snapshot $snapshot -DebounceSeconds $NetworkDebounceSeconds
        if(-not $snapshot.Valid -and $lastNotice -ne 'NetworkInspectionUnavailable'){
            Write-P2TLog -Path $logPath -Message 'Physical network inspection unavailable; no rebuild is triggered by this observation.'
            $lastNotice='NetworkInspectionUnavailable'
        }
        if($child){
            $failure=''
            if($child.HasExited){$failure='CoreExited'}
            elseif($networkChanged){$failure='PhysicalNetworkChanged'}
            else{
                $tunNetwork=Test-P2TOwnedTunRoutes -InterfaceName $state.InterfaceName -AdapterGuid $state.AdapterGuid
                if($tunNetwork.Success){$tunMisses=0}else{$tunMisses++;$recovery.HealthySince=$null}
                $upstreamHealthy=Test-P2TProcessIdentity -Candidate $candidate
                if($upstreamHealthy){$probe=Test-P2TProxyEndpoint -ProxyHost $candidate.Host -Port $candidate.Port -Protocol $candidate.Protocol;$upstreamHealthy=$probe.Success}
                if($upstreamHealthy){$misses=0}else{$misses++;$recovery.HealthySince=$null}
                if($tunMisses -ge $LossThreshold){$failure=$tunNetwork.Classification}
                elseif($misses -ge $LossThreshold){$failure='UpstreamUnavailableOrIdentityChanged'}
                elseif($tunNetwork.Success -and $upstreamHealthy -and [DateTime]::UtcNow -ge $healthAt){
                    $health=Test-P2TForwardingHealth -RuntimePath $runtime
                    $healthAt=[DateTime]::UtcNow.AddSeconds($HealthIntervalSeconds)
                    $summary='{0}; {1}; HTTPS {2}, HTTP {3}, curl {4}' -f $health.Dns.Classification,$health.FreshDns.Classification,$health.Https.Classification,$health.Https.HttpStatus,$health.Https.CurlExitCode
                    if($health.Success){$forwardingMisses=0;Register-P2TRecoverySuccess -State $recovery -HealthyResetSeconds $HealthyResetSeconds}
                    else{$forwardingMisses++;$recovery.HealthySince=$null}
                    if($summary -ne $lastHealth -or -not $health.Success){Write-P2TLog -Path $logPath -Message ('Forwarding check: '+$summary);$lastHealth=$summary}
                    if($forwardingMisses -ge $LossThreshold){$failure='TunAliveButForwardingFailed'}
                }
            }
            if($failure){
                Stop-P2TOwnedChild -Child $child -State $state -StatePath $statePath -LogPath $logPath
                $child=$null;$candidate=$null;$misses=0;$tunMisses=0;$forwardingMisses=0
                Write-RecoveryState -Reason $failure
            }
            continue
        }
        if($recovery.Latched -or [DateTime]::UtcNow -lt $recovery.RetryAt){continue}
        if($network.Initialized -and -not $network.StableAvailable){
            if($lastNotice -ne 'NoPhysicalDefaultRoute'){Write-P2TLog -Path $logPath -Message 'Waiting for a stable physical default route.';$lastNotice='NoPhysicalDefaultRoute'}
            continue
        }
        try{
            $candidate=Select-P2TProxyCandidate -Candidates @(Get-P2TProxyCandidates @selection) @selection
            if(-not $candidate -or -not (Test-P2TProcessIdentity -Candidate $candidate)){continue}
            if(Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue){throw 'AnotherCorePresent'}
            $state.InterfaceName='p2t-'+[guid]::NewGuid().ToString('N').Substring(0,10)
            if(Get-NetAdapter -Name $state.InterfaceName -IncludeHidden -ErrorAction SilentlyContinue){throw 'AdapterNameCollision'}
            $coreLog=Join-Path $runtime ('core-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'.log')
            $config=New-P2TSingBoxConfig -Candidate $candidate -InterfaceName $state.InterfaceName -LogPath $coreLog -ExtraDirectProcessPath $ExtraDirectProcessPath -AllowSystemDnsBootstrap:$AllowSystemDnsBootstrap
            $transaction=Set-P2TSingBoxConfig -Config $config -Path $configPath -SingBoxPath $SingBoxPath
            if(Test-Path -LiteralPath $stopPath){break}
            if(-not (Test-P2TProcessIdentity -Candidate $candidate)){throw 'UpstreamChangedBeforeStart'}
            $state.Status='Starting';Write-P2TState -State $state -Path $statePath
            $child=New-Object Proxy2Tun.OwnedProcess($SingBoxPath,('run -c "'+$configPath+'"'),(Split-Path $SingBoxPath))
            $state.Child=[ordered]@{Id=$child.Id;Path=$SingBoxPath;StartFileTime=$child.StartFileTime.ToString()}
            Write-P2TState -State $state -Path $statePath
            $readyUntil=[DateTime]::UtcNow.AddSeconds(12);$adapter=$null;$tunReady=$false
            while(-not $child.HasExited -and [DateTime]::UtcNow -lt $readyUntil -and -not (Test-Path -LiteralPath $stopPath)){
                $adapter=Get-NetAdapter -Name $state.InterfaceName -IncludeHidden -ErrorAction SilentlyContinue
                if($adapter){
                    $state.AdapterGuid=$adapter.InterfaceGuid.ToString();Write-P2TState -State $state -Path $statePath
                    $tunReady=(Test-P2TOwnedTunRoutes -InterfaceName $state.InterfaceName -AdapterGuid $state.AdapterGuid).Success
                    if($tunReady){break}
                }
                Start-Sleep -Milliseconds 250
            }
            if(Test-Path -LiteralPath $stopPath){break}
            if(-not $adapter -or $child.HasExited -or -not $state.AdapterGuid -or -not $tunReady){throw 'TunRoutesNotReady'}
            $state.Status='Verifying';Write-P2TState -State $state -Path $statePath
            $verifyUntil=[DateTime]::UtcNow.AddSeconds($StartupGraceSeconds)
            do{
                $health=Test-P2TForwardingHealth -RuntimePath $runtime
                $lastHealth='{0}; {1}; HTTPS {2}, HTTP {3}, curl {4}' -f $health.Dns.Classification,$health.FreshDns.Classification,$health.Https.Classification,$health.Https.HttpStatus,$health.Https.CurlExitCode
                Write-P2TLog -Path $logPath -Message ('Startup check: '+$lastHealth)
                if($health.Success -or $child.HasExited -or (Test-Path -LiteralPath $stopPath) -or [DateTime]::UtcNow -ge $verifyUntil){break}
                Start-Sleep -Milliseconds 250
            }while($true)
            if(Test-Path -LiteralPath $stopPath){break}
            if(-not $health.Success -or $child.HasExited -or -not (Test-P2TOwnedTunRoutes -InterfaceName $state.InterfaceName -AdapterGuid $state.AdapterGuid).Success){throw 'StartupDnsOrHttpsVerificationFailed'}
            $transaction=$null
            $state.Status='Running';$state.RecoveryFailures=$recovery.Failures;Write-P2TState -State $state -Path $statePath
            Register-P2TRecoverySuccess -State $recovery -HealthyResetSeconds $HealthyResetSeconds
            $healthAt=[DateTime]::UtcNow.AddSeconds([Math]::Max($HealthIntervalSeconds,$StartupGraceSeconds))
            $misses=0;$tunMisses=0;$forwardingMisses=0;$lastNotice=''
            Write-P2TLog -Path $logPath -Message ('TUN ready: {0}; {1} upstream; DNS and certificate-validated HTTPS passed. HTTP service errors/challenges do not trigger a transport restart.' -f $state.InterfaceName,$candidate.Protocol)
        }catch{
            # Stop and verify cleanup before replacing configuration. A cleanup
            # failure escapes: starting a second child would be unsafe.
            $startError=$_.Exception.Message
            if($child){Stop-P2TOwnedChild -Child $child -State $state -StatePath $statePath -LogPath $logPath;$child=$null}
            if($transaction){Restore-P2TSingBoxConfig -Transaction $transaction;$transaction=$null;Write-P2TLog -Path $logPath -Message 'Failed startup configuration rolled back after owned TUN teardown.'}
            $candidate=$null
            $reason=if($startError -in @('AnotherCorePresent','AdapterNameCollision','UpstreamChangedBeforeStart','TunRoutesNotReady','StartupDnsOrHttpsVerificationFailed')){$startError}else{'StartupOrDiscoveryError'}
            Write-RecoveryState -Reason $reason
        }
    }
}finally{
    try{
        if($state){Stop-P2TOwnedChild -Child $child -State $state -StatePath $statePath -LogPath $logPath;$child=$null}
        if($transaction){Restore-P2TSingBoxConfig -Transaction $transaction;$transaction=$null}
        if($state){$state.Status='Stopped';Write-P2TState -State $state -Path $statePath}
    }finally{
        if($child){$child.Dispose()};if($lockFile){$lockFile.Dispose()};if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()
    }
}
