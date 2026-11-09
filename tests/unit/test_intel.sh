#!/usr/bin/env bash
# IP intelligence (RIPEstat, IPinfo, AbuseIPDB), geo consensus and HTTP
# reachability of services, against canned curl responses. No real network.
set -uo pipefail
# shellcheck source=tests/lib/assert.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"
# shellcheck source=tests/lib/hostfix.sh
source "$REPO_ROOT/tests/lib/hostfix.sh"
# shellcheck source=tests/lib/curlfix.sh
source "$REPO_ROOT/tests/lib/curlfix.sh"

PY=$(find_python) || {
  echo "python 3 is required" >&2
  exit 1
}
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
unset NO_COLOR LANG LC_ALL LC_MESSAGES IPINFO_TOKEN ABUSEIPDB_API_KEY
export QVK_RETRY_DELAY_S=0
CF="$WORK/curlfix"
R="$WORK/r.json"

IP=203.0.113.10
RIPE_URL="https://stat.ripe.net/data/prefix-overview/data.json?resource=$IP"
INFO_URL="https://ipinfo.io/$IP/json"
ABUSE_URL="https://api.abuseipdb.com/api/v2/check?ipAddress=$IP&maxAgeInDays=90"

RIPE_OK='{"messages":[],"version":"1.3","data_call_status":"supported","status":"ok","status_code":200,"data":{"is_less_specific":false,"announced":true,"asns":[{"asn":64500,"holder":"EXAMPLE-AS - Example Hosting GmbH"}],"related_prefixes":[],"resource":"203.0.113.0/24","type":"prefix","block":{"resource":"203.0.0.0/8","desc":"Administered by ARIN","name":"IANA"}}}'
RIPE_UNANNOUNCED='{"status":"ok","data":{"announced":false,"asns":[],"resource":"203.0.113.0/24","type":"prefix"}}'
INFO_OK=$'{\n  "ip": "203.0.113.10",\n  "hostname": "203-0-113-10.static.example.net",\n  "city": "Frankfurt",\n  "region": "Hesse",\n  "country": "DE",\n  "loc": "50.1,8.6",\n  "org": "AS64500 Example Hosting GmbH",\n  "timezone": "Europe/Berlin"\n}'
INFO_HOSTING=$'{\n  "ip": "203.0.113.10",\n  "country": "DE",\n  "org": "AS64500 Example Hosting GmbH",\n  "hosting": true\n}'
ABUSE_OK='{"data":{"ipAddress":"203.0.113.10","isPublic":true,"abuseConfidenceScore":12,"countryCode":"DE","usageType":"Data Center/Web Hosting/Transit","isp":"Example Hosting","totalReports":3}}'
NC_URL="https://ip.net.coffee/api/iprisk/$IP"
NC_OK='{"ip":"203.0.113.10","cidr":"203.0.113.0/24","is_bogon":false,"is_datacenter":true,"isResidential":false,"is_vpn":false,"is_proxy":false,"is_tor":false,"is_crawler":false,"is_abuser":false,"asn":64500,"asOrganization":"Example Hosting GmbH","country":"Germany","countryCode":"de","trust_score":41,"rdns":"203-0-113-10.example.net"}'
NC_CLEAN='{"ip":"203.0.113.10","isResidential":true,"is_vpn":false,"is_proxy":false,"is_tor":false,"is_crawler":false,"is_abuser":false,"asn":64500,"asOrganization":"Example Home ISP","country":"Germany","countryCode":"de","trust_score":92}'
NC_RESTRICTED='{"ip":"203.0.113.10","isResidential":true,"is_vpn":false,"is_proxy":false,"is_tor":false,"is_crawler":false,"is_abuser":false,"country":"Russia","countryCode":"ru","trust_score":88}'
NC_TOR='{"ip":"203.0.113.10","isResidential":true,"is_tor":true,"is_vpn":false,"is_proxy":false,"is_crawler":false,"is_abuser":false,"countryCode":"de","trust_score":95}'
NC_ABUSER='{"ip":"203.0.113.10","isResidential":true,"is_abuser":true,"is_vpn":false,"is_proxy":false,"is_tor":false,"is_crawler":false,"countryCode":"de","trust_score":88}'
INFO_RU=$'{\n  "ip": "203.0.113.10",\n  "country": "RU",\n  "org": "AS64500 Example Hosting GmbH"\n}'

