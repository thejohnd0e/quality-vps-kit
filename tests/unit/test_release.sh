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
commit_and_retag() {
  local dir=$1
  (cd "$dir" && git add . && git -c user.email=t@t -c user.name=t commit -qm test-change && git -c user.email=t@t -c user.name=t tag -fa v0.1.1 -m test HEAD >/dev/null)
}

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
printf '# newer commit\n' >"$AHEAD/extra"
(cd "$AHEAD" && git add extra && git -c user.email=t@t -c user.name=t commit -qm newer)
run_check "$AHEAD"; rc=$?
assert_eq 2 "$rc" "tag pointing behind HEAD rejected"

DRIFT="$T/install-drift"
setup_repo "$DRIFT"
sed -i 's/QVK_VERSION:-[0-9.]*/QVK_VERSION:-9.9.9/' "$DRIFT/install.sh"
commit_and_retag "$DRIFT"
output=$(cd "$DRIFT" && bash ./scripts/release.sh --check 2>&1); rc=$?
assert_eq 2 "$rc" "install.sh version drift rejected"
assert_contains "$output" 'install.sh default' "install pin check reached for a clean matching tag"

PREFIX="$T/install-prefix"
setup_repo "$PREFIX"
sed -i 's/QVK_VERSION:-[0-9.]*/QVK_VERSION:-0.1.10/' "$PREFIX/install.sh"
commit_and_retag "$PREFIX"
output=$(cd "$PREFIX" && bash ./scripts/release.sh --check 2>&1); rc=$?
assert_eq 2 "$rc" "install.sh version prefix does not count as a match"
assert_contains "$output" 'install.sh default' "prefix pin does not satisfy exact version"

BADVER="$T/malformed-version"
setup_repo "$BADVER"
printf '0.1. 1\n' >"$BADVER/VERSION"
(cd "$BADVER" && git add VERSION && git -c user.email=t@t -c user.name=t commit -qm malformed && git -c user.email=t@t -c user.name=t tag -fa v0.1.1 -m test HEAD >/dev/null)
run_check "$BADVER"; rc=$?
assert_eq 2 "$rc" "internal whitespace in version rejected"

LEADING="$T/leading-zero"
setup_repo "$LEADING"
printf '00.1.1\n' >"$LEADING/VERSION"
(cd "$LEADING" && git add VERSION && git -c user.email=t@t -c user.name=t commit -qm malformed && git -c user.email=t@t -c user.name=t tag -fa v00.1.1 -m test HEAD >/dev/null)
run_check "$LEADING"; rc=$?
assert_eq 2 "$rc" "leading zero in SemVer component rejected"

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
  assert_contains "$(cat "$WORKFLOW")" 'GITHUB_REF_NAME' "workflow checks the triggering tag identity"
  assert_contains "$(cat "$WORKFLOW")" 'GITHUB_REF_NAME" != "$expected_tag"' "mismatched trigger tag is rejected before publishing"
  assert_contains "$verify_step" 'SHA256SUMS' "asset verification checks the checksum asset"
  assert_contains "$verify_step" 'quality-vps-kit-' "asset verification checks the archive asset"
  assert_contains "$verify_step" 'grep -Fxq' "asset verification fails when an exact asset is missing"
fi

finish_tests
