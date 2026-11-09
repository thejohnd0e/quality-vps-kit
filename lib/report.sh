# shellcheck shell=bash
# Report assembly (JSON) and human-readable rendering.
# Run state lives in QVK_* globals filled by cmd_run and the modules.

QVK_SCHEMA_VERSION="0.1"

QVK_RUN_ID=""
QVK_STARTED_AT=""
QVK_FINISHED_AT=""
QVK_PROFILE="quick"
QVK_OFFLINE=0
QVK_REDACT=0

# Render a stored message "<key><US><arg>..." with msg (human) or msg_en (JSON).
_qvk_render() {
  local fn=$1 key args=()
  key=${2%%"$QVK_US"*}
  if [[ $2 == *"$QVK_US"* ]]; then
    IFS=$QVK_US read -r -a args <<<"${2#*"$QVK_US"}"
  fi
  "$fn" "$key" "${args[@]}"
}

# Typed accessors over QVK_SYS.
_s() { json_str_or_null "${QVK_SYS[$1]:-}"; }
_n() { json_num "${QVK_SYS[$1]:-}"; }
_b() { json_bool "${QVK_SYS[$1]:-}"; }

# Address list "addr prefix class" lines -> JSON array of objects.
_addr_list_json() {
  local items=() addr prefix class
  while read -r addr prefix class; do
    [[ -n $addr ]] || continue
    items+=("$(json_obj address "$(json_str "$addr")" prefix_len "$(json_num "$prefix")" \
      class "$(json_str "$class")")")
  done <<<"$1"
  json_arr "${items[@]}"
}

qvk_system_json() {
  json_obj \
    os "$(json_obj \
      id "$(json_str_or_null "$QVK_OS_ID")" \
      version_id "$(json_str_or_null "$QVK_OS_VERSION_ID")" \
      pretty_name "$(json_str_or_null "$QVK_OS_PRETTY")")" \
    kernel "$(_s kernel)" \
    arch "$(json_str "$(qvk_arch)")" \
    virtualization "$(json_obj type "$(_s virt.type)" container "$(_b virt.container)" \
      source "$(_s virt.source)")" \
    cpu "$(json_obj model "$(_s cpu.model)" vcpus "$(_n cpu.vcpus)" aes "$(_b cpu.aes)" \
      clmul "$(_b cpu.clmul)")" \
    memory "$(json_obj total_mb "$(_n memory.total_mb)" available_mb "$(_n memory.available_mb)" \
      swap_total_mb "$(_n memory.swap_total_mb)")" \
    disk_root "$(json_obj total_mb "$(_n disk_root.total_mb)" \
      available_mb "$(_n disk_root.available_mb)")" \
    load "$(json_obj load1 "$(_n load.load1)" load5 "$(_n load.load5)" load15 "$(_n load.load15)")" \
    uptime_s "$(_n uptime_s)" \
    steal "$(json_obj pct "$(_n steal.pct)" sample_s "$(_n steal.sample_s)")" \
    network "$(json_obj \
      default_iface "$(_s net.default_iface)" \
      interface_mtu "$(_n net.interface_mtu)" \
      ipv4_addresses "$(_addr_list_json "${QVK_SYS[net.ipv4_addresses]:-}")" \
      ipv6_addresses "$(_addr_list_json "${QVK_SYS[net.ipv6_addresses]:-}")" \
      ipv6_default_route "$(_b net.ipv6_default_route)")" \
    time "$(json_obj ntp_synchronized "$(_b time.ntp_synchronized)")" \
    kernel_net "$(json_obj \
      tcp_congestion_control "$(_s kernel_net.tcp_congestion_control)" \
      default_qdisc "$(_s kernel_net.default_qdisc)" \
      bbr "$(_s kernel_net.bbr)" \
      rmem_max_bytes "$(_n kernel_net.rmem_max_bytes)" \
      wmem_max_bytes "$(_n kernel_net.wmem_max_bytes)" \
      ip_forward "$(_b kernel_net.ip_forward)")" \
    modules "$(json_obj wireguard "$(_s modules.wireguard)" \
      amneziawg_loaded "$(_b modules.amneziawg_loaded)")" \
    firewall "$(json_obj \
      nftables_tables "$(_n firewall.nftables_tables)" \
      iptables_backend "$(_s firewall.iptables_backend)" \
      iptables_rules "$(_n firewall.iptables_rules)" \
      ufw_active "$(_b firewall.ufw_active)" \
      firewalld_active "$(_b firewall.firewalld_active)")"
}

