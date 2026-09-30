#requires -Version 5.1
[CmdletBinding()]
param([string]$SingBoxPath)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$files=@(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') -and $_.FullName -notmatch '\\runtime\\' })
foreach ($file in $files) {
    $tokens=$null; $parseErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count) { throw ($file.Name + ': ' + ($parseErrors.Message -join '; ')) }
}
Write-Host ('PASS syntax: {0} PowerShell files' -f $files.Count)
& (Join-Path $PSScriptRoot 'Test-DiscoveryConfig.ps1')
& (Join-Path $PSScriptRoot 'Test-Lifecycle.ps1')
& (Join-Path $PSScriptRoot 'Test-Watcher.ps1')
if ($SingBoxPath) {
    $SingBoxPath=(Resolve-Path -LiteralPath $SingBoxPath).Path
    Import-Module (Join-Path $root 'src\Config.psm1') -Force
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('p2t-config-test-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        foreach ($protocol in @('socks5','http')) {
            $candidate=[pscustomobject]@{Host='127.0.0.1';Port=10808;Protocol=$protocol;ProcessId=42;ProcessPath='C:\ProxyClient\core.exe';ProcessStartTime='2026-01-01T00:00:00.0000000Z';ParentPath='';ParentName='';ParentProcessId=0}
            $config=New-P2TSingBoxConfig -Candidate $candidate -InterfaceName 'p2t-0123456789'
            Write-P2TSingBoxConfig -Config $config -Path $temp
            & $SingBoxPath check -c $temp
            if ($LASTEXITCODE -ne 0) { throw "$protocol config check failed." }
            Write-Host "PASS official sing-box config check: $protocol"
        }
    } finally { Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue }
    & (Join-Path $PSScriptRoot 'Test-Install.ps1') -SingBoxPath $SingBoxPath
}
Write-Host 'PASS all requested local checks. No TUN was created by this suite.'
