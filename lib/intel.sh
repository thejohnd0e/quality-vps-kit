# shellcheck shell=bash
# State shared with lib/report.sh.
# shellcheck disable=SC2034

# IP intelligence (section ip_intelligence, QVK-05) and geo consensus.
#
# Sources are independent: each yields its own test record (status, timing,
# traffic) and one entry in ip_intelligence.sources. A missing key, a rate limit
# or an outage makes that source `skipped`/`unknown`, never fails the run.
#
# Secrets come from the environment only (IPINFO_TOKEN, ABUSEIPDB_API_KEY) and
# are passed to curl through a 0600 header file, never on the command line and
# never into the report or logs.
#
# These services receive the target's public IP (documented in docs/security.md).
# A score from one provider is not an objective probability of being blocked.

QVK_INTEL_SOURCES=()
QVK_GEO_JSON="null"
QVK_GEO_COUNTRIES=""
QVK_GEO_CONFLICT=""
declare -gA QVK_GEO=()   # source -> ISO 3166 alpha-2 country as that source sees the IP
QVK_GEO_ORDER=()

QVK_RETRY_DELAY_S=1

QVK_RIPESTAT_URL="https://stat.ripe.net/data/prefix-overview/data.json?resource="
QVK_IPINFO_URL="https://ipinfo.io/"
QVK_ABUSEIPDB_URL="https://api.abuseipdb.com/api/v2/check?ipAddress="
QVK_NETCOFFEE_URL="https://ip.net.coffee/api/iprisk/"

# Last netcoffee answer, kept for the risk assessment (the shared A_* attributes
# are reset by every source).
QVK_NC_OK=0
QVK_NC_ASN="" QVK_NC_HOLDER="" QVK_NC_COUNTRY="" QVK_NC_TRUST="" QVK_NC_RESID=""
QVK_NC_VPN="" QVK_NC_PROXY="" QVK_NC_TOR="" QVK_NC_CRAWLER="" QVK_NC_ABUSER=""

qvk_geo_add() {
  local src=$1 cc=$2
  [[ $cc =~ ^[A-Z]{2}$ ]] || return 0
  [[ -n ${QVK_GEO[$src]+x} ]] || QVK_GEO_ORDER+=("$src")
  QVK_GEO[$src]=$cc
}

# --- tiny JSON field extractors (no jq); values are untrusted data ------------------

# _jstr <file> <key> -> first string value of "key" (no escaped quotes handled)
_jstr() {
  grep -m1 -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null \
    | head -n1 | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//'
}
_jnum() {
  grep -m1 -oE "\"$2\"[[:space:]]*:[[:space:]]*-?[0-9]+" "$1" 2>/dev/null \
    | head -n1 | sed -E 's/^.*:[[:space:]]*//'
}
_jbool() {
  grep -m1 -oE "\"$2\"[[:space:]]*:[[:space:]]*(true|false)" "$1" 2>/dev/null \
    | head -n1 | sed -E 's/^.*:[[:space:]]*//'
}

# net.coffee fields are untrusted. Require a complete scalar token and its JSON
# delimiter so prefixes such as `trueish` and `8.9` cannot be misread.
_nc_num() {
  grep -m1 -oE "\"$2\"[[:space:]]*:[[:space:]]*[0-9]+([[:space:]]*[,}]|[[:space:]]*$)" "$1" 2>/dev/null \
    | head -n1 | sed -E 's/^.*:[[:space:]]*//; s/[[:space:],}]//g'
}
_nc_bool() {
  grep -m1 -oE "\"$2\"[[:space:]]*:[[:space:]]*(true|false)([[:space:]]*[,}]|[[:space:]]*$)" "$1" 2>/dev/null \
    | head -n1 | sed -E 's/^.*:[[:space:]]*//; s/[[:space:],}]//g'
}
_nc_json_object() {
  local first last
  first=$(sed -n '/[^[:space:]]/{s/^[[:space:]]*//;p;q;}' "$1")
  last=$(tac "$1" | sed -n '/[^[:space:]]/{s/^[[:space:]]*//;p;q;}')
  [[ $first == \{* && $last == *\} ]]
}

