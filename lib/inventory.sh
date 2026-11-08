# shellcheck shell=bash
# Facts are stored in QVK_SYS and consumed by lib/readiness.sh and lib/report.sh.
# shellcheck disable=SC2034

# System inventory. Strictly read-only: reads /proc, /sys, /lib/modules and runs
# listing commands (ip, df, ss, nft list, iptables -S, ufw status, ...).
#
# All values are stored as raw strings in QVK_SYS[<key>]; an empty or missing
# value means "unknown". Types are applied when the JSON is built.
#
# Test hooks (see docs/architecture.md):
#   QVK_TEST_ROOTFS            prefix for every file path read here
#   QVK_TEST_STEAL_SAMPLE_S    steal sampling interval in seconds (default 2)
#   QVK_TEST_HIDE_TOOLS        space-separated tools to treat as not installed

declare -gA QVK_SYS=()

# Ports a VPN kit typically needs: proto:port.
QVK_WATCHED_PORTS=(tcp:80 tcp:443 udp:443 udp:51820)

# Recommended UDP socket buffer for QUIC/Hysteria, bytes.
QVK_UDP_BUF_RECOMMENDED=16777216

# Per-command timeout for local listing commands, seconds.
QVK_LOCAL_CMD_TIMEOUT=5

qvk_fs() { printf '%s%s' "${QVK_TEST_ROOTFS:-}" "$1"; }

# Optional tool present? Honors QVK_TEST_HIDE_TOOLS.
qvk_tool() {
  [[ " ${QVK_TEST_HIDE_TOOLS:-} " == *" $1 "* ]] && return 1
  command -v "$1" >/dev/null 2>&1
}

# qvk_local_cmd <cmd> [args...] — run a local read-only command with a timeout,
# stderr discarded. Exit status is the command's (124 on timeout).
qvk_local_cmd() {
  timeout -k 1 "$QVK_LOCAL_CMD_TIMEOUT" "$@" 2>/dev/null
}

# First line of a file (empty + status 1 when unreadable).
qvk_read_line() {
  local f l=""
  f=$(qvk_fs "$1")
  [[ -r $f ]] || return 1
  IFS= read -r l <"$f" || [[ -n $l ]] || return 1
  printf '%s' "$l"
}

_is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }

# --- pure helpers (unit-tested) ----------------------------------------------

# qvk_steal_pct "<cpu line t0>" "<cpu line t1>" — steal share in percent with
# one decimal; status 1 when the samples are unusable.
qvk_steal_pct() {
  local -a a b
  local i ta=0 tb=0 dt ds tenths
  read -r -a a <<<"$1"
  read -r -a b <<<"$2"
  [[ ${a[0]:-} == cpu && ${b[0]:-} == cpu ]] || return 1
  for i in 1 2 3 4 5 6 7 8; do
    _is_uint "${a[i]:-}" && _is_uint "${b[i]:-}" || return 1
    ta=$((ta + a[i]))
    tb=$((tb + b[i]))
  done
  dt=$((tb - ta))
  ds=$((b[8] - a[8]))
  ((dt > 0 && ds >= 0)) || return 1
  tenths=$(((ds * 1000 + dt / 2) / dt))
  printf '%d.%d' $((tenths / 10)) $((tenths % 10))
}

# qvk_ipv4_class <a.b.c.d> — private|cgnat|loopback|link_local|public|invalid
qvk_ipv4_class() {
  local a b c d o
  IFS=. read -r a b c d <<<"$1"
  for o in "$a" "$b" "$c" "$d"; do
    if ! [[ $o =~ ^(0|[1-9][0-9]{0,2})$ ]] || ((o > 255)); then
      printf 'invalid'
      return
    fi
  done
  if ((a == 10)) || ((a == 172 && b >= 16 && b <= 31)) || ((a == 192 && b == 168)); then
    printf 'private'
  elif ((a == 100 && b >= 64 && b <= 127)); then
    printf 'cgnat'
  elif ((a == 127)); then
    printf 'loopback'
  elif ((a == 169 && b == 254)); then
    printf 'link_local'
  else
    printf 'public'
  fi
}

# qvk_ipv6_class <addr> — ula|global (only called for scope-global addresses)
qvk_ipv6_class() {
  case ${1,,} in
    fc* | fd*) printf 'ula' ;;
    *) printf 'global' ;;
  esac
}

# --- collectors ----------------------------------------------------------------

inv_kernel() {
  QVK_SYS[kernel]=$(qvk_read_line /proc/sys/kernel/osrelease) || QVK_SYS[kernel]=$(uname -r 2>/dev/null)
}

