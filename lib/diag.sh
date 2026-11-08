# shellcheck shell=bash
# Extra diagnostics for profile `full` (QVK-02): path MTU (tracepath), ICMP RTT
# (ping) and a resolver comparison (dig). All tools are optional: a missing tool
# gives `skipped` / `tool_missing`. Nothing here changes the verdict.
#
# ICMP and traceroute-style probes are often filtered; their silence is not
# evidence of anything beyond "no reply to this probe" (the TCP tests are
# reported separately).

QVK_DIAG_CMD_TIMEOUT=25
QVK_ICMP_COUNT=5
QVK_DNS_PUBLIC_RESOLVERS=(1.1.1.1 8.8.8.8)

_diag_cmd() { timeout -k 1 "$QVK_DIAG_CMD_TIMEOUT" "$@" 2>/dev/null; }

_diag_skip() {
  local id=$1 method=$2 code=$3 reason=$4 hmsg=$5 endpoint=${6:-}
  qvk_add_test id="$id" section=network_egress method="$method" endpoint="$endpoint" \
    status=skipped reason_code="$code" reason="$reason" hmsg="$hmsg"
}

# --- path MTU ---------------------------------------------------------------------------

_diag_path_mtu() {
  local host out pmtu imtu metrics status reason hmsg
  host=$(qvk_url_host "$(qvk_endpoints baseline | head -n1 | cut -d' ' -f2)")
  [[ -n $host ]] || return 0
  if ((QVK_OFFLINE)); then
    _diag_skip path_mtu tracepath offline_mode "--offline: no external requests" net.offline "$host"
    return 0
  fi
  if ! qvk_tool tracepath; then
    _diag_skip path_mtu tracepath tool_missing "tracepath is not installed" diag.no_tool "$host"
    return 0
  fi
  qvk_progress "$(msg progress.pmtu)"
  out=$(_diag_cmd tracepath -n -m 12 "$host")
  pmtu=$(grep -oE 'pmtu [0-9]+' <<<"$out" | tail -n1 | cut -d' ' -f2)
  imtu=${QVK_SYS[net.interface_mtu]:-}
  metrics=$(json_obj path_mtu_bytes "$(json_num "$pmtu")" interface_mtu_bytes "$(json_num "$imtu")")
  if [[ -z $pmtu ]]; then
    qvk_add_test id=path_mtu section=network_egress method=tracepath endpoint="$host" status=unknown \
      reason_code=insufficient_data reason="tracepath produced no path MTU" metrics="$metrics" \
      timeout_ms=$((QVK_DIAG_CMD_TIMEOUT * 1000)) hmsg=diag.pmtu_unknown
    return 0
  fi
  status=pass reason="" hmsg=diag.pmtu_ok
  if [[ $imtu =~ ^[0-9]+$ ]] && ((pmtu < imtu)); then
    status=warn hmsg=diag.pmtu_low
    reason="path MTU ($pmtu) is below the interface MTU ($imtu): size VPN tunnel MTU accordingly"
  fi
  qvk_add_test id=path_mtu section=network_egress method=tracepath endpoint="$host" status="$status" \
    reason="$reason" samples=1 timeout_ms=$((QVK_DIAG_CMD_TIMEOUT * 1000)) metrics="$metrics" \
    details="$(json_obj towards "$(json_str "$host")" note "$(json_str "UDP probe; a value equal to the interface MTU is the common case")")" \
    hmsg="$hmsg" hargs="$pmtu${QVK_US}${imtu:-?}"
}

# --- ICMP RTT -----------------------------------------------------------------------------

_diag_icmp() {
  local name url host out sent recv loss min avg max metrics status code reason
  while read -r name url; do
    [[ -n $name ]] || continue
    host=$(qvk_url_host "$url")
    local id="icmp_rtt_ru_$name"
    if ((QVK_OFFLINE)); then
      _diag_skip "$id" ping offline_mode "--offline: no external requests" net.offline "$host"
      continue
    fi
    if ! qvk_tool ping; then
      _diag_skip "$id" ping tool_missing "ping is not installed" diag.no_tool "$host"
      continue
    fi
    out=$(_diag_cmd ping -n -c "$QVK_ICMP_COUNT" -W 2 "$host")
    sent="" recv="" loss="" min="" avg="" max=""
    if [[ $out =~ ([0-9]+)\ packets\ transmitted,\ ([0-9]+)\ (packets\ )?received ]]; then
      sent=${BASH_REMATCH[1]} recv=${BASH_REMATCH[2]}
    fi
    if [[ $out =~ ([0-9.]+)%\ packet\ loss ]]; then loss=${BASH_REMATCH[1]}; fi
    if [[ $out =~ =\ ([0-9.]+)/([0-9.]+)/([0-9.]+)/[0-9.]+\ ms ]]; then
      min=${BASH_REMATCH[1]} avg=${BASH_REMATCH[2]} max=${BASH_REMATCH[3]}
    fi
    metrics=$(json_obj icmp_rtt_ms_min "$(json_num "$min")" icmp_rtt_ms_avg "$(json_num "$avg")" \
      icmp_rtt_ms_max "$(json_num "$max")" packet_loss_pct "$(json_num "$loss")")
    status=pass code="" reason=""
    if [[ -z $sent ]]; then
      status=unknown code=insufficient_data reason="ping output could not be parsed"
    elif ((recv == 0)); then
      status=unknown code=icmp_no_reply
      reason="no ICMP reply from $host; ICMP is often filtered, which says nothing about TCP/UDP (see the TCP RTT test)"
    elif [[ $loss != 0 && $loss != 0.0 ]]; then
      status=warn
      reason="$loss% packet loss over $sent probes (a few probes only; not a stable loss figure)"
    fi
    local hmsg=diag.icmp_ok hargs
    hargs="$host${QVK_US}${avg:-?}${QVK_US}${min:-?}${QVK_US}${max:-?}${QVK_US}${loss:-?}"
    if [[ $status == unknown ]]; then
      hmsg=diag.icmp_none hargs=$host # printf would recycle surplus arguments
    fi
    qvk_add_test id="$id" section=network_egress method=ping endpoint="$host" status="$status" \
      reason_code="$code" reason="$reason" samples="${sent:-$QVK_ICMP_COUNT}" \
      timeout_ms=$((QVK_DIAG_CMD_TIMEOUT * 1000)) metrics="$metrics" hmsg="$hmsg" hargs="$hargs"
  done < <(qvk_endpoints rtt_ru)
}

