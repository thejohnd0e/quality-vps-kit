# shellcheck shell=bash
# State shared with lib/verdict.sh and lib/report.sh.
# shellcheck disable=SC2034

# Network checks from the target itself (section network_egress, QVK-01/02):
# egress IPv4/IPv6 with conflict detection, NAT, baseline HTTPS timing, DNS,
# TCP RTT towards Russia-hosted endpoints, clock offset from HTTP Date headers.
#
# Nothing here proves reachability FROM a client network.

QVK_TARGET_IP=""
QVK_TARGET_NAT="unknown"
QVK_EGRESS4_STATUS=""
QVK_BASELINE_PASS=0
QVK_BASELINE_RUN=0
QVK_BASELINE_NETFAIL=0
QVK_DNS_STATUS=""
QVK_CLOCK_STATUS=""

QVK_RTT_SAMPLES_QUICK=3
QVK_RTT_SAMPLES_FULL=20
QVK_CLOCK_MAX_OFFSET_S=30
QVK_RTT_PLAUSIBLE_MIN_MS=1.0

declare -gA _CLOCK_BY_HOST=()  # host -> offset sample (one per host)
_DNS_TRIED=0
_DNS_FAILED=0
_DNS_MS=()

_net_note_response() {
  local host=$1 rc=$2 off
  _DNS_TRIED=$((_DNS_TRIED + 1))
  if [[ $rc == 6 ]]; then
    _DNS_FAILED=$((_DNS_FAILED + 1))
  elif [[ -n $QC_DNS ]]; then
    _DNS_MS+=("$(qvk_ms "$QC_DNS")")
  fi
  if [[ -z ${_CLOCK_BY_HOST[$host]+x} ]]; then
    off=$(qvk_clock_offset_sample)
    [[ -n $off ]] && _CLOCK_BY_HOST[$host]=$off
  fi
  return 0
}

