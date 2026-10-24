#requires -Version 5.1
Set-StrictMode -Version 2.0

function ConvertTo-P2TProcessArgument {
    param([AllowEmptyString()][string]$Value)
    # Windows CommandLineToArgvW quoting; never pass arguments through a shell.
    return ('"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"')
}

function Invoke-P2TBoundedProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string[]]$Arguments=@(), [ValidateRange(100,60000)][int]$TimeoutMs=12000)
    $process=New-Object Diagnostics.Process
    try {
        $process.StartInfo.FileName=$Path
        $process.StartInfo.Arguments=(@($Arguments | ForEach-Object { ConvertTo-P2TProcessArgument $_ }) -join ' ')
        $process.StartInfo.UseShellExecute=$false
        $process.StartInfo.CreateNoWindow=$true
        $process.StartInfo.RedirectStandardOutput=$true
        $process.StartInfo.RedirectStandardError=$true
        # Neither environment proxy settings nor a user's curl configuration may
        # make the forwarding check accidentally bypass the TUN via a proxy.
        foreach($key in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY')) { $process.StartInfo.EnvironmentVariables.Remove($key) }
        $null=$process.Start()
        $outputTask=$process.StandardOutput.ReadToEndAsync()
        $errorTask=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutMs)) {
            $process.Kill(); $null=$process.WaitForExit(1500)
            return [pscustomobject]@{ExitCode=-1;TimedOut=$true;Output=''}
        }
        $output=$outputTask.GetAwaiter().GetResult()
        $null=$errorTask.GetAwaiter().GetResult()
        return [pscustomobject]@{ExitCode=$process.ExitCode;TimedOut=$false;Output=$output}
    } catch {
        # Do not surface raw stderr/response data, command lines or DNS results.
        return [pscustomobject]@{ExitCode=-2;TimedOut=$false;Output=''}
    } finally {
        try { if($process.Id -and -not $process.HasExited){$process.Kill();$null=$process.WaitForExit(1500)} } catch {}
        $process.Dispose()
    }
}

function ConvertFrom-P2THttpsProbe {
    [CmdletBinding()]
    param([int]$ExitCode, [AllowEmptyString()][string]$Output='', [AllowEmptyString()][string]$Headers='', [bool]$TimedOut=$false)
    $status=0; $elapsed=0.0
    if($Output.Trim() -match '^(\d{3})\|([\d.]+)$') { $status=[int]$Matches[1]; $null=[double]::TryParse($Matches[2],[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$elapsed) }
    $transport=($ExitCode -eq 0 -and -not $TimedOut -and $status -ge 100 -and $status -le 599)
    $classification='NetworkError'
    if($TimedOut -or $ExitCode -eq 28) { $classification='Timeout' }
    elseif($ExitCode -in @(51,58,60,77,82,83,90,91)) { $classification='TlsValidationError' }
    elseif($transport) {
        if($status -eq 403 -and $Headers -match '(?im)^cf-mitigated:\s*challenge\s*$') { $classification='CloudflareChallenge' }
        elseif($status -ge 200 -and $status -lt 400) { $classification='HttpSuccess' }
        else { $classification='HttpServiceError' }
    }
    [pscustomobject]@{TransportSuccess=$transport;ServiceSuccess=($transport -and $status -ge 200 -and $status -lt 400);Classification=$classification;HttpStatus=$status;CurlExitCode=$ExitCode;ElapsedSeconds=$elapsed}
}

function Test-P2THttpsForwarding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimePath, [uri]$Url='https://www.cloudflare.com/cdn-cgi/trace', [ValidateRange(1,20)][int]$TimeoutSeconds=8)
    if($Url.Scheme -ne 'https' -or $Url.UserInfo -or $Url.Query -or $Url.Fragment) { throw 'Health probes require a credential-free HTTPS URL without query or fragment.' }
    $curl=Join-Path $env:SystemRoot 'System32\curl.exe'
    $headers=Join-Path $RuntimePath ('probe-'+[guid]::NewGuid().ToString('N')+'.headers')
    try {
        # -q must be first. There is deliberately no --insecure, --fail, or
        # redirect: HTTP 403 can prove working TLS/transport without service access.
        $result=Invoke-P2TBoundedProcess -Path $curl -Arguments @('-q','--silent','--show-error','--noproxy','*','--proxy','','--connect-timeout','3','--max-time',([string]$TimeoutSeconds),'--head','--output','NUL','--dump-header',$headers,'--write-out','%{http_code}|%{time_total}',[string]$Url) -TimeoutMs (($TimeoutSeconds+2)*1000)
        $headerText=''
        if(Test-Path -LiteralPath $headers){
            $info=Get-Item -LiteralPath $headers
            if($info.Length -le 65536){$headerText=[IO.File]::ReadAllText($headers)}
        }
        ConvertFrom-P2THttpsProbe -ExitCode $result.ExitCode -Output $result.Output -Headers $headerText -TimedOut $result.TimedOut
    } finally { Remove-Item -LiteralPath $headers -Force -ErrorAction SilentlyContinue }
}

