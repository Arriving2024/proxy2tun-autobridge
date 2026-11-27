#requires -Version 5.1
# Offline desktop contract checks; only a disposable hidden PowerShell fixture runs.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\Discovery.psm1') -Force
Import-Module (Join-Path $root 'src\Desktop.psm1') -Force -DisableNameChecking
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch=Join-Path $tempBase ('p2t-desktop-tests-'+[guid]::NewGuid().ToString('N'))
$runtime=Join-Path $scratch 'runtime'
$null=New-Item -ItemType Directory -Path $runtime -Force
$checks=0;$owned=$null
function Assert-Desktop([bool]$Condition,[string]$Message){if(-not $Condition){throw ('Desktop assertion failed: '+$Message)};$script:checks++;Write-Host ('PASS: '+$Message)}
function Read-Status {Get-Content -LiteralPath (Join-Path $runtime 'desktop-status.json') -Raw -Encoding UTF8|ConvertFrom-Json}
function Save-Choice([string]$Text){[IO.File]::WriteAllText((Join-Path $runtime 'desktop-choice.json'),$Text,[Text.UTF8Encoding]::new($false))}
function New-Candidate([string]$App='Alpha',[string]$Core='core.exe',[int]$OwnerId=100,[int]$ParentId=90,[string]$Protocol='socks5',[int]$Port=10808,[string]$Address='127.0.0.1'){
    [pscustomobject]@{Host=$Address;Port=$Port;Protocol=$Protocol;ProcessId=$OwnerId;ProcessName=$Core;ProcessPath=('C:\Fixture\'+$App+'\'+$Core);ProcessStartTime='2026-11-02T00:00:01.0000000Z';ParentProcessId=$ParentId;ParentName=($App+'.exe');ParentPath=('C:\Fixture\'+$App+'\'+$App+'.exe');ParentProcessStartTime='2026-11-02T00:00:00.0000000Z';Source='Listener';Priority=100}
}
try{
    $socks=New-Candidate
    $http=New-Candidate -Core 'http.exe' -OwnerId 101 -Protocol http -Port 10809
    $same=@(Get-P2TDesktopChoices -Candidates @($http,$socks))
    Assert-Desktop ($same.Count -eq 1 -and $same[0].Candidate.Protocol -eq 'socks5') 'Verified same-app HTTP and SOCKS endpoints form one choice with SOCKS preferred.'
    Assert-Desktop ($same[0].Key -cmatch '^[a-f0-9]{64}$') 'Choice is represented by an opaque stable SHA-256 key.'
    $selected=Select-P2TDesktopCandidate -Candidates @($http,$socks) -RuntimePath $runtime
    Assert-Desktop ($selected.ProcessId -eq $socks.ProcessId) 'Real cross-module single-app selection binds without prompting.'
    $beta=New-Candidate -App Beta -OwnerId 200 -ParentId 190 -Port 7890
    $options=@(Get-P2TDesktopChoices -Candidates @($socks,$beta))
    Assert-Desktop ($options.Count -eq 2 -and $options[0].Key -cne $options[1].Key) 'Independent apps remain distinct choices.'
    $selected=Select-P2TDesktopCandidate -Candidates @($socks,$beta) -RuntimePath $runtime
    $status=Read-Status
    Assert-Desktop ($null -eq $selected -and $status.Status -eq 'ChoiceRequired' -and $status.Candidates.Count -eq 2) 'Ambiguous apps request a choice instead of binding an arbitrary proxy.'
    Assert-Desktop (@($status.Candidates[0].PSObject.Properties.Name).Count -eq 3 -and -not ($status|ConvertTo-Json -Depth 6).Contains('C:\\Fixture')) 'Choice UI contains public labels/endpoints and no process paths or identities.'
    $betaKey=($options|Where-Object {$_.Candidate.ProcessId -eq 200}).Key
    Save-Choice (@{Key=$betaKey}|ConvertTo-Json)
    $selected=Select-P2TDesktopCandidate -Candidates @($socks,$beta) -RuntimePath $runtime
    Assert-Desktop ($selected.ProcessId -eq 200) 'A matching submitted choice selects only that verified app.'
    $restarted=New-Candidate -App Beta -OwnerId 300 -ParentId 290 -Port 7890
    $restarted.ParentProcessStartTime='2026-11-02T01:00:00.0000000Z'
    $restarted.ProcessStartTime='2026-11-02T01:00:01.0000000Z'
    $restartedKey=@(Get-P2TDesktopChoices -Candidates @($restarted))[0].Key
    Assert-Desktop ($restartedKey -ceq $betaKey) 'An app restarting at the same verified installation retains the submitted choice key.'
    $selected=Select-P2TDesktopCandidate -Candidates @($socks,$restarted) -RuntimePath $runtime
    Assert-Desktop ($selected.ProcessId -eq 300) 'Remembered app choice follows the new verified owner, not the stale PID.'
    Save-Choice (@{Key=('0'*64)}|ConvertTo-Json)
    Assert-Desktop ($null -eq (Select-P2TDesktopCandidate -Candidates @($socks,$beta) -RuntimePath $runtime) -and (Read-Status).Status -eq 'ChoiceRequired') 'Stale selection keys never authorize another app.'
    Save-Choice ('x'*9000)
    Assert-Desktop ($null -eq (Select-P2TDesktopCandidate -Candidates @($socks,$beta) -RuntimePath $runtime)) 'Oversized choice data is ignored safely.'
    Save-Choice '{broken'
    Assert-Desktop ($null -eq (Select-P2TDesktopCandidate -Candidates @($socks,$beta) -RuntimePath $runtime)) 'Malformed choice JSON remains a choice request.'
    Assert-Desktop ((Get-P2TDesktopEndpoint (New-Candidate -Address '::1')) -eq 'socks5://[::1]:10808') 'IPv6 loopback endpoints preserve required URI brackets.'
    $null=Select-P2TDesktopCandidate -Candidates @() -RuntimePath $runtime
    Assert-Desktop ((Read-Status).Status -eq 'WaitingForProxy' -and (Read-Status).Candidates.Count -eq 0) 'No available proxy waits without claiming a connection.'
    $state=[ordered]@{Status='Running';LastHealthPassed=$false;ProxyDisplayName='Alpha';ProxyEndpoint='socks5://127.0.0.1:10808'}
    Sync-P2TDesktopStatus -State $state -RuntimePath $runtime
    Assert-Desktop ((Read-Status).Status -eq 'Verifying') 'Failed fresh health turns the desktop status into verification, not a green connection.'
    $state.LastHealthPassed=$true
    Sync-P2TDesktopStatus -State $state -RuntimePath $runtime
    Assert-Desktop ((Read-Status).Status -eq 'Running' -and (Read-Status).SelectedDisplayName -eq 'Alpha') 'Successful watcher health publishes the bound app and endpoint.'
    $shared=[IO.File]::Open((Join-Path $runtime 'desktop-status.json'),[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try{Write-P2TDesktopStatus -RuntimePath $runtime -Status 'Backoff' -Message 'fixture'}finally{$shared.Dispose()}
    Assert-Desktop ((Read-Status).Status -eq 'Backoff') 'Atomic state replacement succeeds while a shared GUI reader has the prior file open.'
    $state.Status='RecoveryPaused';Sync-P2TDesktopStatus -State $state -RuntimePath $runtime
    Assert-Desktop ((Read-Status).Status -eq 'RecoveryPaused') 'Recovery exhaustion remains a distinct actionable desktop state.'
    $bin=Join-Path $scratch 'bin';$null=New-Item -ItemType Directory -Path $bin
    $fake=Join-Path $bin 'sing-box.exe';[IO.File]::WriteAllText($fake,'fixture-not-an-executable')
    $before=(Get-FileHash -LiteralPath $fake).Hash;$failure=''
    try{Ensure-P2TDesktopDependency -Root $scratch -RuntimePath $runtime|Out-Null}catch{$failure=$_.Exception.Message}
    Assert-Desktop ($failure -like 'DependencyHashMismatch:*' -and (Get-FileHash -LiteralPath $fake).Hash -eq $before) 'A changed existing dependency is rejected intact before execution or any download.'

    Copy-Item -LiteralPath (Join-Path $root 'Show-Logs.ps1'),(Join-Path $root 'VERSION') -Destination $scratch
    $fixtureEvents=@(
        '2026-11-08 10:35:37 Network change observed; checking current forwarding.'
        '2026-11-08 10:35:39 Network recheck passed; current TUN retained.'
        '2026-11-08 10:35:45 TUN stopped: reason=StopRequested; graceful=False; owned adapter cleanup completed.'
        '2026-11-08 10:35:46 Dependency check: DependencyDownloadFailed: ProtocolError; HTTP=503'
        '2026-11-08 10:35:47 Scan: candidates=2; elapsedMs=74000'
        '2026-11-08 10:35:48 Upstream check: ProxyConnectionRefused'
        '2026-11-08 10:35:49 TUN ready: p2t-ba5eba11ab; socks5 upstream; DNS and certificate-validated HTTPS passed. HTTP service errors/challenges do not trigger a transport restart.'
        '2026-11-08 10:35:50 Unrecognized line: C:\Users\Private\secret.txt, https://personal.example'
        '2026-11-08 10:35:51 Scan: candidates=2; elapsedMs=700; https://personal.example'
    )
    [IO.File]::WriteAllLines((Join-Path $runtime 'bridge.log'),$fixtureEvents)
    [IO.File]::WriteAllText((Join-Path $runtime 'config.json'),'PrivateFixtureConfig')
    [IO.File]::WriteAllText((Join-Path $runtime 'core-fixture.log'),'PrivateFixtureCore')
    $summary=(& (Join-Path $scratch 'Show-Logs.ps1') -Summary) -join "`n"
    foreach($line in $fixtureEvents[0..5]){
        Assert-Desktop ($summary.Contains($line)) 'Shareable diagnostic includes the known controller event.'
    }
    Assert-Desktop ($summary.Contains('TUN ready; upstream=socks5;') -and
        $summary -notmatch 'ba5eba11ab|Private|personal\.example') 'Shareable diagnostic omits adapter IDs, unknown fields, raw config and traffic.'

    Import-Module (Join-Path $root 'src\Lifecycle.psm1') -Force
    Initialize-P2TNative
    $ready=Join-Path $scratch 'hidden-ready.txt'
    $fixture=Join-Path $scratch 'hidden.ps1'
    $source=@'
param([string]$ReadyPath)
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class P2TDesktopConsoleFixture{[DllImport("kernel32.dll")]public static extern IntPtr GetConsoleWindow();}'
[IO.File]::WriteAllText($ReadyPath,[P2TDesktopConsoleFixture]::GetConsoleWindow().ToInt64().ToString())
Start-Sleep -Seconds 30
'@
    [IO.File]::WriteAllText($fixture,$source,[Text.UTF8Encoding]::new($false))
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ReadyPath "{1}"' -f $fixture,$ready
    $owned=New-Object Proxy2Tun.OwnedProcess($powershell,$arguments,$scratch,$true)
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    while(-not (Test-Path -LiteralPath $ready) -and -not $owned.HasExited -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
    Assert-Desktop ((Test-Path -LiteralPath $ready) -and [IO.File]::ReadAllText($ready) -eq '0') 'The real hidden native-process overload gives its fixture no console window.'
    $owned.Dispose()
    Assert-Desktop ($owned.HasExited) 'Disposing the hidden fixture releases its exact owned child.'
    $owned=$null
    Write-Host ('Desktop contracts passed: {0} checks; no real proxy, network change or TUN.' -f $checks)
}finally{
    if($owned){$owned.Dispose()}
    $resolved=[IO.Path]::GetFullPath($scratch)
    if($resolved.StartsWith(($tempBase.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^p2t-desktop-tests-[a-f0-9]{32}$'){
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
