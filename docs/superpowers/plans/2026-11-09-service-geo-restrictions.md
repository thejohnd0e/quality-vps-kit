# Service geo restrictions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an informational `service_geo` section that reports, per service, whether that service restricts the country of this VPS's egress IP.

**Architecture:** One new module `lib/servicegeo.sh` issues one GET per service with a browser User-Agent, reads the answer for a restriction marker and a positive availability marker, and appends an ordinary `tests[]` record with `section=service_geo`. The human report renders those records through the existing test renderer in a new section placed after `http_reachability`.

**Tech Stack:** Bash 4.4, `curl` only, project JSON helpers (`json_obj`, `json_str_or_null`), `qvk_add_test`, `lib/i18n/{en,ru}.sh`, `tests/lib/curlfix.sh` canned responses.

**Spec:** `docs/superpowers/specs/2026-11-09-service-geo-restrictions-design.md`

## Global Constraints

- Bash >= 4.4, `curl` the only required tool; no `jq` dependency.
- One GET per service per run; no retries; no redirects (`--max-redirs 0` stays).
- `--offline`: zero requests, rows `skipped` / `offline_mode`.
- Status vocabulary `pass|warn|fail|unknown|skipped|error`; `diagnosis` always `none`; `reason_code` and `http_outcome` keep existing meanings.
- `restriction` is `country_restricted|none|unknown`; `none` only with positive evidence; a missing marker is `unknown`.
- JSON keys/values English; every human string exists in both `en.sh` and `ru.sh`.
- `schema_version` stays `0.1`; add only the `service_geo` value to `$defs/section`.
- Tool version `0.1.2` (0.2.0 is reserved for the controller/probe line).
- Spotify key: published web-client constant, passed as a `curl` argument, never in `endpoint`, reports, logs, or human output.
- Browser UA applies only to these four GETs; every other section keeps `quality-vps-kit/$QVK_VERSION`.
- No addresses in this section, so `--redact-ip` has nothing to change.

## Review Focus

1. A service page changes and the marker disappears → the row must become `unknown`, never `available` and never `country_restricted`.
2. An EU exit receives a 302/consent answer → `unknown` with `http_error`, no crash, no restriction.
3. A body over the 1 MB cap (`curl` exit 63) → `unknown` / `insufficient_data`, never `pass`.
4. The Spotify key leaking into `endpoint`, JSON, human output, or the stub log.
5. `--offline` must issue no request at all (assert via the stub call log).

---

### Task 0: Commit the pending human-output tweak

**Files:** (already modified in the working tree, nothing new)
- `lib/report.sh`, `lib/i18n/en.sh`, `lib/i18n/ru.sh`, `tests/unit/test_intel.sh`, `tests/unit/test_i18n.sh`, `docs/methodology.md`, `docs/superpowers/specs/2026-11-09-claude-ip-risk-design.md`

**Interfaces:**
- Produces: a clean tree. No runtime interface.

- [ ] **Step 1: Verify the tree still passes**

Run: `bash tests/run.sh`
Expected: `RESULT: OK`, with `test_intel.sh` and `test_i18n.sh` reporting `0 failed`.

- [ ] **Step 2: Commit**

```bash
git add lib/report.sh lib/i18n/en.sh lib/i18n/ru.sh tests/unit/test_intel.sh tests/unit/test_i18n.sh docs/methodology.md docs/superpowers/specs/2026-11-09-claude-ip-risk-design.md
git commit -m "report: show Claude risk as its own paragraph with Claude trust score"
```

---

### Task 1: Capture the four responses (operator action)

**Files:**
- Create: `tests/fixtures/service_geo/<service>-<country>.txt` (reduced excerpts)
- Create: `.superpowers/sdd/2026-11-09-service-geo/capture.md` (local, git-ignored)

**Interfaces:**
- Produces: the exact marker substrings every later task asserts. No code interface.

- [ ] **Step 1: Get the foreign sample.** Ask the operator to run on a US/EE/TR VPS (read-only, no install):

