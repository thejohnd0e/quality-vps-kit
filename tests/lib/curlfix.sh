# shellcheck shell=bash
# Canned curl responses for network tests. Needs WORK, CF, REPO_ROOT, hostfix.sh.

# fix <family|""> <url> <curl exit> <http code> <body> [time_connect seconds] [extra headers]
fix() {
  local fam=$1 url=$2 rc=$3 code=$4 body=$5 conn=${6:-0.025000} extra=${7:-} key
  key=$(printf '%s %s' "$fam" "$url" | tr -c 'A-Za-z0-9._-' '_')
  case $rc in
    0) printf '%s 0.004000 %s 0.060000 0.090000 0.091000 %d 300 80 192.0.2.80\n' \
      "$code" "$conn" "${#body}" >"$CF/$key.w" ;;
    6) printf '000 0.000000 0.000000 0.000000 0.000000 0.010000 0 0 0 \n' >"$CF/$key.w" ;;
    7 | 28) printf '000 0.004000 0.000000 0.000000 0.000000 3.000000 0 0 0 \n' >"$CF/$key.w" ;;
    *) printf '000 0.004000 0.000000 0.000000 0.000000 0.001000 0 0 0 \n' >"$CF/$key.w" ;;
  esac
  {
    printf 'HTTP/2 %s\r\ndate: @DATE@\r\ncontent-type: text/plain\r\n' "$code"
    [[ -n $extra ]] && printf '%s\r\n' "$extra"
    printf '\r\n'
  } >"$CF/$key.h"
  printf '%s' "$body" >"$CF/$key.b"
  [[ $rc == 0 ]] || printf 'curl: (%s) stub failure\n' "$rc" >"$CF/$key.e"
  echo "$rc" >"$CF/$key.exit"
}

# scenario <rc_echo> <rc_baseline> <rc_rtt> [aws_ip]
scenario() {
  local re=$1 rb=$2 rr=$3 aws_ip=${4:-203.0.113.10}
  rm -rf "$CF"
  mkdir -p "$CF"
  fix 4 https://www.cloudflare.com/cdn-cgi/trace "$re" 200 $'fl=1\nip=203.0.113.10\nloc=DE\n'
  fix 4 https://api.ipify.org/ "$re" 200 '203.0.113.10'
  fix 4 https://checkip.amazonaws.com/ "$re" 200 "$aws_ip"$'\n'
  fix 6 https://www.cloudflare.com/cdn-cgi/trace "$re" 200 $'ip=2001:db8:10::5\nloc=DE\n'
  fix 6 https://api6.ipify.org/ "$re" 200 '2001:db8:10::5'
  fix "" https://www.google.com/generate_204 "$rb" 204 ''
  fix "" https://www.cloudflare.com/cdn-cgi/trace "$rb" 200 $'ip=203.0.113.10\n'
  fix "" https://www.wikipedia.org/robots.txt "$rb" 200 'User-agent: *'
  fix "" https://ya.ru/ "$rr" 200 '' 0.045000
  fix "" https://vk.com/ "$rr" 200 '' 0.050000
  fix "" https://mail.ru/ "$rr" 200 '' 0.040000
}

host() {
  use_host_fixture "$1"
  cp "$REPO_ROOT/tests/fixtures/stub-curl.sh" "$WORK/hostbin/curl"
  chmod +x "$WORK/hostbin/curl"
  export QVK_CURL_FIXTURES="$CF" QVK_STUB_CLOCK_OFFSET=0
}
