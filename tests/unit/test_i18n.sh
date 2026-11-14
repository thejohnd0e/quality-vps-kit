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

qvk_set_lang en
assert_eq "yes" "$(msg yes)" "plain lookup"
assert_eq "no.such.key" "$(msg no.such.key)" "unknown key falls back to the key"
assert_eq "HTTP ai/x" "$(msg test.http ai x)" "arguments are substituted"
assert_eq "HTTP ai/x" "$(msg test.http ai x surplus more)" "surplus arguments are not recycled"
assert_eq "10% done" "$(_qvk_printf_fmt '%s%% done' 10 extra)" "literal %% is not counted as a conversion"
assert_eq "a b" "$(_qvk_printf_fmt '%s %s' a b c d)" "two conversions, four arguments"
assert_eq "x" "$(_qvk_printf_fmt 'x' a b)" "no conversions, surplus arguments ignored"
assert_eq "low trust score" "$(msg claude_risk.reason.low_trust_score)" "claude risk reason text"
assert_eq "Claude risk" "$(msg report.claude_risk)" "claude risk label"
assert_eq "Claude trust score 79" "$(msg claude_risk.trust 79)" "claude trust score wording"

assert_eq "yes" "$(msg_en yes)" "msg_en returns English"


finish_tests
