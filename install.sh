#!/usr/bin/env bash
# One-line runner: downloads qvk from the master branch and runs it.
# Installs nothing and changes no host settings.
#   curl -fsSL https://raw.githubusercontent.com/thejohnd0e/quality-vps-kit/master/install.sh | bash
#   ... | bash -s -- run --offline       (arguments are passed to qvk; default: run)
set -euo pipefail

base="https://github.com/thejohnd0e/quality-vps-kit/archive/refs/heads/master"
name="quality-vps-kit-master.tar.gz"

for tool in curl tar mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "install.sh: required tool missing: $tool" >&2; exit 2; }
done

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

curl -fsSL --max-time 60 -o "$tmp/$name" "$base.tar.gz"
tar -xzf "$tmp/$name" -C "$tmp"

[[ $# -gt 0 ]] || set -- run
rc=0
"$tmp/quality-vps-kit-master/qvk" "$@" || rc=$?
exit "$rc"
