# shellcheck shell=bash
# iperf3 throughput test module for qvk.
# Runs iperf3 against public servers, measures download/upload/latency.

QVK_IPERF_TIMEOUT=30
QVK_IPERF_DURATION=5

# qvk_pkg_mgr — detect package manager, echo name, return 0 on success, 1 if unknown.
qvk_pkg_mgr() {
  if command -v apt >/dev/null 2>&1; then
    echo "apt"
    return 0
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
    return 0
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman"
    return 0
  elif command -v apk >/dev/null 2>&1; then
    echo "apk"
    return 0
  fi
  return 1
}

# qvk_iperf_ensure — ensure iperf3 is available (auto-install if missing).
# Returns 0 if iperf3 is ready, 1 on failure.
qvk_iperf_ensure() {
  command -v iperf3 >/dev/null 2>&1 && return 0

  local mgr
  mgr=$(qvk_pkg_mgr) || return 1

  # We need root for package installation
  if (( EUID != 0 )); then
    qvk_log "$(msg throughput.install_failed)" >&2
    return 1
  fi

  local install_cmd
  case $mgr in
    apt)    install_cmd="apt-get update && apt-get install -y iperf3" ;;
    dnf)    install_cmd="dnf install -y iperf3" ;;
    pacman) install_cmd="pacman -Sy --noconfirm iperf3" ;;
    apk)    install_cmd="apk add iperf3" ;;
    *)      return 1 ;;
  esac

  qvk_log "$(msg throughput.installing)" >&2
  if eval "$install_cmd" >/dev/null 2>&1; then
    command -v iperf3 >/dev/null 2>&1 && return 0
  fi

  qvk_log "$(msg throughput.install_failed)" >&2
  return 1
}

# _iperf_parse_download <json> — extract download Mbps from iperf3 JSON.
_iperf_parse_download() {
  local json=$1
  local bps
  # iperf3 JSON: end.sum_received.bits_per_second
  bps=$(printf '%s' "$json" | grep -o '"sum_received"[^}]*"bits_per_second"[[:space:]]*:[[:space:]]*[0-9.]*' | head -1 | sed -E 's/.*:[[:space:]]*//')
  if [[ -z $bps ]]; then
    # Fallback: try sum (without _received or _sent)
    bps=$(printf '%s' "$json" | grep -o '"bits_per_second"[[:space:]]*:[[:space:]]*[0-9.]*' | tail -1 | sed -E 's/.*:[[:space:]]*//')
  fi
  if [[ -n $bps ]]; then
    awk "BEGIN {printf \"%.1f\", $bps / 1000000}"
  else
    echo "0.0"
  fi
}

# _iperf_parse_upload <json> — extract upload Mbps from iperf3 JSON.
_iperf_parse_upload() {
  local json=$1
  local bps
  bps=$(printf '%s' "$json" | grep -o '"sum_sent"[^}]*"bits_per_second"[[:space:]]*:[[:space:]]*[0-9.]*' | head -1 | sed -E 's/.*:[[:space:]]*//')
  if [[ -z $bps ]]; then
    # Fallback
    bps=$(printf '%s' "$json" | grep -o '"bits_per_second"[[:space:]]*:[[:space:]]*[0-9.]*' | head -1 | sed -E 's/.*:[[:space:]]*//')
  fi
  if [[ -n $bps ]]; then
    awk "BEGIN {printf \"%.1f\", $bps / 1000000}"
  else
    echo "0.0"
  fi
}

# _iperf_parse_latency <json> — extract latency (rtt) in ms from iperf3 JSON.
_iperf_parse_latency() {
  local json=$1
  local rtt
  # Try streams[0].sender.rtt or streams[0].rtt
  rtt=$(printf '%s' "$json" | grep -o '"rtt"[[:space:]]*:[[:space:]]*[0-9.]*' | head -1 | sed -E 's/.*:[[:space:]]*//')
  if [[ -n $rtt ]]; then
    awk "BEGIN {printf \"%.1f\", $rtt / 1000}"
  else
    echo "0.0"
  fi
}

# qvk_iperf_run_server <host> — run iperf3 download+upload test against one server.
# Emits test record via qvk_add_test with section=iperf_throughput.
qvk_iperf_run_server() {
  local host=$1
  local download_json upload_json download_mbps upload_mbps latency_ms err_file

  if ((QVK_OFFLINE)); then
    qvk_add_test id="iperf_${host//./_}" section=iperf_throughput method=iperf3 endpoint="$host" \
      status=skipped reason_code=offline_mode reason="--offline: no external requests" \
      hmsg=throughput.offline hargs="" \
      duration_ms=0 timeout_ms=$((QVK_IPERF_TIMEOUT * 1000)) samples=1 traffic_bytes=0
    return 0
  fi

  err_file=$(mktemp)

  # Download test (reverse mode: server sends)
  if download_json=$(timeout "$QVK_IPERF_TIMEOUT" iperf3 -c "$host" -t "$QVK_IPERF_DURATION" -R -J 2>"$err_file"); then
    download_mbps=$(_iperf_parse_download "$download_json")
    latency_ms=$(_iperf_parse_latency "$download_json")
  else
    local rc=$?
    local err_msg
    err_msg=$(head -c 200 "$err_file" 2>/dev/null | tr '\n' ' ')
    qvk_add_test id="iperf_${host//./_}" section=iperf_throughput method=iperf3 endpoint="$host" \
      status=error reason_code=iperf_error reason="${err_msg:-iperf3 download failed (rc=$rc)}" \
      hmsg=throughput.error hargs="${host}${QVK_US}${err_msg:-iperf3 download failed (rc=$rc)}" \
      duration_ms=0 timeout_ms=$((QVK_IPERF_TIMEOUT * 1000)) samples=1 traffic_bytes=0
    rm -f "$err_file"
    return 0
  fi

  # Upload test
  if upload_json=$(timeout "$QVK_IPERF_TIMEOUT" iperf3 -c "$host" -t "$QVK_IPERF_DURATION" -J 2>"$err_file"); then
    upload_mbps=$(_iperf_parse_upload "$upload_json")
  else
    upload_mbps="0.0"
  fi

  rm -f "$err_file"

  # Emit test record
  local details
  details=$(json_obj download_mbps "$(json_num "$download_mbps")" \
    upload_mbps "$(json_num "$upload_mbps")" latency_ms "$(json_num "$latency_ms")")

  qvk_add_test id="iperf_${host//./_}" section=iperf_throughput method=iperf3 endpoint="$host" \
    status=pass reason_code="" reason="" \
    hmsg=throughput.row hargs="${host}${QVK_US}${download_mbps}${QVK_US}${upload_mbps}${QVK_US}${latency_ms}" \
    details="$details" duration_ms=0 timeout_ms=$((QVK_IPERF_TIMEOUT * 1000)) samples=1 traffic_bytes=0
}

# qvk_iperf_run — main entry point, runs throughput test against all configured servers.
qvk_iperf_run() {
  qvk_iperf_ensure || { qvk_log "$(msg throughput.install_failed)" >&2; return 0; }
  qvk_load_iperf_servers "$QVK_ROOT/config/iperf_servers.tsv" || return 0

  local i
  for i in "${!QVK_IPERF_HOST[@]}"; do
    qvk_progress "$(msg progress.throughput "${QVK_IPERF_NAME[i]}")"
    qvk_iperf_run_server "${QVK_IPERF_HOST[i]}"
  done
}