inv_cpu() {
  local f flags model vcpus
  f=$(qvk_fs /proc/cpuinfo)
  [[ -r $f ]] || return 0
  model=$(awk -F': *' '/^model name[ \t]*:/ {print $2; exit}' "$f")
  vcpus=$(grep -c '^processor[[:space:]]*:' "$f")
  if ! _is_uint "$vcpus" || ((vcpus == 0)); then
    vcpus=$(nproc 2>/dev/null)
  fi
  flags=$(awk -F': *' '/^(flags|Features)[ \t]*:/ {print $2; exit}' "$f")
  QVK_SYS[cpu.model]=$model
  QVK_SYS[cpu.vcpus]=$vcpus
  if [[ -n $flags ]]; then
    flags=" $flags "
    if [[ $flags == *" aes "* ]]; then QVK_SYS[cpu.aes]=1; else QVK_SYS[cpu.aes]=0; fi
    if [[ $flags == *" pclmulqdq "* || $flags == *" pmull "* ]]; then
      QVK_SYS[cpu.clmul]=1
    else
      QVK_SYS[cpu.clmul]=0
    fi
    if [[ $flags == *" hypervisor "* ]]; then QVK_SYS[cpu.hypervisor_flag]=1; fi
  fi
}

inv_memory() {
  local f
  f=$(qvk_fs /proc/meminfo)
  [[ -r $f ]] || return 0
  local key val
  while read -r key val _; do
    case $key in
      MemTotal:) QVK_SYS[memory.total_mb]=$((val / 1024)) ;;
      MemAvailable:) QVK_SYS[memory.available_mb]=$((val / 1024)) ;;
      SwapTotal:) QVK_SYS[memory.swap_total_mb]=$((val / 1024)) ;;
    esac
  done < <(grep -E '^(MemTotal|MemAvailable|SwapTotal):[[:space:]]+[0-9]+' "$f")
}

inv_disk() {
  local line total avail
  qvk_tool df || return 0
  line=$(qvk_local_cmd df -Pk / | awk 'NR == 2')
  read -r _ total _ avail _ <<<"$line"
  _is_uint "$total" && QVK_SYS[disk_root.total_mb]=$((total / 1024))
  _is_uint "$avail" && QVK_SYS[disk_root.available_mb]=$((avail / 1024))
  return 0
}

inv_load_uptime() {
  local line l1 l5 l15 up
  if line=$(qvk_read_line /proc/loadavg); then
    read -r l1 l5 l15 _ <<<"$line"
    QVK_SYS[load.load1]=$l1
    QVK_SYS[load.load5]=$l5
    QVK_SYS[load.load15]=$l15
  fi
  if line=$(qvk_read_line /proc/uptime); then
    read -r up _ <<<"$line"
    up=${up%%.*}
    _is_uint "$up" && QVK_SYS[uptime_s]=$up
  fi
  return 0
}

inv_steal() {
  local s0 s1 interval=${QVK_TEST_STEAL_SAMPLE_S:-2} f pct
  f=$(qvk_fs /proc/stat)
  [[ -r $f ]] || return 0
  s0=$(grep -m1 '^cpu ' "$f")
  if ((interval > 0)); then sleep "$interval"; fi
  s1=$(grep -m1 '^cpu ' "$f")
  QVK_SYS[steal.sample_s]=$interval
  if pct=$(qvk_steal_pct "$s0" "$s1"); then
    QVK_SYS[steal.pct]=$pct
  fi
}

inv_virtualization() {
  local v c
  if qvk_tool systemd-detect-virt; then
    c=$(qvk_local_cmd systemd-detect-virt --container)
    v=$(qvk_local_cmd systemd-detect-virt --vm)
    if [[ -n $c && $c != none ]]; then
      QVK_SYS[virt.type]=$c
      QVK_SYS[virt.container]=1
    elif [[ -n $v && $v != none ]]; then
      QVK_SYS[virt.type]=$v
      QVK_SYS[virt.container]=0
    elif [[ $c == none && $v == none ]]; then
      QVK_SYS[virt.type]=none
      QVK_SYS[virt.container]=0
    fi
    [[ -n ${QVK_SYS[virt.type]:-} ]] && QVK_SYS[virt.source]=systemd-detect-virt && return 0
  fi
  if [[ -e $(qvk_fs /proc/user_beancounters) ]]; then
    QVK_SYS[virt.type]=openvz QVK_SYS[virt.container]=1 QVK_SYS[virt.source]=/proc/user_beancounters
  elif v=$(qvk_read_line /run/systemd/container) && [[ -n $v ]]; then
    QVK_SYS[virt.type]=$v QVK_SYS[virt.container]=1 QVK_SYS[virt.source]=/run/systemd/container
  elif [[ -e $(qvk_fs /.dockerenv) ]]; then
    QVK_SYS[virt.type]=docker QVK_SYS[virt.container]=1 QVK_SYS[virt.source]=/.dockerenv
  elif [[ ${QVK_SYS[cpu.hypervisor_flag]:-} == 1 ]]; then
    # A VM of unknown type; container status cannot be ruled out this way.
    QVK_SYS[virt.type]=vm QVK_SYS[virt.source]=cpuinfo_hypervisor_flag
  fi
  return 0
}

