# shellcheck shell=bash
# Globals defined here are consumed by ./qvk and lib/report.sh.
# shellcheck disable=SC2034

# Platform, privilege and tool detection. Read-only.
#
# Test hooks (documented in docs/architecture.md), never needed in production:
#   QVK_TEST_OS_RELEASE  path to an os-release fixture
#   QVK_TEST_ARCH        value to use instead of `uname -m`
#   QVK_TEST_EUID        value to use instead of $EUID
#   QVK_TEST_TUN         path to use instead of /dev/net/tun

QVK_OS_ID=""
QVK_OS_VERSION_ID=""
QVK_OS_PRETTY=""

QVK_REQUIRED_TOOLS=(curl ip timeout mktemp date awk sed grep)
QVK_OPTIONAL_TOOLS=(jq iconv ping tracepath mtr iperf3 dig ss chronyc timedatectl systemd-detect-virt git)

# Parse os-release as data (never `source` it).
qvk_read_os_release() {
  local f=${QVK_TEST_OS_RELEASE:-/etc/os-release} k v
  QVK_OS_ID="" QVK_OS_VERSION_ID="" QVK_OS_PRETTY=""
  [[ -r $f ]] || return 1
  while IFS='=' read -r k v || [[ -n $k ]]; do
    v=${v%$'\r'}
    if [[ $v == \"*\" || $v == \'*\' ]]; then
      v=${v:1:${#v}-2}
    fi
    case $k in
      ID) QVK_OS_ID=$v ;;
      VERSION_ID) QVK_OS_VERSION_ID=$v ;;
      PRETTY_NAME) QVK_OS_PRETTY=$v ;;
    esac
  done <"$f"
  [[ -n $QVK_OS_ID ]]
}

qvk_os_supported() {
  case "$QVK_OS_ID:$QVK_OS_VERSION_ID" in
    debian:12 | debian:13 | ubuntu:22.04 | ubuntu:24.04) return 0 ;;
  esac
  return 1
}

qvk_arch() {
  local m=${QVK_TEST_ARCH:-}
  [[ -n $m ]] || m=$(uname -m)
  case $m in
    x86_64 | amd64) printf 'amd64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) printf '%s' "$m" ;;
  esac
}

qvk_arch_supported() {
  case $(qvk_arch) in
    amd64 | arm64) return 0 ;;
  esac
  return 1
}

qvk_platform_label() {
  printf '%s %s/%s' "${QVK_OS_ID:-unknown}" "${QVK_OS_VERSION_ID:-?}" "$(qvk_arch)"
}

qvk_euid() { printf '%s' "${QVK_TEST_EUID:-$EUID}"; }
qvk_is_root() { [[ $(qvk_euid) == 0 ]]; }

qvk_bash_ok() {
  ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4)))
}

qvk_tun_present() { [[ -c ${QVK_TEST_TUN:-/dev/net/tun} ]]; }

# Print missing required tools, one per line.
qvk_missing_required() {
  local t
  for t in "${QVK_REQUIRED_TOOLS[@]}"; do
    qvk_have "$t" || printf '%s\n' "$t"
  done
}

# Debian/Ubuntu package that provides a required tool.
qvk_tool_package() {
  case $1 in
    ip) printf 'iproute2' ;;
    timeout | mktemp | date) printf 'coreutils' ;;
    awk) printf 'mawk' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Version string of a tool, empty if absent/unknown.
qvk_tool_version() {
  local line=""
  case $1 in
    curl) qvk_have curl && line=$(curl --version 2>/dev/null | head -n1 | awk '{print $2}') ;;
    jq) qvk_have jq && { line=$(jq --version 2>/dev/null); line=${line#jq-}; } ;;
  esac
  printf '%s' "$line"
}
