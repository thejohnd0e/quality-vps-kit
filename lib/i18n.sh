# shellcheck shell=bash
# Message lookup. All output is English.

declare -gA QVK_MSG_EN=()

qvk_i18n_load() {
  # shellcheck source=lib/i18n/en.sh
  source "$QVK_LIB/i18n/en.sh"
}

# Human output is English only (JSON too); the language setting is kept so the
# --lang en flag stays accepted.
qvk_set_lang() { :; }

# msg <key> [printf args...] — English catalog, key fallback.
msg() {
  local key=$1 fmt
  shift
  fmt=${QVK_MSG_EN[$key]:-$key}
  _qvk_printf_fmt "$fmt" "$@"
}

# printf with exactly as many arguments as the format has conversions; bash's
# printf would otherwise recycle the format for surplus arguments.
_qvk_printf_fmt() {
  local fmt=$1 n
  shift
  n=${fmt//%%/}
  n=${n//[^%]/}
  n=${#n}
  # shellcheck disable=SC2059  # formats come from our own catalogs
  printf -- "$fmt" "${@:1:n}"
}

qvk_msg_has() { [[ -n ${QVK_MSG_EN[$1]+x} ]]; }

# msg_en <key> [args...] — always English (for JSON fields).
msg_en() {
  local key=$1 fmt
  shift
  fmt=${QVK_MSG_EN[$key]:-$key}
  _qvk_printf_fmt "$fmt" "$@"
}
