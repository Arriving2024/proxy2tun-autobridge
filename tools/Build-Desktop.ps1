#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw 'Build on 64-bit Windows with Windows PowerShell 5.1 or newer.' }
$sourceVersion=([IO.File]::ReadAllText((Join-Path $repo 'VERSION'))).Trim()
if(-not $Version){$Version=$sourceVersion}
if ($sourceVersion -cne $Version -or $Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Build version does not match VERSION.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo ('dist\desktop-' + $Version) }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if ($OutputDirectory -eq $repo) { throw 'Use a separate build output directory.' }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The system .NET Framework x64 C# compiler is missing.' }

# Payload sources are deliberately explicit. Never scan runtime, bin or user data.
$payloadFiles = @(
    'Start-Bridge.ps1', 'Stop-Bridge.ps1', 'Stop-Misty-TUN.ps1', 'Show-Logs.ps1',
    'Start-Bridge.cmd', 'Stop-Bridge.cmd', 'install.ps1', 'uninstall.ps1',
    'README.md', 'CHANGELOG.md', 'RELEASE_NOTES.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md', '.gitignore', 'VERSION',
    'src/Discovery.psm1', 'src/Config.psm1', 'src/Lifecycle.psm1', 'src/Health.psm1', 'src/NativeProcess.cs',
    'src/Desktop.psm1', 'src/DesktopApp.cs', 'desktop/Backend.ps1',
    'tools/Repair-LegacyScriptEncoding.ps1', 'tools/Build-Desktop.ps1',
    'docs/architecture.md', 'docs/troubleshooting.md', 'docs/validation.md', 'docs/field-debug.md', 'docs/desktop.md'
) | Sort-Object -Unique

