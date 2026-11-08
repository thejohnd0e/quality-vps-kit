# quality-vps-kit

Read-only evaluation of a fresh VPS **before** you turn it into a VPN/proxy server.
Log in as root, run one command, get a readable report and a machine-readable JSON.

> Русская версия: [README.ru.md](README.ru.md)

`qvk` answers: what is this server (CPU, memory, virtualization, MTU, NAT), is it ready
for a VPN (AES, BBR, UDP buffers, busy ports, `/dev/net/tun`), does its own internet
access work (egress IP, DNS, HTTPS, clock), how does the world see its IP (ASN, prefix,
country consensus) and how do popular services react to it.

It is deliberately **not** a monitoring platform: no daemon, no database, no panel,
nothing is installed or changed.

## Honest limits (read this first)

- **It measures from the VPS.** It cannot tell whether the VPS is reachable **from your
  client network**, e.g. from Russia. `client_reachability` is always `indeterminate`
  in v0.1. A client-side probe is planned (v0.2).
- It never says "blocked by RKN" or "bypass works". HTTP 403/429 from a service is a
  decision of that service, not proof of network filtering.
- IP-reputation scores come from single providers and are not a probability of being
  blocked anywhere. `hosting=true` for a VPS is normal.
- Unknown stays `null`/`unknown`/`skipped`; there is no score and no single "grade".

Details: [docs/methodology.md](docs/methodology.md).

## Requirements

Debian 12/13 or Ubuntu 22.04/24.04, amd64 or arm64, **root**. Needed tools: `bash`
(≥ 4.4), coreutils, `curl`, `iproute2` (present on minimal images). Everything else
(`jq`, `ping`, `ss`, `mtr`, `iperf3`, `dig`, `git`, …) is optional; missing tools make
the related check `skipped`. `qvk` never installs packages.

## Install and run

From a release tarball (no `git` needed). Copy the tarball and `SHA256SUMS` to the VPS,
then:

```bash
sha256sum -c SHA256SUMS
tar xzf quality-vps-kit-*.tar.gz
cd quality-vps-kit-*/
./qvk doctor
./qvk run
```

Or from a checkout: `git clone <repo-url> && cd quality-vps-kit && ./qvk run`.

Do not pipe a network script into a shell. Build a tarball with `scripts/release.sh`.

## Usage

```text
qvk doctor                         platform, privileges, tools (root not required)
qvk run [options]                  run the checks (root required)
qvk version | qvk --help
```

| Option | Meaning |
|---|---|
| `--profile quick\|full` | `full` adds 20 RTT samples (so p95 exists), path MTU, ICMP RTT and a resolver comparison (needs `tracepath`, `ping`, `dig`). No load tests in v0.1 |
| `--format human\|json` | default: human; `json` when `--output` is given |
| `--output FILE` | write the report to `FILE` (mode 0600) |
| `--offline` | no external request at all; network checks become `skipped` |
| `--redact-ip` | replace IP addresses (and prefix, reverse DNS) before you share a report |
| `--lang en\|ru` | language of the human report; JSON is always English |
| `--endpoints FILE` | your own endpoint list (default `config/endpoints.tsv`) |

`--allow-load` and `--max-traffic-mb` exist for v0.2 and currently exit with code 1.

Examples:

```bash
./qvk run                                        # readable report
./qvk run --format json --output report.json --redact-ip
./qvk run --profile full --lang ru
./qvk run --offline                              # local facts only
```

Exit codes: `0` report produced (any verdict) · `1` usage error · `2` not root or
unsupported platform · `3` internal error · `130` interrupted. Read the verdict from the
JSON (`summary.verdicts`), not from the exit code.

Optional keys, **environment only**: `IPINFO_TOKEN`, `ABUSEIPDB_API_KEY`.

## Example report (abridged)

```text
System
  OS                 Debian GNU/Linux 12 (bookworm)
  Virtualization     kvm
  CPU                AMD EPYC 7543 32-Core Processor, 2 vCPU
  IPv4               203.0.113.10/24 (public)

VPN readiness
  PASS     CPU AES acceleration   present
  WARN     UDP buffers            rmem_max 208 KB, wmem_max 208 KB: low for QUIC/Hysteria.
                                  Not applied by qvk: sysctl -w net.core.rmem_max=16777216 ...
  WARN     VPN ports              in use: 443/tcp (xray)

Network (measured from this VPS)
  PASS     Egress IPv4            203.0.113.10 (3 of 3 sources agree); NAT: none
  PASS     RTT to RU: yandex      ya.ru: p50 41.0 ms ...; route from the VPS, not from Russia

Verdicts
  Target self-check                suitable
  Client reachability              indeterminate
    - standalone run cannot test reachability from a client network ...
```

The JSON contract is [schema/report.schema.json](schema/report.schema.json); a full
example is in [schema/examples/](schema/examples/). `schema_version` is `0.x` until 1.0,
and a minor bump may change it incompatibly.

## What it sends and where

Without `--offline` it contacts echo services, RIPEstat, IPinfo, optionally AbuseIPDB,
and the endpoints in `config/endpoints.tsv`; all of them learn the VPS's public IP.
See [docs/security.md](docs/security.md).

## Not implemented yet

Load/throughput tests (`--allow-load`), traceroute/`mtr` reports, the
controller `qvkctl`, client-side probes and `compare` (v0.2), real VPN tunnel tests
(v0.3), Markdown reports, a user-defined criteria file. Planned work:
[docs/roadmap.md](docs/roadmap.md).

## Tests

`bash tests/run.sh` runs syntax checks, ShellCheck (if installed), the schema check and
unit tests with fixtures. It never touches the network and does not need root. The
tests have been run on Git Bash (Windows) and Debian 12 (WSL), and `qvk run --profile full`
was run as real root on a Debian 13 lab VM. **Runs on hosted VPSes are a separate manual
step** and are not covered by CI.

## License

MIT (provisional).
