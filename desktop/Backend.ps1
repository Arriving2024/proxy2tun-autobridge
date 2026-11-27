#requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Run','Stop','Detect','Diagnose')][string]$Action='Run')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$runtime=Join-Path $root 'runtime'
if($Action -eq 'Diagnose'){& (Join-Path $root 'Show-Logs.ps1') -Summary;return}
Import-Module (Join-Path $root 'src\Desktop.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Lifecycle.psm1') -Force
$desktopStop=Join-Path $runtime 'desktop-stop.request'
if($Action -eq 'Stop'){
    $null=New-Item -ItemType Directory -Path $runtime -Force
    [IO.File]::WriteAllText($desktopStop,'stop')
    & (Join-Path $root 'Stop-Bridge.ps1')
    return
}
if($Action -eq 'Detect'){
    Import-Module (Join-Path $root 'src\Discovery.psm1') -Force
    $candidates=@(Get-P2TProxyCandidates -IncludeEstablished)
    @(Get-P2TDesktopChoices $candidates|Select-Object Key,DisplayName,Endpoint)|ConvertTo-Json -Depth 5
    return
}
if(-not (Test-P2TAdministrator)){throw 'Administrator rights are required to start TUN.'}
$mutex=New-Object Threading.Mutex($false,'Global\Proxy2TUN.Desktop.Backend.v1')
$locked=$false
try{
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Another desktop controller is running.'}
    Assert-P2TDesktopLocalPath $root
    $null=New-Item -ItemType Directory -Path $runtime -Force
    Assert-P2TDesktopLocalPath $runtime
    if(Test-Path -LiteralPath $desktopStop){Remove-Item -LiteralPath $desktopStop -Force}
    if(Get-Process -Name sing-box -ErrorAction SilentlyContinue){
        Write-P2TDesktopStatus $runtime 'ExistingTun' '检测到已有 TUN 正在运行。请先用原工具停止，再点击重试。'
        exit 2
    }
    Write-P2TDesktopStatus $runtime 'Preparing' '正在准备网络组件。'
    $logPath=Join-Path $runtime 'bridge.log'
    if($env:PROXY2TUN_DESKTOP_SHA256 -match '^[0-9a-fA-F]{64}$'){
        Write-P2TLog -Path $logPath -Message ("Build: desktop SHA256="+$env:PROXY2TUN_DESKTOP_SHA256)
    }
    try{$binary=Ensure-P2TDesktopDependency -Root $root -RuntimePath $runtime}
    catch{
        $failure=$_.Exception.Message
        if($failure -notmatch '^(?:DependencyDownload(?:Failed: [A-Za-z]+(?:; HTTP=[1-5][0-9]{2})?|CancelledOrTimedOut)|Dependency(?:ArchiveHash|ArchiveEntry|ExecutableHash)Mismatch|DependencyHashMismatch: existing binary was preserved\.)$'){
            $failure='DependencyPreparationFailed'
        }
        Write-P2TLog -Path $logPath -Message ("Dependency check: "+$failure)
        throw
    }
    if(Test-Path -LiteralPath $desktopStop){Write-P2TDesktopStatus $runtime 'Stopped' '已取消启动。';return}
    Write-P2TDesktopStatus $runtime 'Scanning' '正在识别本机代理软件。'
    & (Join-Path $root 'Start-Bridge.ps1') -Mode Watch -SingBoxPath $binary -DesktopMode -LossThreshold 3
}catch{
    if(Test-Path -LiteralPath $desktopStop){Write-P2TDesktopStatus $runtime 'Stopped' '已停止。'}
    else{
        # Exception contents, paths and network responses stay out of the UI.
        Write-P2TDesktopStatus $runtime 'Error' '启动未完成。请检查代理软件和网络后重试；诊断中可查看原因。'
        try{Add-Content -LiteralPath (Join-Path $runtime 'desktop-errors.log') -Value ([DateTime]::UtcNow.ToString('o')+' '+$_.Exception.Message) -Encoding UTF8}catch{}
        throw
    }
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