function Assert-RegularBuildPath([string]$Path) {
    $probe = [IO.Path]::GetFullPath($Path)
    while ($probe) {
        if (Test-Path -LiteralPath $probe) {
            $item = Get-Item -LiteralPath $probe -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('Refusing build path through a reparse point: ' + $probe) }
        }
        $parent = [IO.Directory]::GetParent($probe)
        if ($null -eq $parent) { break }
        $probe = $parent.FullName
    }
}
function Get-BytesHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
$snapshots = @{}
$records = New-Object 'Collections.Generic.List[object]'
foreach ($relative in $payloadFiles) {
    $path = [IO.Path]::GetFullPath((Join-Path $repo $relative))
    if (-not $path.StartsWith($repo.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Payload path escaped repository.' }
    Assert-RegularBuildPath $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Missing payload source: ' + $relative) }
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($relative -match '\.ps(m1|1)$') {
        $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0
        $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
        if ($nonAscii -and -not $bom) { throw ('PowerShell requires ASCII or UTF-8 BOM: ' + $relative) }
        $null = (New-Object Text.UTF8Encoding($false,$true)).GetString($bytes)
    }
    $snapshots[$relative] = $bytes
    $records.Add([ordered]@{path=$relative;sha256=(Get-BytesHash $bytes)})
}
$guiSource = [Text.Encoding]::UTF8.GetString($snapshots['src/DesktopApp.cs'])
if ($guiSource -notmatch ('const\s+string\s+Version\s*=\s*"' + [regex]::Escape($Version) + '"\s*;')) {
    throw 'Desktop source version does not match the build and payload version.'
}
$manifest = [ordered]@{version=$Version;files=$records.ToArray()}
$manifestText = $manifest | ConvertTo-Json -Depth 6
$utf8 = New-Object Text.UTF8Encoding($false)
$manifestBytes = $utf8.GetBytes($manifestText)
Assert-RegularBuildPath $OutputDirectory
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$exePath = Join-Path $OutputDirectory ('Proxy2TUN-AutoBridge-v' + $Version + '.exe')
$sumPath = Join-Path $OutputDirectory 'SHA256SUMS.txt'
foreach ($path in @($exePath,$sumPath)) { if (Test-Path -LiteralPath $path) { throw ('Output exists; choose a fresh output directory: ' + $path) } }
$stage = Join-Path $OutputDirectory ('.desktop-build-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stage
$zipPath = Join-Path $stage 'payload.zip'
$sourcePath = Join-Path $stage 'DesktopApp.cs'
$manifestPath = Join-Path $stage 'app.manifest'
$completed = $false
try {
    Add-Type -AssemblyName System.IO.Compression
    $zipStream = [IO.File]::Open($zipPath,[IO.FileMode]::CreateNew)
    $zip = $null
    try {
        $zip = New-Object IO.Compression.ZipArchive($zipStream,[IO.Compression.ZipArchiveMode]::Create,$true)
        foreach ($relative in @($payloadFiles) + @('desktop-payload.json')) {
            $bytes = if ($relative -ceq 'desktop-payload.json') { $manifestBytes } else { $snapshots[$relative] }
            $entry = $zip.CreateEntry($relative,[IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]'2000-01-01T00:00:00Z'
            $target = $entry.Open()
            try { $target.Write($bytes,0,$bytes.Length) } finally { $target.Dispose() }
        }
    } finally { if ($zip) { $zip.Dispose() }; $zipStream.Dispose() }
    # Verify the actual archive, including every source hash and its exact entry set.
    $zipStream = [IO.File]::OpenRead($zipPath)
    $zip = $null
    try {
        $zip = New-Object IO.Compression.ZipArchive($zipStream,[IO.Compression.ZipArchiveMode]::Read,$true)
        if ($zip.Entries.Count -ne ($records.Count + 1)) { throw 'Payload entry count mismatch.' }
        foreach ($record in $records) {
            $entry = $zip.GetEntry($record.path)
            if (-not $entry -or $entry.Length -ne $snapshots[$record.path].Length) { throw ('Payload entry mismatch: ' + $record.path) }
            $input = $entry.Open()
            $memory = New-Object IO.MemoryStream
            try { $input.CopyTo($memory); $actualHash = Get-BytesHash $memory.ToArray() }
            finally { $input.Dispose(); $memory.Dispose() }
            if ($actualHash -cne $record.sha256) { throw ('Payload SHA-256 mismatch: ' + $record.path) }
        }
        $reader = New-Object IO.StreamReader($zip.GetEntry('desktop-payload.json').Open(),$utf8)
        try { if ($reader.ReadToEnd() -cne $manifestText) { throw 'Payload manifest mismatch.' } }
        finally { $reader.Dispose() }
    } finally { if ($zip) { $zip.Dispose() }; $zipStream.Dispose() }
    [IO.File]::WriteAllBytes($sourcePath,$snapshots['src/DesktopApp.cs'])
    # The application performs its own one-time UAC flow; preview/self-test stay unelevated.
    $applicationManifest = @'
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <assemblyIdentity version="0.3.0.0" name="Proxy2Tun.Desktop" />
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges><requestedExecutionLevel level="asInvoker" uiAccess="false" /></requestedPrivileges></security></trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1"><application><supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}" /></application></compatibility>
</assembly>
'@
    $applicationManifest = $applicationManifest.Replace('version="0.3.0.0"',('version="' + $Version + '.0"'))
    [IO.File]::WriteAllText($manifestPath,$applicationManifest,$utf8)
    $compilerArgs = @('/nologo','/target:winexe','/platform:x64','/optimize+','/codepage:65001',
        ('/out:' + $exePath),('/win32manifest:' + $manifestPath),('/resource:' + $zipPath + ',Proxy2Tun.Payload.zip'),
        '/reference:System.dll','/reference:System.Core.dll','/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll',
        '/reference:System.Web.Extensions.dll','/reference:System.IO.Compression.dll','/reference:System.IO.Compression.FileSystem.dll',$sourcePath)
    & $compiler @compilerArgs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw 'Desktop C# compilation failed.' }
    $exeBytes = [IO.File]::ReadAllBytes($exePath)
    $peOffset = [BitConverter]::ToInt32($exeBytes,60)
    if ($peOffset -lt 0 -or $peOffset + 96 -gt $exeBytes.Length -or
        [BitConverter]::ToUInt16($exeBytes,$peOffset+4) -ne 0x8664 -or
        [BitConverter]::ToUInt16($exeBytes,$peOffset+24) -ne 0x20b -or
        [BitConverter]::ToUInt16($exeBytes,$peOffset+24+68) -ne 2) { throw 'Expected an x64 Windows GUI PE executable.' }
    # Loading assembly bytes does not invoke Main. Compare the embedded resource bytes.
    $assembly = [Reflection.Assembly]::Load($exeBytes)
    $resource = $assembly.GetManifestResourceStream('Proxy2Tun.Payload.zip')
    if (-not $resource) { throw 'Desktop executable is missing its payload resource.' }
    $memory = New-Object IO.MemoryStream
    try { $resource.CopyTo($memory); $resourceHash = Get-BytesHash $memory.ToArray() }
    finally { $resource.Dispose(); $memory.Dispose() }
    if ($resourceHash -cne (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Embedded payload differs from the checked archive.' }
    $checksum = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($sumPath,($checksum + '  ' + [IO.Path]::GetFileName($exePath) + "`r`n"),$utf8)
    $completed = $true
    Write-Host ('PASS desktop x64 GUI build: ' + $exePath)
    Write-Host ('Verified embedded payload: ' + $records.Count + ' explicit source files plus manifest; no third-party binaries or runtime data.')
    Write-Host ('SHA-256: ' + $checksum)
} finally {
    # Only the three known build files are cleaned. No recursive cleanup is used.
    foreach ($knownFile in @($zipPath,$sourcePath,$manifestPath)) {
        if (Test-Path -LiteralPath $knownFile -PathType Leaf) { Remove-Item -LiteralPath $knownFile -Force }
    }
    if ((Test-Path -LiteralPath $stage -PathType Container) -and @(Get-ChildItem -LiteralPath $stage -Force).Count -eq 0) { Remove-Item -LiteralPath $stage }
    if (-not $completed) { Write-Warning 'Desktop build did not complete. Do not distribute unverified output.' }
}
