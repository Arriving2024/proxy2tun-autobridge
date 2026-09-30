#requires -Version 5.1
Set-StrictMode -Version 2.0

function ConvertFrom-P2TSystemProxy {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$ProxyServer)
    foreach ($part in ($ProxyServer -split ';')) {
        $value = $part.Trim()
        if (-not $value) { continue }
        $hint = 'auto'
        if ($value -match '^([^=]+)=(.+)$') { $hint = $Matches[1].ToLowerInvariant(); $value = $Matches[2] }
        if ($value -match '^(?:(?:https?|socks5?)://)?(\[[^\]]+\]|[^:/]+):(\d+)$') {
            $address = $Matches[1].Trim('[', ']'); $portNumber = [int]$Matches[2]
            if ($address -ieq 'localhost') { $address = '127.0.0.1' }
            $ipAddress = $null
            if ([Net.IPAddress]::TryParse($address, [ref]$ipAddress) -and [Net.IPAddress]::IsLoopback($ipAddress) -and $portNumber -ge 1 -and $portNumber -le 65535) {
                [pscustomobject]@{ Host = $address; Port = $portNumber; ProtocolHint = $hint; Source = 'SystemProxy' }
            }
        }
    }
}

function Get-P2TSystemProxyEndpoints {
    [CmdletBinding()]
    param()
    try {
        $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($settings.PSObject.Properties['ProxyEnable'] -and $settings.ProxyEnable -eq 1 -and $settings.PSObject.Properties['ProxyServer']) {
            ConvertFrom-P2TSystemProxy -ProxyServer $settings.ProxyServer
        }
        if ($settings.PSObject.Properties['AutoConfigURL'] -and $settings.AutoConfigURL) { Write-Verbose 'PAC URL detected; PAC evaluation is not supported.' }
    } catch { Write-Verbose ('System proxy unavailable: ' + $_.Exception.Message) }
}

function Get-P2TProcessIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        $process = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $ProcessId) -ErrorAction Stop
        if (-not $process -or -not $process.ExecutablePath -or -not $process.CreationDate) { return $null }
        $path = [IO.Path]::GetFullPath([string]$process.ExecutablePath)
        if ([IO.Path]::GetFileName($path) -ieq 'sing-box.exe') { return $null }
        $parent = $null
        if ($process.ParentProcessId -gt 0) {
            $parent = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $process.ParentProcessId) -ErrorAction SilentlyContinue
            # Windows can reuse the parent's PID after it exits.
            if ($parent -and $parent.CreationDate -gt $process.CreationDate) { $parent = $null }
        }
        [pscustomobject]@{
            ProcessId = [int]$process.ProcessId
            ProcessName = [string]$process.Name
            ProcessPath = $path
            ProcessStartTime = ([datetime]$process.CreationDate).ToUniversalTime().ToString('o')
            ParentProcessId = [int]$process.ParentProcessId
            ParentName = $(if ($parent) { [string]$parent.Name } else { '' })
            ParentPath = $(if ($parent -and $parent.ExecutablePath) { [string]$parent.ExecutablePath } else { '' })
            ParentProcessStartTime = $(if ($parent -and $parent.CreationDate) { ([datetime]$parent.CreationDate).ToUniversalTime().ToString('o') } else { '' })
        }
    } catch { Write-Verbose ('Process identity unavailable for PID {0}: {1}' -f $ProcessId, $_.Exception.Message); return $null }
}

function Read-P2TBytes {
    param([IO.Stream]$Stream, [int]$Count, [Diagnostics.Stopwatch]$Clock, [int]$TimeoutMs)
    $buffer = New-Object byte[] $Count
    $offset = 0
    while ($offset -lt $Count) {
        $remaining = $TimeoutMs - [int]$Clock.ElapsedMilliseconds
        if ($remaining -le 0) { throw 'Probe timed out.' }
        $Stream.ReadTimeout = $remaining
        $read = $Stream.Read($buffer, $offset, $Count - $offset)
        if ($read -le 0) { throw 'Peer closed the connection.' }
        $offset += $read
    }
    return ,$buffer
}

