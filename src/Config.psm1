#requires -Version 5.1
Set-StrictMode -Version 2.0

function Get-P2TDirectProcessPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Candidate, [string[]]$ExtraDirectProcessPath = @())
    if (-not $Candidate.ProcessPath -or -not [IO.Path]::IsPathRooted($Candidate.ProcessPath) -or -not $Candidate.ProcessStartTime -or [int]$Candidate.ProcessId -le 0) { throw 'A complete verified upstream process identity is required.' }
    $ownerPath = [IO.Path]::GetFullPath($Candidate.ProcessPath)
    if ([IO.Path]::GetFileName($ownerPath) -ieq 'sing-box.exe') { throw 'sing-box cannot be its own upstream.' }
    if ([IO.Path]::GetFileName($ownerPath) -ieq 'svchost.exe') { throw 'A shared Windows service host cannot be bypassed as an upstream executable.' }
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
        [string[]]$ExtraDirectProcessPath = @(),
        [switch]$AllowSystemDnsBootstrap
    )
    $ip = $null
    if (-not [Net.IPAddress]::TryParse([string]$Candidate.Host,[ref]$ip) -or -not [Net.IPAddress]::IsLoopback($ip)) { throw 'Only a loopback upstream is supported.' }
    if ([int]$Candidate.Port -lt 1 -or [int]$Candidate.Port -gt 65535 -or $Candidate.Protocol -notin @('socks5','http')) { throw 'Invalid upstream port or protocol.' }
    $directPaths = @(Get-P2TDirectProcessPaths -Candidate $Candidate -ExtraDirectProcessPath $ExtraDirectProcessPath)
    $log = [ordered]@{ level='info'; timestamp=$true }
    if ($LogPath) { $log['output'] = [IO.Path]::GetFullPath($LogPath) }
    $upstream = [ordered]@{ type=$(if ($Candidate.Protocol -eq 'socks5') {'socks'} else {'http'}); tag='upstream'; server=[string]$Candidate.Host; server_port=[int]$Candidate.Port; connect_timeout='10s' }
    if ($Candidate.Protocol -eq 'socks5') { $upstream['version']='5' }
    $rules = @([ordered]@{ process_path=$directPaths; action='route'; outbound='direct' })
    if ($AllowSystemDnsBootstrap) {
        $windowsPath = [Environment]::GetFolderPath('Windows')
        if (-not $windowsPath) { $windowsPath = $env:SystemRoot }
        if (-not $windowsPath) { throw 'Cannot determine the Windows directory.' }
        # Explicit compatibility opt-in only: Windows DNS Client is shared by
        # applications, so this bypass can also send their DNS outside the DoH.
        $rules += [ordered]@{ process_path=@((Join-Path $windowsPath 'System32\svchost.exe')); port=@(53); action='route'; outbound='direct' }
    }
    $rules += @(
        [ordered]@{ port=@(53); action='hijack-dns' },
        [ordered]@{ network=@('udp','icmp'); action='reject' },
        [ordered]@{ ip_is_private=$true; action='route'; outbound='direct' }
    )
    return [ordered]@{
        log=$log
        dns=[ordered]@{
            servers=@([ordered]@{ type='https'; tag='remote-dns'; server='1.1.1.1'; server_port=443; path='/dns-query'; tls=[ordered]@{ enabled=$true; server_name='cloudflare-dns.com' }; detour='upstream' })
            final='remote-dns'; strategy='ipv4_only'
        }
        inbounds=@([ordered]@{
            type='tun'; tag='tun-in'; interface_name=$InterfaceName
            address=@('172.31.255.1/30','fdfe:7072:6f78::1/126'); mtu=1500
            auto_route=$true; strict_route=$false; dns_mode='hijack'
            route_exclude_address=@('127.0.0.0/8','::1/128')
            stack='mixed'
        })
        outbounds=@($upstream,[ordered]@{ type='direct'; tag='direct' })
        route=[ordered]@{
            auto_detect_interface=$true; find_process=$true; final='upstream'
            rules=$rules
        }
    }
}