function Test-P2TSystemDns {
    [CmdletBinding()]
    param([ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$Name='www.cloudflare.com', [ValidateRange(1,20)][int]$TimeoutSeconds=5)
    # Run Windows DNS in a bounded child so an OS resolver timeout cannot stall
    # the watcher. Emit only a fixed marker; addresses and error details stay private.
    $command="try { `$r=@(Resolve-DnsName -Name '$Name' -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Where-Object { `$_.Type -eq 'A' -and `$_.IPAddress }); if(`$r.Count -gt 0){[Console]::Write('DNS_OK');exit 0};exit 1 } catch { exit 1 }"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $result=Invoke-P2TBoundedProcess -Path $shell -Arguments @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -TimeoutMs ($TimeoutSeconds*1000)
    [pscustomobject]@{Success=($result.ExitCode -eq 0 -and $result.Output -eq 'DNS_OK');Classification=$(if($result.TimedOut){'DnsTimeout'}elseif($result.ExitCode -eq 0 -and $result.Output -eq 'DNS_OK'){'DnsSuccess'}else{'DnsError'})}
}

function Get-P2TDnsUInt16 {
    param([byte[]]$Message,[int]$Offset)
    if($Offset -lt 0 -or $Offset+1 -ge $Message.Length){throw 'Invalid DNS packet.'}
    return (([int]$Message[$Offset] -shl 8) -bor [int]$Message[$Offset+1])
}

function Read-P2TDnsName {
    param([byte[]]$Message,[ref]$Offset)
    $position=[int]$Offset.Value;$next=$position;$jumped=$false;$steps=0
    $labels=New-Object 'Collections.Generic.List[string]'
    while($true){
        if($position -lt 0 -or $position -ge $Message.Length -or $steps++ -ge 128){throw 'Invalid DNS name.'}
        $length=[int]$Message[$position]
        if(($length -band 192) -eq 192){
            if($position+1 -ge $Message.Length){throw 'Invalid DNS pointer.'}
            if(-not $jumped){$next=$position+2}
            $position=(($length -band 63) -shl 8) -bor [int]$Message[$position+1]
            $jumped=$true;continue
        }
        if($length -gt 63){throw 'Invalid DNS label.'}
        if($length -eq 0){if(-not $jumped){$next=$position+1};break}
        if($position+1+$length -gt $Message.Length){throw 'Invalid DNS label length.'}
        $label=[Text.Encoding]::ASCII.GetString($Message,$position+1,$length)
        if($label -notmatch '^[a-zA-Z0-9_-]+$'){throw 'Invalid DNS label content.'}
        $labels.Add($label);$position+=1+$length
        if(-not $jumped){$next=$position}
    }
    $Offset.Value=$next
    return ($labels -join '.').ToLowerInvariant()
}

function New-P2TDnsQuery {
    param([ValidateRange(0,65535)][int]$TransactionId,[ValidatePattern('^[a-zA-Z0-9.-]{1,253}$')][string]$Name)
    $query=New-Object 'Collections.Generic.List[byte]'
    $query.AddRange([byte[]]@(($TransactionId -shr 8),($TransactionId -band 255),1,0,0,1,0,0,0,0,0,0))
    foreach($label in $Name.TrimEnd('.').Split('.')){
        if($label.Length -lt 1 -or $label.Length -gt 63){throw 'Invalid DNS query label.'}
        $query.Add([byte]$label.Length);$query.AddRange([Text.Encoding]::ASCII.GetBytes($label))
    }
    $query.AddRange([byte[]]@(0,0,1,0,1))
    return ,$query.ToArray()
}

function Test-P2TDnsResponse {
    [CmdletBinding()]
    param([byte[]]$Message,[ValidateRange(0,65535)][int]$TransactionId,[string]$Name)
    try{
        if($Message.Length -lt 12 -or $Message.Length -gt 4096 -or (Get-P2TDnsUInt16 $Message 0) -ne $TransactionId){throw 'Invalid DNS header.'}
        $flags=Get-P2TDnsUInt16 $Message 2;$rcode=$flags -band 15
        if(($flags -band 32768) -eq 0 -or ($flags -band 30720) -ne 0 -or ($flags -band 512) -ne 0 -or $rcode -notin @(0,3)){throw 'Invalid DNS flags.'}
        if((Get-P2TDnsUInt16 $Message 4) -ne 1){throw 'Invalid DNS question count.'}
        $answers=Get-P2TDnsUInt16 $Message 6;$authorities=Get-P2TDnsUInt16 $Message 8;$additional=Get-P2TDnsUInt16 $Message 10
        if($answers+$authorities+$additional -gt 128){throw 'DNS record limit exceeded.'}
        $offset=12;$question=Read-P2TDnsName $Message ([ref]$offset)
        if($question -ne $Name.TrimEnd('.').ToLowerInvariant() -or (Get-P2TDnsUInt16 $Message $offset) -ne 1 -or (Get-P2TDnsUInt16 $Message ($offset+2)) -ne 1){throw 'DNS question mismatch.'}
        $offset+=4;$aNames=New-Object 'Collections.Generic.List[string]';$aliases=@{};$hasSoa=$false
        for($record=0;$record -lt $answers+$authorities+$additional;$record++){
            $owner=Read-P2TDnsName $Message ([ref]$offset)
            $type=Get-P2TDnsUInt16 $Message $offset;$class=Get-P2TDnsUInt16 $Message ($offset+2);$length=Get-P2TDnsUInt16 $Message ($offset+8)
            $offset+=10
            if($offset+$length -gt $Message.Length){throw 'Invalid DNS record length.'}
            if($record -lt $answers -and $class -eq 1){
                if($type -eq 1 -and $length -eq 4){$aNames.Add($owner)}
                elseif($type -eq 5){$aliasOffset=$offset;$target=Read-P2TDnsName $Message ([ref]$aliasOffset);if($aliasOffset -ne $offset+$length){throw 'Invalid CNAME record.'};$aliases[$owner]=$target}
            }
            if($record -ge $answers -and $record -lt $answers+$authorities -and $class -eq 1 -and $type -eq 6){
                $soaOffset=$offset;$null=Read-P2TDnsName $Message ([ref]$soaOffset);$null=Read-P2TDnsName $Message ([ref]$soaOffset)
                if($soaOffset+20 -ne $offset+$length){throw 'Invalid SOA record.'};$hasSoa=$true
            }
            $offset+=$length
        }
        if($offset -ne $Message.Length){throw 'Unexpected DNS trailing data.'}
        if($rcode -eq 3 -and $answers -eq 0 -and $hasSoa){return [pscustomobject]@{Success=$true;Classification='FreshDnsNxDomain'}}
        $answerName=$question
        for($depth=0;$depth -le $answers;$depth++){
            if($aNames.Contains($answerName)){return [pscustomobject]@{Success=$true;Classification='FreshDnsPositive'}}
            if(-not $aliases.ContainsKey($answerName)){break};$answerName=$aliases[$answerName]
        }
        throw 'No DNS A answer or verified negative response structure.'
    } catch {return [pscustomobject]@{Success=$false;Classification='FreshDnsInvalidResponse'}}
}

function Test-P2TFreshTunDns {
    [CmdletBinding()]
    param([string]$TunDnsServer='172.31.255.2',[ValidateRange(100,10000)][int]$TimeoutMs=2500)
    $client=$null
    try{
        $server=[Net.IPAddress]::Parse($TunDnsServer)
        $nonce=[guid]::NewGuid().ToString('N')
        $name='p2t-'+$nonce+'.example.com'
        $id=[Convert]::ToInt32($nonce.Substring(0,4),16)
        $query=New-P2TDnsQuery -TransactionId $id -Name $name
        $client=New-Object Net.Sockets.UdpClient($server.AddressFamily)
        $client.Client.ReceiveTimeout=$TimeoutMs;$client.Client.SendTimeout=$TimeoutMs
        $client.Connect($server,53)
        $null=$client.Send($query,$query.Length)
        $remote=New-Object Net.IPEndPoint([Net.IPAddress]::Any,0)
        $reply=$client.Receive([ref]$remote)
        if(-not $remote.Address.Equals($server) -or $remote.Port -ne 53){return [pscustomobject]@{Success=$false;Classification='FreshDnsSourceMismatch'}}
        Test-P2TDnsResponse -Message $reply -TransactionId $id -Name $name
    }catch [Net.Sockets.SocketException]{
        [pscustomobject]@{Success=$false;Classification=$(if($_.Exception.SocketErrorCode -in @([Net.Sockets.SocketError]::TimedOut,[Net.Sockets.SocketError]::WouldBlock)){'FreshDnsTimeout'}else{'FreshDnsNetworkError'})}
    }catch{[pscustomobject]@{Success=$false;Classification='FreshDnsProbeError'}}
    finally{if($client){$client.Close()}}
}

function Test-P2TForwardingHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimePath)
    $dns=Test-P2TSystemDns
    # A unique negative query goes straight to our generated TUN DNS address,
    # bypassing Windows cache and the core's prior per-name cache. The positive
    # OS lookup remains a separate check of the normal application resolver path.
    $freshDns=Test-P2TFreshTunDns
    $https=Test-P2THttpsForwarding -RuntimePath $RuntimePath
    # A second independent origin avoids rebuilding for a single blocked origin.
    if(-not $https.TransportSuccess){$https=Test-P2THttpsForwarding -RuntimePath $RuntimePath -Url 'https://www.gstatic.com/generate_204'}
    [pscustomobject]@{Success=($dns.Success -and $freshDns.Success -and $https.TransportSuccess);Dns=$dns;FreshDns=$freshDns;Https=$https}
}