function Test-P2TTlsServerHello {
    param([IO.Stream]$Stream, [Diagnostics.Stopwatch]$Clock, [int]$TimeoutMs)
    # A TLS 1.2 ClientHello: no application payload, credentials or user domains.
    $random = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($random) } finally { $rng.Dispose() }
    [byte[]]$body = @(3,3) + $random + @(0,0,18,192,47,192,43,204,168,204,169,0,156,0,157,0,47,0,53,0,255,1,0) +
        @(0,26,0,10,0,6,0,4,0,23,0,24,0,11,0,2,1,0,0,13,0,6,0,4,4,1,4,3)
    [byte[]]$handshake = @(1,0,0,[byte]$body.Length) + $body
    [byte[]]$hello = @(22,3,1,0,[byte]$handshake.Length) + $handshake
    $Stream.Write($hello, 0, $hello.Length)
    $record = Read-P2TBytes $Stream 5 $Clock $TimeoutMs
    $recordLength = ([int]$record[3] * 256) + [int]$record[4]
    if ($record[0] -ne 22 -or $record[1] -ne 3 -or $record[2] -gt 3 -or $recordLength -lt 42 -or $recordLength -gt 18432) { return $false }
    $reply = Read-P2TBytes $Stream 42 $Clock $TimeoutMs
    $messageLength = ([int]$reply[1] * 65536) + ([int]$reply[2] * 256) + [int]$reply[3]
    return ($reply[0] -eq 2 -and $reply[4] -eq 3 -and $reply[5] -le 3 -and $messageLength -ge 38 -and $messageLength -le 18428)
}

function Test-P2TProxyEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Alias('Host')][string]$ProxyHost,
        [Parameter(Mandatory)][Alias('Port')][ValidateRange(1,65535)][int]$ProxyPort,
        [Parameter(Mandatory)][ValidateSet('socks5','http')][string]$Protocol,
        [ValidateRange(100,30000)][int]$TimeoutMs = 1500,
        [string]$ProbeAddress = '1.1.1.1',
        [ValidateRange(1,65535)][int]$ProbePort = 443
    )
    $client = $null; $stream = $null; $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $ip = [Net.IPAddress]::Parse($ProxyHost)
        if (-not [Net.IPAddress]::IsLoopback($ip)) { throw 'Only loopback proxies are supported.' }
        $target = [Net.IPAddress]::Parse($ProbeAddress)
        if ($target.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'ProbeAddress must be an IPv4 literal.' }
        $client = New-Object Net.Sockets.TcpClient($ip.AddressFamily)
        $pending = $client.BeginConnect($ip, $ProxyPort, $null, $null)
        try {
            if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw 'Connect timed out.' }
            $client.EndConnect($pending)
        } finally { $pending.AsyncWaitHandle.Close() }
        $stream = $client.GetStream(); $stream.WriteTimeout = $TimeoutMs; $stream.ReadTimeout = $TimeoutMs
        if ($Protocol -eq 'socks5') {
            [byte[]]$greeting = @(5,1,0); $stream.Write($greeting,0,$greeting.Length)
            $reply = Read-P2TBytes $stream 2 $clock $TimeoutMs
            if ($reply[0] -ne 5) { throw 'Not a SOCKS5 response.' }
            if ($reply[1] -ne 0) { throw 'SOCKS5 authentication is required or unsupported.' }
            [byte[]]$request = @(5,1,0,1) + $target.GetAddressBytes() + @([byte]($ProbePort -shr 8),[byte]($ProbePort -band 255))
            $stream.Write($request,0,$request.Length)
            $reply = Read-P2TBytes $stream 4 $clock $TimeoutMs
            if ($reply[0] -ne 5 -or $reply[1] -ne 0 -or $reply[2] -ne 0) { throw 'SOCKS5 CONNECT failed.' }
            switch ($reply[3]) {
                1 { $null = Read-P2TBytes $stream 6 $clock $TimeoutMs }
                4 { $null = Read-P2TBytes $stream 18 $clock $TimeoutMs }
                3 { $length = Read-P2TBytes $stream 1 $clock $TimeoutMs; $null = Read-P2TBytes $stream ([int]$length[0]+2) $clock $TimeoutMs }
                default { throw 'Invalid SOCKS5 bind address.' }
            }
        } else {
            $authority = '{0}:{1}' -f $ProbeAddress, $ProbePort
            $request = [Text.Encoding]::ASCII.GetBytes("CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Connection: keep-alive`r`n`r`n")
            $stream.Write($request,0,$request.Length)
            $header = New-Object 'Collections.Generic.List[byte]'
            $finished = $false
            while ($header.Count -lt 8192) {
                $one = Read-P2TBytes $stream 1 $clock $TimeoutMs; $header.Add($one[0])
                $n = $header.Count
                if ($n -ge 4 -and $header[$n-4] -eq 13 -and $header[$n-3] -eq 10 -and $header[$n-2] -eq 13 -and $header[$n-1] -eq 10) { $finished = $true; break }
            }
            if (-not $finished) { throw 'HTTP proxy header exceeded the limit.' }
            $status = [Text.Encoding]::ASCII.GetString($header.ToArray())
            if ($status -match '^HTTP/1\.[01] 407(?:\s|\r)') { throw 'HTTP proxy authentication is unsupported.' }
            if ($status -notmatch '^HTTP/1\.[01] 200(?:\s|\r)') { throw 'HTTP CONNECT was not accepted.' }
        }
        if (-not (Test-P2TTlsServerHello $stream $clock $TimeoutMs)) { throw 'CONNECT did not return a TLS ServerHello.' }
        [pscustomobject]@{ Success = $true; Protocol = $Protocol; Reason = 'CONNECT and TLS ServerHello received.' }
    } catch {
        [pscustomobject]@{ Success = $false; Protocol = $Protocol; Reason = $_.Exception.Message }
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($client) { $client.Close() }
        $clock.Stop()
    }
}

