# shellcheck shell=bash
# Results are exposed through QC_* / QVK_EP_* globals used by lib/egress.sh.
# shellcheck disable=SC2034

# Network primitives: endpoint list, one measured curl call, curl error mapping,
# statistics. Every request has a connect timeout and a total timeout.

QVK_ENDPOINTS_FILE=""
QVK_EP_ERROR=""
QVK_EP_CAT=()
QVK_EP_NAME=()
QVK_EP_URL=()
QVK_EP_CATEGORIES="echo4 echo6 baseline rtt_ru ai social media dev web ru_hosted"

QVK_HTTP_CONNECT_TIMEOUT=5
QVK_HTTP_MAX_TIME=10
QVK_RTT_CONNECT_TIMEOUT=3
QVK_RTT_MAX_TIME=6
QVK_MAX_BODY_BYTES=1048576

# qvk_load_endpoints <file> — fills QVK_EP_*; on error sets QVK_EP_ERROR, returns 1.
qvk_load_endpoints() {
  local f=$1 line cat name url extra lineno=0
  QVK_EP_CAT=() QVK_EP_NAME=() QVK_EP_URL=() QVK_EP_ERROR=""
  if [[ ! -r $f ]]; then
    QVK_EP_ERROR="cannot read endpoint list: $f"
    return 1
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    cat="" name="" url="" extra=""
    read -r cat name url extra <<<"$line"
    if [[ " $QVK_EP_CATEGORIES " != *" $cat "* ]] \
      || ! [[ $name =~ ^[a-z0-9_]{1,32}$ ]] \
      || ! [[ $url =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^[:space:]\"\'\\\`]*)?$ ]] \
      || [[ -n $extra ]]; then
      QVK_EP_ERROR="$f:$lineno: invalid endpoint line (expected: <category> <name> <https-url>)"
      return 1
    fi
    QVK_EP_CAT+=("$cat")
    QVK_EP_NAME+=("$name")
    QVK_EP_URL+=("$url")
  done <"$f"
  return 0
}

# qvk_endpoints <category> — prints "name url" lines.
qvk_endpoints() {
  local i
  for i in "${!QVK_EP_CAT[@]}"; do
    [[ ${QVK_EP_CAT[i]} == "$1" ]] && printf '%s %s\n' "${QVK_EP_NAME[i]}" "${QVK_EP_URL[i]}"
  done
  return 0
}

# --- iperf3 throughput servers -------------------------------------------------------

QVK_IPERF_NAME=()
QVK_IPERF_HOST=()
QVK_IPERF_ERROR=""

# qvk_load_iperf_servers <file> — fills QVK_IPERF_NAME/HOST; on error sets QVK_IPERF_ERROR, returns 1.
qvk_load_iperf_servers() {
  local f=$1 line name host lineno=0
  QVK_IPERF_NAME=() QVK_IPERF_HOST=() QVK_IPERF_ERROR=""
  if [[ ! -r $f ]]; then
    QVK_IPERF_ERROR="cannot read iperf server list: $f"
    return 1
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    local name="" host="" extra=""
    # Use an array to split and check exact field count
    local -a fields=()
    read -r -a fields <<<"$line"
    if (( ${#fields[@]} != 2 )); then
      QVK_IPERF_ERROR="$f:$lineno: invalid iperf server line (expected: <name> <host>)"
      return 1
    fi
    name=${fields[0]}
    host=${fields[1]}
    # Validate host: hostname or IP (basic check)
    if ! [[ $host =~ ^[A-Za-z0-9.-]+$ ]]; then
      QVK_IPERF_ERROR="$f:$lineno: invalid host format: $host"
      return 1
    fi
    QVK_IPERF_NAME+=("$name")
    QVK_IPERF_HOST+=("$host")
  done <"$f"
  return 0
}

# qvk_iperf_servers — prints "name host" lines for iteration.
qvk_iperf_servers() {
  local i
  for i in "${!QVK_IPERF_NAME[@]}"; do
    printf '%s %s\n' "${QVK_IPERF_NAME[i]}" "${QVK_IPERF_HOST[i]}"
  done
  return 0
}

qvk_url_host() {
  local h=${1#https://}
  h=${h%%/*}
  printf '%s' "${h%%:*}"
}

# --- one measured request ---------------------------------------------------------

QC_RC=0 QC_CODE="" QC_DNS="" QC_CONNECT="" QC_TLS="" QC_TTFB="" QC_TOTAL=""
QC_BYTES=0 QC_REMOTE="" QC_HDR="" QC_BODY="" QC_T0="" QC_ERR=""

QVK_CURL_WFORMAT='%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{size_header} %{size_request} %{remote_ip}\n'

# qvk_curl <tag> <url> [extra curl args: -4|-6|-I ...]
# HTTPS only, no redirects followed, body capped, both timeouts always set.
qvk_curl() {
  local tag=$1 url=$2 dir w dl hs rq
  shift 2
  dir=$(qvk_tmpdir)
  QC_HDR="$dir/$tag.h" QC_BODY="$dir/$tag.b"
  local ctimeout=$QVK_HTTP_CONNECT_TIMEOUT mtime=$QVK_HTTP_MAX_TIME
  if [[ " $* " == *" -I "* ]]; then
    ctimeout=$QVK_RTT_CONNECT_TIMEOUT mtime=$QVK_RTT_MAX_TIME
  fi
  QC_T0=$EPOCHREALTIME
  w=$(curl -sS --proto '=https' --max-redirs 0 -A "quality-vps-kit/$QVK_VERSION" \
    --connect-timeout "$ctimeout" --max-time "$mtime" --max-filesize "$QVK_MAX_BODY_BYTES" \
    -o "$QC_BODY" -D "$QC_HDR" -w "$QVK_CURL_WFORMAT" "$@" "$url" 2>"$dir/$tag.e")
  QC_RC=$?
  QC_CODE="" QC_DNS="" QC_CONNECT="" QC_TLS="" QC_TTFB="" QC_TOTAL="" QC_REMOTE=""
  dl=0 hs=0 rq=0
  read -r QC_CODE QC_DNS QC_CONNECT QC_TLS QC_TTFB QC_TOTAL dl hs rq QC_REMOTE <<<"$w"
  [[ $dl =~ ^[0-9]+$ ]] || dl=0
  [[ $hs =~ ^[0-9]+$ ]] || hs=0
  [[ $rq =~ ^[0-9]+$ ]] || rq=0
  QC_BYTES=$((dl + hs + rq))
  QC_ERR=$(head -c 300 "$dir/$tag.e" 2>/dev/null | tr -d '\r' | head -n1)
  [[ $QC_CODE == 000 ]] && QC_CODE=""
  return 0
}

# Map the last curl exit code: prints "<status> <reason_code>"; "pass -" on success.
# Network failures are `fail`; problems of the tester itself are `error`.
qvk_curl_outcome() {
  case $1 in
    0 | 63) printf 'pass -' ;; # 63: body larger than the cap, headers/timings are valid
    6) printf 'fail dns_failure' ;;
    7) printf 'fail tcp_connect_failed' ;;
    28) printf 'fail timeout' ;;
    35 | 53 | 54 | 58 | 59 | 60 | 64 | 66 | 77 | 80 | 83 | 90 | 91) printf 'fail tls_failure' ;;
    52 | 55 | 56) printf 'fail connection_reset' ;;
    47) printf 'fail http_error' ;;
    *) printf 'error curl_error' ;;
  esac
}

# --- arithmetic helpers (awk; bash has no floats) -----------------------------------

# qvk_ms <seconds> [minus_seconds] -> milliseconds with one decimal, empty if invalid.
qvk_ms() {
  awk -v a="${1:-}" -v b="${2:-0}" 'BEGIN {
    if (a !~ /^[0-9.]+$/ || b !~ /^[0-9.]+$/) exit
    v = (a - b) * 1000; if (v < 0) v = 0
    printf "%.1f", v }'
}

# qvk_stats <values...> -> "n min p50 max p95" (nearest rank); "-" for unknown.
# p95 is reported only for n >= 20.
qvk_stats() {
  if (($# == 0)); then
    printf '0 - - - -'
    return
  fi
  printf '%s\n' "$@" | sort -g | awk '
    { a[NR] = $1 }
    END {
      n = NR
      r50 = int((50 * n + 99) / 100); if (r50 < 1) r50 = 1
      p95 = "-"
      if (n >= 20) { r95 = int((95 * n + 99) / 100); p95 = a[r95] }
      printf "%d %s %s %s %s", n, a[1], a[r50], a[n], p95
    }'
}

# "-" -> empty (for json_num)
qvk_dash() { [[ $1 == - ]] && return 0; printf '%s' "$1"; }

# Last Date: header of the last response -> epoch seconds (empty if none).
qvk_header_date_epoch() {
  local d
  d=$(grep -i '^date:' "$1" 2>/dev/null | tail -n1 | cut -d: -f2- | tr -d '\r')
  d=${d# }
  [[ -n $d ]] || return 0
  date -u -d "$d" +%s 2>/dev/null
}

# Clock offset of one response in seconds (server minus local), or empty.
# The server's Date has 1 s resolution (truncated), hence +0.5 s.
qvk_clock_offset_sample() {
  local server
  server=$(qvk_header_date_epoch "$QC_HDR")
  [[ -n $server && -n $QC_T0 && -n $QC_TTFB ]] || return 0
  awk -v s="$server" -v t0="$QC_T0" -v ttfb="$QC_TTFB" \
    'BEGIN { printf "%.1f", (s + 0.5) - (t0 + ttfb) }'
}