# --- request with at most one retry on transient failures -----------------------------

_INTEL_BYTES=0
_INTEL_MS=0

# _intel_request <tag> <url> [curl args...]
_intel_request() {
  local tag=$1 url=$2 try t0 rc
  shift 2
  _INTEL_BYTES=0
  t0=$EPOCHREALTIME
  for try in 1 2; do
    qvk_curl "$tag" "$url" "$@"
    rc=$QC_RC
    _INTEL_BYTES=$((_INTEL_BYTES + QC_BYTES))
    case $rc in
      28 | 7 | 52 | 56) ;;                       # transient: retry once
      0) [[ $QC_CODE == 5* ]] || break ;;        # 5xx: retry once
      *) break ;;
    esac
    ((try < 2)) && sleep "$QVK_RETRY_DELAY_S"
  done
  _INTEL_MS=$(awk -v a="$t0" -v b="$EPOCHREALTIME" 'BEGIN { printf "%d", (b - a) * 1000 }')
}

# Classify the last response. Sets I_STATUS and I_CODE; I_STATUS empty = HTTP 200.
_intel_classify() {
  local st code
  I_STATUS="" I_CODE=""
  read -r st code <<<"$(qvk_curl_outcome "$QC_RC")"
  if [[ $st != pass ]]; then
    I_STATUS=$st I_CODE=$code
    return 0
  fi
  case $QC_CODE in
    200) ;;
    429) I_STATUS=skipped I_CODE=rate_limited ;;
    401 | 403) I_STATUS=unknown I_CODE=http_403 ;;
    *) I_STATUS=unknown I_CODE=http_error ;;
  esac
}

_intel_reason() {
  case $I_CODE in
    rate_limited) printf 'the service answered HTTP 429 (rate limit); not an error of this VPS' ;;
    http_403) printf 'the service answered HTTP %s (access denied or key rejected)' "$QC_CODE" ;;
    http_error) printf 'unexpected HTTP status %s' "$QC_CODE" ;;
    invalid_answer) printf 'the answer could not be parsed' ;;
    *) printf '%s' "${QC_ERR:-request failed ($I_CODE)}" ;;
  esac
}

# _intel_source_json <source> <test_id> <status> <code> then attribute pairs via globals
_intel_source_json() {
  local source=$1 test_id=$2 status=$3 code=$4
  json_obj \
    source "$(json_str "$source")" \
    test_id "$(json_str "$test_id")" \
    status "$(json_str "$status")" \
    reason_code "$(json_str_or_null "$code")" \
    queried_at "$(json_str "$(qvk_now_utc)")" \
    asn "$(json_num "${A_ASN:-}")" \
    asn_holder "$(json_str_or_null "${A_HOLDER:-}")" \
    prefix "$(json_str_or_null "${A_PREFIX:-}")" \
    announced "$(json_bool "${A_ANNOUNCED:-}")" \
    country "$(json_str_or_null "${A_COUNTRY:-}")" \
    hostname "$(json_str_or_null "${A_HOSTNAME:-}")" \
    hosting "$(json_bool "${A_HOSTING:-}")" \
    abuse_confidence_pct "$(json_num "${A_ABUSE_PCT:-}")" \
    abuse_reports "$(json_num "${A_ABUSE_REPORTS:-}")" \
    usage_type "$(json_str_or_null "${A_USAGE:-}")" \
    trust_score "$(json_num "${A_TRUST:-}")" \
    residential "$(json_bool "${A_RESID:-}")" \
    vpn "$(json_bool "${A_VPN:-}")" \
    proxy "$(json_bool "${A_PROXY:-}")" \
    tor "$(json_bool "${A_TOR:-}")" \
    crawler "$(json_bool "${A_CRAWLER:-}")" \
    abuser "$(json_bool "${A_ABUSER:-}")"
}

