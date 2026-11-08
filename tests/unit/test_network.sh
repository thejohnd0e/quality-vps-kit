#!/usr/bin/env bash
# Network checks from the target (egress IP, NAT, HTTPS timing, DNS, RTT to RU,
# clock offset) and the target_self_check verdict, against canned curl
# responses. No real network access.
set -uo pipefail
# shellcheck source=tests/lib/assert.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"
# shellcheck source=tests/lib/hostfix.sh
source "$REPO_ROOT/tests/lib/hostfix.sh"

PY=$(find_python) || {
  echo "python 3 is required" >&2
  exit 1
}
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
unset NO_COLOR LANG LC_ALL LC_MESSAGES
CF="$WORK/curlfix"
CONFIG="$REPO_ROOT/config/endpoints.tsv"
R="$WORK/r.json"

# fix <family|""> <url> <curl exit> <http code> <body> [time_connect seconds]
fix() {
  local fam=$1 url=$2 rc=$3 code=$4 body=$5 conn=${6:-0.025000} key
  key=$(printf '%s %s' "$fam" "$url" | tr -c 'A-Za-z0-9._-' '_')
  case $rc in
    0) printf '%s 0.004000 %s 0.060000 0.090000 0.091000 %d 300 80 192.0.2.80\n' \
      "$code" "$conn" "${#body}" >"$CF/$key.w" ;;
    6) printf '000 0.000000 0.000000 0.000000 0.000000 0.010000 0 0 0 \n' >"$CF/$key.w" ;;
    7 | 28) printf '000 0.004000 0.000000 0.000000 0.000000 3.000000 0 0 0 \n' >"$CF/$key.w" ;;
    *) printf '000 0.004000 0.000000 0.000000 0.000000 0.001000 0 0 0 \n' >"$CF/$key.w" ;;
  esac
  printf 'HTTP/2 %s\r\ndate: @DATE@\r\ncontent-type: text/plain\r\n\r\n' "$code" >"$CF/$key.h"
  printf '%s' "$body" >"$CF/$key.b"
  [[ $rc == 0 ]] || printf 'curl: (%s) stub failure\n' "$rc" >"$CF/$key.e"
  echo "$rc" >"$CF/$key.exit"
}

# scenario <rc_echo> <rc_baseline> <rc_rtt> [aws_ip]
scenario() {
  local re=$1 rb=$2 rr=$3 aws_ip=${4:-203.0.113.10}
  rm -rf "$CF"
  mkdir -p "$CF"
  fix 4 https://www.cloudflare.com/cdn-cgi/trace "$re" 200 $'fl=1\nip=203.0.113.10\nloc=DE\n'
  fix 4 https://api.ipify.org/ "$re" 200 '203.0.113.10'
  fix 4 https://checkip.amazonaws.com/ "$re" 200 "$aws_ip"$'\n'
  fix 6 https://www.cloudflare.com/cdn-cgi/trace "$re" 200 $'ip=2001:db8:10::5\nloc=DE\n'
  fix 6 https://api6.ipify.org/ "$re" 200 '2001:db8:10::5'
  fix "" https://www.google.com/generate_204 "$rb" 204 ''
  fix "" https://www.cloudflare.com/cdn-cgi/trace "$rb" 200 $'ip=203.0.113.10\n'
  fix "" https://www.wikipedia.org/robots.txt "$rb" 200 'User-agent: *'
  fix "" https://ya.ru/ "$rr" 200 '' 0.045000
  fix "" https://vk.com/ "$rr" 200 '' 0.050000
  fix "" https://mail.ru/ "$rr" 200 '' 0.040000
}

host() {
  use_host_fixture "$1"
  cp "$REPO_ROOT/tests/fixtures/stub-curl.sh" "$WORK/hostbin/curl"
  chmod +x "$WORK/hostbin/curl"
  export QVK_CURL_FIXTURES="$CF" QVK_STUB_CLOCK_OFFSET=0
}

