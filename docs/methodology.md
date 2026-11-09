# Methodology

What every number in a `qvk` report means, what it does not mean, and why a
standalone run cannot diagnose blocking from Russia.

## 1. What a standalone run can and cannot say

`qvk` runs **on the VPS**. Everything it measures is seen **from the VPS**:
the VPS's own hardware, the VPS's route to the internet, and how services treat
the VPS's IP address.

It cannot measure the path **from a client network to the VPS**, which is the path
that matters for a VPN. Reachability from Russia depends on the client's operator,
access type (fixed or mobile), time of day and the exact protocol and port. A
measurement from a foreign VPS says nothing about it, and even one measurement
from one Russian operator describes only that operator's route.

Therefore in v0.1:

- `client_reachability` is always `indeterminate` with `reason_code: no_probe`;
- no output of `qvk` ever states "blocked by RKN" or "bypass works";
- the RTT towards Russia-hosted endpoints is labelled *route from the VPS, not
  reachability from Russia*;
- client-side measurements need a probe in the client network (v0.2).

## 2. Result vocabulary

Four independent fields; never merged:

| Field | Values | Meaning |
|---|---|---|
| `status` | `pass` `warn` `fail` `unknown` `skipped` `error` | outcome of one test. `error` = the tester failed (e.g. curl crashed), not proof of a network problem |
| `diagnosis` | `none` `suspected_filtering` `suspected_throttling` `unreachable` `service_missing` `inconclusive` / `null` | only for filtering/degradation tests (v0.2). Requires repeated comparable measurements and a control pair, otherwise `inconclusive` |
| `reason_code` | fixed list in `schema/report.schema.json` | machine-readable cause of a non-pass |
| `http_outcome` | `reachable` `network_error` `tls_error` `http_denied` `rate_limited` `unknown` | for HTTP tests only |

Unknown or untested values are JSON `null`, never `0`, `100` or `"N/A"`.

## 3. Indicators

### Inventory (`system`) — facts, no verdict

- **steal**: share of CPU time the hypervisor took, from two `/proc/stat` samples
  2 s apart. One sample is a snapshot, not a quality verdict; do not judge a host by it.
- **virtualization**: `systemd-detect-virt`, else `/proc/user_beancounters`,
  `/run/systemd/container`, `/.dockerenv`, else the CPU `hypervisor` flag (`vm`).
- **memory / disk / load**: `/proc/meminfo`, `df -Pk /`, `/proc/loadavg`.
- **interface MTU**: from `ip link`. It is not the path MTU; the path MTU is measured
  separately by `tracepath` in profile `full` (see below).
- **addresses**: classified `public`, `private`, `cgnat` (100.64.0.0/10), `link_local`,
  `loopback`; IPv6 `global` or `ula`.
- **firewall**: only presence and counts (nftables tables, iptables rules, ufw/firewalld
  active). Rule contents are never copied.

### VPN readiness (`vpn_readiness`) — tests with a status

| Test | pass | warn | Rationale |
|---|---|---|---|
| `cpu_crypto_accel` | `aes` flag (x86 `aes`, arm64 `aes`) | no flag | no AES acceleration makes TLS/QUIC CPU-bound; prefer ChaCha20-Poly1305 |
| `tun_device` | `/dev/net/tun` present | absent | Xray, Hysteria and in-kernel WireGuard do not need it; userspace amneziawg-go / wireguard-go do. Not a verdict criterion |
| `tcp_bbr_available` | BBR listed, built in or loadable | absent | informational; BBR is a choice, not a requirement |
| `udp_buffer_size` | `rmem_max` and `wmem_max` ≥ 16 MiB | lower | small buffers limit QUIC/Hysteria. qvk prints the `sysctl` command and never runs it |
| `listening_ports` | 80/tcp, 443/tcp, 443/udp, 51820/udp free | any in use | an installed kit is a normal reason; the process name is shown when `ss` is available |

### Network (measured from the VPS)

- **Egress IPv4/IPv6**: several echo services must agree. Disagreement is `warn` with
  `reason_code: conflict` and `target.ip` stays `null`. An echo service shows the
  address used for outbound traffic. It does **not** prove that the VPS accepts
  inbound connections.
- **NAT**: egress IP present on the interface → `none`; only a private address →
  `one_to_one_suspected`; only 100.64.0.0/10 → `cgnat_suspected`. With NAT, inbound
  reachability depends on the provider's rules.