```bash
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36'
for u in 'https://www.youtube.com/premium?hl=en' 'https://music.youtube.com/?hl=en' 'https://www.primevideo.com/'; do
  echo "== $u"; curl -sS -m 20 -A "$UA" -w '\nHTTP %{http_code}\n' "$u" | head -c 400000
done
echo "== spotify"
curl -sS -m 20 -A "$UA" 'https://spclient.wg.spotify.com/signup/public/v1/account/?validate=1&key=<key>'
```

- [ ] **Step 2: Get the restricted-country sample.** Repeat the same three HTML commands (plus Spotify) on the Moscow VPS. YouTube may refuse from that network; record whatever comes back instead of retrying.

- [ ] **Step 3: Reduce and record.** For each service keep the shortest excerpt that contains the country marker and the availability/restriction marker, write it to `tests/fixtures/service_geo/`, and record in `capture.md`: date, country of each vantage, command, matched substrings, and which services can ship.

Expected: `capture.md` names each service as `ship` or `drop` with the reason. A service whose restricted case produced no decisive marker is `drop`.

If the Moscow VPS cannot reach a service at all (YouTube is commonly reset from
Russian networks), do **not** invent a real capture: write the restricted excerpt as
a synthetic body containing the service's documented wording, name the file
`<service>-restricted-synthetic.txt`, and record in `capture.md` that the restricted
branch is verified only against the documented marker, so a change in wording
degrades to `unknown` (fail-closed) rather than a false `restricted`.

- [ ] **Step 4: Commit the excerpts**

```bash
git add tests/fixtures/service_geo
git commit -m "test: add service_geo response excerpts"
```

---

### Task 2: Section infrastructure with YouTube Premium

**Files:**
- Create: `lib/servicegeo.sh`
- Create: `tests/unit/test_servicegeo.sh`
- Create: `tests/lib/fixtures.sh` (shared canned responses, extracted from `test_intel.sh`)
- Modify: `tests/unit/test_intel.sh` (source the shared helper)
- Modify: `qvk` (source the module, call it in `cmd_run`)
- Modify: `lib/report.sh` (`_qvk_report_human_raw` section order)
- Modify: `schema/report.schema.json` (`$defs.section.enum`)
- Modify: `lib/i18n/en.sh`, `lib/i18n/ru.sh`
- Modify: `tests/unit/test_network.sh` (contacted-host allowlist)

**Interfaces:**
- Produces: `qvk_service_geo_run` (no arguments, appends records to `QVK_TESTS`), `QVK_SG_UA` (browser User-Agent), `QVK_SG_SERVICES` (array of service ids), `_sg_emit <id> <status> <restriction> <country> <evidence> <hmsg> <hargs> <endpoint>`.
- Consumes: `qvk_curl <tag> <url> [args...]` setting `QC_BODY QC_RC QC_CODE QC_BYTES`; `qvk_add_test`; `qvk_curl_outcome`; `msg`.

- [ ] **Step 1: Write the failing test**

First extract the canned-response helpers so both network test files share them. Move
`services_fixtures` and `intel_fixtures` (with the `RIPE_*`, `INFO_*`, `ABUSE_*`,
`NC_*` body constants they use) out of `tests/unit/test_intel.sh` into a new
`tests/lib/fixtures.sh`, and source it from `test_intel.sh`. Run
`bash tests/unit/test_intel.sh` before writing anything else: expected unchanged,
`0 failed`. The extraction changes no behaviour.

Then create `tests/unit/test_servicegeo.sh`:

```bash
#!/usr/bin/env bash
# service_geo rows against canned curl responses. No real network.
set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"
source "$REPO_ROOT/tests/lib/hostfix.sh"
source "$REPO_ROOT/tests/lib/curlfix.sh"
source "$REPO_ROOT/tests/lib/fixtures.sh"

PY=$(find_python) || { echo "python 3 is required" >&2; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf -- "$WORK"' EXIT
unset NO_COLOR LANG LC_ALL LC_MESSAGES
export QVK_RETRY_DELAY_S=0
CF="$WORK/curlfix"; R="$WORK/r.json"; H="$WORK/h.txt"

YT_URL='https://www.youtube.com/premium?hl=en'
available_body=$(cat "$REPO_ROOT/tests/fixtures/service_geo/youtube_premium-kz.txt")
restricted_body=$(cat "$REPO_ROOT/tests/fixtures/service_geo/youtube_premium-ru.txt")
masked_body='<html><body>Nothing to see here.</body></html>'

# sg_fixtures <yt url> <curl rc> <http code> <body>: everything else stays default
sg_fixtures() {
  scenario 0 0 0
  services_fixtures
  intel_fixtures
  fix "" "$1" "$2" "$3" "$4"
}
```

