# 故障排查与恢复

适用于实验性 v0.2.1。下文路径和端口均为示例，应替换为本次安装的实际位置；不要操作其他安装或仍在使用的手工 TUN。历史案例与证据等级见[现场调试记录](field-debug.md)。

## 代理没有发现，或无法启动

先确认原客户端提供本机无需认证的 SOCKS5 / HTTP CONNECT 端口。PAC、需要用户名密码的代理、只有远端 VPN 而没有本地端口的产品不在支持范围。执行 `Start-Bridge.ps1 -Mode Detect`；必要时用 `-ProxyEndpoint 'socks5://127.0.0.1:10808'` 指定实际入口，端口仅为示例。

发现探测会请求 `1.1.1.1:443` 并检查 TLS 握手。目标被拦截可能造成误判。无法读取端口归属程序路径时，可在管理员窗口再探测；不要用不相关路径冒充上游核心。

明确指定入口是为限定本次检测范围，不表示跳过协议、转发或所有者检查。历史聊天中提及的约 52 秒耗时不是新版本性能结果；若检测仍很慢，请记录版本、是否指定入口和耗时，不上传完整监听表。

TUN 必须在管理员窗口启动。右键 `Start-Bridge.cmd` → **以管理员身份运行**；工具不会静默提升权限。`Detect` / `Generate` 不开启 TUN。若 UAC 使用另一个管理员账号，读取到的 System Proxy 可能不同，应用 `-ProxyEndpoint` 明确指定入口。

已有 sing-box 时会拒绝启动。应通过原工具自己的正常停止入口退出，再运行 AutoBridge；不接管原手工 TUN，不结束其他实例，不叠加两个 TUN。

### 监听表显示 PID 0、重复记录或缺少端口

Windows 监听元数据可能异常，而回环连接仍然可用。不能把 PID 0 当作实际代理核心，也不能仅因一次表查询为空就断定代理已经停止。

可靠核验需要保持一个实际本机 TCP 连接，以服务端地址/端口及客户端地址/临时端口匹配 Established 记录，再核对唯一的正 PID 和进程身份。仅看到代理进程存在、或 HTTPS 可达，都不足以证明端口归属。元数据仍未知或相互冲突时应保守拒绝启动；不要删除防回环规则或伪造进程路径来绕过检查。

