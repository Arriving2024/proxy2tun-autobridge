#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir,
    [switch]$PurgeData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $InstallDir) { $InstallDir = $PSScriptRoot }
$sourceFiles = @(
    'Start-Bridge.ps1', 'Stop-Bridge.ps1', 'Stop-Misty-TUN.ps1', 'Show-Logs.ps1',
    'Start-Bridge.cmd', 'Stop-Bridge.cmd', 'install.ps1', 'uninstall.ps1',
    'README.md', 'CHANGELOG.md', 'RELEASE_NOTES.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md', '.gitignore', 'VERSION',
    'src/Discovery.psm1', 'src/Config.psm1', 'src/Lifecycle.psm1', 'src/Health.psm1', 'src/NativeProcess.cs',
    'src/Desktop.psm1', 'src/DesktopApp.cs', 'desktop/Backend.ps1',
    'tools/Repair-LegacyScriptEncoding.ps1', 'tools/Build-Desktop.ps1',
    'docs/architecture.md', 'docs/troubleshooting.md', 'docs/validation.md', 'docs/field-debug.md', 'docs/desktop.md'
)
$allowedFiles = @($sourceFiles) + @('bin/sing-box.exe')

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
$desktop = $false
if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    $marker = Assert-OwnedPath (Join-Path $target '.proxy2tun-desktop-install.json') $target
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'Missing installation ownership manifest. No files were removed. A source checkout is not an installation.' }
    $desktop = $true
    $allowedFiles = @($sourceFiles)
}
$manifest = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
$expectedProject = if ($desktop) { 'Proxy2TUN-AutoBridge-Desktop' } else { 'Proxy2TUN-AutoBridge' }
if ($manifest.project -cne $expectedProject -or $manifest.schemaVersion -ne 1 -or $manifest.installRoot -ine $target) {
    throw 'Installation ownership manifest does not match this exact directory. No files were removed.'
}
$desktopExtras = @()
if ($desktop) {
    $declaredVersion = ([IO.File]::ReadAllText((Join-Path $target 'VERSION'))).Trim()
    if ($manifest.version -cne $declaredVersion) { throw 'Desktop ownership version mismatch. No files were removed.' }
    $payloadPath = Assert-OwnedPath (Join-Path $target 'desktop-payload.json') $target
    if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) { throw 'Desktop payload manifest is missing. No files were removed.' }
    $payload = Get-Content -LiteralPath $payloadPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($payload.version -cne $declaredVersion -or @($payload.files).Count -ne @($manifest.files).Count) { throw 'Desktop payload ownership mismatch.' }
    $desktopExtras += $payloadPath
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
    $verifiedPath = Assert-OwnedPath (Join-Path $target $relative) $target
    if ($desktop) {
        $payloadRecord = @($payload.files | Where-Object { $_.path -ceq $relative })
        if ($payloadRecord.Count -ne 1 -or $payloadRecord[0].sha256 -cne $record.sha256) { throw 'Desktop payload file record mismatch.' }
    }
    $verifiedPaths += $verifiedPath
}

if ($desktop) {
    # The EXE itself is outside this directory. Only the fixed, verified optional
    # downloaded dependency and its receipt may be removed beside payload files.
    $receiptPath = Assert-OwnedPath (Join-Path $target 'bin/sing-box.receipt.json') $target
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $officialExeHash = '7bbef1dea9189ee12799ae834ea4b4658355da25c47a21ad8804904c0ccd9410'
        if ($receipt.version -cne '1.14.2' -or $receipt.exeSha256 -ine $officialExeHash) { throw 'Desktop dependency receipt is not the pinned official version. No files were removed.' }
        $binaryPath = Assert-OwnedPath (Join-Path $target 'bin/sing-box.exe') $target
        if (Test-Path -LiteralPath $binaryPath -PathType Leaf) {
            if ((Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash -ine $officialExeHash) { throw 'Desktop dependency changed after verification. No files were removed.' }
            $desktopExtras += $binaryPath
        }
        $desktopExtras += $receiptPath
    }
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
foreach ($path in $desktopExtras) {
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
foreach ($name in @('src', 'docs', 'bin', 'tools', 'desktop')) {
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