run_json() { "$REPO_ROOT/qvk" run --format json "$@" >"$R" 2>"$WORK/err"; }
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
# Every curl call must target an https URL from the endpoint list.
curl_calls_outside_config() {
  local line url
  grep '^curl ' "$QVK_STUB_LOG" | while IFS= read -r line; do
    [[ $line == 'curl --version' ]] && continue
    url=${line##* }
    grep -qF -- " $url" "$CONFIG" || printf '%s\n' "$line"
  done
}
num_between() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v + 0 >= lo && v + 0 <= hi) }'; }

echo "# all good (Debian 12 VM, public address on the interface)"
host debian12-kvm-amd64
scenario 0 0 0
run_json
assert_eq 0 "$?" "run exits 0"
assert_true "schema" validate
assert_eq '"pass"' "$(tf egress_ipv4 status)" "egress ipv4 pass"
assert_eq '"203.0.113.10"' "$(jf target.ip)" "target.ip from echo services"
assert_eq '"none"' "$(jf target.nat)" "address on interface -> no NAT"
assert_eq '3' "$(tf egress_ipv4 samples)" "three echo sources"
assert_eq '"pass"' "$(tf egress_ipv6 status)" "egress ipv6 pass"
assert_eq '"pass"' "$(tf https_google status)" "baseline google pass"
assert_eq '"reachable"' "$(tf https_google http_outcome)" "http_outcome reachable"
assert_eq '21.0' "$(tf https_google metrics.tcp_connect_ms)" "tcp connect = connect - dns"
assert_eq '35.0' "$(tf https_google metrics.tls_ms)" "tls = appconnect - connect"
assert_eq '"pass"' "$(tf tcp_rtt_ru_yandex status)" "rtt yandex pass"
assert_eq '41.0' "$(tf tcp_rtt_ru_yandex metrics.rtt_ms_p50)" "rtt p50"
assert_eq 'null' "$(tf tcp_rtt_ru_yandex metrics.rtt_ms_p95)" "p95 null with 3 samples"
assert_eq '3' "$(tf tcp_rtt_ru_yandex samples)" "quick profile: 3 samples"
assert_contains "$(tf tcp_rtt_ru_yandex reason)" "not reachability from a Russian client network" \
  "rtt explicitly not client reachability"
assert_eq '"pass"' "$(tf dns_resolution status)" "dns pass"
assert_eq '"pass"' "$(tf clock_offset status)" "clock pass"
assert_true "clock offset near zero" num_between "$(tf clock_offset metrics.offset_s)" -2 2
assert_eq '"suitable"' "$(jf summary.verdicts.target_self_check.verdict)" "verdict suitable"
assert_eq '[]' "$(jf summary.verdicts.target_self_check.missing_evidence)" "nothing missing"
assert_eq '"indeterminate"' "$(jf summary.verdicts.client_reachability.verdict)" "client reachability still indeterminate"
assert_eq "" "$(curl_calls_outside_config)" "only configured https endpoints were contacted"
assert_eq "" "$(stub_calls_not_allowed | grep -v '^curl ')" "other commands stay read-only"
human=$("$REPO_ROOT/qvk" run 2>/dev/null)
assert_contains "$human" "Network (measured from this VPS)" "human network section"
assert_contains "$human" "203.0.113.10 (3 of 3 sources agree); NAT: none" "human egress line"
assert_contains "$human" "RTT to RU: yandex" "human rtt label"
assert_contains "$human" "suitable" "human verdict"

echo "# --redact-ip removes egress and interface addresses"
run_json --redact-ip
assert_true "schema" validate
body=$(cat "$R")
assert_not_contains "$body" "203.0.113.10" "egress ipv4 redacted everywhere"
assert_not_contains "$body" "2001:db8:10::5" "ipv6 redacted everywhere"
assert_eq '"<ip-1>"' "$(jf target.ip)" "target.ip label"
assert_contains "$body" "192.0.2.80" "endpoint addresses are not redacted"

