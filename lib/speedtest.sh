# shellcheck shell=bash
# Official Ookla Speedtest CLI integration. Installation and testing only run
# when the caller has explicitly enabled load testing.

QVK_SPEEDTEST_TIMEOUT=180
QVK_SPEEDTEST_INSTALL_TIMEOUT=300
QVK_SPEEDTEST_KEY_URL=https://packagecloud.io/ookla/speedtest-cli/gpgkey
QVK_SPEEDTEST_REPO=https://packagecloud.io/ookla/speedtest-cli

_speedtest_cli_is_ookla() {
  local version
  command -v speedtest >/dev/null 2>&1 || return 1
  version=$(timeout 5 speedtest --version 2>&1) || return 1
  [[ $version == *'Speedtest by Ookla'* ]]
}

_speedtest_parse_mbps() {
  local json=$1 direction=$2 bandwidth section
  section=$(_speedtest_top_object "$json" "$direction") || return 1
  bandwidth=$(printf '%s' "$section" | tr '\n\r\t' '   ' | grep -oE '"bandwidth"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$')
  [[ $bandwidth =~ ^[0-9]+$ ]] || return 1
  awk -v b="$bandwidth" 'BEGIN { printf "%.1f", b * 8 / 1000000 }'
}

_speedtest_parse_latency() {
  local json=$1 latency section
  section=$(_speedtest_top_object "$json" ping) || return 1
  latency=$(printf '%s' "$section" | tr '\n\r\t' '   ' | grep -oE '"latency"[[:space:]]*:[[:space:]]*[0-9]+([.][0-9]+)?' | head -1 | grep -oE '[0-9]+([.][0-9]+)?$')
  [[ $latency =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  printf '%s' "$latency"
}

_speedtest_parse_bytes() {
  local json=$1 direction=$2 section bytes
  section=$(_speedtest_top_object "$json" "$direction") || return 1
  bytes=$(printf '%s' "$section" | tr '\n\r\t' '   ' | grep -oE '"bytes"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$')
  [[ $bytes =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$bytes"
}

# Return a named direct child object from the Ookla result. Braces inside
# strings are ignored; nested objects with the same key cannot masquerade as
# the top-level download/upload/ping fields.
_speedtest_json_balanced() {
  local json=$1 i=0 n=${#1} in_string=0 escaped=0 started=0 closed=0 ch
  local -a stack=()
  while ((i < n)); do
    ch=${json:i:1}
    if ((in_string)); then
      if ((escaped)); then escaped=0
      elif [[ $ch == \\ ]]; then escaped=1
      elif [[ $ch == '"' ]]; then in_string=0
      fi
    elif [[ $ch == '"' ]]; then
      ((closed == 0)) || return 1
      in_string=1
    elif [[ $ch =~ [[:space:]] ]]; then
      :
    elif ((closed)); then
      return 1
    else
      if ((started == 0)); then [[ $ch == \{ ]] || return 1; started=1; fi
      case $ch in
        '{' | '[') stack+=("$ch") ;;
        '}' | ']')
          ((${#stack[@]})) || return 1
          if [[ $ch == '}' && ${stack[-1]} != '{' ]] || [[ $ch == ']' && ${stack[-1]} != '[' ]]; then return 1; fi
          unset 'stack[-1]'
          ;;
      esac
      if ((started)) && ((${#stack[@]} == 0)); then closed=1; fi
    fi
    i=$((i + 1))
  done
  ((started && closed && in_string == 0 && ${#stack[@]} == 0))
}

_speedtest_top_object() {
  local json=$1 wanted=$2 n=${#1} i=0 j k depth=0 in_string=0 escaped=0
  local ch key value_depth value_string value_escape
  _speedtest_json_balanced "$json" || return 1
  while ((i < n)); do
    ch=${json:i:1}
    if ((in_string)); then
      if ((escaped)); then escaped=0
      elif [[ $ch == \\ ]]; then escaped=1
      elif [[ $ch == '"' ]]; then in_string=0
      fi
    else
      case $ch in
        '"')
          if ((depth == 1)); then
            j=$((i + 1)) key="" escaped=0
            while ((j < n)); do
              ch=${json:j:1}
              if ((escaped)); then key+=$ch; escaped=0
              elif [[ $ch == \\ ]]; then escaped=1
              elif [[ $ch == '"' ]]; then break
              else key+=$ch
              fi
              j=$((j + 1))
            done
            if ((j >= n)); then return 1; fi
            k=$((j + 1))
            while ((k < n)) && [[ ${json:k:1} =~ [[:space:]] ]]; do k=$((k + 1)); done
            if [[ $key == "$wanted" && ${json:k:1} == : ]]; then
              k=$((k + 1))
              while ((k < n)) && [[ ${json:k:1} =~ [[:space:]] ]]; do k=$((k + 1)); done
              [[ ${json:k:1} == \{ ]] || return 1
              value_depth=0 value_string=0 value_escape=0
              for ((j = k; j < n; j++)); do
                ch=${json:j:1}
                if ((value_string)); then
                  if ((value_escape)); then value_escape=0
                  elif [[ $ch == \\ ]]; then value_escape=1
                  elif [[ $ch == '"' ]]; then value_string=0
                  fi
                else
                  case $ch in
                    '"') value_string=1 ;;
                    '{') value_depth=$((value_depth + 1)) ;;
                    '}')
                      value_depth=$((value_depth - 1))
                      if ((value_depth == 0)); then
                        printf '%s' "${json:k:j-k+1}"
                        return 0
                      fi
                      ;;
                  esac
                fi
              done
              return 1
            fi
            i=$j
          else
            in_string=1
          fi
          ;;
        '{') depth=$((depth + 1)) ;;
        '}') depth=$((depth - 1)); ((depth >= 0)) || return 1 ;;
      esac
    fi
    i=$((i + 1))
  done
  return 1
}

# Configure the official Ookla Packagecloud APT source using its signing key,
# then install the signed package through apt. No remote script is executed.
qvk_speedtest_ensure() {
  _speedtest_cli_is_ookla && return 0
  local euid=${QVK_TEST_EUID:-$EUID} os=${QVK_OS_ID:-} version=${QVK_OS_VERSION_ID:-} codename
  local tmp rc=0 keyring=${QVK_TEST_SPEEDTEST_KEYRING:-/etc/apt/keyrings/qvk-ookla-speedtest.gpg}
  local sources=${QVK_TEST_SPEEDTEST_SOURCES:-/etc/apt/sources.list.d/qvk-ookla-speedtest.list}
  local source_line
  if ((euid != 0)); then
    QVK_SPEEDTEST_ERROR='root is required to install Ookla Speedtest CLI'
    return 1
  fi
  case "$os:$version" in
    debian:12) codename=bookworm ;;
    debian:13) codename=trixie ;;
    ubuntu:22.04) codename=jammy ;;
    ubuntu:24.04) codename=noble ;;
    *)
    QVK_SPEEDTEST_ERROR="official Ookla APT installation is unsupported on ${os:-unknown OS} ${version}"
    return 1
    ;;
  esac
  if ! command -v apt-get >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    QVK_SPEEDTEST_ERROR='apt-get or curl is unavailable'
    return 1
  fi
  printf -v source_line 'deb [signed-by=%s] %s/%s %s main' "$keyring" "$QVK_SPEEDTEST_REPO" "$os" "$codename"
  if [[ -e $sources ]] && [[ $(cat -- "$sources") != "$source_line" ]]; then
    QVK_SPEEDTEST_ERROR="refusing to overwrite unrelated APT source file: $sources"
    return 1
  fi

  if [[ -n ${QVK_TMPDIR:-} && -d $QVK_TMPDIR ]]; then
    tmp="$QVK_TMPDIR/speedtest-installer"
    mkdir -m 0700 -- "$tmp" || { QVK_SPEEDTEST_ERROR='cannot create installer temp directory'; return 1; }
  else
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/qvk-speedtest.XXXXXX") || { QVK_SPEEDTEST_ERROR='cannot create installer temp directory'; return 1; }
  fi
  qvk_log "$(msg throughput.installing)" >&2
  export DEBIAN_FRONTEND=noninteractive
  local apt_opts=(-o Acquire::http::Timeout=30 -o Acquire::ftp::Timeout=30 -o Acquire::https::Timeout=30)
  if ! command -v gpg >/dev/null 2>&1; then
    timeout -k 5 "$QVK_SPEEDTEST_INSTALL_TIMEOUT" apt-get "${apt_opts[@]}" update >/dev/null 2>&1 || rc=$?
    if ((rc == 0)); then
      timeout -k 5 "$QVK_SPEEDTEST_INSTALL_TIMEOUT" apt-get "${apt_opts[@]}" install -y gnupg >/dev/null 2>&1 || rc=$?
    fi
  fi
  if ((rc == 0)); then
    curl -fsSL --max-time 30 -o "$tmp/ookla.asc" "$QVK_SPEEDTEST_KEY_URL" || rc=$?
  fi
  if ((rc == 0)); then
    timeout -k 5 30 gpg --dearmor --batch --yes -o "$tmp/ookla.gpg" "$tmp/ookla.asc" >/dev/null 2>&1 || rc=$?
  fi
  if ((rc == 0)); then
    if [[ -e $keyring ]] && ! cmp -s -- "$tmp/ookla.gpg" "$keyring"; then
      QVK_SPEEDTEST_ERROR="refusing to overwrite unrelated APT signing key: $keyring"
      rm -rf -- "$tmp"
      return 1
    fi
    install -d -m 0755 "$(dirname -- "$keyring")" "$(dirname -- "$sources")" || rc=$?
    if ((rc == 0)) && [[ ! -e $keyring ]]; then
      install -m 0644 "$tmp/ookla.gpg" "$keyring" || rc=$?
    fi
    if ((rc == 0)) && [[ ! -e $sources ]]; then
      printf '%s\n' "$source_line" >"$tmp/ookla.list" || rc=$?
      if ((rc == 0)); then install -m 0644 "$tmp/ookla.list" "$sources" || rc=$?; fi
    fi
  fi
  if ((rc == 0)); then
    timeout -k 5 "$QVK_SPEEDTEST_INSTALL_TIMEOUT" apt-get "${apt_opts[@]}" update >/dev/null 2>&1 || rc=$?
  fi
  if ((rc == 0)); then
    timeout -k 5 "$QVK_SPEEDTEST_INSTALL_TIMEOUT" apt-get "${apt_opts[@]}" install -y --no-install-recommends speedtest >/dev/null 2>&1 || rc=$?
  fi
  rm -rf -- "$tmp"
  if ((rc != 0)) || ! _speedtest_cli_is_ookla; then
    QVK_SPEEDTEST_ERROR='official Ookla Speedtest CLI installation failed'
    return 1
  fi
  return 0
}

_qvk_speedtest_add_failure() {
  local status=$1 code=$2 reason=$3
  qvk_add_test id=speedtest_ookla section=speedtest method=ookla_speedtest \
    status="$status" reason_code="$code" reason="$reason" \
    hmsg=throughput.error hargs="$reason" \
    duration_ms=0 timeout_ms=$((QVK_SPEEDTEST_TIMEOUT * 1000)) samples=1 traffic_bytes=''
}

qvk_speedtest_run() {
  local output rc=0 download upload latency download_bytes upload_bytes traffic_bytes duration_ms details
  if ((QVK_OFFLINE)); then
    qvk_add_test id=speedtest_ookla section=speedtest method=ookla_speedtest \
      status=skipped reason_code=offline_mode reason='--offline: no external requests' \
      hmsg=throughput.offline hargs='' duration_ms=0 timeout_ms=$((QVK_SPEEDTEST_TIMEOUT * 1000)) \
      samples=1 traffic_bytes=0
    return 0
  fi
  if ! qvk_speedtest_ensure; then
    _qvk_speedtest_add_failure error install_failed "${QVK_SPEEDTEST_ERROR:-Ookla Speedtest CLI installation failed}"
    return 0
  fi

  local started=$SECONDS
  output=$(timeout "$QVK_SPEEDTEST_TIMEOUT" speedtest --accept-license --accept-gdpr --format=json 2>/dev/null) || rc=$?
  duration_ms=$(((SECONDS - started) * 1000))
  if ((rc != 0)); then
    if ((rc == 124)); then _qvk_speedtest_add_failure error timeout 'Ookla Speedtest timed out'
    else _qvk_speedtest_add_failure error speedtest_failed "Ookla Speedtest failed (exit $rc)"
    fi
    return 0
  fi
  download=$(_speedtest_parse_mbps "$output" download) || download=''
  upload=$(_speedtest_parse_mbps "$output" upload) || upload=''
  latency=$(_speedtest_parse_latency "$output") || latency=''
  download_bytes=$(_speedtest_parse_bytes "$output" download) || download_bytes=''
  upload_bytes=$(_speedtest_parse_bytes "$output" upload) || upload_bytes=''
  if [[ -z $download || -z $upload || -z $latency ]]; then
    _qvk_speedtest_add_failure error invalid_output 'Ookla Speedtest returned invalid JSON or missing metrics'
    return 0
  fi
  if [[ $download_bytes =~ ^[0-9]+$ && $upload_bytes =~ ^[0-9]+$ ]]; then
    traffic_bytes=$((download_bytes + upload_bytes))
  else
    traffic_bytes=''
  fi
  details=$(json_obj download_mbps "$(json_num "$download")" upload_mbps "$(json_num "$upload")" \
    latency_ms "$(json_num "$latency")" download_bytes "$(json_num "$download_bytes")" \
    upload_bytes "$(json_num "$upload_bytes")")
  qvk_add_test id=speedtest_ookla section=speedtest method=ookla_speedtest status=pass \
    endpoint=speedtest.net reason_code='' reason='' details="$details" \
    hmsg=throughput.row hargs="${download}${QVK_US}${upload}${QVK_US}${latency}" \
    duration_ms="$duration_ms" timeout_ms=$((QVK_SPEEDTEST_TIMEOUT * 1000)) samples=1 traffic_bytes="${traffic_bytes:-}"
}
