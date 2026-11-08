# shellcheck shell=bash
# Per-area verdicts (QVK-08). Read by lib/report.sh.
# shellcheck disable=SC2034

# target_self_check uses the built-in v0.1 preset (documented in
# docs/methodology.md). A criterion is "ok", "fail" (verified violation) or
# "unknown" (not enough data):
#   - supported OS/arch (guaranteed: qvk run refuses otherwise)
#   - RAM >= QVK_PRESET_MIN_RAM_MB
#   - public egress IPv4 determined without conflict
#   - DNS resolution works
#   - at least one baseline HTTPS endpoint answers
#   - |clock offset| <= QVK_CLOCK_MAX_OFFSET_S
# Any fail -> unsuitable; otherwise any unknown -> indeterminate; else suitable.
# /dev/net/tun is deliberately not a criterion (see TZ v1.2, change 11).
#
# Reasons are stored as "<i18n key><US><arg>..." so that JSON gets English text
# and the human report the active language.

QVK_PRESET_MIN_RAM_MB=512

QVK_SELF_VERDICT="indeterminate"
QVK_SELF_REASON_CODE="insufficient_data"
QVK_SELF_REASONS=()
QVK_SELF_MISSING=()

QVK_CLIENT_VERDICT="indeterminate"
QVK_CLIENT_REASON_CODE="no_probe"
QVK_CLIENT_REASONS=("reason.no_probe")
QVK_CLIENT_MISSING=(client_reachability)

QVK_CLOCK_OFFSET_S=""

_vd_add_missing() {
  local s
  for s in "${QVK_SELF_MISSING[@]}"; do [[ $s == "$1" ]] && return 0; done
  QVK_SELF_MISSING+=("$1")
}

qvk_verdict_evaluate() {
  local fails=() unknowns=() ram=${QVK_SYS[memory.total_mb]:-}
  QVK_SELF_MISSING=()

  if [[ -z $ram ]]; then
    unknowns+=("verdict.ram_unknown")
    _vd_add_missing system
  elif ((ram < QVK_PRESET_MIN_RAM_MB)); then
    fails+=("verdict.ram_low${QVK_US}$ram${QVK_US}$QVK_PRESET_MIN_RAM_MB")
  fi

  case $QVK_EGRESS4_STATUS in
    pass) ;;
    fail) fails+=("verdict.no_egress") ;;
    conflict)
      unknowns+=("verdict.egress_conflict")
      _vd_add_missing network_egress
      ;;
    *)
      unknowns+=("verdict.egress_unknown")
      _vd_add_missing network_egress
      ;;
  esac

  case $QVK_DNS_STATUS in
    pass | warn) ;;
    fail) fails+=("verdict.dns_fail") ;;
    *)
      unknowns+=("verdict.dns_unknown")
      _vd_add_missing network_egress
      ;;
  esac

  if ((QVK_BASELINE_PASS > 0)); then
    :
  elif ((QVK_BASELINE_NETFAIL > 0)); then
    fails+=("verdict.https_fail")
  else
    # Not run, or only tester errors: no network evidence either way.
    unknowns+=("verdict.https_unknown")
    _vd_add_missing network_egress
  fi

  case $QVK_CLOCK_STATUS in
    pass) ;;
    warn) fails+=("verdict.clock_bad${QVK_US}${QVK_CLOCK_OFFSET_S:-?}${QVK_US}$QVK_CLOCK_MAX_OFFSET_S") ;;
    *)
      unknowns+=("verdict.clock_unknown")
      _vd_add_missing system
      ;;
  esac

  if ((${#fails[@]})); then
    QVK_SELF_VERDICT=unsuitable
    QVK_SELF_REASON_CODE=criteria_failed
    QVK_SELF_REASONS=("${fails[@]}")
    QVK_SELF_MISSING=()
  elif ((${#unknowns[@]})); then
    QVK_SELF_VERDICT=indeterminate
    if ((QVK_OFFLINE)); then
      QVK_SELF_REASON_CODE=offline_mode
      QVK_SELF_REASONS=("verdict.offline" "${unknowns[@]}")
    else
      QVK_SELF_REASON_CODE=insufficient_data
      QVK_SELF_REASONS=("${unknowns[@]}")
    fi
  else
    QVK_SELF_VERDICT=suitable
    QVK_SELF_REASON_CODE=""
    QVK_SELF_REASONS=("verdict.all_passed")
  fi
}
