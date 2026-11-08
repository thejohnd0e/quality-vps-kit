# shellcheck shell=bash
# Minimal JSON emitter in pure Bash (no jq dependency).
#
# All functions print a JSON fragment to stdout. Compose them with command
# substitution, e.g.:
#   json_obj name "$(json_str "$x")" count "$(json_num "$n")"
#
# Requires LC_ALL=C (set by qvk_init_env) so that string operations are
# byte-wise. Strings are passed through `iconv -c` when they contain non-ASCII
# bytes so that invalid UTF-8 never reaches the output.

# Drop invalid UTF-8 sequences. Valid UTF-8 (e.g. Cyrillic) is preserved.
_json_sanitize_utf8() {
  local s=$1 r
  if [[ $s != *[$'\x80'-$'\xff']* ]]; then
    printf '%s' "$s"
    return
  fi
  if command -v iconv >/dev/null 2>&1; then
    # The sentinel keeps trailing newlines that $(...) would otherwise strip
    # and proves that iconv produced complete output. `iconv -c` exits non-zero
    # whenever it dropped bytes, so its exit status is deliberately ignored.
    r=$(printf '%sx' "$s" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
    if [[ $r == *x ]]; then
      printf '%s' "${r%x}"
      return
    fi
  fi
  # Degraded fallback: replace every non-ASCII byte.
  printf '%s' "${s//[$'\x80'-$'\xff']/?}"
}

# Print the escaped body of a JSON string (without surrounding quotes).
json_escape() {
  local s out ch i hex
  s=$(_json_sanitize_utf8 "$1"x)
  s=${s%x}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  if [[ $s == *[$'\x01'-$'\x1f']* ]]; then
    out=""
    for ((i = 0; i < ${#s}; i++)); do
      ch=${s:i:1}
      case $ch in
        [$'\x01'-$'\x1f'])
          printf -v hex '\\u%04x' "'$ch"
          out+=$hex
          ;;
        *) out+=$ch ;;
      esac
    done
    s=$out
  fi
  printf '%s' "$s"
}

json_str() { printf '"%s"' "$(json_escape "$1")"; }

# String or null when the value is empty.
json_str_or_null() {
  if [[ -z $1 ]]; then printf 'null'; else json_str "$1"; fi
}

json_null() { printf 'null'; }

# Number, or null when the value is empty / not a valid JSON number.
json_num() {
  if [[ $1 =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
    printf '%s' "$1"
  else
    printf 'null'
  fi
}

# true/false from 1/0/true/false/yes/no; anything else -> null.
json_bool() {
  case $1 in
    1 | true | yes) printf 'true' ;;
    0 | false | no) printf 'false' ;;
    *) printf 'null' ;;
  esac
}

# json_obj key1 frag1 key2 frag2 ...  (fragments are already-encoded JSON)
json_obj() {
  if (($# % 2 != 0)); then
    printf 'qvk: internal error: json_obj needs key/value pairs\n' >&2
    return 3
  fi
  local out="{" sep="" k
  while (($#)); do
    k=$(json_escape "$1")
    out+="$sep\"$k\":$2"
    sep=","
    shift 2
  done
  printf '%s}' "$out"
}

# json_arr frag1 frag2 ...  (fragments are already-encoded JSON)
json_arr() {
  local out="[" sep="" v
  for v in "$@"; do
    out+="$sep$v"
    sep=","
  done
  printf '%s]' "$out"
}

# json_str_arr str1 str2 ...  (plain strings, encoded here)
json_str_arr() {
  local items=() v
  for v in "$@"; do items+=("$(json_str "$v")"); done
  json_arr "${items[@]}"
}
