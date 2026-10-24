# v0.2.0 验证与复现记录

记录日期：2026-10-24。基线为实际仓库 [Arriving2024/proxy2tun-autobridge](https://github.com/Arriving2024/proxy2tun-autobridge) 已发布的实验性 v0.1.0，标签提交 `35f73bb42ce819e724a9758d98f93142d29e10bf`。本次按新增健康监控与 DNS 默认行为变更选择 v0.2.0，继续作为预发布。

## 用户提供的 Windows 11 手动恢复记录

下面是用户提供并确认恢复的记录摘要，**不是本版新封装的自动化实测结果**。这里只保留协议、公共探测目标和故障分类，不附私人节点、账户、解析地址或本机原始日志。

| 顺序 | 观察 | 能支持的结论 |
| --- | --- | --- |
| 1 | 经 `socks5h` 请求 `https://chatgpt.com`，约 0.4 秒收到 HTTP 403，`Cf-Mitigated: challenge` | 远端解析的代理 HTTPS 通道可达；服务要求 challenge，不能把 403 当成网络断开 |
| 2 | 同一入口使用 `socks5` 本地解析方式发生 DNS timeout | 本地 DNS 路径存在故障；本地代理能通不证明系统 DNS 可用 |
| 3 | 旧 TUN 请求为 HTTP 000 / reset | 原 TUN 数据路径失败；核心存在不等于转发健康 |
| 4 | 候选配置通过 sing-box 检查；重建 TUN，启用 `dns_mode: hijack`，DoH 经本地 SOCKS5 detour，使用 `1.1.1.1:443`、SNI `cloudflare-dns.com`、`/dns-query` | 这是用户实际采用的修复组合；不能仅凭配置检查宣称已经恢复 |
| 5 | 重建后 `Resolve-DnsName -Type A` 成功；HTTPS 返回 HTTP 403，耗时 0.476090 秒 | 系统解析和该次 HTTPS 传输恢复，403 仍属于 challenge / 服务访问层 |
| 6 | 用户确认“恢复了”，Remote 恢复 | 用户使用中的远控恢复；不证明所有远控协议或新封装已验证 |

通用代码把上述 `detour` 指向按检测结果生成的 `upstream`（SOCKS5 / HTTP），不写死某客户端标签或端口。发行过程不导入、改写或打包现有手工配置；当前正常连接不用于破坏性回归测试。

## 本版自动化验证范围

以下项目的实际执行结果以测试命令输出和对应提交的 CI 为准。合成代理、模拟网卡/核心及隔离安装检查**不创建真实 TUN，不改变当前路由**。不把 v0.1.0 的历史断言数量直接算作 v0.2.0 的本次通过数量。

| 检查 | 范围 |
| --- | --- |
| PowerShell 5.1 语法与编码 | 所有 ps1/psm1；纯 ASCII 或有效 UTF-8 BOM；非 ASCII 无 BOM 拒绝；离线修复输出与兼容停止入口 |
| 代理发现 | System Proxy 解析、SOCKS5 / HTTP CONNECT、分段响应、超时、误判防护、进程身份与歧义处理 |
| DNS 与路由配置 | TUN hijack、DoH 地址/SNI/path、动态出站、默认无共享 DNS 直连、显式引导兼容选项、规则顺序与 JSON 编码 |
| 配置事务 | 官方校验前不替换；备份原字节；原子切换；失败回滚；首启撤销；外部修改后拒绝覆盖 |
| 健康与恢复策略 | challenge 403 与服务错误/网络错误分类；新查询 DNS 报文校验/超时；独立系统 DNS；网卡 GUID/状态及 IPv4/IPv6 路由覆盖；出口变化防抖；预算/退避；持续健康后重置；暂停恢复 |
| 进程生命周期 / Watch / Stop | 一次性测试子进程及模拟核心/代理/网卡；等待、启动、失联、恢复、正常/紧急停止与无关进程保留 |
| 安装与卸载 | 独立临时目录；归属清单、已有目录/越界/链接拒绝；保留未知文件；可选清除数据 |
| 官方核心兼容 | 固定官方 sing-box 1.14.2 对 SOCKS5 / HTTP 生成配置执行 `check`；不启动真实核心转发 |
| 发行包 | 跟踪源码白名单、脚本编码、最终 ZIP 逐文件 SHA-256、清单、外部校验和；无运行数据和第三方二进制 |

官方 Windows amd64 1.14.2 ZIP 的固定 SHA-256 在本次重新核对为 `c2d8bfff918755808781dfdeeb8581b6c91eb3a243d9a7b55483cfc0c0684d32`，二进制版本输出为 1.14.2 / windows amd64。原有手工停止脚本只读语法检查通过；发行包增加编码回归保护，不覆盖该脚本。

本次最终整套本地检查已在 Windows PowerShell **5.1.26100.9711** 通过：22 个 PowerShell 文件的语法/编码检查、60 项发现/配置断言（含官方核心检查）、18 项配置事务断言、57 项健康检查、17 项进程生命周期检查、48 项监控集成检查，以及 8 项隔离安装/卸载检查。额外覆盖了清理检查失败时保留归属状态、BOM 编码修复和中文安装目录下无 BOM UTF-8 状态文件的停止入口。最终输出为 `PASS all requested local checks. No TUN was created by this suite.`

源码包构建检查通过 39 个白名单文件及内嵌清单的逐项回读校验。上述本地结果不替代发布工作流结果，也不代表待完成的管理员实机验收已通过。

本次还用新入口完成了当前本地代理的只读自动检测及 `-Mode Generate` 烟测：自动选择可用代理，在新源码目录生成独立 preview，并通过官方核心 `check`。没有启动新 TUN或改变当前路由；原手工配置的前后完整性核对一致。本机 preview、路径、端口和校验细节不随包公开。

## 复现自动化检查与构建

在源码目录的系统 Windows PowerShell 5.1 中执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1
```

包含官方配置和隔离安装/卸载检查时，使用从官方取得的固定核心：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1 -SingBoxPath 'C:\Tools\sing-box.exe'
```

预期：全部请求的检查输出 PASS，最后明确提示没有创建 TUN。任何异常均应先修复，不用历史结果替代本次输出。进程测试可能打印一次性测试子进程的 CTRL_BREAK 提示；测试负责限时清理。

构建要求新增发行源码已纳入 Git 跟踪。输出目录不能已存在同名发行文件：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Release.ps1 -Version v0.2.0 -OutputDirectory 'C:\ReleaseOutput\v0.2.0'
Get-FileHash 'C:\ReleaseOutput\v0.2.0\Proxy2TUN-AutoBridge-v0.2.0-windows-x64-source.zip' -Algorithm SHA256
```

发布工作流仅在相关提交测试和构建成功后发布实验性预发布，遇到已有版本/标签拒绝覆盖。在线发布是否完成以实际 Release 页面为准，不能把本地生成 ZIP 视为已发布。

## 仍需管理员实机验收

本次不为了验证新封装而停止当前正常手工 TUN、叠加第二个 TUN或修改其配置。下面是待执行的真实机器验收，不是已通过的结果：

1. 在能本地操作并恢复的 Windows 11 x64 设备上，保留旧安装和恢复入口，记录起始网络状态；通过各自工具正常关闭其他 TUN。
2. 用新目录 Detect / Generate 检查选中的真实核心与 DoH，管理员启动。确认启动 DNS / HTTPS 分类，实际打开网页并连接使用中的远控产品。
3. 分别切换 Wi-Fi / 以太网、短暂断开/恢复物理网络，核对防抖、退避与一次安全重建；保留其他应用的访问情况。
4. 退出/重启代理客户端，验证端口/身份变化；模拟可控的“核心活着但转发失败”，核对连续失败阈值和预算用尽后释放 TUN并进入 `RecoveryPaused`。
5. 检查正常停止、关闭窗口、紧急停止和卸载；对照起始状态确认只撤销本实例的网卡/路由，原代理客户端仍能独立使用。
6. 在新版本停止后回退旧安装，验证可逆。另行验证 IPv6、不同客户端和复杂进程树，不能从 IPv4 A 记录成功外推。

无管理员端到端验收，不宣称新版已通过真实 TUN 切网、所有远控、驱动异常或断电恢复。手工方案成功、单元检查通过、模拟集成通过与实机验收是不同证据。
