# shellcheck shell=bash
# Report assembly (JSON) and human-readable rendering.
#
# Run state is kept in QVK_* globals filled by cmd_run; measurement modules
# will append to QVK_TESTS (array of JSON test objects) in later slices.

QVK_SCHEMA_VERSION="0.1"

QVK_RUN_ID=""
QVK_STARTED_AT=""
QVK_FINISHED_AT=""
QVK_PROFILE="quick"
QVK_OFFLINE=0
QVK_REDACT=0
QVK_TESTS=()

# Verdict state per area: verdict, reason_code (or empty), reason key, missing sections.
QVK_SELF_VERDICT="indeterminate"
QVK_SELF_REASON_CODE="not_implemented"
QVK_SELF_REASON_KEY="reason.not_implemented"
QVK_SELF_MISSING=(system vpn_readiness network_egress ip_intelligence http_reachability)

QVK_CLIENT_VERDICT="indeterminate"
QVK_CLIENT_REASON_CODE="no_probe"
QVK_CLIENT_REASON_KEY="reason.no_probe"
QVK_CLIENT_MISSING=(client_reachability)

_qvk_verdict_json() {
  local verdict=$1 code=$2 key=$3
  shift 3
  json_obj \
    verdict "$(json_str "$verdict")" \
    reason_code "$(json_str_or_null "$code")" \
    reasons "$(json_str_arr "$(msg_en "$key")")" \
    missing_evidence "$(json_str_arr "$@")"
}

qvk_report_json() {
  local tool run env target system ipintel summary
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
  target=$(json_obj id "$(json_str target)" ip null nat "$(json_str unknown)")
  system=$(json_obj \
    os "$(json_obj \
      id "$(json_str_or_null "$QVK_OS_ID")" \
      version_id "$(json_str_or_null "$QVK_OS_VERSION_ID")" \
      pretty_name "$(json_str_or_null "$QVK_OS_PRETTY")")" \
    kernel "$(json_str_or_null "$(uname -r 2>/dev/null)")" \
    arch "$(json_str "$(qvk_arch)")")
  ipintel=$(json_obj sources '[]' geo_consensus null)
  summary=$(json_obj verdicts "$(json_obj \
    target_self_check "$(_qvk_verdict_json "$QVK_SELF_VERDICT" "$QVK_SELF_REASON_CODE" \
      "$QVK_SELF_REASON_KEY" "${QVK_SELF_MISSING[@]}")" \
    client_reachability "$(_qvk_verdict_json "$QVK_CLIENT_VERDICT" "$QVK_CLIENT_REASON_CODE" \
      "$QVK_CLIENT_REASON_KEY" "${QVK_CLIENT_MISSING[@]}")")")

  json_obj \
    schema_version "$(json_str "$QVK_SCHEMA_VERSION")" \
    tool "$tool" \
    run "$run" \
    environment "$env" \
    target "$target" \
    probes '[]' \
    system "$system" \
    tests "$(json_arr "${QVK_TESTS[@]}")" \
    ip_intelligence "$ipintel" \
    summary "$summary"
  printf '\n'
}

_qvk_human_verdict() {
  local area=$1 verdict=$2 key=$3
  shift 3
  local missing IFS=','
  missing="$*"
  printf '  %s %s\n' "$(qvk_pad "$(msg "report.area.$area")" 32)" "$(qvk_color_verdict "$verdict")"
  printf '    - %s\n' "$(msg "$key")"
  if (($#)); then
    printf '    - %s\n' "$(msg report.missing "${missing//,/, }")"
  fi
}

_qvk_human_field() {
  printf '  %s %s\n' "$(qvk_pad "$(msg "$1")" 14)" "$2"
}

qvk_report_human() {
  printf '%s\n\n' "$(qvk_paint bold "$(msg report.title)")"
  _qvk_human_field report.run_id "$QVK_RUN_ID"
  _qvk_human_field report.profile "$QVK_PROFILE"
  _qvk_human_field report.started "$QVK_STARTED_AT"
  _qvk_human_field report.finished "$QVK_FINISHED_AT"
  _qvk_human_field report.os "${QVK_OS_PRETTY:-$QVK_OS_ID $QVK_OS_VERSION_ID}"
  _qvk_human_field report.arch "$(qvk_arch)"
  _qvk_human_field report.kernel "$(uname -r 2>/dev/null)"
  if ((QVK_OFFLINE)); then
    _qvk_human_field report.offline "$(msg yes)"
  fi
  printf '\n'
  if ((${#QVK_TESTS[@]} == 0)); then
    printf '%s\n\n' "$(msg report.no_tests)"
  fi
  printf '%s\n' "$(msg report.verdicts)"
  _qvk_human_verdict target_self_check "$QVK_SELF_VERDICT" "$QVK_SELF_REASON_KEY" "${QVK_SELF_MISSING[@]}"
  _qvk_human_verdict client_reachability "$QVK_CLIENT_VERDICT" "$QVK_CLIENT_REASON_KEY" "${QVK_CLIENT_MISSING[@]}"
}
