#!/usr/bin/env bash
# CLI tests for ./qvk: commands, exit codes, root/platform gating, report output.
# Uses fixtures and test hooks only; never touches the network.
set -uo pipefail
# shellcheck source=tests/lib/assert.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

PY=$(find_python) || {
  echo "python 3 is required for report validation" >&2
  exit 1
}
QVK="$REPO_ROOT/qvk"
FIX="$REPO_ROOT/tests/fixtures"
VALIDATE="$REPO_ROOT/tests/tools/validate_report.py"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

# Stub binaries so `run` passes the required-tool check on any host (e.g. no
# `ip` on a developer's Windows machine). They must never be executed for real.
mkdir -p "$WORK/bin"
for t in ip curl; do
  # shellcheck disable=SC2016  # the stub body is literal shell code
  printf '#!/bin/sh\n[ "$1" = "--version" ] && echo "%s 0.0.0-stub" && exit 0\necho "stub %s must not run" >&2\nexit 99\n' "$t" "$t" >"$WORK/bin/$t"
  chmod +x "$WORK/bin/$t"
done
export PATH="$WORK/bin:$PATH"
unset NO_COLOR LANG LC_ALL LC_MESSAGES

# Common environment for a supported root run.
as_root_debian() {
  QVK_TEST_EUID=0 QVK_TEST_OS_RELEASE="$FIX/os-release/debian-12" QVK_TEST_ARCH=x86_64 "$@"
}

# run_qvk <env-wrapper|-> args... ; sets OUT, ERR, CODE
run_qvk() {
  local wrap=$1
  shift
  if [[ $wrap == - ]]; then
    "$QVK" "$@" >"$WORK/out" 2>"$WORK/err"
  else
    "$wrap" "$QVK" "$@" >"$WORK/out" 2>"$WORK/err"
  fi
  CODE=$?
  OUT=$(cat "$WORK/out")
  ERR=$(cat "$WORK/err")
}

