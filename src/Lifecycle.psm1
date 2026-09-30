Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-P2TNative {
    if (-not ('Proxy2Tun.OwnedProcess' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'NativeProcess.cs') }
}
function Test-P2TAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Write-P2TState {
    param($State, [string]$Path)
    $temporary = "$Path.tmp"
    [IO.File]::WriteAllText($temporary, ($State | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Write-P2TLog {
    param([string]$Message, [string]$Path)
    $line = '{0} {1}' -f ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')), $Message
    Write-Host $line
    [IO.File]::AppendAllText($Path, "$line`r`n", (New-Object Text.UTF8Encoding($false)))
}
function Get-P2TProcessStamp {
    param([int]$ProcessId)
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    return [pscustomobject]@{ Id = $process.Id; Path = $process.Path; StartFileTime = $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() }
}
function Test-P2TStamp {
    param($Stamp)
    try {
        $current = Get-P2TProcessStamp -ProcessId $Stamp.Id
        return ($current.Path -eq $Stamp.Path -and $current.StartFileTime -eq $Stamp.StartFileTime)
    } catch { return $false }
}
function Remove-P2TOwnedNetwork {
    param($State)
    # An alias alone is insufficient evidence. Match GUID captured after creation.
    if (-not $State.AdapterGuid -or $State.InterfaceName -notmatch '^p2t-[a-f0-9]{10}$') { return }
    $adapter = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq $State.InterfaceName -and $_.InterfaceGuid.ToString() -eq $State.AdapterGuid
    }
    if ($adapter) {
        Get-NetRoute -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction Stop
        $adapter | Disable-NetAdapter -Confirm:$false -ErrorAction Stop
    }
}
function Stop-P2TOwnedChild {
    param($Child, $State, [string]$StatePath, [string]$LogPath)
    if ($Child) {
        $graceful = $Child.StopGracefully(3000)
        $Child.Dispose()
    }
    if ($State) {
        Remove-P2TOwnedNetwork -State $State
        $State.Child = $null; $State.Status = 'Waiting'; $State.AdapterGuid = $null
        Write-P2TState -State $State -Path $StatePath
    }
    if ($Child) { Write-P2TLog -Path $LogPath -Message ('TUN stopped (graceful={0}); owned adapter cleanup completed.' -f $graceful) }
}
Export-ModuleMember -Function *-P2T*
