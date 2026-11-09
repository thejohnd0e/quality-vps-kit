# Design — service geo restrictions (`service_geo`)

Date: 2026-11-09. Status: awaiting approval. Scope: tool version `0.1.2` (the
`0.2.0` line stays reserved for the controller/probe work in `docs/roadmap.md`).

## Intent

The instances `qvk` evaluates are candidates for use as VPN exits. Before choosing
one, the operator needs one fact that `http_reachability` does not answer: **does a
service restrict this exit because of its country?** A client of the future VPN
lands on the same address and gets the same answer, so the answer describes the
service's policy for the candidate, not this run's luck.

Requested shape (agreed in conversation): a separate section, live answers from the
services themselves, no stored country tables. IP-reputation signals (captcha,
anti-bot 403, "unusual traffic") were explicitly excluded: they say something about
the address, not the country, and the operator reads them by hand.

## Goals

- One new informational section, `service_geo`, in both JSON (`tests[]` rows) and
  the human report.
- Up to four services in 0.1.2: `youtube_premium`, `youtube_music`, `spotify_signup`,
  `prime_video`.
- Per service: `restriction` = `country_restricted` | `none` | `unknown`, the
  `country` the service assigned to this IP when the answer contains it, and which
  `evidence` produced the conclusion.
- Fail closed: a row says `none` (available) only with a positive marker; a missing
  marker is `unknown`, never "available".
- Every rule reproducible from a captured response; offline tests need no network.

## Non-goals

- No geo-consensus across many GeoIP APIs (that is `ip_intelligence.geo_consensus`).
- No stored lists of "countries where X works"; no dated availability tables.
- No captcha, anti-bot, or reputation signals; no 403 interpretation as a country
  restriction.
- No catalogue comparison (which films a region gets) and no CDN/edge location.
- No authentication, no API keys of our own, no captcha bypass, no retries that
  hammer a service.
- No change to any verdict, no score, no single "VPN suitability" number.

## Anti-goals

- A section that reports `available` because the page changed and the marker
  disappeared.
- A row that reports `country_restricted` from an HTTP 403 alone.
- Treating this section as proof that a VPN will or will not work.

## Constraints

- Bash 4.4, `curl` only, one GET per service, `--offline` sends nothing.
- These four requests present a browser User-Agent instead of the honest
  `quality-vps-kit/<version>`: the section asks what a browser would see, and some
  services answer anything else with a "browser deprecated" page. Approved by the
  operator; `docs/security.md` must say so, and no other section changes its UA.
- Redirects are still not followed (`--max-redirs 0`); a 3xx answer is `unknown`
  with `reason_code: http_error`. If the captured samples show that a target
  redirects on every request, that is a finding to revisit, not a reason to weaken
  the no-redirects promise silently.
- These pages are large (~900 KB); each row records `traffic_bytes`, so the operator
  sees the cost. `curl` exit 63 (body over the 1 MB cap) means a partial body and
  therefore `unknown`/`insufficient_data`, never `pass`.
- Status vocabulary stays the project's: `pass/warn/fail/unknown/skipped/error`;
  `diagnosis` stays `none` for these rows; `reason_code` and `http_outcome` keep
  their existing meanings.
- JSON keys and values English; human strings in `lib/i18n/{en,ru}.sh`.
- `schema_version` stays `0.1`: the change is additive (a new `section` value and
  an optional `details` shape). Old reports remain valid.
- No addresses in this section, so `--redact-ip` has nothing to redact here.
- No secrets: the only third-party constant is Spotify's published web-client
  key, documented in `docs/security.md`.

## What the reconnaissance established

Run on 2026-11-09 from a Russian home network and through a non-RU HTTP fetcher.

| Fact | Consequence |
|---|---|
| From RU: `youtube.com` resets the connection, `primevideo.com` returns an empty body, Netflix speedtest API returns `NaN` | The checks must run on the foreign VPS, not from the operator's network; a failure here is `error`/`unknown`, not "restricted" |
| From RU: JetBrains `geo`, Apple `pep/gcc`, Steam `steamCountry`, TikTok `region` answer with `RU` | Machine-readable country signals are cheap; the section can show `country` without HTML guessing |
| Non-RU sample of `youtube.com/premium` contains `"countryCode":"KZ"` and premium product markers, and no "not available" text | Both directions of evidence exist in the same page; absence of the restriction text in a supported country proves the fail-closed rule must rely on product markers, not on absence alone |
| Non-RU sample of `primevideo.com` contains `"currentTerritory":"KZ"` and no `isServiceRestricted` field | Prime Video's restricted case is not observable from this sample; the service ships only if its rules are verified against a captured restricted response |
| `ipregion` (the reference script) greps the same markers but treats "marker absent" as available | We deliberately diverge: unknown instead of guessing |
| `music.youtube.com` answers a non-browser request with "Your browser is deprecated"; the fetcher got that page too | This service is in the set only if the browser-UA capture yields a country and an availability marker; otherwise it is dropped |
| `primevideo.com` sample has territory but no restriction flag | The restricted branch needs a capture from a restricted-country exit (the operator approved one read-only capture on the Moscow VPS); without it, Prime Video is dropped |

