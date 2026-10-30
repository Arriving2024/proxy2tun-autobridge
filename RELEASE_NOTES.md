# Proxy2TUN AutoBridge v0.2.1 — experimental patch prerelease

整合 v0.2.0 在朋友电脑部署和本机排障中发现的封装层问题，保留现有 Detect / Generate / Watch、并排安装、配置回滚、紧急停止和可逆卸载。

- **指定代理直接检查**：`-ProxyEndpoint` 在发现阶段就限定地址、端口和协议，跳过无关端口扫描。
- **核验实际连接归属**：处理 Windows 监听表 PID 0、重复记录和漏项，通过保持中的连接核验真正的代理进程；未知归属不会默认放行。
- **修正拆分路由检查**：验证完整 CIDR 并集，兼容回环地址排除造成的进一步拆分；缺少公网覆盖或网卡归属不符仍拒绝启动。
- **修正 DNS 误停**：正确识别有相关、完整 SOA 的合法 NODATA 响应，保留事务和报文结构验证。
- **合并脱敏调试记录**：记录朋友代理可达但 TUN 未运行、手动 TUN 可达，以及本机误判修复；区分真实输出、历史回顾、模拟测试和待完成验收。诊断步骤避开 PowerShell 5.1 的空字符串原生命令参数陷阱。

下载 `Proxy2TUN-AutoBridge-v0.2.1-windows-x64-source.zip`，与 `SHA256SUMS.txt` 核对后解压。升级时先用旧安装目录自己的停止入口退出，再按 README 并排安装到新目录；保留旧安装便于回退。源码包包含文件清单，不包含第三方二进制、节点、订阅、账户信息、运行日志或私人配置。

本版继续标记实验性预发布。本机旧 Misty 启动器的五轮实际 DNS/HTTPS 检查通过，是同源修复逻辑的现场证据；它不能代替 v0.2.1 完整通用封装在朋友电脑上的管理员验收。HTTP 401、Cloudflare challenge 403 或配置校验通过，也不代表已完成登录后的模型请求或所有远控功能。

详见 [README](https://github.com/Arriving2024/proxy2tun-autobridge/blob/v0.2.1/README.md)、[现场调试记录](https://github.com/Arriving2024/proxy2tun-autobridge/blob/v0.2.1/docs/field-debug.md)、[验证范围](https://github.com/Arriving2024/proxy2tun-autobridge/blob/v0.2.1/docs/validation.md) 和 [第三方说明](https://github.com/Arriving2024/proxy2tun-autobridge/blob/v0.2.1/THIRD-PARTY-NOTICES.md)。
