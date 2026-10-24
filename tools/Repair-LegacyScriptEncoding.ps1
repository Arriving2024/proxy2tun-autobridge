#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $SourcePath).ProviderPath
$destination = [IO.Path]::GetFullPath($OutputPath)
if ([IO.Path]::GetExtension($source) -notin @('.ps1','.psm1') -or [IO.Path]::GetExtension($destination) -notin @('.ps1','.psm1')) { throw 'Source and output must be PowerShell script files.' }
if ($source -ieq $destination -or (Test-Path -LiteralPath $destination)) { throw 'Choose a new output file; this tool never overwrites a source or existing file.' }
# Decode strictly. Guessing ANSI encodings can silently corrupt an already
# damaged script. Such scripts must be restored from a known-good backup.
$encoding = New-Object Text.UTF8Encoding($false,$true)
$text = $encoding.GetString([IO.File]::ReadAllBytes($source)).TrimStart([char]0xFEFF)
$tokens = $null; $errors = $null
$null = [Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
if (@($errors).Count) { throw 'Decoded script has syntax errors. Restore a known-good copy; changing encoding cannot repair damaged source text.' }
$withBom = New-Object Text.UTF8Encoding($true)
$stream = [IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
try {
    $preamble = $withBom.GetPreamble(); $payload = $withBom.GetBytes($text)
    $stream.Write($preamble,0,$preamble.Length); $stream.Write($payload,0,$payload.Length)
} finally { $stream.Dispose() }
$null = [Management.Automation.Language.Parser]::ParseFile($destination,[ref]$tokens,[ref]$errors)
if (@($errors).Count) { throw 'Output failed the local PowerShell parser. Source was preserved.' }
Write-Host 'Created a syntax-checked UTF-8 BOM copy. Review it before any manual replacement; no script was executed.'
