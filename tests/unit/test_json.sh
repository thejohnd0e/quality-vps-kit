#!/usr/bin/env bash
# Unit tests for lib/json.sh: escaping round-trips through a real JSON parser.
set -uo pipefail
# shellcheck source=tests/lib/assert.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"
export LC_ALL=C
# shellcheck source=lib/json.sh
source "$REPO_ROOT/lib/json.sh"

PY=$(find_python) || {
  echo "python 3 is required for JSON round-trip tests" >&2
  exit 1
}
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

# --- numbers / bools / structure -------------------------------------------
assert_eq '0' "$(json_num 0)" "json_num 0"
assert_eq '-12.5' "$(json_num -12.5)" "json_num negative float"
assert_eq '1e-3' "$(json_num 1e-3)" "json_num exponent"
assert_eq 'null' "$(json_num '')" "json_num empty -> null"
assert_eq 'null' "$(json_num 'N/A')" "json_num N/A -> null"
assert_eq 'null' "$(json_num '01')" "json_num leading zero -> null"
assert_eq 'null' "$(json_num '1.')" "json_num trailing dot -> null"
assert_eq 'null' "$(json_num '1;rm')" "json_num injection -> null"
assert_eq 'true' "$(json_bool 1)" "json_bool 1"
assert_eq 'false' "$(json_bool false)" "json_bool false"
assert_eq 'null' "$(json_bool maybe)" "json_bool unknown -> null"
assert_eq 'null' "$(json_str_or_null '')" "json_str_or_null empty"
assert_eq '[]' "$(json_arr)" "json_arr empty"
assert_eq '["a","b c"]' "$(json_str_arr a 'b c')" "json_str_arr"
assert_eq '{"a":1,"b":null}' "$(json_obj a 1 b null)" "json_obj"
json_obj a 2>/dev/null
assert_eq 3 "$?" "json_obj with odd args fails with code 3"

# --- string round-trips -----------------------------------------------------
# shellcheck disable=SC2016  # literal $(...) and backticks are test data
cases=(
  'plain'
  ''
  'quote " inside'
  'back\slash \\ double'
  $'new\nline'
  $'tab\there'
  $'cr\rhere'
  $'ctrl\x01\x02\x1f end'
  $'bs\b ff\f'
  $'trailing newline\n\n'
  'Привет, мир — UTF-8 ✓'
  '</script><!-- ${x} $(id) `id`'
  $'mixed "q" \\ \n Ж \x07'
)
i=0
for c in "${cases[@]}"; do
  printf '%s' "$c" >"$WORK/raw.$i"
  json_obj v "$(json_str "$c")" >"$WORK/json.$i"
  i=$((i + 1))
done

out=$("$PY" -I - "$WORK" "$i" <<'PY'
import json, sys
work, n = sys.argv[1], int(sys.argv[2])
bad = []
for i in range(n):
    raw = open(f"{work}/raw.{i}", "rb").read()
    try:
        got = json.loads(open(f"{work}/json.{i}", "rb").read().decode("utf-8"))["v"]
    except Exception as exc:
        bad.append(f"case {i}: invalid JSON: {exc}")
        continue
    if got.encode("utf-8") != raw:
        bad.append(f"case {i}: {got!r} != {raw!r}")
print("\n".join(bad) if bad else "OK")
PY
)
assert_eq OK "$out" "string round-trips (${#cases[@]} cases)"

# Invalid UTF-8 must still produce valid JSON (bytes dropped or replaced).
json_obj v "$(json_str $'ok\xff\xfe end \xd0')" >"$WORK/invalid.json"
out=$("$PY" -I -c 'import json,sys; v=json.loads(open(sys.argv[1],"rb").read().decode("utf-8"))["v"]; print("OK" if v.startswith("ok") and " end " in v else repr(v))' "$WORK/invalid.json" 2>&1)
assert_eq OK "$out" "invalid UTF-8 yields valid JSON"

# Valid Cyrillic is preserved byte-for-byte even when mixed with invalid bytes.
json_obj v "$(json_str $'Ж\xffЖ')" >"$WORK/mixed.json"
out=$("$PY" -I -c 'import json,sys; v=json.loads(open(sys.argv[1],"rb").read().decode("utf-8"))["v"]; print("OK" if v.count("Ж")==2 else repr(v))' "$WORK/mixed.json" 2>&1)
assert_eq OK "$out" "valid UTF-8 kept around invalid bytes"

finish_tests
