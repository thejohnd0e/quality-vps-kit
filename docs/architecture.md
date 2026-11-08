# Architecture

Status: v0.1 skeleton. Authoritative requirements: TZ v1.2 (local spec file).
This document records design decisions and the contracts that code must keep.

## Components

| Component | Where it runs | Language | Phase |
|---|---|---|---|
| `qvk` | target VPS, as root | Bash ≥ 4.4 | v0.1 |
| `qvk-probe` | client network (manual, pull mode) | Bash or Python 3 stdlib (to be decided) | v0.2 |
| `qvkctl` | operator machine (Windows/Linux/macOS) | Python 3 stdlib + OpenSSH CLI | v0.2 |

v0.1 delivers only `qvk`. Nothing in `qvk` depends on the controller.

## Repository layout

```text
qvk                     entry point: argument parsing, commands doctor/run/version/help
lib/common.sh           environment (LC_ALL=C, umask 077), exit codes, temp dir, traps, terminal output
lib/json.sh             JSON emitter in pure Bash
lib/i18n.sh             message lookup; catalogs in lib/i18n/{en,ru}.sh
lib/platform.sh         os-release parsing, arch, root check, tool detection
lib/inventory.sh        read-only system facts -> QVK_SYS (QVK-01)
lib/readiness.sh        VPN-readiness checks over QVK_SYS -> tests[] (QVK-01a)
lib/tests.sh            qvk_add_test: test records for JSON and human output
lib/redact.sh           --redact-ip: registered addresses -> <ip-N>
lib/report.sh           report assembly (JSON) and human rendering
schema/                 JSON Schema of the report + reference example(s)
tests/run.sh            all offline checks (syntax, ShellCheck, schema, unit tests)
tests/tools/            stdlib-only helpers (schema validator)
tests/fixtures/         os-release files, invalid reports, later: captured command output
```

Network modules (`network.sh`, `ip-intel.sh`) are added in later slices. Every
module appends test objects through `qvk_add_test` and never prints to stdout.

## Decisions

### D1. Root-first, read-only

`qvk run` requires root and exits 2 otherwise. `doctor`, `version` and `help` run
unprivileged; `doctor` warns that `run` will refuse. Root never implies permission
to change the host: no package installs, no firewall/sysctl/route/DNS/systemd changes.

### D2. Minimal required tools

Required: `bash`, coreutils (`timeout`, `mktemp`, `date`), `awk`, `sed`, `grep`,
`curl`, `iproute2`. Everything else is optional and yields `skipped` with
`reason_code: tool_missing`. Rationale: minimal hoster images usually lack `jq`,
`git`, `dig`, `ping`, and qvk must not install packages.

`curl -w` is the primary measurement primitive (DNS, TCP connect, TLS, TTFB, total
in one call).

### D3. JSON in pure Bash

`lib/json.sh` builds JSON from fragments (`json_obj`, `json_arr`, `json_str`,
`json_num`, `json_bool`). Rules:

- every string goes through `json_escape`: `\`, `"`, `\n`, `\r`, `\t`, `\b`, `\f`
  and remaining control bytes as `\u00XX`;
- non-ASCII strings pass through `iconv -c` (glibc, always present on Debian/Ubuntu)
  so invalid UTF-8 never reaches the report; without iconv non-ASCII bytes become `?`;
- `json_num` emits only valid JSON numbers, otherwise `null` (never `"N/A"`);
- output is compact single-line JSON plus a trailing newline; `jq` is optional.

The escaper is covered by round-trip tests through Python's JSON parser.

### D4. Exit codes

| Code | Meaning |
|---|---|
| 0 | report produced, regardless of verdict (doctor: platform ready) |
| 1 | usage error, or an option not implemented in this version (`--allow-load`) |
| 2 | not root for `run`, unsupported platform, missing required tool |
| 3 | internal error |
| 130 / 143 | interrupted by SIGINT / SIGTERM after cleanup |

Usage errors are checked before environment errors. Verdicts are read from JSON,
never from the exit code.

### D5. Report schema and versioning

`schema/report.schema.json` (JSON Schema 2020-12) is the contract;
`schema/examples/*.json` must validate in CI.

- `schema_version` is `0.x` until 1.0; a minor bump may break compatibility.
  From 1.0: semver (breaking change = major).
- Unknown values are `null`. Units are key suffixes: `_ms`, `_s`, `_mbps`, `_bytes`,
  `_pct`, `_mb`. `metrics` holds numbers/null only; non-numeric facts go to `details`.
- `status`, `diagnosis`, `reason_code` and `http_outcome` are separate fields with
  fixed enums. `N/A` exists only in human-readable tables.
- Verdicts are per area (`summary.verdicts.target_self_check`,
  `summary.verdicts.client_reachability`); there is no single overall score.
  In v0.1 `client_reachability` is always `indeterminate` / `no_probe`.

CI validates with `tests/tools/validate_report.py`, a stdlib-only validator for
the keyword subset the schema uses, so CI never downloads packages. Adding a new
keyword to the schema requires extending the validator (it fails loudly on
unknown keywords).

### D6. Output and language

- Report goes to stdout or `--output FILE`; diagnostics and progress go to stderr.
- `--output` defaults the format to JSON; files are written atomically with mode 0600.
- Colors only on a TTY, honoring `NO_COLOR` and `TERM=dumb`.
- Human output: English by default, Russian with `--lang ru` or a `ru*` locale.
  All human strings live in `lib/i18n/{en,ru}.sh`; missing Russian keys fall back
  to English. JSON keys and values are always English (`msg_en`).
