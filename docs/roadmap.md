# Roadmap

## v0.1 — standalone `qvk` (this release line)

Done: `doctor`, `run --profile quick|full` (no load; `full` adds 20 RTT samples, path MTU,
ICMP RTT and a resolver comparison when the tools exist), inventory, VPN-readiness facts,
egress IP with conflict detection, NAT hint, DNS/TCP/TLS/HTTP timing via `curl -w`,
RTT towards Russia-hosted endpoints, clock offset, IP intelligence (RIPEstat, IPinfo,
AbuseIPDB), geo consensus, HTTP reachability of services, per-area verdicts,
`--offline`, `--redact-ip`, `--lang en`, JSON schema 0.1.

Known gaps before calling v0.1 final:

- Real runs so far: a Debian 13 amd64 VirtualBox lab VM as real root (`--profile full`,
  exit 0, valid JSON, no leftovers) and Debian 12 on WSL. Not yet run on hosted VPSes
  (Debian 12, Ubuntu 22.04/24.04, arm64). The lab VM had no `tracepath`, so path MTU
  was only exercised through fixtures.
- ICMP replies were absent on both lab networks, so the ICMP RTT success path has only
  been verified with fixtures.
- The AbuseIPDB adapter is verified against fixtures only.
- Default endpoint URLs in `config/endpoints.tsv` need a periodic check.

## v0.2 — controller, probe, traffic-capped throughput, compare

`qvkctl` (Python 3 stdlib + OpenSSH, Windows/Linux/macOS); SSH probe and pull-mode
`qvk-probe` + `qvkctl import`; probe metadata (access type, operator); bounded TCP/UDP
traffic-capped measurements with authorization and a watchdog on the target; filtering methodology
(`bytes_before_stall`, mandatory control pair, SNI comparison); user criteria file;
`qvkctl compare`.

## v0.3 — real VPN tunnels

Separate spec: temporary test profiles for Hysteria2, VLESS+REALITY and AmneziaWG with
explicit consent and guaranteed cleanup.
