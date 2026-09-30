#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SingBoxPath,
    [string]$ScratchRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $ScratchRoot) { $ScratchRoot = [IO.Path]::GetTempPath() }
$sourceRoot = Split-Path $PSScriptRoot -Parent
$binary = (Resolve-Path -LiteralPath $SingBoxPath).ProviderPath
$scratch = Join-Path ([IO.Path]::GetFullPath($ScratchRoot)) ('p2t-install-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$script:passed = 0
$script:sequence = 0

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Pass-Test([string]$Name) {
    $script:passed++
    Write-Host ('PASS {0}: {1}' -f $script:passed, $Name)
}
function Run-Script([string]$Path, [string[]]$Arguments, [bool]$ExpectSuccess) {
    $script:sequence++
    $log = Join-Path $scratch ('command-{0}.log' -f $script:sequence)
    # A child Windows PowerShell process tests actual 5.1 entry-point behavior.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments *> $log
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    $success = ($code -eq 0)
    if ($success -ne $ExpectSuccess) { throw "Unexpected exit code $code; inspect $log" }
}

$target = Join-Path $scratch 'install-default'
Run-Script (Join-Path $sourceRoot 'install.ps1') @('-InstallDir', $target, '-SingBoxPath', $binary) $true
$marker = Join-Path $target '.proxy2tun-install.json'
$raw = Get-Content -LiteralPath $marker -Raw
$manifest = $raw | ConvertFrom-Json
Assert-Test ($manifest.installRoot -ieq $target) 'Manifest root differs.'
Assert-Test (@($manifest.files).Count -eq 19) 'Installation file count differs.'
Assert-Test (Test-Path -LiteralPath (Join-Path $target 'bin/sing-box.exe')) 'Binary was not installed.'
Pass-Test 'fresh installation, exact ownership root, 19 allowlisted files'

$sentinel = Join-Path $target 'user-file.txt'
'user sentinel' | Set-Content -LiteralPath $sentinel
Run-Script (Join-Path $sourceRoot 'install.ps1') @('-InstallDir', $target, '-SingBoxPath', $binary) $false
Assert-Test ((Get-Content -LiteralPath $sentinel -Raw).Trim() -ceq 'user sentinel') 'Existing user file changed.'
Pass-Test 'existing destination refused with user file intact'

Run-Script (Join-Path $sourceRoot 'uninstall.ps1') @('-InstallDir', $sourceRoot) $false
Assert-Test (Test-Path -LiteralPath (Join-Path $sourceRoot 'Start-Bridge.ps1')) 'Source file was removed.'
Pass-Test 'source checkout uninstall refused'

$unowned = Join-Path $scratch 'unowned'
New-Item -ItemType Directory -Path $unowned | Out-Null
'unrelated sentinel' | Set-Content -LiteralPath (Join-Path $unowned 'keep.txt')
Run-Script (Join-Path $sourceRoot 'uninstall.ps1') @('-InstallDir', $unowned, '-PurgeData') $false
Assert-Test (Test-Path -LiteralPath (Join-Path $unowned 'keep.txt')) 'Unowned user file removed.'
Pass-Test 'unowned directory refused'

$manifest.files[0].path = '../outside.txt'
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $marker -Encoding UTF8
Run-Script (Join-Path $target 'uninstall.ps1') @() $false
Assert-Test (Test-Path -LiteralPath (Join-Path $target 'bin/sing-box.exe')) 'Refusal removed installed binary.'
$raw | Set-Content -LiteralPath $marker -Encoding UTF8
Pass-Test 'path traversal in manifest refused before deletion'

$runtime = Join-Path $target 'runtime'
New-Item -ItemType Directory -Path $runtime | Out-Null
'retained log' | Set-Content -LiteralPath (Join-Path $runtime 'example.log')
Run-Script (Join-Path $target 'uninstall.ps1') @() $true
Assert-Test (Test-Path -LiteralPath (Join-Path $runtime 'example.log')) 'Default uninstall removed logs.'
Assert-Test (Test-Path -LiteralPath $sentinel) 'Default uninstall removed user file.'
Assert-Test (-not (Test-Path -LiteralPath $marker)) 'Manifest not removed.'
foreach ($record in @(($raw | ConvertFrom-Json).files)) {
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $target $record.path))) ('Installed file remains: ' + $record.path)
}
Pass-Test 'default uninstall removes all owned files and retains runtime/user files'

$purgeTarget = Join-Path $scratch 'install-purge'
Run-Script (Join-Path $sourceRoot 'install.ps1') @('-InstallDir', $purgeTarget, '-SingBoxPath', $binary) $true
$purgeRuntime = Join-Path $purgeTarget 'runtime'
New-Item -ItemType Directory -Path (Join-Path $purgeRuntime 'nested') | Out-Null
'to purge' | Set-Content -LiteralPath (Join-Path $purgeRuntime 'nested/example.log')
'keep' | Set-Content -LiteralPath (Join-Path $purgeTarget 'user-file.txt')

# Junctions require no symbolic-link privilege on ordinary Windows NTFS volumes.
$junction = Join-Path $purgeRuntime 'outside-link'
New-Item -ItemType Junction -Path $junction -Target $unowned | Out-Null
Run-Script (Join-Path $purgeTarget 'uninstall.ps1') @('-PurgeData') $false
Assert-Test (Test-Path -LiteralPath (Join-Path $unowned 'keep.txt')) 'Junction target was touched.'
Assert-Test (Test-Path -LiteralPath (Join-Path $purgeTarget 'bin/sing-box.exe')) 'Junction refusal removed binary.'
# Remove only the junction object, never recursively and never its target.
Assert-Test ([IO.Path]::GetFullPath($junction).StartsWith($scratch + '\', [StringComparison]::OrdinalIgnoreCase)) 'Junction path escaped scratch directory.'
[IO.Directory]::Delete($junction)
Pass-Test 'runtime junction refused without touching its target'

Run-Script (Join-Path $purgeTarget 'uninstall.ps1') @('-PurgeData') $true
Assert-Test (-not (Test-Path -LiteralPath $purgeRuntime)) 'Purge left runtime data.'
Assert-Test (Test-Path -LiteralPath (Join-Path $purgeTarget 'user-file.txt')) 'Purge removed unrelated user file.'
Assert-Test (-not (Test-Path -LiteralPath (Join-Path $purgeTarget '.proxy2tun-install.json'))) 'Purge left install manifest.'
Pass-Test 'PurgeData removes nested runtime data but preserves other user files'

Write-Host ('Installer checks: {0}/8 PASS. No TUN was started. Test records: {1}' -f $script:passed, $scratch)
