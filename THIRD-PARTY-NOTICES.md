# Third-party dependencies and non-affiliation

Proxy2TUN AutoBridge's original wrapper scripts and documentation are licensed under the [MIT License](LICENSE). Third-party software remains under its own license; the MIT license does not relicense those components.

## sing-box

- Author/project: [SagerNet/sing-box](https://github.com/SagerNet/sing-box).
- Tested configuration target: [v1.14.2](https://github.com/SagerNet/sing-box/releases/tag/v1.14.2), Windows amd64.
- Upstream [LICENSE](https://github.com/SagerNet/sing-box/blob/v1.14.2/LICENSE) specifies GNU GPL version 3 or later and an additional naming/association provision. Read the upstream license before redistributing or modifying that software.
- The source repository and this project's release archive do **not** contain sing-box binaries. `install.ps1` can fetch the official release archive after the user chooses to install; alternatively the user supplies a local `sing-box.exe` with `-SingBoxPath`.
- Pinned asset: `sing-box-1.14.2-windows-amd64.zip`.
- SHA-256: `c2d8bfff918755808781dfdeeb8581b6c91eb3a243d9a7b55483cfc0c0684d32`.
- Hash source: the `digest` field of [GitHub's official release metadata](https://api.github.com/repos/SagerNet/sing-box/releases/tags/v1.14.2), checked on 2026-09-30. The installer uses the hard-coded hash above; it does not trust a freshly downloaded checksum as its only check.

The pinned release embeds its Windows TUN dependency. Its [go.mod](https://github.com/SagerNet/sing-box/blob/v1.14.2/go.mod) references sing-tun commit `ddaa4ca25e3b`; that commit [embeds the amd64 Wintun DLL](https://github.com/SagerNet/sing-tun/blob/ddaa4ca25e3b/internal/wintun/dll_windows_amd64.go) and [identifies version 0.14.1](https://github.com/SagerNet/sing-tun/blob/ddaa4ca25e3b/internal/wintun/README.md). This wrapper does not download or distribute a separate Wintun DLL. Refer to [Wintun](https://www.wintun.net/) and the upstream dependency notices for its licensing and driver behavior.

## Misty and other upstream clients

Misty is the first user-reported successful **manual** adaptation of a local proxy with sing-box TUN that motivated this project. Misty itself, subscriptions, server addresses, account credentials, and user node configurations are neither required in this repository nor redistributed by it.

Proxy2TUN AutoBridge is an independent community project. It is not an official product, plugin, or endorsed integration of Misty, SagerNet, sing-box, WireGuard, Wintun, Microsoft, or other upstream clients. The names describe compatibility or dependencies only.