- **HTTPS timing**: `curl -w` timings. `tcp_connect_ms = connect − namelookup`,
  `tls_ms = appconnect − connect`, `ttfb_ms = starttransfer − appconnect`.
- **DNS**: name-lookup time of every request made by the run; failures are counted
  separately from other network errors.
- **RTT towards Russia-hosted endpoints**: the TCP handshake time from the VPS
  (`time_connect − time_namelookup`), 3 samples in `quick`, 20 in `full`. It is an
  indirect indicator of the VPS's route towards Russia. **Not** reachability from a
  Russian client network. A handshake under 1 ms is `warn` / `middlebox_suspected`:
  a remote host cannot answer that fast, so something close to the machine
  terminates TCP (a transparent proxy or middlebox) and the value does not describe
  the route.
- **Percentiles**: nearest-rank. `p50` = value at rank `ceil(0.50·n)`, `p95` = rank
  `ceil(0.95·n)`, and `p95` is reported **only for n ≥ 20**, otherwise `null`.
- **Clock offset**: median over the `Date` headers of at least 3 distinct hosts,
  corrected for request latency; resolution is 1 s. `|offset| > 30 s` is `warn`
  because TLS and REALITY handshakes can fail on a wrong clock.

### Extra diagnostics (profile `full`, optional tools)

- **Path MTU** (`tracepath -n -m 12` towards the first baseline host): the last `pmtu`
  value. Below the interface MTU → `warn` with advice to size the VPN tunnel MTU
  accordingly. The probe is UDP; a value equal to the interface MTU is the common case.
- **ICMP RTT** (`ping -c 5`) towards the Russia-hosted hosts: min/avg/max and packet loss
  over five probes. No reply is `unknown` / `icmp_no_reply`, never `fail`: ICMP is often
  filtered and says nothing about TCP or UDP. Five probes are not a stable loss figure.
- **Resolver comparison** (`dig +short`): the system resolver versus 1.1.1.1 and 8.8.8.8
  for the baseline names. Only the *presence* of an answer is compared (CDN names
  legitimately differ per resolver). A name the system resolver cannot resolve while
  public resolvers can is `warn` / `dns_failure`: a resolver problem or DNS interference,
  not a verdict on routes. Querying public resolvers discloses the baseline host names
  to them.

Missing tools give `skipped` / `tool_missing`; `--offline` gives `skipped` /
`offline_mode`. None of these tests changes a verdict.

### IP intelligence

Each source is a separate record with its own status and timestamp.

- **RIPEstat** (`prefix-overview`, no key): announced prefix, origin ASN and holder.
- **IPinfo** (`ipinfo.io/<ip>/json`, optional `IPINFO_TOKEN`): country, organisation,
  reverse DNS. The `hosting` flag exists only on paid plans; without it the field is
  `null`, never `false`.
- **AbuseIPDB** (optional `ABUSEIPDB_API_KEY`): abuse confidence score and report
  count. The adapter follows the documented v2 `check` endpoint but has **not** been
  verified against the live service in this repository's tests (no key was available);
  it is covered by fixtures only.
- **net.coffee** (`ip.net.coffee/api/iprisk/<ip>`, no key): one provider's trust score
  plus `vpn` / `proxy` / `tor` / `crawler` / `abuser` flags. The endpoint is
  undocumented, so it is also covered by fixtures only; its failure only degrades the
  report.

Reading the results:

- `hosting=true` is normal for a VPS and is never a failure.
- A score from one provider is not an objective probability of being blocked anywhere.
- No abuse reports does not mean the address is "clean".
- A missing key, HTTP 429 or an outage gives `skipped` / `unknown` for that source and
  never affects the verdict or the exit code.
- **Geo consensus** compares the country each independent source reports (IPinfo,
  AbuseIPDB, the `loc=` line of Cloudflare `cdn-cgi/trace` pages). It shows how
  different services *see* the address. `geo_conflict` is `null` with fewer than two
  sources. It does not say whether a given service works.

### Claude risk (`ip_intelligence.claude_risk`)

How much risk this VPS's own egress IP carries for working through Claude. It is a
judgement about the address, not about an account, and not a verdict area: the
`ip_intelligence` section stays informational in v0.1.

Rules. Every matching factor is listed in `reasons`; the level is the worst bucket:

| Level | Factors |
|---|---|
| `high` | country in the restricted list; Tor exit; known crawler; trust score < 50 |
| `medium` | abuse history; trust score 50-79; VPN or proxy exit; hosting (datacenter) IP; residential property unknown |
| `low` | trust score >= 80, residential IP, none of the factors above |
| `unknown` | no data, incomplete risk flags for an otherwise clean-looking address, or the risk service did not answer (a country reported by another source still counts) |