echo "# echo services disagree"
scenario 0 0 0 198.51.100.7
run_json
assert_true "schema" validate
assert_eq '"warn"' "$(tf egress_ipv4 status)" "conflict -> warn"
assert_eq '"conflict"' "$(tf egress_ipv4 reason_code)" "reason_code conflict"
assert_eq 'null' "$(jf target.ip)" "no target.ip on conflict"
assert_eq '"indeterminate"' "$(jf summary.verdicts.target_self_check.verdict)" "conflict -> indeterminate"
assert_eq '["network_egress"]' "$(jf summary.verdicts.target_self_check.missing_evidence)" "missing network_egress"

echo "# clock off by 120 s"
scenario 0 0 0
QVK_STUB_CLOCK_OFFSET=120 run_json
assert_true "schema" validate
assert_eq '"warn"' "$(tf clock_offset status)" "clock warn"
assert_true "offset about 120 s" num_between "$(tf clock_offset metrics.offset_s)" 118 122
assert_eq '"unsuitable"' "$(jf summary.verdicts.target_self_check.verdict)" "clock -> unsuitable"
assert_eq '"criteria_failed"' "$(jf summary.verdicts.target_self_check.reason_code)" "criteria_failed"
assert_contains "$(jf summary.verdicts.target_self_check.reasons)" "system clock is off by" "clock reason"

echo "# outbound blocked (connect failures and timeouts)"
scenario 7 28 7
run_json
assert_true "schema" validate
assert_eq '"fail"' "$(tf egress_ipv4 status)" "egress fail"
assert_eq '"tcp_connect_failed"' "$(tf egress_ipv4 reason_code)" "egress reason"
assert_eq '"fail"' "$(tf https_google status)" "baseline fail"
assert_eq '"timeout"' "$(tf https_google reason_code)" "baseline timeout"
assert_eq '"network_error"' "$(tf https_google http_outcome)" "http_outcome network_error"
assert_eq '"fail"' "$(tf tcp_rtt_ru_vk status)" "rtt fail"
assert_eq '3' "$(tf tcp_rtt_ru_vk metrics.connect_failures)" "3 failed handshakes"
assert_eq 'null' "$(tf tcp_rtt_ru_vk metrics.rtt_ms_p50)" "no rtt without handshakes"
assert_eq '"unsuitable"' "$(jf summary.verdicts.target_self_check.verdict)" "outage -> unsuitable"
assert_contains "$(jf summary.verdicts.target_self_check.reasons)" "outbound internet access does not work" "egress reason in verdict"
assert_contains "$(jf summary.verdicts.target_self_check.reasons)" "no baseline HTTPS endpoint answered" "https reason in verdict"

echo "# DNS broken"
scenario 6 6 6
run_json
assert_true "schema" validate
assert_eq '"fail"' "$(tf dns_resolution status)" "dns fail"
assert_eq '"dns_failure"' "$(tf egress_ipv4 reason_code)" "egress dns_failure"
assert_contains "$(jf summary.verdicts.target_self_check.reasons)" "DNS resolution does not work" "dns reason"

echo "# curl itself fails (tester error is not a network verdict)"
scenario 2 2 2
run_json
assert_true "schema" validate
assert_eq '"error"' "$(tf egress_ipv4 status)" "egress error, not fail"
assert_eq '"error"' "$(tf https_google status)" "baseline error, not fail"
assert_eq '"indeterminate"' "$(jf summary.verdicts.target_self_check.verdict)" "tester error -> indeterminate"
assert_not_contains "$(jf summary.verdicts.target_self_check.reasons)" "does not work" "no network blame"

