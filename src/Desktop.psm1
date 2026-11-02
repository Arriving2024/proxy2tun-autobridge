#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-P2TDesktopStatus {
    param([string]$RuntimePath, [string]$Status, [string]$Message,
        [object[]]$Candidates=@(), [string]$SelectedKey='', [string]$SelectedDisplayName='', [string]$SelectedEndpoint='')
    $null=New-Item -ItemType Directory -Path $RuntimePath -Force
    $data=[ordered]@{Status=$Status;Message=$Message;Candidates=@($Candidates);SelectedKey=$SelectedKey;
        SelectedDisplayName=$SelectedDisplayName;SelectedEndpoint=$SelectedEndpoint;UpdatedUtc=[DateTime]::UtcNow.ToString('o')}
    $path=Join-Path $RuntimePath 'desktop-status.json'
    $temporary=Join-Path $RuntimePath ('desktop-status-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        [IO.File]::WriteAllText($temporary,($data|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        if(Test-Path -LiteralPath $path){[IO.File]::Replace($temporary,$path,[NullString]::Value)}else{[IO.File]::Move($temporary,$path)}
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}

function Get-P2TDesktopEndpoint {
    param($Candidate)
    $address=[string]$Candidate.Host
    if($address.Contains(':')){$address='['+$address.Trim('[',']')+']'}
    return ('{0}://{1}:{2}' -f $Candidate.Protocol,$address,$Candidate.Port)
}

function Get-P2TDesktopChoices {
    param([object[]]$Candidates=@())
    $groups=@($Candidates|Group-Object -Property {Get-P2TFamilyKey $_})
    $scopes=@{}
    foreach($group in $groups){
        $best=$group.Group|Sort-Object @{Expression={if($_.Protocol -eq 'socks5'){0}else{1}}},Priority,Port,Host|Select-Object -First 1
        $scope=if($group.Name.StartsWith('app|')){'app|'+$best.ParentPath.ToLowerInvariant()}else{'core|'+$best.ProcessPath.ToLowerInvariant()}
        if(-not $scopes.ContainsKey($scope)){$scopes[$scope]=0};$scopes[$scope]++
    }
    foreach($group in $groups){
        $best=$group.Group|Sort-Object @{Expression={if($_.Protocol -eq 'socks5'){0}else{1}}},Priority,Port,Host|Select-Object -First 1
        $scope=if($group.Name.StartsWith('app|')){'app|'+$best.ParentPath.ToLowerInvariant()}else{'core|'+$best.ProcessPath.ToLowerInvariant()}
        if($scopes[$scope] -gt 1){$scope+='|'+$group.Name}
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($scope))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $label=if($group.Name.StartsWith('app|')){[IO.Path]::GetFileNameWithoutExtension($best.ParentPath)}else{[IO.Path]::GetFileNameWithoutExtension($best.ProcessPath)}
        $endpoint=Get-P2TDesktopEndpoint $best
        [pscustomobject]@{Key=$key;DisplayName=($label+'  '+$endpoint);Endpoint=$endpoint;Candidate=$best}
    }
}

function Select-P2TDesktopCandidate {
    param([object[]]$Candidates=@(), [string]$RuntimePath)
    if($Candidates.Count -eq 0){Write-P2TDesktopStatus $RuntimePath 'WaitingForProxy' '暂未找到可用代理。请确认代理软件已连接，程序会继续识别。';return $null}
    $options=@(Get-P2TDesktopChoices -Candidates $Candidates)
    $choicePath=Join-Path $RuntimePath 'desktop-choice.json'
    $chosenKey=''
    if(Test-Path -LiteralPath $choicePath){
        try{
            if((Get-Item -LiteralPath $choicePath).Length -le 8192){
                $choice=Get-Content -LiteralPath $choicePath -Raw -Encoding UTF8|ConvertFrom-Json
                if($choice.Key -match '^[a-f0-9]{64}$'){$chosenKey=[string]$choice.Key}
            }
        }catch{}
    }
    $selected=@($options|Where-Object {$_.Key -ceq $chosenKey})
    if($selected.Count -eq 1){return $selected[0].Candidate}
    try{return (Select-P2TProxyCandidate -Candidates $Candidates)}
    catch{
        # An ambiguity is a user choice, never a network recovery failure.
        $public=@($options|Select-Object Key,DisplayName,Endpoint)
        Write-P2TDesktopStatus -RuntimePath $RuntimePath -Status 'ChoiceRequired' -Message '检测到多个代理软件，请选择要绑定的一个。' -Candidates $public
        return $null
    }
}

