#requires -Version 5.1
[CmdletBinding()]
param([string]$SingBoxPath = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repository = Split-Path $PSScriptRoot -Parent
$discoveryModule=Import-Module (Join-Path $repository 'src\Discovery.psm1') -Force -PassThru
Import-Module (Join-Path $repository 'src\Config.psm1') -Force
if (-not ('P2TTests.ProbeServer' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'fixtures\ProbeServer.cs') }
$script:assertionCount = 0
function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw ('FAIL: '+$Message) }; $script:assertionCount++ }
function Assert-Throws { param([scriptblock]$Operation,[string]$Message) $threw=$false; try { & $Operation } catch {$threw=$true}; Assert-True $threw $Message }
function New-Candidate {
    param([int]$Owner = 100,[string]$Protocol='socks5',[int]$Port=10808,[string]$Source='Listener')
    [pscustomobject]@{Host='127.0.0.1';Port=$Port;Protocol=$Protocol;ProcessId=$Owner;ProcessName='v2ray.exe';ProcessPath='C:\Apps\Misty\core\v2ray.exe';ProcessStartTime='2026-09-29T00:00:00.0000000Z';ParentProcessId=99;ParentName='Misty.exe';ParentPath='C:\Apps\Misty\Misty.exe';ParentProcessStartTime='2026-09-28T00:00:00.0000000Z';Source=$Source;Priority=$(if($Source -eq 'SystemProxy'){0}else{100})}
}

$parsed = @(ConvertFrom-P2TSystemProxy 'http=127.0.0.1:10809;socks=localhost:10808;https=[::1]:7890;http=10.0.0.1:8080')
Assert-True ($parsed.Count -eq 3) 'System proxy parser keeps only loopback endpoints'
Assert-True ($parsed[1].Host -eq '127.0.0.1' -and $parsed[2].Host -eq '::1') 'localhost and bracketed IPv6 normalization'
Assert-True (@(ConvertFrom-P2TSystemProxy 'user:secret@127.0.0.1:8080;127.0.0.1:70000;file://example.pac').Count -eq 0) 'Credentials and invalid settings rejected'
Assert-True (@(ConvertFrom-P2TSystemProxy '').Count -eq 0) 'Empty system proxy supported'

foreach ($fixture in @('socks-ok','http-ok','http-fragmented','socks-auth','socks-denied','http-auth','web200','http-bad-tls','stall')) {
    $server = New-Object P2TTests.ProbeServer($fixture)
    try {
        $protocol = if ($fixture.StartsWith('socks')) {'socks5'} else {'http'}
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $probe = Test-P2TProxyEndpoint -ProxyHost 127.0.0.1 -ProxyPort $server.Port -Protocol $protocol -TimeoutMs 1500
        $elapsed = $timer.ElapsedMilliseconds
        $expected = $fixture -in @('socks-ok','http-ok','http-fragmented')
        Assert-True ($probe.Success -eq $expected) ('Probe fixture '+$fixture+' result: '+$probe.Reason)
        Assert-True ($elapsed -lt 3000) ('Probe deadline '+$fixture)
        if ($expected) { Assert-True ($server.Target -eq '1.1.1.1:443') 'CONNECT uses the declared IP target' }
    } finally { $server.Dispose() }
}
Assert-True (-not (Test-P2TProxyEndpoint -ProxyHost 10.0.0.1 -ProxyPort 80 -Protocol http).Success) 'Non-loopback probe refused'

