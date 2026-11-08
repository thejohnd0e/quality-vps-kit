# shellcheck shell=bash
# Message lookup. Human output uses the active language; JSON uses English.

declare -gA QVK_MSG_EN=()
declare -gA QVK_MSG_RU=()
QVK_LANG=en

qvk_i18n_load() {
  # shellcheck source=lib/i18n/en.sh
  source "$QVK_LIB/i18n/en.sh"
  # shellcheck source=lib/i18n/ru.sh
  source "$QVK_LIB/i18n/ru.sh"
}

# Pick the language: explicit flag wins, then the user's locale, then English.
qvk_set_lang() {
  local requested=$1
  if [[ -n $requested ]]; then
    QVK_LANG=$requested
  elif [[ $QVK_USER_LOCALE == ru* ]]; then
    QVK_LANG=ru
  else
    QVK_LANG=en
  fi
}

# msg <key> [printf args...] — active language, English fallback, key fallback.
msg() {
  local key=$1 fmt
  shift
  if [[ $QVK_LANG == ru && -n ${QVK_MSG_RU[$key]+x} ]]; then
    fmt=${QVK_MSG_RU[$key]}
  else
    fmt=${QVK_MSG_EN[$key]:-$key}
  fi
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
