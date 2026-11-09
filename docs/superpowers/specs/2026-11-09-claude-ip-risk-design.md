# Claude IP risk for this VPS — design

Small change. Additive to v0.1: one new IP-intelligence source plus a derived,
documented risk object. No new CLI surface, no verdict for `ip_intelligence`.

## Intent

`qvk` runs on the VPS and knows its own egress IP. The question to answer on that
report: **how risky is this instance's IP for working through Claude**, and why.
The operator uses these VPSes as VPN exits (Claude among the workloads), so the
decision is per instance: keep it for Claude, treat it as a fallback, or don't.

## Goals

- Report the third-party signals behind the judgement, not just one number:
  trust score, residential vs hosting, `vpn/proxy/tor/crawler/abuser` flags, ASN,
  country, and whether the country is one Claude itself restricts.
- A `low|medium|high|unknown` level derived by rules documented in
  `docs/methodology.md`, with machine-readable reasons.
- Region restriction works even if the third-party API is down (country is also
  available from IPinfo / geo consensus).

## Non-goals

- No claim about whether Claude will accept the account; no `blocked` verdict.
- No login/API test with credentials, no attempt to bypass anything.
- No arbitrary-IP mode: the script checks only the instance it runs on.
- No new report section (that was option B) and no verdict area for v0.1.

## Anti-goals

- A single opaque score presented as probability of being blocked.
- Quietly turning a missing/rate-limited API into `low` or `0`.
- Reporting "hosting = fail"; hosting is normal for a VPS.

## Constraints

- Read-only, one HTTPS GET, at most one retry, with timeout — reuse
  `_intel_request` / `_intel_classify` / `_intel_emit`.
- `--offline` => `skipped` / `offline_mode`; no egress IPv4 => `skipped` / `not_applicable`.
- Failures never break the run: `skipped`/`unknown` with a reason code.
- The API is undocumented and run by a third party (ip.net.coffee). Treat every
  value as untrusted data: length-limited, pattern-checked, JSON-escaped, and
  never copied wholesale into the report (no `rdns`, no prefix, no free text).
- Report values under `--redact-ip`: `checked_ip` is redacted like other addresses.

## Approaches considered

- **A — new source inside `ip_intelligence` + derived `claude_risk`** (chosen).
  Smallest diff; reuses retry/classify/redaction/i18n machinery; the derived
  object stays separate from the source record.
- **B — separate `ai_readiness` section.** Cleaner semantics and room for future
  providers, but adds a schema section, human section, i18n and a second network
  helper for a single provider now. Rejected for v0.1.
- **C — derive everything from existing sources.** No new dependency, but drops
  exactly what was asked for: their trust score and vpn/proxy/tor/residential
  classification. Rejected.

## How it works

### 1. New source `netcoffee`

`GET https://ip.net.coffee/api/iprisk/<egress-ip>` — public, no key, JSON. Method id
`netcoffee_iprisk`, test id `intel_netcoffee`. Fields taken from the answer:

| report field | API field | notes |
|---|---|---|
| `asn` | `asn` | number |
| `asn_holder` | `asOrganization` | string |
| `country` | `countryCode` | upper-cased 2 letters |
| `hosting` | `isResidential == false` | reported as hosting property |
| `trust_score` | `trust_score` | 0..100 or null |
| `residential` | `isResidential` | bool or null |
| `vpn` / `proxy` / `tor` / `crawler` / `abuser` | `is_vpn` / `is_proxy` / `is_tor` / `is_crawler` / `is_abuser` | bool or null |

Not taken: `rdns`, `range`, `related_domains`, `ai_verdict`, `intelligence`,
`vpn_trace`, `reddit_blocked`, `asn_tbps` — not needed and/or identifying.

The API normalises to a range (`1.1.1.1` answered `"ip": "1.1.1.2"`). We report
what we asked for as `checked_ip` and ignore their `ip` field.

`source` enum gains `netcoffee`; `intel_source` gains the seven nullable optional
fields above (`trust_score`, `residential`, `vpn`, `proxy`, `tor`, `crawler`,
`abuser`) so each source record stays self-describing; they are `null` for
RIPEstat/IPinfo/AbuseIPDB. Additive to `schema_version 0.1`.

### 2. Derived object `ip_intelligence.claude_risk`

```json
"claude_risk": {
  "level": "medium",
  "reasons": ["hosting_asn", "low_trust_score"],
  "country": "DE",
  "restricted_region": false,
  "trust_score": 41,
  "residential": false,
  "checked_ip": "203.0.113.10",
  "note": "judgement by one third-party service (net.coffee); what Claude itself decides is unknown"
}
```

`level` and `reasons` are never null; `country`, `trust_score`, `residential`,
`checked_ip` are null when unknown.

### 3. Rules (documented verbatim in `docs/methodology.md`)

Inputs: `country` (netcoffee, else IPinfo, else geo consensus), `restricted_region`,
`trust_score`, `residential`, flags. Evaluate in order, first match sets the level;
reasons accumulate.

1. no country and no `trust_score` and no flags → `unknown` [`no_data`]
2. country in the restricted list → `high` [`restricted_region`]
3. `tor` → `high` [`tor_exit`]
4. `crawler` → `high` [`crawler`]
5. `abuser` → at least `medium` [`abuse_history`]
6. `trust_score < 50` → `high` [`low_trust_score`]; `50..79` → at least `medium` [`moderate_trust_score`]
7. `vpn` or `proxy` → at least `medium` [`vpn_or_proxy`]
8. `residential == false` → at least `medium` [`hosting_asn`]
9. source failed and no country → `unknown` [`source_unavailable`]
10. otherwise, `trust_score >= 80` and `residential == true` and no flags → `low`

Restricted list (from the net.coffee frontend on 2026-11-09, where the browser
forces the score to 0): CN, HK, MO, RU, KP, IR, SY, CU, BY, VE. Recorded with its
date and source, because it can change; Claude's own policy is not ours to state.

Consequence, stated in the docs: a plain VPS is normally `medium` at best, since
its IP is a hosting IP. That is the honest answer, not a defect.

### 4. Human output

One line under the IP-intelligence section, next to the geo line:

```
  Claude risk        medium — hosting ASN, trust score 41 (net.coffee; their judgement)
```

i18n keys `claude_risk.*` in `lib/i18n/en.sh` and `ru.sh`; JSON keys stay English.

### 5. Privacy

`docs/security.md` gets a row for `ip.net.coffee` (learns the VPS public IP, no key,
no cookies), and the "at most one retry" rule already covers it.

## Tests

- Unit (`tests/unit/test_intel.sh`, canned curl): source record parsed; `low` for a
  clean residential answer; `high` for a restricted-country answer; `high` for
  `trust_score 20`; `unknown` with `source_unavailable` when the API fails but
  IPinfo works; `skipped`/`offline_mode` under `--offline`; no secrets/IP leakage
  under `--redact-ip`.
- Existing fixtures that run `qvk run` need the new URL stubbed (default: an error
  or a canned clean answer) so unrelated assertions stay stable.
- Schema validation via `tests/tools/validate_report.py` for both fixtures and the
  updated `schema/examples/report-quick.example.json`.
- `bash -n` + ShellCheck over all shell files; i18n test for the new keys.

## Left to the builder

Exact i18n wording, the human-line padding, and whether the level line is printed
when the source is `skipped` (proposal: print it only for `low|medium|high|unknown`
with `country` or `trust_score` known, otherwise omit the line and keep the source
row's reason).
