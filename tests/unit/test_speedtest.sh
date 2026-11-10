#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=tests/lib/assert.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"
# shellcheck source=lib/json.sh
source "$REPO_ROOT/lib/json.sh"
# shellcheck source=lib/speedtest.sh
source "$REPO_ROOT/lib/speedtest.sh"

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/bin"
export PATH="$WORK/bin:$PATH"
QVK_OFFLINE=0
QVK_US=$'\x1f'
QVK_SPEEDTEST_TIMEOUT=2
QVK_TEST_EUID=0
QVK_CAPTURED_TEST=()
qvk_add_test() { QVK_CAPTURED_TEST=("$@"); }
qvk_log() { :; }
msg() { printf '%s' "$1"; }

speed_json=$(cat <<'JSON'
{
  "type": "result",
  "timestamp": "2026-11-10T03:10:00Z",
  "ping": { "jitter": 1.2, "latency": 18.4 },
  "download": { "bandwidth": 12500000, "bytes": 50000000, "elapsed": 4000 },
  "upload": { "bandwidth": 2500000, "bytes": 10000000, "elapsed": 4000 },
  "server": { "name": "Test ISP", "location": "Paris", "country": "France", "host": "speed.example" },
  "result": { "id": "123", "url": "https://www.speedtest.net/result/123" }
}
JSON
)
assert_eq "100.0" "$(_speedtest_parse_mbps "$speed_json" download)" "download bandwidth bytes/s converts to Mbps"
assert_eq "20.0" "$(_speedtest_parse_mbps "$speed_json" upload)" "upload bandwidth bytes/s converts to Mbps"
assert_eq "18.4" "$(_speedtest_parse_latency "$speed_json")" "latency is parsed in ms"
assert_eq "" "$(_speedtest_parse_mbps '{"nested":{"download":{"bandwidth":90000000}}}' download 2>/dev/null)" \
  "nested fake metrics are not treated as Ookla top-level results"
assert_eq "" "$(_speedtest_parse_mbps '{"download":{"bandwidth":90000000}' download 2>/dev/null)" \
  "unbalanced JSON cannot produce a successful speed measurement"
assert_eq "" "$(_speedtest_parse_mbps '{"download":{"bandwidth":90000000]}' download 2>/dev/null)" \
  "mismatched JSON delimiters cannot produce a successful speed measurement"

# The CLI is called exactly once and its JSON becomes one report row.
cat >"$WORK/bin/speedtest" <<'STUB'
#!/usr/bin/env bash
if [[ $1 == --version ]]; then echo 'Speedtest by Ookla 1.2.0'; exit 0; fi
printf '%s\n' "$*" >>"$SPEEDTEST_ARGS_OUT"
cat "$SPEEDTEST_JSON"
STUB
chmod +x "$WORK/bin/speedtest"
export SPEEDTEST_ARGS_OUT="$WORK/args" SPEEDTEST_JSON="$WORK/result.json"
printf '%s\n' "$speed_json" >"$WORK/result.json"
qvk_speedtest_run
assert_eq 1 "$(wc -l <"$WORK/args" | tr -d ' ')" "speedtest CLI invoked once"
assert_contains "$(cat "$WORK/args")" "--accept-license --accept-gdpr --format=json" "official CLI accepts terms non-interactively and requests JSON"
assert_contains "${QVK_CAPTURED_TEST[*]}" "id=speedtest_ookla" "one Ookla report record produced"
assert_contains "${QVK_CAPTURED_TEST[*]}" "status=pass" "valid Ookla result passes"
assert_contains "${QVK_CAPTURED_TEST[*]}" '"download_mbps":100' "report contains parsed download"
assert_contains "${QVK_CAPTURED_TEST[*]}" '"upload_mbps":20' "report contains parsed upload"
assert_contains "${QVK_CAPTURED_TEST[*]}" 'traffic_bytes=60000000' "measured transfer volume is not misreported as zero"

