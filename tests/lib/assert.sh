# shellcheck shell=bash
# Tiny assertion helpers for qvk tests. No external dependencies.

TESTS_RUN=0
TESTS_FAILED=0
# shellcheck disable=SC2034  # used by the test files that source this
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)

_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  FAIL: %s\n' "$*" >&2
}

_ok() { printf '  ok:   %s\n' "$*"; }

# assert_eq <expected> <actual> <name>
assert_eq() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ $1 == "$2" ]]; then _ok "$3"; else _fail "$3 (expected [$1], got [$2])"; fi
}

# assert_contains <haystack> <needle> <name>
assert_contains() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ $1 == *"$2"* ]]; then _ok "$3"; else _fail "$3 (missing [$2] in [${1:0:300}])"; fi
}

# assert_not_contains <haystack> <needle> <name>
assert_not_contains() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ $1 != *"$2"* ]]; then _ok "$3"; else _fail "$3 (unexpected [$2])"; fi
}

# assert_true <name> <command...>
assert_true() {
  local name=$1
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@"; then _ok "$name"; else _fail "$name"; fi
}

finish_tests() {
  printf '%s: %d checks, %d failed\n' "$(basename -- "$0")" "$TESTS_RUN" "$TESTS_FAILED"
  ((TESTS_FAILED == 0))
}

# Print a working Python 3 interpreter (python3 or python), or nothing.
find_python() {
  local c
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 \
      && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

is_windows_shell() {
  case $(uname -s) in MINGW* | MSYS* | CYGWIN*) return 0 ;; esac
  return 1
}
