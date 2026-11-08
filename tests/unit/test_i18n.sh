#!/usr/bin/env bash
# Message lookup: language selection, fallbacks and argument handling.
set -uo pipefail
# shellcheck source=tests/lib/assert.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"
export LC_ALL=C
QVK_LIB="$REPO_ROOT/lib"
# shellcheck source=lib/common.sh
source "$QVK_LIB/common.sh"
# shellcheck source=lib/i18n.sh
source "$QVK_LIB/i18n.sh"
qvk_i18n_load

QVK_USER_LOCALE=""
qvk_set_lang ""
assert_eq en "$QVK_LANG" "default language is English"
QVK_USER_LOCALE=ru_RU.UTF-8
qvk_set_lang ""
assert_eq ru "$QVK_LANG" "ru locale selects Russian"
qvk_set_lang en
assert_eq en "$QVK_LANG" "explicit flag beats the locale"

qvk_set_lang en
assert_eq "yes" "$(msg yes)" "plain lookup"
assert_eq "no.such.key" "$(msg no.such.key)" "unknown key falls back to the key"
assert_eq "HTTP ai/x" "$(msg test.http ai x)" "arguments are substituted"
assert_eq "HTTP ai/x" "$(msg test.http ai x surplus more)" "surplus arguments are not recycled"
assert_eq "10% done" "$(_qvk_printf_fmt '%s%% done' 10 extra)" "literal %% is not counted as a conversion"
assert_eq "a b" "$(_qvk_printf_fmt '%s %s' a b c d)" "two conversions, four arguments"
assert_eq "x" "$(_qvk_printf_fmt 'x' a b)" "no conversions, surplus arguments ignored"

qvk_set_lang ru
assert_eq "да" "$(msg yes)" "Russian lookup"
assert_eq "yes" "$(msg_en yes)" "msg_en ignores the active language"

# Every Russian key must exist in English and use the same number of conversions.
bad=""
for k in "${!QVK_MSG_RU[@]}"; do
  if [[ -z ${QVK_MSG_EN[$k]+x} ]]; then bad+="$k(missing-en) "; continue; fi
  e=${QVK_MSG_EN[$k]//%%/}
  r=${QVK_MSG_RU[$k]//%%/}
  e=${e//[^%]/}
  r=${r//[^%]/}
  [[ ${#e} == "${#r}" ]] || bad+="$k(args ${#e}!=${#r}) "
done
assert_eq "" "$bad" "ru catalog keys exist in en with matching argument counts"

finish_tests
