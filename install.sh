#!/usr/bin/env bash
# One-line runner: downloads the pinned release, verifies its SHA-256, runs qvk from a
# temporary directory and removes it. Installs nothing and changes no host settings.
#   curl -fsSL https://raw.githubusercontent.com/thejohnd0e/quality-vps-kit/master/install.sh | bash
#   ... | bash -s -- run --lang ru        (arguments are passed to qvk; default: run)
set -euo pipefail

version=${QVK_VERSION:-0.1.8}
base="https://github.com/thejohnd0e/quality-vps-kit/releases/download/v${version}"
name="quality-vps-kit-${version}"

for tool in curl tar sha256sum mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "install.sh: required tool missing: $tool" >&2; exit 2; }
done

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

curl -fsSL --max-time 60 -o "$tmp/$name.tar.gz" "$base/$name.tar.gz"
curl -fsSL --max-time 60 -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
(cd "$tmp" && sha256sum -c --quiet SHA256SUMS) || { echo "install.sh: checksum mismatch, aborting" >&2; exit 3; }
tar -xzf "$tmp/$name.tar.gz" -C "$tmp"

[[ $# -gt 0 ]] || set -- run
rc=0
"$tmp/$name/qvk" "$@" || rc=$?
exit "$rc"
