#!/usr/bin/env bash
# Run all offline checks: syntax, ShellCheck, Python compile, schema, unit tests.
# No network access is needed. Set QVK_REQUIRE_SHELLCHECK=1 (CI) to fail when
# the ShellCheck binary is missing instead of skipping that step.
set -uo pipefail
# shellcheck source=tests/lib/assert.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/assert.sh"
cd -- "$REPO_ROOT" || exit 1

failed=0
step() { printf '\n== %s\n' "$*"; }
bad() {
  printf 'FAILED: %s\n' "$*" >&2
  failed=1
}

mapfile -t shell_files < <(
  {
    printf '%s\n' qvk
    find lib tests -type f -name '*.sh'
  } | sort
)

step "bash -n (${#shell_files[@]} files)"
for f in "${shell_files[@]}"; do
  bash -n "$f" || bad "bash -n $f"
done

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -S style "${shell_files[@]}" || bad "shellcheck"
elif [[ ${QVK_REQUIRE_SHELLCHECK:-0} == 1 ]]; then
  bad "shellcheck is required but not installed"
else
  echo "skipped: shellcheck not installed"
fi

PY=$(find_python) || {
  bad "python 3 not found"
  exit 1
}

step "python compile"
"$PY" -I -m py_compile tests/tools/validate_report.py || bad "py_compile"

step "schema: example and negative fixture"
"$PY" -I -c 'import json,sys; json.load(open(sys.argv[1],encoding="utf-8"))' schema/report.schema.json \
  || bad "schema is not valid JSON"
"$PY" -I tests/tools/validate_report.py schema/examples/*.json || bad "examples must validate"
if "$PY" -I tests/tools/validate_report.py tests/fixtures/invalid/*.json >/dev/null 2>&1; then
  bad "invalid fixtures must be rejected"
else
  echo "invalid fixtures rejected"
fi

for t in tests/unit/test_*.sh; do
  step "$t"
  bash "$t" || bad "$t"
done

echo
if ((failed)); then
  echo "RESULT: FAILED"
  exit 1
fi
echo "RESULT: OK"