# _qvk_verdict_json <verdict> <reason_code> <reasons array name> <missing array name>
_qvk_verdict_json() {
  local verdict=$1 code=$2 r texts=()
  local -n _vj_reasons=$3 _vj_missing=$4
  for r in "${_vj_reasons[@]}"; do texts+=("$(_qvk_render msg_en "$r")"); done
  json_obj \
    verdict "$(json_str "$verdict")" \
    reason_code "$(json_str_or_null "$code")" \
    reasons "$(json_str_arr "${texts[@]}")" \
    missing_evidence "$(json_str_arr "${_vj_missing[@]}")"
}

_qvk_report_json_raw() {
  local tool run env target ipintel summary
  tool=$(json_obj name "$(json_str quality-vps-kit)" version "$(json_str "$QVK_VERSION")")
  run=$(json_obj \
    id "$(json_str "$QVK_RUN_ID")" \
    started_at "$(json_str "$QVK_STARTED_AT")" \
    finished_at "$(json_str "$QVK_FINISHED_AT")" \
    profile "$(json_str "$QVK_PROFILE")" \
    load_test_enabled false \
    offline "$(json_bool "$QVK_OFFLINE")" \
    redacted "$(json_bool "$QVK_REDACT")")
  env=$(json_obj \
    bash "$(json_str "$BASH_VERSION")" \
    curl "$(json_str_or_null "$(qvk_tool_version curl)")" \
    jq "$(json_str_or_null "$(qvk_tool_version jq)")")
  target=$(json_obj id "$(json_str target)" ip "$(json_str_or_null "$QVK_TARGET_IP")" \
    nat "$(json_str "$QVK_TARGET_NAT")")
  ipintel=$(json_obj sources "$(json_arr "${QVK_INTEL_SOURCES[@]}")" geo_consensus "$QVK_GEO_JSON" \
    claude_risk "${QVK_CLAUDE_RISK_JSON:-null}")
  summary=$(json_obj verdicts "$(json_obj \
    target_self_check "$(_qvk_verdict_json "$QVK_SELF_VERDICT" "$QVK_SELF_REASON_CODE" \
      QVK_SELF_REASONS QVK_SELF_MISSING)" \
    client_reachability "$(_qvk_verdict_json "$QVK_CLIENT_VERDICT" "$QVK_CLIENT_REASON_CODE" \
      QVK_CLIENT_REASONS QVK_CLIENT_MISSING)")")

  json_obj \
    schema_version "$(json_str "$QVK_SCHEMA_VERSION")" \
    tool "$tool" \
    run "$run" \
    environment "$env" \
    target "$target" \
    probes '[]' \
    system "$(qvk_system_json)" \
    tests "$(json_arr "${QVK_TESTS[@]}")" \
    ip_intelligence "$ipintel" \
    summary "$summary"
}

qvk_report_json() {
  qvk_redact "$(_qvk_report_json_raw)"
  printf '\n'
}

# --- human ---------------------------------------------------------------------

_qvk_human_field() {
  printf '  %s %s\n' "$(qvk_pad "$(msg "$1")" 18)" "$2"
}

_qvk_status_label() {
  local label
  label=$(qvk_pad "$(msg "status.$1")" 8)
  case $1 in
    pass) qvk_paint green "$label" ;;
    warn) qvk_paint yellow "$label" ;;
    fail | error) qvk_paint red "$label" ;;
    *) printf '%s' "$label" ;;
  esac
}

