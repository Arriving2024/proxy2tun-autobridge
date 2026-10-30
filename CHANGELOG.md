# Changelog

## v0.2.1 — 2026-10-31 — experimental patch prerelease

Fix wrapper-level false negatives found while deploying v0.2.0 on a second Windows computer and diagnosing the original local installation. Existing Detect / Generate / Watch commands and recovery/ownership boundaries remain available.

### Fixed

- Pass an explicit proxy selection into discovery before probing. A specified SOCKS5 / HTTP endpoint no longer waits for unrelated listeners and protocols to be scanned.
- Verify the proxy owner through the server side of a live connection, instead of trusting duplicate, PID-zero or incomplete Windows Listen snapshots. Revalidation checks the process path and start identity of the connected owner.
- Recognize complete IPv4/IPv6 CIDR unions after the configured loopback exclusions split the routes. Missing public coverage, another adapter or an unverified adapter GUID still fails.
- Accept RFC 2308 NODATA only with a complete authority IN/SOA covering the exact question or an ancestor zone. Keep transaction, question, class, error-code, truncation and length checks; malformed or unrelated negative responses still fail.
- Include VERSION and the field-debug guide in new installations; use the existing PowerShell-safe native probe wrapper for diagnosis instead of fragile empty-argument curl commands.

### Evidence and scope

- Added regression cases for real NODATA wire data from a self-generated query, endpoint/owner anomalies, filtered discovery and excluded-loopback route coverage.
- Sanitized field notes distinguish the friend's visible command output, earlier assistant recaps, the local legacy launcher's live checks, and the generic wrapper's remaining administrator acceptance. HTTP 401/403 proves transport, not a successful authenticated application operation.
- No change to upstream credentials, client configuration, default persistence, recovery limits, public UDP support or the existing manual C:\Misty-TUN configuration. One-click client-launch/task prototypes from earlier discussions are not represented as tested features of this patch.

## v0.2.0 — 2026-10-24 — experimental prerelease

Continues the existing v0.1.0 repository and release. This minor release keeps the Detect / Generate / Watch entry points, scoped stop/uninstall, local unauthenticated SOCKS5 / HTTP CONNECT support and foreground defaults. The default DNS behavior intentionally changes to address the observed forwarding failure.

### Fixed

- Enable sing-box 1.14.x TUN `dns_mode: hijack` and send Cloudflare DoH through the detected `upstream` outbound, using an IP endpoint with explicit TLS SNI to avoid a resolver bootstrap dependency.
- Distinguish DNS, TLS/transport, ordinary HTTP responses and Cloudflare challenge HTTP 403. A valid challenge response is evidence of HTTPS reachability; it does not establish application access or authenticated service health.
- Require ASCII or UTF-8 BOM PowerShell sources to avoid Windows PowerShell 5.1 decoding failures. Add an owned-instance `Stop-Misty-TUN.ps1` compatibility entry point and an explicit-output offline legacy encoding repair utility.
- Read UTF-8 state and installation manifests explicitly so non-ASCII installation paths remain usable across PowerShell versions.

### Added

- Owned adapter/route coverage checks, fresh nonce DNS requests directly to TUN, separate system DNS and certificate-validated HTTPS checks; network-egress change detection and debounce; checks for a live core whose forwarding path has failed.
- Failure thresholds, capped exponential backoff, a finite recovery budget and a latched `RecoveryPaused` state. A sustained healthy interval is required to reset the budget.
- Validated atomic configuration replacement, a previous-configuration backup and rollback after failed startup verification.
- Unit and simulated integration coverage for DNS policy, configuration rollback, response classification, recovery budgeting, interface change behavior and PowerShell encodings.
- Source-only release builder with Git-tracked source allowlist, encoding validation, archive read-back hashing, a file manifest and SHA-256 checksums.
- User-supplied Windows 11 recovery evidence and a separate administrator acceptance procedure in `docs/validation.md`.

### Preserved / limitations

- No default boot persistence, no broad process termination, no import of subscriptions or node credentials, no overwrite of an existing manual TUN configuration, and ownership-checked uninstall/emergency stop.
- General UDP / QUIC / ICMP remains unsupported; there is no kill switch. Existing CLI commands remain usable, while DNS takeover and health-based recovery are new operational behavior.
- Automated tests do not create a real TUN. The new wrapper still requires administrator acceptance on actual network changes and remote-control use before a stable-release claim.

## v0.1.0 — existing prerelease

Existing repository tag: `35f73bb42ce819e724a9758d98f93142d29e10bf`.

- Initial local-proxy discovery, SOCKS5 / HTTP CONNECT probing, process identity and exact-path bypass generation.
- Foreground TUN lifecycle, scoped stop/emergency stop, logs, ownership manifests, fresh-directory installation and reversible uninstall.
- Pinned official sing-box 1.14.2 dependency, source-only release and documented manual Misty adaptation.
- Original DNS policy allowed Windows DNS Client direct bootstrap and used `dns_mode: disabled`; v0.2.0 changes the default to hijacking and makes system DNS bootstrap an explicit compatibility option.