function Get-P2TProxyCandidates {
    [CmdletBinding()]
    param([ValidateRange(100,30000)][int]$TimeoutMs = 1500, [string]$ProbeAddress = '1.1.1.1', [int]$ProbePort = 443)
    $systemEndpoints = @(Get-P2TSystemProxyEndpoints)
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
    $endpoints = @{}
    foreach ($listener in $listeners) {
        $address = [string]$listener.LocalAddress
        if ($address -eq '0.0.0.0') { $address = '127.0.0.1' }
        if ($address -eq '::') { $address = '::1' }
        $ip = $null
        if (-not [Net.IPAddress]::TryParse($address,[ref]$ip) -or -not [Net.IPAddress]::IsLoopback($ip)) { continue }
        $key = '{0}|{1}' -f $address, $listener.LocalPort
        $isSystem = @($systemEndpoints | Where-Object { $_.Host -eq $address -and $_.Port -eq $listener.LocalPort }).Count -gt 0
        $endpoints[$key] = [pscustomobject]@{ Host=$address; Port=[int]$listener.LocalPort; ProcessId=[int]$listener.OwningProcess; Source=$(if ($isSystem) {'SystemProxy'} else {'Listener'}); Priority=$(if ($isSystem) {0} else {100}) }
    }
    $identityCache = @{}
    foreach ($endpoint in ($endpoints.Values | Sort-Object Priority,Port,Host)) {
        $owner = [int]$endpoint.ProcessId
        if (-not $identityCache.ContainsKey($owner)) { $identityCache[$owner] = Get-P2TProcessIdentity -ProcessId $owner }
        $identity = $identityCache[$owner]
        if (-not $identity) { Write-Verbose ('Skipping port {0}: reliable non-sing-box process identity unavailable.' -f $endpoint.Port); continue }
        foreach ($protocol in @('socks5','http')) {
            $probe = Test-P2TProxyEndpoint -ProxyHost $endpoint.Host -ProxyPort $endpoint.Port -Protocol $protocol -TimeoutMs $TimeoutMs -ProbeAddress $ProbeAddress -ProbePort $ProbePort
            if ($probe.Success) {
                [pscustomobject]@{
                    Host=$endpoint.Host; Port=$endpoint.Port; Protocol=$protocol
                    ProcessId=$identity.ProcessId; ProcessName=$identity.ProcessName; ProcessPath=$identity.ProcessPath; ProcessStartTime=$identity.ProcessStartTime
                    ParentProcessId=$identity.ParentProcessId; ParentName=$identity.ParentName; ParentPath=$identity.ParentPath; ParentProcessStartTime=$identity.ParentProcessStartTime
                    Source=$endpoint.Source; Priority=$endpoint.Priority
                }
                # Mixed listeners can support both protocols. Keep both so an
                # explicit HTTP endpoint remains selectable on such a listener.
                continue
            }
            Write-Verbose ('{0}:{1} {2}: {3}' -f $endpoint.Host,$endpoint.Port,$protocol,$probe.Reason)
        }
    }
}