# _qvk_human_verdict <area> <verdict> <reasons array name> <missing array name>
_qvk_human_verdict() {
  local area=$1 verdict=$2 r missing
  local -n _hv_reasons=$3 _hv_missing=$4
  printf '  %s %s\n' "$(qvk_pad "$(msg "report.area.$area")" 32)" "$(qvk_color_verdict "$verdict")"
  for r in "${_hv_reasons[@]}"; do
    printf '    - %s\n' "$(_qvk_render msg "$r")"
  done
  if ((${#_hv_missing[@]})); then
    missing=$(printf '%s, ' "${_hv_missing[@]}")
    printf '    - %s\n' "$(msg report.missing "${missing%, }")"
  fi
}

# Join non-empty arguments with ", ".
_join() {
  local out="" x
  for x in "$@"; do
    [[ -n $x ]] || continue
    out+="${out:+, }$x"
  done
  printf '%s' "$out"
}

_or_unknown() { if [[ -n $1 ]]; then printf '%s' "$1"; else msg unknown; fi; }

_qvk_human_system() {
  local v addr prefix class list
  printf '%s\n' "$(qvk_paint bold "$(msg report.section.system)")"
  _qvk_human_field report.os "${QVK_OS_PRETTY:-$QVK_OS_ID $QVK_OS_VERSION_ID}"
  _qvk_human_field report.kernel "$(_or_unknown "${QVK_SYS[kernel]:-}") / $(qvk_arch)"

  v=${QVK_SYS[virt.type]:-}
  if [[ -n $v && ${QVK_SYS[virt.container]:-} == 1 ]]; then v+=" ($(msg report.container))"; fi
  _qvk_human_field report.virt "$(_or_unknown "$v")"

  v=$(_join "${QVK_SYS[cpu.model]:-}" \
    "${QVK_SYS[cpu.vcpus]:+$(msg report.vcpus "${QVK_SYS[cpu.vcpus]}")}")
  _qvk_human_field report.cpu "$(_or_unknown "$v")"

  if [[ -n ${QVK_SYS[memory.total_mb]:-} ]]; then
    v=$(msg report.mem_value "${QVK_SYS[memory.total_mb]}" "${QVK_SYS[memory.available_mb]:-?}" \
      "${QVK_SYS[memory.swap_total_mb]:-?}")
  else
    v=""
  fi
  _qvk_human_field report.memory "$(_or_unknown "$v")"

  if [[ -n ${QVK_SYS[disk_root.total_mb]:-} ]]; then
    v=$(msg report.disk_value "${QVK_SYS[disk_root.total_mb]}" "${QVK_SYS[disk_root.available_mb]:-?}")
  else
    v=""
  fi
  _qvk_human_field report.disk "$(_or_unknown "$v")"

  if [[ -n ${QVK_SYS[load.load1]:-} ]]; then
    v="${QVK_SYS[load.load1]} ${QVK_SYS[load.load5]:-} ${QVK_SYS[load.load15]:-}"
  else
    v=""
  fi
  _qvk_human_field report.load "$(_or_unknown "$v")"

  if [[ -n ${QVK_SYS[steal.pct]:-} ]]; then
    v=$(msg report.steal_value "${QVK_SYS[steal.pct]}" "${QVK_SYS[steal.sample_s]:-?}")
  else
    v=""
  fi
  _qvk_human_field report.steal "$(_or_unknown "$v")"

  v=${QVK_SYS[net.default_iface]:-}
  [[ -n $v && -n ${QVK_SYS[net.interface_mtu]:-} ]] && v+=", MTU ${QVK_SYS[net.interface_mtu]}"
  _qvk_human_field report.iface "$(_or_unknown "$v")"

  list=()
  while read -r addr prefix class; do
    [[ -n $addr ]] && list+=("$addr${prefix:+/$prefix} ($class)")
  done <<<"${QVK_SYS[net.ipv4_addresses]:-}"
  _qvk_human_field report.ipv4 "$(_or_unknown "$(_join "${list[@]}")")"

  list=()
  while read -r addr prefix class; do
    [[ -n $addr ]] && list+=("$addr${prefix:+/$prefix} ($class)")
  done <<<"${QVK_SYS[net.ipv6_addresses]:-}"
  if ((${#list[@]})); then
    v=$(_join "${list[@]}")
    [[ ${QVK_SYS[net.ipv6_default_route]:-} == 0 ]] && v+="; $(msg report.no_v6_route)"
  else
    v=$(msg report.none)
  fi
  _qvk_human_field report.ipv6 "$v"

  case ${QVK_SYS[time.ntp_synchronized]:-} in
    1) v=$(msg yes) ;;
    0) v=$(msg no) ;;
    *) v=$(msg unknown) ;;
  esac
  _qvk_human_field report.ntp "$v"

  v=$(_join \
    "${QVK_SYS[firewall.nftables_tables]:+nftables: $(msg report.tables "${QVK_SYS[firewall.nftables_tables]}")}" \
    "${QVK_SYS[firewall.iptables_backend]:+iptables (${QVK_SYS[firewall.iptables_backend]}): $(msg report.rules "${QVK_SYS[firewall.iptables_rules]:-?}")}" \
    "$([[ ${QVK_SYS[firewall.ufw_active]:-} == 1 ]] && printf 'ufw: active')" \
    "$([[ ${QVK_SYS[firewall.firewalld_active]:-} == 1 ]] && printf 'firewalld: active')")
  _qvk_human_field report.firewall "$(_or_unknown "$v")"

  case ${QVK_SYS[kernel_net.ip_forward]:-} in
    1) v=$(msg yes) ;;
    0) v=$(msg no) ;;
    *) v=$(msg unknown) ;;
  esac
  _qvk_human_field report.ip_forward "$v"
  _qvk_human_field report.wireguard "$(_or_unknown "${QVK_SYS[modules.wireguard]:-}")"
}