# Extract the caller IP from an echo response body (plain or Cloudflare trace).
_echo_ip() {
  local body=$1 ip
  if grep -q '^ip=' "$body" 2>/dev/null; then
    ip=$(grep -m1 '^ip=' "$body" | cut -d= -f2)
  else
    ip=$(head -c 100 "$body" 2>/dev/null | head -n1)
  fi
  ip=${ip//[$'\r\n\t ']/}
  printf '%s' "$ip"
}

_valid_ip() {
  local fam=$1 ip=$2
  if [[ $fam == 4 ]]; then
    [[ $(qvk_ipv4_class "$ip") == public ]]
  else
    [[ $ip == *:* && $ip =~ ^[0-9A-Fa-f:]{2,39}$ ]]
  fi
}

# _net_egress <4|6> — echo services of the family; emits test egress_ipv<fam>.
_net_egress() {
  local fam=$1 name url host outcome st rc ip traffic=0 srcs=() ips=() uniq=() fail_code="" n_err=0
  local id="egress_ipv$fam"
  while read -r name url; do
    [[ -n $name ]] || continue
    host=$(qvk_url_host "$url")
    qvk_curl "echo${fam}_$name" "$url" "-$fam"
    rc=$QC_RC
    traffic=$((traffic + QC_BYTES))
    _net_note_response "$host" "$rc"
    read -r st outcome <<<"$(qvk_curl_outcome "$rc")"
    ip=""
    if [[ $st == pass && $QC_CODE == 200 ]]; then
      ip=$(_echo_ip "$QC_BODY")
      if _valid_ip "$fam" "$ip"; then
        ips+=("$ip")
        qvk_register_ip "$ip"
        outcome=ok
      else
        ip="" outcome=invalid_answer fail_code=invalid_answer
      fi
    elif [[ $st == pass ]]; then
      outcome="http_${QC_CODE:-000}" fail_code=http_error
    else
      fail_code=$outcome
      [[ $st == error ]] && n_err=$((n_err + 1))
    fi
    srcs+=("$(json_obj source "$(json_str "$name")" ip "$(json_str_or_null "$ip")" \
      result "$(json_str "$outcome")")")
  done < <(qvk_endpoints "echo$fam")

  if ((${#ips[@]})); then
    mapfile -t uniq < <(printf '%s\n' "${ips[@]}" | sort -u)
  fi
  local n_uniq=${#uniq[@]} joined
  joined=$(printf '%s ' "${uniq[@]}")
  joined=${joined% }
  local details
  details=$(json_obj sources "$(json_arr "${srcs[@]}")" \
    note "$(json_str "an echo service shows the egress address only; it does not prove inbound reachability")")

  if ((${#srcs[@]} == 0)); then
    qvk_add_test id="$id" section=network_egress method=http_echo status=skipped \
      reason_code=not_applicable reason="no echo$fam endpoints configured" hmsg=net.skipped_cfg
    [[ $fam == 4 ]] && QVK_EGRESS4_STATUS=skipped
    return 0
  fi
  if ((n_uniq == 1)); then
    if [[ $fam == 4 ]]; then
      QVK_TARGET_IP=${uniq[0]}
      _net_nat
      details=$(json_obj sources "$(json_arr "${srcs[@]}")" nat "$(json_str "$QVK_TARGET_NAT")" \
        note "$(json_str "an echo service shows the egress address only; it does not prove inbound reachability")")
      qvk_add_test id="$id" section=network_egress method=http_echo status=pass \
        samples="${#srcs[@]}" traffic_bytes="$traffic" details="$details" \
        hmsg=net.egress4_ok \
        hargs="${uniq[0]}${QVK_US}${#ips[@]}${QVK_US}${#srcs[@]}${QVK_US}$(msg "nat.$QVK_TARGET_NAT")"
      QVK_EGRESS4_STATUS=pass
    else
      qvk_add_test id="$id" section=network_egress method=http_echo status=pass \
        samples="${#srcs[@]}" traffic_bytes="$traffic" details="$details" \
        hmsg=net.egress_ok hargs="${uniq[0]}${QVK_US}${#ips[@]}${QVK_US}${#srcs[@]}"
    fi
  elif ((n_uniq > 1)); then
    qvk_add_test id="$id" section=network_egress method=http_echo status=warn reason_code=conflict \
      reason="echo services disagree: $joined" samples="${#srcs[@]}" \
      traffic_bytes="$traffic" details="$details" hmsg=net.egress_conflict hargs="$joined"
    [[ $fam == 4 ]] && QVK_EGRESS4_STATUS=conflict
  elif ((n_err == ${#srcs[@]})); then
    # Every request failed inside the tester (curl itself): not a network verdict.
    qvk_add_test id="$id" section=network_egress method=http_echo status=error \
      reason_code=curl_error reason="curl failed locally for every echo service; this is a tester problem, not a network result" \
      samples="${#srcs[@]}" details="$details" error="$QC_ERR" hmsg=net.tester_error
    [[ $fam == 4 ]] && QVK_EGRESS4_STATUS=error
  else
    qvk_add_test id="$id" section=network_egress method=http_echo status=fail \
      reason_code="${fail_code:-curl_error}" reason="no echo service returned a valid IPv$fam address" \
      samples="${#srcs[@]}" traffic_bytes="$traffic" details="$details" hmsg=net.egress_fail
    [[ $fam == 4 ]] && QVK_EGRESS4_STATUS=fail
  fi
}

# NAT from the egress IPv4 vs. addresses on the default interface.
_net_nat() {
  local addr prefix class has_private=0 has_cgnat=0
  if [[ -z $QVK_TARGET_IP ]]; then
    QVK_TARGET_NAT=unknown
    return 0
  fi
  while read -r addr prefix class; do
    [[ -n $addr ]] || continue
    if [[ $addr == "$QVK_TARGET_IP" ]]; then
      QVK_TARGET_NAT=none
      return 0
    fi
    [[ $class == private ]] && has_private=1
    [[ $class == cgnat ]] && has_cgnat=1
  done <<<"${QVK_SYS[net.ipv4_addresses]:-}"
  if ((has_cgnat)); then
    QVK_TARGET_NAT=cgnat_suspected
  elif ((has_private)); then
    QVK_TARGET_NAT=one_to_one_suspected
  else
    QVK_TARGET_NAT=unknown
  fi
}

_timing_metrics() {
  json_obj \
    dns_ms "$(json_num "$(qvk_ms "$QC_DNS")")" \
    tcp_connect_ms "$(json_num "$(qvk_ms "$QC_CONNECT" "$QC_DNS")")" \
    tls_ms "$(json_num "$(qvk_ms "$QC_TLS" "$QC_CONNECT")")" \
    ttfb_ms "$(json_num "$(qvk_ms "$QC_TTFB" "$QC_TLS")")" \
    total_ms "$(json_num "$(qvk_ms "$QC_TOTAL")")"
}

_net_baseline() {
  local name url host st code rc details
  while read -r name url; do
    [[ -n $name ]] || continue
    host=$(qvk_url_host "$url")
    qvk_curl "base_$name" "$url"
    rc=$QC_RC
    QVK_BASELINE_RUN=$((QVK_BASELINE_RUN + 1))
    _net_note_response "$host" "$rc"
    read -r st code <<<"$(qvk_curl_outcome "$rc")"
    details=$(json_obj http_code "$(json_num "$QC_CODE")" remote_ip "$(json_str_or_null "$QC_REMOTE")")
    if [[ $st == pass ]]; then
      QVK_BASELINE_PASS=$((QVK_BASELINE_PASS + 1))
      qvk_add_test id="https_$name" section=network_egress method=curl_get endpoint="$url" \
        status=pass http_outcome=reachable samples=1 timeout_ms=$((QVK_HTTP_MAX_TIME * 1000)) \
        duration_ms="$(qvk_ms "$QC_TOTAL" | cut -d. -f1)" metrics="$(_timing_metrics)" \
        details="$details" traffic_bytes="$QC_BYTES" \
        hmsg=net.https_ok hargs="$host${QVK_US}${QC_CODE}${QVK_US}$(qvk_ms "$QC_CONNECT" "$QC_DNS")${QVK_US}$(qvk_ms "$QC_TLS" "$QC_CONNECT")"
    else
      [[ $st == fail ]] && QVK_BASELINE_NETFAIL=$((QVK_BASELINE_NETFAIL + 1))
      local hout=network_error
      [[ $code == tls_failure ]] && hout=tls_error
      [[ $st == error ]] && hout=unknown
      qvk_add_test id="https_$name" section=network_egress method=curl_get endpoint="$url" \
        status="$st" reason_code="$code" reason="$QC_ERR" http_outcome="$hout" \
        samples=1 timeout_ms=$((QVK_HTTP_MAX_TIME * 1000)) metrics="$(_timing_metrics)" \
        details="$details" traffic_bytes="$QC_BYTES" error="$QC_ERR" \
        hmsg=net.https_fail hargs="$host${QVK_US}$code"
    fi
  done < <(qvk_endpoints baseline)
}

_net_rtt_ru() {
  local name url host n i rc ok fails last_code st code samples=() traffic=0
  local stats cnt min p50 max p95 metrics status reason
  n=$QVK_RTT_SAMPLES_QUICK
  [[ $QVK_PROFILE == full ]] && n=$QVK_RTT_SAMPLES_FULL
  while read -r name url; do
    [[ -n $name ]] || continue
    host=$(qvk_url_host "$url")
    samples=() fails=0 traffic=0 last_code=""
    for ((i = 1; i <= n; i++)); do
      qvk_curl "rtt_${name}_$i" "$url" -I
      rc=$QC_RC
      traffic=$((traffic + QC_BYTES))
      ((i == 1)) && _net_note_response "$host" "$rc"
      read -r st code <<<"$(qvk_curl_outcome "$rc")"
      # curl reports time_connect = 0 when no TCP connection was made. A
      # completed handshake counts even if TLS/HTTP fails afterwards.
      if awk -v c="${QC_CONNECT:-0}" 'BEGIN { exit !(c + 0 > 0) }'; then
        ok=$(qvk_ms "$QC_CONNECT" "$QC_DNS")
        [[ -n $ok ]] && samples+=("$ok")
      else
        fails=$((fails + 1))
        last_code=$code
        [[ $st == pass ]] && last_code=curl_error
      fi
    done
    stats=$(qvk_stats "${samples[@]}")
    read -r cnt min p50 max p95 <<<"$stats"
    metrics=$(json_obj \
      rtt_ms_min "$(json_num "$(qvk_dash "$min")")" \
      rtt_ms_p50 "$(json_num "$(qvk_dash "$p50")")" \
      rtt_ms_max "$(json_num "$(qvk_dash "$max")")" \
      rtt_ms_p95 "$(json_num "$(qvk_dash "$p95")")" \
      connect_failures "$fails")
    reason="TCP handshake RTT from this VPS to a Russia-hosted endpoint; this is not reachability from a Russian client network"
    local hmsg=net.rtt
    if ((cnt == 0)); then
      status=fail
      reason="$reason; all $n attempts failed"
    elif awk -v p="$p50" -v t="$QVK_RTT_PLAUSIBLE_MIN_MS" 'BEGIN { exit !(p + 0 < t) }'; then
      # A remote host cannot answer a TCP handshake in under ~1 ms: something
      # close to this machine (transparent proxy, middlebox) terminates TCP.
      status=warn
      last_code=middlebox_suspected
      reason="TCP handshake completed in ${p50} ms, which is implausible for a remote host: a transparent proxy or middlebox near this machine likely terminates TCP, so this value does not describe the route"
      hmsg=net.rtt_middlebox
    elif ((fails > 0)); then
      status=warn
      reason="$reason; $fails of $n attempts failed"
    else
      status=pass
      last_code=""
    fi
    local hargs
    if [[ $hmsg == net.rtt_middlebox ]]; then
      hargs="$host${QVK_US}$p50"
    else
      hargs="$host${QVK_US}$(qvk_dash "$p50")${QVK_US}$(qvk_dash "$min")${QVK_US}$(qvk_dash "$max")${QVK_US}$cnt${QVK_US}$n"
    fi
    qvk_add_test id="tcp_rtt_ru_$name" section=network_egress method=curl_time_connect endpoint="$host:443" \
      status="$status" reason_code="$last_code" reason="$reason" samples="$n" \
      timeout_ms=$((QVK_RTT_MAX_TIME * 1000)) metrics="$metrics" traffic_bytes="$traffic" \
      hmsg="$hmsg" hargs="$hargs"
  done < <(qvk_endpoints rtt_ru)
}

_net_dns() {
  local f ns=() line stats cnt min p50 max p95 details metrics
  f=$(qvk_fs /etc/resolv.conf)
  if [[ -r $f ]]; then
    while read -r line; do ns+=("$line"); done < <(awk '$1 == "nameserver" {print $2}' "$f")
  fi
  stats=$(qvk_stats "${_DNS_MS[@]}")
  read -r cnt min p50 max p95 <<<"$stats"
  details=$(json_obj resolvers "$(json_str_arr "${ns[@]}")" source "$(json_str /etc/resolv.conf)")
  metrics=$(json_obj lookup_ms_p50 "$(json_num "$(qvk_dash "$p50")")" \
    lookup_ms_max "$(json_num "$(qvk_dash "$max")")" lookups "$_DNS_TRIED" failures "$_DNS_FAILED")
  if ((_DNS_TRIED == 0)); then
    QVK_DNS_STATUS=unknown
    qvk_add_test id=dns_resolution section=network_egress method=curl_namelookup status=unknown \
      reason="no lookups were attempted" details="$details" metrics="$metrics" hmsg=rd.unknown
  elif ((_DNS_FAILED == _DNS_TRIED)); then
    QVK_DNS_STATUS=fail
    qvk_add_test id=dns_resolution section=network_egress method=curl_namelookup status=fail \
      reason_code=dns_failure reason="every name lookup failed" samples="$_DNS_TRIED" \
      details="$details" metrics="$metrics" hmsg=net.dns_fail
  elif ((_DNS_FAILED > 0)); then
    QVK_DNS_STATUS=warn
    qvk_add_test id=dns_resolution section=network_egress method=curl_namelookup status=warn \
      reason_code=dns_failure reason="$_DNS_FAILED of $_DNS_TRIED lookups failed" samples="$_DNS_TRIED" \
      details="$details" metrics="$metrics" hmsg=net.dns_partial hargs="$_DNS_FAILED${QVK_US}$_DNS_TRIED"
  else
    QVK_DNS_STATUS=pass
    qvk_add_test id=dns_resolution section=network_egress method=curl_namelookup status=pass \
      samples="$_DNS_TRIED" details="$details" metrics="$metrics" \
      hmsg=net.dns_ok hargs="$_DNS_TRIED${QVK_US}$(qvk_dash "$p50")"
  fi
}

_net_clock() {
  local offs=() h stats cnt min med max p95 abs details metrics
  for h in "${!_CLOCK_BY_HOST[@]}"; do offs+=("${_CLOCK_BY_HOST[$h]}"); done
  stats=$(qvk_stats "${offs[@]}")
  read -r cnt min med max p95 <<<"$stats"
  details=$(json_obj hosts "$(json_str_arr "${!_CLOCK_BY_HOST[@]}")" \
    ntp_synchronized "$(json_bool "${QVK_SYS[time.ntp_synchronized]:-}")" \
    accuracy_s 1)
  metrics=$(json_obj offset_s "$(json_num "$(qvk_dash "$med")")" \
    offset_s_min "$(json_num "$(qvk_dash "$min")")" offset_s_max "$(json_num "$(qvk_dash "$max")")" \
    threshold_s "$QVK_CLOCK_MAX_OFFSET_S")
  if ((cnt < 3)); then
    QVK_CLOCK_STATUS=unknown
    qvk_add_test id=clock_offset section=system method=http_date_header status=unknown \
      reason_code=insufficient_samples reason="fewer than 3 independent Date headers ($cnt)" \
      samples="$cnt" details="$details" metrics="$metrics" hmsg=net.clock_unknown hargs="$cnt"
    return 0
  fi
  QVK_CLOCK_OFFSET_S=$med
  abs=${med#-}
  if awk -v a="$abs" -v t="$QVK_CLOCK_MAX_OFFSET_S" 'BEGIN { exit !(a <= t) }'; then
    QVK_CLOCK_STATUS=pass
    qvk_add_test id=clock_offset section=system method=http_date_header status=pass \
      samples="$cnt" details="$details" metrics="$metrics" hmsg=net.clock_ok hargs="$med${QVK_US}$cnt"
  else
    QVK_CLOCK_STATUS=warn
    qvk_add_test id=clock_offset section=system method=http_date_header status=warn \
      reason="system clock is off by ${med} s (threshold ${QVK_CLOCK_MAX_OFFSET_S} s); TLS and REALITY handshakes may fail; enable NTP" \
      samples="$cnt" details="$details" metrics="$metrics" hmsg=net.clock_bad hargs="$med"
  fi
}

# --offline: every network test is reported as skipped.
_net_offline() {
  local id name url cat
  local skip=(status=skipped reason_code=offline_mode reason="--offline: no external requests" hmsg=net.offline)
  for id in egress_ipv4 egress_ipv6; do
    qvk_add_test id="$id" section=network_egress method=http_echo "${skip[@]}"
  done
  for cat in baseline rtt_ru; do
    while read -r name url; do
      [[ -n $name ]] || continue
      if [[ $cat == baseline ]]; then
        qvk_add_test id="https_$name" section=network_egress method=curl_get endpoint="$url" "${skip[@]}"
      else
        qvk_add_test id="tcp_rtt_ru_$name" section=network_egress method=curl_time_connect \
          endpoint="$(qvk_url_host "$url"):443" "${skip[@]}"
      fi
    done < <(qvk_endpoints "$cat")
  done
  qvk_add_test id=dns_resolution section=network_egress method=curl_namelookup "${skip[@]}"
  qvk_add_test id=clock_offset section=system method=http_date_header "${skip[@]}"
  QVK_EGRESS4_STATUS=skipped QVK_DNS_STATUS=skipped QVK_CLOCK_STATUS=skipped
}

qvk_egress_run() {
  if ((QVK_OFFLINE)); then
    _net_offline
    return 0
  fi
  qvk_progress "$(msg progress.egress)"
  _net_egress 4
  if [[ ${QVK_SYS[net.ipv6_default_route]:-} == 1 ]]; then
    _net_egress 6
  else
    qvk_add_test id=egress_ipv6 section=network_egress method=http_echo status=skipped \
      reason_code=not_applicable reason="no IPv6 default route" hmsg=net.no_ipv6
  fi
  qvk_progress "$(msg progress.baseline)"
  _net_baseline
  qvk_progress "$(msg progress.rtt)"
  _net_rtt_ru
  _net_dns
  _net_clock
}
