#requires -Version 5.1
[CmdletBinding()]
param([switch]$Core,[switch]$Summary)
$path=Join-Path $PSScriptRoot 'runtime\bridge.log'
if($Summary){
    if($Core){throw 'Choose either -Summary or -Core.'}
    $version=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
    if($version -notmatch '^\d{1,4}\.\d{1,4}\.\d{1,4}$'){throw 'Invalid version.'}
    'Proxy2TUN AutoBridge v'+$version+' diagnostic summary'
    'Recent controller events. Timestamps use the local clock.'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ 'No controller log yet.';return }
    if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Refusing a linked log.'}
    # Select whole known messages. Never copy arbitrary log messages or use
    # replacements on raw configuration, shell output or core traffic logs.
    $upstream='UpstreamIdentityUnverified|ProxyConnectionRefused|ProxyConnectFailed|ProxyProtocolFailed|ProxyTlsProbeFailed|ProxyIdentityUnverified'
    $reason=$upstream+'|CoreExited|PhysicalNetworkChanged|UpstreamUnavailableOrIdentityChanged|OwnedTunAdapterUnavailable|OwnedTunRoutesMissing|OwnedTunInspectionFailed|TunAliveButForwardingFailed|AnotherCorePresent|AdapterNameCollision|UpstreamChangedBeforeStart|TunRoutesNotReady|StartupDnsOrHttpsVerificationFailed|StartupOrDiscoveryError|StartupFailed|StopRequested|WatcherExit'
    $patterns=@(
        'Proxy2TUN AutoBridge v\d{1,4}\.\d{1,4}\.\d{1,4}\. Watcher; DNS and HTTPS checks enabled\. Ctrl\+C or Stop-Bridge stops it\.'
        'Build: watcher SHA256=[a-fA-F0-9]{64}; core SHA256=[a-fA-F0-9]{64}'
        'Build: desktop SHA256=[a-fA-F0-9]{64}'
        'Scan: candidates=\d{1,8}; elapsedMs=\d{1,10}'
        'Network change observed; checking current forwarding\.'
        'Network recheck passed; current TUN retained\.'
        'Waiting for a stable physical default route\.'
        ('Upstream check: (?:'+$upstream+')')
        '(?:Startup|Forwarding) check: Dns(?:Success|Timeout|Error); FreshDns(?:NxDomain|NoData|Positive|InvalidResponse|SourceMismatch|Timeout|NetworkError|ProbeError); HTTPS (?:HttpSuccess|HttpServiceError|CloudflareChallenge|TlsValidationError|Timeout|NetworkError), HTTP \d{1,3}, curl -?\d{1,4}'
        ('Recovery \d{1,2}/\d{1,2}: (?:'+$reason+'); retry in \d{1,4}s\. Owned TUN released\.')
        ('Recovery paused after \d{1,2} consecutive failures \((?:'+$reason+')\)\. Owned TUN released\. Stop and start explicitly after checking runtime diagnostics\.')
        ('TUN stopped: reason=(?:'+$reason+'); graceful=(?:True|False); owned adapter cleanup completed\.')
        'Watcher ended: (?:StopRequested|WatcherExit)'
        'Forced cleanup requested: (?:EmergencyStop|StopWaitExpired)'
        'Dependency check: (?:DependencyDownload(?:Failed: [A-Za-z]{1,32}(?:; HTTP=[1-5][0-9]{2})?|CancelledOrTimedOut)|Dependency(?:ArchiveHash|ArchiveEntry|ExecutableHash)Mismatch|DependencyHashMismatch: existing binary was preserved\.|DependencyPreparationFailed)'
    )
    $known='^(?<time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (?:'+($patterns -join '|')+')$'
    foreach($line in (Get-Content -LiteralPath $path -Tail 300 -Encoding UTF8)){
        if($line -cmatch $known){$line}
        elseif($line -cmatch '^(?<time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) TUN ready: p2t-[a-f0-9]{10}; (?<protocol>http|socks5) upstream; DNS and certificate-validated HTTPS passed\. HTTP service errors/challenges do not trigger a transport restart\.$'){
            '{0} TUN ready; upstream={1}; DNS and TLS-validated HTTPS passed.' -f $Matches.time,$Matches.protocol
        }
    }
    return
}
if ($Core) { $item=Get-ChildItem (Join-Path $PSScriptRoot 'runtime\core-*.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($item) { $path=$item.FullName } }
if (-not (Test-Path -LiteralPath $path)) { Write-Host 'No log yet. Start AutoBridge first.'; return }
Get-Content -LiteralPath $path -Tail 40 -Wait
