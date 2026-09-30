# v0.1.0 本地验证 / Validation

验证日期：2026-09-30。环境：Windows 11 Pro for Workstations x64，系统版本 10.0.26200，Windows PowerShell 5.1.26100.9549，官方 sing-box 1.14.2 Windows amd64。

## 已通过

| 检查 | 结果与范围 |
| --- | --- |
| PowerShell 语法 | 所有 `.ps1` / `.psm1` 通过系统 PowerShell 5.1 解析 |
| 代理发现与配置 | 50 项断言：系统代理解析、IPv6 loopback、SOCKS/HTTP 探测、分段响应、认证拒绝、普通网页误判防护、超时、歧义选择、Misty 同父进程选择、PID 重用、精确路径绕过、DNS/UDP 策略、JSON 编码 |
| Windows 进程生命周期 | 17 项检查：原生辅助代码编译、子进程启动、身份校验、停止、重复清理、主进程崩溃后 Job 自动终止子进程、无关进程保留 |
| Watch / Stop 模拟集成 | 11 项检查：使用原样入口脚本和模拟核心、网卡、代理，检查等待、启动、失联撤销、恢复重启、正常停止与紧急停止；没有测试真实网卡 |
| 安装与卸载 | 8 项隔离检查：新目录安装、已有目录拒绝、源码/无归属目录拒绝、清单越界拒绝、默认保留数据、目录联接拒绝、清除运行数据并保留未知文件 |
| 官方核心配置检查 | SOCKS5 和 HTTP 两份生成配置均通过 `sing-box check` |
| 官方依赖下载 | Windows amd64 ZIP 的 SHA-256 与固定官方资产 digest 一致；没有将二进制加入本项目包 |
| 本机 Misty 只读检查 | 检测到 HTTP 10809 / `v2ray_privoxy.exe` 和 SOCKS5 10808 / `v2ray.exe`，确认同一 Misty 父进程；自动选择 SOCKS5 10808，生成 `v2ray.exe` 与 Misty 精确路径 DIRECT 规则，并通过官方核心配置检查 |

协议单元测试使用本机合成服务器，不是真实代理服务或完整 TLS 证书验证。进程生命周期测试启动的是一次性测试子进程，不是 TUN。安装测试使用已从官方发行包取出的核心，只运行版本检查，不启动核心转发。

## 尚未验证

本次没有管理员权限，且机器上已有用户正在使用的 Misty TUN。为保持该连接，本次没有启动新 TUN、关闭旧 TUN或改变系统路由。因此 **新自动封装的管理员端到端启动、真实路由转发、IPv6 联通、上游退出/重启后的真实网卡恢复，以及紧急停止的真实网卡清理，均不能宣称已实测通过**。

Misty + sing-box 是发起人此前确认成功的手动案例。本次只读取了已有桥接配置中的路由和本地出口字段，确认其使用 `127.0.0.1:10808`、v2ray DIRECT 和自动接口检测；未提取节点、订阅或账号凭据。历史手动案例和新封装测试属于不同证据。

v0.1.0 作为实验性预发布提供。它支持的网络范围、允许 DNS 直连、无断网保护、非通用 UDP 转发等限制见 README。没有测试不等于失败，也不等于已验证兼容。

## 复现基础检查

在源代码目录打开 Windows PowerShell：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1
```

同时检查官方配置兼容和安装/卸载，提供从官方 Release 获取的核心：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1 -SingBoxPath 'C:\Tools\sing-box.exe'
```

测试输出为本次实际结果；测试用例不创建 TUN。安装测试使用独立临时目录，并在最后打印位置供检查。生命周期测试中给 PowerShell 测试子进程发送 CTRL_BREAK 可能打印调试提示，随后经过限时强制清理；这不代表测试要求人工交互。

## 后续管理员验收

在可本地恢复的 Windows 11 测试机器上，先关闭其他 TUN，再记录默认路由/网卡，依次测试开启、应用 TCP、DNS、IPv6、上游退出与重启、正常停止、关闭窗口、紧急停止，最后对照路由和网卡确认只撤销本实例的接管。该步骤是后续实机验收清单，**不是本次已经完成的测试**。
