#!/bin/sh
# curl stub for network tests. Serves canned responses from
# "$QVK_CURL_FIXTURES/<key>.{w,h,b,exit}", where <key> is "<family> <url>"
# (family 4, 6 or empty) with characters outside [A-Za-z0-9._-] replaced by "_".
#   .w     line printed for -w (already rendered)
#   .h     headers written to -D; "@DATE@" becomes the current time shifted by
#          $QVK_STUB_CLOCK_OFFSET seconds (HTTP-date format)
#   .b     body written to -o
#   .exit  exit status (default 0)
# Unknown URLs fail like an unresolvable name (exit 6). Calls are logged.
if [ -n "${QVK_STUB_LOG:-}" ]; then
  printf 'curl %s\n' "$*" >>"$QVK_STUB_LOG"
fi
out="" hdr="" url="" fam=""
while [ $# -gt 0 ]; do
  case $1 in
    --version)
      echo "curl 8.5.0-stub (x86_64-pc-linux-gnu) libcurl/8.5.0"
      exit 0
      ;;
    -o) out=$2; shift ;;
    -D) hdr=$2; shift ;;
    -w | -A | --proto | --max-redirs | --connect-timeout | --max-time | --max-filesize) shift ;;
    -4) fam=4 ;;
    -6) fam=6 ;;
    https://*) url=$1 ;;
  esac
  shift
done
d=${QVK_CURL_FIXTURES:-/nonexistent}
key=$(printf '%s %s' "$fam" "$url" | tr -c 'A-Za-z0-9._-' '_')
if [ ! -f "$d/$key.w" ]; then
  [ -n "$out" ] && : >"$out"
  [ -n "$hdr" ] && : >"$hdr"
  printf '000 0.000000 0.000000 0.000000 0.000000 0.001000 0 0 0 \n'
  echo "curl: (6) Could not resolve host (stub: no fixture for $fam $url)" >&2
  exit 6
fi
now=$(($(date +%s) + ${QVK_STUB_CLOCK_OFFSET:-0}))
httpdate=$(date -u -d "@$now" '+%a, %d %b %Y %H:%M:%S GMT')
if [ -n "$hdr" ]; then
  if [ -f "$d/$key.h" ]; then sed "s/@DATE@/$httpdate/" "$d/$key.h" >"$hdr"; else : >"$hdr"; fi
fi
if [ -n "$out" ]; then
  if [ -f "$d/$key.b" ]; then cat "$d/$key.b" >"$out"; else : >"$out"; fi
fi
cat "$d/$key.w"
if [ -f "$d/$key.e" ]; then cat "$d/$key.e" >&2; fi
if [ -f "$d/$key.exit" ]; then exit "$(cat "$d/$key.exit")"; fi
exit 0