Copy the `run_json` / `jf` / `tf` / `sf` accessors from `tests/unit/test_intel.sh`.
Required assertions:

- available excerpt → `sg_youtube_premium.status` `"pass"`, `details.restriction` `"none"`, `details.evidence` `"product_page"`, `details.country` is the code in the excerpt.
- restricted excerpt → `"warn"`, `"country_restricted"`, `"restriction_marker"`.
- masked body with HTTP 200 → `"unknown"`, `"unknown"`, `reason_code` `"insufficient_data"`.
- 302 → `"unknown"`, `"unknown"`, `reason_code` `"http_error"`.
- 403 → `"unknown"`, `reason_code` `"http_403"`, `http_outcome` `"http_denied"`.
- 429 → `"unknown"`, `reason_code` `"http_429"`, `http_outcome` `"rate_limited"`.
- `curl` exit 63 (body over the cap) → `"unknown"`, `"insufficient_data"`.
- `curl` exit 28 (timeout) → `"error"`, `reason_code` `"timeout"`.
- `--offline` → `"skipped"`+`offline_mode` and the curl stub log (`QVK_STUB_LOG`) contains no `youtube.com`.
- human output contains `Service restrictions` and the `YouTube Premium` label.
- `summary.verdicts.target_self_check.verdict` stays `"suitable"` in every case above.

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash tests/unit/test_servicegeo.sh`
Expected: FAIL — `test_servicegeo.sh: no such fixture` or a missing-row assertion.

- [ ] **Step 3: Implement the module**

`lib/servicegeo.sh`:

```bash
# shellcheck shell=bash
# Service geo restrictions: does a service restrict the country of this egress IP?
# One gentle GET per service, browser User-Agent, informational only.

QVK_SG_UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36'
QVK_SG_SERVICES=(youtube_premium)

_sg_emit() { ... }        # builds details JSON, maps status/reason_code, calls qvk_add_test
_sg_html() { ... }        # <id> <url> <restriction-regex> <product-regex> [country-json-key=countryCode]
_sg_youtube_premium() { ... }
qvk_service_geo_run() { local id; for id in "${QVK_SG_SERVICES[@]}"; do "_sg_$id"; done; }
```

Rules to encode exactly:
- `_sg_html <id> <url> <restriction-regex> <product-regex> [country-json-key]`
- country extraction: first `"<country-json-key>":"XY"` in the body (default
  `countryCode`), upper-cased; empty → `null`.
- restriction match → `warn`, `country_restricted`, `restriction_marker`.
- else product regex **and** country → `pass`, `none`, `evidence=product_page`.
- else `unknown`, `unknown`, `insufficient_data`.
- `QC_RC=63` → `unknown`, `insufficient_data` (truncated body).
- non-200: `403` → `unknown`/`http_403`/`http_denied`, `429` → `unknown`/`http_429`/`rate_limited`, other 3xx/4xx/5xx → `unknown`/`http_error`/`unknown`.
- network failure → `error` with the code from `qvk_curl_outcome`.
- `QVK_OFFLINE=1` → `skipped`/`offline_mode` and no `qvk_curl` call.
- `endpoint` field is the URL passed to `_sg_html`; `traffic_bytes` is `QC_BYTES`.

YouTube Premium rule: URL `https://www.youtube.com/premium?hl=en`, restriction regex `not available in your country`, product regex `ypc`.

Wire it up: source `lib/servicegeo.sh` in `qvk` after `lib/httpcheck.sh`; call `qvk_service_geo_run` in `cmd_run` after `qvk_http_run` and before `qvk_geo_consensus`; add `_qvk_human_tests service_geo report.section.service_geo` after the `http_reachability` line in `_qvk_report_human_raw`.

- [ ] **Step 4: Add schema and i18n**

