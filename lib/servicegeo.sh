# shellcheck shell=bash
# Service geo restrictions (section service_geo). One gentle GET per service:
# does this service restrict the country of the target's egress IP?
#
# Fail-closed: a row says `none` (available) only on positive evidence; when the
# answer carries no decisive marker the row is `unknown`, never "available".
# IP-reputation signals (captcha, anti-bot 403) are deliberately out of scope.
# Nothing here follows redirects or changes a verdict.

QVK_SG_UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36'
# Spotify's published web-client key (it ships inside spotify.com pages). Not a
# user secret: it never reaches a report, a log or the recorded endpoint.
QVK_SG_SPOTIFY_KEY='142b583129b2df829de3656f9eb484e6'
QVK_SG_SERVICES=(youtube_premium prime_video spotify_signup)

# _sg_country <file> [json key] -> two-letter code, upper-cased; empty when absent
_sg_country() {
  local key=${2:-countryCode} code
  code=$(grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\"[A-Za-z]{2}\"" "$1" 2>/dev/null |
    head -n1 | sed -E 's/^.*:[[:space:]]*"//; s/"$//' | tr '[:lower:]' '[:upper:]')
  [[ $code =~ ^[A-Z]{2}$ ]] || code=""
  printf '%s' "$code"
}

# _sg_too_big: the body reached the configured cap. curl does not always return
# exit 63 for streamed bodies, so the size is checked here as well.
_sg_too_big() {
  local n
  n=$(wc -c <"$QC_BODY" 2>/dev/null) || n=0
  ((n >= QVK_MAX_BODY_BYTES))
}

# _sg_has <file> <extended regex> -> 0 when the (case-insensitive) pattern matches
_sg_has() { grep -qiE -- "$2" "$1" 2>/dev/null; }

# _sg_emit <id> <status> <restriction> <country> <evidence> <reason_code> <hmsg> <hargs> <endpoint> [http_outcome]
_sg_emit() {
  local id=$1 status=$2 restriction=$3 country=$4 evidence=$5 rcode=$6 hmsg=$7 hargs=$8 endpoint=$9
  local outcome=${10:-} details duration_ms
  details=$(json_obj restriction "$(json_str "$restriction")" \
    country "$(json_str_or_null "$country")" evidence "$(json_str "$evidence")")
  duration_ms=$(qvk_ms "$QC_TOTAL")
  qvk_add_test id="sg_$id" section=service_geo method=curl_get endpoint="$endpoint" \
    status="$status" diagnosis=none reason_code="$rcode" http_outcome="$outcome" \
    hmsg="$hmsg" hargs="$hargs" details="$details" \
    duration_ms="${duration_ms%.*}" timeout_ms=$((QVK_HTTP_MAX_TIME * 1000)) samples=1 \
    traffic_bytes="$QC_BYTES"
}

# _sg_failure <id> <endpoint>: map a non-successful answer to a row.
_sg_failure() {
  local id=$1 endpoint=$2 st rcode outcome
  read -r st rcode <<<"$(qvk_curl_outcome "$QC_RC")"
  if [[ $st != pass ]]; then
    case $rcode in
      tls_failure) outcome=tls_error ;;
      curl_error) outcome=unknown ;;
      *) outcome=network_error ;;
    esac
    _sg_emit "$id" "$st" unknown "" none "$rcode" sg.unreachable "$rcode" "$endpoint" "$outcome"
    return 0
  fi
  case $QC_CODE in
    403) rcode=http_403 outcome=http_denied ;;
    429) rcode=http_429 outcome=rate_limited ;;
    *) rcode=http_error outcome=unknown ;;
  esac
  _sg_emit "$id" unknown unknown "" none "$rcode" sg.failed "${QC_CODE:-none}" "$endpoint" "$outcome"
}

# _sg_html <id> <url> <restriction regex> <product regex> [country json key] [guard regex]
# The guard, when given, must match as well: a broad product token alone is not
# proof that the product is offered.
_sg_html() {
  local id=$1 url=$2 restr=$3 product=$4 ckey=${5:-countryCode} guard=${6:-}
  local st country status restriction evidence hmsg hargs
  if ((QVK_OFFLINE)); then
    QC_TOTAL=0 QC_BYTES=0
    _sg_emit "$id" skipped unknown "" none offline_mode sg.offline "" "$url"
    return 0
  fi
  qvk_curl "sg_$id" "$url" -A "$QVK_SG_UA"
  if ((QC_RC == 63)) || _sg_too_big; then
    _sg_emit "$id" unknown unknown "" none insufficient_data sg.truncated "" "$url"
    return 0
  fi
  read -r st _ <<<"$(qvk_curl_outcome "$QC_RC")"
  if [[ $st != pass || $QC_CODE != 2?? ]]; then
    _sg_failure "$id" "$url"
    return 0
  fi
  country=$(_sg_country "$QC_BODY" "$ckey")
  if _sg_has "$QC_BODY" "$restr"; then
    status=warn restriction=country_restricted evidence=restriction_marker
    if [[ -n $country ]]; then hmsg=sg.restricted hargs="$country"; else hmsg=sg.restricted_nc hargs=""; fi
  elif _sg_has "$QC_BODY" "$product" && { [[ -z $guard ]] || _sg_has "$QC_BODY" "$guard"; }; then
    status=pass restriction=none evidence=product_page
    if [[ -n $country ]]; then hmsg=sg.available hargs="$country"; else hmsg=sg.available_nc hargs=""; fi
  else
    status=unknown restriction=unknown evidence=none
    if [[ -n $country ]]; then hmsg=sg.unknown_country hargs="$country"; else hmsg=sg.unknown hargs=""; fi
    _sg_emit "$id" "$status" "$restriction" "$country" "$evidence" insufficient_data "$hmsg" "$hargs" "$url"
    return 0
  fi
  _sg_emit "$id" "$status" "$restriction" "$country" "$evidence" "" "$hmsg" "$hargs" "$url"
}