function Sync-P2TDesktopStatus {
    param($State,[string]$RuntimePath)
    $status=[string]$State.Status
    $messages=@{
        Waiting='等待代理软件连接。';Starting='正在建立全局代理连接。';Verifying='正在验证 DNS 和 HTTPS。';
        Running='全局 TCP 代理已开启，DNS 和 HTTPS 验证通过。';Backoff='连接出现问题，正在等待有限重试。';
        RecoveryPaused='多次恢复失败，已停止接管。请检查代理软件后点击重试。';Stopped='已停止全局代理，普通网络已恢复。'
    }
    if($status -eq 'Waiting'){$status='WaitingForProxy'}
    $message=if($messages.ContainsKey([string]$State.Status)){$messages[[string]$State.Status]}else{'正在检查连接。'}
    if($State.Status -eq 'Running' -and $State.Contains('LastHealthPassed') -and -not $State.LastHealthPassed){$status='Verifying';$message='连接检查出现波动，正在复查。'}
    $name=if($State.Contains('ProxyDisplayName')){[string]$State.ProxyDisplayName}else{''}
    $endpoint=if($State.Contains('ProxyEndpoint')){[string]$State.ProxyEndpoint}else{''}
    Write-P2TDesktopStatus -RuntimePath $RuntimePath -Status $status -Message $message -SelectedDisplayName $name -SelectedEndpoint $endpoint
}

function Assert-P2TDesktopLocalPath {
    param([string]$Path)
    $probe=[IO.Path]::GetFullPath($Path)
    if($probe.StartsWith('\\')){throw 'Network installation paths are unsupported.'}
    while($probe){
        if(Test-Path -LiteralPath $probe){if((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse installation paths are refused.'}}
        $parent=[IO.Directory]::GetParent($probe);$probe=if($parent){$parent.FullName}else{''}
    }
}

function Ensure-P2TDesktopDependency {
    param([string]$Root,[string]$RuntimePath)
    Assert-P2TDesktopLocalPath $Root
    $bin=Join-Path $Root 'bin';$exe=Join-Path $bin 'sing-box.exe'
    $exeHash='7bbef1dea9189ee12799ae834ea4b4658355da25c47a21ad8804904c0ccd9410'
    $zipHash='c2d8bfff918755808781dfdeeb8581b6c91eb3a243d9a7b55483cfc0c0684d32'
    $receipt=Join-Path $bin 'sing-box.receipt.json'
    if(Test-Path -LiteralPath $exe){
        if((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $exeHash){throw 'DependencyHashMismatch: existing binary was preserved.'}
    }else{
        $null=New-Item -ItemType Directory -Path $bin -Force
        Assert-P2TDesktopLocalPath $bin
        Write-P2TDesktopStatus $RuntimePath 'Preparing' '首次使用：正在下载并校验官方网络组件。'
        $id=[guid]::NewGuid().ToString('N');$archive=Join-Path $bin ($id+'.zip');$stage=Join-Path $bin ($id+'.exe.tmp')
        $client=New-Object Net.WebClient
        try{
            [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $client.Headers['User-Agent']='Proxy2TUN-AutoBridge/0.3.0'
            $task=$client.DownloadFileTaskAsync([uri]'https://github.com/SagerNet/sing-box/releases/download/v1.14.2/sing-box-1.14.2-windows-amd64.zip',$archive)
            $deadline=[DateTime]::UtcNow.AddMinutes(5)
            while(-not $task.IsCompleted){
                if((Test-Path -LiteralPath (Join-Path $RuntimePath 'desktop-stop.request')) -or [DateTime]::UtcNow -ge $deadline){$client.CancelAsync();throw 'DependencyDownloadCancelledOrTimedOut'}
                Start-Sleep -Milliseconds 200
            }
            $null=$task.GetAwaiter().GetResult()
            if((Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -ne $zipHash){throw 'DependencyArchiveHashMismatch'}
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip=[IO.Compression.ZipFile]::OpenRead($archive)
            try{
                $entries=@($zip.Entries|Where-Object {$_.FullName -ceq 'sing-box-1.14.2-windows-amd64/sing-box.exe'})
                if($entries.Count -ne 1){throw 'DependencyArchiveEntryMismatch'}
                $inputStream=$entries[0].Open();$outputStream=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
                try{$inputStream.CopyTo($outputStream)}finally{$inputStream.Dispose();$outputStream.Dispose()}
            }finally{$zip.Dispose()}
            if((Get-FileHash -LiteralPath $stage).Hash.ToLowerInvariant() -ne $exeHash){throw 'DependencyExecutableHashMismatch'}
            if(Test-Path -LiteralPath (Join-Path $RuntimePath 'desktop-stop.request')){throw 'DependencyDownloadCancelledOrTimedOut'}
            [IO.File]::Move($stage,$exe)
        }finally{
            $client.Dispose()
            foreach($file in @($archive,$stage)){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force}}
        }
    }
    $record=[ordered]@{version='1.14.2';exeSha256=$exeHash}
    [IO.File]::WriteAllText($receipt,($record|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    return $exe
}

Export-ModuleMember -Function *-P2TDesktop*,Sync-P2TDesktopStatus
