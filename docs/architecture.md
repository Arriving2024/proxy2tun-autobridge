# Architecture / 架构

## 数据路径与代码边界

```text
Windows public TCP + intercepted DNS
                 |
       unique owned sing-box TUN
                 |
    selected loopback SOCKS5 / HTTP CONNECT
                 |
         existing proxy dialing core
                 |
        original physical network

Intercepted DNS -> sing-box DoH -> selected upstream
Proxy owner / verified helper -> DIRECT -> physical network
```

Proxy2TUN AutoBridge owns discovery, generated configuration, health supervision and the lifecycle of its own child process. sing-box owns the virtual interface and active routing. The existing client continues to own its remote server settings, subscriptions and authentication; AutoBridge does not import those settings.

| Entry/module | Responsibility |
| --- | --- |
| `Start-Bridge.ps1` | Detect / Generate / Watch entry point; finite recovery state machine |
| `src/Discovery.psm1` | System Proxy/listener discovery, bounded SOCKS5 / HTTP probes, process identity |
| `src/Config.psm1` | sing-box 1.14.2 DNS/routing policy, validated configuration transactions |
| `src/Health.psm1` | Bounded system DNS / HTTPS checks, response classification, network fingerprints and recovery budgeting |
| `src/Lifecycle.psm1` / `src/NativeProcess.cs` | Owned state, scoped startup/stop, Windows child-process protection and cleanup |
| `Stop-Bridge.ps1` / `Stop-Misty-TUN.ps1` | Stop only the new owned AutoBridge instance; compatibility name does not target legacy Misty |
| `install.ps1` / `uninstall.ps1` | Fresh-directory allowlisted installation and ownership-checked removal |
| `tools/Build-Release.ps1` | Tracked-source allowlist, encoding checks, source archive, manifest and checksum verification |

## 发现与进程身份

The detector reads the current user's Internet Settings proxy configuration and inspects loopback listeners. PAC scripts are not executed. A listening port is not considered a proxy without successful protocol probing. Supported endpoints are local unauthenticated SOCKS5 and HTTP CONNECT.

Discovery requests a bounded outbound connection to `1.1.1.1:443` through the candidate and inspects TLS handshake framing. This is stronger than a local port-open check, but is **not certificate validation or a full HTTPS transaction**. A blocked probe destination may cause a false negative. Separate certificate-validated HTTPS health checks run after TUN startup.

Port ownership maps to PID, executable path, start time and parent identity. An inaccessible or ambiguous identity is rejected. Exact verified owner paths and legitimate related parent paths are bypassed; generic host/shell parents are excluded. `-ExtraDirectProcessPath` adds known external helper cores when a client's layout cannot be inferred. A changed path or process identity causes rediscovery rather than reuse of a stale identity.

## DNS 与路由回环

The TUN uses `dns_mode: hijack`, `auto_route: true` and `strict_route: false`. Loopback ranges are excluded from TUN routing, and `auto_detect_interface` selects an underlying interface for direct dialing. The configured DoH server is an IP literal, so resolving the DoH endpoint does not require DNS first:

```json
{
  "type": "https",
  "tag": "remote-dns",
  "server": "1.1.1.1",
  "server_port": 443,
  "path": "/dns-query",
  "tls": { "enabled": true, "server_name": "cloudflare-dns.com" },
  "detour": "upstream"
}
```

`upstream` is generated from the selected SOCKS5 / HTTP candidate. The DNS strategy is `ipv4_only`; successful A resolution does not demonstrate IPv6 resolution or connectivity.

Rule order is deliberate: verified proxy processes DIRECT; DNS port 53 hijacked; general UDP / ICMP rejected; private destinations direct; remaining public TCP through `upstream`. The proxy core must be able to reach its server outside TUN capture. If it delegates a server-hostname lookup to the shared Windows DNS Client after takeover, a circular bootstrap dependency can still occur.

By default, shared `svchost.exe` DNS traffic is **not** bypassed. For a confirmed bootstrap dependency, the explicit `-AllowSystemDnsBootstrap` switch adds the system `svchost.exe` port-53 DIRECT rule before interception. This is a compatibility escape hatch: the shared DNS service may serve many applications, so the exception can send their DNS direct too. It is never enabled automatically, and DNS health in that mode does not prove DNS traversed DoH. Prefer a healthy original proxy with its own cached/working server resolution and correctly identified dialing cores.