# Ownership comes from the exact accepted connection, not Listen PID metadata.
$clientEndpoint=New-Object Net.IPEndPoint([Net.IPAddress]::Loopback,55001)
$serverEndpoint=New-Object Net.IPEndPoint([Net.IPAddress]::Loopback,10808)
$row=[pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=10808;RemoteAddress='127.0.0.1';RemotePort=55001;OwningProcess=100}
$zero=[pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=10808;RemoteAddress='127.0.0.1';RemotePort=55001;OwningProcess=0}
$conflict=[pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=10808;RemoteAddress='127.0.0.1';RemotePort=55001;OwningProcess=101}
$wrongPort=[pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=10808;RemoteAddress='127.0.0.1';RemotePort=55002;OwningProcess=101}
$wrongAddress=[pscustomobject]@{LocalAddress='127.0.0.2';LocalPort=10808;RemoteAddress='127.0.0.1';RemotePort=55001;OwningProcess=101}
$mapped=[pscustomobject]@{LocalAddress='::ffff:127.0.0.1';LocalPort=10808;RemoteAddress='::ffff:127.0.0.1';RemotePort=55001;OwningProcess=100}
$resolved=& $discoveryModule {param($r,$c,$s) Resolve-P2TConnectedOwnerId $r $c $s} @($row,$row,$zero,$wrongPort,$wrongAddress) $clientEndpoint $serverEndpoint
Assert-True ($resolved -eq 100) 'Exact server four-tuple deduplicates positive owner and ignores PID zero/unrelated sockets'
Assert-True ($null -eq (& $discoveryModule {param($r,$c,$s) Resolve-P2TConnectedOwnerId $r $c $s} @($zero) $clientEndpoint $serverEndpoint)) 'PID zero cannot establish proxy ownership'
Assert-True ($null -eq (& $discoveryModule {param($r,$c,$s) Resolve-P2TConnectedOwnerId $r $c $s} @($row,$conflict) $clientEndpoint $serverEndpoint)) 'Conflicting connected owners fail closed'
Assert-True ((& $discoveryModule {param($r,$c,$s) Resolve-P2TConnectedOwnerId $r $c $s} @($mapped) $clientEndpoint $serverEndpoint) -eq 100) 'IPv4-mapped connection addresses normalize to the same four-tuple'
$v6client=New-Object Net.IPEndPoint([Net.IPAddress]::IPv6Loopback,55001)
$v6server=New-Object Net.IPEndPoint([Net.IPAddress]::IPv6Loopback,10808)
$v6row=[pscustomobject]@{LocalAddress='::1';LocalPort=10808;RemoteAddress='::1';RemotePort=55001;OwningProcess=102}
Assert-True ((& $discoveryModule {param($r,$c,$s) Resolve-P2TConnectedOwnerId $r $c $s} @($v6row,$row) $v6client $v6server) -eq 102) 'IPv6 loopback ownership does not borrow an IPv4 endpoint owner'

# Real offline protocol exchange; mock only Windows process/connection metadata.
$identityFixture=New-Candidate
& $discoveryModule {
    param($identity)
    $script:identityFixture=$identity;$script:observedClient=$null
    function script:Get-P2TConnectedProcessIdentity {param($Client) $script:observedClient=$Client; if(-not $Client.Connected){throw 'Owner queried after connection closed.'};return $script:identityFixture}
} $identityFixture
$server=New-Object P2TTests.ProbeServer('socks-ok')
try {
    $probe=Test-P2TProxyEndpoint -ProxyHost 127.0.0.1 -ProxyPort $server.Port -Protocol socks5 -RequireIdentity
    Assert-True ($probe.Success -and $probe.Identity.ProcessId -eq 100) 'Successful protocol exchange can return identity from its still-open connection'
    $observedClient=& $discoveryModule {$script:observedClient}
    $disposed=$false;try{$null=$observedClient.GetStream()}catch{$disposed=$true}
    Assert-True $disposed 'Protocol probe releases the connection after ownership verification'
} finally {$server.Dispose()}
& $discoveryModule {$script:identityFixture=$null}
$server=New-Object P2TTests.ProbeServer('http-ok')
try {
    $probe=Test-P2TProxyEndpoint -ProxyHost 127.0.0.1 -ProxyPort $server.Port -Protocol http -RequireIdentity
    Assert-True (-not $probe.Success -and $probe.Reason -like 'ListenerMetadataUnknown:*') 'Working protocol with unknown connected owner is rejected explicitly'
} finally {$server.Dispose()}
$discoveryModule=Import-Module (Join-Path $repository 'src\Discovery.psm1') -Force -PassThru

