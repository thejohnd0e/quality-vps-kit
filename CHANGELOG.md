# Changelog

Tool releases follow Semantic Versioning. The JSON report schema has its own version; see [docs/architecture.md, D5](docs/architecture.md#d5-report-schema-and-versioning).

## [Unreleased]

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
