# shellcheck shell=bash
# Test records. A module calls qvk_add_test with key=value pairs; the record is
# appended as JSON to QVK_TESTS and as a human summary to QVK_TEST_HUMAN.
#
# Keys: id section method status (required); vantage endpoint diagnosis
# http_outcome reason_code reason samples timeout_ms duration_ms traffic_bytes
# error (strings/numbers, empty = null); metrics details (JSON fragments);
# hmsg (i18n key) and hargs (args separated by the unit separator $'\x1f').

QVK_TESTS=()
QVK_TEST_HUMAN=()   # "section<US>id<US>status<US>hmsg<US>hargs..."

QVK_US=$'\x1f'

qvk_add_test() {
  local -A t=(
    [vantage]=target [endpoint]="" [diagnosis]="" [http_outcome]="" [reason_code]=""
    [reason]="" [samples]="" [timeout_ms]="" [duration_ms]=0 [traffic_bytes]=0
    [error]="" [metrics]="{}" [details]="" [hmsg]="" [hargs]=""
  )
  local kv k
  for kv in "$@"; do
    k=${kv%%=*}
    t[$k]=${kv#*=}
  done
  for k in id section method status; do
    if [[ -z ${t[$k]:-} ]]; then
      printf 'qvk: internal error: test without %s\n' "$k" >&2
      return 3
    fi
  done

  local -a fields=(
    id "$(json_str "${t[id]}")"
    section "$(json_str "${t[section]}")"
    vantage "$(json_str "${t[vantage]}")"
    endpoint "$(json_str_or_null "${t[endpoint]}")"
    method "$(json_str "${t[method]}")"
    status "$(json_str "${t[status]}")"
    diagnosis "$(json_str_or_null "${t[diagnosis]}")"
  )
  [[ -n ${t[http_outcome]} ]] && fields+=(http_outcome "$(json_str "${t[http_outcome]}")")
  fields+=(
    reason_code "$(json_str_or_null "${t[reason_code]}")"
    reason "$(json_str_or_null "${t[reason]}")"
    started_at "$(json_str "$(qvk_now_utc)")"
    duration_ms "$(json_num "${t[duration_ms]}")"
    timeout_ms "$(json_num "${t[timeout_ms]}")"
    samples "$(json_num "${t[samples]}")"
    metrics "${t[metrics]}"
  )
  [[ -n ${t[details]} ]] && fields+=(details "${t[details]}")
  fields+=(
    traffic_bytes "$(json_num "${t[traffic_bytes]}")"
    error "$(json_str_or_null "${t[error]}")"
  )
  QVK_TESTS+=("$(json_obj "${fields[@]}")")
  QVK_TEST_HUMAN+=("${t[section]}$QVK_US${t[id]}$QVK_US${t[status]}$QVK_US${t[hmsg]}$QVK_US${t[hargs]}")
}
