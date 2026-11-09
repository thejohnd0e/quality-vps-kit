#!/usr/bin/env bash
# Release preflight must catch drift before producing any archive.
set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

command -v git >/dev/null 2>&1 || { echo "skipped: git not installed"; exit 0; }
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT

setup_repo() {
  local dir=$1 version=${2:-0.1.1}
  mkdir -p "$dir/scripts"
  cp "$REPO_ROOT/scripts/release.sh" "$dir/scripts/release.sh"
  cp "$REPO_ROOT/install.sh" "$dir/install.sh"
  sed -i "s/QVK_VERSION:-[0-9.]*/QVK_VERSION:-$version/" "$dir/install.sh"
  printf '%s\n' "$version" >"$dir/VERSION"
  (cd "$dir" && git init -q && git add . && git -c user.email=t@t -c user.name=t commit -qm init && git tag "v$version")
}

run_check() { (cd "$1" && bash ./scripts/release.sh --check >/dev/null 2>&1); }

GOOD="$T/good"
setup_repo "$GOOD"
run_check "$GOOD"; rc=$?
assert_eq 0 "$rc" "consistent version/tag/install default passes"
assert_true "--check does not create release artifacts" test ! -e "$GOOD/dist"

MISSING="$T/missing-tag"
setup_repo "$MISSING"
(cd "$MISSING" && git tag -d v0.1.1 >/dev/null)
run_check "$MISSING"; rc=$?
assert_eq 2 "$rc" "missing tag rejected"

AHEAD="$T/version-ahead"
setup_repo "$AHEAD"
printf '0.1.2\n' >"$AHEAD/VERSION"
(cd "$AHEAD" && git add VERSION && git -c user.email=t@t -c user.name=t commit -qm bump)
run_check "$AHEAD"; rc=$?
assert_eq 2 "$rc" "VERSION ahead of tag rejected"

DRIFT="$T/install-drift"
setup_repo "$DRIFT"
sed -i 's/QVK_VERSION:-[0-9.]*/QVK_VERSION:-9.9.9/' "$DRIFT/install.sh"
run_check "$DRIFT"; rc=$?
assert_eq 2 "$rc" "install.sh version drift rejected"

DIRTY="$T/dirty"
setup_repo "$DIRTY"
printf '\n# local edit\n' >>"$DIRTY/install.sh"
run_check "$DIRTY"; rc=$?
assert_eq 2 "$rc" "dirty tracked tree rejected"

WORKFLOW="$REPO_ROOT/.github/workflows/release.yml"
assert_true "release workflow exists" test -f "$WORKFLOW"
if [[ -f $WORKFLOW ]]; then
  tests_line=$(grep -nF 'bash tests/run.sh' "$WORKFLOW" | head -n1 | cut -d: -f1)
  publish_line=$(grep -nF 'gh release create' "$WORKFLOW" | head -n1 | cut -d: -f1)
  assert_true "workflow runs tests before publishing" test -n "$tests_line" -a -n "$publish_line" -a "$tests_line" -lt "$publish_line"
  assert_contains "$(cat "$WORKFLOW")" 'tags:' "workflow triggers on a tag push"
  assert_contains "$(cat "$WORKFLOW")" 'v*' "workflow matches version tags"
  assert_contains "$(cat "$WORKFLOW")" 'contents: write' "workflow can publish release assets"
  assert_contains "$(cat "$WORKFLOW")" 'gh release view' "workflow verifies the published release"
  verify_step=$(sed -n '/name: Verify published release/,$p' "$WORKFLOW")
  assert_contains "$verify_step" 'GH_TOKEN:' "release verification has GitHub API auth"
fi

finish_tests
