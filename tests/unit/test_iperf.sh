#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=tests/lib/assert.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"
# shellcheck source=lib/iperf.sh
source "$REPO_ROOT/lib/iperf.sh"

iperf_json=$(cat <<'JSON'
{
  "intervals": [
    {
      "sum": {
        "bits_per_second": 35000000
      }
    }
  ],
  "end": {
    "sum_sent": {
      "bits_per_second": 40000000
    },
    "sum_received": {
      "bits_per_second": 50000000
    },
    "streams": [
      {
        "sender": {
          "rtt": 12345
        }
      }
    ]
  }
}
JSON
)
assert_eq "50.0" "$(_iperf_parse_download "$iperf_json")" "download uses end.sum_received, not last/first generic rate"
assert_eq "40.0" "$(_iperf_parse_upload "$iperf_json")" "upload uses end.sum_sent, not interval rate"
assert_eq "12.3" "$(_iperf_parse_latency "$iperf_json")" "latency is converted from microseconds"

# iperf3 -J may put its error object on stdout and still exit nonzero.
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir "$WORK/bin"
cat >"$WORK/bin/iperf3" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$IPERF_ARGS_OUT"
printf '%s\n' '{"error": "unable to connect to server: Connection refused"}'
exit 1
STUB
chmod +x "$WORK/bin/iperf3"
IPERF_ARGS_OUT="$WORK/args"
export IPERF_ARGS_OUT
PATH="$WORK/bin:$PATH"
QVK_OFFLINE=0
QVK_US=$'\x1f'
QVK_IPERF_TIMEOUT=2
QVK_CAPTURED_TEST=()
qvk_add_test() { QVK_CAPTURED_TEST=("$@"); }
qvk_iperf_run_server example.com 5203
iperf_reason=""
for field in "${QVK_CAPTURED_TEST[@]}"; do
  [[ $field == reason=* ]] && iperf_reason=${field#reason=}
done
assert_contains "$iperf_reason" "unable to connect to server: Connection refused" "runner extracts JSON error from stdout on rc=1"
assert_contains "$(cat "$WORK/args")" "-p 5203" "runner uses configured server port"

cat >"$WORK/bin/iperf3" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" -R "* ]]; then
  printf '%s\n' '{"end":{"sum_received":{"bits_per_second":5000000},"sum_sent":{"bits_per_second":5000000},"streams":[{"sender":{"rtt":1200}}]}}'
else
  printf '%s\n' '{"error": "unable to connect to server: upload rejected"}'
  exit 1
fi
STUB
chmod +x "$WORK/bin/iperf3"
QVK_CAPTURED_TEST=()
qvk_iperf_run_server example.com
iperf_reason=""
iperf_status=""
for field in "${QVK_CAPTURED_TEST[@]}"; do
  [[ $field == reason=* ]] && iperf_reason=${field#reason=}
  [[ $field == status=* ]] && iperf_status=${field#status=}
done
assert_eq "error" "$iperf_status" "upload failure is not reported as a successful test"
assert_contains "$iperf_reason" "upload: unable to connect to server: upload rejected" "upload failure includes JSON diagnostic"
assert_eq "iperf3 timed out (rc=124)" "$(_iperf_failure_reason '' /dev/null 124)" "timeout exit code is explained"

cat >"$WORK/bin/iperf3" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"error": "the server is busy running a test. try again later"}'
exit 1
STUB
chmod +x "$WORK/bin/iperf3"
QVK_CAPTURED_TEST=()
qvk_iperf_run_server example.com 5203
iperf_status=""
for field in "${QVK_CAPTURED_TEST[@]}"; do
  [[ $field == status=* ]] && iperf_status=${field#status=}
done
assert_eq "skipped" "$iperf_status" "busy public iperf server is skipped, not a tester error"

# The human report must surface the command's diagnostic, not just the host.
source "$REPO_ROOT/lib/report.sh"
source "$REPO_ROOT/lib/i18n.sh"
QVK_LANG=en
QVK_US=$'\x1f'
QVK_LIB="$REPO_ROOT/lib"
qvk_i18n_load
QVK_TEST_HUMAN=("iperf_throughput${QVK_US}iperf_example_com${QVK_US}error${QVK_US}throughput.error${QVK_US}example.com${QVK_US}Connection refused")
declare -A QVK_TEST_GROUP=([iperf_example_com]='')
qvk_pad() { printf '%s' "$1"; }
qvk_paint() { printf '%s' "$2"; }
output=$(_qvk_human_tests iperf_throughput report.section.throughput)
assert_contains "$output" "example.com: Connection refused" "human error includes iperf diagnostic"
finish_tests