Restricted list (checked 2026-11-09 against the net.coffee page script, which forces
the displayed score to 0 for these): CN, HK, MO, RU, KP, IR, SY, CU, BY, VE. Recorded
with its date and source because it can change; what Claude itself enforces is not
observable from here.

Reading the result:

- A plain VPS is `medium` at best, because its address is a hosting address. That is
  the honest answer, not a defect.
- `trust_score` is one provider's figure; the level is our rule applied to it, not a
  probability that Claude will act. The human report labels it "Claude trust score"
  because it is the score behind the Claude risk line; the JSON keeps it under the
  `netcoffee` source as `trust_score`.
- The region factor does not depend on the third-party service: with IPinfo or the
  geo consensus reporting a restricted country, the level is `high` even when
  net.coffee is unreachable.
- `checked_ip` is the address that was looked up and is redacted like every other
  address with `--redact-ip`.
- What Claude itself decides (captcha, refusal, account action) is unknown to `qvk`.

### HTTP reachability of services

One gentle GET per endpoint (`ai`, `media`, `ru_hosted` categories).

- 2xx/3xx, 401 (authentication required), 404, 405 → `reachable`: the service answered.
- **403 → `http_denied`, 429 → `rate_limited`**: decisions of the service (geo policy,
  anti-bot, rate limit). They are **not** evidence of network filtering. In
  particular, some Russia-hosted services reject foreign IPs by their own policy.
- 5xx → `unknown`. Timeouts, DNS, TCP and TLS failures → `network_error`/`tls_error`.
- Captchas are never bypassed. A successful GET proves nothing about an account,
  streaming or payments.

### Service geo restrictions (`service_geo`)

For a VPS considered as a VPN exit: does a service restrict this exit **because of its
country**? One gentle GET per service, browser User-Agent (those pages serve a stub to
a tool User-Agent), no redirects followed, no captcha and no anti-bot signals here.

| Service | `country_restricted` when | `none` (available) when |
|---|---|---|
| YouTube Premium | the page says the product is "not available in your country" | the product name and a premium product token (`ypc`) both appear |
| Prime Video | the answer redirects to `/servicerestricted` | the answer redirects to the service's own `/offers/` path |
| Spotify signup | `is_country_launched` is exactly `false` | `is_country_launched` is exactly `true` |

Rules:

- **Fail closed.** `none` requires positive evidence. When the answer carries no
  decisive marker the row is `unknown` with `insufficient_data` — never "available".
  A wording change therefore degrades the row; it cannot invent a restriction. A
  malformed value (for example `trueish` instead of `true`) is not a decision, and a
  redirect to an unverified path is `unknown`, not availability.
- A body that reaches the 1 MB download cap counts as truncated, whichever way
  `curl` reports it, and yields `unknown`.
- `country_restricted` is a policy of the service for the country of this address.
  It is not network filtering, not a verdict, and not proof that a VPN will or will not
  work for a particular account.
- A 3xx is not automatically a restriction; redirects are not followed. HTTP 403/429
  mean `unknown` with `http_denied`/`rate_limited` — the service's decision, not a
  country fact. A timeout is `fail`, like every other network measurement.
- `country` is what the service itself reported, or `null` when it reported none. Two
  services may disagree about the same address; that is their data, not an error.
- `--offline` sends nothing and the row is `skipped`/`offline_mode`.
- Captchas, anti-bot pages and catalogue comparisons are out of scope: they describe
  the address or the region's catalogue, not a country restriction.

## 4. `target_self_check` (v0.1 built-in preset)

| Criterion | Violation (`fail`) | Unknown |
|---|---|---|
| RAM ≥ 512 MB | below | not readable |
| public egress IPv4 determined | no echo service answered | conflict, error, offline |
| DNS works | every lookup failed | not checked |
| ≥ 1 baseline HTTPS endpoint answers | all failed (network) | not run / only tester errors |
| \|clock offset\| ≤ 30 s | above | fewer than 3 samples |

Any verified violation → `unsuitable`. Otherwise any unknown → `indeterminate` with
`missing_evidence`. All criteria met → `suitable`. `/dev/net/tun`, IP reputation, NAT
and RTT are not criteria. The verdict says "this VPS looks usable *as a server*", not
that clients can reach it.
