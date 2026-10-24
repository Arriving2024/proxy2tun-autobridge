# 故障排查与恢复

## 代理没有发现，或无法启动

先确认原客户端提供本机无需认证的 SOCKS5 / HTTP CONNECT 端口。PAC、需要用户名密码的代理、只有远端 VPN 而没有本地端口的产品不在支持范围。执行 `Start-Bridge.ps1 -Mode Detect`；必要时用 `-ProxyEndpoint 'socks5://127.0.0.1:10808'` 指定实际入口，端口仅为示例。

发现探测会请求 `1.1.1.1:443` 并检查 TLS 握手。目标被拦截可能造成误判。无法读取端口归属程序路径时，可在管理员窗口再探测；不要用不相关路径冒充上游核心。

TUN 必须在管理员窗口启动。右键 `Start-Bridge.cmd` → **以管理员身份运行**；工具不会静默提升权限。`Detect` / `Generate` 不开启 TUN。若 UAC 使用另一个管理员账号，读取到的 System Proxy 可能不同，应用 `-ProxyEndpoint` 明确指定入口。

已有 sing-box 时会拒绝启动。应通过原工具自己的正常停止入口退出，再运行 AutoBridge；不接管原手工 TUN，不结束其他实例，不叠加两个 TUN。

## DNS 失败，但代理本身可用

先正常停止 AutoBridge，再确认原代理能独立访问 HTTPS。重新生成配置，检查 `dns_mode` 为 `hijack`，DoH 的 `detour` 为实际通用出站标签 `upstream`，并检查检测到的真实核心路径。不要复制带节点或账号信息的原客户端配置。

DoH 使用 IP 地址加明确 SNI，避免其自身的域名引导回环；上游客户端仍可能需要解析自己的服务器域名。默认不把共享 Windows DNS Client 设为 DIRECT。仅在确认存在该依赖后，可在管理员窗口尝试兼容选项：

```powershell
.\Start-Bridge.ps1 -Mode Watch -AllowSystemDnsBootstrap
```

这个选项会允许共享系统 DNS 服务的端口 53 直连，可能包括其他应用的查询；不是“仅放行某一个节点域名”。不得把此模式的 DNS 成功当作 DoH 路径证明。优先检查实际拨号核心的 `-ExtraDirectProcessPath`、原代理自身解析及客户端缓存。

不要为消除回环而将所有进程 DIRECT，也不要清空系统路由或删除所有 Wintun 网卡。

## HTTP 403、HTTP 000 与网络错误

`403` 配合 `Cf-Mitigated: challenge` 表示 Cloudflare 要求浏览器验证。完成证书校验并收到该响应，说明这次 HTTPS 传输已建立；它不等于页面可用或已登录。工具将其分类为 `CloudflareChallenge`，不为这一状态单独重建 TUN。

普通 HTTP 4xx / 5xx 是服务层响应，同样不能直接等同于断网。`HTTP 000` 是未取得有效 HTTP 响应的占位结果，应结合 curl 退出码区分 DNS 超时、连接 reset、TLS 校验失败和连接超时。内置诊断记录分类，不保存网页正文或原始 DNS 地址。

浏览器 challenge、远控账号状态与代理链路健康属于不同层次；探测通过后仍需实际测试使用中的应用。

## 切换 Wi-Fi / 以太网后，核心还在但网页打不开

Watch 对物理出口指纹变化进行防抖，再安全重建自己的 TUN。它检查专用网卡身份/状态及完整默认路由覆盖，并定期检查系统 DNS、直接发送给 TUN DNS 的随机域名新查询和 HTTPS，不只看 sing-box 进程是否存在。随机查询避免缓存掩盖 DoH 故障；路由检查防止 TUN 路由丢失后直连成功造成误判。默认连续失败 2 次、最多恢复 3 次，退避从 10 秒起并封顶 120 秒；连续健康 300 秒才重置预算。等待期间前台会记录分类和恢复次数。

`RecoveryPaused` 表示本次恢复预算已用尽，工具已释放自己的 TUN，不再无限重启。先检查代理、物理连接、核心路径和日志，再停止前台窗口并重新运行。不要把 `-MaxRecoveryAttempts` 调得很大来掩盖持续故障；恢复直连也不等于原代理已恢复。

真实 Wi-Fi / 以太网切换仍需按 [实机验收](validation.md) 在可本地恢复的设备上测试。自动化模拟不证明每种网卡和驱动组合已通过。

## 配置备份与回退

候选配置先通过官方核心检查，再原子替换本安装目录 `runtime/config.json`。旧字节保存在独立 `config.json.backup-*`；启动验证失败时先停止新核心和接管，再回滚。若活动配置或备份被外部修改，回滚会拒绝覆盖，并保留诊断信息。

备份恢复是文件操作，不会自动运行旧核心。需要回退版本时，先用新安装目录的停止入口退出，再运行保留的旧安装目录。不要混用两版 runtime、归属清单或进程 PID。

## PowerShell 5.1 ParserError / 旧 Stop-Misty-TUN.ps1 乱码

系统 Windows PowerShell 5.1 对无 BOM 的非 ASCII 脚本可能按旧代码页读取，导致引号损坏或 ParserError。本版脚本统一为纯 ASCII 或 UTF-8 BOM，测试及构建均拒绝无 BOM 非 ASCII 脚本。

当前用户原有停止脚本已能通过只读解析检查；本版不重写该文件，也不声称它仍处于故障状态。包中的 `Stop-Misty-TUN.ps1` 仅为新 AutoBridge 的安全兼容名称，实际调用本安装目录的归属核验停止入口，**不能用于停止旧手工 Misty TUN**。

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