# --- resolver comparison ----------------------------------------------------------------------

# _dig_answers <resolver|""> <name> -> prints IPv4 answers, one per line
_dig_answers() {
  local resolver=$1 name=$2 line
  if [[ -n $resolver ]]; then
    _diag_cmd dig +short +time=3 +tries=1 "@$resolver" "$name" A
  else
    _diag_cmd dig +short +time=3 +tries=1 "$name" A
  fi | while read -r line; do
    [[ $(qvk_ipv4_class "$line") != invalid ]] && printf '%s\n' "$line"
  done
}

_diag_dns_compare() {
  local names=() n r name url res ans cnt mismatch=0 mism_names=() resolvers=() summary=() sys_has any_public
  while read -r name url; do
    [[ -n $name ]] && names+=("$(qvk_url_host "$url")")
  done < <(qvk_endpoints baseline)
  ((${#names[@]})) || return 0
  if ((QVK_OFFLINE)); then
    _diag_skip dns_resolvers dig offline_mode "--offline: no external requests" net.offline
    return 0
  fi
  if ! qvk_tool dig; then
    _diag_skip dns_resolvers dig tool_missing "dig is not installed" diag.no_tool
    return 0
  fi
  qvk_progress "$(msg progress.dns)"
  resolvers=("" "${QVK_DNS_PUBLIC_RESOLVERS[@]}")
  local -A got=()
  for n in "${names[@]}"; do
    for r in "${resolvers[@]}"; do
      ans=$(_dig_answers "$r" "$n")
      cnt=0
      [[ -n $ans ]] && cnt=$(grep -c . <<<"$ans")
      got["$n|${r:-system}"]=$cnt
    done
    sys_has=${got["$n|system"]}
    any_public=0
    for r in "${QVK_DNS_PUBLIC_RESOLVERS[@]}"; do ((got["$n|$r"] > 0)) && any_public=1; done
    if ((sys_has == 0 && any_public == 1)); then
      mismatch=$((mismatch + 1))
      mism_names+=("$n")
    fi
  done
  for r in "${resolvers[@]}"; do
    cnt=0
    for n in "${names[@]}"; do ((got["$n|${r:-system}"] > 0)) && cnt=$((cnt + 1)); done
    summary+=("$(json_obj resolver "$(json_str "${r:-system}")" names_resolved "$cnt" names_queried "${#names[@]}")")
  done
  res=$(json_obj resolvers "$(json_arr "${summary[@]}")" \
    mismatching_names "$(json_str_arr "${mism_names[@]}")" \
    note "$(json_str "answers are compared for presence only; CDN names legitimately return different addresses per resolver")")
  if ((mismatch > 0)); then
    qvk_add_test id=dns_resolvers section=network_egress method=dig_compare status=warn \
      reason_code=dns_failure \
      reason="the system resolver returned no address for ${mism_names[*]} while public resolvers did; this indicates a resolver problem or DNS interference, not a verdict on routes" \
      samples=$((${#names[@]} * ${#resolvers[@]})) details="$res" hmsg=diag.dns_mismatch \
      hargs="$mismatch${QVK_US}${#names[@]}"
  else
    qvk_add_test id=dns_resolvers section=network_egress method=dig_compare status=pass \
      samples=$((${#names[@]} * ${#resolvers[@]})) details="$res" hmsg=diag.dns_same \
      hargs="${#resolvers[@]}${QVK_US}${#names[@]}"
  fi
}

qvk_diag_run() {
  [[ $QVK_PROFILE == full ]] || return 0
  _diag_path_mtu
  _diag_icmp
  _diag_dns_compare
}