inv_network() {
  local dev mtu a addr prefix v4=() v6=()
  qvk_tool ip || return 0
  dev=$(qvk_local_cmd ip -o route show default \
    | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  [[ $dev =~ ^[A-Za-z0-9_.:@-]{1,32}$ ]] || dev=""
  QVK_SYS[net.default_iface]=$dev
  if [[ -n $dev ]]; then
    mtu=$(qvk_local_cmd ip -o link show dev "$dev" \
      | awk '{for (i = 1; i < NF; i++) if ($i == "mtu") {print $(i + 1); exit}}')
    _is_uint "$mtu" && QVK_SYS[net.interface_mtu]=$mtu
    while read -r a; do
      [[ -n $a ]] || continue
      addr=${a%/*} prefix=${a#*/}
      [[ $prefix == "$a" ]] && prefix=""
      [[ $(qvk_ipv4_class "$addr") != invalid ]] || continue
      v4+=("$addr $prefix $(qvk_ipv4_class "$addr")")
      qvk_register_ip "$addr"
    done < <(qvk_local_cmd ip -o -4 addr show dev "$dev" \
      | awk '{for (i = 1; i < NF; i++) if ($i == "inet") print $(i + 1)}')
    while read -r a; do
      [[ -n $a ]] || continue
      addr=${a%/*} prefix=${a#*/}
      [[ $prefix == "$a" ]] && prefix=""
      [[ $addr =~ ^[0-9A-Fa-f:]+$ ]] || continue
      v6+=("$addr $prefix $(qvk_ipv6_class "$addr")")
      qvk_register_ip "$addr"
    done < <(qvk_local_cmd ip -o -6 addr show dev "$dev" scope global \
      | awk '{for (i = 1; i < NF; i++) if ($i == "inet6") print $(i + 1)}')
  fi
  QVK_SYS[net.ipv4_addresses]=$(printf '%s\n' "${v4[@]}")
  QVK_SYS[net.ipv6_addresses]=$(printf '%s\n' "${v6[@]}")
  if [[ -n $(qvk_local_cmd ip -o -6 route show default) ]]; then
    QVK_SYS[net.ipv6_default_route]=1
  else
    QVK_SYS[net.ipv6_default_route]=0
  fi
}

inv_time() {
  local v
  qvk_tool timedatectl || return 0
  v=$(qvk_local_cmd timedatectl show -p NTPSynchronized --value)
  case $v in
    yes) QVK_SYS[time.ntp_synchronized]=1 ;;
    no) QVK_SYS[time.ntp_synchronized]=0 ;;
  esac
  return 0
}

_module_file_exists() {
  local base=$1 rel=$2 ext
  for ext in "" .xz .zst .gz; do
    [[ -e $base/$rel.ko$ext ]] && return 0
  done
  return 1
}

inv_kernel_net() {
  local v k moddir avail
  QVK_SYS[kernel_net.tcp_congestion_control]=$(qvk_read_line /proc/sys/net/ipv4/tcp_congestion_control)
  avail=$(qvk_read_line /proc/sys/net/ipv4/tcp_available_congestion_control)
  QVK_SYS[kernel_net.tcp_available_congestion_control]=$avail
  QVK_SYS[kernel_net.default_qdisc]=$(qvk_read_line /proc/sys/net/core/default_qdisc)
  v=$(qvk_read_line /proc/sys/net/core/rmem_max) && QVK_SYS[kernel_net.rmem_max_bytes]=$v
  v=$(qvk_read_line /proc/sys/net/core/wmem_max) && QVK_SYS[kernel_net.wmem_max_bytes]=$v
  v=$(qvk_read_line /proc/sys/net/ipv4/ip_forward) && QVK_SYS[kernel_net.ip_forward]=$v

  # BBR: listed (loaded), built in, or loadable module file present.
  k=${QVK_SYS[kernel]:-}
  moddir=$(qvk_fs "/lib/modules/$k")
  if [[ " $avail " == *" bbr "* ]]; then
    QVK_SYS[kernel_net.bbr]=available
  elif [[ -n $k && -d $moddir ]]; then
    if grep -qs 'tcp_bbr\.ko' "$moddir/modules.builtin" \
      || _module_file_exists "$moddir" kernel/net/ipv4/tcp_bbr; then
      QVK_SYS[kernel_net.bbr]=available
    else
      QVK_SYS[kernel_net.bbr]=absent
    fi
  fi
  return 0
}

