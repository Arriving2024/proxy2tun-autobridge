#requires -Version 5.1
[CmdletBinding()]
param([string]$SingBoxPath = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repository = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repository 'src\Discovery.psm1') -Force
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
Assert-True (-not $config.inbounds[0].strict_route -and $config.inbounds[0].dns_mode -eq 'disabled') 'Conservative OS DNS bootstrap mode explicit'
Assert-True ($config.route.rules[1].port[0] -eq 53 -and $config.route.rules[1].outbound -eq 'direct') 'Windows DNS Client exception scoped to port 53'
Assert-True ($config.dns.servers[0].detour -eq 'upstream' -and $config.dns.servers[0].server -eq '1.1.1.1') 'Remote DoH uses upstream without domain bootstrap'
Assert-True ($config.route.rules[3].network -contains 'udp' -and $config.route.rules[3].network -contains 'icmp' -and $config.route.rules[3].action -eq 'reject') 'Unsupported general UDP and ICMP rejected'
$generic = New-Candidate; $generic.ParentPath='C:\Windows\explorer.exe'; $generic.ParentName='explorer.exe'
Assert-True (@(Get-P2TDirectProcessPaths $generic).Count -eq 1) 'Generic Explorer parent is not bypassed'
$unrelated = New-Candidate; $unrelated.ParentPath='C:\Unrelated\OtherApp.exe'
Assert-True (@(Get-P2TDirectProcessPaths $unrelated).Count -eq 1) 'Unrelated app parent is not bypassed'
$missing = New-Candidate; $missing.ProcessPath=''
Assert-Throws { New-P2TSingBoxConfig -Candidate $missing -InterfaceName p2t-test } 'Missing process path fails closed'
$self = New-Candidate; $self.ProcessPath='C:\Apps\sing-box.exe'
Assert-Throws { New-P2TSingBoxConfig -Candidate $self -InterfaceName p2t-test } 'sing-box loopback upstream rejected'
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
    if ($SingBoxPath) {
        & $SingBoxPath check -c $temporaryConfig
        Assert-True ($LASTEXITCODE -eq 0) 'Official sing-box accepts SOCKS configuration'
        Write-P2TSingBoxConfig -Config (New-P2TSingBoxConfig -Candidate $http -InterfaceName p2t-http-test) -Path $temporaryConfig
        & $SingBoxPath check -c $temporaryConfig
        Assert-True ($LASTEXITCODE -eq 0) 'Official sing-box accepts HTTP configuration'
    }
} finally { Remove-Item -LiteralPath $temporaryConfig -Force }
Write-Host ('PASS: {0} discovery/config assertions on PowerShell {1}. Offline fixtures do not validate a live TUN.' -f $script:assertionCount,$PSVersionTable.PSVersion)
