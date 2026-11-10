# Changelog

Tool releases follow Semantic Versioning. The JSON report schema has its own version; see [docs/architecture.md, D5](docs/architecture.md#d5-report-schema-and-versioning).

## [Unreleased]

## [0.1.10] - 2026-11-10

### Fixed

- Preserve a successful download measurement when a public iperf server refuses the upload direction; report upload as unavailable rather than failing the entire server result.

## [0.1.9] - 2026-11-10

### Fixed

- Replace stale, unresolvable iperf endpoints with currently published public servers and their required ports.
- Skip servers that are temporarily busy (and timed-out runs) instead of marking these external conditions as tester errors.

## [0.1.8] - 2026-11-10

### Fixed

- Preserve iperf3 stdout when the command exits nonzero and extract the JSON error message, instead of reporting only the exit code.
- Report upload failures as errors rather than successful tests with a zero upload rate.
- Explain iperf3 timeout exit code 124 in the throughput report.

## [0.1.7] - 2026-11-10

### Fixed

- Include ShellCheck source annotations for the new iperf regression test so the release workflow can validate it.
- Parse iperf3 pretty-printed JSON from the end-of-test aggregates, so upload no longer reports an interval rate and successful tests no longer show zero throughput due to multiline JSON.
- Include iperf3 connection diagnostics in human-readable error rows.
- Pin the one-line installer to v0.1.7 so VPS runs receive these fixes.

## [0.1.6] - 2026-11-10

### Fixed

- Parse iperf3 pretty-printed JSON from the end-of-test aggregates, so upload no longer reports an interval rate and successful tests no longer show zero throughput due to multiline JSON.
- Include iperf3 connection diagnostics in human-readable error rows.
- Pin the one-line installer to v0.1.6 so VPS runs receive these fixes.

## [0.1.5] - 2026-11-10

### Added

- Add iperf3-based network throughput test (download + upload) against public iperf3 servers (Scaleway, Hurricane Electric, Clouvider, Worldstream, AS53852 locations worldwide).
- Auto-install iperf3 via package manager (apt/dnf/pacman/apk) if missing and running as root.
- Table output with Server | Download (Mbps) | Upload (Mbps) | Latency (ms) columns, matching speedtest.net style.
- Section runs under `--profile full`, auto-installs iperf3 via package manager if missing (requires root).

## [0.1.4] - 2026-11-10

### Added

- Add iperf3-based network throughput test (download + upload) against public iperf3 servers (Scaleway, Hurricane Electric, Clouvider, Worldstream, AS53852 locations worldwide).
- Auto-install iperf3 via package manager (apt/dnf/pacman/apk) if missing and running as root.
- Table output with Server | Download (Mbps) | Upload (Mbps) | Latency (ms) columns, matching speedtest.net style.
- Section runs under `--profile full`, auto-installs iperf3 via package manager if missing (requires root).

## [0.1.3] - 2026-11-09

### Added

- Add popular censored & infrastructure endpoints (Discord, X, Instagram, Facebook, Telegram API, LinkedIn, GitHub, Google Play, DigitalOcean, Amnezia VPN, Outline VPN, Rutracker, Flibusta, Mailfence, Rezka, Google Video CDN).
- Render HTTP reachability section as a clean, categorized table with human-friendly service names and latency.

## [0.1.2] - 2026-11-09

### Added

- Add the informative `service_geo` section: per-service country restrictions for YouTube Premium, Prime Video and Spotify signup, with a fail-closed `unknown` when the answer carries no decisive marker.

## [0.1.1] - 2026-11-09

### Added

- Add the net.coffee IP-intelligence source and `ip_intelligence.claude_risk` level, reasons, and restricted-region check. The assessment is informational and does not change the report verdicts.

## [0.1.0] - 2026-11-08

### Added

- First release of `doctor`, `run --profile quick|full`, read-only VPN readiness, egress/NAT/geo consensus, HTTP reachability, `--redact-ip`, `--lang en|ru`, and the `install.sh` runner.