function Get-P2TNetworkFingerprint {
    [CmdletBinding()]
    param([string]$OwnedInterfaceName='')
    try {
        $adapters=@(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and $_.Name -ne $OwnedInterfaceName -and $_.Name -notmatch '^p2t-' })
        $parts=New-Object 'Collections.Generic.List[string]'; $available=$false
        foreach($adapter in ($adapters | Sort-Object ifIndex)) {
            $index=[int]$adapter.ifIndex
            $parts.Add(('adapter|{0}|{1}' -f $index,$adapter.InterfaceGuid))
            foreach($route in @(Get-NetRoute -InterfaceIndex $index -ErrorAction Stop | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0','::/0') } | Sort-Object DestinationPrefix,NextHop,RouteMetric)) {
                $parts.Add(('route|{0}|{1}|{2}' -f $route.DestinationPrefix,$route.NextHop,$route.RouteMetric));$available=$true
            }
            foreach($ip in @(Get-NetIPAddress -InterfaceIndex $index -ErrorAction Stop | Sort-Object IPAddress)) { $parts.Add(('ip|{0}|{1}' -f $ip.IPAddress,$ip.PrefixLength)) }
            foreach($dns in @(Get-DnsClientServerAddress -InterfaceIndex $index -ErrorAction Stop | Sort-Object AddressFamily)) { $parts.Add(('dns|{0}|{1}' -f $dns.AddressFamily,(@($dns.ServerAddresses) -join ','))) }
            foreach($metric in @(Get-NetIPInterface -InterfaceIndex $index -ErrorAction Stop | Sort-Object AddressFamily)) { $parts.Add(('metric|{0}|{1}' -f $metric.AddressFamily,$metric.InterfaceMetric)) }
        }
        $sha=[Security.Cryptography.SHA256]::Create()
        try {$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))))).Replace('-','')}finally{$sha.Dispose()}
        [pscustomobject]@{Valid=$true;Available=$available;Fingerprint=$hash}
    } catch { [pscustomobject]@{Valid=$false;Available=$false;Fingerprint=''} }
}

