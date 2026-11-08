# shellcheck shell=bash
# --redact-ip support: every IP registered by a module is replaced in the final
# human and JSON output with a stable label <ip-N> (N = registration order).
#
# Only registered addresses (the target's own, later the probe's/client's) are
# replaced; public endpoints such as resolvers stay readable. Matching respects
# address boundaries, so 1.2.3.4 never rewrites part of 11.2.3.45.

QVK_SENSITIVE_IPS=()

qvk_register_ip() {
  local ip=$1 x
  [[ -n $ip ]] || return 0
  [[ $ip == 127.* || $ip == ::1 ]] && return 0
  for x in "${QVK_SENSITIVE_IPS[@]}"; do
    [[ $x == "$ip" ]] && return 0
  done
  QVK_SENSITIVE_IPS+=("$ip")
}

_qvk_is_addr_char() { [[ -n $1 && $1 == [0-9A-Fa-f.:] ]]; }

# _qvk_replace_bounded <text> <needle> <label> — prints the result.
_qvk_replace_bounded() {
  local rest=$1 needle=$2 label=$3 out="" pre before after
  while [[ $rest == *"$needle"* ]]; do
    pre=${rest%%"$needle"*}
    rest=${rest#*"$needle"}
    before=${pre: -1}
    [[ -z $pre ]] && before=""
    after=${rest:0:1}
    if _qvk_is_addr_char "$before" || _qvk_is_addr_char "$after"; then
      out+=$pre$needle
    else
      out+=$pre$label
    fi
  done
  printf '%s' "$out$rest"
}

# qvk_redact <text> — prints text with registered IPs replaced (if enabled).
qvk_redact() {
  local text=$1 i ip order
  if ((QVK_REDACT == 0 || ${#QVK_SENSITIVE_IPS[@]} == 0)); then
    printf '%s' "$text"
    return
  fi
  # Longest addresses first so that a shorter one cannot clip a longer one.
  order=$(for i in "${!QVK_SENSITIVE_IPS[@]}"; do
    printf '%d %d\n' "${#QVK_SENSITIVE_IPS[i]}" "$i"
  done | sort -rn | awk '{print $2}')
  for i in $order; do
    ip=${QVK_SENSITIVE_IPS[i]}
    text=$(_qvk_replace_bounded "$text" "$ip" "<ip-$((i + 1))>"; printf x)
    text=${text%x}
  done
  printf '%s' "$text"
}
