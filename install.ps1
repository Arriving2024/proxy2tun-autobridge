#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Proxy2TUN-AutoBridge'),
    [string]$SingBoxPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$version = '1.14.2'
$assetUrl = 'https://github.com/SagerNet/sing-box/releases/download/v1.14.2/sing-box-1.14.2-windows-amd64.zip'
$assetSha256 = 'c2d8bfff918755808781dfdeeb8581b6c91eb3a243d9a7b55483cfc0c0684d32'
$sourceFiles = @(
    'Start-Bridge.ps1', 'Stop-Bridge.ps1', 'Show-Logs.ps1',
    'Start-Bridge.cmd', 'Stop-Bridge.cmd', 'install.ps1', 'uninstall.ps1',
    'README.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md', '.gitignore',
    'src/Discovery.psm1', 'src/Config.psm1', 'src/Lifecycle.psm1', 'src/NativeProcess.cs',
    'docs/architecture.md', 'docs/troubleshooting.md', 'docs/validation.md'
)

function Assert-NoReparseAncestor([string]$Path) {
    $probe = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($probe)) {
        if (Test-Path -LiteralPath $probe) {
            $item = Get-Item -LiteralPath $probe -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a junction or symbolic link in installation path: $probe"
            }
        }
        $parent = [IO.Directory]::GetParent($probe)
        if ($null -eq $parent) { break }
        $probe = $parent.FullName
    }
}

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
    throw 'Use 64-bit Windows PowerShell 5.1 or newer on Windows 11 x64.'
}
$target = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\', '/')
if ($target.StartsWith('\\') -or $target -eq [IO.Path]::GetPathRoot($target).TrimEnd('\', '/')) {
    throw 'The installation directory must be a new local subdirectory, not a drive root or network share.'
}
Assert-NoReparseAncestor $target
if (Test-Path -LiteralPath $target) {
    throw "Installation directory already exists. Nothing was changed. Use another new directory or uninstall the previous copy first: $target"
}
foreach ($relative in $sourceFiles) {
    $source = Join-Path $PSScriptRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Source package is incomplete: $relative" }
    Assert-NoReparseAncestor $source
}

$stage = Join-Path ([IO.Path]::GetTempPath()) ('Proxy2TUN-install-' + [Guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $stage 'sing-box.zip'
$stagedExe = Join-Path $stage 'sing-box.exe'
$createdFiles = New-Object 'System.Collections.Generic.List[string]'
$createdDirectories = New-Object 'System.Collections.Generic.List[string]'
$targetCreated = $false
$complete = $false
try {
    New-Item -ItemType Directory -Path $stage -ErrorAction Stop | Out-Null
    if ($SingBoxPath) {
        $provided = (Resolve-Path -LiteralPath $SingBoxPath -ErrorAction Stop).ProviderPath
        if (-not (Test-Path -LiteralPath $provided -PathType Leaf)) { throw '-SingBoxPath must name an existing sing-box.exe file.' }
        Copy-Item -LiteralPath $provided -Destination $stagedExe -ErrorAction Stop
        Write-Host 'Using the sing-box executable supplied by you; its trust is your responsibility.'
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Host "Downloading sing-box $version from its official SagerNet GitHub release..."
        $oldProgress = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -UseBasicParsing -Uri $assetUrl -OutFile $archivePath -TimeoutSec 300
        } finally { $ProgressPreference = $oldProgress }
        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $assetSha256) { throw "Official archive SHA-256 mismatch. Refusing to install. Expected $assetSha256; got $actualHash" }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $entryName = 'sing-box-1.14.2-windows-amd64/sing-box.exe'
            $entries = @($zip.Entries | Where-Object { $_.FullName -ceq $entryName })
            if ($entries.Count -ne 1) { throw "Official archive is missing the exact expected executable: $entryName" }
            $inputStream = $entries[0].Open()
            try {
                $outputStream = [IO.File]::Open($stagedExe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
                try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
            } finally { $inputStream.Dispose() }
        } finally { $zip.Dispose() }
    }

    $versionText = (& $stagedExe version 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '(?m)^sing-box version 1\.14\.2\s*$' -or $versionText -notmatch 'windows/amd64') {
        throw "This release requires sing-box 1.14.2 for Windows amd64. Supplied binary reported: $versionText"
    }
    # CreateNew via Directory.CreateDirectory would accept a concurrently-created directory;
    # New-Item without -Force instead refuses it before any source copy occurs.
    New-Item -ItemType Directory -Path $target -ErrorAction Stop | Out-Null
    $targetCreated = $true
    Assert-NoReparseAncestor $target
    foreach ($directoryName in @('src', 'docs', 'bin')) {
        $directoryPath = Join-Path $target $directoryName
        New-Item -ItemType Directory -Path $directoryPath -ErrorAction Stop | Out-Null
        $createdDirectories.Add($directoryPath)
    }
    foreach ($relative in $sourceFiles) {
        $destination = Join-Path $target $relative
        $createdFiles.Add($destination)
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relative) -Destination $destination -ErrorAction Stop
    }
    $binaryDestination = Join-Path $target 'bin/sing-box.exe'
    $createdFiles.Add($binaryDestination)
    Copy-Item -LiteralPath $stagedExe -Destination $binaryDestination
    $installed = @($sourceFiles) + @('bin/sing-box.exe')
    $records = @(foreach ($relative in $installed) {
        [ordered]@{ path = $relative; sha256 = (Get-FileHash -LiteralPath (Join-Path $target $relative) -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $manifest = [ordered]@{
        project = 'Proxy2TUN-AutoBridge'; schemaVersion = 1; version = '0.1.0'
        installRoot = $target; createdUtc = [DateTime]::UtcNow.ToString('o'); files = $records
    }
    $marker = Join-Path $target '.proxy2tun-install.json'
    $createdFiles.Add($marker)
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $marker -Encoding UTF8
    $complete = $true
    Write-Host "Installed: $target"
    Write-Host 'No service, scheduled task, startup entry, system proxy setting, or network route was added.'
    Write-Host 'Open the installed folder, then right-click Start-Bridge.cmd and choose Run as administrator.'
} finally {
    if ($targetCreated -and -not $complete) {
        Write-Warning 'Installation did not complete. Removing only files created by this attempt.'
        foreach ($file in $createdFiles) {
            if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        }
        for ($i = $createdDirectories.Count - 1; $i -ge 0; $i--) {
            $directoryPath = $createdDirectories[$i]
            if ((Test-Path -LiteralPath $directoryPath -PathType Container) -and @(Get-ChildItem -LiteralPath $directoryPath -Force).Count -eq 0) {
                Remove-Item -LiteralPath $directoryPath -ErrorAction SilentlyContinue
            }
        }
        if ((Test-Path -LiteralPath $target -PathType Container) -and @(Get-ChildItem -LiteralPath $target -Force).Count -eq 0) {
            Remove-Item -LiteralPath $target -ErrorAction SilentlyContinue
        }
    }
    # Only these two known staging files are ever removed; no recursive path deletion.
    foreach ($stagedFile in @($archivePath, $stagedExe)) {
        if (Test-Path -LiteralPath $stagedFile -PathType Leaf) { Remove-Item -LiteralPath $stagedFile -Force -ErrorAction SilentlyContinue }
    }
    if ((Test-Path -LiteralPath $stage -PathType Container) -and @(Get-ChildItem -LiteralPath $stage -Force).Count -eq 0) {
        Remove-Item -LiteralPath $stage -ErrorAction SilentlyContinue
    }
}