# intel_base [ripe_rc ripe_code ripe_body info_rc info_code info_body nc_rc nc_code nc_body]
intel_fixtures() {
  fix "" "$RIPE_URL" "${1:-0}" "${2:-200}" "${3:-$RIPE_OK}"
  fix "" "$INFO_URL" "${4:-0}" "${5:-200}" "${6:-$INFO_OK}"
  fix "" "$ABUSE_URL" 0 200 "$ABUSE_OK"
  fix "" "$NC_URL" "${7:-0}" "${8:-200}" "${9:-$NC_OK}"
}

# risk_fixtures <nc rc> <nc body> [info body]: one run with a chosen netcoffee answer
risk_fixtures() {
  scenario 0 0 0
  services_fixtures
  intel_fixtures 0 200 "$RIPE_OK" 0 200 "${3:-$INFO_OK}" "$1" 200 "$2"
}

# services_fixtures: gentle HTTP checks of the default endpoint list
services_fixtures() {
  fix "" https://api.openai.com/v1/models 0 401 '{"error":"auth"}'
  fix "" https://chatgpt.com/cdn-cgi/trace 0 200 $'ip=203.0.113.10\nloc=DE\n'
  fix "" https://api.anthropic.com/v1/models 0 401 '{}'
  fix "" https://gemini.google.com/ 0 200 '<html>'
  fix "" https://www.youtube.com/robots.txt 0 200 'User-agent: *'
  fix "" https://www.netflix.com/robots.txt 0 200 'User-agent: *'
  fix "" https://open.spotify.com/robots.txt 0 200 'User-agent: *'
  fix "" https://ya.ru/robots.txt 0 200 'User-agent: *'
  fix "" https://vk.com/robots.txt 0 200 'User-agent: *'
  fix "" https://www.gosuslugi.ru/robots.txt 0 200 'User-agent: *'
}

run_json() {
  : >"$QVK_STUB_LOG"   # call counts are per run
  "$REPO_ROOT/qvk" run --format json "$@" >"$R" 2>"$WORK/err"
}
validate() { "$PY" -I "$REPO_ROOT/tests/tools/validate_report.py" "$R" >/dev/null; }
jf() {
  "$PY" -I -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
for k in sys.argv[2].split("."):
    d=d[int(k)] if isinstance(d,list) else d[k]
print(json.dumps(d, ensure_ascii=False))' "$R" "$1"
}
tf() {
  "$PY" -I -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
t=[x for x in d["tests"] if x["id"]==sys.argv[2]]
v=t[0] if t else None
for k in (sys.argv[3].split(".") if v is not None else []):
    v=v.get(k) if isinstance(v,dict) else None
print(json.dumps(v, ensure_ascii=False))' "$R" "$1" "$2"
}
# source record of ip_intelligence.sources by name
sf() {
  "$PY" -I -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
s=[x for x in d["ip_intelligence"]["sources"] if x["source"]==sys.argv[2]]
print(json.dumps(s[0][sys.argv[3]] if s else "MISSING", ensure_ascii=False))' "$R" "$1" "$2"
}
count_calls() { grep -cF -- "$1" "$QVK_STUB_LOG"; }

echo "# default: RIPEstat + IPinfo answer, AbuseIPDB has no key"
host debian12-kvm-amd64
scenario 0 0 0
intel_fixtures
services_fixtures
run_json
assert_eq 0 "$?" "run exits 0"
assert_true "schema" validate
assert_eq '"pass"' "$(tf intel_ripestat status)" "ripestat pass"
assert_eq '64500' "$(sf ripestat asn)" "asn parsed"
assert_eq '"EXAMPLE-AS - Example Hosting GmbH"' "$(sf ripestat asn_holder)" "holder parsed"
assert_eq '"203.0.113.0/24"' "$(sf ripestat prefix)" "announced prefix parsed"
assert_eq 'true' "$(sf ripestat announced)" "announced"
assert_eq '"pass"' "$(tf intel_ipinfo status)" "ipinfo pass"
assert_eq '"DE"' "$(sf ipinfo country)" "ipinfo country"
assert_eq '64500' "$(sf ipinfo asn)" "ipinfo asn from org"
assert_eq '"203-0-113-10.static.example.net"' "$(sf ipinfo hostname)" "hostname kept without --redact-ip"
assert_eq 'null' "$(sf ipinfo hosting)" "hosting unknown without a token: null, not false"
assert_eq '"skipped"' "$(tf intel_abuseipdb status)" "abuseipdb skipped without key"
assert_eq '"no_api_key"' "$(tf intel_abuseipdb reason_code)" "reason no_api_key"
assert_eq '"DE"' "$(jf ip_intelligence.geo_consensus.countries.0)" "geo consensus country"
assert_eq 'false' "$(jf ip_intelligence.geo_consensus.geo_conflict)" "no geo conflict"
assert_eq '3' "$(jf ip_intelligence.geo_consensus.sources | "$PY" -I -c 'import json,sys; print(len(json.load(sys.stdin)))')" \
  "three independent country sources (cloudflare trace, ipinfo, chatgpt trace)"