_qvk_human_geo() {
  [[ $QVK_GEO_JSON != null ]] || return 0
  local line n=${#QVK_GEO_ORDER[@]} s items=()
  for s in "${QVK_GEO_ORDER[@]}"; do items+=("$s=${QVK_GEO[$s]}"); done
  if ((n == 0)); then
    line=$(msg geo.none)
  elif [[ $QVK_GEO_CONFLICT == true ]]; then
    line=$(msg geo.conflict "$(_join "${items[@]}")")
  elif ((n == 1)); then
    line=$(msg geo.single "$QVK_GEO_COUNTRIES" "${items[0]%%=*}")
  else
    line=$(msg geo.agree "$QVK_GEO_COUNTRIES" "$n")
  fi
  printf '  %s %s %s\n' "$(qvk_pad "" 8)" "$(qvk_pad "$(msg report.geo)" 22)" "$line"
}

_qvk_human_claude_risk() {
  [[ -n ${QVK_CLAUDE_RISK_LEVEL:-} ]] || return 0
  local level text r reasons=""
  local -a parts=()
  for r in "${QVK_CLAUDE_RISK_REASONS[@]}"; do
    parts+=("$(msg "claude_risk.reason.$r")")
  done
  if ((${#parts[@]})); then
    printf -v reasons '%s, ' "${parts[@]}"
    reasons=${reasons%, }
  fi
  level=$(msg "claude_risk.level.$QVK_CLAUDE_RISK_LEVEL")
  text=$level
  [[ -n $reasons ]] && text+=" — $reasons"
  [[ -n $QVK_CLAUDE_RISK_TRUST ]] && text+=" ($(msg claude_risk.trust "$QVK_CLAUDE_RISK_TRUST"))"
  case $QVK_CLAUDE_RISK_LEVEL in
    high) text=$(qvk_paint red "$text") ;;
    medium | unknown) text=$(qvk_paint yellow "$text") ;;
    *) text=$(qvk_paint green "$text") ;;
  esac
  printf '\n%s\n  %s\n' "$(qvk_paint bold "$(msg report.claude_risk)")" "$text"
}

_qvk_test_label() {
  local id=$1 rest cat
  if qvk_msg_has "test.$id"; then
    msg "test.$id"
  elif [[ $id == http_* ]]; then
    rest=${id#http_}
    cat=${rest%%_*}
    [[ $rest == ru_hosted_* ]] && cat=ru_hosted
    name=${rest#"${cat}"_}
  if qvk_msg_has "test.$name"; then msg "test.$name"; else msg test.http "$cat" "$name"; fi
  elif [[ $id == https_* ]]; then
    msg test.https "${id#https_}"
  elif [[ $id == icmp_rtt_ru_* ]]; then
    msg test.icmp_rtt "${id#icmp_rtt_ru_}"
  elif [[ $id == tcp_rtt_ru_* ]]; then
    msg test.rtt_ru "${id#tcp_rtt_ru_}"
  else
    printf '%s' "$id"
  fi
}

_qvk_human_tests() {
  local section=$1 title_key=$2 rec sec id status hmsg hargs grp n=0 prev_group=""
  local -a args
  for rec in "${QVK_TEST_HUMAN[@]}"; do
    IFS=$QVK_US read -r sec id status hmsg hargs <<<"$rec"
    [[ $sec == "$section" ]] || continue
    if ((n++ == 0)) && [[ -n $title_key ]]; then
      printf '\n%s\n' "$(qvk_paint bold "$(msg "$title_key")")"
    fi
    grp=${QVK_TEST_GROUP[$id]:-}
    # Logical sub-groups for HTTP reachability: one bold line per category.
    if [[ $section == http_reachability && -n $grp && $grp != "$prev_group" ]]; then
      printf '  %s\n' "$(qvk_paint bold "$(msg "report.group.$grp")")"
      prev_group=$grp
    fi
    args=()
    [[ -n $hargs ]] && IFS=$QVK_US read -r -a args <<<"$hargs"
    printf '  %s %s %s\n' "$(_qvk_status_label "$status")" \
      "$(qvk_pad "$(_qvk_test_label "$id")" 22)" "$(msg "${hmsg:-rd.unknown}" "${args[@]}")"
  done
}

_qvk_report_human_raw() {
  printf '%s\n\n' "$(qvk_paint bold "$(msg report.title)")"
  _qvk_human_field report.run_id "$QVK_RUN_ID"
  _qvk_human_field report.profile "$QVK_PROFILE"
  _qvk_human_field report.started "$QVK_STARTED_AT"
  _qvk_human_field report.finished "$QVK_FINISHED_AT"
  if ((QVK_OFFLINE)); then
    _qvk_human_field report.offline "$(msg yes)"
  fi
  printf '\n'
  _qvk_human_system
  _qvk_human_tests system ""
  _qvk_human_tests vpn_readiness report.section.readiness
  _qvk_human_tests network_egress report.section.network
  _qvk_human_tests ip_intelligence report.section.intel
  _qvk_human_geo
  _qvk_human_claude_risk
  _qvk_human_tests http_reachability report.section.http
  _qvk_human_tests service_geo report.section.service_geo
  printf '\n%s\n' "$(qvk_paint bold "$(msg report.verdicts)")"
  _qvk_human_verdict target_self_check "$QVK_SELF_VERDICT" QVK_SELF_REASONS QVK_SELF_MISSING
  _qvk_human_verdict client_reachability "$QVK_CLIENT_VERDICT" QVK_CLIENT_REASONS QVK_CLIENT_MISSING
}

qvk_report_human() {
  qvk_redact "$(_qvk_report_human_raw)"
  printf '\n'
}
