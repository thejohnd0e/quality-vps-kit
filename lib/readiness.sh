# shellcheck shell=bash
# VPN-readiness checks (section vpn_readiness), evaluated from QVK_SYS facts.
# Read-only: recommendations are printed, never applied.

rd_cpu_crypto() {
  local aes=${QVK_SYS[cpu.aes]:-} details
  details=$(json_obj aes "$(json_bool "$aes")" clmul "$(json_bool "${QVK_SYS[cpu.clmul]:-}")" \
    source "$(json_str /proc/cpuinfo)")
  case $aes in
    1) qvk_add_test id=cpu_crypto_accel section=vpn_readiness method=cpuinfo_flags status=pass \
      details="$details" hmsg=rd.aes_yes ;;
    0) qvk_add_test id=cpu_crypto_accel section=vpn_readiness method=cpuinfo_flags status=warn \
      reason="no AES hardware acceleration: TLS/QUIC throughput is CPU-bound; prefer ChaCha20-Poly1305 ciphers" \
      details="$details" hmsg=rd.aes_no ;;
    *) qvk_add_test id=cpu_crypto_accel section=vpn_readiness method=cpuinfo_flags status=unknown \
      reason="CPU flags are not readable" details="$details" hmsg=rd.unknown ;;
  esac
}

rd_tun() {
  if qvk_tun_present; then
    qvk_add_test id=tun_device section=vpn_readiness method=char_device status=pass \
      endpoint=/dev/net/tun hmsg=rd.tun_yes
  else
    qvk_add_test id=tun_device section=vpn_readiness method=char_device status=warn \
      endpoint=/dev/net/tun \
      reason="/dev/net/tun is absent: userspace VPNs (amneziawg-go, wireguard-go, TUN-mode servers) cannot run; Xray and kernel WireGuard do not need it" \
      hmsg=rd.tun_no
  fi
}

rd_bbr() {
  local bbr=${QVK_SYS[kernel_net.bbr]:-} cur=${QVK_SYS[kernel_net.tcp_congestion_control]:-}
  local qdisc=${QVK_SYS[kernel_net.default_qdisc]:-} details
  # shellcheck disable=SC2086  # intentional word splitting of the sysctl list
  details=$(json_obj \
    current "$(json_str_or_null "$cur")" \
    available "$(json_str_arr ${QVK_SYS[kernel_net.tcp_available_congestion_control]:-})" \
    default_qdisc "$(json_str_or_null "$qdisc")" \
    bbr "$(json_str_or_null "$bbr")")
  case $bbr in
    available)
      qvk_add_test id=tcp_bbr_available section=vpn_readiness method=sysctl_modules status=pass \
        details="$details" hmsg=rd.bbr_yes hargs="${cur:-?}" ;;
    absent)
      qvk_add_test id=tcp_bbr_available section=vpn_readiness method=sysctl_modules status=warn \
        reason="TCP BBR is not available in this kernel" details="$details" hmsg=rd.bbr_no ;;
    *)
      qvk_add_test id=tcp_bbr_available section=vpn_readiness method=sysctl_modules status=unknown \
        reason="kernel modules directory is not readable (container?)" details="$details" \
        hmsg=rd.unknown ;;
  esac
}

rd_udp_buffers() {
  local r=${QVK_SYS[kernel_net.rmem_max_bytes]:-} w=${QVK_SYS[kernel_net.wmem_max_bytes]:-}
  local want=$QVK_UDP_BUF_RECOMMENDED metrics
  metrics=$(json_obj rmem_max_bytes "$(json_num "$r")" wmem_max_bytes "$(json_num "$w")" \
    recommended_bytes "$want")
  if ! [[ $r =~ ^[0-9]+$ && $w =~ ^[0-9]+$ ]]; then
    qvk_add_test id=udp_buffer_size section=vpn_readiness method=sysctl status=unknown \
      reason="net.core.rmem_max/wmem_max are not readable" metrics="$metrics" hmsg=rd.unknown
  elif ((r >= want && w >= want)); then
    qvk_add_test id=udp_buffer_size section=vpn_readiness method=sysctl status=pass \
      metrics="$metrics" hmsg=rd.udpbuf_ok hargs="$((r / 1048576))${QVK_US}$((w / 1048576))"
  else
    qvk_add_test id=udp_buffer_size section=vpn_readiness method=sysctl status=warn \
      reason="UDP socket buffers are below ${want} bytes, which limits QUIC/Hysteria throughput; recommended (not applied): sysctl -w net.core.rmem_max=${want} net.core.wmem_max=${want}" \
      metrics="$metrics" hmsg=rd.udpbuf_low \
      hargs="$((r / 1024))${QVK_US}$((w / 1024))${QVK_US}${want}${QVK_US}${want}"
  fi
}

rd_ports() {
  local src=${QVK_SYS[ports.source]:-} listening=${QVK_SYS[ports.listening]:-}
  local w proto port lp lport lproc busy=() busy_json=() label
  if [[ -z $src ]]; then
    qvk_add_test id=listening_ports section=vpn_readiness method=socket_list status=unknown \
      reason="neither ss nor /proc/net is available" hmsg=rd.unknown
    return 0
  fi
  for w in "${QVK_WATCHED_PORTS[@]}"; do
    proto=${w%%:*} port=${w#*:}
    while read -r lp lport lproc; do
      [[ $lp == "$proto" && $lport == "$port" ]] || continue
      label="$port/$proto"
      [[ -n $lproc ]] && label+=" ($lproc)"
      busy+=("$label")
      busy_json+=("$(json_obj port "$port" proto "$(json_str "$proto")" \
        process "$(json_str_or_null "$lproc")")")
      break
    done <<<"$listening"
  done
  local details watched=()
  for w in "${QVK_WATCHED_PORTS[@]}"; do watched+=("${w#*:}/${w%%:*}"); done
  details=$(json_obj source "$(json_str "$src")" watched "$(json_str_arr "${watched[@]}")" \
    in_use "$(json_arr "${busy_json[@]}")")
  if ((${#busy[@]} == 0)); then
    qvk_add_test id=listening_ports section=vpn_readiness method=socket_list status=pass \
      details="$details" hmsg=rd.ports_free hargs="${watched[*]}"
  else
    local joined
    joined=$(printf '%s, ' "${busy[@]}")
    joined=${joined%, }
    qvk_add_test id=listening_ports section=vpn_readiness method=socket_list status=warn \
      reason="ports already in use: $joined" details="$details" \
      hmsg=rd.ports_busy hargs="$joined"
  fi
}

qvk_readiness_evaluate() {
  rd_cpu_crypto
  rd_tun
  rd_bbr
  rd_udp_buffers
  rd_ports
}