function Get-P2TFamilyKey {
    param($Candidate)
    $genericParents = @('explorer.exe','powershell.exe','pwsh.exe','cmd.exe','conhost.exe','windowsterminal.exe','wt.exe','services.exe','svchost.exe','wininit.exe','winlogon.exe','taskhostw.exe','wscript.exe','cscript.exe','rundll32.exe','dllhost.exe','python.exe','pythonw.exe','node.exe','java.exe','javaw.exe','dotnet.exe','sing-box.exe')
    if ($Candidate.PSObject.Properties['ParentProcessStartTime'] -and $Candidate.ParentProcessStartTime -and $Candidate.ParentPath -and [IO.Path]::IsPathRooted($Candidate.ParentPath)) {
        $parentPath = [IO.Path]::GetFullPath($Candidate.ParentPath)
        $parentDirectory = [IO.Path]::GetDirectoryName($parentPath).TrimEnd('\') + '\'
        $parentName = [IO.Path]::GetFileName($parentPath).ToLowerInvariant()
        if ($genericParents -notcontains $parentName -and $parentDirectory.Length -gt ([IO.Path]::GetPathRoot($parentPath)).Length -and $Candidate.ProcessPath.StartsWith($parentDirectory,[StringComparison]::OrdinalIgnoreCase)) {
            return ('app|{0}|{1}|{2}' -f $Candidate.ParentProcessId,$Candidate.ParentProcessStartTime,$parentPath.ToLowerInvariant())
        }
    }
    # Generic launchers do not make their otherwise unrelated children a family.
    return ('{0}|{1}' -f $Candidate.ProcessId,$Candidate.ProcessStartTime)
}

function Select-P2TProxyCandidate {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Candidates = @(), [string]$ProxyHost = '', [int]$ProxyPort = 0, [ValidateSet('','socks5','http')][string]$ProxyProtocol = '')
    $items = @($Candidates)
    if ($ProxyHost) { $items = @($items | Where-Object { $_.Host -eq $ProxyHost }) }
    if ($ProxyPort -gt 0) { $items = @($items | Where-Object { $_.Port -eq $ProxyPort }) }
    if ($ProxyProtocol) { $items = @($items | Where-Object { $_.Protocol -eq $ProxyProtocol }) }
    if ($items.Count -eq 0) { return $null }
    if ($ProxyPort -le 0 -and -not $ProxyHost -and -not $ProxyProtocol) {
        $system = @($items | Where-Object { $_.Source -eq 'SystemProxy' })
        if ($system.Count -gt 0) {
            $families = @($system | ForEach-Object { Get-P2TFamilyKey $_ } | Select-Object -Unique)
            if ($families.Count -ne 1) { throw 'Ambiguous system proxies belong to different processes; specify -ProxyHost and -ProxyPort.' }
            $chosenFamily = $families[0]
            # Misty can run HTTP (privoxy) and SOCKS (v2ray) as separate children.
            # Group only a live, same-install app parent, never a generic launcher.
            $items = @($items | Where-Object { (Get-P2TFamilyKey $_) -eq $chosenFamily })
        }
    }
    $families = @($items | ForEach-Object { Get-P2TFamilyKey $_ } | Select-Object -Unique)
    if ($families.Count -ne 1) { throw 'Ambiguous unrelated proxies detected; specify -ProxyHost and -ProxyPort.' }
    return $items | Sort-Object @{Expression={if ($_.Protocol -eq 'socks5') {0} else {1}}},Priority,Port,Host | Select-Object -First 1
}

function Test-P2TProcessIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Candidate)
    $identity = Get-P2TProcessIdentity -ProcessId $Candidate.ProcessId
    if (-not $identity -or $identity.ProcessPath -ine $Candidate.ProcessPath -or $identity.ProcessStartTime -ne $Candidate.ProcessStartTime) { return $false }
    if ($Candidate.PSObject.Properties['ParentProcessStartTime'] -and $Candidate.ParentProcessStartTime -and ($identity.ParentPath -ine $Candidate.ParentPath -or $identity.ParentProcessStartTime -ne $Candidate.ParentProcessStartTime)) { return $false }
    try {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Candidate.Port -ErrorAction Stop | Where-Object {
            $_.OwningProcess -eq $Candidate.ProcessId -and ($_.LocalAddress -eq $Candidate.Host -or ($_.LocalAddress -eq '0.0.0.0' -and $Candidate.Host -match '^127\.') -or ($_.LocalAddress -eq '::' -and $Candidate.Host -eq '::1'))
        })
        return ($listeners.Count -gt 0)
    } catch { return $false }
}

Export-ModuleMember -Function ConvertFrom-P2TSystemProxy,Get-P2TSystemProxyEndpoints,Get-P2TProcessIdentity,Test-P2TProxyEndpoint,Get-P2TProxyCandidates,Select-P2TProxyCandidate,Test-P2TProcessIdentity
