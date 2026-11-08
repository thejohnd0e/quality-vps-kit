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
lib/report.sh           report assembly (JSON) and human rendering
schema/                 JSON Schema of the report + reference example(s)
tests/run.sh            all offline checks (syntax, ShellCheck, schema, unit tests)
tests/tools/            stdlib-only helpers (schema validator)
tests/fixtures/         os-release files, invalid reports, later: captured command output
```

Measurement modules (`inventory.sh`, `readiness.sh`, `network.sh`, `ip-intel.sh`)
are added in later slices. Each appends test objects to `QVK_TESTS` and never
prints to stdout.

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

Setting them cannot grant privileges: a faked root only makes qvk attempt reads
that the real user may not be allowed to perform.

### D9. Redaction

`--redact-ip` is accepted from v0.1 and recorded in `run.redacted`. The skeleton
report contains no IP addresses yet; the redaction pass (stable `<ip-N>` labels
across all fields, prefix removed, ASN/country kept) lands together with the
first module that records an IP, with a test that no original IP substring remains.

## Not yet decided

- `qvk-probe` language (Bash vs Python stdlib) — decide at the start of v0.2.
- Release packaging (tarball layout, checksum file name) — before the first release.
