# shellcheck shell=bash
# Host fixtures: run qvk against tests/fixtures/hosts/<name> instead of the real
# machine. Requires assert.sh to be sourced first and WORK to be set.

# Commands qvk may call while collecting inventory. Each gets the generic stub,
# so real tools on the developer's machine are never executed.
HOSTFIX_COMMANDS=(ip df ss systemd-detect-virt timedatectl nft iptables ufw firewall-cmd curl nproc tracepath ping dig speedtest)

# Read-only command lines qvk is allowed to run (extended regexes over "cmd args").
HOSTFIX_ALLOWED=(
  '^curl --version$'
  '^ip -o (-[46] )?route show default$'
  '^ip -o link show dev [A-Za-z0-9_.:@-]+$'
  '^ip -o -4 addr show dev [A-Za-z0-9_.:@-]+$'
  '^ip -o -6 addr show dev [A-Za-z0-9_.:@-]+ scope global$'
  '^df -Pk /$'
  '^ss -H -ltnup$'
  '^systemd-detect-virt --(container|vm)$'
  '^timedatectl show -p NTPSynchronized --value$'
  '^nft list ruleset$'
  '^iptables -(V|S)$'
  '^ufw status$'
  '^firewall-cmd --state$'
  '^nproc$'
  '^tracepath -n -m 12 [A-Za-z0-9.-]+$'
  '^ping -n -c [0-9]+ -W 2 [A-Za-z0-9.-]+$'
  '^dig \+short \+time=3 \+tries=1 (@[0-9.]+ )?[A-Za-z0-9.-]+ A$'
)

# use_host_fixture <name> — exports the environment for qvk.
use_host_fixture() {
  local name=$1 dir="$REPO_ROOT/tests/fixtures/hosts/$1" t
  [[ -d $dir ]] || {
    echo "no host fixture: $name" >&2
    return 1
  }
  rm -rf -- "$WORK/hostbin"
  mkdir -p "$WORK/hostbin"
  for t in "${HOSTFIX_COMMANDS[@]}"; do
    cp "$REPO_ROOT/tests/fixtures/stub-cmd.sh" "$WORK/hostbin/$t"
    chmod +x "$WORK/hostbin/$t"
  done
  # A fake Ookla CLI keeps ordinary qvk runs deterministic and offline.
  cat >"$WORK/hostbin/speedtest" <<'SPEEDTEST_STUB'
#!/bin/sh
if [ "${1:-}" = --version ]; then
  echo 'Speedtest by Ookla 1.2.0'
  exit 0
fi
cat <<'JSON'
{"ping":{"latency":12.5},"download":{"bandwidth":1000000,"bytes":1000000},"upload":{"bandwidth":500000,"bytes":500000}}
JSON
SPEEDTEST_STUB
  chmod +x "$WORK/hostbin/speedtest"
  # Keep the original PATH for real coreutils/awk/sed/grep, stubs first.
  export PATH="$WORK/hostbin:${HOSTFIX_ORIG_PATH:=$PATH}"
  export QVK_STUB_DIR="$dir/cmd"
  export QVK_STUB_LOG="$WORK/stub.log"
  : >"$QVK_STUB_LOG"
  export QVK_TEST_ROOTFS="$dir/rootfs"
  export QVK_TEST_EUID=0
  export QVK_TEST_STEAL_SAMPLE_S=0

  # env: KEY=value lines (OS, ARCH, TUN=present|absent, HIDE="tool ...").
  local k v
  export QVK_TEST_HIDE_TOOLS=""
  while IFS='=' read -r k v; do
    v=${v#\"} v=${v%\"}
    case $k in
      OS) export QVK_TEST_OS_RELEASE="$REPO_ROOT/tests/fixtures/os-release/$v" ;;
      ARCH) export QVK_TEST_ARCH=$v ;;
      HIDE) export QVK_TEST_HIDE_TOOLS=$v ;;
      TUN)
        if [[ $v == present ]]; then
          export QVK_TEST_TUN=/dev/null # any character device
        else
          export QVK_TEST_TUN="$WORK/no-tun"
        fi
        ;;
    esac
  done <"$dir/env"
}

# Print logged stub calls that are not on the read-only allowlist.
stub_calls_not_allowed() {
  local line re ok
  while IFS= read -r line; do
    ok=0
    for re in "${HOSTFIX_ALLOWED[@]}"; do
      [[ $line =~ $re ]] && ok=1 && break
    done
    ((ok)) || printf '%s\n' "$line"
  done <"$QVK_STUB_LOG"
}