_intel_reset_attrs() {
  A_ASN="" A_HOLDER="" A_PREFIX="" A_ANNOUNCED="" A_COUNTRY="" A_HOSTNAME=""
  A_HOSTING="" A_ABUSE_PCT="" A_ABUSE_REPORTS="" A_USAGE=""
  A_TRUST="" A_RESID="" A_VPN="" A_PROXY="" A_TOR="" A_CRAWLER="" A_ABUSER=""
}

# Secret header file; echoes its path. The caller removes it.
_intel_header_file() {
  local f
  f="$(qvk_tmpdir)/hdr.$1"
  printf '%s\n' "$2" >"$f"
  chmod 600 "$f" 2>/dev/null || true
  printf '%s' "$f"
}

# _intel_emit <source> <method> <endpoint> <status> <code> <reason> <hmsg> <hargs>
_intel_emit() {
  local source=$1 method=$2 endpoint=$3 status=$4 code=$5 reason=$6 hmsg=$7 hargs=$8
  local id="intel_$source"
  QVK_INTEL_SOURCES+=("$(_intel_source_json "$source" "$id" "$status" "$code")")
  qvk_add_test id="$id" section=ip_intelligence method="$method" endpoint="$endpoint" \
    status="$status" reason_code="$code" reason="$reason" samples=1 \
    timeout_ms=$((QVK_HTTP_MAX_TIME * 1000)) duration_ms="$_INTEL_MS" traffic_bytes="$_INTEL_BYTES" \
    hmsg="$hmsg" hargs="$hargs"
}

# --- sources --------------------------------------------------------------------------