function Test-P2TOwnedTunRoutes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InterfaceName,[Parameter(Mandatory)][string]$AdapterGuid)
    try {
        $adapter=Get-NetAdapter -Name $InterfaceName -IncludeHidden -ErrorAction Stop
        if(-not $adapter -or $adapter.InterfaceGuid.ToString() -ne $AdapterGuid -or $adapter.Status -ne 'Up'){
            return [pscustomobject]@{Success=$false;Classification='OwnedTunAdapterUnavailable'}
        }
        $prefixes=@(Get-NetRoute -InterfaceIndex $adapter.ifIndex -ErrorAction Stop | ForEach-Object {$_.DestinationPrefix})
        $ipv4=($prefixes -contains '0.0.0.0/0' -or ($prefixes -contains '0.0.0.0/1' -and $prefixes -contains '128.0.0.0/1'))
        $ipv6=($prefixes -contains '::/0' -or ($prefixes -contains '::/1' -and $prefixes -contains '8000::/1'))
        [pscustomobject]@{Success=($ipv4 -and $ipv6);Classification=$(if($ipv4 -and $ipv6){'OwnedTunRoutesReady'}else{'OwnedTunRoutesMissing'})}
    } catch {[pscustomobject]@{Success=$false;Classification='OwnedTunInspectionFailed'}}
}

