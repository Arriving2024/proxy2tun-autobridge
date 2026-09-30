#requires -Version 5.1
# Runs unmodified entry-point scripts against isolated mock modules and a fake
# core. No sing-box, adapter, route, registry, admin, or real kill operation runs.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot=Join-Path $tempBase ('p2t-watcher-'+[guid]::NewGuid().ToString('N'))
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$process=$null; $checks=0
function Assert-Watcher { param([bool]$Condition,[string]$Message) if(-not $Condition){throw ('Watcher assertion failed: '+$Message)}; $script:checks++; Write-Host ('PASS: '+$Message) }
function Save-Fixture { param([string]$Path,[string]$Content) [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false))) }
try {
    $null=New-Item -ItemType Directory -Path (Join-Path $testRoot 'src') -Force
    $null=New-Item -ItemType Directory -Path (Join-Path $testRoot 'runtime') -Force
    foreach($name in @('Start-Bridge.ps1','Stop-Bridge.ps1')){Copy-Item -LiteralPath (Join-Path $repository $name) -Destination (Join-Path $testRoot $name)}
    Copy-Item -LiteralPath (Join-Path $repository 'src\Config.psm1') -Destination (Join-Path $testRoot 'src\Config.psm1')
    Assert-Watcher ((Get-FileHash (Join-Path $testRoot 'Start-Bridge.ps1')).Hash -eq (Get-FileHash (Join-Path $repository 'Start-Bridge.ps1')).Hash) 'Fixture executes the unchanged watcher entry point'
    Save-Fixture (Join-Path $testRoot 'fake-core.cmd') @'
@echo off
if "%1"=="version" echo sing-box version 1.14.2
exit /b 0
'@
    Save-Fixture (Join-Path $testRoot 'src\Discovery.psm1') @'
Set-StrictMode -Version Latest
$script:scans=0; $script:probes=0
function Get-P2TProxyCandidates {
    $script:scans++
    if($script:scans -eq 1){return}
    [pscustomobject]@{Host='127.0.0.1';Port=10808;Protocol='socks5';ProcessId=4242;ProcessName='fixture.exe';ProcessPath='C:\Fixture\fixture.exe';ProcessStartTime='2026-09-29T00:00:00.0000000Z';ParentProcessId=0;ParentName='';ParentPath='';ParentProcessStartTime='';Source='Listener';Priority=100}
}
function Select-P2TProxyCandidate { param($Candidates,$ProxyHost,$ProxyPort,$ProxyProtocol) $Candidates | Select-Object -First 1 }
function Test-P2TProcessIdentity { param($Candidate) return $true }
function Test-P2TProxyEndpoint { param($ProxyHost,$Port,$Protocol) $script:probes++; [pscustomobject]@{Success=($script:probes -le 1)} }
Export-ModuleMember -Function *-P2T*
'@
    Save-Fixture (Join-Path $testRoot 'src\Lifecycle.psm1') @'
Set-StrictMode -Version Latest
$script:root=Split-Path $PSScriptRoot -Parent
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
  public OwnedProcess(string executable,string arguments,string directory){Root=directory; Active=true; Starts++; File.AppendAllText(Path.Combine(Root,"starts.txt"),"start\n");}
  public bool StopGracefully(int milliseconds){if(Active) File.AppendAllText(Path.Combine(Root,"stops.txt"),"stop\n"); Active=false; return true;}
  public void Dispose(){Active=false;}
  public static bool StopVerified(int id,long stamp,string path){File.WriteAllText(Path.Combine(Root,"kill-"+id+".txt"),"mock verified stop"); return true;}
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
    if($State.Status -eq 'Running' -and [Proxy2Tun.OwnedProcess]::Starts -ge 2){[IO.File]::WriteAllText((Join-Path $script:root 'runtime\stop.request'),'fixture stop')}
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
function Get-NetAdapter {param($Name,[switch]$IncludeHidden,$ErrorAction) if([Proxy2Tun.OwnedProcess]::Active){[pscustomobject]@{Name=$Name;InterfaceGuid=[guid]'22222222-2222-2222-2222-222222222222';ifIndex=9999}}}
function Get-NetRoute {param($InterfaceIndex,$ErrorAction) foreach($prefix in @('0.0.0.0/1','128.0.0.0/1','::/1','8000::/1')){[pscustomobject]@{DestinationPrefix=$prefix}}}
function Get-CimInstance {param($ClassName,$Filter) $command=if($Filter -match '51001'){Join-Path $script:root 'Start-Bridge.ps1'}else{Join-Path $script:root 'runtime\config.json'}; [pscustomobject]@{CommandLine=$command}}
Export-ModuleMember -Function *
'@
    $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Watch -SingBoxPath "{1}" -PollSeconds 1 -LossThreshold 2' -f (Join-Path $testRoot 'Start-Bridge.ps1'),(Join-Path $testRoot 'fake-core.cmd')
    $process=Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $testRoot 'stdout.log') -RedirectStandardError (Join-Path $testRoot 'stderr.log')
    $null=$process.Handle
    if(-not $process.WaitForExit(45000)){throw 'Mock watcher timed out.'}
    Assert-Watcher ($process.ExitCode -eq 0) ('Mock watcher exits successfully (exit='+$process.ExitCode+'): '+(Get-Content -LiteralPath (Join-Path $testRoot 'stderr.log') -Raw))
    $events=@(Get-Content -LiteralPath (Join-Path $testRoot 'events.txt'))
    $state=Get-Content -LiteralPath (Join-Path $testRoot 'runtime\state.json') -Raw|ConvertFrom-Json
    Assert-Watcher ($events[0] -eq 'Waiting') 'Missing upstream leaves the watcher waiting'
    Assert-Watcher (@($events|Where-Object{$_ -eq 'Running'}).Count -eq 2) 'Upstream appearance starts the TUN fixture and later reappearance restarts it'
    Assert-Watcher (@(Get-Content -LiteralPath (Join-Path $testRoot 'starts.txt')).Count -eq 2) 'Exactly two owned core fixtures are created'
    Assert-Watcher (@(Get-Content -LiteralPath (Join-Path $testRoot 'stops.txt')).Count -eq 2) 'Probe loss and final stop each release the owned core'
    Assert-Watcher ((Get-Content -LiteralPath (Join-Path $testRoot 'runtime\bridge.log') -Raw) -match 'Upstream disappeared') 'Probe-loss teardown is recorded in visible logs'
    Assert-Watcher ($state.Status -eq 'Stopped' -and $null -eq $state.Child -and $null -eq $state.AdapterGuid) 'Stop request leaves a clean stopped state'

    # Exercise the actual emergency-stop entry point with fake identities and
    # fake verified termination; native crash cleanup has its separate test.
    $state.Owner=[pscustomobject]@{Id=51001;Path='C:\Fixture\powershell.exe';StartFileTime='1'}
    $state.Child=[pscustomobject]@{Id=51002;Path='C:\Fixture\fake-core.exe';StartFileTime='1'}
    $state.Status='Running';$state.AdapterGuid='22222222-2222-2222-2222-222222222222'
    Save-Fixture (Join-Path $testRoot 'runtime\state.json') ($state|ConvertTo-Json -Depth 12)
    $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Emergency' -f (Join-Path $testRoot 'Stop-Bridge.ps1')
    $process=Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $testRoot 'stop-stdout.log') -RedirectStandardError (Join-Path $testRoot 'stop-stderr.log')
    $null=$process.Handle
    if(-not $process.WaitForExit(15000)){throw 'Mock emergency stop timed out.'}
    Assert-Watcher ($process.ExitCode -eq 0) ('Emergency entry point succeeds: '+(Get-Content -LiteralPath (Join-Path $testRoot 'stop-stderr.log') -Raw))
    Assert-Watcher ((Test-Path (Join-Path $testRoot 'kill-51001.txt')) -and (Test-Path (Join-Path $testRoot 'kill-51002.txt'))) 'Emergency stop requests verified termination for owner and core'
    $state=Get-Content -LiteralPath (Join-Path $testRoot 'runtime\state.json') -Raw|ConvertFrom-Json
    Assert-Watcher ($state.Status -eq 'Stopped' -and $null -eq $state.AdapterGuid -and $null -eq $state.Child) 'Emergency cleanup persists the stopped state'
    Write-Host ('Watcher integration passed: {0} checks. All network and core operations were mocked.' -f $checks)
} finally {
    if($process -and -not $process.HasExited){$process.Kill();$process.WaitForExit()}
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if($resolved.StartsWith(($tempBase.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^p2t-watcher-[a-f0-9]{32}$'){
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