assert_eq '"suitable"' "$(jf summary.verdicts.target_self_check.verdict)" "intel does not change the verdict"
human=$("$REPO_ROOT/qvk" run 2>/dev/null)
assert_contains "$human" "IP intelligence" "human intel section"
assert_contains "$human" "AS64500 EXAMPLE-AS - Example Hosting GmbH, prefix 203.0.113.0/24" "human ripestat line"
assert_contains "$human" "DE (3 sources agree)" "human geo consensus"
assert_contains "$human" "skipped: set ABUSEIPDB_API_KEY to enable" "human abuseipdb hint"
assert_eq '"pass"' "$(tf intel_netcoffee status)" "netcoffee pass"
assert_eq '64500' "$(sf netcoffee asn)" "netcoffee asn"
assert_eq '"Example Hosting GmbH"' "$(sf netcoffee asn_holder)" "netcoffee holder"
assert_eq '"DE"' "$(sf netcoffee country)" "countryCode upper-cased"
assert_eq '41' "$(sf netcoffee trust_score)" "trust score parsed"
assert_eq 'false' "$(sf netcoffee residential)" "residential parsed"
assert_eq 'true' "$(sf netcoffee hosting)" "isResidential=false reported as hosting"
assert_eq 'null' "$(sf ripestat trust_score)" "other sources keep null"
assert_not_contains "$(cat "$R")" "203-0-113-10.example.net" "rdns is never copied"
assert_contains "$human" "Claude risk" "human risk line"
assert_contains "$human" "low trust score" "risk reason rendered"

echo "# HTTP reachability classification"
fix "" https://vk.com/robots.txt 0 403 'forbidden'
fix "" https://www.netflix.com/robots.txt 0 429 'slow down'
fix "" https://open.spotify.com/robots.txt 28 000 ''
fix "" https://gemini.google.com/ 0 503 'unavailable'
fix "" https://www.gosuslugi.ru/robots.txt 0 404 'nf'
run_json
assert_true "schema" validate
assert_eq '"pass"' "$(tf http_ai_openai_api status)" "401 means reachable (auth required)"
assert_eq '"reachable"' "$(tf http_ai_openai_api http_outcome)" "outcome reachable"
assert_eq '"warn"' "$(tf http_ru_hosted_vk status)" "403 -> warn"
assert_eq '"http_denied"' "$(tf http_ru_hosted_vk http_outcome)" "outcome http_denied"
assert_eq '"http_403"' "$(tf http_ru_hosted_vk reason_code)" "reason http_403"
assert_contains "$(tf http_ru_hosted_vk reason)" "reject foreign IPs" "RU 403 explained as the service's own policy"
assert_eq '"rate_limited"' "$(tf http_media_netflix http_outcome)" "429 -> rate_limited"
assert_eq '"http_429"' "$(tf http_media_netflix reason_code)" "reason http_429"
assert_eq '"fail"' "$(tf http_media_spotify status)" "timeout -> fail"
assert_eq '"network_error"' "$(tf http_media_spotify http_outcome)" "outcome network_error"
assert_eq '"timeout"' "$(tf http_media_spotify reason_code)" "reason timeout"
assert_eq '"warn"' "$(tf http_ai_gemini status)" "503 -> warn"
assert_eq '"unknown"' "$(tf http_ai_gemini http_outcome)" "503 outcome unknown"
assert_eq '"pass"' "$(tf http_ru_hosted_gosuslugi status)" "404 on robots.txt still means the host answered"
assert_eq '{"method":"cloudflare_trace_loc","country":"DE"}' \
  "$(tf http_ai_chatgpt details.region_signal | tr -d ' ')" "region signal from cdn-cgi/trace"
