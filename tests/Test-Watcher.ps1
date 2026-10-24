#requires -Version 5.1
# Execute unchanged entry points and actual config/recovery/debounce code in an
# isolated runtime tree. Native core, DNS, HTTPS, identities and network cmdlets
# are mocked: no adapter, route, registry, admin or real kill operation runs.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$runtimeBase=[IO.Path]::GetFullPath((Join-Path $repository 'runtime'))
$testRoot=Join-Path $runtimeBase ('watcher-tests-'+[guid]::NewGuid().ToString('N'))
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$process=$null;$checks=0
function Assert-Watcher {param([bool]$Condition,[string]$Message) if(-not $Condition){throw ('Watcher assertion failed: '+$Message)};$script:checks++;Write-Host ('PASS: '+$Message)}
function Save-Fixture {param([string]$Path,[string]$Content) [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))}
function Get-FixtureLineCount {param([string]$Path) if(Test-Path -LiteralPath $Path){return @(Get-Content -LiteralPath $Path).Count};return 0}

$discoveryFixture=@'
Set-StrictMode -Version Latest
$script:root=Split-Path $PSScriptRoot -Parent
$script:scenario=(Get-Content -LiteralPath (Join-Path $script:root 'scenario.txt') -Raw).Trim()
$script:scans=0;$script:identityMisses=0
function Get-P2TProxyCandidates {
    $script:scans++
    if($script:scans -eq 1){return}
    [pscustomobject]@{Host='127.0.0.1';Port=10808;Protocol='socks5';ProcessId=4242;ProcessName='fixture.exe';ProcessPath='C:\Fixture\fixture.exe';ProcessStartTime='2026-10-24T00:00:00.0000000Z';ParentProcessId=0;ParentName='';ParentPath='';ParentProcessStartTime='';Source='Listener';Priority=100}
}
function Select-P2TProxyCandidate {param($Candidates,$ProxyHost,$ProxyPort,$ProxyProtocol) $Candidates | Select-Object -First 1}
function Test-P2TProcessIdentity {
    param($Candidate)
    if($script:scenario -eq 'Identity' -and [Proxy2Tun.OwnedProcess]::Active -and [Proxy2Tun.OwnedProcess]::Starts -eq 1){$script:identityMisses++;return $false}
    return $true
}
function Test-P2TProxyEndpoint {
    param($ProxyHost,$Port,$Protocol)
    [pscustomobject]@{Success=(-not ($script:scenario -eq 'ProxyLoss' -and [Proxy2Tun.OwnedProcess]::Starts -eq 1))}
}
Export-ModuleMember -Function *-P2T*
'@