# Exercise the production connection-to-CIM chain using a real local socket
# and synthetic Windows metadata, including a Unicode executable directory.
$server=New-Object P2TTests.ProbeServer('socks-ok')
$client=$null
try {
    $client=& $discoveryModule {param($port) Connect-P2TLoopbackClient -ProxyHost 127.0.0.1 -ProxyPort $port -TimeoutMs 1500} $server.Port
    $local=$client.Client.LocalEndPoint;$remote=$client.Client.RemoteEndPoint
    $tuple=[pscustomobject]@{LocalAddress=$remote.Address.ToString();LocalPort=$remote.Port;RemoteAddress=$local.Address.ToString();RemotePort=$local.Port;OwningProcess=100}
    $unicodeInstall='E:\'+[char]0x5DE5+[char]0x5177+'\Misty'
    & $discoveryModule {
        param($row,$directory)
        $script:connectionRows=@($row);$script:cimQueries=0;$script:observedState=''
        $script:processFixture=[pscustomobject]@{ProcessId=100;Name='v2ray.exe';ExecutablePath=($directory+'\core\v2ray.exe');CreationDate=[datetime]'2026-09-29T00:00:00Z';ParentProcessId=99}
        $script:parentFixture=[pscustomobject]@{ProcessId=99;Name='Misty.exe';ExecutablePath=($directory+'\Misty.exe');CreationDate=[datetime]'2026-09-28T00:00:00Z';ParentProcessId=1}
        function script:Get-NetTCPConnection {[CmdletBinding()]param($State) $script:observedState=$State;return $script:connectionRows}
        function script:Get-CimInstance {[CmdletBinding()]param($ClassName,$Filter) $script:cimQueries++;if($Filter -eq 'ProcessId = 100'){return $script:processFixture};if($Filter -eq 'ProcessId = 99'){return $script:parentFixture}}
    } $tuple $unicodeInstall
    $identity=& $discoveryModule {param($socket) Get-P2TConnectedProcessIdentity -Client $socket} $client
    Assert-True ($identity.ProcessId -eq 100 -and $identity.ProcessPath -eq ($unicodeInstall+'\core\v2ray.exe')) 'Connected-owner metadata reaches verified Unicode process identity'
    Assert-True ($identity.ParentPath -eq ($unicodeInstall+'\Misty.exe') -and [bool]$identity.ParentProcessStartTime) 'Connected owner retains the related-parent identity stamp'
    Assert-True ((& $discoveryModule {$script:observedState}) -eq 'Established') 'Owner lookup uses the whole Established table rather than endpoint filters'
    Assert-True $client.Connected 'Ownership lookup keeps its caller-owned connection open'
    $before=& $discoveryModule {$script:cimQueries}
    Assert-True ($null -eq (Get-P2TProcessIdentity -ProcessId 0) -and (& $discoveryModule {$script:cimQueries}) -eq $before) 'PID zero is rejected before querying Idle or any process metadata'
    & $discoveryModule {$script:connectionRows[0].OwningProcess=0}
    Assert-True ($null -eq (& $discoveryModule {param($socket) Get-P2TConnectedProcessIdentity -Client $socket} $client)) 'Unknown connected owner cannot become an arbitrary running process'
    Assert-True ((& $discoveryModule {$script:cimQueries}) -eq $before) 'Unknown socket ownership does not query guessed process IDs'
    & $discoveryModule {$script:connectionRows[0].OwningProcess=100;$script:processFixture.ExecutablePath='C:\Apps\sing-box.exe'}
    Assert-True ($null -eq (& $discoveryModule {param($socket) Get-P2TConnectedProcessIdentity -Client $socket} $client)) 'sing-box cannot be accepted as its own connected upstream'
} finally {if($client){$client.Dispose()};$server.Dispose()}
$discoveryModule=Import-Module (Join-Path $repository 'src\Discovery.psm1') -Force -PassThru

