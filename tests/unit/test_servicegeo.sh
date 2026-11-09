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
# shellcheck source=lib/servicegeo.sh
source "$REPO_ROOT/lib/servicegeo.sh"

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
PV_URL='https://www.primevideo.com/'
SP_URL="https://spclient.wg.spotify.com/signup/public/v1/account/?validate=1&key=$QVK_SG_SPOTIFY_KEY"

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
run_human_offline() {
  : >"$QVK_STUB_LOG"
  "$REPO_ROOT/qvk" run --offline >"$H" 2>"$WORK/err"
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
  fix "" "$PV_URL" 0 302 '' 0.025000 'location: /offers/nonprimehomepage'
  fix "" "$SP_URL" 0 200 '{"country":"US","is_country_launched":true}'
}

# sp_fixtures <body>: Spotify signup answer
sp_fixtures() {
  sg_fixtures 0 200 "$YT_AVAILABLE"
  fix "" "$SP_URL" 0 200 "${1:-{\"country\":\"US\",\"is_country_launched\":true}}"
}

# pv_fixtures <code> <location>: Prime Video answers with a redirect and no body
pv_fixtures() {
  sg_fixtures 0 200 "$YT_AVAILABLE"
  fix "" "$PV_URL" 0 "${1:-302}" '' 0.025000 "location: ${2:-/offers/nonprimehomepage}"
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

echo "# markers that are not specific to the product"
sg_fixtures 0 200 '<html>Featured video not available in your country</html>'
run_json
assert_eq '"unknown"' "$(tf sg_youtube_premium status)" "a generic 'not available' line is not a Premium restriction"

sg_fixtures 0 200 '<html><script src="/ypc.js"></script></html>'
run_json
assert_eq '"unknown"' "$(tf sg_youtube_premium status)" "a bare ypc token is not Premium availability"

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
run_human_offline
assert_contains "$(cat "$H")" "offline mode" "offline rows explain themselves"
assert_not_contains "$(cat "$H")" "sg_offline" "no raw i18n keys in the report"

echo "# body over the size cap is not a decision"
big="${YT_AVAILABLE}$(head -c 1100000 /dev/zero | tr '\0' a)"
sg_fixtures 0 200 "$big"
run_json
assert_eq '"unknown"' "$(tf sg_youtube_premium status)" "oversized body -> unknown even when curl exits 0"
assert_eq '"insufficient_data"' "$(tf sg_youtube_premium reason_code)" "oversized body reason"

echo "# failures explain themselves in the human report"
sg_fixtures 28 200 ''
run_human
assert_contains "$(cat "$H")" "no answer from the service" "human timeout message"
assert_not_contains "$(cat "$H")" "sg_unreachable" "no raw i18n keys for failures"

echo "# prime video: the redirect target is the signal"
pv_fixtures 302 /servicerestricted
run_json
assert_eq '"warn"' "$(tf sg_prime_video status)" "servicerestricted -> warn"
assert_eq '"country_restricted"' "$(tf sg_prime_video details.restriction)" "servicerestricted -> restricted"
assert_eq '"restriction_marker"' "$(tf sg_prime_video details.evidence)" "evidence is the redirect"

pv_fixtures 302 '/offers/nonprimehomepage?ref_=dv_web_force_root'
run_json
assert_eq '"pass"' "$(tf sg_prime_video status)" "own offers page -> available"
assert_eq '"none"' "$(tf sg_prime_video details.restriction)" "no restriction"
assert_eq '"redirect"' "$(tf sg_prime_video details.evidence)" "evidence is the redirect"

pv_fixtures 302 'https://consent.example/start'
run_json
assert_eq '"unknown"' "$(tf sg_prime_video status)" "redirect to a foreign host -> unknown"
assert_eq '"unknown"' "$(tf sg_prime_video details.restriction)" "not a country restriction"

pv_fixtures 302 '/consent'
run_json
assert_eq '"unknown"' "$(tf sg_prime_video status)" "unverified relative redirect -> unknown, not available"
assert_eq '"unknown"' "$(tf sg_prime_video details.restriction)" "relative redirect is not a country fact"

pv_fixtures 200 ''
run_json
assert_eq '"unknown"' "$(tf sg_prime_video status)" "200 without a marker -> unknown"
assert_eq '"insufficient_data"' "$(tf sg_prime_video reason_code)" "200 reason"

pv_fixtures 403 ''
run_json
assert_eq '"unknown"' "$(tf sg_prime_video status)" "403 -> unknown"
assert_eq '"http_403"' "$(tf sg_prime_video reason_code)" "403 code"

echo "# spotify: the service's own availability flag"
sp_fixtures '{"country":"US","is_country_launched":false}'
run_json
assert_eq '"warn"' "$(tf sg_spotify_signup status)" "is_country_launched=false -> warn"
assert_eq '"country_restricted"' "$(tf sg_spotify_signup details.restriction)" "false -> restricted"
assert_eq '"availability_flag"' "$(tf sg_spotify_signup details.evidence)" "evidence is the flag"

sp_fixtures '{"country":"US","is_country_launched":true}'
run_json
assert_eq '"pass"' "$(tf sg_spotify_signup status)" "true -> pass"
assert_eq '"none"' "$(tf sg_spotify_signup details.restriction)" "no restriction"
assert_eq '"US"' "$(tf sg_spotify_signup details.country)" "country from the same answer"

sp_fixtures '{"status":1}'
run_json
assert_eq '"unknown"' "$(tf sg_spotify_signup status)" "flag missing -> unknown"
assert_eq '"insufficient_data"' "$(tf sg_spotify_signup reason_code)" "flag missing reason"

sp_fixtures '{"country":"US","is_country_launched":trueish}'
run_json
assert_eq '"unknown"' "$(tf sg_spotify_signup status)" "malformed boolean is not a decision"

sp_fixtures '{"country":"US","is_country_launched":falseish}'
run_json
assert_eq '"unknown"' "$(tf sg_spotify_signup status)" "malformed false is not a restriction"

sp_fixtures '{"country":"US","is_country_launched":true}'
run_json
assert_not_contains "$(cat "$R")" "$QVK_SG_SPOTIFY_KEY" "json report never contains the key"
assert_not_contains "$(tf sg_spotify_signup endpoint)" "key=" "endpoint recorded without the key"
run_human
assert_not_contains "$(cat "$H")" "$QVK_SG_SPOTIFY_KEY" "human report never contains the key"

echo "# human output"
sg_fixtures 0 200 "$YT_RESTRICTED"
run_human
assert_contains "$(cat "$H")" "Service restrictions" "human section title"
assert_contains "$(cat "$H")" "YouTube Premium" "human service label"
assert_contains "$(cat "$H")" "restricted" "human restriction text"

finish_tests
