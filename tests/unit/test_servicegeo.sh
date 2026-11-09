#!/usr/bin/env bash
# service_geo: does a service restrict the country of this egress IP?
# Canned curl responses only, no real network.
set -uo pipefail
# shellcheck source=tests/lib/assert.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"
# shellcheck source=tests/lib/hostfix.sh
source "$REPO_ROOT/tests/lib/hostfix.sh"
# shellcheck source=tests/lib/curlfix.sh
source "$REPO_ROOT/tests/lib/curlfix.sh"
# shellcheck source=tests/lib/fixtures.sh
source "$REPO_ROOT/tests/lib/fixtures.sh"

PY=$(find_python) || {
  echo "python 3 is required" >&2
  exit 1
}
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
unset NO_COLOR LANG LC_ALL LC_MESSAGES
export QVK_RETRY_DELAY_S=0
CF="$WORK/curlfix"
R="$WORK/r.json"
H="$WORK/h.txt"

host debian12-kvm-amd64

YT_URL='https://www.youtube.com/premium?hl=en'

# Marker-bearing bodies, reduced from the capture recorded in the plan workspace.
YT_AVAILABLE='<html><script>var ytcfg={"ypcOffers":[],"countryCode":"US","ypcGetOffersEndpoint":"/youtubei/v1"};</script>YouTube Premium</html>'
YT_RESTRICTED='<html><body>YouTube Premium is not available in your country</body></html>'
YT_MASKED='<html><body>Nothing decisive here.</body></html>'

run_json() {
  : >"$QVK_STUB_LOG"
  "$REPO_ROOT/qvk" run --format json "$@" >"$R" 2>"$WORK/err"
}
run_human() {
  : >"$QVK_STUB_LOG"
  "$REPO_ROOT/qvk" run >"$H" 2>"$WORK/err"
}
jf() {
  "$PY" -I -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
for k in sys.argv[2].split("."):
    d=d[int(k)] if isinstance(d,list) else d[k]
print(json.dumps(d, ensure_ascii=False))' "$R" "$1"
}
# tf <test id> <field path>
tf() {
  "$PY" -I -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
t=[x for x in d["tests"] if x["id"]==sys.argv[2]]
v=t[0] if t else None
for k in (sys.argv[3].split(".") if v is not None else []):
    v=v.get(k) if isinstance(v,dict) else None
print(json.dumps(v, ensure_ascii=False))' "$R" "$1" "$2"
}
count_calls() { grep -cF -- "$1" "$QVK_STUB_LOG" 2>/dev/null || true; }

# sg_fixtures <curl rc> <http code> <body> [extra headers]: full run, chosen YouTube answer
sg_fixtures() {
  scenario 0 0 0
  services_fixtures
  intel_fixtures
  fix "" "$YT_URL" "${1:-0}" "${2:-200}" "${3:-$YT_AVAILABLE}" 0.025000 "${4:-}"
}

echo "# available with a product marker"
sg_fixtures 0 200 "$YT_AVAILABLE"
run_json
assert_eq '"pass"' "$(tf sg_youtube_premium status)" "product marker -> pass"
assert_eq '"none"' "$(tf sg_youtube_premium details.restriction)" "no restriction"
assert_eq '"product_page"' "$(tf sg_youtube_premium details.evidence)" "evidence is the product page"
assert_eq '"US"' "$(tf sg_youtube_premium details.country)" "country read from the page"
assert_eq '"suitable"' "$(jf summary.verdicts.target_self_check.verdict)" "verdict unchanged"

echo "# explicit country restriction"
sg_fixtures 0 200 "$YT_RESTRICTED"
run_json
assert_eq '"warn"' "$(tf sg_youtube_premium status)" "restriction -> warn"
assert_eq '"country_restricted"' "$(tf sg_youtube_premium details.restriction)" "restriction recorded"
assert_eq '"restriction_marker"' "$(tf sg_youtube_premium details.evidence)" "evidence is the marker"

echo "# answered without a decisive marker"
sg_fixtures 0 200 "$YT_MASKED"
run_json
assert_eq '"unknown"' "$(tf sg_youtube_premium status)" "no marker -> unknown, never available"
assert_eq '"unknown"' "$(tf sg_youtube_premium details.restriction)" "restriction unknown"
assert_eq '"insufficient_data"' "$(tf sg_youtube_premium reason_code)" "reason recorded"

echo "# redirect is not a country restriction"
sg_fixtures 0 302 '' 'location: /consent'
run_json
assert_eq '"unknown"' "$(tf sg_youtube_premium status)" "302 -> unknown"
assert_eq '"http_error"' "$(tf sg_youtube_premium reason_code)" "302 uses http_error"
assert_eq '"unknown"' "$(tf sg_youtube_premium details.restriction)" "302 is not country_restricted"

echo "# service decisions and failures"
sg_fixtures 0 403 ''
run_json
assert_eq '"unknown"' "$(tf sg_youtube_premium status)" "403 -> unknown"
assert_eq '"http_403"' "$(tf sg_youtube_premium reason_code)" "403 code"
assert_eq '"http_denied"' "$(tf sg_youtube_premium http_outcome)" "403 outcome"

sg_fixtures 0 429 ''
run_json
assert_eq '"http_429"' "$(tf sg_youtube_premium reason_code)" "429 code"
assert_eq '"rate_limited"' "$(tf sg_youtube_premium http_outcome)" "429 outcome"

sg_fixtures 63 200 '<html>truncated'
run_json
assert_eq '"unknown"' "$(tf sg_youtube_premium status)" "truncated body -> unknown"
assert_eq '"insufficient_data"' "$(tf sg_youtube_premium reason_code)" "truncated body reason"

sg_fixtures 28 200 ''
run_json
assert_eq '"fail"' "$(tf sg_youtube_premium status)" "timeout -> fail (route fact, like every other check)"
assert_eq '"timeout"' "$(tf sg_youtube_premium reason_code)" "timeout code"

echo "# offline sends nothing"
sg_fixtures 0 200 "$YT_AVAILABLE"
run_json --offline
assert_eq '"skipped"' "$(tf sg_youtube_premium status)" "offline -> skipped"
assert_eq '"offline_mode"' "$(tf sg_youtube_premium reason_code)" "offline reason"
assert_eq '0' "$(count_calls youtube.com)" "no request to YouTube offline"

echo "# human output"
sg_fixtures 0 200 "$YT_RESTRICTED"
run_human
assert_contains "$(cat "$H")" "Service restrictions" "human section title"
assert_contains "$(cat "$H")" "YouTube Premium" "human service label"
assert_contains "$(cat "$H")" "restricted" "human restriction text"

finish_tests