## Capture step (approved, one-off)

Before the per-service rules are implemented, capture the four responses once:

- one foreign VPS (US/EE/TR) with the browser User-Agent used by the section;
- one Moscow VPS for the restricted-country case.

The capture is read-only: four `curl` GETs, no install, no config change. The
reduced bodies become fixtures and the exact markers are read off them. Nothing in
the shipped tool depends on the capture hosts; they are only evidence.

## Approaches considered

- **A. Extend `http_reachability` rows** with a restriction field. Cheap, but that
  section would then mean two things ("service answered" and "service restricts the
  country"), and its verdict-facing wording would have to explain both. Rejected.
- **B. New section `service_geo`** (chosen). Own service list, own fields, own
  human paragraph, no effect on other sections.
- **C. Full `ipregion`-style table** (16 geo APIs + services + CDN + percentages).
  Rejected: the operator does not need geo consensus, and dozens of third-party
  APIs with embedded keys add traffic, fragility, and privacy cost.

Storage of the new rows is my call: they are ordinary `tests[]` records with
`section=service_geo` and a `details` object, not a new top-level JSON object. That
reuses the existing status handling, human renderer, redaction pass, schema
validation, and test helpers instead of duplicating them. The cost is that a JSON
consumer must filter by `section`; that is how every other check already works.

## Data model

One row per service (`tests[]`):

```json
{
  "id": "sg_youtube_premium",
  "section": "service_geo",
  "method": "curl_get",
  "endpoint": "https://www.youtube.com/premium?hl=en",
  "status": "warn",
  "diagnosis": "none",
  "reason_code": null,
  "details": {
    "restriction": "country_restricted",
    "country": "RU",
    "evidence": "restriction_marker"
  }
}
```

- `details.restriction`: `country_restricted` | `none` | `unknown`.
- `details.country`: two-letter code the service assigned, or `null`.
- `details.evidence`: `restriction_marker` | `availability_flag` |
  `product_page` | `none`.

Status mapping:

| Situation | status | reason_code | http_outcome |
|---|---|---|---|
| Explicit country restriction | `warn` | `null` | — |
| Positive availability evidence | `pass` | `null` | — |
| Service answered, no decisive marker | `unknown` | `insufficient_data` | — |
| Service answered 403 / 429 | `unknown` | `http_403` / `http_429` | `http_denied` / `rate_limited` |
| Other unexpected status | `unknown` | `http_error` | `unknown` |
| Timeout, DNS, TLS, reset | `error` | existing curl codes | existing mapping |
| `--offline` | `skipped` | `offline_mode` | — |

`diagnosis` is always `none`. Verdicts are untouched.

## Per-service rules (0.1.2)

Each rule is a pair: a restriction marker and positive availability evidence. Both
are matched case-insensitively against the raw body, one GET, no `jq`.

| id | Endpoint | Restriction marker | Availability evidence |
|---|---|---|---|
| `youtube_premium` | `GET https://www.youtube.com/premium?hl=en` | text "not available in your country" (the service's own wording) | `"countryCode":"XX"` present **and** a premium product marker (`ypc`) present |
| `youtube_music` | `GET https://music.youtube.com/` | text "not available in your area" | `"countryCode":"XX"` present and no restriction marker |
| `spotify_signup` | `GET https://spclient.wg.spotify.com/signup/public/v1/account/?validate=1` with the published Spotify web key | `"is_country_launched":false` | `"is_country_launched":true` |
| `prime_video` | `GET https://www.primevideo.com/` | `"isServiceRestricted":true` | `"currentTerritory":"XX"` present and no restriction marker |

Rules that keep this honest:

- The restriction marker is a *candidate*: if a service changes wording, the row
  degrades to `unknown`, never to `available` and never to a false `restricted`.
- `youtube_music`'s availability needs a positive product marker before shipping; if
  the captured sample has none, the service is dropped from 0.1.2 rather than
  reduced to "absence of a marker".
- `prime_video` ships only after a captured restricted response verifies the
  `isServiceRestricted` shape; without it, it is dropped. Which of the four ships is
  therefore a fact of implementation, recorded in the plan's ledger.
- A body that is not HTML/JSON (proxy page, captive portal) yields `unknown`.
- At most one request per service per run; no retries.
- Spotify's key is a published web-client constant, not a user secret; it is passed
  to `curl` in an argument array, and the row's `endpoint` is the URL without the
  key, so the key never reaches a report, a log, or the human output. A test asserts
  that the key string does not appear anywhere in either report.
- The browser User-Agent applies to these four GETs only and is one Chrome string,
  documented in `docs/security.md` with the reason.

## Human output

New section after `http_reachability`:

```
Service restrictions (from this VPS)
  WARN  YouTube Premium    restricted — country US
  PASS  YouTube Music      available — country US
  ????  Spotify signup     unknown — availability not stated
  WARN  Prime Video        restricted — territory US
```

- Section title: `report.section.service_geo`; ids render through `test.sg_*` keys.
- `warn` only for `country_restricted`, `pass` only for positive availability,
  `unknown` for "answered without a decisive marker"; `error`/`skipped` reuse the
  existing labels.
- A footer line is not needed; the section title says "from this VPS" so the fact is
  not mistaken for a client-side measurement.

## Code shape

- New `lib/servicegeo.sh`, sourced by `qvk`, exposing `qvk_service_geo_run`.
- Called in `cmd_run` after `qvk_http_run`, before `qvk_geo_consensus`.
- Service table and per-service parse functions live in the file; there is no new
  config file and no `--endpoints` category (the four URLs are not user data).
  Users who want different services edit the file; the section is not a plugin API.
- Reuses `qvk_curl`, `qvk_add_test`, `qvk_ms`; no new transport code.
- `_qvk_test_label` gains no new branch: ids are `sg_<service>` and the i18n keys
  `test.sg_<service>` are added to both catalogs.

## Tests

`tests/unit/test_servicegeo.sh` (new), following the existing stub-curl pattern:

- Restricted body (synthetic, containing the documented marker) → `warn`,
  `country_restricted`, evidence `restriction_marker`.
- Same body without the marker → `unknown` + `insufficient_data` (the regression
  this section exists for).
- Positive availability body → `pass`, `none`, evidence recorded, country extracted.
- Country marker present but no product marker → `unknown`.
- Spotify boolean in both directions; `is_country_launched:false` → restricted.
- 403, 429, 500, invalid body, timeout → `unknown`/`error` with the existing codes;
  never `country_restricted`.
- `--offline` → `skipped`/`offline_mode` and zero requests on the allowlist.
- `--redact-ip` → no address leaks in the section (there are none to leak).
- Verdicts unchanged by any service_geo outcome.
- `tests/unit/test_report.sh` (or equivalent) checks the section renders in human
  output and both languages, and that the JSON validates against
  `schema/report.schema.json` with `section: "service_geo"`.
- `tests/unit/test_network.sh` allowlist gains the four hosts.
- No fixture ships a full 900 KB page; fixtures are the minimal bodies that carry
  the markers, captured once from a real non-RU vantage and reduced.

## Schema and versioning

- `schema/report.schema.json`: add `"service_geo"` to `$defs/section.enum`. No other
  schema change; `details` is already a free object.
- `docs/architecture.md` D5: one sentence that informational sections may add enum
  values without a schema bump, because old reports stay valid.
- Tool version: `0.1.2` (new section). `CHANGELOG.md` entry; `docs/release.md`
  procedure unchanged.

## Docs

- `docs/methodology.md`: new subsection "Service geo restrictions" with the rules
  table, the fail-closed rule, and what the section cannot say.
- `docs/security.md`: the four hosts contacted, what is sent (one unauthenticated
  GET, no IP in the query), and the Spotify public web key with its source and the
  fact that it is not a user secret.
- `README.md`: one line in the feature list.

## Left to the builder

- Exact marker strings and their case handling, decided against the captured
  samples; any service whose restricted case cannot be captured is dropped and the
  reason recorded in the ledger.
- Whether the Spotify key constant lives in the file or in `config/`; either is
  acceptable, it must be documented as public and must not reach a report.
- Human column widths and message wording within the existing style.
- Whether `service_geo` rows need their own `test.sg_*` labels or can reuse
  `test.service_geo_*`; either is fine as long as both catalogs stay in parity.