inv_modules() {
  local k moddir mods
  mods=$(qvk_fs /proc/modules)
  k=${QVK_SYS[kernel]:-}
  moddir=$(qvk_fs "/lib/modules/$k")
  if grep -qs '^wireguard ' "$mods"; then
    QVK_SYS[modules.wireguard]=loaded
  elif [[ -n $k && -d $moddir ]]; then
    if grep -qs '/wireguard\.ko' "$moddir/modules.builtin" \
      || _module_file_exists "$moddir" kernel/drivers/net/wireguard/wireguard; then
      QVK_SYS[modules.wireguard]=available
    else
      QVK_SYS[modules.wireguard]=absent
    fi
  fi
  if [[ -r $mods ]]; then
    if grep -qs '^amneziawg ' "$mods"; then
      QVK_SYS[modules.amneziawg_loaded]=1
    else
      QVK_SYS[modules.amneziawg_loaded]=0
    fi
  fi
  return 0
}

inv_firewall() {
  local out v
  if qvk_tool nft && out=$(qvk_local_cmd nft list ruleset); then
    QVK_SYS[firewall.nftables_tables]=$(grep -c '^table ' <<<"$out")
  fi
  if qvk_tool iptables; then
    v=$(qvk_local_cmd iptables -V)
    case $v in
      *nf_tables*) QVK_SYS[firewall.iptables_backend]=nf_tables ;;
      *legacy*) QVK_SYS[firewall.iptables_backend]=legacy ;;
    esac
    if out=$(qvk_local_cmd iptables -S); then
      QVK_SYS[firewall.iptables_rules]=$(grep -c '^-A ' <<<"$out")
    fi
  fi
  if qvk_tool ufw; then
    out=$(qvk_local_cmd ufw status)
    case $out in
      "Status: active"*) QVK_SYS[firewall.ufw_active]=1 ;;
      "Status: inactive"*) QVK_SYS[firewall.ufw_active]=0 ;;
    esac
  fi
  if qvk_tool firewall-cmd; then
    out=$(qvk_local_cmd firewall-cmd --state)
    case $out in
      running) QVK_SYS[firewall.firewalld_active]=1 ;;
      "not running") QVK_SYS[firewall.firewalld_active]=0 ;;
    esac
  fi
  return 0
}

# Listening sockets as "proto port process" lines (process may be empty).
inv_listening() {
  local out f hex proto
  if qvk_tool ss && out=$(qvk_local_cmd ss -H -ltnup); then
    QVK_SYS[ports.source]=ss
    QVK_SYS[ports.listening]=$(awk '
      $1 == "tcp" || $1 == "udp" {
        n = split($5, p, ":"); proc = ""
        if (match($0, /users:\(\("[^"]+"/)) proc = substr($0, RSTART + 9, RLENGTH - 10)
        print $1, p[n], proc
      }' <<<"$out" | sort -u)
    return 0
  fi
  # Fallback without ss: TCP state 0A = LISTEN, UDP state 07 = bound/unconnected.
  # Process names are not available this way.
  local state
  out=""
  for proto in tcp udp; do
    if [[ $proto == tcp ]]; then state=0A; else state=07; fi
    for f in "$proto" "${proto}6"; do
      f=$(qvk_fs "/proc/net/$f")
      [[ -r $f ]] || continue
      QVK_SYS[ports.source]=proc
      while read -r hex; do
        [[ $hex =~ ^[0-9A-Fa-f]{4}$ ]] && out+="$proto $((16#$hex))"$'\n'
      done < <(awk -v st="$state" 'NR > 1 && $4 == st {n = split($2, a, ":"); print a[n]}' "$f")
    done
  done
  QVK_SYS[ports.listening]=$(printf '%s' "$out" | sort -u)
  return 0
}

qvk_inventory_collect() {
  inv_kernel
  inv_cpu
  inv_memory
  inv_disk
  inv_load_uptime
  inv_steal
  inv_virtualization
  inv_network
  inv_time
  inv_kernel_net
  inv_modules
  inv_firewall
  inv_listening
}