此类问题的复现证据见[现场记录](field-debug.md#2026-10-30-本机监测器误判两种有效状态)。

## 使用项目内置检查区分 DNS 与 HTTPS

在本次安装目录运行以下命令。它们检查现有网络路径，不启动或停止 TUN、不替换配置；HTTPS 检查只在 runtime 中短暂使用响应头文件并自行清理。

```powershell
Set-Location 'C:\Tools\Proxy2TUN'
Import-Module .\src\Health.psm1 -Force
$probeRuntime = Join-Path (Get-Location) 'runtime'
New-Item -ItemType Directory -Path $probeRuntime -Force | Out-Null

Test-P2TSystemDns |
    Format-List Success,Classification

Test-P2THttpsForwarding -RuntimePath $probeRuntime `
    -Url 'https://www.gstatic.com/generate_204' -TimeoutSeconds 8 |
    Format-List TransportSuccess,ServiceSuccess,Classification,HttpStatus,CurlExitCode,ElapsedSeconds
```

- DNS 失败、HTTPS 失败：先结合两项分类检查代理与系统解析，不能仅凭进程存活继续重建。
- DNS 成功、HTTPS 得到 401 / 403 / 5xx：已经收到服务端响应，但应用权限、challenge 或服务状态尚未验证。
- HTTPS 204：该次探测服务与传输可用；仍需核对 TUN 身份、路由和新查询 DNS，才能判断是否确实由 TUN 转发。
- 没有 TUN 时检查也可能经物理网络成功。因此这些手动检查不能替代 Watch 的完整健康链路，更不能证明 ChatGPT、远控或其他应用已经完成真实操作。

内置 HTTPS 检查禁用 curl 用户配置和显式/环境代理，使用保留空参数的原生进程封装并验证 TLS 证书。不要用 `--insecure` 把证书错误改写成成功。

### Windows PowerShell 5.1 下出现意外目标地址

不要直接复制包含 `curl.exe ... --proxy "" --connect-timeout 5 ...` 的旧诊断命令。Windows PowerShell 5.1 的原生参数传递可能丢弃空字符串，后续参数因此错位。历史输出中的意外 `0.0.0.5:80` 是这一问题的线索，不能直接归因于 DNS 或节点失效。

优先使用上面的两个项目函数。它们避免让手动命令的参数传递错误干扰网络判断。PowerShell 7.3 引入了不同的原生参数行为，不能用 PowerShell 7 的结果替代 5.1 兼容验证。[微软说明](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_parsing?view=powershell-7.6)

## DNS 失败，但代理本身可用

先正常停止 AutoBridge，再确认原代理能独立访问 HTTPS。重新生成配置，检查 `dns_mode` 为 `hijack`，DoH 的 `detour` 为实际通用出站标签 `upstream`，并检查检测到的真实核心路径。不要复制带节点或账号信息的原客户端配置。

DoH 使用 IP 地址加明确 SNI，避免其自身的域名引导回环；上游客户端仍可能需要解析自己的服务器域名。默认不把共享 Windows DNS Client 设为 DIRECT。仅在确认存在该依赖后，可在管理员窗口尝试兼容选项：

```powershell
.\Start-Bridge.ps1 -Mode Watch -AllowSystemDnsBootstrap
```

这个选项会允许共享系统 DNS 服务的端口 53 直连，可能包括其他应用的查询；不是“仅放行某一个节点域名”。不得把此模式的 DNS 成功当作 DoH 路径证明。优先检查实际拨号核心的 `-ExtraDirectProcessPath`、原代理自身解析及客户端缓存。

不要为消除回环而将所有进程 DIRECT，也不要清空系统路由或删除所有 Wintun 网卡。

### 随机测试域名没有 A 记录，不一定是 DNS 失败

新查询探测使用自行生成的随机名称，目的是验证 DNS 请求是否真正完成，而不是要求随机名称必须存在。`NXDOMAIN`，以及 `NOERROR`、零 Answer、带合法 authority SOA 的 `NODATA`，都可能是有效负回答。

只有事务 ID、问题、IN 类、报文结构、长度、来源和 SOA 区域覆盖均符合要求时才通过。空回应、无关 SOA、SERVFAIL、截断或超时仍属于失败。不要把“放宽为接受任意 DNS 包”当作修复。[RFC 2308 §2.2](https://www.rfc-editor.org/rfc/rfc2308.html#section-2.2)

## HTTP 403、HTTP 000 与网络错误

`403` 配合 `Cf-Mitigated: challenge` 表示 Cloudflare 要求浏览器验证。完成证书校验并收到该响应，说明这次 HTTPS 传输已建立；它不等于页面可用或已登录。工具将其分类为 `CloudflareChallenge`，不为这一状态单独重建 TUN。

普通 HTTP 4xx / 5xx 是服务层响应，同样不能直接等同于断网。`HTTP 000` 是未取得有效 HTTP 响应的占位结果，应结合 curl 退出码区分 DNS 超时、连接 reset、TLS 校验失败和连接超时。内置诊断记录分类，不保存网页正文或原始 DNS 地址。

浏览器 challenge、远控账号状态与代理链路健康属于不同层次；探测通过后仍需实际测试使用中的应用。

## 切换 Wi-Fi / 以太网后，核心还在但网页打不开

Watch 对物理出口指纹变化进行防抖，再安全重建自己的 TUN。它检查专用网卡身份/状态及配置要求的路由覆盖，并定期检查系统 DNS、直接发送给 TUN DNS 的随机域名新查询和 HTTPS，不只看 sing-box 进程是否存在。随机查询避免缓存掩盖 DoH 故障；路由检查防止 TUN 路由丢失后直连成功造成误判。默认连续失败 2 次、最多恢复 3 次，退避从 10 秒起并封顶 120 秒；连续健康 300 秒才重置预算。等待期间前台会记录分类和恢复次数。

`RecoveryPaused` 表示本次恢复预算已用尽，工具已释放自己的 TUN，不再无限重启。先检查代理、物理连接、核心路径和日志，再停止前台窗口并重新运行。不要把 `-MaxRecoveryAttempts` 调得很大来掩盖持续故障；恢复直连也不等于原代理已恢复。

真实 Wi-Fi / 以太网切换仍需按 [实机验收](validation.md) 在可本地恢复的设备上测试。自动化模拟不证明每种网卡和驱动组合已通过。

### 网卡 Up，却出现 TunRoutesNotReady

网卡 Up 不能独立证明路由完整，但缺少单条默认路由也不等于失败。排除 `127.0.0.0/8` 与 `::1/128` 等回环范围后，sing-box 可以生成多段前缀；旧版只认默认路由或两条 `/1` 的判断会遗漏有效布局。

正确检查应验证属于本实例网卡的路由前缀并集是否完整覆盖要求的非回环范围，同时保留 GUID、状态、地址族及缺口检查。不要手动添加覆盖回环的默认路由来迎合旧检查，也不要因看到应用流量就删除所有路由验证。旧版案例和证据限制见[现场记录](field-debug.md#能独立确认的封装缺陷)。

## 配置备份与回退

候选配置先通过官方核心检查，再原子替换本安装目录 `runtime/config.json`。旧字节保存在独立 `config.json.backup-*`；启动验证失败时先停止新核心和接管，再回滚。若活动配置或备份被外部修改，回滚会拒绝覆盖，并保留诊断信息。

备份恢复是文件操作，不会自动运行旧核心。需要回退版本时，先用新安装目录的停止入口退出，再运行保留的旧安装目录。不要混用两版 runtime、归属清单或进程 PID。

## PowerShell 5.1 ParserError / 旧 Stop-Misty-TUN.ps1 乱码

系统 Windows PowerShell 5.1 对无 BOM 的非 ASCII 脚本可能按旧代码页读取，导致引号损坏或 ParserError。本版脚本统一为纯 ASCII 或 UTF-8 BOM，测试及构建均拒绝无 BOM 非 ASCII 脚本。

历史手工停止脚本的故障和本包停止入口应分开处理。包中的 `Stop-Misty-TUN.ps1` 仅为新 AutoBridge 的安全兼容名称，实际调用本安装目录的归属核验停止入口，**不能用于停止旧手工 Misty TUN**，也不会替用户覆盖旧安装中的同名文件。

若保存了确实为 UTF-8 但缺少 BOM 的历史脚本，可先在离线副本上转换：

```powershell
.\tools\Repair-LegacyScriptEncoding.ps1 -SourcePath 'C:\ScriptCopies\Stop-Legacy.ps1' -OutputPath 'C:\ScriptCopies\Stop-Legacy.fixed.ps1'
```

输出必须是尚不存在的新文件。工具严格解码、校验语法并写 UTF-8 BOM；不会执行脚本，也不会覆盖源文件。原文件已乱码、截断或属于其他编码时，转换编码无法恢复内容，应从可信备份恢复。检查输出内容后才考虑手动替换；本工具不自动操作旧 TUN。

## 紧急停止、断电或卸载

在对应安装目录打开管理员 PowerShell：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Stop-Bridge.ps1 -Emergency
```

该命令核验状态、进程身份与专用网卡，只处理本安装拥有的实例。状态无法核验时保守拒绝；不要为绕过检查修改 PID。可重启 Windows 清理失效会话后单独检查原客户端。进程保护不承诺在断电、系统崩溃或驱动故障下立即完成全部用户态清理。

卸载只接受安装器建立的目录；无清单的源码目录、越界清单、被移动/篡改的安装和目录联接会被拒绝。默认保留 runtime 和未知文件；首次卸载可选 `-PurgeData`。不会移除原客户端或共享 Wintun 包。

## 下载校验与问题反馈

安装器固定使用 [官方 sing-box 1.14.2](https://github.com/SagerNet/sing-box/releases/tag/v1.14.2)，校验失败时不执行文件。可重新获取官方 Windows amd64 版本，或用 `-SingBoxPath` 指定可信本地核心；不要跳过哈希或从陌生镜像复制二进制。

反馈请说明 Windows/核心版本、代理类型，以及错误发生于安装、检测、启动、切网、运行还是停止。只附必要、已遮盖个人路径和访问目标的日志。不要上传 runtime 整包、订阅 URL、节点地址、账号密码、私钥、原客户端配置或本机完整网络快照。请分清用户手动成功、模拟测试和管理员真实 TUN 验收。