`schema/report.schema.json`: add `"service_geo"` to `$defs.section.enum` (after `http_reachability`).

`lib/i18n/en.sh`: `report.section.service_geo='Service restrictions (from this VPS)'`, `test.sg_youtube_premium='YouTube Premium'`, `sg.restricted='restricted — country %s'`, `sg.restricted_nc='restricted — country not stated'`, `sg.available='available — country %s'`, `sg.available_nc='available'`, `sg.unknown='availability not stated'`, `sg.unknown_country='availability not stated (country %s)'`.
`lib/i18n/ru.sh`: the same keys translated, same `%s` counts.

- [ ] **Step 5: Run the tests**

Run: `bash tests/unit/test_servicegeo.sh`
Expected: `0 failed`.

Run: `bash tests/unit/test_network.sh`
Expected: `0 failed` after the allowlist gains `youtube.com` (add the host where the other contacted hosts are listed).

- [ ] **Step 6: Commit**

```bash
git add lib/servicegeo.sh qvk lib/report.sh schema/report.schema.json lib/i18n/en.sh lib/i18n/ru.sh tests/unit/test_servicegeo.sh tests/unit/test_network.sh tests/lib/fixtures.sh tests/unit/test_intel.sh
git commit -m "feat: add service_geo section with YouTube Premium"
```

---

### Task 3: Second HTML service (YouTube Music or Prime Video)

**Files:**
- Modify: `lib/servicegeo.sh` (`QVK_SG_SERVICES`, one `_sg_<id>` function)
- Modify: `lib/i18n/en.sh`, `lib/i18n/ru.sh` (`test.sg_<id>`)
- Modify: `tests/unit/test_servicegeo.sh`, `tests/unit/test_network.sh`

**Interfaces:**
- Consumes: `_sg_html`, `_sg_emit` from Task 2.
- Produces: one more row; no new interface.

- [ ] **Step 1: Pick the service from the capture**

If `capture.md` marks `youtube_music` as `ship`: id `youtube_music`, URL `https://music.youtube.com/?hl=en`, restriction regex `not available in your area`, product regex `"countryCode"`.
Else if `prime_video` is `ship`: id `prime_video`, URL `https://www.primevideo.com/`, restriction regex `isServiceRestricted"\s*:\s*true`, product regex `"currentTerritory"`, country key `currentTerritory` instead of `countryCode`.
If neither is `ship`, skip this task, add one line to `capture.md`, and go to Task 4.

- [ ] **Step 2: Write the failing test**

Add to `tests/unit/test_servicegeo.sh`: the same three cases as Task 2 for the new id (restricted / available / masked), using its excerpt files.

- [ ] **Step 3: Run it to make sure it fails**

Run: `bash tests/unit/test_servicegeo.sh`
Expected: FAIL — row `sg_<id>` missing.

- [ ] **Step 4: Implement the service**

Append the id to `QVK_SG_SERVICES` and add `_sg_<id>` calling `_sg_html` with the values from Step 1. For `prime_video`, `_sg_html` takes the country JSON key as a fifth argument; default `countryCode`.

- [ ] **Step 5: Run the tests**

Run: `bash tests/unit/test_servicegeo.sh && bash tests/unit/test_network.sh`
Expected: both `0 failed` (allowlist gains the new host).

- [ ] **Step 6: Commit**

```bash
git add lib/servicegeo.sh lib/i18n/en.sh lib/i18n/ru.sh tests/unit/test_servicegeo.sh tests/unit/test_network.sh
git commit -m "feat: add <id> to service_geo"
```

---

### Task 4: Spotify signup row with the published key

**Files:**
- Modify: `lib/servicegeo.sh` (`QVK_SG_SPOTIFY_KEY`, `_sg_spotify_signup`)
- Modify: `tests/unit/test_servicegeo.sh`
- Modify: `tests/unit/test_network.sh`, `docs/security.md`

**Interfaces:**
- Produces: `QVK_SG_SPOTIFY_KEY` (string, sourced by the test to build the fixture URL).

- [ ] **Step 1: Write the failing test**