assert_eq '"suitable"' "$(jf summary.verdicts.target_self_check.verdict)" "service denials do not make the VPS unsuitable"
human=$("$REPO_ROOT/qvk" run --lang ru 2>/dev/null)
assert_contains "$human" "HTTP ru_hosted/vk" "human label for service check"
assert_contains "$human" "решение сервиса, а не сетевая фильтрация" "russian 403 wording"
assert_contains "$human" "риск для Claude" "russian risk label"

echo "# geo conflict between services"
scenario 0 0 0
intel_fixtures
services_fixtures
fix "" https://chatgpt.com/cdn-cgi/trace 0 200 $'ip=203.0.113.10\nloc=US\n'
run_json
assert_true "schema" validate
assert_eq 'true' "$(jf ip_intelligence.geo_consensus.geo_conflict)" "geo_conflict true"
assert_eq '["DE","US"]' "$(jf ip_intelligence.geo_consensus.countries | tr -d ' ')" "both countries listed"
assert_eq '"suitable"' "$(jf summary.verdicts.target_self_check.verdict)" "geo conflict is not a failure"
human=$("$REPO_ROOT/qvk" run 2>/dev/null)
assert_contains "$human" "sources disagree:" "human geo conflict"

echo "# keys: used when set, never leaked"
scenario 0 0 0
intel_fixtures
services_fixtures
ABUSEIPDB_API_KEY=SECRET-ABUSE-KEY-123 IPINFO_TOKEN=SECRET-INFO-TOKEN-456 run_json
assert_true "schema" validate
assert_eq '"pass"' "$(tf intel_abuseipdb status)" "abuseipdb pass with key"
assert_eq '12' "$(sf abuseipdb abuse_confidence_pct)" "abuse score parsed"
assert_eq '3' "$(sf abuseipdb abuse_reports)" "abuse reports parsed"
assert_eq '"Data Center/Web Hosting/Transit"' "$(sf abuseipdb usage_type)" "usage type"
assert_not_contains "$(cat "$R")" "SECRET-ABUSE-KEY-123" "abuse key absent from report"
assert_not_contains "$(cat "$R")" "SECRET-INFO-TOKEN-456" "ipinfo token absent from report"
assert_not_contains "$(cat "$QVK_STUB_LOG")" "SECRET-" "secrets never on a command line"
assert_not_contains "$(cat "$WORK/err")" "SECRET-" "secrets absent from stderr"
assert_contains "$(grep -F "ipAddress=" "$QVK_STUB_LOG")" "-H @" "key passed through a header file"
fix "" "$INFO_URL" 0 200 "$INFO_HOSTING"
ABUSEIPDB_API_KEY=SECRET-ABUSE-KEY-123 run_json
assert_eq 'true' "$(sf ipinfo hosting)" "hosting=true parsed"
assert_eq '"pass"' "$(tf intel_ipinfo status)" "hosting=true is not a failure"

echo "# rate limits and outages never break the run"
scenario 0 0 0
intel_fixtures 0 200 "$RIPE_OK" 0 429 'rate limit exceeded'
services_fixtures
run_json
assert_eq 0 "$?" "run exits 0 with a rate-limited source"
assert_true "schema" validate
assert_eq '"skipped"' "$(tf intel_ipinfo status)" "429 -> skipped"
assert_eq '"rate_limited"' "$(tf intel_ipinfo reason_code)" "reason rate_limited"
assert_eq '"pass"' "$(tf intel_ripestat status)" "other sources unaffected"
assert_eq '1' "$(count_calls "$INFO_URL")" "429 is not retried"
assert_eq '"suitable"' "$(jf summary.verdicts.target_self_check.verdict)" "verdict unaffected"

intel_fixtures 28 000 '' 0 403 'bad token'
run_json
assert_true "schema" validate
assert_eq '"fail"' "$(tf intel_ripestat status)" "timeout -> fail"
assert_eq '"timeout"' "$(tf intel_ripestat reason_code)" "reason timeout"
assert_eq '2' "$(count_calls "$RIPE_URL")" "transient failure retried exactly once"
assert_eq '"unknown"' "$(tf intel_ipinfo status)" "403 -> unknown"
assert_eq '"http_403"' "$(tf intel_ipinfo reason_code)" "reason http_403"
assert_eq '1' "$(count_calls "$INFO_URL")" "403 is not retried"
assert_eq '"suitable"' "$(jf summary.verdicts.target_self_check.verdict)" "outage of intel APIs does not change the verdict"