# YouTube Premium states unavailability in the page and exposes premium product
# markers otherwise; the captured page carries no country code.
_sg_youtube_premium() {
  _sg_html youtube_premium 'https://www.youtube.com/premium?hl=en' \
    'youtube premium (is )?not available in your country' 'youtube premium' '' 'ypc'
}

# Prime Video answers with a redirect and an empty body: `/servicerestricted`
# means the country is restricted, its own offers path means the service is
# served. The Location header is the evidence; redirects are not followed.
_sg_prime_video() {
  local url='https://www.primevideo.com/' st loc
  if ((QVK_OFFLINE)); then
    QC_TOTAL=0 QC_BYTES=0
    _sg_emit prime_video skipped unknown "" none offline_mode sg.offline "" "$url"
    return 0
  fi
  qvk_curl sg_prime_video "$url" -A "$QVK_SG_UA"
  if ((QC_RC == 63)) || _sg_too_big; then
    _sg_emit prime_video unknown unknown "" none insufficient_data sg.truncated "" "$url"
    return 0
  fi
  read -r st _ <<<"$(qvk_curl_outcome "$QC_RC")"
  if [[ $st != pass ]]; then
    _sg_failure prime_video "$url"
    return 0
  fi
  case $QC_CODE in
    3??)
      loc=$(grep -i -m1 '^location:' "$QC_HDR" 2>/dev/null | sed -E 's/^[^:]+:[[:space:]]*//; s/\r$//')
      case $loc in
        /servicerestricted | /servicerestricted\?* | /servicerestricted/*)
          _sg_emit prime_video warn country_restricted "" restriction_marker "" sg.restricted_nc "" "$url"
          ;;
        /offers/*)
          _sg_emit prime_video pass none "" redirect "" sg.available_nc "" "$url"
          ;;
        *)
          _sg_emit prime_video unknown unknown "" none http_error sg.failed "$QC_CODE" "$url" unknown
          ;;
      esac
      ;;
    2??)
      _sg_emit prime_video unknown unknown "" none insufficient_data sg.unknown "" "$url"
      ;;
    *)
      _sg_failure prime_video "$url"
      ;;
  esac
}

# Spotify signup states country availability as a boolean; the query carries a
# published web key, so the recorded endpoint is the bare path.
_sg_spotify_signup() {
  local url='https://spclient.wg.spotify.com/signup/public/v1/account/' st country
  local full="$url?validate=1&key=$QVK_SG_SPOTIFY_KEY"
  if ((QVK_OFFLINE)); then
    QC_TOTAL=0 QC_BYTES=0
    _sg_emit spotify_signup skipped unknown "" none offline_mode sg.offline "" "$url"
    return 0
  fi
  qvk_curl sg_spotify_signup "$full" -A "$QVK_SG_UA"
  if ((QC_RC == 63)) || _sg_too_big; then
    _sg_emit spotify_signup unknown unknown "" none insufficient_data sg.truncated "" "$url"
    return 0
  fi
  read -r st _ <<<"$(qvk_curl_outcome "$QC_RC")"
  if [[ $st != pass || $QC_CODE != 2?? ]]; then
    _sg_failure spotify_signup "$url"
    return 0
  fi
  country=$(_sg_country "$QC_BODY" country)
  if _sg_has "$QC_BODY" '"is_country_launched"[[:space:]]*:[[:space:]]*false[[:space:]]*[,}]'; then
    _sg_emit spotify_signup warn country_restricted "$country" availability_flag "" \
      "$([[ -n $country ]] && echo sg.restricted || echo sg.restricted_nc)" "$country" "$url"
  elif _sg_has "$QC_BODY" '"is_country_launched"[[:space:]]*:[[:space:]]*true[[:space:]]*[,}]'; then
    _sg_emit spotify_signup pass none "$country" availability_flag "" \
      "$([[ -n $country ]] && echo sg.available || echo sg.available_nc)" "$country" "$url"
  else
    _sg_emit spotify_signup unknown unknown "$country" none insufficient_data sg.unknown "" "$url"
  fi
}

qvk_service_geo_run() {
  local id
  for id in "${QVK_SG_SERVICES[@]}"; do
    "_sg_$id"
  done
}
