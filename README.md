# Proxy2TUN AutoBridge

**v0.1.0 · Windows 11 x64 · 前台运行 · 独立社区项目**

将 Windows 本机已提供的 SOCKS5 / HTTP 代理连接到 sing-box TUN。工具发现可用代理后启动自己的 TUN；上游消失后停止自己的 TUN，让系统恢复原有网络。适合为已有代理客户端补充 TUN 入口。

Misty + sing-box 是项目发起人此前手动验证成功的首个适配案例。**本版本新增的自动化封装，已完成与尚未完成的验证均列在 [验证记录](docs/validation.md) 中**；手动方案成功不等于本版本在所有客户端或设备上都已通过实机测试。本项目不宣称首创，也不保证“任何 VPN / 所有流量”均可兼容。

## v0.1.0 能做什么

- 读取当前用户 Windows System Proxy，枚举本机 loopback 监听端口。
- 实际探测 SOCKS5 / HTTP CONNECT，识别端口所属 PID、可执行文件路径与父进程。
- 生成 sing-box 配置，用精确进程路径绕过已识别的上游核心，降低 TUN 回环风险。
- 前台循环监控：上游出现时连接，连续失联达到阈值时撤销；默认每 3 秒检查，连续 2 次失败视为失联。
- 提供停止、紧急停止、实时日志，以及有文件归属检查的安装与卸载脚本。
- 默认不添加 Windows 服务、计划任务、开机启动项，不修改 Windows System Proxy。

## 本版网络边界

**这不是隐私型 VPN，也没有断网保护（kill switch）。** 停止、上游丢失或退出后，系统恢复直连。普通 Windows DNS 可直连，不提供 DNS 泄漏保护；TUN 捕获的其他 DNS 使用经上游代理的 DoH。一般 UDP / QUIC / ICMP 不在本版支持范围内，配置会拒绝这些流量；支持的是可经上游转发的公网 IPv4 / IPv6 TCP。局域网 TCP 保留直连；普通局域网 UDP 也受拒绝规则限制，已绕过的上游进程与 Windows DNS 例外。

仅支持本机无需用户名/密码认证的 SOCKS5 和 HTTP CONNECT；不支持 PAC 求值、需要认证的代理、只提供远端服务而无本地监听端口的 VPN。SOCKS5 支持不代表上游提供 UDP relay。UDP 型远程控制、游戏、语音或视频软件可能无法工作，应用有 TCP 回退时才可能继续使用。

进程绕过仍依赖客户端结构：若监听程序另外委托独立目录中的核心拨号，需显式补充该核心路径。更改客户端程序路径后会重新识别。已有 sing-box 实例时 Watch 会拒绝启动，避免干扰正在使用的网络；先正常关闭原有 TUN，再启动此工具。

## 安装

需要 Windows 11 x64、64 位 Windows PowerShell 5.1（系统自带）或更新版本，以及能正常工作的本地代理客户端。创建 TUN 时需要管理员权限；单纯探测和生成配置通常不需要。

1. 从本仓库的 **Releases → v0.1.0** 下载源代码包并解压到一个普通本地目录。
2. 在该目录打开 PowerShell，执行：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
   ```

3. 安装完成后，在资源管理器地址栏输入 `%LOCALAPPDATA%\Proxy2TUN-AutoBridge`，进入安装目录。
4. 启动你的原有代理客户端，确认其本地代理可用。右键安装目录的 **Start-Bridge.cmd → 以管理员身份运行**，接受 Windows 管理员授权，并保留打开的窗口。
5. 在窗口中查看被选中的代理、进程和连接状态。正常停止时按 `Ctrl+C`；紧急停止可右键 **Stop-Bridge.cmd → 以管理员身份运行**。

安装器从 [SagerNet 官方 v1.14.2 Release](https://github.com/SagerNet/sing-box/releases/tag/v1.14.2) 下载 Windows amd64 包，校验固定 SHA-256 后提取执行文件。源码包和本项目 Release 不包含 sing-box、Misty 或节点凭据。第三方来源、许可证与固定校验值见 [第三方说明](THIRD-PARTY-NOTICES.md)。首次 TUN 运行可能由 sing-box 安装 Wintun 驱动。

不能访问 GitHub 时，先自行从官方 Release 获取 `sing-box.exe`（**1.14.2，windows/amd64**），然后执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -SingBoxPath 'C:\Downloads\sing-box.exe'
```

