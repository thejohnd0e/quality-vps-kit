#!/usr/bin/env bash
# Profile `full` diagnostics: path MTU (tracepath), ICMP RTT (ping) and resolver
# comparison (dig), against canned tool output. No real network.
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
CMD="$WORK/cmd"

# sfix <exit code> <output> <command line...> — canned output of a stubbed tool
sfix() {
  local rc=$1 out=$2 key
  shift 2
  key=$(printf '%s' "$*" | tr -c 'A-Za-z0-9._-' '_')
  printf '%s\n' "$out" >"$CMD/$key"
  echo "$rc" >"$CMD/$key.exit"
}

tp_out() {
  printf ' 1?: [LOCALHOST]                      pmtu %s\n 1:  203.0.113.1  0.402ms\n 2:  no reply\n     Resume: pmtu %s hops 5 back 5\n' "$1" "$1"
}
ping_out() { # host sent recv loss min avg max
  local o
  o=$(printf 'PING %s (192.0.2.1) 56(84) bytes of data.\n\n--- %s ping statistics ---\n%s packets transmitted, %s received, %s%% packet loss, time 4006ms\n' \
    "$1" "$1" "$2" "$3" "$4")
  if (($3 > 0)); then
    o+=$(printf '\nrtt min/avg/max/mdev = %s/%s/%s/0.900 ms' "$5" "$6" "$7")
  fi
  printf '%s' "$o"
}

full_fixtures() {
  sfix 0 "$(tp_out 1500)" tracepath -n -m 12 www.google.com
  sfix 0 "$(ping_out ya.ru 5 5 0 41.1 42.0 43.3)" ping -n -c 5 -W 2 ya.ru
  sfix 0 "$(ping_out vk.com 5 4 20 50.0 51.5 53.0)" ping -n -c 5 -W 2 vk.com
  sfix 1 "$(ping_out mail.ru 5 0 100)" ping -n -c 5 -W 2 mail.ru
  local h r
  for h in www.google.com www.cloudflare.com www.wikipedia.org; do
    for r in "" @1.1.1.1 @8.8.8.8; do
      if [[ -n $r ]]; then
        sfix 0 $'192.0.2.10\n192.0.2.11' dig +short +time=3 +tries=1 "$r" "$h" A
      else
        sfix 0 $'192.0.2.10' dig +short +time=3 +tries=1 "$h" A
      fi
    done
  done
}

setup() {
  host debian12-kvm-amd64
  scenario 0 0 0
  rm -rf "$CMD"
  cp -r "$QVK_STUB_DIR" "$CMD"
  export QVK_STUB_DIR="$CMD"
  full_fixtures
}

