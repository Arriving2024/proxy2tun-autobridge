# Proxy2TUN AutoBridge v0.1.0

Windows 11 x64 的实验性最小版本：自动发现本机无需认证的 SOCKS5 / HTTP CONNECT 代理，并以 sing-box TUN 为已有客户端补充系统 TCP 转发入口。独立社区项目，与 Misty / SagerNet 无官方关系。

- 自动读取 Windows System Proxy 和 loopback 监听端口，验证 CONNECT 与 TLS ServerHello。
- 识别端口、PID、执行路径与父进程；支持 Misty 的 Privoxy / v2ray 兄弟进程，优先选用 SOCKS5 核心。
- 生成 sing-box 配置，按精确进程路径绕过上游核心；提供手动入口与额外核心路径设置。
- 前台监控上游出现、丢失及重启，提供实时日志、正常停止、紧急停止和 Windows Job 子进程保护。
- 安装与卸载使用文件归属检查；默认不安装服务、任务或开机启动项。
- sing-box 1.14.2 从官方 Release 下载并核验固定 SHA-256，或由用户自行提供。本发行包不含 Misty、sing-box 二进制、订阅或节点凭据。

本地 PowerShell 5.1 语法、50 项发现/配置断言、17 项进程生命周期检查、11 项模拟监控/停止集成检查、8 项安装/卸载检查及官方核心配置检查通过。本机 Misty 自动检测和配置生成通过。模拟集成检查不创建真实 TUN。完整证据与复现命令见 `docs/validation.md`。

**验证限制：本次没有切换正在使用的现有 TUN；新封装的管理员端到端 TUN 转发及实际网卡恢复尚未实测，故标记为预发布。** 本版主要支持 TCP；一般 UDP/QUIC/ICMP 拒绝，系统 DNS 可直连，无 kill switch，不提供全流量或 DNS 隐私保证。

下载 `Proxy2TUN-AutoBridge-v0.1.0-windows-x64-source.zip`，解压后按 README 运行 `install.ps1`。安装完成后右键 `Start-Bridge.cmd` 以管理员身份运行。需要紧急停止时，同样以管理员身份运行 `Stop-Bridge.cmd`。