也可用 `-InstallDir 'D:\Tools\Proxy2TUN-AutoBridge'` 安装到另一个新目录。安装器拒绝覆盖已有目录；不读取或复制原客户端的配置。`ExecutionPolicy Bypass` 只作用于这次 PowerShell 进程，不修改系统执行策略。

## 先检查，再开启

以下命令均在安装目录执行。只检查当前候选代理，不改变网络：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-Bridge.ps1 -Mode Detect
```

生成配置但不启动 TUN：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-Bridge.ps1 -Mode Generate
```

有多个代理，或希望固定使用某个入口时：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-Bridge.ps1 -Mode Watch -ProxyEndpoint 'socks5://127.0.0.1:10808'
```

HTTP 示例为 `-ProxyEndpoint 'http://127.0.0.1:10809'`。`Watch` 必须在管理员窗口中运行。默认自动检测会优先参考 Windows System Proxy，但仍要求握手探测成功；不会把每个监听端口都当作代理。

在已打开的管理员 PowerShell 中可直接传入额外核心路径：

```powershell
.\Start-Bridge.ps1 -Mode Watch -ExtraDirectProcessPath @('C:\Tools\ExampleProxy\core.exe')
```

该路径只是格式示例，应替换为实际拨号核心的完整路径。无需、也不要输入订阅链接、节点配置或账号密码。完整参数以 `Get-Help .\Start-Bridge.ps1 -Full` 和脚本参数声明为准。

## 日志与停止

运行窗口直接显示实时日志。另开一个 PowerShell 窗口可查看：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Show-Logs.ps1
```

日志和生成配置保存在安装目录的 `runtime\`。它们可能包含本机端口、程序路径，以及 sing-box 记录的目标域名/IP；公开提交 issue 前请检查并遮盖个人信息及访问记录。工具不会读取原客户端节点凭据。

`Show-Logs.ps1` 默认持续跟随主日志，`-Core` 跟随最近的 sing-box 核心日志；按 `Ctrl+C` 退出查看。

正常停止：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Stop-Bridge.ps1
```

紧急停止，在管理员 PowerShell 中执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Stop-Bridge.ps1 -Emergency
```

停止仅针对本安装目录记录并核验身份的实例和它的专用适配器，不按进程名终止所有 sing-box。窗口关闭时的清理由进程生命周期保护辅助完成；断电或系统崩溃后的恢复边界见 [故障排查](docs/troubleshooting.md)。

## 卸载

在安装目录中执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

卸载先停止该目录的 Bridge，再按安装清单删除工具文件；默认保留 `runtime\` 日志和用户后来放入的其他文件。若 Bridge 正在以管理员身份运行，卸载也需管理员窗口。需要同时删除运行数据时，在第一次卸载时使用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -PurgeData
```

卸载拒绝无归属清单的目录、路径越界与符号链接/目录联接。不会卸载 Misty、其他客户端或共享 Wintun 驱动包。路由与本工具的 TUN 实例应在停止后撤销；不声称 Windows 驱动仓库或系统事件日志完全无痕。源代码目录不是安装目录，不能用卸载器删除它。

## 文档与许可

- [架构与生命周期](docs/architecture.md)
- [故障排查与恢复](docs/troubleshooting.md)
- [本地验证记录与未覆盖项目](docs/validation.md)
- [MIT License（本工具原始代码）](LICENSE)
- [第三方依赖与非官方关系](THIRD-PARTY-NOTICES.md)

## English summary

Proxy2TUN AutoBridge is an independent Windows 11 x64 foreground wrapper that discovers local unauthenticated SOCKS5 / HTTP CONNECT proxies and connects them to sing-box TUN. It maps listening ports to executable paths, generates process bypass rules, watches upstream availability, and supports scoped emergency stop and reversible installation. No Windows service, scheduled task, or automatic startup entry is installed by default.

v0.1.0 targets sing-box 1.14.2. It supports public TCP over the detected upstream, preserves LAN TCP access, rejects general UDP/ICMP (including LAN UDP except bypassed cores and Windows DNS), permits normal Windows DNS to go direct, and has no kill switch. Misty is the first user-confirmed manual adaptation; see the validation record for the new wrapper's actual test coverage. This project ships no Misty binaries, subscription data, credentials, or sing-box binaries, and is not affiliated with those upstream projects.
