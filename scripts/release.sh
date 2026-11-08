#!/usr/bin/env bash
# Build a release tarball plus SHA256SUMS from the committed tree (run on a
# developer machine, not on the VPS). Usage: scripts/release.sh [output-dir]
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"

if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
  echo "release.sh: the working tree has uncommitted changes; commit first" >&2
  exit 1
fi

version=$(tr -d '[:space:]' <VERSION)
out=${1:-"$root/dist"}
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
