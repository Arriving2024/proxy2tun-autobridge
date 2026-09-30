#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Detect','Generate','Watch')][string]$Mode = 'Watch',
    [string]$SingBoxPath,
    [string]$ProxyEndpoint,
    [string[]]$ExtraDirectProcessPath = @(),
    [ValidateRange(1,60)][int]$PollSeconds = 3,
    [ValidateRange(1,10)][int]$LossThreshold = 2
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $SingBoxPath) { $SingBoxPath = Join-Path $PSScriptRoot 'bin\sing-box.exe' }
Import-Module (Join-Path $PSScriptRoot 'src\Discovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src\Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src\Lifecycle.psm1') -Force
if (-not [Environment]::Is64BitProcess -or $env:OS -ne 'Windows_NT') { throw 'Use 64-bit Windows PowerShell on Windows 11 x64.' }
$selection = @{}
if ($ProxyEndpoint) {
    $endpoint = [uri]$ProxyEndpoint
    if ($endpoint.Scheme -notin @('socks5','http') -or $endpoint.Host -notin @('127.0.0.1','localhost','[::1]','::1') -or $endpoint.Port -lt 1 -or $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment -or $endpoint.AbsolutePath -notin @('','/')) {
        throw 'Use a no-auth loopback endpoint, e.g. socks5://127.0.0.1:10808. Credentials and remote endpoints are unsupported.'
    }
    $selection = @{ ProxyHost = $endpoint.Host.Trim('[',']'); ProxyPort = $endpoint.Port; ProxyProtocol = $endpoint.Scheme }
    if ($selection.ProxyHost -eq 'localhost') { $selection.ProxyHost = '127.0.0.1' }
}
if ($Mode -eq 'Detect') {
    Get-P2TProxyCandidates | Format-Table Protocol,Host,Port,ProcessId,ProcessName,ParentName,Source -AutoSize
    return
}
if (-not (Test-Path -LiteralPath $SingBoxPath -PathType Leaf)) { throw 'sing-box.exe missing. Run install.ps1 or provide -SingBoxPath.' }
$SingBoxPath = (Resolve-Path -LiteralPath $SingBoxPath).Path
$version = (& $SingBoxPath version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $version -notmatch 'sing-box version 1\.14\.2(?:\s|$)') { throw 'This release requires sing-box 1.14.2. Run install.ps1 for the pinned official dependency.' }
$runtime = Join-Path $PSScriptRoot 'runtime'
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
$configPath = Join-Path $runtime 'config.json'
if ($Mode -eq 'Generate') {
    $candidate = Select-P2TProxyCandidate -Candidates @(Get-P2TProxyCandidates) @selection
    if (-not $candidate) { throw 'No compatible proxy detected. Start your proxy client and retry.' }
    $config = New-P2TSingBoxConfig -Candidate $candidate -InterfaceName ('p2t-' + [guid]::NewGuid().ToString('N').Substring(0,10)) -ExtraDirectProcessPath $ExtraDirectProcessPath
    Write-P2TSingBoxConfig -Config $config -Path (Join-Path $runtime 'preview.json')
    & $SingBoxPath check -c (Join-Path $runtime 'preview.json')
    if ($LASTEXITCODE -ne 0) { throw 'sing-box configuration validation failed.' }
    Write-Host 'Preview written to runtime\preview.json; syntax checked. No network changes.'
    return
}
if (-not (Test-P2TAdministrator)) { throw 'Watch needs administrator rights. Right-click Start-Bridge.cmd and choose Run as administrator.' }
Initialize-P2TNative
$mutex = New-Object Threading.Mutex($false, 'Global\Proxy2TUN.AutoBridge.v1')
$locked = $false; $child = $null; $state = $null; $lockFile = $null; $logReader = $null
$statePath = Join-Path $runtime 'state.json'
$logPath = Join-Path $runtime 'bridge.log'
$stopPath = Join-Path $runtime 'stop.request'
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another AutoBridge watcher is running. Stop it from its own installation first.' }
    $lockFile = [IO.File]::Open((Join-Path $runtime 'watcher.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    if (Test-Path -LiteralPath $statePath) {
        $oldState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($oldState.Child -and (Test-P2TStamp $oldState.Child)) { throw 'Previous owned core is still running. Run Stop-Bridge.ps1 -Emergency first.' }
        Remove-P2TOwnedNetwork -State $oldState
    }
    if (Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue) { throw 'An existing sing-box is running. Stop the other TUN through its own controls before starting AutoBridge.' }
    Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
    $state = [ordered]@{ Schema=1; Root=$PSScriptRoot; Owner=(Get-P2TProcessStamp $PID); Child=$null; InterfaceName=$null; AdapterGuid=$null; Status='Waiting' }
    Write-P2TState -State $state -Path $statePath
    Write-P2TLog -Path $logPath -Message 'Proxy2TUN AutoBridge v0.1.0. Waiting for a compatible local proxy. Ctrl+C or Stop-Bridge stops the watcher.'
    $candidate = $null; $misses = 0; $retryAt = [DateTime]::MinValue; $lastNotice = ''; $scanAt = [DateTime]::MinValue
    while (-not (Test-Path -LiteralPath $stopPath)) {
        if ($logReader) {
            while ($null -ne ($line = $logReader.ReadLine())) { Write-Host ('[sing-box] ' + $line) }
        }
        if ([DateTime]::UtcNow -lt $scanAt) { Start-Sleep -Milliseconds 200; continue }
        $scanAt = [DateTime]::UtcNow.AddSeconds($PollSeconds)
        if ($child) {
            $healthy = (-not $child.HasExited) -and (Test-P2TProcessIdentity -Candidate $candidate)
            if ($healthy) {
                $probe = Test-P2TProxyEndpoint -ProxyHost $candidate.Host -Port $candidate.Port -Protocol $candidate.Protocol
                $healthy = $probe.Success
            }
            if ($healthy) { $misses = 0 } else { $misses++ }
            if ($child.HasExited -or $misses -ge $LossThreshold) {
                Write-P2TLog -Path $logPath -Message 'Upstream disappeared, failed its probe, changed identity, or core exited. Releasing TUN.'
                Stop-P2TOwnedChild -Child $child -State $state -StatePath $statePath -LogPath $logPath
                $child = $null; $candidate = $null; $misses = 0; $retryAt = [DateTime]::UtcNow.AddSeconds(10)
                if ($logReader) { $logReader.Dispose(); $logReader=$null }
            }
            continue
        }
        if ([DateTime]::UtcNow -lt $retryAt) { continue }
        try {
            $candidate = Select-P2TProxyCandidate -Candidates @(Get-P2TProxyCandidates) @selection
            if (-not $candidate) { continue }
            if (-not (Test-P2TProcessIdentity -Candidate $candidate)) { continue }
            if (Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue) { throw 'Another sing-box appeared. Waiting for it to stop.' }
            $state.InterfaceName = 'p2t-' + [guid]::NewGuid().ToString('N').Substring(0,10)
            if (Get-NetAdapter -Name $state.InterfaceName -IncludeHidden -ErrorAction SilentlyContinue) { throw 'Generated adapter name already exists.' }
            $coreLog = Join-Path $runtime ('core-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '.log')
            $config = New-P2TSingBoxConfig -Candidate $candidate -InterfaceName $state.InterfaceName -LogPath $coreLog -ExtraDirectProcessPath $ExtraDirectProcessPath
            Write-P2TSingBoxConfig -Config $config -Path $configPath
            $check = (& $SingBoxPath check -c $configPath 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) { throw ('Config check failed: ' + $check.Trim()) }
            if (Test-Path -LiteralPath $stopPath) { break }
            if (-not (Test-P2TProcessIdentity -Candidate $candidate)) { continue }
            $state.Status='Starting'; Write-P2TState -State $state -Path $statePath
            $child = New-Object Proxy2Tun.OwnedProcess($SingBoxPath, ('run -c "' + $configPath + '"'), (Split-Path $SingBoxPath))
            $state.Child = [ordered]@{ Id=$child.Id; Path=$SingBoxPath; StartFileTime=$child.StartFileTime.ToString() }
            Write-P2TState -State $state -Path $statePath
            $readyUntil = [DateTime]::UtcNow.AddSeconds(12); $adapter = $null; $routes = @(); $routes6 = @()
            while (-not $child.HasExited -and [DateTime]::UtcNow -lt $readyUntil -and -not (Test-Path -LiteralPath $stopPath)) {
                $adapter = Get-NetAdapter -Name $state.InterfaceName -IncludeHidden -ErrorAction SilentlyContinue
                if ($adapter) {
                    $state.AdapterGuid=$adapter.InterfaceGuid.ToString(); Write-P2TState -State $state -Path $statePath
                    $routes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/1','0.0.0.0/0','128.0.0.0/1') })
                    $routes6 = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -in @('::/1','::/0','8000::/1') })
                    if ($routes.Count -gt 0 -and $routes6.Count -gt 0) { break }
                }
                Start-Sleep -Milliseconds 250
            }
            if (-not $adapter -or $child.HasExited -or -not $state.AdapterGuid -or $routes.Count -eq 0 -or $routes6.Count -eq 0) { throw 'TUN did not become ready for IPv4 and IPv6. See runtime core log.' }
            $state.Status='Running'; Write-P2TState -State $state -Path $statePath
            Write-P2TLog -Path $logPath -Message ('TUN ready: {0} -> {1}://{2}:{3}, owner {4}, parent {5}. TCP mode; system DNS may use DIRECT.' -f $state.InterfaceName,$candidate.Protocol,$candidate.Host,$candidate.Port,$candidate.ProcessName,$candidate.ParentName)
            if (Test-Path -LiteralPath $coreLog) { $logReader=New-Object IO.StreamReader([IO.File]::Open($coreLog,'Open','Read','ReadWrite')) }
            $lastNotice=''
        } catch {
            if ($child) { Stop-P2TOwnedChild -Child $child -State $state -StatePath $statePath -LogPath $logPath; $child=$null }
            if ($_.Exception.Message -ne $lastNotice) { $lastNotice=$_.Exception.Message; Write-P2TLog -Path $logPath -Message ('Waiting: ' + $lastNotice) }
            $retryAt = [DateTime]::UtcNow.AddSeconds(10)
        }
    }
} finally {
    if ($logReader) { $logReader.Dispose() }
    try { if ($state) { Stop-P2TOwnedChild -Child $child -State $state -StatePath $statePath -LogPath $logPath; $state.Status='Stopped'; Write-P2TState -State $state -Path $statePath } }
    finally { if ($child) { $child.Dispose() }; if ($lockFile) { $lockFile.Dispose() }; if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
