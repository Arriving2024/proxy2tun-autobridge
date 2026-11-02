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
$expectedVersion = ([IO.File]::ReadAllText((Join-Path $sourceRoot 'VERSION'))).Trim()
$tokens = $null; $parseErrors = $null
$installerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'install.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'Source installer cannot be parsed.' }
$sourceAssignment = $installerAst.Find({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$sourceFiles'},$true)
if (-not $sourceAssignment) { throw 'Cannot find explicit installer source allowlist.' }
$expectedSources = @($sourceAssignment.Right.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst]},$true) | ForEach-Object { $_.Value })
if ($expectedSources.Count -lt 1 -or @($expectedSources | Sort-Object -Unique).Count -ne $expectedSources.Count) { throw 'Installer source allowlist is empty or duplicated.' }
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
Assert-Test (@($manifest.files).Count -eq ($expectedSources.Count + 1)) 'Installation file count differs.'
Assert-Test ($manifest.version -ceq $expectedVersion) 'Installation version differs.'
Assert-Test ((Get-Content -LiteralPath (Join-Path $target 'VERSION') -Raw).Trim() -eq $manifest.version) 'Installed VERSION differs from manifest.'
Assert-Test (Test-Path -LiteralPath (Join-Path $target 'docs/field-debug.md')) 'Field-debug guide missing from installation.'
Assert-Test (Test-Path -LiteralPath (Join-Path $target 'src/Health.psm1')) 'Health module missing from installation.'
foreach ($relative in @('desktop/Backend.ps1','src/Desktop.psm1','src/DesktopApp.cs','tools/Build-Desktop.ps1','docs/desktop.md')) {
    Assert-Test (Test-Path -LiteralPath (Join-Path $target $relative)) ('Desktop source missing from installation: ' + $relative)
}
Assert-Test (Test-Path -LiteralPath (Join-Path $target 'bin/sing-box.exe')) 'Binary was not installed.'
Pass-Test ('fresh installation, exact ownership root, complete source allowlist and version ' + $expectedVersion)

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

function New-DesktopFixture([string]$Name) {
    $fixture = Join-Path $scratch $Name
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $records = @(foreach ($relative in $expectedSources) {
        $destination = Join-Path $fixture $relative
        $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
        Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $destination
        [ordered]@{path=$relative;sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    $payload = [ordered]@{version=$expectedVersion;files=$records}
    $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $fixture 'desktop-payload.json') -Encoding UTF8
    $ownership = [ordered]@{project='Proxy2TUN-AutoBridge-Desktop';schemaVersion=1;version=$expectedVersion;installRoot=$fixture;files=$records}
    $ownership | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $fixture '.proxy2tun-desktop-install.json') -Encoding UTF8
    return $fixture
}

$desktopTarget = New-DesktopFixture 'desktop-no-dependency'
$desktopRuntime = Join-Path $desktopTarget 'runtime'
$null = New-Item -ItemType Directory -Path $desktopRuntime
'private fixture diagnostic' | Set-Content -LiteralPath (Join-Path $desktopRuntime 'keep.log')
'user data' | Set-Content -LiteralPath (Join-Path $desktopTarget 'keep.txt')
Run-Script (Join-Path $desktopTarget 'uninstall.ps1') @() $true
Assert-Test (Test-Path -LiteralPath (Join-Path $desktopRuntime 'keep.log')) 'Desktop uninstall removed retained runtime.'
Assert-Test (Test-Path -LiteralPath (Join-Path $desktopTarget 'keep.txt')) 'Desktop uninstall removed user data.'
Assert-Test (-not (Test-Path -LiteralPath (Join-Path $desktopTarget 'desktop-payload.json'))) 'Desktop payload manifest remains.'
Assert-Test (-not (Test-Path -LiteralPath (Join-Path $desktopTarget '.proxy2tun-desktop-install.json'))) 'Desktop ownership marker remains.'
foreach ($relative in $expectedSources) { Assert-Test (-not (Test-Path -LiteralPath (Join-Path $desktopTarget $relative))) ('Desktop source remains: ' + $relative) }
Pass-Test 'desktop source-only installation uninstalls without requiring a downloaded dependency'

$unknownBinaryTarget = New-DesktopFixture 'desktop-unowned-binary'
$null = New-Item -ItemType Directory -Path (Join-Path $unknownBinaryTarget 'bin')
'unowned executable fixture' | Set-Content -LiteralPath (Join-Path $unknownBinaryTarget 'bin/sing-box.exe')
Run-Script (Join-Path $unknownBinaryTarget 'uninstall.ps1') @() $true
Assert-Test ((Get-Content -LiteralPath (Join-Path $unknownBinaryTarget 'bin/sing-box.exe') -Raw).Trim() -ceq 'unowned executable fixture') 'Desktop uninstall removed an unreceipted binary.'
Pass-Test 'desktop uninstall preserves an unreceipted binary instead of claiming ownership'

$traversalTarget = New-DesktopFixture 'desktop-invalid-ownership'
$desktopMarker = Join-Path $traversalTarget '.proxy2tun-desktop-install.json'
$desktopOwned = Get-Content -LiteralPath $desktopMarker -Raw -Encoding UTF8 | ConvertFrom-Json
$desktopOwned.files[0].path = '../outside.txt'
$desktopOwned | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $desktopMarker -Encoding UTF8
Run-Script (Join-Path $traversalTarget 'uninstall.ps1') @() $false
Assert-Test (Test-Path -LiteralPath (Join-Path $traversalTarget 'Start-Bridge.ps1')) 'Desktop ownership refusal deleted source files.'
Pass-Test 'desktop ownership traversal is rejected before stopping or deleting files'

$officialExeHash = '7bbef1dea9189ee12799ae834ea4b4658355da25c47a21ad8804904c0ccd9410'
if ((Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash -ieq $officialExeHash) {
    $dependencyTarget = New-DesktopFixture 'desktop-verified-dependency'
    $null = New-Item -ItemType Directory -Path (Join-Path $dependencyTarget 'bin')
    $dependencyPath = Join-Path $dependencyTarget 'bin/sing-box.exe'
    Copy-Item -LiteralPath $binary -Destination $dependencyPath
    [ordered]@{version='1.14.2';exeSha256=$officialExeHash} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dependencyTarget 'bin/sing-box.receipt.json') -Encoding UTF8
    [IO.File]::AppendAllText($dependencyPath,'tampered')
    Run-Script (Join-Path $dependencyTarget 'uninstall.ps1') @() $false
    Assert-Test (Test-Path -LiteralPath (Join-Path $dependencyTarget 'Start-Bridge.ps1')) 'Desktop dependency mismatch deleted source.'
    Copy-Item -LiteralPath $binary -Destination $dependencyPath -Force
    Run-Script (Join-Path $dependencyTarget 'uninstall.ps1') @() $true
    Assert-Test (-not (Test-Path -LiteralPath $dependencyTarget)) 'Verified desktop dependency uninstall left an empty installation behind.'
    Pass-Test 'desktop dependency hash mismatch refuses deletion; intact pinned dependency and receipt uninstall together'
} else { Write-Host 'SKIP pinned desktop dependency removal: supplied CLI test binary differs from the official fixed binary.' }

Write-Host ('Installer checks: {0} PASS. No TUN was started. Test records: {1}' -f $script:passed, $scratch)