# Missing CLI is installed from Ookla's signed official repository without prompting.
export WORK
mv "$WORK/bin/speedtest" "$WORK/bin/speedtest.saved"
cat >"$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_ARGS_OUT"
while (($#)); do
  if [[ $1 == -o ]]; then printf 'fake-ookla-signing-key\n' >"$2"; exit 0; fi
  shift
done
exit 1
STUB
cat >"$WORK/bin/gpg" <<'STUB'
#!/usr/bin/env bash
while (($#)); do
  if [[ $1 == -o ]]; then printf 'fake-dearmored-key\n' >"$2"; exit 0; fi
  shift
done
exit 1
STUB
cat >"$WORK/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$APT_ARGS_OUT"
if [[ " $* " == *" install "* && " $* " == *" speedtest "* ]]; then
  cp "$WORK/bin/speedtest.saved" "$WORK/bin/speedtest"
fi
STUB
chmod +x "$WORK/bin/curl" "$WORK/bin/gpg" "$WORK/bin/apt-get"
export CURL_ARGS_OUT="$WORK/curl.args" APT_ARGS_OUT="$WORK/apt.args"
export QVK_TEST_SPEEDTEST_KEYRING="$WORK/etc/apt/keyrings/ookla.gpg"
export QVK_TEST_SPEEDTEST_SOURCES="$WORK/etc/apt/sources.list.d/ookla.list"
QVK_OS_ID=debian QVK_OS_VERSION_ID=12
assert_true "missing Ookla CLI installs successfully" qvk_speedtest_ensure
assert_contains "$(cat "$WORK/curl.args")" "packagecloud.io/ookla/speedtest-cli/gpgkey" "official Ookla signing key is fetched"
assert_contains "$(cat "$WORK/etc/apt/sources.list.d/ookla.list")" "https://packagecloud.io/ookla/speedtest-cli/debian bookworm main" "official signed Debian source is configured"
assert_contains "$(cat "$WORK/etc/apt/sources.list.d/ookla.list")" "[signed-by=$WORK/etc/apt/keyrings/ookla.gpg]" "APT source is restricted to Ookla's signing key"
assert_contains "$(cat "$WORK/apt.args")" "install -y speedtest" "Ookla package is installed through apt"

# A colliding source file is rejected before keyring/source mutation.
mv "$WORK/bin/speedtest" "$WORK/bin/speedtest.installed"
cp "$QVK_TEST_SPEEDTEST_KEYRING" "$WORK/keyring.before"
printf 'deb https://unrelated.example/repo stable main\n' >"$QVK_TEST_SPEEDTEST_SOURCES"
curl_count_before=$(wc -l <"$WORK/curl.args" | tr -d ' ')
if qvk_speedtest_ensure; then assert_eq 0 1 "unrelated APT source is refused"
else assert_contains "$QVK_SPEEDTEST_ERROR" "refusing to overwrite unrelated APT source" "unrelated APT source is refused"; fi
assert_true "existing signing key remains unchanged after source conflict" cmp -s "$WORK/keyring.before" "$QVK_TEST_SPEEDTEST_KEYRING"
assert_eq "$curl_count_before" "$(wc -l <"$WORK/curl.args" | tr -d ' ')" "conflicting source is rejected before downloading a key"
mv "$WORK/bin/speedtest.installed" "$WORK/bin/speedtest"

# Offline mode skips before installation or CLI invocation.
QVK_OFFLINE=1
QVK_CAPTURED_TEST=()
qvk_speedtest_run
assert_contains "${QVK_CAPTURED_TEST[*]}" "reason_code=offline_mode" "offline mode skips Ookla"
assert_eq 1 "$(wc -l <"$WORK/args" | tr -d ' ')" "offline mode does not invoke CLI"

# Malformed output and CLI failures are reported without leaking raw JSON.
QVK_OFFLINE=0
cat >"$WORK/bin/speedtest" <<'STUB'
#!/usr/bin/env bash
if [[ $1 == --version ]]; then echo 'Speedtest by Ookla 1.2.0'; exit 0; fi
echo 'not-json-with-token-secret'
exit 1
STUB
chmod +x "$WORK/bin/speedtest"
QVK_CAPTURED_TEST=()
qvk_speedtest_run
assert_contains "${QVK_CAPTURED_TEST[*]}" "status=error" "invalid output is an error"
assert_not_contains "${QVK_CAPTURED_TEST[*]}" "token-secret" "raw CLI error output is not recorded"

finish_tests