$socks = New-Candidate
$http = New-Candidate -Owner 101 -Protocol http -Port 10809 -Source SystemProxy
$http.ProcessPath='C:\Apps\Misty\core\v2ray_privoxy.exe'
$other = New-Candidate -Owner 200 -Port 7890
$other.ParentProcessId=199
Assert-True ($null -eq (Select-P2TProxyCandidate -Candidates @())) 'Empty selection returns null'
Assert-True ((Select-P2TProxyCandidate -Candidates @($http,$socks,$other)).Port -eq 10808) 'System proxy owner selected with SOCKS sibling preference'
Assert-True ((Select-P2TProxyCandidate -Candidates @($socks,$other) -ProxyPort 7890).ProcessId -eq 200) 'Explicit port disambiguates'
Assert-Throws { Select-P2TProxyCandidate -Candidates @($socks,$other) } 'Unrelated candidates require selection'
$other.Source='SystemProxy'
Assert-Throws { Select-P2TProxyCandidate -Candidates @($http,$other) } 'Conflicting system proxy owners require selection'
$shellSocks = New-Candidate; $shellSocks.ParentPath='C:\Windows\explorer.exe'; $shellSocks.ProcessPath='C:\Windows\CoreA.exe'
$shellHttp = New-Candidate -Owner 101 -Protocol http -Port 10809; $shellHttp.ParentPath='C:\Windows\explorer.exe'; $shellHttp.ProcessPath='C:\Windows\CoreB.exe'
Assert-Throws { Select-P2TProxyCandidate -Candidates @($shellSocks,$shellHttp) } 'Generic launcher siblings remain unrelated'
$reusedParent = New-Candidate -Owner 101; $reusedParent.ParentProcessStartTime='2026-09-29T01:00:00.0000000Z'
Assert-Throws { Select-P2TProxyCandidate -Candidates @($socks,$reusedParent) } 'Parent PID reuse does not merge families'

$config = New-P2TSingBoxConfig -Candidate $socks -InterfaceName p2t-offline-test
Assert-True ($config.inbounds[0].address.Count -eq 2) 'IPv4 and IPv6 TUN addresses present'
Assert-True ($config.route.auto_detect_interface) 'Physical interface auto detection enabled'
Assert-True ($config.route.rules[0].process_path -contains $socks.ProcessPath) 'Exact upstream path bypassed'
Assert-True ($config.route.rules[0].process_path -contains $socks.ParentPath) 'Related application parent bypassed'
Assert-True (-not $config.inbounds[0].strict_route -and $config.inbounds[0].dns_mode -eq 'hijack') 'Windows TUN DNS interception enabled explicitly'
Assert-True ($config.route.rules[1].port[0] -eq 53 -and $config.route.rules[1].action -eq 'hijack-dns') 'DNS hijack precedes UDP rejection and private-IP bypass'
Assert-True (@($config.route.rules | Where-Object { $_.Contains('process_path') -and ($_.process_path -match 'svchost.exe') }).Count -eq 0) 'Default configuration does not bypass shared Windows application DNS'
Assert-True ($config.dns.servers[0].detour -eq 'upstream' -and $config.dns.servers[0].server -eq '1.1.1.1') 'Remote DoH uses upstream without domain bootstrap'
Assert-True ($config.dns.servers[0].type -eq 'https' -and $config.dns.servers[0].path -eq '/dns-query' -and $config.dns.servers[0].server_port -eq 443 -and $config.dns.servers[0].tls.enabled -and $config.dns.servers[0].tls.server_name -eq 'cloudflare-dns.com') 'DoH has literal bootstrap IP and verified TLS identity'
Assert-True ($config.dns.strategy -eq 'ipv4_only') 'Working IPv4-only DNS policy retained'
Assert-True ($config.route.rules[2].network -contains 'udp' -and $config.route.rules[2].network -contains 'icmp' -and $config.route.rules[2].action -eq 'reject') 'Unsupported general UDP and ICMP rejected after DNS hijack'
$bootstrapConfig = New-P2TSingBoxConfig -Candidate $socks -InterfaceName p2t-bootstrap-test -AllowSystemDnsBootstrap
Assert-True ($bootstrapConfig.inbounds[0].dns_mode -eq 'hijack' -and $bootstrapConfig.route.rules[1].outbound -eq 'direct' -and $bootstrapConfig.route.rules[1].port[0] -eq 53 -and $bootstrapConfig.route.rules[1].process_path[0].EndsWith('\System32\svchost.exe')) 'Shared Windows DNS bypass requires explicit compatibility opt-in'
$httpConfig = New-P2TSingBoxConfig -Candidate $http -InterfaceName p2t-http-test
Assert-True ($httpConfig.outbounds[0].type -eq 'http' -and $httpConfig.outbounds[0].server_port -eq 10809 -and $httpConfig.dns.servers[0].detour -eq $httpConfig.outbounds[0].tag) 'Generic HTTP upstream dynamically supplies DoH detour'
$ipv6Candidate = New-Candidate -Port 7890; $ipv6Candidate.Host='::1'
$ipv6Config = New-P2TSingBoxConfig -Candidate $ipv6Candidate -InterfaceName p2t-ipv6-proxy
Assert-True ($ipv6Config.outbounds[0].server -eq '::1' -and $ipv6Config.outbounds[0].server_port -eq 7890) 'Discovered IPv6 loopback and custom port are retained'
$generic = New-Candidate; $generic.ParentPath='C:\Windows\explorer.exe'; $generic.ParentName='explorer.exe'
Assert-True (@(Get-P2TDirectProcessPaths $generic).Count -eq 1) 'Generic Explorer parent is not bypassed'
$unrelated = New-Candidate; $unrelated.ParentPath='C:\Unrelated\OtherApp.exe'
Assert-True (@(Get-P2TDirectProcessPaths $unrelated).Count -eq 1) 'Unrelated app parent is not bypassed'
$missing = New-Candidate; $missing.ProcessPath=''
Assert-Throws { New-P2TSingBoxConfig -Candidate $missing -InterfaceName p2t-test } 'Missing process path fails closed'
$self = New-Candidate; $self.ProcessPath='C:\Apps\sing-box.exe'
Assert-Throws { New-P2TSingBoxConfig -Candidate $self -InterfaceName p2t-test } 'sing-box loopback upstream rejected'
$sharedHost = New-Candidate; $sharedHost.ProcessPath='C:\Windows\System32\svchost.exe'
Assert-Throws { New-P2TSingBoxConfig -Candidate $sharedHost -InterfaceName p2t-test } 'Shared DNS service host cannot become a broad upstream bypass'
Assert-Throws { New-P2TSingBoxConfig -Candidate $socks -InterfaceName Ethernet } 'Unowned adapter name rejected'
Assert-Throws { New-P2TSingBoxConfig -Candidate $socks -InterfaceName p2t-test -ExtraDirectProcessPath 'relative.exe' } 'Relative helper bypass rejected'
$extraExe = (Get-Process -Id $PID).Path
$extraConfig = New-P2TSingBoxConfig -Candidate $socks -InterfaceName p2t-test -ExtraDirectProcessPath $extraExe
Assert-True ($extraConfig.route.rules[0].process_path -contains $extraExe) 'Explicit existing helper path is accepted'