$lifecycleFixture=@'
Set-StrictMode -Version Latest
$script:root=Split-Path $PSScriptRoot -Parent
$script:scenario=(Get-Content -LiteralPath (Join-Path $script:root 'scenario.txt') -Raw).Trim()
function Initialize-P2TNative {
    if('Proxy2Tun.OwnedProcess' -as [type]){return}
    Add-Type -TypeDefinition @"
using System;
using System.IO;
namespace Proxy2Tun {
 public sealed class OwnedProcess : IDisposable {
  public static bool Active;
  public static int Starts;
  public static string Root;
  public int Id { get { return 51002; } }
  public long StartFileTime { get { return 1; } }
  public bool HasExited { get { return !Active; } }
  public OwnedProcess(string executable,string arguments,string directory){Root=directory;Active=true;Starts++;File.AppendAllText(Path.Combine(Root,"starts.txt"),"start\n");}
  public bool StopGracefully(int milliseconds){if(Active)File.AppendAllText(Path.Combine(Root,"stops.txt"),"stop\n");Active=false;return true;}
  public void Dispose(){Active=false;}
  public static bool StopVerified(int id,long stamp,string path){File.WriteAllText(Path.Combine(Root,"kill-"+id+".txt"),"mock verified stop");return true;}
 }
}
"@
    [Proxy2Tun.OwnedProcess]::Root=$script:root
}
function Test-P2TAdministrator {return $true}
function Get-P2TProcessStamp {param($ProcessId) [pscustomobject]@{Id=$ProcessId;Path='C:\Fixture\powershell.exe';StartFileTime='1'}}
function Test-P2TStamp {param($Stamp) return (-not (Test-Path -LiteralPath (Join-Path $script:root ('kill-'+$Stamp.Id+'.txt'))))}
function Write-P2TState {
    param($State,$Path)
    [IO.File]::WriteAllText($Path,($State|ConvertTo-Json -Depth 12))
    [IO.File]::AppendAllText((Join-Path $script:root 'events.txt'),($State.Status+"`n"))
    if($State.Status -eq 'Running'){
        [IO.File]::WriteAllText((Join-Path $script:root 'ran.txt'),'yes')
        if($script:scenario -eq 'Challenge' -or [Proxy2Tun.OwnedProcess]::Starts -ge 2){
            [IO.File]::WriteAllText((Join-Path $script:root 'runtime\stop.request'),'fixture stop')
        }
    }
    if($State.Status -eq 'RecoveryPaused'){
        [IO.File]::WriteAllText((Join-Path $script:root 'latched.json'),($State|ConvertTo-Json -Depth 12))
        [IO.File]::WriteAllText((Join-Path $script:root 'runtime\stop.request'),'fixture stop at circuit latch')
    }
}
function Write-P2TLog {param($Message,$Path) [IO.File]::AppendAllText($Path,($Message+"`n"))}
function Remove-P2TOwnedNetwork {param($State) [IO.File]::AppendAllText((Join-Path $script:root 'cleanup.txt'),"mock cleanup`n")}
function Stop-P2TOwnedChild {
    param($Child,$State,$StatePath,$LogPath)
    if($Child){$null=$Child.StopGracefully(3000);$Child.Dispose()}
    Remove-P2TOwnedNetwork $State
    if($State){$State.Child=$null;$State.Status='Waiting';$State.AdapterGuid=$null;Write-P2TState $State $StatePath}
}
function Get-Process {param($Name,$ErrorAction) return $null}
function Get-NetAdapter {
    param($Name,[switch]$IncludeHidden,$ErrorAction)
    if([Proxy2Tun.OwnedProcess]::Active){[pscustomobject]@{Name=$Name;InterfaceGuid=[guid]'22222222-2222-2222-2222-222222222222';Status='Up';ifIndex=9999}}
}
function Get-NetRoute {
    param($InterfaceIndex,$ErrorAction)
    $prefixes=@('0.0.0.0/1','128.0.0.0/1','::/1','8000::/1')
    if($script:scenario -eq 'RouteLoss' -and [Proxy2Tun.OwnedProcess]::Starts -eq 1 -and (Test-Path -LiteralPath (Join-Path $script:root 'ran.txt'))){$prefixes=@('0.0.0.0/1','::/1')}
    foreach($prefix in $prefixes){[pscustomobject]@{DestinationPrefix=$prefix}}
}
function Get-CimInstance {param($ClassName,$Filter) $command=if($Filter -match '51001'){Join-Path $script:root 'Start-Bridge.ps1'}else{Join-Path $script:root 'runtime\config.json'};[pscustomobject]@{CommandLine=$command}}
Export-ModuleMember -Function *
'@

$healthFixture=@'
$script:fixtureRoot=Split-Path $PSScriptRoot -Parent
$script:fixtureScenario=(Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'scenario.txt') -Raw).Trim()
$script:fixtureScans=0;$script:fixtureHealthCalls=0
function Get-P2TNetworkFingerprint {
    param($OwnedInterfaceName)
    $script:fixtureScans++
    $fingerprint='wifi-a'
    if($script:fixtureScenario -eq 'Network'){
        if($script:fixtureScans -eq 4 -or $script:fixtureScans -ge 6){$fingerprint='ethernet-b'}
    }
    [IO.File]::AppendAllText((Join-Path $script:fixtureRoot 'network.txt'),($script:fixtureScans.ToString()+'|'+$fingerprint+"`n"))
    [pscustomobject]@{Valid=$true;Available=$true;Fingerprint=$fingerprint}
}
function Test-P2TForwardingHealth {
    param($RuntimePath)
    $script:fixtureHealthCalls++
    $good=$true;$status=204;$classification='HttpSuccess';$curl=0
    if($script:fixtureScenario -eq 'Challenge'){$status=403;$classification='CloudflareChallenge'}
    if($script:fixtureScenario -eq 'StartupFailure' -or ($script:fixtureScenario -eq 'Forwarding' -and $script:fixtureHealthCalls -gt 1)){$good=$false;$status=0;$classification='NetworkError';$curl=56}
    [pscustomobject]@{Success=$good;Dns=[pscustomobject]@{Success=$true;Classification='DnsSuccess'};FreshDns=[pscustomobject]@{Success=$true;Classification='FreshDnsNxDomain'};Https=[pscustomobject]@{TransportSuccess=$good;ServiceSuccess=($status -eq 204);Classification=$classification;HttpStatus=$status;CurlExitCode=$curl;ElapsedSeconds=0.4}}
}
Export-ModuleMember -Function *-P2T*
'@

