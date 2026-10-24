#requires -Version 5.1
# Exercises config files only. No TUN or network operation runs.
[CmdletBinding()]
param([string]$SingBoxPath = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repository = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repository 'src\Config.psm1') -Force
$script:assertions = 0
function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw ('FAIL: ' + $Message) }; $script:assertions++ }
function Assert-Throws { param([scriptblock]$Operation,[string]$Message) $threw=$false; try { & $Operation } catch { $threw=$true }; Assert-True $threw $Message }
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('p2t-config-transaction-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testDirectory
try {
    $validator = Join-Path $testDirectory 'validator.cmd'
    $fixture = @'
@echo off
if not "%~1"=="check" exit /b 8
if not "%~2"=="-c" exit /b 8
if not exist "%~3" exit /b 8
findstr /c:"REJECT_FOR_TEST" "%~3" > nul
if not errorlevel 1 exit /b 9
exit /b 0
'@
    [IO.File]::WriteAllText($validator,$fixture,[Text.Encoding]::ASCII)
    $active = Join-Path $testDirectory 'config.json'
    $original = '{"fixture":"previous config; preserved exactly"}'
    [IO.File]::WriteAllText($active,$original,(New-Object Text.UTF8Encoding($true)))
    $originalHash = (Get-FileHash -LiteralPath $active -Algorithm SHA256).Hash
    Assert-Throws { Set-P2TSingBoxConfig -Config @{failure='REJECT_FOR_TEST'} -Path $active -SingBoxPath $validator } 'Rejected candidate fails before active replacement'
    Assert-True ((Get-FileHash -LiteralPath $active -Algorithm SHA256).Hash -eq $originalHash) 'Invalid config leaves active bytes unchanged'
    Assert-True (@(Get-ChildItem -LiteralPath $testDirectory -Filter '*.backup-*').Count -eq 0) 'Rejected candidate creates no backup or promotion'
    Assert-True (@(Get-ChildItem -LiteralPath $testDirectory -Filter '.config-*' -Force).Count -eq 0) 'Rejected candidate is cleaned'

    $transaction = Set-P2TSingBoxConfig -Config @{fixture='new config'} -Path $active -SingBoxPath $validator
    Assert-True ($transaction.HadPrevious -and (Test-Path -LiteralPath $transaction.BackupPath)) 'Previous config receives a unique backup'
    Assert-True ((Get-FileHash -LiteralPath $transaction.BackupPath -Algorithm SHA256).Hash -eq $originalHash) 'Backup preserves exact previous bytes including BOM'
    Assert-True ((Get-Content -LiteralPath $active -Raw | ConvertFrom-Json).fixture -eq 'new config') 'Validated config promoted'
    Restore-P2TSingBoxConfig -Transaction $transaction
    Assert-True ((Get-FileHash -LiteralPath $active -Algorithm SHA256).Hash -eq $originalHash) 'Failed startup can restore exact previous config'
    Restore-P2TSingBoxConfig -Transaction $transaction
    Assert-True (Test-Path -LiteralPath $transaction.BackupPath) 'Rollback is idempotent and retains backup for review'

    $transaction = Set-P2TSingBoxConfig -Config @{fixture='another config'} -Path $active -SingBoxPath $validator
    [IO.File]::WriteAllText($active,'{"fixture":"operator changed this"}',[Text.Encoding]::ASCII)
    $changedHash = (Get-FileHash -LiteralPath $active -Algorithm SHA256).Hash
    Assert-Throws { Restore-P2TSingBoxConfig -Transaction $transaction } 'Rollback refuses active config changed by operator'
    Assert-True ((Get-FileHash -LiteralPath $active -Algorithm SHA256).Hash -eq $changedHash) 'Operator edit survives refused rollback'

    $transaction = Set-P2TSingBoxConfig -Config @{fixture='backup guard'} -Path $active -SingBoxPath $validator
    [IO.File]::WriteAllText($transaction.BackupPath,'{"fixture":"tampered backup"}',[Text.Encoding]::ASCII)
    Assert-Throws { Restore-P2TSingBoxConfig -Transaction $transaction } 'Rollback refuses a modified backup'
    Assert-True ((Get-FileHash -LiteralPath $active -Algorithm SHA256).Hash -eq $transaction.AppliedHash) 'Modified backup cannot replace active config'

    $newPath = Join-Path $testDirectory 'new.json'
    $newTransaction = Set-P2TSingBoxConfig -Config @{fixture='first startup'} -Path $newPath -SingBoxPath $validator
    Assert-True (-not $newTransaction.HadPrevious -and -not $newTransaction.BackupPath) 'First startup has no invented previous backup'
    Restore-P2TSingBoxConfig -Transaction $newTransaction
    Restore-P2TSingBoxConfig -Transaction $newTransaction
    Assert-True (-not (Test-Path -LiteralPath $newPath)) 'Rollback removes only its newly created config'
    Assert-True (@(Get-ChildItem -LiteralPath $testDirectory -Filter '.config-*' -Force).Count -eq 0) 'Promotion and rollback leave no candidate files'

    if ($SingBoxPath) {
        $candidate = [pscustomobject]@{Host='127.0.0.1';Port=10808;Protocol='socks5';ProcessId=42;ProcessPath='C:\ProxyClient\core.exe';ProcessStartTime='2026-01-01T00:00:00.0000000Z';ParentPath='';ParentName='';ParentProcessId=0}
        $validConfig = New-P2TSingBoxConfig -Candidate $candidate -InterfaceName p2t-transaction-test
        $official = Set-P2TSingBoxConfig -Config $validConfig -Path $newPath -SingBoxPath $SingBoxPath
        $validConfig.inbounds[0].type = 'invalid-test-inbound-type'
        Assert-Throws { Set-P2TSingBoxConfig -Config $validConfig -Path $newPath -SingBoxPath $SingBoxPath } 'Official engine rejects invalid candidate before promotion'
        Assert-True ((Get-FileHash -LiteralPath $newPath -Algorithm SHA256).Hash -eq $official.AppliedHash) 'Official rejection preserves valid active config'
        Restore-P2TSingBoxConfig -Transaction $official
    }
} finally {
    # This is the exact freshly-created test directory, never a computed parent.
    if ([IO.Path]::GetFileName($testDirectory) -notlike 'p2t-config-transaction-*' -or [IO.Path]::GetDirectoryName($testDirectory).TrimEnd('\') -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Refusing unexpected test cleanup target.' }
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
Write-Host ('PASS: {0} config transaction assertions on PowerShell {1}. No TUN was created.' -f $script:assertions,$PSVersionTable.PSVersion)
