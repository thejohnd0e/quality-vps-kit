# shellcheck shell=bash
# HTTP reachability of popular services from the target's IP (section
# http_reachability, QVK-04). One gentle GET per endpoint.
#
# An HTTP answer says only that the service replied to this request from this
# IP. 401 means "reachable, authentication required". 403 and 429 are decisions
# of the service (geo policy, rate limit, anti-bot), NOT network filtering. A
# captcha is never bypassed. Nothing here proves that an account, a stream or a
# payment works.

QVK_HTTP_CATEGORIES=(ai social media dev web ru_hosted)

# _http_classify -> sets H_STATUS H_OUTCOME H_CODE H_REASON for the last response.
_http_classify() {
  local st code cat=$1
  H_STATUS=pass H_OUTCOME=reachable H_CODE="" H_REASON=""
  read -r st code <<<"$(qvk_curl_outcome "$QC_RC")"
  if [[ $st != pass ]]; then
    H_STATUS=$st H_CODE=$code H_REASON=$QC_ERR
    case $code in
      tls_failure) H_OUTCOME=tls_error ;;
      curl_error) H_OUTCOME=unknown ;;
      *) H_OUTCOME=network_error ;;
    esac
    return 0
  fi
  case $QC_CODE in
    2?? | 3?? | 401 | 404 | 405) ;;
    403)
      H_STATUS=warn H_OUTCOME=http_denied H_CODE=http_403
      H_REASON="the service answered 403 to this IP: a decision of the service (geo policy, anti-bot), not proof of network filtering"
      [[ $cat == ru_hosted ]] && H_REASON="the service answered 403: some Russia-hosted services reject foreign IPs by their own policy; this is not filtering of this route"
      ;;
    429)
      H_STATUS=warn H_OUTCOME=rate_limited H_CODE=http_429
      H_REASON="the service answered 429 (rate limit); retrying later may succeed"
      ;;
    5??)
      H_STATUS=warn H_OUTCOME=unknown H_CODE=http_error
      H_REASON="the service answered HTTP $QC_CODE (server-side problem)"
      ;;
    *)
      H_STATUS=unknown H_OUTCOME=unknown H_CODE=http_error
      H_REASON="unexpected HTTP status ${QC_CODE:-none}"
      ;;
  esac
}

qvk_http_run() {
  local cat name url id loc region details metrics hmsg hargs total_ms
  for cat in "${QVK_HTTP_CATEGORIES[@]}"; do
    while read -r name url; do
      [[ -n $name ]] || continue
      id="http_${cat}_$name"
      if ((QVK_OFFLINE)); then
        qvk_add_test id="$id" section=http_reachability method=curl_get endpoint="$url" \
          status=skipped reason_code=offline_mode reason="--offline: no external requests" hmsg=net.offline
        continue
      fi
      qvk_curl "http_${cat}_$name" "$url"
      _http_classify "$cat"
      loc=""
      if [[ $H_STATUS != error && $QC_CODE == 200 ]] && grep -q '^loc=' "$QC_BODY" 2>/dev/null; then
        loc=$(grep -m1 '^loc=' "$QC_BODY" | cut -d= -f2 | tr -d '\r')
        if [[ $loc =~ ^[A-Z]{2}$ ]]; then qvk_geo_add "${name}_trace" "$loc"; else loc=""; fi
      fi
      total_ms=$(qvk_ms "$QC_TOTAL")
      region=null
      if [[ -n $loc ]]; then
        region=$(json_obj method "$(json_str cloudflare_trace_loc)" country "$(json_str "$loc")")
      fi
      details=$(json_obj category "$(json_str "$cat")" http_code "$(json_num "$QC_CODE")" \
        region_signal "$region")
      metrics=$(json_obj \
        dns_ms "$(json_num "$(qvk_ms "$QC_DNS")")" \
        tcp_connect_ms "$(json_num "$(qvk_ms "$QC_CONNECT" "$QC_DNS")")" \
        tls_ms "$(json_num "$(qvk_ms "$QC_TLS" "$QC_CONNECT")")" \
        ttfb_ms "$(json_num "$(qvk_ms "$QC_TTFB" "$QC_TLS")")" \
        total_ms "$(json_num "$total_ms")")
      case $H_OUTCOME in
        reachable) hmsg=http.ok hargs="$QC_CODE${QVK_US}${total_ms%.*}" ;;
        http_denied) hmsg=http.denied hargs="" ;;
        rate_limited) hmsg=http.rate hargs="" ;;
        *) hmsg=http.fail hargs="${H_CODE:-$QC_CODE}" ;;
      esac
      # group is the category for http_reachability sub-headings in the report.
      qvk_add_test id="$id" section=http_reachability method=curl_get endpoint="$url" \
        status="$H_STATUS" http_outcome="$H_OUTCOME" reason_code="$H_CODE" reason="$H_REASON" \
        samples=1 timeout_ms=$((QVK_HTTP_MAX_TIME * 1000)) duration_ms="${total_ms%.*}" \
        metrics="$metrics" details="$details" traffic_bytes="$QC_BYTES" \
        error="$([[ $H_STATUS == error ]] && printf '%s' "$QC_ERR")" \
        hmsg="$hmsg" hargs="$hargs" group="$cat"
    done < <(qvk_endpoints "$cat")
  done
}