No kill switch is provided. Shutdown or failure releases TUN and permits ordinary network behavior. This policy is not a general traffic privacy guarantee or a guarantee against all DNS leaks. General UDP / QUIC / ICMP is unsupported; LAN TCP remains direct.

## 启动验证与故障分类

Startup and every polling cycle verify the owned adapter's GUID, Up state and complete IPv4/IPv6 default or split-default route coverage. A missing TUN route cannot be hidden by successful direct HTTPS. Route coverage does not itself prove IPv6 end-to-end connectivity.

During the startup verification window, and periodically while running, the wrapper checks a fresh TUN DNS request, Windows A-record resolution and certificate-validated HTTPS. Fresh DNS uses a random `p2t-<guid>.example.com` A query sent directly to the generated TUN DNS address `172.31.255.2:53`, with a bounded deadline. It validates the response source, transaction, question and records, accepting a positive A response or SOA-backed NXDOMAIN. The new query name prevents prior Windows/core cache entries from masking the DoH path failure, without flushing any shared DNS cache. The separate positive Windows resolver check can use cache and is not sufficient by itself.

HTTPS probes use the system `curl.exe`, ignore proxy environment variables and user curl configuration, pass no proxy, do not disable TLS validation and do not follow redirects. They test the ordinary application path while the owned TUN and routing checks remain valid. A second origin is attempted when the first transport fails, reducing rebuilds for a single blocked origin.

Probe classifications distinguish fresh DNS and system DNS errors/timeouts, TLS validation errors, transport errors/timeouts, successful HTTP, HTTP service errors and `CloudflareChallenge` (403 with `Cf-Mitigated: challenge`). A valid HTTP response proves the transport reached an HTTPS service; a challenge is not application access, login success, or remote-control health. An HTTP service error alone does not trigger a rebuild when DNS and HTTPS transport are healthy. Successful probes cannot establish every application's behavior.

Physical adapters, default routes, addresses, DNS server configuration and interface metrics contribute to a network fingerprint; the dedicated TUN is excluded. Raw network details are hashed for comparison rather than copied into the health log. A stable fingerprint change after debounce requests one scoped rebuild. Interface-query failure is not interpreted as a confirmed network change.

## 有限恢复与配置回滚

```text
Waiting -> Starting -> Verifying -> Running
              |            |         |
              +------------+---------+-- repeated failure / stable egress change
                                        |
                           stop owned core + cleanup
                                        |
                           Backoff -> retry within budget
                                        |
                          RecoveryPaused when exhausted

User stop / emergency stop / watcher exit -> scoped stop + cleanup
```

Defaults: proxy polling 3 seconds, failure threshold 2; forwarding health every 30 seconds; startup grace 15 seconds; network debounce 6 seconds; maximum recovery attempts 3; exponential delay from 10 seconds capped at 120 seconds; budget reset only after 300 seconds continuously healthy. Probe timeouts add elapsed time. A live core with failed forwarding is treated as unhealthy after the same failure policy. `RecoveryPaused` is latched for the session and requires explicit stop/relaunch; merely restarting the core does not reset its failure budget.

Each new configuration is written to a same-directory candidate, checked by the pinned core and atomically promoted. An existing configuration is saved byte-for-byte in a unique `runtime/config.json.backup-*` file. Failed startup verification tears down the new core before rollback; first-run rollback removes the newly created active configuration. Rollback verifies hashes and refuses to overwrite an active/backup file changed by another actor. Backups remain local. File rollback does not itself restart an older core.

## 归属、安装与撤销

Each session uses a unique `p2t-...` adapter. The global watcher mutex and refusal to run beside another sing-box reduce competing takeover. State records both executable identity and start time; stale PID data alone never authorizes termination. Emergency stop remains scoped to the recorded owned instance and dedicated adapter.

Installation copies an explicit source allowlist into a fresh directory and records hashes in its ownership manifest. It refuses existing targets, network shares and reparse points. sing-box is separately obtained from the pinned official release with a fixed SHA-256. The source release contains no third-party executable or runtime state.

Uninstall stops the owned session before removing manifest-owned tool files. Unknown files and runtime data remain by default; `-PurgeData` validates the runtime tree and refuses links. There are no default services, tasks, startup entries, System Proxy edits or persistent execution-policy changes. Shared Wintun packages and Windows event logs may remain after uninstall. Existing legacy manual configuration is never an installation target.
