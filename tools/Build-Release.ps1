#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version = 'v0.2.0',
    [string]$OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if ($OutputDirectory -eq $repo) { throw 'Choose a separate output directory, not the repository root.' }

# Sources must be tracked. New release files must be staged before this build.
$tracked = @(& git -C $repo ls-files --cached)
if ($LASTEXITCODE -ne 0 -or -not $tracked.Count) { throw 'Build requires a Git checkout with tracked release sources.' }
$revision = (& git -C $repo rev-parse HEAD | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the source revision.' }
$changes = @(& git -C $repo status --porcelain --untracked-files=no)
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify working-tree status.' }
$rootAllow = @(
    '.gitattributes', '.gitignore', 'LICENSE', 'VERSION', 'README.md', 'CHANGELOG.md',
    'RELEASE_NOTES.md', 'THIRD-PARTY-NOTICES.md',
    'install.ps1', 'uninstall.ps1', 'Start-Bridge.ps1', 'Stop-Bridge.ps1',
    'Show-Logs.ps1', 'Stop-Misty-TUN.ps1', 'Start-Bridge.cmd', 'Stop-Bridge.cmd'
)
$releaseAllow = @($rootAllow + @(
    'src/Config.psm1', 'src/Discovery.psm1', 'src/Health.psm1', 'src/Lifecycle.psm1', 'src/NativeProcess.cs',
    'tests/Test-All.ps1', 'tests/Test-ConfigTransaction.ps1', 'tests/Test-DiscoveryConfig.ps1',
    'tests/Test-Encoding.ps1', 'tests/Test-Health.ps1', 'tests/Test-Install.ps1', 'tests/Test-Lifecycle.ps1',
    'tests/Test-NetworkCleanup.ps1', 'tests/Test-Watcher.ps1', 'tests/fixtures/Lifecycle-Child.ps1', 'tests/fixtures/ProbeServer.cs',
    'docs/architecture.md', 'docs/troubleshooting.md', 'docs/validation.md',
    'tools/Build-Release.ps1', 'tools/Repair-LegacyScriptEncoding.ps1',
    '.github/workflows/windows-checks.yml', '.github/workflows/release.yml'
))
$sources = New-Object 'Collections.Generic.List[string]'
foreach ($relative in $tracked) {
    $relative = $relative.Replace('\','/')
    if ($releaseAllow -notcontains $relative) { throw ('Tracked file is outside the explicit release allowlist: ' + $relative) }
    $sources.Add($relative)
}
$sources = @($sources | Sort-Object -Unique)
foreach ($required in $releaseAllow) {
    if ($sources -notcontains $required) { throw ('Missing tracked required release source: ' + $required + '. Stage intended new release files before building.') }
}
$declaredVersion = ([IO.File]::ReadAllText((Join-Path $repo 'VERSION'))).Trim()
if ($Version -cne ('v' + $declaredVersion)) { throw 'Requested release version does not match VERSION.' }

$records = New-Object 'Collections.Generic.List[object]'
foreach ($relative in $sources) {
    $full = [IO.Path]::GetFullPath((Join-Path $repo $relative))
    if (-not $full.StartsWith($repo.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Source escaped repository.' }
    $item = Get-Item -LiteralPath $full -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw ('Refusing non-regular release source: ' + $relative) }
    $ancestor = $item.Directory
    while ($ancestor -and $ancestor.FullName -ne $repo) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('Refusing source through a junction: ' + $relative) }
        $ancestor = $ancestor.Parent
    }
    $bytes = [IO.File]::ReadAllBytes($full)
    if ($relative -match '\.ps(m1|1)$') {
        $ascii = $true
        foreach ($value in $bytes) { if ($value -gt 127) { $ascii = $false; break } }
        $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
        if (-not $ascii -and -not $bom) { throw ('PowerShell source must be ASCII or UTF-8 BOM for Windows PowerShell 5.1: ' + $relative) }
        if ($bom) { $null = (New-Object Text.UTF8Encoding($false,$true)).GetString($bytes,3,$bytes.Length-3) }
    }
    $records.Add([ordered]@{ Path=$relative; Bytes=$bytes.Length; SHA256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() })
}

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$outputProbe = Get-Item -LiteralPath $OutputDirectory -Force
while ($outputProbe) {
    if ($outputProbe.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing output through a junction or symbolic link.' }
    $outputProbe = $outputProbe.Parent
}
$baseName = 'Proxy2TUN-AutoBridge-' + $Version + '-windows-x64-source'
$archivePath = Join-Path $OutputDirectory ($baseName + '.zip')
$manifestPath = Join-Path $OutputDirectory ($baseName + '.manifest.json')
$sumPath = Join-Path $OutputDirectory 'SHA256SUMS.txt'
foreach ($outputPath in @($archivePath,$manifestPath,$sumPath)) {
    if (Test-Path -LiteralPath $outputPath) { throw ('Output already exists; choose a fresh output directory: ' + [IO.Path]::GetFileName($outputPath)) }
}
$manifest = [ordered]@{
    Project='Proxy2TUN AutoBridge'; Version=$Version; SourceRevision=$revision
    WorkingTreeChanges=($changes.Count -gt 0); SourceOnly=$true
    Files=$records.ToArray()
}
$manifestText = $manifest | ConvertTo-Json -Depth 6
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($manifestPath,$manifestText,$utf8)
Add-Type -AssemblyName System.IO.Compression
$zipStream = $null; $zip = $null
try {
    $zipStream = [IO.File]::Open($archivePath,[IO.FileMode]::CreateNew)
    $zip = New-Object IO.Compression.ZipArchive($zipStream,[IO.Compression.ZipArchiveMode]::Create,$true)
    foreach ($relative in $sources) {
        $entry = $zip.CreateEntry(($baseName + '/' + $relative),[IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]'2000-01-01T00:00:00Z'
        $target = $null; $source = $null
        try {
            $target = $entry.Open(); $source = [IO.File]::OpenRead((Join-Path $repo $relative)); $source.CopyTo($target)
        } finally { if ($source) { $source.Dispose() }; if ($target) { $target.Dispose() } }
    }
    $entry = $zip.CreateEntry(($baseName + '/release-file-manifest.json'))
    $entry.LastWriteTime = [DateTimeOffset]'2000-01-01T00:00:00Z'
    $target = $null
    try { $target=$entry.Open(); $encoded=$utf8.GetBytes($manifestText); $target.Write($encoded,0,$encoded.Length) } finally { if ($target) { $target.Dispose() } }
} finally { if ($zip) { $zip.Dispose() }; if ($zipStream) { $zipStream.Dispose() } }

# Verify the final archive bytes, names, and file count, not just source files.
$zipStream = [IO.File]::OpenRead($archivePath); $zip = $null
try {
    $zip = New-Object IO.Compression.ZipArchive($zipStream,[IO.Compression.ZipArchiveMode]::Read,$true)
    if ($zip.Entries.Count -ne ($records.Count + 1)) { throw 'Archive file count mismatch.' }
    foreach ($record in $records) {
        $entry = $zip.GetEntry(($baseName + '/' + $record.Path))
        if (-not $entry -or $entry.Length -ne $record.Bytes) { throw ('Archive entry mismatch: ' + $record.Path) }
        $source=$null; $hash=[Security.Cryptography.SHA256]::Create()
        try { $source=$entry.Open(); $actual=([BitConverter]::ToString($hash.ComputeHash($source))).Replace('-','').ToLowerInvariant() } finally { if ($source) { $source.Dispose() }; $hash.Dispose() }
        if ($actual -ne $record.SHA256) { throw ('Archive hash mismatch: ' + $record.Path) }
    }
    $manifestEntry = $zip.GetEntry(($baseName + '/release-file-manifest.json'))
    if (-not $manifestEntry) { throw 'Archive manifest missing.' }
    $reader = $null
    try { $reader = New-Object IO.StreamReader($manifestEntry.Open(),$utf8); $archivedManifest = $reader.ReadToEnd() } finally { if ($reader) { $reader.Dispose() } }
    if ($archivedManifest -cne $manifestText) { throw 'Archive manifest content mismatch.' }
} finally { if ($zip) { $zip.Dispose() }; $zipStream.Dispose() }
$sumLines = foreach ($path in @($archivePath,$manifestPath)) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($path) }
[IO.File]::WriteAllText($sumPath,($sumLines -join "`r`n") + "`r`n",$utf8)
Write-Host ('PASS source-only archive verified: ' + $archivePath)
Write-Host ('Files: ' + $records.Count + '; manifest: ' + $manifestPath)
Write-Host ('Checksums: ' + $sumPath)
