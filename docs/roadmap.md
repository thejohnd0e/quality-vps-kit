# Roadmap

## v0.1 — standalone `qvk` (this release line)

Done: `doctor`, `run --profile quick|full` (no load; `full` adds 20 RTT samples, path MTU,
ICMP RTT and a resolver comparison when the tools exist), inventory, VPN-readiness facts,
egress IP with conflict detection, NAT hint, DNS/TCP/TLS/HTTP timing via `curl -w`,
RTT towards Russia-hosted endpoints, clock offset, IP intelligence (RIPEstat, IPinfo,
AbuseIPDB), geo consensus, HTTP reachability of services, per-area verdicts,
`--offline`, `--redact-ip`, `--lang en|ru`, JSON schema 0.1.

Known gaps before calling v0.1 final:

- A run on real VPS hosts (Debian 12/13, Ubuntu 22.04/24.04, amd64/arm64) has not been
  done; tests used fixtures and WSL.
- The AbuseIPDB adapter is verified against fixtures only.
- Default endpoint URLs in `config/endpoints.tsv` need a periodic check.

## v0.2 — controller, probe, throughput, compare

`qvkctl` (Python 3 stdlib + OpenSSH, Windows/Linux/macOS); SSH probe and pull-mode
`qvk-probe` + `qvkctl import`; probe metadata (access type, operator); bounded TCP/UDP
`iperf3` with authorization and a watchdog on the target; filtering methodology
(`bytes_before_stall`, mandatory control pair, SNI comparison); user criteria file;
`qvkctl compare`.

## v0.3 — real VPN tunnels

Separate spec: temporary test profiles for Hysteria2, VLESS+REALITY and AmneziaWG with
explicit consent and guaranteed cleanup.
