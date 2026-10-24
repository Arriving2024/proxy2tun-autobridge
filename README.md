# Proxy2TUN AutoBridge

**v0.2.0 · 实验性预发布 · Windows 11 x64 · 前台运行 · MIT**

把 Windows 本机可用的 SOCKS5 / HTTP CONNECT 代理接到 sing-box TUN。自动检测本地代理、生成配置并监控连接；停止后撤销本工具的 TUN 接管。默认不安装服务、计划任务或开机启动项，不修改 Windows System Proxy。

实际仓库是 [Arriving2024/proxy2tun-autobridge](https://github.com/Arriving2024/proxy2tun-autobridge)。本次从已发布的 **v0.1.0**（`35f73bb`）继续开发 v0.2.0；发行状态与下载以仓库 [Releases](https://github.com/Arriving2024/proxy2tun-autobridge/releases) 为准。

Misty 是用户手动验证成功的首个适配案例。通用版本按检测到的协议、地址、端口生成 `upstream` 出站，DNS 的 `detour` 引用这个出站，**不要求 Misty 或固定的 10808 端口**。用户提供的手动恢复记录与新封装测试范围分别记在 [验证记录](docs/validation.md)。

本次用户提供的 Windows 11 复现记录：`socks5h` 访问 `https://chatgpt.com` 约 0.4 秒返回 HTTP 403 / `Cf-Mitigated: challenge`；`socks5` 使用本地 DNS 时 timeout；旧 TUN 为 HTTP 000 / reset。重建 TUN 并接管 DoH 后，`Resolve-DnsName -Type A` 正常，HTTPS 返回 HTTP 403（0.476090 秒），用户确认 Remote 恢复。**这是手动方案的用户记录，不能替代新版封装的实机验收。**

## v0.2.0 的变化

- 为 sing-box 1.14.x TUN 启用 `dns_mode: hijack`。默认 DoH 使用 `1.1.1.1:443`、TLS SNI `cloudflare-dns.com`、`/dns-query`，通过选中的本地代理转发。
- 用精确核心进程路径、loopback 路由排除和底层接口检测降低 DNS / 路由回环风险。系统 DNS 引导直连仅作为显式兼容选项，见 [架构](docs/architecture.md)。
- 启动后检查专用网卡/路由、系统 DNS、绕过缓存的新查询与经过 TUN 的 HTTPS；定期检查代理、出口接口变化，以及核心活着但转发失败的情况。Cloudflare challenge 的 HTTP 403 单独分类，避免误判为断网。
- 重建有失败阈值、接口变化防抖、有限次数和退避。持续失败后释放自己启动的 TUN，进入 `RecoveryPaused`，等待用户检查并重新启动。
- 生成配置先校验，再原子替换并备份；启动验证失败后停止自己的核心并回滚。PowerShell 脚本限定纯 ASCII 或 UTF-8 BOM，兼容系统 PowerShell 5.1。
- 保留归属核验、紧急停止、可逆卸载和前台默认行为。源码发行包不包含代理配置、运行日志或第三方二进制。

## 网络边界

支持本机**无需认证**的 SOCKS5 / HTTP CONNECT；不执行 PAC，不导入订阅或节点配置。支持经上游转发的公网 TCP；局域网 TCP 直连。一般 UDP / QUIC / ICMP 拒绝，SOCKS5 握手成功也不代表支持 UDP relay。远程控制软件的 TCP 通道可能恢复，但本项目不承诺所有远控、游戏或语音协议可用。

这不是隐私型 VPN，没有 kill switch。停止、退出或故障撤销后恢复普通网络。默认 DNS 接管有上述明确边界；上游核心绕过、局域网行为、显式系统 DNS 引导选项以及 Windows 其他应用的加密 DNS，使它不能作为“所有 DNS 均不直连”的隐私保证。

已有 sing-box 运行时拒绝开启新的 TUN。应先通过原工具正常停止原有 TUN，再启动 AutoBridge；不要为测试而叠加两个 TUN。**本版本不修改、迁移或覆盖现有 `C:\Misty-TUN\config.json`。**

## 安装与升级

需要 Windows 11 x64、64 位 Windows PowerShell 5.1 或更新版本，以及本地代理客户端。安装通常无需管理员权限；开启和停止 TUN 需要管理员权限。

1. 在 [Releases](https://github.com/Arriving2024/proxy2tun-autobridge/releases) 选择 v0.2.0 预发布，下载 `Proxy2TUN-AutoBridge-v0.2.0-windows-x64-source.zip` 和 `SHA256SUMS.txt`，核对 ZIP 的 SHA-256 后解压。
2. 升级时，先用**旧安装目录自己的** `Stop-Bridge.ps1` 停止旧 AutoBridge。若正在使用原有手工 TUN，在准备正式切换前保留其正常连接；正式切换时用它自己的停止方式退出。不要运行两个 TUN。
3. 在新解压的源码目录执行安装。新用户可使用默认目录：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
   ```

   从旧版升级应并排安装到新目录，保留旧目录用于回退：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -InstallDir "$env:LOCALAPPDATA\Proxy2TUN-AutoBridge-v0.2.0"
   ```

4. 进入新安装目录，启动原代理客户端。先运行下面的 Detect / Generate 检查。正式切换前正常停止其他 TUN，再右键 `Start-Bridge.cmd` → **以管理员身份运行**，保留前台窗口。
5. 看到验证结果后试开实际使用的网页或远程控制连接。停止时按 `Ctrl+C`；紧急停止可右键 `Stop-Bridge.cmd` → **以管理员身份运行**。

安装器拒绝覆盖已有目录，从 [SagerNet 官方 v1.14.2 Release](https://github.com/SagerNet/sing-box/releases/tag/v1.14.2) 下载固定 Windows amd64 依赖并校验 SHA-256。也可以自行从官方获取该版本后指定：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -SingBoxPath 'C:\Downloads\sing-box.exe'
```

源码包不含 sing-box、Misty 或节点信息。第三方来源与许可证见 [第三方说明](THIRD-PARTY-NOTICES.md)。首次使用 TUN 可能由 sing-box 安装共享 Wintun 驱动。`ExecutionPolicy Bypass` 仅用于这次进程，不修改系统策略。

## 先检查，再开启

在安装目录运行，只检测代理、不改变网络：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-Bridge.ps1 -Mode Detect
```

生成并校验 `runtime\preview.json`，不启动 TUN：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-Bridge.ps1 -Mode Generate
```

自动检测会参考 Windows System Proxy 和 loopback 监听端口，并验证协议握手及外部 TLS 握手。存在多个代理时可固定入口；下面地址仅为示例，应使用本机实际端口：

```powershell
.\Start-Bridge.ps1 -Mode Watch -ProxyEndpoint 'socks5://127.0.0.1:10808'
# HTTP example:
.\Start-Bridge.ps1 -Mode Watch -ProxyEndpoint 'http://127.0.0.1:10809'
```

`Watch` 需管理员窗口。若客户端委托独立目录中的拨号核心，可补充实际完整路径：

```powershell
.\Start-Bridge.ps1 -Mode Watch -ExtraDirectProcessPath @('C:\Tools\ExampleProxy\core.exe')
```

默认每 3 秒检查代理及专用网卡/路由，连续 2 次失败触发撤销；每 30 秒检查系统 DNS、新查询和 HTTPS。新查询使用随机域名并直接请求 TUN DNS，避免旧缓存掩盖 DoH 故障；系统正常域名解析另行检查。启动宽限为 15 秒，接口变化防抖为 6 秒。故障恢复默认最多 3 次，按 10 秒起始指数退避、上限 120 秒；连续健康 300 秒才重置恢复预算。探测本身有超时，因此这些设置不是严格恢复时限。参数以脚本声明为准。

`RecoveryPaused` 表示已用尽恢复预算，本实例已释放 TUN。检查日志、代理和实际网络后，先停止前台窗口，再重新运行；不会在后台无限重启。

## 日志、回滚与停止

运行窗口显示日志；另开窗口查看：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Show-Logs.ps1
```

`-Core` 跟随最近的 sing-box 日志。运行日志、状态、生成配置和上一份配置备份位于本安装目录的 `runtime\`。诊断会记录故障分类、重建次数和状态变化；核心日志仍可能含程序路径、目标域名或 IP。公开 issue 前请遮盖个人信息，**不要上传整个 runtime 或原客户端配置**。

配置切换会保留上一份配置；启动验证失败时先停止新核心、撤销本实例接管，再恢复配置文件。备份恢复不等于已经启动旧版 TUN。需要回退版本时，停止新版，用旧安装目录重新启动；不要把两版配置或状态文件互相复制。

正常停止与紧急停止：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Stop-Bridge.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Stop-Bridge.ps1 -Emergency
```

停止会核验实例身份，仅处理本安装目录拥有的进程与专用网卡。兼容入口 `Stop-Misty-TUN.ps1` 也是停止**本目录 AutoBridge**，不接管旧手工 Misty TUN。历史脚本编码故障和离线修复方式见 [故障排查](docs/troubleshooting.md)。

## 卸载

在对应安装目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

卸载先停止该目录的实例，再按安装清单删除工具文件；默认保留运行数据和用户自行放入的文件。首次卸载若要清除运行数据，追加 `-PurgeData`。正在以管理员身份运行的实例，卸载也需管理员窗口。

卸载拒绝无归属清单、路径越界与目录联接/符号链接。不会卸载原代理客户端或共享 Wintun 驱动；系统事件日志也可能保留。源码目录不是安装目录，不能交给卸载器。

## 验证与构建

本版保持实验性预发布。用户手工恢复成功，不能替代新封装在 Wi-Fi / 以太网切换、实际远控及真实 TUN 清理上的管理员验收。自动化套件不创建 TUN，范围和实测状态见 [验证记录](docs/validation.md)。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1
# Include official configuration and isolated install/uninstall checks:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1 -SingBoxPath 'C:\Tools\sing-box.exe'
# Stage intended new source files before building:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Release.ps1 -OutputDirectory 'C:\ReleaseOutput\v0.2.0'
```

构建只取 Git 已跟踪的显式白名单源码，校验 PowerShell 编码，生成 ZIP、逐文件清单和 SHA-256，并重新读取最终 ZIP 核对每个文件。已有同名输出会拒绝覆盖。构建不等于测试通过或发布成功。

- [更新记录](CHANGELOG.md) · [本次发行说明](RELEASE_NOTES.md)
- [架构与生命周期](docs/architecture.md) · [故障排查](docs/troubleshooting.md)
- [验证与复现记录](docs/validation.md) · [MIT License](LICENSE) · [第三方说明](THIRD-PARTY-NOTICES.md)

## English summary

Proxy2TUN AutoBridge v0.2.0 is an experimental Windows 11 x64 foreground wrapper for local unauthenticated SOCKS5 / HTTP CONNECT proxies and sing-box 1.14.2. It enables TUN DNS hijacking with encrypted DoH through the dynamically selected upstream, uses scoped process bypasses, verifies system DNS and HTTPS, distinguishes Cloudflare challenge responses, and bounds recovery attempts with backoff. No startup service or task is installed by default.

Public TCP is supported; general UDP / QUIC / ICMP is rejected. There is no kill switch or blanket DNS privacy guarantee. Installation, stop, configuration rollback and uninstall are scoped to the owned instance. No original client configuration, credentials, runtime data, or third-party executable is redistributed. User-supplied manual recovery evidence and automated non-TUN checks are documented separately. This independent project is not affiliated with Misty, SagerNet, Microsoft, or other upstream clients.