echo "# container behind NAT, no IPv6"
host ubuntu24-lxc-arm64
scenario 0 0 0
run_json
assert_true "schema" validate
assert_eq '"one_to_one_suspected"' "$(jf target.nat)" "private interface + public egress -> 1:1 NAT"
assert_eq '"skipped"' "$(tf egress_ipv6 status)" "ipv6 skipped"
assert_eq '"not_applicable"' "$(tf egress_ipv6 reason_code)" "ipv6 not applicable"
assert_eq 0 "$(grep -c -- '^curl .* -6 ' "$QVK_STUB_LOG")" "no IPv6 requests without an IPv6 route"
assert_eq '"suitable"' "$(jf summary.verdicts.target_self_check.verdict)" "NAT alone is not a failure"
human=$("$REPO_ROOT/qvk" run --lang ru 2>/dev/null)
assert_contains "$human" "NAT: вероятно 1:1 NAT" "russian NAT label"

echo "# --offline: no requests at all"
host debian12-kvm-amd64
scenario 0 0 0
run_json --offline
assert_true "schema" validate
assert_eq 0 "$(grep '^curl ' "$QVK_STUB_LOG" | grep -vc '^curl --version$')" "no curl requests"
assert_eq '"skipped"' "$(tf egress_ipv4 status)" "egress skipped"
assert_eq '"offline_mode"' "$(tf https_google reason_code)" "baseline offline_mode"
assert_eq '"offline_mode"' "$(tf clock_offset reason_code)" "clock offline_mode"
assert_eq '"indeterminate"' "$(jf summary.verdicts.target_self_check.verdict)" "offline -> indeterminate"
assert_eq '"offline_mode"' "$(jf summary.verdicts.target_self_check.reason_code)" "verdict reason offline_mode"

echo "# profile full: 20 RTT samples and p95"
run_json --profile full
assert_true "schema" validate
assert_eq '20' "$(tf tcp_rtt_ru_mailru samples)" "20 samples"
assert_eq '36.0' "$(tf tcp_rtt_ru_mailru metrics.rtt_ms_p95)" "p95 present with n >= 20"

echo "# sub-millisecond handshake: a nearby proxy answers, not the route"
scenario 0 0 0
fix "" https://ya.ru/ 0 200 '' 0.004600
run_json
assert_true "schema" validate
assert_eq '"warn"' "$(tf tcp_rtt_ru_yandex status)" "implausible rtt -> warn"
assert_eq '"middlebox_suspected"' "$(tf tcp_rtt_ru_yandex reason_code)" "reason middlebox_suspected"
assert_eq '0.6' "$(tf tcp_rtt_ru_yandex metrics.rtt_ms_p50)" "measured value still reported"
assert_eq '"pass"' "$(tf tcp_rtt_ru_vk status)" "other endpoints unaffected"
human=$("$REPO_ROOT/qvk" run 2>/dev/null)
assert_contains "$human" "ya.ru: handshake in 0.6 ms is implausible" "human middlebox message"
assert_eq 1 "$(grep -c 'ya.ru: handshake in' <<<"$human")" "message printed once"

echo "# endpoint list validation"
printf 'baseline bad http://insecure.example/\n' >"$WORK/bad.tsv"
"$REPO_ROOT/qvk" run --endpoints "$WORK/bad.tsv" >/dev/null 2>"$WORK/err"
assert_eq 1 "$?" "non-https endpoint rejected with exit 1"
assert_contains "$(cat "$WORK/err")" "bad.tsv:1" "error names file and line"
printf 'baseline x https://ok.example/;rm\n' >"$WORK/bad2.tsv"
"$REPO_ROOT/qvk" run --endpoints "$WORK/bad2.tsv" >/dev/null 2>&1
assert_eq 0 "$?" "odd but quoted-safe URL characters are passed as one argument"
printf 'unknown x https://ok.example/\n' >"$WORK/bad3.tsv"
"$REPO_ROOT/qvk" run --endpoints "$WORK/bad3.tsv" >/dev/null 2>&1
assert_eq 1 "$?" "unknown category rejected"

finish_tests
