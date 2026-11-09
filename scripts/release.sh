#!/usr/bin/env bash
# Build a release tarball plus SHA256SUMS from the committed tree (run on a
# developer machine, not on the VPS). Usage: scripts/release.sh [output-dir]
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"

check_only=0
out=""
while (($#)); do
  case $1 in
    --check) check_only=1 ;;
    -h | --help)
      echo "usage: scripts/release.sh [--check] [output-dir]"
      exit 0
      ;;
    *)
      [[ -z $out ]] || { echo "release.sh: unexpected argument: $1" >&2; exit 2; }
      out=$1
      ;;
  esac
  shift
done

_release_error() { echo "release.sh: $*" >&2; exit 2; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || _release_error "not inside a git work tree"
[[ -z $(git status --porcelain --untracked-files=no) ]] || _release_error "the working tree has uncommitted changes; commit first"
git ls-files --error-unmatch VERSION >/dev/null 2>&1 || _release_error "VERSION is not tracked"
version=$(<VERSION)
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || _release_error "VERSION must be a valid x.y.z SemVer value"
tag="v$version"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1 || _release_error "git tag $tag is missing"
tag_commit=$(git rev-parse "$tag^{commit}")
head_commit=$(git rev-parse HEAD)
[[ $tag_commit == "$head_commit" ]] || _release_error "tag $tag does not point to HEAD"
pin_line="version=\${QVK_VERSION:-$version}"
pin_count=$(grep -Fxc -- "$pin_line" install.sh || true)
assignment_count=$(grep -c '^version=' install.sh || true)
[[ $pin_count == 1 && $assignment_count == 1 ]] || _release_error "install.sh default does not match VERSION $version"

echo "release.sh: checks passed: $tag"
((check_only)) && exit 0

out=${out:-"$root/dist"}
name="quality-vps-kit-$version"
mkdir -p -- "$out"

git archive --format=tar.gz --prefix="$name/" -o "$out/$name.tar.gz" HEAD
(
  cd -- "$out"
  sha256sum "$name.tar.gz" >SHA256SUMS
)

echo "created: $out/$name.tar.gz"
echo "checksum: $(cat -- "$out/SHA256SUMS")"
echo "verify on the VPS with: sha256sum -c SHA256SUMS"
