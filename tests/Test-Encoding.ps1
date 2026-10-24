#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$count = 0
foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') -and $_.FullName -notmatch '\\(runtime|\.git)\\' })) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $hasNonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    if ($hasNonAscii -and -not $hasBom) { throw ('Non-ASCII PowerShell requires UTF-8 BOM: ' + $file.Name) }
    $decoder = New-Object Text.UTF8Encoding($false,$true)
    $null = $decoder.GetString($bytes)
    $count++
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('p2t-encoding-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
try {
    $source = Join-Path $scratch 'legacy.ps1'; $output = Join-Path $scratch 'fixed.ps1'
    $unicodeText = "Write-Output '" + [char]0x505C + [char]0x6B62 + "'"
    [IO.File]::WriteAllText($source,$unicodeText,(New-Object Text.UTF8Encoding($false)))
    $before = (Get-FileHash -LiteralPath $source).Hash
    & (Join-Path $root 'tools\Repair-LegacyScriptEncoding.ps1') -SourcePath $source -OutputPath $output
    $actual = [IO.File]::ReadAllBytes($output)
    if ($actual[0] -ne 239 -or $actual[1] -ne 187 -or $actual[2] -ne 191) { throw 'Repair did not write BOM.' }
    if ((Get-FileHash -LiteralPath $source).Hash -ne $before) { throw 'Repair modified the source.' }
    $refused = $false
    try { & (Join-Path $root 'tools\Repair-LegacyScriptEncoding.ps1') -SourcePath $source -OutputPath $output } catch { $refused = $true }
    if (-not $refused) { throw 'Repair overwrote an existing file.' }
    [IO.File]::WriteAllText($source,"Write-Output '",(New-Object Text.UTF8Encoding($false)))
    $refused = $false
    try { & (Join-Path $root 'tools\Repair-LegacyScriptEncoding.ps1') -SourcePath $source -OutputPath (Join-Path $scratch 'invalid.ps1') } catch { $refused = $true }
    if (-not $refused) { throw 'Repair accepted damaged source.' }
    # Exercise the real stop entry point reading BOM-less UTF-8 state from a
    # non-ASCII installation path. No process or network owner is present.
    $unicodeRoot = Join-Path $scratch ([string][char]0x6D4B + [char]0x8BD5)
    $null = New-Item -ItemType Directory -Path (Join-Path $unicodeRoot 'src') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $unicodeRoot 'runtime') -Force
    Copy-Item -LiteralPath (Join-Path $root 'Stop-Bridge.ps1') -Destination $unicodeRoot
    Copy-Item -LiteralPath (Join-Path $root 'src\Lifecycle.psm1') -Destination (Join-Path $unicodeRoot 'src')
    $unicodeState = @{Schema=1;Root=$unicodeRoot;Owner=@{Id=2147483647;Path='fixture';StartFileTime='0'};Child=$null;AdapterGuid=$null;Status='Waiting'}
    $unicodeStatePath = Join-Path $unicodeRoot 'runtime\state.json'
    [IO.File]::WriteAllText($unicodeStatePath,($unicodeState | ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $unicodeRoot 'Stop-Bridge.ps1')
    if ($LASTEXITCODE -ne 0 -or (Get-Content -LiteralPath $unicodeStatePath -Raw -Encoding UTF8 | ConvertFrom-Json).Status -ne 'Stopped') { throw 'UTF-8 state failed in a non-ASCII installation path.' }
    Write-Host ('PASS encoding: {0} script files; BOM repair/source preservation/overwrite and syntax refusal; UTF-8 state in non-ASCII path' -f $count)
} finally {
    foreach ($name in @('legacy.ps1','fixed.ps1','invalid.ps1')) { Remove-Item -LiteralPath (Join-Path $scratch $name) -Force -ErrorAction SilentlyContinue }
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $resolvedUnicode = Join-Path $resolvedScratch ([string][char]0x6D4B + [char]0x8BD5)
    if ($resolvedUnicode.StartsWith($resolvedScratch + '\',[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedUnicode)) { Remove-Item -LiteralPath $resolvedUnicode -Recurse -Force }
    if (@(Get-ChildItem -LiteralPath $scratch -Force).Count -eq 0) { Remove-Item -LiteralPath $scratch }
}