- `LC_ALL=C` is forced for parsing, so display width is computed by `qvk_strwidth`
  (UTF-8 aware) instead of `printf %-Ns`.

### D7. Duration

No global time budget (TZ v1.2, change 10). Termination is guaranteed by a timeout
on every network operation and bounded retries. Each test records `duration_ms`
and `timeout_ms`.

### D8. Test hooks

Environment variables used only by tests, never needed in production:

| Variable | Replaces |
|---|---|
| `QVK_TEST_OS_RELEASE` | `/etc/os-release` |
| `QVK_TEST_ARCH` | `uname -m` |
| `QVK_TEST_EUID` | `$EUID` |
| `QVK_TEST_TUN` | `/dev/net/tun` |
| `QVK_TEST_ROOTFS` | prefix for every file read by the inventory (`/proc`, `/sys`, `/lib/modules`, `/run`) |
| `QVK_TEST_STEAL_SAMPLE_S` | steal sampling interval (default 2 s; tests use 0) |
| `QVK_TEST_HIDE_TOOLS` | tools to treat as not installed |

Setting them cannot grant privileges: a faked root only makes qvk attempt reads
that the real user may not be allowed to perform.

Host fixtures (`tests/fixtures/hosts/<name>/`) hold a fake `rootfs/`, captured
command output in `cmd/` and an `env` file. `tests/fixtures/stub-cmd.sh` replaces
every command the inventory may call and logs each invocation; tests assert that
only allow-listed read-only command lines were executed.

### D9. Redaction

`--redact-ip` replaces every *registered* address (`qvk_register_ip`: the target's
interface addresses now, egress/probe/client addresses later) with a stable label
`<ip-N>` in the final JSON and human output. Matching respects address boundaries
(`1.2.3.4` never rewrites part of `11.2.3.45`); longer addresses are replaced first.
Public endpoints (resolvers, test hosts) are not registered and stay readable.
Loopback is never registered. Tests assert that no original address substring
remains in a redacted report.

### D10. Facts vs. checks

`system` holds facts without a verdict (CPU, memory, steal, firewall presence, ...).
A value gets a `status` only as a test in `tests[]` with a documented rule
(`vpn_readiness`: AES, tun, BBR, UDP buffers, VPN ports). One steal sample is a
fact, never a verdict. Firewall rule contents are never copied, only counts.

Readiness rules: missing `/dev/net/tun` is `warn`, not `fail` — Xray and kernel
WireGuard work without it; userspace VPNs (amneziawg-go, wireguard-go) do not.
UDP buffers below 16 MiB are `warn` with the recommended `sysctl` printed, never
applied. VPN ports already in use are `warn` (an installed kit is a normal reason).

### D11. Network checks from the target

Modules: `lib/net.sh` (endpoint list, one measured `curl` call, outcome mapping,
statistics), `lib/egress.sh` (checks), `lib/verdict.sh` (per-area verdicts).
Endpoints live in `config/endpoints.tsv` (`<category> <name> <https-url>`, validated:
https only, known category, no extra fields); `--endpoints FILE` overrides it.

- Every request: HTTPS only, no redirects, body capped at 1 MiB, connect timeout 5 s,
  total timeout 10 s (RTT probes: 3 s / 6 s). The loop is bounded, so a run always ends.
- curl exit codes map to `fail` + `reason_code` for network problems (DNS, connect,
  timeout, TLS, reset) and to `error` for curl-side problems. A tester error is never
  reported as a network failure and never makes the verdict `unsuitable`.
- Egress IPv4/IPv6: several echo services; disagreement is `warn` + `conflict` and
  leaves `target.ip` null. An echo service proves only the egress address.
- NAT: egress IP found on the interface → `none`; only a private address →
  `one_to_one_suspected`; 100.64/10 → `cgnat_suspected`; else `unknown`. NAT is
  informational and never a failure.
- RTT towards Russia-hosted hosts is the TCP handshake time from the VPS
  (`time_connect - time_namelookup`), 3 samples in `quick`, 20 in `full`; p95 only for
  n ≥ 20. Every such test states that it is not client reachability. A handshake
  under 1 ms is reported as `warn` / `middlebox_suspected`: a remote host cannot
  answer that fast, so something near the machine terminates TCP (seen on WSL).
- Clock offset: median of the `Date` header offsets of ≥ 3 distinct hosts, corrected
  for request latency, resolution 1 s; |offset| > 30 s is `warn`.
- `--offline` makes no request at all; every network test is `skipped` / `offline_mode`.

### D12. target_self_check verdict (v0.1 preset)

Criteria: RAM ≥ 512 MB, egress IPv4 determined without conflict, DNS works, at least
one baseline HTTPS endpoint answers, |clock offset| ≤ 30 s. Any verified violation →
`unsuitable`; otherwise any unknown → `indeterminate` (with `missing_evidence`);
else `suitable`. `/dev/net/tun` is not a criterion (TZ v1.2, change 11). Reasons are
stored as message keys and rendered English for JSON, active language for humans.

## Not yet decided

- `qvk-probe` language (Bash vs Python stdlib) — decide at the start of v0.2.
- Release packaging (tarball layout, checksum file name) — before the first release.
