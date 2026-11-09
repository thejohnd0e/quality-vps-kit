# Security and data handling

## Privileges

`qvk run` is meant to run as **root** on a fresh VPS right after `ssh root@host`.
Root is needed for complete reads (`/proc`, firewall state, socket owners), not to
change anything. `qvk` does not call `sudo` and creates no service user.
`doctor`, `version` and `--help` work unprivileged.

## Read-only by design

`qvk` never installs packages and never changes the firewall, sysctl, routes, DNS,
systemd units or VPN configuration. It opens no listening sockets and starts no
background processes. Local commands it may run (all read-only, each with a timeout):

`ip -o route|link|addr show`, `df -Pk /`, `tracepath`, `ping`, `dig` (profile `full`), `ss -H -ltnup`, `systemd-detect-virt`,
`timedatectl show`, `nft list ruleset`, `iptables -V|-S`, `ufw status`,
`firewall-cmd --state`, `nproc`, `uname`, `curl`.

Tests assert that only these command lines are executed. Recommended `sysctl` values
are printed as text and never applied.

## What leaves the machine

Without `--offline`, `qvk` makes HTTPS requests, each with a `quality-vps-kit/<version>`
User-Agent, no cookies and no redirects followed:

| Destination | What it learns |
|---|---|
| echo services (Cloudflare trace, ipify, AWS checkip) | the VPS's public IP (that is their purpose) |
| RIPEstat, IPinfo, AbuseIPDB | the VPS's public IP |
| `ip.net.coffee` (`/api/iprisk`) | the VPS's public IP |
| public DNS resolvers 1.1.1.1 and 8.8.8.8 (profile `full`, `dig`) | the VPS's public IP and the baseline host names |
| `tracepath`/`ping` targets (baseline and Russia-hosted hosts, profile `full`) | the VPS's public IP |
| baseline, `rtt_ru`, `ai`, `media`, `ru_hosted` endpoints from `config/endpoints.tsv` | the VPS's public IP and that a request was made to that host |

Nothing from the report is uploaded anywhere; the report is written locally.
`--offline` makes **no** external request. Use `--endpoints FILE` to run with your own
list. Third-party services have their own terms and rate limits; the defaults are
chosen to be gentle (small documents, one request per endpoint, at most one retry for
the intelligence APIs). `ip.net.coffee` is an undocumented endpoint of a third-party
site: a failure there only removes one source and one risk factor from the report.

## Secrets

Optional keys come **only from the environment**: `IPINFO_TOKEN`,
`ABUSEIPDB_API_KEY`. They are never accepted as command-line arguments, passed to
`curl` through a `0600` header file (so they do not appear in `ps` output), and never
written to reports, logs or progress messages. Tests assert this.

SSH keys, VPN keys, tokens, UUIDs and URIs are never read or reported.

## Reports and redaction

- Reports and temporary files are created with `umask 077`; `--output` files are `0600`.
- A report contains the VPS's IP addresses. Publish it with `--redact-ip`: every address
  learned by the run becomes a stable label (`<ip-1>`), the announced prefix and the
  reverse-DNS name are removed, ASN, holder and country stay. Matching respects
  address boundaries. Redaction covers addresses the run knows about; review a report
  before publishing it anyway, because host names and free text can carry identifying
  details.
- Firewall rule contents are never copied into the report.

## Input handling

Endpoint lists are validated line by line (known category, safe name, `https://` URL
without shell metacharacters) before use; nothing user-provided is ever evaluated by a
shell. `/etc/os-release` is parsed as data, never sourced. Values from remote services
are untrusted data: they are length-limited, pattern-checked and JSON-escaped.

## The one-line installer

`install.sh` is a short bootstrap meant for `curl ... | bash`. It downloads the pinned
release tarball and `SHA256SUMS` over HTTPS from GitHub, verifies the checksum, runs `qvk`
from a temporary directory and deletes it. The checksum is served from the same origin as
the tarball, so it detects corruption, not a compromised repository: if you need more
assurance, read `install.sh`, or use a git checkout (inspect the code, then run it) or the
release tarball.

## Reporting vulnerabilities

Open a private security advisory on the repository or contact the maintainer.