validate() { "$PY" -I "$VALIDATE" "$1" >/dev/null 2>"$WORK/validate.err"; }
json_field() { "$PY" -I -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8"));
for k in sys.argv[2].split("."): d=d[k]
print(json.dumps(d))' "$1" "$2"; }

echo "# version / help"
run_qvk - version
assert_eq 0 "$CODE" "version exits 0"
assert_contains "$OUT" "$(cat "$REPO_ROOT/VERSION")" "version prints VERSION"
run_qvk - --help
assert_eq 0 "$CODE" "--help exits 0"
assert_contains "$OUT" "Usage: qvk" "--help prints usage"
run_qvk - --lang ru help
assert_contains "$OUT" "Использование" "global --lang ru localizes help"
run_qvk - help --lang=ru
assert_contains "$OUT" "Использование" "--lang=ru after command localizes help"
LANG=ru_RU.UTF-8 run_qvk - help
assert_contains "$OUT" "Использование" "LANG=ru_RU selects Russian"
run_qvk - help --lang de
assert_eq 1 "$CODE" "unsupported --lang is a usage error"

echo "# usage errors (exit 1)"
run_qvk - bogus
assert_eq 1 "$CODE" "unknown command"
run_qvk as_root_debian run --profile turbo
assert_eq 1 "$CODE" "bad --profile"
run_qvk as_root_debian run --format xml
assert_eq 1 "$CODE" "bad --format"
run_qvk as_root_debian run --frobnicate
assert_eq 1 "$CODE" "unknown run option"
run_qvk as_root_debian run --output
assert_eq 1 "$CODE" "--output without value"
run_qvk as_root_debian run --output=
assert_eq 1 "$CODE" "--output= empty value"
run_qvk as_root_debian run --allow-load
assert_eq 1 "$CODE" "--allow-load is not implemented in v0.1"
assert_contains "$ERR" "not implemented in v0.1" "--allow-load explains why"
run_qvk as_root_debian run --max-traffic-mb 250
assert_eq 1 "$CODE" "--max-traffic-mb is not implemented in v0.1"
QVK_TEST_EUID=1000 run_qvk - run --allow-load
assert_eq 1 "$CODE" "usage errors win over the root check"

echo "# environment errors (exit 2)"
QVK_TEST_EUID=1000 QVK_TEST_OS_RELEASE="$FIX/os-release/debian-12" run_qvk - run
assert_eq 2 "$CODE" "run without root exits 2"
assert_contains "$ERR" "root" "run without root explains root is required"
assert_eq "" "$OUT" "run without root prints nothing to stdout"
QVK_TEST_EUID=0 QVK_TEST_OS_RELEASE="$FIX/os-release/centos-9" QVK_TEST_ARCH=x86_64 run_qvk - run
assert_eq 2 "$CODE" "unsupported OS exits 2"
assert_contains "$ERR" "centos" "unsupported OS is named"
QVK_TEST_EUID=0 QVK_TEST_OS_RELEASE="$FIX/os-release/debian-12" QVK_TEST_ARCH=riscv64 run_qvk - run
assert_eq 2 "$CODE" "unsupported arch exits 2"
QVK_TEST_EUID=0 QVK_TEST_OS_RELEASE="$WORK/nonexistent" QVK_TEST_ARCH=x86_64 run_qvk - run
assert_eq 2 "$CODE" "missing os-release exits 2"

echo "# run as root on a supported platform"
run_qvk as_root_debian run --format json
assert_eq 0 "$CODE" "run --format json exits 0"
printf '%s\n' "$OUT" >"$WORK/r1.json"
assert_true "stdout JSON matches schema" validate "$WORK/r1.json"
assert_eq '"indeterminate"' "$(json_field "$WORK/r1.json" summary.verdicts.client_reachability.verdict)" \
  "client_reachability is indeterminate without a probe"
assert_eq '"no_probe"' "$(json_field "$WORK/r1.json" summary.verdicts.client_reachability.reason_code)" \
  "client_reachability reason_code no_probe"
assert_eq '"quick"' "$(json_field "$WORK/r1.json" run.profile)" "default profile is quick"
assert_eq '"debian"' "$(json_field "$WORK/r1.json" system.os.id)" "os id from os-release"
assert_eq '"amd64"' "$(json_field "$WORK/r1.json" system.arch)" "x86_64 normalized to amd64"
assert_eq 'false' "$(json_field "$WORK/r1.json" run.load_test_enabled)" "load tests disabled"

QVK_TEST_EUID=0 QVK_TEST_OS_RELEASE="$FIX/os-release/ubuntu-24.04" QVK_TEST_ARCH=aarch64 \
  run_qvk - run --profile full --offline --redact-ip --format json
assert_eq 0 "$CODE" "ubuntu 24.04 arm64 full offline exits 0"
printf '%s\n' "$OUT" >"$WORK/r2.json"
assert_true "full/offline JSON matches schema" validate "$WORK/r2.json"
assert_eq 'true' "$(json_field "$WORK/r2.json" run.offline)" "run.offline recorded"
assert_eq 'true' "$(json_field "$WORK/r2.json" run.redacted)" "run.redacted recorded"
assert_eq '"arm64"' "$(json_field "$WORK/r2.json" system.arch)" "aarch64 normalized to arm64"

run_qvk as_root_debian run --output "$WORK/report.json"
assert_eq 0 "$CODE" "run --output exits 0"
assert_eq "" "$OUT" "nothing on stdout when --output is used"
assert_contains "$ERR" "$WORK/report.json" "saved path reported on stderr"
assert_true "--output defaults to JSON matching schema" validate "$WORK/report.json"
if ! is_windows_shell; then
  assert_eq 600 "$(stat -c %a "$WORK/report.json")" "report file mode is 0600"
fi
run_qvk as_root_debian run --output "$WORK/no/such/dir/r.json"
assert_eq 1 "$CODE" "--output into a missing directory is a usage error"

run_qvk as_root_debian run
assert_eq 0 "$CODE" "human report exits 0"
assert_contains "$OUT" "Target self-check" "human report shows target self-check"
assert_contains "$OUT" "indeterminate" "human report shows verdict"
assert_not_contains "$OUT" $'\033[' "no ANSI colors when stdout is not a TTY"
run_qvk as_root_debian run --lang ru
assert_contains "$OUT" "Самопроверка VPS" "human report in Russian"
assert_contains "$OUT" "не определено" "verdict translated"

echo "# doctor"
QVK_TEST_EUID=1000 QVK_TEST_OS_RELEASE="$FIX/os-release/debian-12" QVK_TEST_ARCH=x86_64 run_qvk - doctor
assert_eq 0 "$CODE" "doctor works without root on a supported platform"
assert_contains "$OUT" "not root" "doctor warns about missing root"
assert_contains "$OUT" "log in as root" "doctor says how to fix"
run_qvk as_root_debian doctor
assert_eq 0 "$CODE" "doctor as root exits 0"
assert_contains "$OUT" 'ready for "qvk run"' "doctor reports ready"
QVK_TEST_EUID=0 QVK_TEST_OS_RELEASE="$FIX/os-release/centos-9" QVK_TEST_ARCH=x86_64 run_qvk - doctor
assert_eq 2 "$CODE" "doctor on unsupported OS exits 2"
run_qvk as_root_debian doctor --lang ru
assert_contains "$OUT" "Обязательные утилиты" "doctor in Russian"
run_qvk as_root_debian doctor --bogus
assert_eq 1 "$CODE" "doctor rejects unknown options"

finish_tests
