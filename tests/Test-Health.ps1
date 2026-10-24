#requires -Version 5.1
# Unit tests use byte fixtures and mock DNS/HTTPS/network boundaries. The only
# real child processes are a local argument/timeout fixture; no live probe runs.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$healthModule=Import-Module (Join-Path $root 'src\Health.psm1') -Force -PassThru
$runtimeBase=[IO.Path]::GetFullPath((Join-Path $root 'runtime'))
$testRoot=Join-Path $runtimeBase ('health-tests-'+[guid]::NewGuid().ToString('N'))
$checks=0
function Assert-Health {param([bool]$Condition,[string]$Message) if(-not $Condition){throw ('Health assertion failed: '+$Message)};$script:checks++;Write-Host ('PASS: '+$Message)}
function New-DnsFixture {
    param([int]$Id=1201,[string]$Name='p2t-test.example.com',[switch]$NxDomain)
    [byte[]]$packet=New-P2TDnsQuery -TransactionId $Id -Name $Name
    $packet[2]=129;$packet[3]=128
    if($NxDomain){
        $packet[3]=131;$packet[9]=1
        # Compressed owner, SOA, two root names, then five 32-bit SOA values.
        [byte[]]$record=@(192,12,0,6,0,1,0,0,0,30,0,22,0,0)+(New-Object byte[] 20)
    }else{$packet[7]=1;[byte[]]$record=@(192,12,0,1,0,1,0,0,0,30,0,4,1,1,1,1)}
    return ,([byte[]]($packet+$record))
}
try{
    $null=New-Item -ItemType Directory -Path $testRoot -Force
    $success=ConvertFrom-P2THttpsProbe -ExitCode 0 -Output '204|0.400'
    Assert-Health ($success.TransportSuccess -and $success.ServiceSuccess -and $success.Classification -eq 'HttpSuccess') 'HTTP 204 proves both transport and service success'
    $challenge=ConvertFrom-P2THttpsProbe -ExitCode 0 -Output '403|0.400' -Headers "HTTP/2 403`r`nserver: cloudflare`r`ncf-mitigated: challenge`r`n"
    Assert-Health ($challenge.TransportSuccess -and -not $challenge.ServiceSuccess -and $challenge.Classification -eq 'CloudflareChallenge') 'Verified Cloudflare challenge 403 at 0.4s is a service challenge with working transport'
    $plain403=ConvertFrom-P2THttpsProbe -ExitCode 0 -Output '403|0.400' -Headers "server: cloudflare`r`n"
    Assert-Health ($plain403.TransportSuccess -and $plain403.Classification -eq 'HttpServiceError') 'Cloudflare server header alone does not prove a challenge'
    $cert=ConvertFrom-P2THttpsProbe -ExitCode 60 -Output '403|0.400' -Headers 'cf-mitigated: challenge'
    Assert-Health (-not $cert.TransportSuccess -and $cert.Classification -eq 'TlsValidationError') 'Certificate failure cannot be accepted as an HTTP challenge'
    $reset=ConvertFrom-P2THttpsProbe -ExitCode 56 -Output '000|0.400'
    Assert-Health (-not $reset.TransportSuccess -and $reset.Classification -eq 'NetworkError') 'HTTP 000/reset is a transport failure'
    Assert-Health ((ConvertFrom-P2THttpsProbe -ExitCode 28 -Output '000|8.0').Classification -eq 'Timeout') 'curl timeout has a distinct diagnostic'
    Assert-Health ((ConvertFrom-P2THttpsProbe -ExitCode -1 -TimedOut $true).Classification -eq 'Timeout') 'Outer process deadline is classified as timeout'
    Assert-Health (-not (ConvertFrom-P2THttpsProbe -ExitCode 0 -Output 'not-a-result').TransportSuccess) 'Malformed curl output cannot prove transport'
    Assert-Health ((ConvertFrom-P2THttpsProbe -ExitCode 0 -Output '503|0.1').TransportSuccess) 'Origin HTTP 503 does not cause a network restart'

    [byte[]]$positive=New-DnsFixture
    [byte[]]$negative=New-DnsFixture -NxDomain
    Assert-Health ((Test-P2TDnsResponse -Message $positive -TransactionId 1201 -Name 'p2t-test.example.com').Classification -eq 'FreshDnsPositive') 'Fresh DNS accepts matching compressed A answer'
    Assert-Health ((Test-P2TDnsResponse -Message $negative -TransactionId 1201 -Name 'p2t-test.example.com').Classification -eq 'FreshDnsNxDomain') 'Fresh unique DNS accepts a valid SOA-backed NXDOMAIN'
    Assert-Health (-not (Test-P2TDnsResponse -Message $positive -TransactionId 1202 -Name 'p2t-test.example.com').Success) 'Fresh DNS rejects mismatched transaction ID'
    Assert-Health (-not (Test-P2TDnsResponse -Message $positive -TransactionId 1201 -Name 'different.example.com').Success) 'Fresh DNS rejects mismatched question name'
    [byte[]]$bad=$positive.Clone();$bad[2]=1
    Assert-Health (-not (Test-P2TDnsResponse -Message $bad -TransactionId 1201 -Name 'p2t-test.example.com').Success) 'Fresh DNS rejects packets without QR response flag'
    [byte[]]$bad=$positive.Clone();$bad[2]=131
    Assert-Health (-not (Test-P2TDnsResponse -Message $bad -TransactionId 1201 -Name 'p2t-test.example.com').Success) 'Fresh DNS rejects truncated replies'
    [byte[]]$bad=$positive.Clone();$bad[3]=130
    Assert-Health (-not (Test-P2TDnsResponse -Message $bad -TransactionId 1201 -Name 'p2t-test.example.com').Success) 'Fresh DNS rejects SERVFAIL'
    [byte[]]$bad=$positive.Clone();$bad[12]=192;$bad[13]=12
    Assert-Health (-not (Test-P2TDnsResponse -Message $bad -TransactionId 1201 -Name 'p2t-test.example.com').Success) 'Fresh DNS rejects cyclic compression pointers within a finite bound'
    [byte[]]$bad=$negative[0..($negative.Length-2)]
    Assert-Health (-not (Test-P2TDnsResponse -Message $bad -TransactionId 1201 -Name 'p2t-test.example.com').Success) 'Fresh DNS rejects truncated SOA data'
    [byte[]]$bad=New-P2TDnsQuery -TransactionId 1201 -Name 'p2t-test.example.com';$bad[2]=129;$bad[3]=131
    Assert-Health (-not (Test-P2TDnsResponse -Message $bad -TransactionId 1201 -Name 'p2t-test.example.com').Success) 'NXDOMAIN without an authority SOA does not pass'

    $now=[datetime]'2026-10-24T00:00:00Z'
    $recovery=New-P2TRecoveryState
    foreach($delay in @(10,20,40)){
        Register-P2TRecoveryFailure -State $recovery -Reason 'FixtureFailure' -Now $now
        Assert-Health (-not $recovery.Latched -and $recovery.DelaySeconds -eq $delay -and $recovery.RetryAt -eq $now.AddSeconds($delay)) ('Recovery backoff is '+$delay+' seconds')
    }
    Register-P2TRecoveryFailure -State $recovery -Reason 'FixtureFailure' -Now $now
    Assert-Health ($recovery.Latched -and $recovery.Failures -eq 4) 'Initial start plus three rebuilds exhausts and latches the default budget'
    Register-P2TRecoverySuccess -State $recovery -Now $now.AddDays(1)
    Assert-Health ($recovery.Latched) 'A circuit latch never silently resets'
    $recovery=New-P2TRecoveryState
    Register-P2TRecoveryFailure -State $recovery -Reason 'FixtureFailure' -Now $now -MaxAttempts 10 -BaseSeconds 100
    Register-P2TRecoveryFailure -State $recovery -Reason 'FixtureFailure' -Now $now -MaxAttempts 10 -BaseSeconds 100
    Assert-Health ($recovery.DelaySeconds -eq 120) 'Recovery delay has a 120 second cap'
    Register-P2TRecoverySuccess -State $recovery -Now $now
    Register-P2TRecoverySuccess -State $recovery -Now $now.AddSeconds(299)
    Assert-Health ($recovery.Failures -eq 2) 'Short healthy runs do not replenish the recovery budget'
    Register-P2TRecoverySuccess -State $recovery -Now $now.AddSeconds(300)
    Assert-Health ($recovery.Failures -eq 0) 'Five minutes of proven healthy operation replenishes the budget'

    $a=[pscustomobject]@{Valid=$true;Available=$true;Fingerprint='wifi-a'}
    $b=[pscustomobject]@{Valid=$true;Available=$true;Fingerprint='ethernet-b'}
    $invalid=[pscustomobject]@{Valid=$false;Available=$false;Fingerprint=''}
    $network=New-P2TNetworkObservation -Snapshot $a -Now $now
    Assert-Health (-not (Update-P2TNetworkObservation -State $network -Snapshot $b -Now $now.AddSeconds(1))) 'A new network fingerprint starts debounce without rebuilding'
    Assert-Health (-not (Update-P2TNetworkObservation -State $network -Snapshot $a -Now $now.AddSeconds(2))) 'A transient switch returning to baseline cancels debounce'
    $null=Update-P2TNetworkObservation -State $network -Snapshot $b -Now $now.AddSeconds(3)
    Assert-Health (-not (Update-P2TNetworkObservation -State $network -Snapshot $b -Now $now.AddSeconds(8))) 'Stable switch waits the full debounce period'
    Assert-Health (Update-P2TNetworkObservation -State $network -Snapshot $b -Now $now.AddSeconds(9)) 'Stable Wi-Fi/Ethernet switch emits one change after six seconds'
    Assert-Health (-not (Update-P2TNetworkObservation -State $network -Snapshot $b -Now $now.AddSeconds(20))) 'An unchanged network does not emit repeated switches'
    Assert-Health (-not (Update-P2TNetworkObservation -State $network -Snapshot $invalid -Now $now.AddSeconds(21))) 'Inspection failure does not trigger a network restart'

    # Compile a local fixture to verify quoting, proxy-environment removal and
    # deadline termination without invoking any external network program.
    $probeExe=Join-Path $testRoot 'process-fixture.exe'
    Add-Type -OutputAssembly $probeExe -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
public static class ProcessFixture {
 public static int Main(string[] args) {
  if(args.Length>0 && args[0]=="sleep") { File.WriteAllText(args[1],System.Diagnostics.Process.GetCurrentProcess().Id.ToString()); Thread.Sleep(10000); return 0; }
  foreach(string value in args) Console.Write(Convert.ToBase64String(Encoding.UTF8.GetBytes(value))+"|");
  Console.Write("PROXY="+(Environment.GetEnvironmentVariable("HTTP_PROXY")??""));
  return 0;
 }
}
'@
    $arguments=@('space value','quote"value','C:\path with space\','')
    $oldProxy=$env:HTTP_PROXY
    try{
        $env:HTTP_PROXY='http://fixture.invalid:1'
        $processResult=Invoke-P2TBoundedProcess -Path $probeExe -Arguments $arguments
    }finally{$env:HTTP_PROXY=$oldProxy}
    $expected=(@($arguments | ForEach-Object {[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_))}) -join '|')+'|PROXY='
    Assert-Health ($processResult.ExitCode -eq 0 -and $processResult.Output -eq $expected) 'Bounded native child preserves spaces, quotes, trailing slashes and empty argument while removing proxy environment'
    $pidPath=Join-Path $testRoot 'child.pid';$timer=[Diagnostics.Stopwatch]::StartNew()
    $processResult=Invoke-P2TBoundedProcess -Path $probeExe -Arguments @('sleep',$pidPath) -TimeoutMs 300
    $timer.Stop()
    Assert-Health ($processResult.TimedOut -and $timer.Elapsed.TotalSeconds -lt 4) 'Hung probe child is terminated within the outer deadline'
    $fixturePid=[int](Get-Content -LiteralPath $pidPath -Raw)
    Assert-Health (-not (Get-Process -Id $fixturePid -ErrorAction SilentlyContinue)) 'Timed-out probe leaves no owned child running'

    & $healthModule {
        $script:mode='challenge';$script:observedArguments=@();$script:observedPath='';$script:observedTimeout=0
        function script:Invoke-P2TBoundedProcess {
            param($Path,$Arguments,$TimeoutMs)
            $script:observedArguments=$Arguments;$script:observedPath=$Path;$script:observedTimeout=$TimeoutMs
            if($Arguments -contains '--dump-header'){
                $headerPath=$Arguments[[Array]::IndexOf($Arguments,'--dump-header')+1]
                [IO.File]::WriteAllText($headerPath,"HTTP/2 403`r`ncf-mitigated: challenge`r`n")
                return [pscustomobject]@{ExitCode=0;TimedOut=$false;Output='403|0.400'}
            }
            [pscustomobject]@{ExitCode=0;TimedOut=$false;Output='DNS_OK'}
        }
    }
    $result=Test-P2THttpsForwarding -RuntimePath $testRoot
    $observed=& $healthModule {[pscustomobject]@{Arguments=$script:observedArguments;Path=$script:observedPath;Timeout=$script:observedTimeout}}
    Assert-Health ($result.Classification -eq 'CloudflareChallenge' -and $observed.Arguments[0] -eq '-q') 'HTTPS probe disables curl user configuration before all other arguments'
    $proxyIndex=[Array]::IndexOf($observed.Arguments,'--proxy');$noProxyIndex=[Array]::IndexOf($observed.Arguments,'--noproxy')
    Assert-Health ($observed.Arguments[$proxyIndex+1] -eq '' -and $observed.Arguments[$noProxyIndex+1] -eq '*' -and $observed.Arguments -notcontains '--insecure') 'HTTPS probe bypasses system proxy and keeps certificate validation enabled'
    Assert-Health ($observed.Path -eq (Join-Path $env:SystemRoot 'System32\curl.exe') -and $observed.Timeout -eq 10000) 'HTTPS uses the Windows curl path and a bounded outer timeout'
    Assert-Health (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.headers').Count -eq 0) 'HTTPS response headers are cleaned from runtime after classification'
    Assert-Health ((Test-P2TSystemDns).Success) 'Positive OS DNS probe accepts only its fixed success marker'
    $observed=& $healthModule {[pscustomobject]@{Arguments=$script:observedArguments;Timeout=$script:observedTimeout}}
    Assert-Health ($observed.Timeout -eq 5000 -and $observed.Arguments -contains '-EncodedCommand') 'OS DNS check runs in a bounded child process'

    & $healthModule {
        $script:routePrefixes=@('0.0.0.0/1','128.0.0.0/1','::/1','8000::/1');$script:adapterStatus='Up';$script:adapterGuid='22222222-2222-2222-2222-222222222222'
        function script:Get-NetAdapter {param($Name,[switch]$IncludeHidden,$ErrorAction) [pscustomobject]@{Name=$Name;InterfaceGuid=[guid]$script:adapterGuid;Status=$script:adapterStatus;ifIndex=99}}
        function script:Get-NetRoute {param($InterfaceIndex,$ErrorAction) foreach($prefix in $script:routePrefixes){[pscustomobject]@{DestinationPrefix=$prefix}}}
    }
    $routeParams=@{InterfaceName='p2t-0123456789';AdapterGuid='22222222-2222-2222-2222-222222222222'}
    Assert-Health ((Test-P2TOwnedTunRoutes @routeParams).Success) 'Both split routes for each address family prove owned TUN coverage'
    & $healthModule {$script:routePrefixes=@('0.0.0.0/1','::/1')}
    Assert-Health (-not (Test-P2TOwnedTunRoutes @routeParams).Success) 'One split route per family cannot prove TUN coverage'
    & $healthModule {$script:routePrefixes=@('0.0.0.0/0','::/0')}
    Assert-Health ((Test-P2TOwnedTunRoutes @routeParams).Success) 'Owned default routes for both address families prove TUN coverage'
    & $healthModule {$script:adapterStatus='Down'}
    Assert-Health (-not (Test-P2TOwnedTunRoutes @routeParams).Success) 'A down TUN adapter cannot pass even with recorded routes'
    & $healthModule {$script:adapterStatus='Up';$script:adapterGuid='33333333-3333-3333-3333-333333333333'}
    Assert-Health (-not (Test-P2TOwnedTunRoutes @routeParams).Success) 'Adapter name reuse with a different GUID cannot pass ownership'

    & $healthModule {
        $script:fixtureDns='192.0.2.53';$script:fixtureGateway='192.0.2.1';$script:fixtureIp='192.0.2.2';$script:fixtureMetric=10;$script:fixtureUp=$true;$script:queriedIndexes=@()
        function script:Get-NetAdapter {
            param([switch]$Physical,$ErrorAction)
            [pscustomobject]@{Name='Wi-Fi';Status=$(if($script:fixtureUp){'Up'}else{'Down'});ifIndex=2;InterfaceGuid=[guid]'22222222-2222-2222-2222-222222222222'}
            [pscustomobject]@{Name='p2t-0123456789';Status='Up';ifIndex=9999;InterfaceGuid=[guid]'99999999-9999-9999-9999-999999999999'}
        }
        function script:Get-NetRoute {param($InterfaceIndex,$ErrorAction) $script:queriedIndexes+=$InterfaceIndex;[pscustomobject]@{DestinationPrefix='0.0.0.0/0';NextHop=$script:fixtureGateway;RouteMetric=0}}
        function script:Get-NetIPAddress {param($InterfaceIndex,$ErrorAction) [pscustomobject]@{IPAddress=$script:fixtureIp;PrefixLength=24}}
        function script:Get-DnsClientServerAddress {param($InterfaceIndex,$ErrorAction) [pscustomobject]@{AddressFamily=2;ServerAddresses=@($script:fixtureDns)}}
        function script:Get-NetIPInterface {param($InterfaceIndex,$ErrorAction) [pscustomobject]@{AddressFamily=2;InterfaceMetric=$script:fixtureMetric}}
    }
    $baseline=Get-P2TNetworkFingerprint -OwnedInterfaceName 'p2t-0123456789'
    Assert-Health ($baseline.Valid -and $baseline.Available -and $baseline.Fingerprint -match '^[A-F0-9]{64}$') 'Physical network fingerprint exposes only a digest and route availability'
    Assert-Health ((& $healthModule {$script:queriedIndexes -notcontains 9999})) 'Owned TUN is excluded from physical route fingerprint queries'
    & $healthModule {$script:fixtureDns='192.0.2.54'}
    Assert-Health ((Get-P2TNetworkFingerprint).Fingerprint -ne $baseline.Fingerprint) 'Physical DNS-server change alters the network fingerprint'
    & $healthModule {$script:fixtureDns='192.0.2.53';$script:fixtureGateway='192.0.2.254'}
    Assert-Health ((Get-P2TNetworkFingerprint).Fingerprint -ne $baseline.Fingerprint) 'Physical default gateway change alters the network fingerprint'
    & $healthModule {$script:fixtureGateway='192.0.2.1';$script:fixtureIp='192.0.2.3'}
    Assert-Health ((Get-P2TNetworkFingerprint).Fingerprint -ne $baseline.Fingerprint) 'Physical IP change alters the network fingerprint'
    & $healthModule {$script:fixtureIp='192.0.2.2';$script:fixtureMetric=20}
    Assert-Health ((Get-P2TNetworkFingerprint).Fingerprint -ne $baseline.Fingerprint) 'Route preference change alters the network fingerprint'
    & $healthModule {$script:fixtureUp=$false}
    Assert-Health (-not (Get-P2TNetworkFingerprint).Available) 'No up physical adapter cannot be reported as a usable default route'

    & $healthModule {
        $script:dnsGood=$true;$script:freshGood=$true;$script:httpsCalls=0;$script:firstHttpsGood=$false
        function script:Test-P2TSystemDns {[pscustomobject]@{Success=$script:dnsGood;Classification='FixtureDns'}}
        function script:Test-P2TFreshTunDns {[pscustomobject]@{Success=$script:freshGood;Classification='FixtureFreshDns'}}
        function script:Test-P2THttpsForwarding {param($RuntimePath,$Url) $script:httpsCalls++;[pscustomobject]@{TransportSuccess=($script:firstHttpsGood -or $script:httpsCalls%2 -eq 0);Classification='FixtureHttps';HttpStatus=204;CurlExitCode=0}}
    }
    Assert-Health ((Test-P2TForwardingHealth -RuntimePath $testRoot).Success) 'Independent second HTTPS origin can prove forwarding if the first origin fails'
    Assert-Health ((& $healthModule {$script:httpsCalls}) -eq 2) 'HTTPS fallback is limited to exactly one extra origin'
    & $healthModule {$script:freshGood=$false;$script:firstHttpsGood=$true}
    Assert-Health (-not (Test-P2TForwardingHealth -RuntimePath $testRoot).Success) 'Cached positive OS DNS plus HTTPS cannot mask a failed fresh TUN DNS query'
    Write-Host ('Health tests passed: {0} checks. No live network probes ran.' -f $checks)
}finally{
    Remove-Module $healthModule -Force -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if($resolved.StartsWith(($runtimeBase.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^health-tests-[a-f0-9]{32}$'){
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
