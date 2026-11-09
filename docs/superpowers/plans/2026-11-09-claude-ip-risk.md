# Claude IP risk for this VPS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the report of the VPS it runs on, `qvk` adds one IP-intelligence source (`netcoffee`) and a derived, documented `claude_risk` object saying how risky this instance's egress IP is for working through Claude, and why.

**Architecture:** A new `_intel_netcoffee` source inside the existing `lib/intel.sh` machinery (one HTTPS GET, timeout, at most one retry, `skipped`/`unknown` on failure), storing normalised flags in `QVK_NC_*` globals and in the source record. A separate `qvk_claude_risk_evaluate` turns those flags plus the country into `QVK_CLAUDE_RISK_JSON` by a fixed rule ladder. `lib/report.sh` emits one JSON object inside `ip_intelligence` and one human line.

**Tech Stack:** Bash 4.4+, coreutils, `curl` (via `qvk_curl`); no `jq`, no new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-09-claude-ip-risk-design.md`

## Global Constraints

- Target: Debian 12/13 or Ubuntu 22.04/24.04, amd64/arm64; required tools stay `bash`, coreutils, `curl`, `iproute2`; `jq` optional.
- `LC_ALL=C` for everything parsed (already set by `qvk_init_env`); `umask 077`; temp files via `mktemp -d` + trap.
- Read-only: one HTTPS GET per new endpoint, timeout `QVK_HTTP_MAX_TIME`, at most one retry, no cookies, no redirects followed (`qvk_curl` already does this).
- JSON is a versioned contract (`schema_version` stays `0.1`); keys/values always English; unknown values are JSON `null`, never `0` or `"N/A"`.
- Statuses are `pass|warn|fail|unknown|skipped|error`; `reason_code` values come from the existing enum in `schema/report.schema.json` — do not invent new ones for test records.
- A failing or missing third-party API never breaks the run: the run still exits 0 with a report.
- `tests/tools/validate_report.py` supports only `type, enum, const, required, properties, additionalProperties, items, pattern, minLength, minimum` — **no `maximum`**, no `oneOf`. Keep schema additions inside that subset.
- CI must not touch the network: all tests use canned `curl` responses (`tests/fixtures/stub-curl.sh`).
- `bash -n` and `shellcheck -x -S style` must stay clean; `bash tests/run.sh` must pass.
- No secrets, no credentials, and no free text from remote services in the report.

## Review Focus

- The third-party endpoint timing out, answering 5xx, or returning HTML: the source must end up `fail`/`unknown`/`skipped` with a reason, `claude_risk` must be `unknown`, and the run must exit 0. Pinned in Task 3 and Task 4 tests.
- A hostile or sloppy answer: string instead of bool, `countryCode: "ru"` lowercase, `trust_score` missing, negative or > 100. Values must be normalised or dropped to `null`; the report must stay schema-valid JSON. Pinned in Task 3 tests.
- `--offline` and "no egress IPv4": zero requests, `claude_risk` still present as `unknown`, schema valid. Pinned in Task 6 tests.
- `--redact-ip`: no IPv4 of this host may appear anywhere, including `claude_risk.checked_ip` and the human line. Pinned in Task 6 tests.
- The risk service is down but IPinfo says the country is one Claude restricts: the answer must still be `high` with `restricted_region`, because that factor does not need the third party. Pinned in Task 4 tests.

---

### Task 1: Schema contract for the new source and `claude_risk`

**Files:**
- Modify: `schema/report.schema.json` (`$defs.intel_source` at ~920-958, its `source` enum at ~941, `ip_intelligence` at ~564-582, new `$defs.claude_risk` next to `intel_source`)
- Modify: `schema/examples/report-quick.example.json` (~128-158)

**Interfaces:**
- Produces: the JSON contract every later task must satisfy. Source enum gains `netcoffee`; each `intel_source` gains seven **optional** nullable fields `trust_score`, `residential`, `vpn`, `proxy`, `tor`, `crawler`, `abuser`; `ip_intelligence` gains required `claude_risk` with `level` (`low|medium|high|unknown`), `reasons` (array of the enum below), `restricted_region` (bool|null), `country` (string `^[A-Z]{2}$`|null), `trust_score` (integer|null), `residential` (bool|null), `checked_ip` (string|null), `note` (string, minLength 1); `additionalProperties: false` everywhere it already is.

- [ ] **Step 1: Extend `intel_source`.** Add `netcoffee` to the `source` enum. Add the seven property definitions: `trust_score` `{"type": ["integer","null"]}`, and the six flags `{"type": ["boolean","null"]}`. Do not touch `required` — these stay optional so RIPEstat/IPinfo/AbuseIPDB records remain valid.

- [ ] **Step 2: Add `$defs.claude_risk`.** `reasons.items.enum`: `restricted_region`, `tor_exit`, `crawler`, `abuse_history`, `low_trust_score`, `moderate_trust_score`, `vpn_or_proxy`, `hosting_asn`, `residential_unknown`, `no_data`, `source_unavailable`. Then add `"claude_risk": {"$ref": "#/$defs/claude_risk"}` to `ip_intelligence.properties` and `"claude_risk"` to its `required` list.

- [ ] **Step 3: Update the example.** Add the seven keys (all `null`) to the three existing source records, add a `netcoffee` record (`pass`, asn 64500, holder `Example Hosting GmbH`, country `DE`, `trust_score: 93`, `residential: true`, `hosting: false`, flags `false`), and add a `claude_risk` object: `level: "low"`, `reasons: []`, `restricted_region: false`, `country: "DE"`, `trust_score: 93`, `residential: true`, `checked_ip: "203.0.113.10"`, `note` = `"judgement by one third-party service (net.coffee); what Claude itself decides is unknown"`.

- [ ] **Step 4: Verify the schema and the example**

Run: `python3 -I tests/tools/validate_report.py schema/examples/*.json`
Expected: every example prints `valid`.

- [ ] **Step 5: Verify the new contract actually rejects bad values**

Run: copy the example to `/tmp/bad.json`, set `ip_intelligence.claude_risk.level` to `"severe"`, then `python3 -I tests/tools/validate_report.py /tmp/bad.json`
Expected: exit 1, `... level: 'severe' not in [...]`.

- [ ] **Step 6: Commit**

```bash
git add schema/report.schema.json schema/examples/report-quick.example.json
git commit -m "schema: add netcoffee source fields and claude_risk object"
```

---

### Task 2: i18n keys (English and Russian)

**Files:**
- Modify: `lib/i18n/en.sh` (after the `intel.*` block, ~223)
- Modify: `lib/i18n/ru.sh` (after the `intel.*` block, ~221)
- Test: `tests/unit/test_i18n.sh`

**Interfaces:**
- Produces: keys Task 3-5 use: `test.intel_netcoffee`, `intel.netcoffee_ok` (args: trust score, country), `report.claude_risk`, `claude_risk.level.<low|medium|high|unknown>` (no args), `claude_risk.reason.<code>` for each of the eleven reason codes (no args), `claude_risk.trust` (one arg).

- [ ] **Step 1: Add the failing assertions to `tests/unit/test_i18n.sh`** — after the existing English lookups: `assert_eq "low trust score" "$(msg claude_risk.reason.low_trust_score)"`, `assert_eq "Claude risk" "$(msg report.claude_risk)"`; in the Russian block: `assert_eq "риск для Claude" "$(msg report.claude_risk)"`. The existing parity loop then also covers argument counts.

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/unit/test_i18n.sh`
Expected: FAIL, keys echo back as their own names.

- [ ] **Step 3: Add the keys to both catalogs.** English: `test.intel_netcoffee='net.coffee'`, `intel.netcoffee_ok='trust score %s, %s'`, `report.claude_risk='Claude risk'`, `claude_risk.level.low='low'`, `...medium='medium'`, `...high='high'`, `...unknown='unknown'`, `claude_risk.reason.restricted_region='region restricted by Claude'`, `...tor_exit='Tor exit'`, `...crawler='known crawler'`, `...abuse_history='abuse history'`, `...low_trust_score='low trust score'`, `...moderate_trust_score='moderate trust score'`, `...vpn_or_proxy='VPN or proxy exit'`, `...hosting_asn='hosting (datacenter) IP'`, `...residential_unknown='residential property unknown'`, `...no_data='no data'`, `...source_unavailable='risk service did not answer'`, `claude_risk.trust='net.coffee trust score %s'`. Russian: translate all of them, keep `%s` counts identical.

- [ ] **Step 4: Run the test again**

Run: `bash tests/unit/test_i18n.sh`
Expected: `RESULT: OK`, no `bad=` output.

- [ ] **Step 5: Commit**

```bash
git add lib/i18n/en.sh lib/i18n/ru.sh tests/unit/test_i18n.sh
git commit -m "i18n: keys for the netcoffee source and claude risk"
```

---

### Task 3: `_intel_netcoffee` source in `lib/intel.sh`

**Files:**
- Modify: `lib/intel.sh` (URL constant near ~29; `_intel_source_json` ~107-125; `_intel_reset_attrs` ~127-130; new function after `_intel_abuseipdb` ~267; `_intel_skip_all` ~269-276; `qvk_intel_run` ~308-321)
- Test: `tests/unit/test_intel.sh` (fixtures ~34-39, assertions after ~103)

**Interfaces:**
- Consumes: `_intel_request tag url`, `_intel_classify`, `_intel_reason`, `_intel_emit source method endpoint status code reason hmsg hargs`, `_jstr`, `_jnum`, `_jbool`, `json_*`.
- Produces: `_intel_netcoffee <ip>`; test id `intel_netcoffee`; source name `netcoffee`; globals `QVK_NC_OK` (`1` when the answer parsed, else `0`), `QVK_NC_ASN`, `QVK_NC_HOLDER`, `QVK_NC_COUNTRY` (upper-case 2 letters or empty), `QVK_NC_TRUST` (0-100 or empty), `QVK_NC_RESID`, `QVK_NC_VPN`, `QVK_NC_PROXY`, `QVK_NC_TOR`, `QVK_NC_CRAWLER`, `QVK_NC_ABUSER` (`true`/`false`/empty). Also the seven new `A_*` attributes so `_intel_source_json` emits them for every source (`null` for the others).
- Endpoint recorded in the test record: `https://ip.net.coffee/api/iprisk/<ip>`, method `netcoffee_iprisk`.

- [ ] **Step 1: Write the failing test.** In `tests/unit/test_intel.sh` add `NC_OK` fixture — a real-shaped answer: `{"ip":"203.0.113.10","is_bogon":false,"is_datacenter":true,"isResidential":false,"is_vpn":false,"is_proxy":false,"is_tor":false,"is_crawler":false,"is_abuser":false,"asn":64500,"asOrganization":"Example Hosting GmbH","country":"Germany","countryCode":"de","trust_score":41,"rdns":"203-0-113-10.example.net"}`. Extend `intel_fixtures` with three optional positional args (rc, code, body, defaulting to `0 200 "$NC_OK"`) that stub `https://ip.net.coffee/api/iprisk/$IP`. Default scenario assertions:

```bash
assert_eq '"pass"' "$(tf intel_netcoffee status)" "netcoffee pass"
assert_eq '64500' "$(sf netcoffee asn)" "netcoffee asn"
assert_eq '"Example Hosting GmbH"' "$(sf netcoffee asn_holder)" "netcoffee holder"
assert_eq '"DE"' "$(sf netcoffee country)" "countryCode upper-cased"
assert_eq '41' "$(sf netcoffee trust_score)" "trust score parsed"
assert_eq 'false' "$(sf netcoffee residential)" "residential parsed"
assert_eq 'true' "$(sf netcoffee hosting)" "isResidential=false reported as hosting"
assert_eq 'null' "$(sf ripestat trust_score)" "other sources keep null"
assert_not_contains "$(cat "$R")" "203-0-113-10.example.net" "rdns is never copied"
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/unit/test_intel.sh`
Expected: FAIL on `netcoffee pass` (source missing), no change to other assertions.

- [ ] **Step 3: Implement `_intel_netcoffee`.** Copy the shape of `_intel_abuseipdb`: `_intel_reset_attrs`, set `QVK_NC_OK=0` and clear the `QVK_NC_*` globals, `_intel_request intel_netcoffee "$QVK_NETCOFFEE_URL$ip"`, `_intel_classify`, `_intel_emit` on failure (method `netcoffee_iprisk`, endpoint `"$QVK_NETCOFFEE_URL<ip>"`), then parse. Parsing rules: `cc=$(_jstr "$QC_BODY" countryCode)` upper-cased and kept only if `^[A-Z]{2}$`; `trust=$(_jnum "$QC_BODY" trust_score)` kept only if `^[0-9]+$` and ≤ 100; each flag via `_jbool` with key `is_vpn`/`is_proxy`/`is_tor`/`is_crawler`/`is_abuser`; `resid=$(_jbool "$QC_BODY" isResidential)`; `asn=$(_jnum "$QC_BODY" asn)`; holder `=$(_jstr "$QC_BODY" asOrganization)`. Treat the answer as usable only when at least one of `cc`, `trust`, or any flag is non-empty; otherwise `I_CODE=invalid_answer` and `_intel_emit ... unknown "$I_CODE"`. Copy the values into `QVK_NC_*` and set `QVK_NC_OK=1` before the success `_intel_emit` with `intel.netcoffee_ok "$trust${QVK_US}${cc:-?}"`. Add `A_TRUST/A_RESID/A_VPN/A_PROXY/A_TOR/A_CRAWLER/A_ABUSER` to `_intel_reset_attrs` and the matching seven keys to `_intel_source_json`; set `A_HOSTING=false` when `resid == false`. Add `netcoffee:netcoffee_iprisk` to the `_intel_skip_all` loop and call `_intel_netcoffee "$QVK_TARGET_IP"` last in `qvk_intel_run`.

- [ ] **Step 4: Add the failure-path assertions, then run**

```bash
intel_fixtures 0 200 "$NC_OK" 0 200 "$INFO_OK" 28 000 ''
assert_eq '"fail"' "$(tf intel_netcoffee status)" "timeout -> fail"
assert_eq '"timeout"' "$(tf intel_netcoffee reason_code)" "reason timeout"
assert_eq '2' "$(count_calls "https://ip.net.coffee/api/iprisk/$IP")" "transient failure retried exactly once"
intel_fixtures 0 200 "$NC_OK" 0 200 "$INFO_OK" 0 200 '<html>maintenance</html>'
assert_eq '"invalid_answer"' "$(tf intel_netcoffee reason_code)" "garbage body -> invalid_answer"
intel_fixtures 0 200 "$NC_OK" 0 200 "$INFO_OK" 0 403 'denied'
assert_eq '"http_403"' "$(tf intel_netcoffee reason_code)" "403 -> http_403"
assert_eq '1' "$(count_calls "https://ip.net.coffee/api/iprisk/$IP")" "403 is not retried"
```

Run: `bash tests/unit/test_intel.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/intel.sh tests/unit/test_intel.sh
git commit -m "intel: add netcoffee risk source"
```

---

### Task 4: `qvk_claude_risk_evaluate` rule ladder

**Files:**
- Modify: `lib/intel.sh` (new constant and function after `qvk_geo_consensus` ~306)
- Test: `tests/unit/test_intel.sh`

**Interfaces:**
- Consumes: `QVK_NC_*`, `QVK_GEO[ipinfo]` (array declared at ~22), `QVK_TARGET_IP`, `QVK_OFFLINE`.
- Produces: `qvk_claude_risk_evaluate` (no arguments) setting `QVK_CLAUDE_RISK_JSON` (the object for `ip_intelligence.claude_risk`) and, for the human line, `QVK_CLAUDE_RISK_LEVEL`, `QVK_CLAUDE_RISK_REASONS` (array of reason codes), `QVK_CLAUDE_RISK_COUNTRY`, `QVK_CLAUDE_RISK_TRUST`, `QVK_CLAUDE_RISK_RESTRICTED`. Constant `QVK_CLAUDE_RESTRICTED="CN HK MO RU KP IR SY CU BY VE"`.

- [ ] **Step 1: Write the failing test matrix.** In `tests/unit/test_intel.sh` add fixtures at file scope and assertions per scenario, using `jf ip_intelligence.claude_risk.level` and `jf ip_intelligence.claude_risk.reasons`:
  - `NC_OK` (hosting, trust 41) → `"high"`, reasons contain `low_trust_score` and `hosting_asn`.
  - clean residential: `isResidential:true`, `trust_score:92`, no flags, country `de` → `"low"`, reasons `[]`.
  - restricted: country `ru`, `isResidential:true`, `trust_score:88` → `"high"`, reasons contain `restricted_region`.
  - tor: `is_tor:true`, `trust_score:95`, residential true → `"high"`, reasons contain `tor_exit`.
  - abuser: `is_abuser:true`, `trust_score:88`, residential true → `"medium"`, reasons contain `abuse_history` and not `low_trust_score`.
  - netcoffee fails (`28 000`) while IPinfo is DE → `"unknown"`, reasons contain `source_unavailable`.
  - netcoffee fails while IPinfo country is `RU` (add `INFO_RU` fixture) → `"high"`, reasons contain `restricted_region`.
  - `restricted_region` is `false` for DE and `null` when no source reported a country.
  - `checked_ip` equals `"203.0.113.10"`.

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/unit/test_intel.sh`
Expected: FAIL — schema validation reports the missing `claude_risk` key.

- [ ] **Step 3: Implement.** Country resolution order: `QVK_NC_COUNTRY`, else `QVK_GEO[ipinfo]`, else a single value from `QVK_GEO` if every source agrees. Compute `restricted` when a country is known. Then build the reason set from all true conditions (not just the first): high reasons `restricted_region`, `tor_exit`, `crawler`, `low_trust_score` (trust non-empty and < 50); medium reasons `abuse_history` (abuser true), `moderate_trust_score` (50-79), `vpn_or_proxy`, `hosting_asn` (`residential == false`), `residential_unknown` (trust ≥ 80, residential empty, no other medium reason). Level: `high` if any high reason, else `medium` if any medium reason, else `low` if trust ≥ 80 and `residential == true`, else if `QVK_NC_OK == 0` → `unknown` [`source_unavailable`], else `unknown` [`no_data`]. Emit `note` as the literal English sentence from the spec. Set the `QVK_CLAUDE_RISK_*` globals in the same function so the human line never re-parses JSON.

- [ ] **Step 4: Run the tests**

Run: `bash tests/unit/test_intel.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/intel.sh tests/unit/test_intel.sh
git commit -m "intel: derive claude_risk from IP facts"
```

---

### Task 5: Wire it into JSON and human output

**Files:**
- Modify: `qvk` (~266-271, after `qvk_geo_consensus`)
- Modify: `lib/report.sh` (~112 `ipintel=`, new `_qvk_human_claude_risk` next to `_qvk_human_geo` ~282, call it in `_qvk_report_human_raw` after `_qvk_human_geo` ~335)
- Test: `tests/unit/test_intel.sh`

**Interfaces:**
- Consumes: `QVK_CLAUDE_RISK_JSON` and the `QVK_CLAUDE_RISK_*` globals from Task 4; `_qvk_human_field key value` (pads to 18); i18n keys from Task 2.
- Produces: `ip_intelligence.claude_risk` in JSON; one human line `Claude risk  <level> — <reasons> (net.coffee trust score N)`; omitted only when `QVK_CLAUDE_RISK_LEVEL` is empty.

- [ ] **Step 1: Failing assertions.** In `tests/unit/test_intel.sh`, after the existing JSON assertions on the default scenario: `assert_eq '"medium"'`/`'"high"'` per the fixture in use for `jf ip_intelligence.claude_risk.level`, `assert_eq '"DE"' "$(jf ip_intelligence.claude_risk.country)"`, and for the human output `assert_contains "$human" "Claude risk" "human risk line"`, `assert_contains "$human" "low trust score"`, plus a Russian run asserting `assert_contains "$human" "риск для Claude"`.

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/unit/test_intel.sh`
Expected: FAIL — `claude_risk` missing from JSON (schema rejects the report), no human line.

- [ ] **Step 3: Implement.** In `qvk`, call `qvk_claude_risk_evaluate` after `qvk_geo_consensus` and before `qvk_verdict_evaluate`, unconditionally (it also handles offline and no-IP). In `lib/report.sh` add `claude_risk "$QVK_CLAUDE_RISK_JSON"` to the `ipintel=` object, and write `_qvk_human_claude_risk`: skip when the level is empty; render `"<level> — <reason1>, <reason2>"` from `QVK_CLAUDE_RISK_REASONS` via `msg claude_risk.reason.$code`, append `($(msg claude_risk.trust "$QVK_CLAUDE_RISK_TRUST"))` when trust is known, and print it with `_qvk_human_field report.claude_risk "$text"`. Prefix the level with `qvk_paint red|yellow|green` for high/medium/low/unknown (unknown yellow).

- [ ] **Step 4: Run the full offline suite**

Run: `bash tests/run.sh`
Expected: `RESULT: OK`.

- [ ] **Step 5: Commit**

```bash
git add qvk lib/report.sh tests/unit/test_intel.sh
git commit -m "report: emit claude_risk in JSON and human output"
```

---

### Task 6: Privacy, offline and no-IP coverage

**Files:**
- Test: `tests/unit/test_intel.sh`

**Interfaces:**
- Consumes: everything from Tasks 3-5. No new code expected; if an assertion fails, fix the owning function rather than the test.

- [ ] **Step 1: Add the assertions.** Under the existing `--redact-ip` block: `assert_not_contains "$body" "203.0.113"`, `assert_eq 'null' "$(jf ip_intelligence.claude_risk.checked_ip)"`, `assert_contains "$human" "Claude risk"`. Under `--offline`: `assert_eq '"unknown"' "$(jf ip_intelligence.claude_risk.level)"`, `assert_eq '"no_data"' "$(jf ip_intelligence.claude_risk.reasons.0)"`, `assert_eq '"skipped"' "$(tf intel_netcoffee status)"`, and the existing "no curl requests at all" assertion still holds. Under the no-egress-IP scenario: `assert_eq '"unknown"' "$(jf ip_intelligence.claude_risk.level)"` and `assert_eq 0 "$(count_calls ip.net.coffee)"`.

- [ ] **Step 2: Run it**

Run: `bash tests/unit/test_intel.sh`
Expected: PASS. If `checked_ip` is not redacted, the redaction map does not know that address — register it where `qvk_redact` builds the map instead of special-casing this field.

- [ ] **Step 3: Commit**

```bash
git add tests/unit/test_intel.sh
git commit -m "test: claude_risk privacy, offline and no-IP paths"
```

---

### Task 7: Document the rules and amend the design notes

**Files:**
- Modify: `docs/methodology.md` (new subsection under the IP-intelligence part)
- Modify: `docs/security.md` (destination table ~28-35)
- Modify: `docs/superpowers/specs/2026-11-09-claude-ip-risk-design.md` (rule list and the human-line note)
- Optionally: `README.md` (one row/line where the report sections are described)

**Interfaces:**
- Produces: the human-facing rules that make the number defensible: source, date of the restricted list, the fact that a plain VPS is `medium` at best, and the caveat that the third party's judgement is not Claude's decision.

- [ ] **Step 1: `docs/methodology.md`.** Paste the rule ladder and reason codes from the spec, state the restricted list (CN, HK, MO, RU, KP, IR, SY, CU, BY, VE) with `source: net.coffee frontend, checked 2026-11-09`, note that a hosting IP is `medium` at best, and that `trust_score` is one provider's opinion.

- [ ] **Step 2: `docs/security.md`.** Add a row to "What leaves the machine": `ip.net.coffee (`/api/iprisk`)` | the VPS's public IP. Mention that it is an undocumented third-party endpoint whose failure only degrades the report.

- [ ] **Step 3: Amend the spec.** In the rules section add `residential_unknown` as the medium reason for "trust ≥ 80, residential property unknown", and change the human-output note: the line is always printed, with `unknown — no data`/`source did not answer` when nothing is known.

- [ ] **Step 4: Verify**

Run: `bash tests/run.sh` and `QVK_REQUIRE_SHELLCHECK=1 bash tests/run.sh`
Expected: both `RESULT: OK`.

- [ ] **Step 5: Commit**

```bash
git add docs/methodology.md docs/security.md docs/superpowers/specs/2026-11-09-claude-ip-risk-design.md README.md
git commit -m "docs: claude risk rules, data leaving the machine, spec amendment"
```

---

## Self-review notes

- Spec coverage: source + flags (Tasks 1, 3), derived object and rules (Tasks 1, 4), human/JSON output (Task 5), privacy and degradation (Tasks 3, 6), documentation (Task 7). The spec's "no new section, no verdict" is preserved — `ip_intelligence` stays informational and `summary.verdicts` is untouched.
- Deliberate deviation recorded for the implementer: the design said the human line may be omitted when nothing is known; Task 5 prints it always (`unknown — no data`), and Task 7 amends the spec.
- Type consistency: `QVK_NC_*` (Task 3) → `QVK_CLAUDE_RISK_*` (Task 4) → report and human line (Task 5); source name `netcoffee`, test id `intel_netcoffee`, method `netcoffee_iprisk` are used identically everywhere.
- Not in this plan: the version bump and release — see `2026-11-09-release-hygiene.md`.