```bash
# shellcheck source=lib/servicegeo.sh
source "$REPO_ROOT/lib/servicegeo.sh"
SPOTIFY_URL="https://spclient.wg.spotify.com/signup/public/v1/account/?validate=1&key=$QVK_SG_SPOTIFY_KEY"
fix "" "$SPOTIFY_URL" 0 200 '{"status":320,"is_country_launched":false}'
```

Assertions: `is_country_launched:false` → `warn`/`country_restricted`/`availability_flag`; `:true` → `pass`/`none`/`availability_flag`; `{"status":1}` alone → `unknown` + `insufficient_data`; and the JSON report and human output contain neither `$QVK_SG_SPOTIFY_KEY` nor the literal `key=`.

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash tests/unit/test_servicegeo.sh`
Expected: FAIL — no `sg_spotify_signup` row / key not defined.

- [ ] **Step 3: Implement**

```bash
QVK_SG_SPOTIFY_KEY='<published web-client key from the capture>'
_sg_spotify_signup() {
  local url="https://spclient.wg.spotify.com/signup/public/v1/account/?validate=1&key=$QVK_SG_SPOTIFY_KEY"
  # fetch with -A "$QVK_SG_UA"; parse exactly "is_country_launched":true|false
  # endpoint recorded WITHOUT the query string
}
```

`endpoint` is `https://spclient.wg.spotify.com/signup/public/v1/account/`; the key never enters `details`, `reason`, or `error`.

- [ ] **Step 4: Run the tests**

Run: `bash tests/unit/test_servicegeo.sh`
Expected: `0 failed`, including the key-absence assertions.

- [ ] **Step 5: Add the host to the allowlist and document the key**

`tests/unit/test_network.sh`: allow `spclient.wg.spotify.com`.
`docs/security.md`: one paragraph — the four hosts, the browser UA and why, and that the Spotify key is Spotify's own published web-client constant that qvk never copies into a report.

- [ ] **Step 6: Commit**

```bash
git add lib/servicegeo.sh tests/unit/test_servicegeo.sh tests/unit/test_network.sh docs/security.md
git commit -m "feat: add Spotify signup availability to service_geo"
```

---

### Task 5: Docs, version and release metadata

**Files:**
- Modify: `docs/methodology.md` (new subsection), `README.md` (feature line), `CHANGELOG.md`, `VERSION`, `install.sh`, `docs/architecture.md` (D5 note)

**Interfaces:**
- Produces: `scripts/release.sh --check` passes for `v0.1.2` once the tag exists locally.

- [ ] **Step 1: Document**

`docs/methodology.md`, new subsection "Service geo restrictions" after HTTP reachability: the table of services and markers, the fail-closed rule, the 3xx/truncation behaviour, and what the section cannot say (not a proof a VPN works, not about client networks).
`README.md`: one line in the feature list.
`CHANGELOG.md`: `## [0.1.2] - 2026-11-09` with one `### Added` bullet.
`docs/architecture.md` D5: one sentence that informational sections may add `$defs/section` values without a schema bump, because old reports stay valid.

- [ ] **Step 2: Bump**

`VERSION` → `0.1.2`; `install.sh` default → `0.1.2`.

- [ ] **Step 3: Verify everything**

Run: `bash tests/run.sh`
Expected: `RESULT: OK`.
Run: `shellcheck.exe -x -S style qvk lib/*.sh lib/i18n/*.sh tests/**/*.sh` (Windows) or `shellcheck -x -S style` in CI
Expected: exit 0.
Run: `git tag -a v0.1.2 -m "quality-vps-kit 0.1.2" && bash scripts/release.sh --check`
Expected: `release.sh: checks passed: v0.1.2`.

- [ ] **Step 4: Commit**

```bash
git add docs/methodology.md README.md CHANGELOG.md VERSION install.sh docs/architecture.md docs/security.md
git commit -m "release: v0.1.2 with service geo restrictions"
```

---

## Self-review notes

- Spec coverage: section/data model → Task 2; per-service rules → Tasks 2-4; capture → Task 1; docs/schema/version → Task 5; fail-closed and 3xx/truncation → Task 2 rules and Review Focus tests.
- The plan deliberately does not ship `prime_video`/`youtube_music` unless Task 1 proves their markers; that is the spec's drop rule, not a gap.