try{
    $null=New-Item -ItemType Directory -Path $testRoot -Force
    foreach($scenario in @('Challenge','Identity','ProxyLoss','RouteLoss','Network','Forwarding','StartupFailure')){
        $fixtureRoot=Join-Path $testRoot $scenario
        $null=New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'src') -Force
        $null=New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'runtime') -Force
        foreach($name in @('Start-Bridge.ps1','Stop-Bridge.ps1')){Copy-Item -LiteralPath (Join-Path $repository $name) -Destination (Join-Path $fixtureRoot $name)}
        Copy-Item -LiteralPath (Join-Path $repository 'src\Config.psm1') -Destination (Join-Path $fixtureRoot 'src\Config.psm1')
        $healthSource=[IO.File]::ReadAllText((Join-Path $repository 'src\Health.psm1'))
        Save-Fixture (Join-Path $fixtureRoot 'src\Health.psm1') ($healthSource+"`r`n"+$healthFixture)
        Save-Fixture (Join-Path $fixtureRoot 'src\Discovery.psm1') $discoveryFixture
        Save-Fixture (Join-Path $fixtureRoot 'src\Lifecycle.psm1') $lifecycleFixture
        Save-Fixture (Join-Path $fixtureRoot 'scenario.txt') $scenario
        Save-Fixture (Join-Path $fixtureRoot 'fake-core.cmd') @'
