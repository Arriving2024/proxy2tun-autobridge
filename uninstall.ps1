#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir,
    [switch]$PurgeData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $InstallDir) { $InstallDir = $PSScriptRoot }
$allowedFiles = @(
    'Start-Bridge.ps1', 'Stop-Bridge.ps1', 'Show-Logs.ps1',
    'Start-Bridge.cmd', 'Stop-Bridge.cmd', 'install.ps1', 'uninstall.ps1',
    'README.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md', '.gitignore',
    'src/Discovery.psm1', 'src/Config.psm1', 'src/Lifecycle.psm1', 'src/NativeProcess.cs',
    'docs/architecture.md', 'docs/troubleshooting.md', 'docs/validation.md', 'bin/sing-box.exe'
)

function Assert-OwnedPath([string]$Path, [string]$Root) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing a path outside the verified installation directory: $Path"
    }
    $probe = $full
    while (-not [string]::IsNullOrEmpty($probe)) {
        if (Test-Path -LiteralPath $probe) {
            $item = Get-Item -LiteralPath $probe -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a junction or symbolic link: $probe" }
        }
        $parent = [IO.Directory]::GetParent($probe)
        if ($null -eq $parent) { break }
        $probe = $parent.FullName
    }
    return $full
}

$target = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $target -PathType Container) -or $target.StartsWith('\\')) {
    throw 'Specify the local directory created by install.ps1.'
}
$marker = Assert-OwnedPath (Join-Path $target '.proxy2tun-install.json') $target
if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'Missing installation ownership manifest. No files were removed. A source checkout is not an installation.' }
$manifest = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
if ($manifest.project -cne 'Proxy2TUN-AutoBridge' -or $manifest.schemaVersion -ne 1 -or $manifest.installRoot -ine $target) {
    throw 'Installation ownership manifest does not match this exact directory. No files were removed.'
}
$records = @($manifest.files)
if ($records.Count -ne $allowedFiles.Count) { throw 'Unexpected installation file list. No files were removed.' }
$seen = @{}
$verifiedPaths = @()
foreach ($record in $records) {
    $relative = [string]$record.path
    if ($allowedFiles -cnotcontains $relative -or $seen.ContainsKey($relative) -or [string]$record.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw "Unexpected or duplicate manifest path: $relative. No files were removed."
    }
    $seen[$relative] = $true
    $verifiedPaths += Assert-OwnedPath (Join-Path $target $relative) $target
}

# Check the complete optional purge tree before stopping or removing anything.
$dataRoot = Assert-OwnedPath (Join-Path $target 'runtime') $target
$dataFiles = New-Object 'System.Collections.Generic.List[string]'
$dataDirectories = New-Object 'System.Collections.Generic.List[string]'
function Find-DataEntries([string]$Directory) {
    $null = Assert-OwnedPath $Directory $target
    foreach ($entry in @(Get-ChildItem -LiteralPath $Directory -Force)) {
        $full = Assert-OwnedPath $entry.FullName $target
        if ($entry.PSIsContainer) {
            Find-DataEntries $full
            $dataDirectories.Add($full)
        } else { $dataFiles.Add($full) }
    }
}
if ($PurgeData -and (Test-Path -LiteralPath $dataRoot -PathType Container)) { Find-DataEntries $dataRoot }

$stopPath = Join-Path $target 'Stop-Bridge.ps1'
$stopRecord = @($records | Where-Object { $_.path -ceq 'Stop-Bridge.ps1' })[0]
if (-not (Test-Path -LiteralPath $stopPath -PathType Leaf) -or (Get-FileHash -LiteralPath $stopPath -Algorithm SHA256).Hash -ine $stopRecord.sha256) {
    throw 'Installed stop script is missing or modified. Restore it and stop the bridge before uninstalling.'
}
Write-Host 'Stopping this installation before removing its files...'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopPath
if ($LASTEXITCODE -ne 0) { throw 'The bridge could not be stopped. No installation files were removed. Try again from an elevated PowerShell window.' }

foreach ($path in $verifiedPaths) {
    $null = Assert-OwnedPath $path $target
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
}
if ($PurgeData -and (Test-Path -LiteralPath $dataRoot -PathType Container)) {
    # Stop may have written final logs, so revalidate the current tree before deletion.
    $dataFiles.Clear()
    $dataDirectories.Clear()
    Find-DataEntries $dataRoot
    foreach ($file in $dataFiles) {
        $null = Assert-OwnedPath $file $target
        Remove-Item -LiteralPath $file -Force
    }
    foreach ($directory in $dataDirectories) {
        $null = Assert-OwnedPath $directory $target
        if (@(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) { Remove-Item -LiteralPath $directory }
    }
    if (@(Get-ChildItem -LiteralPath $dataRoot -Force).Count -eq 0) { Remove-Item -LiteralPath $dataRoot }
}
Remove-Item -LiteralPath $marker -Force
foreach ($name in @('src', 'docs', 'bin')) {
    $directory = Assert-OwnedPath (Join-Path $target $name) $target
    if ((Test-Path -LiteralPath $directory -PathType Container) -and @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) { Remove-Item -LiteralPath $directory }
}
if (@(Get-ChildItem -LiteralPath $target -Force).Count -eq 0) {
    Remove-Item -LiteralPath $target
    Write-Host 'Uninstalled; the empty installation directory was removed.'
} else {
    Write-Host "Uninstalled. Retained runtime data or other user files remain at: $target"
}
Write-Host 'Other proxy clients and shared Windows TUN drivers were not removed.'
