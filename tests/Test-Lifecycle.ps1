#requires -Version 5.1
# Uses only disposable PowerShell fixtures. Never starts sing-box or modifies networking.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Lifecycle.psm1') -Force
Initialize-P2TNative
if (-not ('Proxy2Tun.OwnedProcess' -as [type])) { throw 'NativeProcess.cs did not compile.' }
if ($env:OS -ne 'Windows_NT') { throw 'Lifecycle tests require Windows.' }

$powershell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $powershell)) {
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}
$fixture = Join-Path $PSScriptRoot 'fixtures\Lifecycle-Child.ps1'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testDirectory = Join-Path $tempRoot ('p2t-lifecycle-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$ownedProcesses = New-Object Collections.Generic.List[object]
$externalStamps = New-Object Collections.Generic.List[object]
$checks = 0

function Assert-Lifecycle {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Lifecycle assertion failed: ' + $Message) }
    $script:checks++
    Write-Host ('PASS: ' + $Message)
}
function Wait-TestFile {
    param([string]$Path)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $Path)) {
        if ([DateTime]::UtcNow -ge $deadline) { throw ('Fixture readiness timed out: ' + [IO.Path]::GetFileName($Path)) }
        Start-Sleep -Milliseconds 50
    }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function Wait-TestExit {
    param($Stamp)
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while ((Test-P2TStamp -Stamp $Stamp) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    return (-not (Test-P2TStamp -Stamp $Stamp))
}
function Start-OwnedFixture {
    param([string]$Name)
    $ready = Join-Path $testDirectory ($Name + '.json')
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Idle -ReadyPath "{1}"' -f $fixture,$ready
    $process = New-Object Proxy2Tun.OwnedProcess($powershell,$arguments,$PSScriptRoot)
    $ownedProcesses.Add($process)
    $stamp = Wait-TestFile -Path $ready
    return [pscustomobject]@{ Process=$process; Stamp=$stamp }
}

try {
    Assert-Lifecycle -Condition ($PSVersionTable.PSVersion.Major -ge 5) -Message ('NativeProcess.cs compiles in PowerShell ' + $PSVersionTable.PSVersion)
    $sentinelPath = Join-Path $testDirectory 'unrelated.json'
    $sentinelArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Idle -ReadyPath "{1}"' -f $fixture,$sentinelPath
    $sentinelProcess = Start-Process -FilePath $powershell -ArgumentList $sentinelArguments -WindowStyle Hidden -PassThru
    $sentinelStamp = Get-P2TProcessStamp -ProcessId $sentinelProcess.Id
    $externalStamps.Add($sentinelStamp)
    $null = Wait-TestFile -Path $sentinelPath

    $first = Start-OwnedFixture -Name 'dispose-child'
    Assert-Lifecycle -Condition ($first.Process.Id -eq $first.Stamp.Id -and -not $first.Process.HasExited) -Message 'Owned child executes its fixture and reports the expected PID'
    Assert-Lifecycle -Condition ($first.Process.StartFileTime.ToString() -eq $first.Stamp.StartFileTime) -Message 'Native creation time matches the independently observed process stamp'
    $first.Process.Dispose()
    Assert-Lifecycle -Condition ((Wait-TestExit -Stamp $first.Stamp) -and $first.Process.HasExited) -Message 'Dispose terminates the owned child'
    $first.Process.Dispose()
    Assert-Lifecycle -Condition (Test-P2TStamp -Stamp $sentinelStamp) -Message 'Repeated Dispose preserves an unrelated process'

    $second = Start-OwnedFixture -Name 'verified-child'
    $wrongStart = [long]$second.Stamp.StartFileTime + 1
    Assert-Lifecycle -Condition (-not [Proxy2Tun.OwnedProcess]::StopVerified($second.Stamp.Id,$wrongStart,$second.Stamp.Path)) -Message 'StopVerified refuses a mismatched creation time'
    Assert-Lifecycle -Condition (Test-P2TStamp -Stamp $second.Stamp) -Message 'Creation-time mismatch leaves the same PID running'
    Assert-Lifecycle -Condition (-not [Proxy2Tun.OwnedProcess]::StopVerified($second.Stamp.Id,[long]$second.Stamp.StartFileTime,($second.Stamp.Path + '.wrong'))) -Message 'StopVerified refuses a mismatched executable path'
    Assert-Lifecycle -Condition (Test-P2TStamp -Stamp $second.Stamp) -Message 'Path mismatch leaves the same PID running'
    Assert-Lifecycle -Condition ([Proxy2Tun.OwnedProcess]::StopVerified($second.Stamp.Id,[long]$second.Stamp.StartFileTime,$second.Stamp.Path)) -Message 'StopVerified stops the child with the matching identity'
    Assert-Lifecycle -Condition ((Wait-TestExit -Stamp $second.Stamp) -and (Test-P2TStamp -Stamp $sentinelStamp)) -Message 'Verified termination preserves the unrelated process'

    $third = Start-OwnedFixture -Name 'lifecycle-stop'
    $state = [ordered]@{ Schema=1; Child=$third.Stamp; InterfaceName=$null; AdapterGuid=$null; Status='Running' }
    $statePath = Join-Path $testDirectory 'state.json'
    $logPath = Join-Path $testDirectory 'bridge.log'
    Stop-P2TOwnedChild -Child $third.Process -State $state -StatePath $statePath -LogPath $logPath
    $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-Lifecycle -Condition ((Wait-TestExit -Stamp $third.Stamp) -and $saved.Status -eq 'Waiting' -and $null -eq $saved.Child) -Message 'Lifecycle stop terminates its child and persists the waiting state'
    Assert-Lifecycle -Condition ((Get-Content -LiteralPath $logPath -Raw) -match 'TUN stopped') -Message 'Lifecycle stop records a visible log entry'

    $ownerReadyPath = Join-Path $testDirectory 'crash-owner.json'
    $crashChildPath = Join-Path $testDirectory 'crash-child.json'
    $ownerArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Owner -ReadyPath "{1}" -ChildReadyPath "{2}"' -f $fixture,$ownerReadyPath,$crashChildPath
    $ownerProcess = Start-Process -FilePath $powershell -ArgumentList $ownerArguments -WindowStyle Hidden -PassThru
    $ownerStamp = Get-P2TProcessStamp -ProcessId $ownerProcess.Id
    $externalStamps.Add($ownerStamp)
    $crashRecord = Wait-TestFile -Path $ownerReadyPath
    $externalStamps.Add($crashRecord.Child)
    $crashChildStamp = Wait-TestFile -Path $crashChildPath
    Assert-Lifecycle -Condition ($ownerStamp.Id -eq $crashRecord.Owner.Id -and (Test-P2TStamp -Stamp $crashRecord.Owner) -and $crashRecord.Child.Id -eq $crashChildStamp.Id -and (Test-P2TStamp -Stamp $crashChildStamp)) -Message 'Independent owner and its job child are running before the crash test'
    # This uses a stamp from the exact fixture created above, never a name-based kill.
    Assert-Lifecycle -Condition ([Proxy2Tun.OwnedProcess]::StopVerified($ownerStamp.Id,[long]$ownerStamp.StartFileTime,$ownerStamp.Path)) -Message 'Crash test force-terminates only its verified owner fixture'
    Assert-Lifecycle -Condition (Wait-TestExit -Stamp $crashChildStamp) -Message 'Closing the crashed owner job handle automatically kills its child'
    Assert-Lifecycle -Condition (Test-P2TStamp -Stamp $sentinelStamp) -Message 'Owner crash cleanup preserves the unrelated process'
    Write-Host ('Lifecycle tests passed: {0} checks. No TUN or network changes.' -f $checks)
} finally {
    foreach ($process in $ownedProcesses) { $process.Dispose() }
    foreach ($stamp in $externalStamps) {
        if (Test-P2TStamp -Stamp $stamp) { $null = [Proxy2Tun.OwnedProcess]::StopVerified($stamp.Id,[long]$stamp.StartFileTime,$stamp.Path) }
    }
    # Only the unique directory created by this run can be recursively removed.
    $resolvedTestDirectory = [IO.Path]::GetFullPath($testDirectory)
    $safeTempPrefix = $tempRoot.TrimEnd('\') + '\'
    if ($resolvedTestDirectory.StartsWith($safeTempPrefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedTestDirectory) -match '^p2t-lifecycle-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolvedTestDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