intel_fixtures 0 200 '<html>maintenance</html>' 0 200 '{"unexpected":true}'
run_json
assert_true "schema" validate
assert_eq '"unknown"' "$(tf intel_ripestat status)" "garbage -> unknown"
assert_eq '"invalid_answer"' "$(tf intel_ripestat reason_code)" "reason invalid_answer"
assert_eq '"invalid_answer"' "$(tf intel_ipinfo reason_code)" "ipinfo invalid_answer"

echo "# netcoffee failure modes"
scenario 0 0 0
services_fixtures
intel_fixtures 0 200 "$RIPE_OK" 0 200 "$INFO_OK" 28 000 ''
run_json
assert_true "schema" validate
assert_eq '"fail"' "$(tf intel_netcoffee status)" "timeout -> fail"
assert_eq '"timeout"' "$(tf intel_netcoffee reason_code)" "reason timeout"
assert_eq '2' "$(count_calls "$NC_URL")" "transient failure retried exactly once"
intel_fixtures 0 200 "$RIPE_OK" 0 200 "$INFO_OK" 0 200 '<html>maintenance</html>'
run_json
assert_eq '"unknown"' "$(tf intel_netcoffee status)" "garbage -> unknown"
assert_eq '"invalid_answer"' "$(tf intel_netcoffee reason_code)" "reason invalid_answer"
intel_fixtures 0 200 "$RIPE_OK" 0 200 "$INFO_OK" 0 403 'denied'
run_json
assert_eq '"http_403"' "$(tf intel_netcoffee reason_code)" "403 -> http_403"
assert_eq '1' "$(count_calls "$NC_URL")" "403 is not retried"

intel_fixtures 0 200 "$RIPE_UNANNOUNCED"
run_json
assert_eq '"warn"' "$(tf intel_ripestat status)" "unannounced prefix -> warn"
assert_eq 'false' "$(sf ripestat announced)" "announced=false recorded"
assert_eq 'null' "$(sf ripestat asn)" "no asn when unannounced"

echo "# claude risk levels and reasons"
risk_fixtures 0 "$NC_OK"
run_json
assert_true "schema" validate
assert_eq '"high"' "$(jf ip_intelligence.claude_risk.level)" "hosting + low score -> high"
assert_eq '["low_trust_score","hosting_asn"]' "$(jf ip_intelligence.claude_risk.reasons | tr -d ' ')" "reasons listed in a stable order"
assert_eq '"DE"' "$(jf ip_intelligence.claude_risk.country)" "country recorded"
assert_eq 'false' "$(jf ip_intelligence.claude_risk.restricted_region)" "not a restricted region"
assert_eq '41' "$(jf ip_intelligence.claude_risk.trust_score)" "trust score recorded"
assert_eq 'false' "$(jf ip_intelligence.claude_risk.residential)" "residential property recorded"
assert_eq '"203.0.113.10"' "$(jf ip_intelligence.claude_risk.checked_ip)" "checked ip recorded"

risk_fixtures 0 "$NC_CLEAN"
run_json
assert_true "schema" validate
assert_eq '"low"' "$(jf ip_intelligence.claude_risk.level)" "clean residential IP -> low"
assert_eq '[]' "$(jf ip_intelligence.claude_risk.reasons | tr -d ' ')" "no reasons for a clean IP"

risk_fixtures 0 "$NC_RESTRICTED"
run_json
assert_true "schema" validate
assert_eq '"high"' "$(jf ip_intelligence.claude_risk.level)" "restricted region -> high"
assert_eq '["restricted_region"]' "$(jf ip_intelligence.claude_risk.reasons | tr -d ' ')" "restricted region reason"
assert_eq 'true' "$(jf ip_intelligence.claude_risk.restricted_region)" "restricted flag set"

risk_fixtures 0 "$NC_TOR"
run_json
assert_eq '"high"' "$(jf ip_intelligence.claude_risk.level)" "tor exit -> high"
assert_eq '["tor_exit"]' "$(jf ip_intelligence.claude_risk.reasons | tr -d ' ')" "tor reason"