function Write-P2TSingBoxConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config,[Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }
    [IO.File]::WriteAllText($fullPath,($Config | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
}

function Set-P2TSingBoxConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SingBoxPath
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    $binary = (Resolve-Path -LiteralPath $SingBoxPath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'sing-box validator must be an existing file.' }
    if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }
    if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Config directory must not be a reparse point.' }
    if (Test-Path -LiteralPath $fullPath) {
        $current = Get-Item -LiteralPath $fullPath -Force
        if ($current.PSIsContainer -or ($current.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Active config must be a regular file.' }
    }
    $suffix = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')
    $candidatePath = Join-Path $directory ('.config-candidate-' + $suffix + '.json')
    $backupPath = ''
    try {
        Write-P2TSingBoxConfig -Config $Config -Path $candidatePath
        $validation = (& $binary check -c $candidatePath 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw ('sing-box rejected candidate configuration: ' + $validation.Trim()) }
        $appliedHash = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash
        $hadPrevious = Test-Path -LiteralPath $fullPath -PathType Leaf
        $previousHash = ''
        if ($hadPrevious) {
            $previousHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
            $backupPath = $fullPath + '.backup-' + $suffix + '.json'
            # File.Replace is atomic within the same directory/volume. A failed
            # replace leaves the active file intact; no delete-first fallback.
            [IO.File]::Replace($candidatePath,$fullPath,$backupPath,$true)
        } else {
            # Move never overwrites a config created concurrently by another owner.
            [IO.File]::Move($candidatePath,$fullPath)
        }
        return [pscustomobject]@{
            Path=$fullPath; BackupPath=$backupPath; HadPrevious=[bool]$hadPrevious
            AppliedHash=$appliedHash; PreviousHash=$previousHash
        }
    } finally {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) { Remove-Item -LiteralPath $candidatePath -Force }
    }
}

function Restore-P2TSingBoxConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Transaction)
    foreach ($name in @('Path','BackupPath','HadPrevious','AppliedHash','PreviousHash')) {
        if (-not $Transaction.PSObject.Properties[$name]) { throw 'Invalid configuration transaction.' }
    }
    $fullPath = [IO.Path]::GetFullPath([string]$Transaction.Path)
    $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
    $currentHash = $(if ($exists) { (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash } else { '' })
    if ($Transaction.HadPrevious) {
        if (-not $Transaction.BackupPath -or -not (Test-Path -LiteralPath $Transaction.BackupPath -PathType Leaf)) { throw 'Configuration backup is missing; refusing rollback.' }
        if ((Get-FileHash -LiteralPath $Transaction.BackupPath -Algorithm SHA256).Hash -ne $Transaction.PreviousHash) { throw 'Configuration backup changed; refusing rollback.' }
        if ($currentHash -eq $Transaction.PreviousHash) { return }
    } elseif (-not $exists) { return }
    if ($currentHash -ne $Transaction.AppliedHash) { throw 'Active configuration changed after validation; refusing to overwrite it during rollback.' }
    if (-not $Transaction.HadPrevious) {
        [IO.File]::Delete($fullPath)
        return
    }
    $rollbackPath = Join-Path ([IO.Path]::GetDirectoryName($fullPath)) ('.config-rollback-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::Copy([string]$Transaction.BackupPath,$rollbackPath,$false)
        if ((Get-FileHash -LiteralPath $rollbackPath -Algorithm SHA256).Hash -ne $Transaction.PreviousHash) { throw 'Configuration rollback copy is invalid.' }
        [IO.File]::Replace($rollbackPath,$fullPath,[NullString]::Value,$true)
    } finally {
        if (Test-Path -LiteralPath $rollbackPath -PathType Leaf) { Remove-Item -LiteralPath $rollbackPath -Force }
    }
}

Export-ModuleMember -Function Get-P2TDirectProcessPaths,New-P2TSingBoxConfig,Write-P2TSingBoxConfig,Set-P2TSingBoxConfig,Restore-P2TSingBoxConfig