@echo off
if "%1"=="version" echo sing-box version 1.14.2
exit /b 0
'@
        Assert-Watcher ((Get-FileHash (Join-Path $fixtureRoot 'Start-Bridge.ps1')).Hash -eq (Get-FileHash (Join-Path $repository 'Start-Bridge.ps1')).Hash) ($scenario+': unchanged watcher entry point is exercised')
        $oldBytes="{`"fixturePrevious`":true}`r`n"
        if($scenario -eq 'StartupFailure'){Save-Fixture (Join-Path $fixtureRoot 'runtime\config.json') $oldBytes}
        $budget=if($scenario -eq 'StartupFailure'){0}else{1}
        $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Watch -SingBoxPath "{1}" -PollSeconds 1 -LossThreshold 2 -HealthIntervalSeconds 1 -StartupGraceSeconds 1 -NetworkDebounceSeconds 2 -MaxRecoveryAttempts {2} -RecoveryBaseSeconds 1' -f (Join-Path $fixtureRoot 'Start-Bridge.ps1'),(Join-Path $fixtureRoot 'fake-core.cmd'),$budget
        $process=Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $fixtureRoot 'stdout.log') -RedirectStandardError (Join-Path $fixtureRoot 'stderr.log')
        $null=$process.Handle
        if(-not $process.WaitForExit(30000)){throw ($scenario+': mock watcher timed out.')}
        Assert-Watcher ($process.ExitCode -eq 0) ($scenario+': mock watcher exits successfully: '+(Get-Content -LiteralPath (Join-Path $fixtureRoot 'stderr.log') -Raw))
        $events=@(Get-Content -LiteralPath (Join-Path $fixtureRoot 'events.txt'))
        $state=Get-Content -LiteralPath (Join-Path $fixtureRoot 'runtime\state.json') -Raw | ConvertFrom-Json
        $log=Get-Content -LiteralPath (Join-Path $fixtureRoot 'runtime\bridge.log') -Raw
        $starts=Get-FixtureLineCount (Join-Path $fixtureRoot 'starts.txt');$stops=Get-FixtureLineCount (Join-Path $fixtureRoot 'stops.txt')
        Assert-Watcher ($events[0] -eq 'Waiting' -and $state.Status -eq 'Stopped' -and $null -eq $state.Child -and $null -eq $state.AdapterGuid) ($scenario+': waiting/stop request leaves clean owned state')
        Assert-Watcher ($starts -eq $stops) ($scenario+': every started core is released exactly once')
        switch($scenario){
            'Challenge'{
                Assert-Watcher ($starts -eq 1 -and @($events | Where-Object {$_ -eq 'Running'}).Count -eq 1 -and $events -notcontains 'Backoff') '403 challenge passes startup without triggering a rebuild'
                Assert-Watcher ($log -match 'CloudflareChallenge, HTTP 403, curl 0' -and $log -match 'FreshDnsNxDomain') '403 service status and fresh DNS evidence are logged separately'
            }
            'Identity'{
                Assert-Watcher ($starts -eq 2 -and $log -match 'UpstreamUnavailableOrIdentityChanged') 'Upstream identity loss crosses threshold, releases TUN and rebuilds once'
            }
            'ProxyLoss'{
                Assert-Watcher ($starts -eq 2 -and $log -match 'UpstreamUnavailableOrIdentityChanged') 'Proxy health loss crosses threshold and safely rebuilds once'
            }
            'RouteLoss'{
                Assert-Watcher ($starts -eq 2 -and $log -match 'OwnedTunRoutesMissing') 'Missing split-route halves trigger recovery even when mock HTTPS would succeed directly'
            }
            'Network'{
                Assert-Watcher ($starts -eq 2 -and @([regex]::Matches($log,'Recovery 1/1: PhysicalNetworkChanged')).Count -eq 1) 'Transient network change is ignored and one stable switch rebuilds once'
                $networkEvents=@(Get-Content -LiteralPath (Join-Path $fixtureRoot 'network.txt'))
                Assert-Watcher ($networkEvents -contains '4|ethernet-b' -and $networkEvents -contains '5|wifi-a' -and $networkEvents -contains '8|ethernet-b') 'Wi-Fi return and full later debounce are observed before rebuilding'
            }
            'Forwarding'{
                Assert-Watcher ($starts -eq 2 -and $events -contains 'RecoveryPaused' -and @($events | Where-Object {$_ -eq 'Running'}).Count -eq 1) 'Alive TUN with failed forwarding permits only the configured single rebuild and then latches'
                Assert-Watcher ($log -match 'TunAliveButForwardingFailed' -and $log -match 'rolled back after owned TUN teardown') 'Forwarding loss and failed rebuilt startup rollback are diagnosed'
                $backups=@(Get-ChildItem -LiteralPath (Join-Path $fixtureRoot 'runtime') -Filter '*.backup-*.json')
                # The active valid config is the first successfully verified TUN.
                $active=Get-Content -LiteralPath (Join-Path $fixtureRoot 'runtime\config.json') -Raw | ConvertFrom-Json
                Assert-Watcher ($active.inbounds[0].dns_mode -eq 'hijack' -and $active.dns.servers[0].detour -eq 'upstream') 'After failed rebuild the prior working DNS configuration remains active on disk'
                Assert-Watcher ($backups.Count -eq 1 -and (Get-FileHash -LiteralPath $backups[0].FullName).Hash -eq (Get-FileHash -LiteralPath (Join-Path $fixtureRoot 'runtime\config.json')).Hash) 'Failed rebuild restores the exact previously verified config rather than retaining its new candidate'
                $latched=Get-Content -LiteralPath (Join-Path $fixtureRoot 'latched.json') -Raw | ConvertFrom-Json
                Assert-Watcher ($latched.RecoveryFailures -eq 2 -and $null -eq $latched.Child -and $null -eq $latched.AdapterGuid) 'Circuit latch is persisted only after owned core/adapter cleanup'
            }
            'StartupFailure'{
                Assert-Watcher ($starts -eq 1 -and $events -notcontains 'Running' -and $events -contains 'RecoveryPaused') 'Startup DNS/HTTPS failure never reports Running and zero recovery budget prevents restart'
                Assert-Watcher ([IO.File]::ReadAllText((Join-Path $fixtureRoot 'runtime\config.json')) -ceq $oldBytes) 'Failed first startup restores the previous configuration exact bytes'
                Assert-Watcher ($log -match 'rolled back after owned TUN teardown') 'Startup rollback occurs after safe owned teardown'
            }
        }
    }

    # Exercise the actual emergency-stop entry point using the last isolated
    # fixture; PID/start-time/command identity and termination are all mocked.
    $state.Owner=[pscustomobject]@{Id=51001;Path='C:\Fixture\powershell.exe';StartFileTime='1'}
    $state.Child=[pscustomobject]@{Id=51002;Path='C:\Fixture\fake-core.exe';StartFileTime='1'}
    $state.Status='Running';$state.AdapterGuid='22222222-2222-2222-2222-222222222222'
    Save-Fixture (Join-Path $fixtureRoot 'runtime\state.json') ($state | ConvertTo-Json -Depth 12)
    $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Emergency' -f (Join-Path $fixtureRoot 'Stop-Bridge.ps1')
    $process=Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $fixtureRoot 'stop-stdout.log') -RedirectStandardError (Join-Path $fixtureRoot 'stop-stderr.log')
    $null=$process.Handle
    if(-not $process.WaitForExit(15000)){throw 'Mock emergency stop timed out.'}
    Assert-Watcher ($process.ExitCode -eq 0) ('Emergency entry point succeeds: '+(Get-Content -LiteralPath (Join-Path $fixtureRoot 'stop-stderr.log') -Raw))
    Assert-Watcher ((Test-Path (Join-Path $fixtureRoot 'kill-51001.txt')) -and (Test-Path (Join-Path $fixtureRoot 'kill-51002.txt'))) 'Emergency stop requests verified termination for owner and core'
    $state=Get-Content -LiteralPath (Join-Path $fixtureRoot 'runtime\state.json') -Raw | ConvertFrom-Json
    Assert-Watcher ($state.Status -eq 'Stopped' -and $null -eq $state.AdapterGuid -and $null -eq $state.Child) 'Emergency cleanup persists clean stopped state'
    $cleanupBefore=Get-FixtureLineCount (Join-Path $fixtureRoot 'cleanup.txt')
    $startsBefore=Get-FixtureLineCount (Join-Path $fixtureRoot 'starts.txt')
    $state.Root='C:\Fixture\UnrelatedInstallation'
    Save-Fixture (Join-Path $fixtureRoot 'runtime\state.json') ($state | ConvertTo-Json -Depth 12)
    $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Watch -SingBoxPath "{1}"' -f (Join-Path $fixtureRoot 'Start-Bridge.ps1'),(Join-Path $fixtureRoot 'fake-core.cmd')
    $process=Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $fixtureRoot 'mismatch-stdout.log') -RedirectStandardError (Join-Path $fixtureRoot 'mismatch-stderr.log')
    $null=$process.Handle
    if(-not $process.WaitForExit(15000)){throw 'Ownership mismatch fixture timed out.'}
    Assert-Watcher ($process.ExitCode -ne 0 -and (Get-Content -LiteralPath (Join-Path $fixtureRoot 'mismatch-stderr.log') -Raw) -match 'Previous ownership state mismatch') 'Start rejects previous state belonging to another installation'
    Assert-Watcher ((Get-FixtureLineCount (Join-Path $fixtureRoot 'cleanup.txt')) -eq $cleanupBefore -and (Get-FixtureLineCount (Join-Path $fixtureRoot 'starts.txt')) -eq $startsBefore) 'Ownership mismatch performs neither network cleanup nor core start'
    Write-Host ('Watcher integration passed: {0} checks across seven scenarios plus emergency stop. All network/core operations mocked.' -f $checks)
}finally{
    if($process -and -not $process.HasExited){$process.Kill();$process.WaitForExit()}
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if($resolved.StartsWith(($runtimeBase.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^watcher-tests-[a-f0-9]{32}$'){
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