$temporaryConfig = [IO.Path]::GetTempFileName()
try {
    Write-P2TSingBoxConfig -Config $config -Path $temporaryConfig
    $bytes = [IO.File]::ReadAllBytes($temporaryConfig)
    Assert-True (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Config JSON has no UTF-8 BOM'
    $decoded = Get-Content -LiteralPath $temporaryConfig -Raw | ConvertFrom-Json
    Assert-True ($decoded.outbounds[0].type -eq 'socks' -and $decoded.outbounds[0].version -eq '5') 'SOCKS config JSON round trip'
    $unicodeCandidate=New-Candidate
    $unicodeDirectory='E:\'+[char]0x5DE5+[char]0x5177+'\Misty'
    $unicodeCandidate.ProcessPath=$unicodeDirectory+'\core\v2ray.exe'
    $unicodeCandidate.ParentPath=$unicodeDirectory+'\Misty.exe'
    Write-P2TSingBoxConfig -Config (New-P2TSingBoxConfig -Candidate $unicodeCandidate -InterfaceName p2t-unicode-test) -Path $temporaryConfig
    $unicodeDecoded=Get-Content -LiteralPath $temporaryConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($unicodeDecoded.route.rules[0].process_path -contains $unicodeCandidate.ProcessPath -and $unicodeDecoded.route.rules[0].process_path -contains $unicodeCandidate.ParentPath) 'Non-system-drive Unicode process paths survive UTF-8 configuration round trip'
    Write-P2TSingBoxConfig -Config $config -Path $temporaryConfig
    if ($SingBoxPath) {
        & $SingBoxPath check -c $temporaryConfig
        Assert-True ($LASTEXITCODE -eq 0) 'Official sing-box accepts SOCKS configuration'
        Write-P2TSingBoxConfig -Config (New-P2TSingBoxConfig -Candidate $http -InterfaceName p2t-http-test) -Path $temporaryConfig
        & $SingBoxPath check -c $temporaryConfig
        Assert-True ($LASTEXITCODE -eq 0) 'Official sing-box accepts HTTP configuration'
        Write-P2TSingBoxConfig -Config $bootstrapConfig -Path $temporaryConfig
        & $SingBoxPath check -c $temporaryConfig
        Assert-True ($LASTEXITCODE -eq 0) 'Official sing-box accepts explicit bootstrap compatibility configuration'
    }
} finally { Remove-Item -LiteralPath $temporaryConfig -Force }

# Windows discovery fixtures verify filtering without touching real listeners.
& $discoveryModule {
    param($identity)
    $script:discoveryIdentity=$identity;$script:systemEndpoints=@();$script:listenerRows=@();$script:listenCalls=0
    $script:probeCalls=New-Object 'Collections.Generic.List[string]';$script:protocols=@{};$script:unknownOwner=$false;$script:throwListen=$false
    function script:Get-P2TSystemProxyEndpoints {return $script:systemEndpoints}
    function script:Get-NetTCPConnection {param($State,$ErrorAction) $script:listenCalls++;if($script:throwListen){throw 'Fixture listener table unavailable.'};return $script:listenerRows}
    function script:Test-P2TProxyEndpoint {
        param($ProxyHost,$ProxyPort,$Protocol,$TimeoutMs,$ProbeAddress,$ProbePort,[switch]$RequireIdentity)
        if(-not $RequireIdentity){throw 'Discovery omitted connected-owner verification.'}
        $script:probeCalls.Add(('{0}|{1}|{2}' -f $ProxyHost,$ProxyPort,$Protocol))
        $ok=$script:protocols.ContainsKey([int]$ProxyPort) -and $script:protocols[[int]$ProxyPort] -eq $Protocol
        [pscustomobject]@{Success=$ok;Identity=$(if($ok -and -not $script:unknownOwner){$script:discoveryIdentity}else{$null});Reason='Fixture'}
    }
} (New-Candidate)
& $discoveryModule {$script:throwListen=$true;$script:protocols=@{32123='http'}}
$found=@(Get-P2TProxyCandidates -ProxyHost localhost -ProxyPort 32123 -ProxyProtocol http)
$observed=& $discoveryModule {[pscustomobject]@{ListenCalls=$script:listenCalls;Calls=@($script:probeCalls.ToArray())}}
Assert-True ($found.Count -eq 1 -and $found[0].Host -eq '127.0.0.1' -and $found[0].Source -eq 'Explicit') 'Explicit endpoint is probed even without any listener-table entry'
Assert-True ($observed.ListenCalls -eq 0 -and $observed.Calls.Count -eq 1 -and $observed.Calls[0] -eq '127.0.0.1|32123|http') 'Explicit host/port/protocol avoid unrelated scans and protocol probes'
Assert-Throws {Get-P2TProxyCandidates -ProxyHost 10.0.0.1 -ProxyPort 32123} 'Explicit remote proxy cannot enter discovery'
& $discoveryModule {
    $script:throwListen=$false;$script:listenCalls=0;$script:probeCalls.Clear();$script:protocols=@{10808='socks5';10809='http'}
    $script:systemEndpoints=@([pscustomobject]@{Host='127.0.0.1';Port=10809})
    $script:listenerRows=@(
        [pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=10808;OwningProcess=100},
        [pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=10808;OwningProcess=0},
        [pscustomobject]@{LocalAddress='0.0.0.0';LocalPort=10808;OwningProcess=0}
    )
}
$found=@(Get-P2TProxyCandidates)
$observed=& $discoveryModule {@($script:probeCalls.ToArray())}
Assert-True ($found.Count -eq 2 -and @($found | Where-Object {$_.Source -eq 'SystemProxy' -and $_.Port -eq 10809}).Count -eq 1) 'Known system endpoint remains discoverable when Listen omits it'
Assert-True (@($found | Where-Object {$_.Port -eq 10808 -and $_.ProcessId -eq 100}).Count -eq 1) 'Duplicate and PID-zero listener rows cannot overwrite actual connected owner'
Assert-True ($observed.Count -eq 4) 'Duplicate wildcard/listener endpoints are probed only once per protocol'
& $discoveryModule {$script:unknownOwner=$true;$script:probeCalls.Clear()}
Assert-True (@(Get-P2TProxyCandidates -ProxyHost 127.0.0.1 -ProxyPort 10808 -ProxyProtocol socks5).Count -eq 0) 'Successful handshake alone cannot bypass an unknown process identity'
& $discoveryModule {$script:unknownOwner=$false;$script:probeCalls.Clear()}
$found=@(Get-P2TProxyCandidates -ProxyPort 10808 -ProxyProtocol socks5)
Assert-True ($found.Count -eq 1 -and (& $discoveryModule {$script:probeCalls.Count}) -eq 1) 'Partial port/protocol filters also avoid probing unrelated endpoints'
& $discoveryModule {$script:throwListen=$true}
Assert-True (@(Get-P2TProxyCandidates -ProxyProtocol http).Count -eq 1) 'Unavailable listener table does not hide a verified system-proxy endpoint'
$discoveryModule=Import-Module (Join-Path $repository 'src\Discovery.psm1') -Force -PassThru

# Revalidation compares the owner of a fresh connected socket to the stored
# PID/path/start token; process existence by itself is never enough.
$identityFixture=New-Candidate
& $discoveryModule {
    param($identity)
    $script:identityFixture=$identity;$script:observedClients=New-Object 'Collections.Generic.List[object]'
    function script:Get-P2TConnectedProcessIdentity {param($Client) $script:observedClients.Add($Client);return $script:identityFixture}
} $identityFixture
$server=New-Object P2TTests.ProbeServer('socks-ok')
try {
    $candidate=New-Candidate -Port $server.Port
    Assert-True (Test-P2TProcessIdentity $candidate) 'Stored identity is reverified on an actual connected socket'
    & $discoveryModule {$script:identityFixture.ProcessId=101}
    Assert-True (-not (Test-P2TProcessIdentity $candidate)) 'Endpoint rebound to another process is rejected'
    & $discoveryModule {$script:identityFixture.ProcessId=100;$script:identityFixture.ProcessPath='C:\Other\v2ray.exe'}
    Assert-True (-not (Test-P2TProcessIdentity $candidate)) 'Changed connected process path is rejected'
    & $discoveryModule {$script:identityFixture.ProcessPath='C:\Apps\Misty\core\v2ray.exe';$script:identityFixture.ProcessStartTime='2026-09-30T00:00:00.0000000Z'}
    Assert-True (-not (Test-P2TProcessIdentity $candidate)) 'Reused endpoint owner PID with different start time is rejected'
    & $discoveryModule {$script:identityFixture.ProcessStartTime='2026-09-29T00:00:00.0000000Z';$script:identityFixture.ParentProcessStartTime='2026-09-30T00:00:00.0000000Z'}
    Assert-True (-not (Test-P2TProcessIdentity $candidate)) 'Changed related-parent identity is rejected'
    & $discoveryModule {$script:identityFixture=$null}
    Assert-True (-not (Test-P2TProcessIdentity $candidate)) 'Unknown current socket owner fails revalidation'
    $disposedCount=0
    foreach($client in (& $discoveryModule {$script:observedClients.ToArray()})) {try{$null=$client.GetStream()}catch{$disposedCount++}}
    Assert-True ($disposedCount -eq 6) 'All identity revalidation paths release their probe clients'
    & $discoveryModule {function script:Connect-P2TLoopbackClient {param($ProxyHost,$ProxyPort,$TimeoutMs) throw 'Connect timed out.'}}
    Assert-True (-not (Test-P2TProcessIdentity $candidate)) 'Unreachable endpoint cannot pass identity revalidation'
} finally {$server.Dispose()}
$discoveryModule=Import-Module (Join-Path $repository 'src\Discovery.psm1') -Force -PassThru
Write-Host ('PASS: {0} discovery/config assertions on PowerShell {1}. Offline fixtures do not validate a live TUN.' -f $script:assertionCount,$PSVersionTable.PSVersion)