risk_fixtures 0 "$NC_ABUSER"
run_json
assert_eq '"medium"' "$(jf ip_intelligence.claude_risk.level)" "abuse history -> medium"
assert_eq '["abuse_history"]' "$(jf ip_intelligence.claude_risk.reasons | tr -d ' ')" "abuse reason"

risk_fixtures 28 ''
run_json
assert_true "schema" validate
assert_eq '"unknown"' "$(jf ip_intelligence.claude_risk.level)" "risk service down -> unknown"
assert_eq '["source_unavailable"]' "$(jf ip_intelligence.claude_risk.reasons | tr -d ' ')" "source_unavailable reason"

risk_fixtures 28 '' "$INFO_RU"
run_json
assert_true "schema" validate
assert_eq '"high"' "$(jf ip_intelligence.claude_risk.level)" "restricted country known without the risk service -> high"
assert_eq '["restricted_region"]' "$(jf ip_intelligence.claude_risk.reasons | tr -d ' ')" "region reason without the risk service"

echo "# --redact-ip"
scenario 0 0 0
intel_fixtures
services_fixtures
run_json --redact-ip
assert_true "schema" validate
body=$(cat "$R")
assert_not_contains "$body" "203.0.113" "no part of the address or its prefix in the report"
assert_not_contains "$body" "static.example.net" "reverse DNS removed"
assert_eq 'null' "$(sf ripestat prefix)" "prefix removed"
assert_eq 'null' "$(sf ipinfo hostname)" "hostname removed"
assert_eq '64500' "$(sf ripestat asn)" "ASN kept"
assert_eq '"DE"' "$(sf ipinfo country)" "country kept"
assert_eq 'true' "$(jf ip_intelligence.claude_risk.checked_ip | grep -qE '"<ip-[0-9]+>"' && echo true)" "checked_ip replaced by a redaction label"
assert_contains "$human" "Claude risk" "human risk line survives redaction"
human=$("$REPO_ROOT/qvk" run --redact-ip 2>/dev/null)
assert_not_contains "$human" "203.0.113" "human output has no address or prefix"
assert_contains "$human" "AS64500 EXAMPLE-AS - Example Hosting GmbH" "human ripestat line without prefix"

echo "# --offline: nothing is queried"
run_json --offline
assert_true "schema" validate
assert_eq '"skipped"' "$(tf intel_ripestat status)" "ripestat skipped"
assert_eq '"offline_mode"' "$(tf intel_ipinfo reason_code)" "reason offline_mode"
assert_eq 'null' "$(jf ip_intelligence.geo_consensus)" "no geo consensus offline"
assert_eq '"offline_mode"' "$(tf http_ai_openai_api reason_code)" "service checks skipped offline"
assert_eq '"unknown"' "$(jf ip_intelligence.claude_risk.level)" "no risk level offline"
assert_eq '["no_data"]' "$(jf ip_intelligence.claude_risk.reasons | tr -d ' ')" "no_data reason offline"
assert_eq '"skipped"' "$(tf intel_netcoffee status)" "netcoffee skipped offline"
assert_eq '"offline_mode"' "$(tf intel_netcoffee reason_code)" "reason offline_mode"
assert_eq 0 "$(grep '^curl ' "$QVK_STUB_LOG" | grep -vc '^curl --version$')" "no curl requests at all"

echo "# no egress IP: intel has nothing to look up"
scenario 7 0 0
services_fixtures
run_json
assert_true "schema" validate
assert_eq '"skipped"' "$(tf intel_ripestat status)" "ripestat skipped"
assert_eq '"not_applicable"' "$(tf intel_ripestat reason_code)" "reason not_applicable"
assert_eq 0 "$(count_calls stat.ripe.net)" "no intel request without an address"
assert_eq '"unknown"' "$(jf ip_intelligence.claude_risk.level)" "no risk level without an address"
assert_eq '["no_data"]' "$(jf ip_intelligence.claude_risk.reasons | tr -d ' ')" "no_data reason without an address"
assert_eq 'null' "$(jf ip_intelligence.claude_risk.checked_ip)" "no checked ip without an address"
assert_eq 0 "$(count_calls ip.net.coffee)" "no risk request without an address"

finish_tests
