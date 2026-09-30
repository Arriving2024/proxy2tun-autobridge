# Architecture / 架构

## 数据路径

```text
Windows applications (public TCP)
             |
     sing-box TUN adapter (unique name for this run)
             |
     selected loopback SOCKS5 / HTTP CONNECT endpoint
             |
     existing proxy client and its dialing core
             |
     original physical network / upstream server
```

Proxy2TUN AutoBridge handles discovery, configuration and process lifecycle. sing-box owns the virtual interface and its routing behavior. The existing client still owns its node selection, authentication to its remote servers, subscriptions and original configuration. AutoBridge does not import those settings.

## 代码边界

| Entry/module | Responsibility |
| --- | --- |
| `Start-Bridge.ps1` | Detect / Generate / Watch entry point; parameter validation |
| `src/Discovery.psm1` | System Proxy and listener discovery, bounded proxy probes, PID/path/parent identity |
| `src/Config.psm1` | sing-box 1.14.2 configuration and conservative traffic policy |
| `src/Lifecycle.psm1` | owned state, sing-box startup/stop, monitoring, logs and cleanup |
| `src/NativeProcess.cs` | Windows process lifecycle protection for the child process |
| `Stop-Bridge.ps1` | scoped graceful or emergency stop |
| `Show-Logs.ps1` | user-visible log viewing |
| `install.ps1` / `uninstall.ps1` | allowlisted installation and ownership-checked removal |

## 发现与验证

The detector reads the current user's Internet Settings proxy configuration, then inspects localhost listeners. Candidate addresses must be loopback; a local service is not considered a proxy merely because its port resembles a common proxy port. PAC scripts are not executed.

Protocol probes try no-auth SOCKS5 and HTTP CONNECT using bounded connection/read timeouts. They request an outbound connection to `1.1.1.1:443` and inspect the resulting TLS handshake framing. This validates a usable proxy tunnel more strongly than checking whether the local TCP port opens, but is **not full TLS certificate validation or a privacy audit**. Networks that block the probe destination can produce false negatives.

Windows TCP listener ownership maps `port → PID → executable path → parent`. A selected proxy must have a resolvable executable identity; ambiguity or inaccessible process information causes a safe refusal instead of guessing. Users can fix the selected endpoint and explicitly add legitimate dialing core paths.

## 防回环

The generated route configuration sends the detected upstream executable path DIRECT. Related client parent executables may also be included when they share the application directory; generic shell/host ancestors are excluded. Exact full paths reduce collisions between unrelated programs with the same filename. `-ExtraDirectProcessPath` adds known helper cores when a client's process structure cannot be inferred.

The original proxy core must reach its remote server outside the TUN capture loop. sing-box also detects the underlying interface for its own direct outbound. These safeguards do not prove compatibility with every process tree, multi-hop chain or independently hosted background core; a changed path or opaque helper can require explicit configuration.

## 流量策略

- Public IPv4 / IPv6 TCP: sent through the selected local proxy; ultimate IPv6 destination support still depends on that upstream.
- Local/private TCP: direct. General LAN UDP remains rejected unless covered by an earlier upstream-core or Windows DNS bypass.
- Windows DNS Client: scoped system `svchost.exe` port 53 direct so an existing proxy can bootstrap its own server hostname. The generated TUN uses `dns_mode: disabled` and `strict_route: false`.
- Other DNS intercepted by TUN: DNS handling via upstream DoH, where supported by the generated route.
- General UDP, including QUIC, and ICMP: rejected by default. No claim of general UDP forwarding is made for HTTP CONNECT or unverified SOCKS relays.
- Exit or upstream loss: restore ordinary networking. There is no kill switch, DNS leak prevention, or guarantee against direct traffic outside the defined capture rules.

## 生命周期与归属

```text
WAITING -- valid upstream --> STARTING -- config accepted --> ACTIVE
   ^                             |                            |
   |                             +------ startup error -------+
   |                                                          |
   +---- stop owned child and clean up <-- repeated loss -------+

User stop / emergency stop / watcher exit -> stop owned instance -> cleanup
```

Each running session has a uniquely named TUN adapter (`p2t-` plus a random suffix), which must not already exist. The wrapper does not reuse a user's existing adapter. State and logs stay in that installation's `runtime/` directory. Identity checks prevent stale PID data from being treated as authority to kill an unrelated process. The child is supervised using Windows process lifecycle facilities; graceful shutdown is preferred, with scoped emergency termination when required.

An already-running sing-box instance prevents this version from starting another TUN. This intentionally avoids silently interrupting the user's existing tunnel. The wrapper does not restore the system from a broad route snapshot or delete all adapters sharing a friendly name; other network changes that happened during a session must remain intact.

## 安装与撤销

Installation creates a fresh per-user folder, copies an explicit source-file allowlist, and writes an ownership manifest with the exact target and file hashes. Existing target directories, network shares and reparse points are rejected. The optional download comes from the pinned official release and must match the hard-coded SHA-256 before executable extraction. ZIP contents are not broadly expanded.

Uninstall verifies the manifest and stops the owned session before removing named tool files. It preserves runtime data by default. `-PurgeData` validates every path inside the runtime tree and refuses links before deleting that data. Unknown files are retained. No Windows service, task, startup entry, persistent execution-policy change, or System Proxy edit is part of v0.1.0 installation.

sing-box can install its embedded Wintun driver as part of first use. A shared Windows driver package is intentionally not removed during uninstall. “Reversible” describes the tool's files, active instance and its network takeover; it does not promise a byte-for-byte restoration of the Windows driver store or event logs.
