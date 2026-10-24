# Proxy2TUN AutoBridge v0.2.0 — experimental prerelease

继续实际仓库的 v0.1.0，修复“本地代理可用，TUN 存活但 DNS / 转发失败”的恢复路径，并保持现有 Detect / Generate / Watch、归属核验、紧急停止及卸载入口。

- sing-box 1.14.x TUN 改为 `dns_mode: hijack`；Cloudflare DoH 使用 `1.1.1.1:443`、SNI `cloudflare-dns.com`、`/dns-query`，通过自动检测的 SOCKS5 / HTTP `upstream` 出站。端口和客户端名称不写死为 Misty。
- 启动和运行中验证 DNS / HTTPS，识别 Cloudflare challenge HTTP 403；监测出口接口、代理健康和核心存活但转发失效。连续失败按有限预算和退避恢复，用尽后释放本实例 TUN 并暂停恢复。
- 生成配置先检查、再原子替换和备份；启动验证失败后撤销新实例并回滚。PowerShell 编码检查防止 5.1 将无 BOM 中文脚本误解为旧代码页。
- 增加离线编码修复工具、单元/模拟集成检查，以及只含白名单源码的 ZIP、文件清单和 SHA-256 校验。

用户提供的 Windows 11 手动记录显示：`socks5h` HTTPS 在约 0.4 秒收到 Cloudflare challenge HTTP 403；使用本地 DNS 的 `socks5` 超时；旧 TUN 为 HTTP 000 / reset；重建 TUN 并接管 DoH 后系统 DNS 恢复，HTTPS 返回 403（0.476090 秒），用户确认 Remote 恢复。**这是用户手动方案的证据，不代表本版新封装已通过真实 TUN、Wi-Fi / 以太网切换或所有远控软件验收。** 当前自动化验证范围、命令与限制见 [验证记录](https://github.com/Arriving2024/proxy2tun-autobridge/blob/v0.2.0/docs/validation.md)。

下载 `Proxy2TUN-AutoBridge-v0.2.0-windows-x64-source.zip` 并与 `SHA256SUMS.txt` 核对。升级时先用旧安装目录自己的停止入口退出，再按 README 并排安装到新目录；需要回退时先停止新版，再运行保留的旧版。不要同时开启两个 TUN，也不要覆盖原有手工配置。本包不包含 sing-box、Misty、节点、订阅、账户信息或本机运行数据。

保留前台默认行为，不添加开机任务/服务。本版支持公网 TCP，一般 UDP / QUIC / ICMP 拒绝，无 kill switch 或全流量隐私保证。继续标记为实验性预发布；详见 [README](https://github.com/Arriving2024/proxy2tun-autobridge/blob/v0.2.0/README.md)、[CHANGELOG](https://github.com/Arriving2024/proxy2tun-autobridge/blob/v0.2.0/CHANGELOG.md) 和 [第三方说明](https://github.com/Arriving2024/proxy2tun-autobridge/blob/v0.2.0/THIRD-PARTY-NOTICES.md)。