function New-P2TNetworkObservation {
    param($Snapshot,[datetime]$Now=[DateTime]::UtcNow)
    [pscustomobject]@{StableFingerprint=$Snapshot.Fingerprint;StableAvailable=$Snapshot.Available;PendingFingerprint=$Snapshot.Fingerprint;PendingAvailable=$Snapshot.Available;PendingSince=$Now;Initialized=$Snapshot.Valid}
}

function Update-P2TNetworkObservation {
    param($State,$Snapshot,[datetime]$Now=[DateTime]::UtcNow,[int]$DebounceSeconds=6)
    if(-not $Snapshot.Valid){return $false}
    if(-not $State.Initialized){$State.StableFingerprint=$Snapshot.Fingerprint;$State.StableAvailable=$Snapshot.Available;$State.PendingFingerprint=$Snapshot.Fingerprint;$State.PendingAvailable=$Snapshot.Available;$State.PendingSince=$Now;$State.Initialized=$true;return $false}
    if($Snapshot.Fingerprint -eq $State.StableFingerprint){$State.PendingFingerprint=$Snapshot.Fingerprint;$State.PendingAvailable=$Snapshot.Available;$State.PendingSince=$Now;return $false}
    if($Snapshot.Fingerprint -ne $State.PendingFingerprint){$State.PendingFingerprint=$Snapshot.Fingerprint;$State.PendingAvailable=$Snapshot.Available;$State.PendingSince=$Now;return $false}
    if(($Now-$State.PendingSince).TotalSeconds -lt $DebounceSeconds){return $false}
    $State.StableFingerprint=$Snapshot.Fingerprint;$State.StableAvailable=$Snapshot.Available
    return $true
}

function New-P2TRecoveryState {
    [pscustomobject]@{Failures=0;RetryAt=[DateTime]::MinValue;Latched=$false;HealthySince=$null;LastReason='';DelaySeconds=0}
}

function Register-P2TRecoveryFailure {
    param($State,[string]$Reason,[datetime]$Now=[DateTime]::UtcNow,[int]$MaxAttempts=3,[int]$BaseSeconds=10,[int]$CapSeconds=120)
    $State.Failures++;$State.HealthySince=$null;$State.LastReason=$Reason
    # MaxAttempts is the number of automatic rebuilds after the initial start.
    if($State.Failures -gt $MaxAttempts){$State.Latched=$true;$State.DelaySeconds=0;$State.RetryAt=[DateTime]::MaxValue;return}
    $State.DelaySeconds=[int][Math]::Min($CapSeconds,($BaseSeconds*[Math]::Pow(2,($State.Failures-1))))
    $State.RetryAt=$Now.AddSeconds($State.DelaySeconds)
}

function Register-P2TRecoverySuccess {
    param($State,[datetime]$Now=[DateTime]::UtcNow,[int]$HealthyResetSeconds=300)
    if($State.Latched){return}
    if($null -eq $State.HealthySince){$State.HealthySince=$Now;return}
    if(($Now-$State.HealthySince).TotalSeconds -ge $HealthyResetSeconds){$State.Failures=0;$State.DelaySeconds=0;$State.LastReason=''}
}

Export-ModuleMember -Function ConvertTo-P2TProcessArgument,Invoke-P2TBoundedProcess,ConvertFrom-P2THttpsProbe,Test-P2THttpsForwarding,Test-P2TSystemDns,New-P2TDnsQuery,Test-P2TDnsResponse,Test-P2TFreshTunDns,Test-P2TForwardingHealth,Get-P2TNetworkFingerprint,Test-P2TOwnedTunRoutes,New-P2TNetworkObservation,Update-P2TNetworkObservation,New-P2TRecoveryState,Register-P2TRecoveryFailure,Register-P2TRecoverySuccess