run_json() {
  : >"$QVK_STUB_LOG"
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
not_curl_not_allowed() { stub_calls_not_allowed | grep -v '^curl '; }

echo "# full: path MTU, ICMP and resolver comparison"
setup
run_json --profile full
assert_eq 0 "$?" "run exits 0"
assert_true "schema" validate
assert_eq '"pass"' "$(tf path_mtu status)" "path MTU pass"
assert_eq '1500' "$(tf path_mtu metrics.path_mtu_bytes)" "pmtu parsed from Resume line"
assert_eq '1500' "$(tf path_mtu metrics.interface_mtu_bytes)" "interface MTU kept separate"
assert_eq '"pass"' "$(tf icmp_rtt_ru_yandex status)" "icmp pass"
assert_eq '42.0' "$(tf icmp_rtt_ru_yandex metrics.icmp_rtt_ms_avg)" "icmp avg parsed"
assert_eq '0.0' "$(tf icmp_rtt_ru_yandex metrics.packet_loss_pct | sed 's/^0$/0.0/')" "no loss"
assert_eq '"warn"' "$(tf icmp_rtt_ru_vk status)" "packet loss -> warn"
assert_eq '20' "$(tf icmp_rtt_ru_vk metrics.packet_loss_pct)" "loss parsed"
assert_eq '"unknown"' "$(tf icmp_rtt_ru_mailru status)" "no ICMP reply -> unknown, not fail"
assert_eq '"icmp_no_reply"' "$(tf icmp_rtt_ru_mailru reason_code)" "reason icmp_no_reply"
assert_contains "$(tf icmp_rtt_ru_mailru reason)" "says nothing about TCP" "ICMP silence is not blamed on the route"
assert_eq 'null' "$(tf icmp_rtt_ru_mailru metrics.icmp_rtt_ms_avg)" "no rtt without replies"
assert_eq '"pass"' "$(tf dns_resolvers status)" "resolvers agree on presence"
assert_contains "$(tf dns_resolvers details.resolvers)" '"resolver": "system", "names_resolved": 3' "system resolver resolved 3 names"
assert_eq '"suitable"' "$(jf summary.verdicts.target_self_check.verdict)" "diagnostics do not change the verdict"
assert_eq "" "$(not_curl_not_allowed)" "only allow-listed read-only commands were run"
human=$("$REPO_ROOT/qvk" run --profile full 2>/dev/null)
assert_contains "$human" "Path MTU" "human path MTU row"
assert_contains "$human" "ICMP RTT to RU: yandex" "human ICMP row"
assert_contains "$human" "no ICMP reply (often filtered" "human ICMP silence wording"
assert_eq 1 "$(grep 'mail.ru: no ICMP' <<<"$human" | grep -o 'no ICMP reply' | wc -l)" \
  "message is rendered once (surplus printf arguments are not recycled)"

echo "# path MTU below the interface MTU"
sfix 0 "$(tp_out 1400)" tracepath -n -m 12 www.google.com
run_json --profile full
assert_true "schema" validate
assert_eq '"warn"' "$(tf path_mtu status)" "pmtu < interface MTU -> warn"
assert_eq '1400' "$(tf path_mtu metrics.path_mtu_bytes)" "pmtu 1400"
assert_contains "$(tf path_mtu reason)" "size VPN tunnel MTU" "advice about tunnel MTU"
sfix 0 "garbage" tracepath -n -m 12 www.google.com
run_json --profile full
assert_eq '"unknown"' "$(tf path_mtu status)" "no pmtu in output -> unknown"

echo "# system resolver fails where public resolvers answer"
setup
sfix 0 "" dig +short +time=3 +tries=1 www.wikipedia.org A
run_json --profile full
assert_true "schema" validate
assert_eq '"warn"' "$(tf dns_resolvers status)" "mismatch -> warn"
assert_eq '"dns_failure"' "$(tf dns_resolvers reason_code)" "reason dns_failure"
assert_eq '["www.wikipedia.org"]' "$(tf dns_resolvers details.mismatching_names | tr -d ' ')" "mismatching name listed"
assert_eq 'null' "$(tf dns_resolvers diagnosis)" "no filtering diagnosis from one resolver comparison"
assert_not_contains "$(cat "$R")" "blocked" "nothing claims blocking"
assert_eq '"suitable"' "$(jf summary.verdicts.target_self_check.verdict)" "verdict unaffected"

echo "# tools missing"
setup
export QVK_TEST_HIDE_TOOLS="tracepath ping dig"
run_json --profile full
assert_true "schema" validate
assert_eq '"skipped"' "$(tf path_mtu status)" "tracepath missing -> skipped"
assert_eq '"tool_missing"' "$(tf path_mtu reason_code)" "reason tool_missing"
assert_eq '"tool_missing"' "$(tf icmp_rtt_ru_yandex reason_code)" "ping missing"
assert_eq '"tool_missing"' "$(tf dns_resolvers reason_code)" "dig missing"
assert_eq 0 "$(grep -cE '^(tracepath|ping|dig) ' "$QVK_STUB_LOG")" "missing tools are not run"
export QVK_TEST_HIDE_TOOLS="ufw firewall-cmd"

echo "# quick profile does not run them"
setup
run_json
assert_eq 'null' "$(tf path_mtu status)" "no path_mtu in quick"
assert_eq 'null' "$(tf dns_resolvers status)" "no dns_resolvers in quick"
assert_eq 'null' "$(tf icmp_rtt_ru_yandex status)" "no ICMP in quick"
assert_eq 0 "$(grep -cE '^(tracepath|ping|dig) ' "$QVK_STUB_LOG")" "no diagnostic tool calls in quick"

echo "# offline full"
setup
run_json --profile full --offline
assert_true "schema" validate
assert_eq '"offline_mode"' "$(tf path_mtu reason_code)" "pmtu offline"
assert_eq '"offline_mode"' "$(tf icmp_rtt_ru_vk reason_code)" "icmp offline"
assert_eq '"offline_mode"' "$(tf dns_resolvers reason_code)" "dns offline"
assert_eq 0 "$(grep -cE '^(tracepath|ping|dig) ' "$QVK_STUB_LOG")" "no probes offline"

finish_tests
