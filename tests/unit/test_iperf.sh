#!/usr/bin/env bash
set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

# The human report must surface the command's diagnostic, not just the host.
source "$REPO_ROOT/lib/report.sh"
source "$REPO_ROOT/lib/i18n.sh"
QVK_LANG=en
QVK_US=$'\x1f'
QVK_LIB="$REPO_ROOT/lib"
qvk_i18n_load
QVK_TEST_HUMAN=("iperf_throughput${QVK_US}iperf_example_com${QVK_US}error${QVK_US}throughput.error${QVK_US}example.com${QVK_US}Connection refused")
declare -A QVK_TEST_GROUP=([iperf_example_com]='')
qvk_pad() { printf '%s' "$1"; }
qvk_paint() { printf '%s' "$2"; }
output=$(_qvk_human_tests iperf_throughput report.section.throughput)
assert_contains "$output" "example.com: Connection refused" "human error includes iperf diagnostic"
finish_tests