_intel_ripestat() {
  local ip=$1 body data asn="" holder="" prefix="" announced=""
  _intel_reset_attrs
  _intel_request intel_ripe "$QVK_RIPESTAT_URL$ip"
  _intel_classify
  if [[ -n $I_STATUS ]]; then
    _intel_emit ripestat ripestat_prefix_overview "${QVK_RIPESTAT_URL%\?*}" "$I_STATUS" "$I_CODE" \
      "$(_intel_reason)" intel.fail "$I_CODE"
    return 0
  fi
  body=$QC_BODY
  data=$(sed -E 's/.*"data":\{//' "$body" 2>/dev/null | head -c 20000)
  announced=$(grep -oE '"announced":(true|false)' <<<"$data" | head -n1 | cut -d: -f2)
  if [[ $data =~ \"asns\":\[\{\"asn\":([0-9]+),\"holder\":\"([^\"]*)\" ]]; then
    asn=${BASH_REMATCH[1]} holder=${BASH_REMATCH[2]}
  fi
  if [[ $data =~ \"resource\":\"([0-9A-Fa-f.:]+/[0-9]{1,3})\",\"type\":\"prefix\" ]]; then
    prefix=${BASH_REMATCH[1]}
  fi
  if [[ -z $announced ]]; then
    I_CODE=invalid_answer
    _intel_emit ripestat ripestat_prefix_overview "${QVK_RIPESTAT_URL%\?*}" unknown "$I_CODE" \
      "$(_intel_reason)" intel.fail "$I_CODE"
    return 0
  fi
  A_ASN=$asn A_HOLDER=$holder A_PREFIX=$prefix A_ANNOUNCED=$announced
  ((QVK_REDACT)) && A_PREFIX=""   # a prefix reveals the address neighbourhood
  if [[ $announced == true && -n $asn ]]; then
    if [[ -n $A_PREFIX ]]; then
      _intel_emit ripestat ripestat_prefix_overview "${QVK_RIPESTAT_URL%\?*}" pass "" "" \
        intel.ripe_ok "$asn${QVK_US}$holder${QVK_US}$A_PREFIX"
    else
      _intel_emit ripestat ripestat_prefix_overview "${QVK_RIPESTAT_URL%\?*}" pass "" "" \
        intel.ripe_ok_np "$asn${QVK_US}$holder"
    fi
  else
    _intel_emit ripestat ripestat_prefix_overview "${QVK_RIPESTAT_URL%\?*}" warn "" \
      "the address is not announced in BGP according to RIPEstat" intel.ripe_unannounced ""
  fi
}

_intel_ipinfo() {
  local ip=$1 token=${IPINFO_TOKEN:-} hf="" org cc host hosting
  _intel_reset_attrs
  if [[ -n $token ]]; then
    hf=$(_intel_header_file ipinfo "Authorization: Bearer $token")
    _intel_request intel_ipinfo "$QVK_IPINFO_URL$ip/json" -H "@$hf"
    rm -f -- "$hf"
  else
    _intel_request intel_ipinfo "$QVK_IPINFO_URL$ip/json"
  fi
  _intel_classify
  if [[ -n $I_STATUS ]]; then
    _intel_emit ipinfo ipinfo_json "${QVK_IPINFO_URL}<ip>/json" "$I_STATUS" "$I_CODE" \
      "$(_intel_reason)" intel.fail "$I_CODE"
    return 0
  fi
  cc=$(_jstr "$QC_BODY" country)
  org=$(_jstr "$QC_BODY" org)
  host=$(_jstr "$QC_BODY" hostname)
  hosting=$(_jbool "$QC_BODY" hosting)
  if [[ -z $cc && -z $org ]]; then
    I_CODE=invalid_answer
    _intel_emit ipinfo ipinfo_json "${QVK_IPINFO_URL}<ip>/json" unknown "$I_CODE" \
      "$(_intel_reason)" intel.fail "$I_CODE"
    return 0
  fi
  if [[ $org =~ ^AS([0-9]+)[[:space:]]+(.*)$ ]]; then
    A_ASN=${BASH_REMATCH[1]} A_HOLDER=${BASH_REMATCH[2]}
  else
    A_HOLDER=$org
  fi
  [[ $cc =~ ^[A-Z]{2}$ ]] && A_COUNTRY=$cc
  ((QVK_REDACT)) || A_HOSTNAME=$host   # reverse DNS often embeds the address
  A_HOSTING=$hosting
  qvk_geo_add ipinfo "$A_COUNTRY"
  _intel_emit ipinfo ipinfo_json "${QVK_IPINFO_URL}<ip>/json" pass "" "" \
    intel.ipinfo_ok "${A_COUNTRY:-?}${QVK_US}${org:-?}"
}

_intel_abuseipdb() {
  local ip=$1 key=${ABUSEIPDB_API_KEY:-} hf pct reports usage cc
  _intel_reset_attrs
  _INTEL_MS=0 _INTEL_BYTES=0
  if [[ -z $key ]]; then
    _intel_emit abuseipdb abuseipdb_check "${QVK_ABUSEIPDB_URL%\?*}" skipped no_api_key \
      "set ABUSEIPDB_API_KEY in the environment to enable this source" intel.no_key ABUSEIPDB_API_KEY
    return 0
  fi
  hf=$(_intel_header_file abuseipdb "Key: $key")
  _intel_request intel_abuse "$QVK_ABUSEIPDB_URL$ip&maxAgeInDays=90" -H "@$hf" -H "Accept: application/json"
  rm -f -- "$hf"
  _intel_classify
  if [[ -n $I_STATUS ]]; then
    _intel_emit abuseipdb abuseipdb_check "${QVK_ABUSEIPDB_URL%\?*}" "$I_STATUS" "$I_CODE" \
      "$(_intel_reason)" intel.fail "$I_CODE"
    return 0
  fi
  pct=$(_jnum "$QC_BODY" abuseConfidenceScore)
  reports=$(_jnum "$QC_BODY" totalReports)
  usage=$(_jstr "$QC_BODY" usageType)
  cc=$(_jstr "$QC_BODY" countryCode)
  if [[ -z $pct ]]; then
    I_CODE=invalid_answer
    _intel_emit abuseipdb abuseipdb_check "${QVK_ABUSEIPDB_URL%\?*}" unknown "$I_CODE" \
      "$(_intel_reason)" intel.fail "$I_CODE"
    return 0
  fi
  A_ABUSE_PCT=$pct A_ABUSE_REPORTS=$reports A_USAGE=$usage
  [[ $cc =~ ^[A-Z]{2}$ ]] && A_COUNTRY=$cc
  qvk_geo_add abuseipdb "$A_COUNTRY"
  _intel_emit abuseipdb abuseipdb_check "${QVK_ABUSEIPDB_URL%\?*}" pass "" \
    "" intel.abuse_ok "$pct${QVK_US}${reports:-0}"
}

# net.coffee: one provider's risk view of this IP (undocumented public JSON API).
# Failure only degrades the report: the source is recorded and the run continues.
_intel_netcoffee() {
  local ip=$1 cc trust resid asn holder
  _intel_reset_attrs
  QVK_NC_OK=0
  QVK_NC_ASN="" QVK_NC_HOLDER="" QVK_NC_COUNTRY="" QVK_NC_TRUST="" QVK_NC_RESID=""
  QVK_NC_VPN="" QVK_NC_PROXY="" QVK_NC_TOR="" QVK_NC_CRAWLER="" QVK_NC_ABUSER=""
  _intel_request intel_netcoffee "$QVK_NETCOFFEE_URL$ip"
  _intel_classify
  if [[ -n $I_STATUS ]]; then
    _intel_emit netcoffee netcoffee_iprisk "${QVK_NETCOFFEE_URL}<ip>" "$I_STATUS" "$I_CODE" \
      "$(_intel_reason)" intel.fail "$I_CODE"
    return 0
  fi
  if ! _nc_json_object "$QC_BODY"; then
    I_CODE=invalid_answer
    _intel_emit netcoffee netcoffee_iprisk "${QVK_NETCOFFEE_URL}<ip>" unknown "$I_CODE" \
      "$(_intel_reason)" intel.fail "$I_CODE"
    return 0
  fi
  cc=$(_jstr "$QC_BODY" countryCode)
  cc=${cc^^}
  [[ $cc =~ ^[A-Z]{2}$ ]] || cc=""
  trust=$(_nc_num "$QC_BODY" trust_score)
  if [[ $trust =~ ^[0-9]{1,3}$ ]] && ((10#$trust <= 100)); then
    while [[ ${#trust} -gt 1 && $trust == 0* ]]; do trust=${trust#0}; done
  else
    trust=""
  fi
  asn=$(_nc_num "$QC_BODY" asn)
  [[ $asn =~ ^[0-9]{1,10}$ ]] || asn=""
  holder=$(_jstr "$QC_BODY" asOrganization)
  holder=${holder:0:120}
  resid=$(_nc_bool "$QC_BODY" isResidential)
  A_VPN=$(_nc_bool "$QC_BODY" is_vpn)
  A_PROXY=$(_nc_bool "$QC_BODY" is_proxy)
  A_TOR=$(_nc_bool "$QC_BODY" is_tor)
  A_CRAWLER=$(_nc_bool "$QC_BODY" is_crawler)
  A_ABUSER=$(_nc_bool "$QC_BODY" is_abuser)
  if [[ -z $cc && -z $trust && -z $A_VPN && -z $A_PROXY && -z $A_TOR && -z $A_CRAWLER && -z $A_ABUSER ]]; then
    I_CODE=invalid_answer
    _intel_emit netcoffee netcoffee_iprisk "${QVK_NETCOFFEE_URL}<ip>" unknown "$I_CODE" \
      "$(_intel_reason)" intel.fail "$I_CODE"
    return 0
  fi
  A_ASN=$asn A_HOLDER=$holder A_COUNTRY=$cc A_TRUST=$trust A_RESID=$resid
  [[ $resid == false ]] && A_HOSTING=true
  QVK_NC_OK=1
  QVK_NC_ASN=$asn QVK_NC_HOLDER=$holder QVK_NC_COUNTRY=$cc QVK_NC_TRUST=$trust
  QVK_NC_RESID=$resid QVK_NC_VPN=$A_VPN QVK_NC_PROXY=$A_PROXY QVK_NC_TOR=$A_TOR
  QVK_NC_CRAWLER=$A_CRAWLER QVK_NC_ABUSER=$A_ABUSER
  _intel_emit netcoffee netcoffee_iprisk "${QVK_NETCOFFEE_URL}<ip>" pass "" "" \
    intel.netcoffee_ok "${trust:-?}${QVK_US}${cc:-?}"
}

_intel_skip_all() {
  local code=$1 reason=$2 hmsg=$3 s
  _INTEL_MS=0 _INTEL_BYTES=0
  _intel_reset_attrs
  for s in ripestat:ripestat_prefix_overview ipinfo:ipinfo_json abuseipdb:abuseipdb_check \
    netcoffee:netcoffee_iprisk; do
    _intel_emit "${s%%:*}" "${s#*:}" "" skipped "$code" "$reason" "$hmsg" ""
  done
}

# Country agreement across independent sources (registry data excluded).
qvk_geo_consensus() {
  local s cc items=() uniq=() n=${#QVK_GEO_ORDER[@]}
  if ((QVK_OFFLINE)) || [[ -z $QVK_TARGET_IP ]]; then
    QVK_GEO_JSON=null
    return 0
  fi
  for s in "${QVK_GEO_ORDER[@]}"; do
    cc=${QVK_GEO[$s]}
    items+=("$(json_obj source "$(json_str "$s")" country "$(json_str "$cc")")")
  done
  if ((n)); then
    mapfile -t uniq < <(for s in "${QVK_GEO_ORDER[@]}"; do printf '%s\n' "${QVK_GEO[$s]}"; done | sort -u)
  fi
  QVK_GEO_COUNTRIES=$(printf '%s ' "${uniq[@]}")
  QVK_GEO_COUNTRIES=${QVK_GEO_COUNTRIES% }
  if ((n < 2)); then
    QVK_GEO_CONFLICT=""
  elif ((${#uniq[@]} > 1)); then
    QVK_GEO_CONFLICT=true
  else
    QVK_GEO_CONFLICT=false
  fi
  QVK_GEO_JSON=$(json_obj \
    sources "$(json_arr "${items[@]}")" \
    countries "$(json_str_arr "${uniq[@]}")" \
    geo_conflict "$(json_bool "$QVK_GEO_CONFLICT")" \
    note "$(json_str "countries as reported by the listed services; says nothing about whether a given service works")")
}

# Regions where Claude blocks or heavily restricts access, as listed by the
# net.coffee frontend on 2026-11-09. The date and source are part of the rule:
# the list can change, and Claude's own policy is not ours to state.
QVK_CLAUDE_RESTRICTED="CN HK MO RU KP IR SY CU BY VE"

QVK_CLAUDE_RISK_JSON="" QVK_CLAUDE_RISK_LEVEL="" QVK_CLAUDE_RISK_COUNTRY=""
QVK_CLAUDE_RISK_TRUST="" QVK_CLAUDE_RISK_RESTRICTED=""
QVK_CLAUDE_RISK_REASONS=()

# Turn the collected IP facts into a documented risk level for Claude.
# Rules: docs/methodology.md. One provider's judgement, not Claude's decision.
qvk_claude_risk_evaluate() {
  local country trust resid level="" restricted="" r has_high=0 has_med=0
  local -a reasons=() uniq=() rj=()
  country=$QVK_NC_COUNTRY
  [[ -n $country ]] || country=${QVK_GEO[ipinfo]:-}
  if [[ -z $country && -n ${QVK_GEO_COUNTRIES:-} ]]; then
    read -r -a uniq <<<"$QVK_GEO_COUNTRIES"
    ((${#uniq[@]} == 1)) && country=${uniq[0]}
  fi
  [[ $country =~ ^[A-Z]{2}$ ]] || country=""
  trust=$QVK_NC_TRUST
  resid=$QVK_NC_RESID
  if [[ -n $country ]]; then
    if [[ " $QVK_CLAUDE_RESTRICTED " == *" $country "* ]]; then
      restricted=true
    else
      restricted=false
    fi
  fi
  QVK_CLAUDE_RISK_COUNTRY=$country
  QVK_CLAUDE_RISK_TRUST=$trust
  QVK_CLAUDE_RISK_RESTRICTED=$restricted
  if ((${QVK_OFFLINE:-0})) || [[ -z $QVK_TARGET_IP ]]; then
    level=unknown reasons=(no_data)
  else
    [[ $restricted == true ]] && reasons+=(restricted_region)
    [[ $QVK_NC_TOR == true ]] && reasons+=(tor_exit)
    [[ $QVK_NC_CRAWLER == true ]] && reasons+=(crawler)
    if [[ -n $trust ]] && ((trust < 50)); then
      reasons+=(low_trust_score)
    elif [[ -n $trust ]] && ((trust < 80)); then
      reasons+=(moderate_trust_score)
    fi
    [[ $QVK_NC_ABUSER == true ]] && reasons+=(abuse_history)
    [[ $QVK_NC_VPN == true || $QVK_NC_PROXY == true ]] && reasons+=(vpn_or_proxy)
    [[ $resid == false ]] && reasons+=(hosting_asn)
    if [[ -n $trust ]] && ((trust >= 80)) && [[ -z $resid ]] && ((${#reasons[@]} == 0)); then
      reasons+=(residential_unknown)
    fi
    for r in "${reasons[@]}"; do
      case $r in
        restricted_region | tor_exit | crawler | low_trust_score) has_high=1 ;;
        *) has_med=1 ;;
      esac
    done
    if ((has_high)); then
      level=high
    elif ((has_med)); then
      level=medium
    elif [[ -n $trust ]] && ((trust >= 80)) && [[ $resid == true ]] &&
      [[ -n $QVK_NC_VPN && -n $QVK_NC_PROXY && -n $QVK_NC_TOR && -n $QVK_NC_CRAWLER && -n $QVK_NC_ABUSER ]]; then
      level=low
    elif [[ -n $trust ]] && ((trust >= 80)) && [[ $resid == true ]]; then
      level=unknown reasons=(risk_flags_unknown)
    elif ((QVK_NC_OK == 0)); then
      level=unknown reasons=(source_unavailable)
    else
      level=unknown reasons=(no_data)
    fi
  fi
  QVK_CLAUDE_RISK_LEVEL=$level
  QVK_CLAUDE_RISK_REASONS=("${reasons[@]}")
  for r in "${reasons[@]}"; do rj+=("$(json_str "$r")"); done
  QVK_CLAUDE_RISK_JSON=$(json_obj \
    level "$(json_str "$level")" \
    reasons "$(json_arr "${rj[@]}")" \
    restricted_region "$(json_bool "$restricted")" \
    country "$(json_str_or_null "$country")" \
    trust_score "$(json_num "$trust")" \
    residential "$(json_bool "$resid")" \
    checked_ip "$(json_str_or_null "$QVK_TARGET_IP")" \
    note "$(json_str "judgement by one third-party service (net.coffee); what Claude itself decides is unknown")")
}

qvk_intel_run() {
  if ((QVK_OFFLINE)); then
    _intel_skip_all offline_mode "--offline: no external requests" net.offline
    return 0
  fi
  if [[ -z $QVK_TARGET_IP ]]; then
    _intel_skip_all not_applicable "no public egress IPv4 was determined" intel.no_ip
    return 0
  fi
  qvk_progress "$(msg progress.intel)"
  _intel_ripestat "$QVK_TARGET_IP"
  _intel_ipinfo "$QVK_TARGET_IP"
  _intel_abuseipdb "$QVK_TARGET_IP"
  _intel_netcoffee "$QVK_TARGET_IP"
}
