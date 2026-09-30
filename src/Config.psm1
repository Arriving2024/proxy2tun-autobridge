#requires -Version 5.1
Set-StrictMode -Version 2.0

function Get-P2TDirectProcessPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Candidate, [string[]]$ExtraDirectProcessPath = @())
    if (-not $Candidate.ProcessPath -or -not [IO.Path]::IsPathRooted($Candidate.ProcessPath) -or -not $Candidate.ProcessStartTime -or [int]$Candidate.ProcessId -le 0) { throw 'A complete verified upstream process identity is required.' }
    $ownerPath = [IO.Path]::GetFullPath($Candidate.ProcessPath)
    if ([IO.Path]::GetFileName($ownerPath) -ieq 'sing-box.exe') { throw 'sing-box cannot be its own upstream.' }
    $paths = New-Object 'Collections.Generic.List[string]'
    $paths.Add($ownerPath)
    $genericParents = @('explorer.exe','powershell.exe','pwsh.exe','cmd.exe','conhost.exe','windowsterminal.exe','wt.exe','services.exe','svchost.exe','wininit.exe','winlogon.exe','taskhostw.exe','wscript.exe','cscript.exe','rundll32.exe','dllhost.exe','python.exe','pythonw.exe','node.exe','java.exe','javaw.exe','dotnet.exe','sing-box.exe')
    if ($Candidate.PSObject.Properties['ParentProcessStartTime'] -and $Candidate.ParentProcessStartTime -and $Candidate.ParentPath -and [IO.Path]::IsPathRooted($Candidate.ParentPath)) {
        $parentPath = [IO.Path]::GetFullPath($Candidate.ParentPath)
        $parentDirectory = [IO.Path]::GetDirectoryName($parentPath).TrimEnd('\') + '\'
        $parentName = [IO.Path]::GetFileName($parentPath).ToLowerInvariant()
        $driveRoot = [IO.Path]::GetPathRoot($parentPath)
        if ($genericParents -notcontains $parentName -and $parentDirectory.Length -gt $driveRoot.Length -and $ownerPath.StartsWith($parentDirectory,[StringComparison]::OrdinalIgnoreCase)) { $paths.Add($parentPath) }
    }
    foreach ($extraPath in $ExtraDirectProcessPath) {
        if (-not [IO.Path]::IsPathRooted($extraPath) -or -not (Test-Path -LiteralPath $extraPath -PathType Leaf)) { throw ('Extra DIRECT executable must be an existing absolute file path: ' + $extraPath) }
        if ([IO.Path]::GetExtension($extraPath) -ine '.exe') { throw ('Extra DIRECT path must be an executable: ' + $extraPath) }
        $paths.Add([IO.Path]::GetFullPath($extraPath))
    }
    return @($paths | Select-Object -Unique)
}

function New-P2TSingBoxConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)][ValidatePattern('^p2t-[a-zA-Z0-9-]{1,32}$')][string]$InterfaceName,
        [string]$LogPath = '',
        [string[]]$ExtraDirectProcessPath = @()
    )
    $ip = $null
    if (-not [Net.IPAddress]::TryParse([string]$Candidate.Host,[ref]$ip) -or -not [Net.IPAddress]::IsLoopback($ip)) { throw 'Only a loopback upstream is supported.' }
    if ([int]$Candidate.Port -lt 1 -or [int]$Candidate.Port -gt 65535 -or $Candidate.Protocol -notin @('socks5','http')) { throw 'Invalid upstream port or protocol.' }
    $directPaths = @(Get-P2TDirectProcessPaths -Candidate $Candidate -ExtraDirectProcessPath $ExtraDirectProcessPath)
    $log = [ordered]@{ level='info'; timestamp=$true }
    if ($LogPath) { $log['output'] = [IO.Path]::GetFullPath($LogPath) }
    $upstream = [ordered]@{ type=$(if ($Candidate.Protocol -eq 'socks5') {'socks'} else {'http'}); tag='upstream'; server=[string]$Candidate.Host; server_port=[int]$Candidate.Port; connect_timeout='10s' }
    if ($Candidate.Protocol -eq 'socks5') { $upstream['version']='5' }
    $windowsPath = [Environment]::GetFolderPath('Windows')
    if (-not $windowsPath) { $windowsPath = $env:SystemRoot }
    if (-not $windowsPath) { throw 'Cannot determine the Windows directory.' }
    $dnsClientPath = Join-Path $windowsPath 'System32\svchost.exe'
    return [ordered]@{
        log=$log
        dns=[ordered]@{
            servers=@([ordered]@{ type='https'; tag='remote-dns'; server='1.1.1.1'; server_port=443; path='/dns-query'; tls=[ordered]@{ enabled=$true; server_name='cloudflare-dns.com' }; detour='upstream' })
            final='remote-dns'; strategy='prefer_ipv4'
        }
        inbounds=@([ordered]@{
            type='tun'; tag='tun-in'; interface_name=$InterfaceName
            address=@('172.31.255.1/30','fdfe:7072:6f78::1/126'); mtu=1500
            auto_route=$true; strict_route=$false; dns_mode='disabled'
            route_exclude_address=@('127.0.0.0/8','::1/128')
            stack='mixed'
        })
        outbounds=@($upstream,[ordered]@{ type='direct'; tag='direct' })
        route=[ordered]@{
            auto_detect_interface=$true; find_process=$true; final='upstream'
            rules=@(
                [ordered]@{ process_path=$directPaths; action='route'; outbound='direct' },
                # A node hostname may be resolved by the shared Windows DNS Client.
                # Keep only its port-53 traffic DIRECT to avoid a bootstrap cycle.
                [ordered]@{ process_path=@($dnsClientPath); port=@(53); action='route'; outbound='direct' },
                [ordered]@{ port=@(53); action='hijack-dns' },
                [ordered]@{ network=@('udp','icmp'); action='reject' },
                [ordered]@{ ip_is_private=$true; action='route'; outbound='direct' }
            )
        }
    }
}

function Write-P2TSingBoxConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config,[Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }
    [IO.File]::WriteAllText($fullPath,($Config | ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
}

Export-ModuleMember -Function Get-P2TDirectProcessPaths,New-P2TSingBoxConfig,Write-P2TSingBoxConfig
