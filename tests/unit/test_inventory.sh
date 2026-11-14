#!/usr/bin/env bash
# Inventory, VPN-readiness and --redact-ip tests on host fixtures (no network,
# no real system tools executed).
set -uo pipefail
# shellcheck source=tests/lib/assert.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"
# shellcheck source=tests/lib/hostfix.sh
source "$REPO_ROOT/tests/lib/hostfix.sh"

PY=$(find_python) || {
  echo "python 3 is required" >&2
  exit 1
}
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
unset NO_COLOR LANG LC_ALL LC_MESSAGES

# --- pure helpers ---------------------------------------------------------------
(
  export LC_ALL=C
  # shellcheck source=lib/common.sh
  source "$REPO_ROOT/lib/common.sh"
  # shellcheck source=lib/redact.sh
  source "$REPO_ROOT/lib/redact.sh"
  # shellcheck source=lib/inventory.sh
  source "$REPO_ROOT/lib/inventory.sh"

  echo "# steal"
  assert_eq 0.0 "$(qvk_steal_pct 'cpu 100 0 100 800 0 0 0 0 0 0' 'cpu 200 0 200 1600 0 0 0 0 0 0')" "no steal"
  assert_eq 10.0 "$(qvk_steal_pct 'cpu 0 0 0 0 0 0 0 0 0 0' 'cpu 30 0 30 30 0 0 0 10 0 0')" "10% steal"
  assert_eq 33.3 "$(qvk_steal_pct 'cpu 0 0 0 0 0 0 0 0' 'cpu 1 0 0 1 0 0 0 1')" "rounding to one decimal"
  qvk_steal_pct 'cpu 5 0 0 0 0 0 0 0' 'cpu 5 0 0 0 0 0 0 0' >/dev/null
  assert_eq 1 "$?" "identical samples are unusable"
  qvk_steal_pct 'cpu 1 x 0 0 0 0 0 0' 'cpu 2 0 0 0 0 0 0 0' >/dev/null
  assert_eq 1 "$?" "non-numeric fields are rejected"
  qvk_steal_pct 'intr 1 2' 'cpu 2 0 0 0 0 0 0 0' >/dev/null
  assert_eq 1 "$?" "non-cpu line is rejected"

  echo "# ipv4 class"
  for c in 10.1.2.3:private 172.16.0.1:private 172.31.255.255:private 172.32.0.1:public \
    192.168.1.1:private 100.64.0.1:cgnat 100.127.255.255:cgnat 100.128.0.1:public \
    127.0.0.1:loopback 169.254.1.1:link_local 203.0.113.10:public 8.8.8.8:public \
    256.1.1.1:invalid 1.2.3:invalid 01.2.3.4:invalid a.b.c.d:invalid; do
    assert_eq "${c#*:}" "$(qvk_ipv4_class "${c%%:*}")" "ipv4 ${c%%:*}"
  done
  assert_eq ula "$(qvk_ipv6_class fd12:3456::1)" "ipv6 ULA"
  assert_eq global "$(qvk_ipv6_class 2001:db8::1)" "ipv6 global"

  echo "# redaction"
  QVK_REDACT=1
  qvk_register_ip 1.2.3.4
  qvk_register_ip 2001:db8::1
  qvk_register_ip 1.2.3.4
  qvk_register_ip 127.0.0.1
  assert_eq 2 "${#QVK_SENSITIVE_IPS[@]}" "duplicates and loopback are not registered"
  assert_eq '"<ip-1>" x <ip-1>/24' "$(qvk_redact '"1.2.3.4" x 1.2.3.4/24')" "every occurrence replaced"
  assert_eq '11.2.3.4 1.2.3.45 1.2.3.4.5' "$(qvk_redact '11.2.3.4 1.2.3.45 1.2.3.4.5')" \
    "address boundaries respected"
  assert_eq '<ip-2> 2001:db8::10' "$(qvk_redact '2001:db8::1 2001:db8::10')" "ipv6 boundary respected"
  assert_eq $'line\n<ip-1>\nx' "$(qvk_redact $'line\n1.2.3.4\n'; printf x)" "trailing newlines preserved"
  QVK_REDACT=0
  assert_eq '1.2.3.4' "$(qvk_redact '1.2.3.4')" "no redaction unless enabled"
  finish_tests
) || TESTS_FAILED=$((TESTS_FAILED + 1))

json_field() {
  "$PY" -I -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
for k in sys.argv[2].split("."):
    d=d[int(k)] if isinstance(d,list) else d[k]
print(json.dumps(d, ensure_ascii=False))' "$1" "$2"
}
test_field() {
  "$PY" -I -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
t=[x for x in d["tests"] if x["id"]==sys.argv[2]]
v=t[0] if t else None
for k in sys.argv[3].split(".") if v is not None else []:
    v=v.get(k) if isinstance(v,dict) else None
print(json.dumps(v, ensure_ascii=False))' "$1" "$2" "$3"
}
validate() { "$PY" -I "$REPO_ROOT/tests/tools/validate_report.py" "$1" >/dev/null; }

run_fixture_json() {
  "$REPO_ROOT/qvk" run --offline --format json "$@" >"$WORK/r.json" 2>"$WORK/err"
}

echo "# debian12-kvm-amd64 (full toolset, VM)"
use_host_fixture debian12-kvm-amd64
run_fixture_json
assert_eq 0 "$?" "run exits 0"
R="$WORK/r.json"
assert_true "report matches schema" validate "$R"
assert_eq '"6.1.0-27-amd64"' "$(json_field "$R" system.kernel)" "kernel from /proc"
assert_eq '"kvm"' "$(json_field "$R" system.virtualization.type)" "virtualization via systemd-detect-virt"
assert_eq 'false' "$(json_field "$R" system.virtualization.container)" "not a container"
assert_eq '"AMD EPYC 7543 32-Core Processor"' "$(json_field "$R" system.cpu.model)" "cpu model"
assert_eq '2' "$(json_field "$R" system.cpu.vcpus)" "vcpus"
assert_eq 'true' "$(json_field "$R" system.cpu.aes)" "aes flag"
assert_eq '1967' "$(json_field "$R" system.memory.total_mb)" "memory total MB"
assert_eq '1612' "$(json_field "$R" system.memory.available_mb)" "memory available MB"
assert_eq '19991' "$(json_field "$R" system.disk_root.total_mb)" "disk total MB"
assert_eq '0.08' "$(json_field "$R" system.load.load1)" "load1"
assert_eq '3712' "$(json_field "$R" system.uptime_s)" "uptime seconds"
assert_eq 'null' "$(json_field "$R" system.steal.pct)" "steal is null without a usable sample"
assert_eq '"eth0"' "$(json_field "$R" system.network.default_iface)" "default interface"
assert_eq '1500' "$(json_field "$R" system.network.interface_mtu)" "interface MTU"
assert_eq '"203.0.113.10"' "$(json_field "$R" system.network.ipv4_addresses.0.address)" "ipv4 address"
assert_eq '24' "$(json_field "$R" system.network.ipv4_addresses.0.prefix_len)" "ipv4 prefix"
assert_eq '"public"' "$(json_field "$R" system.network.ipv4_addresses.0.class)" "ipv4 class"
assert_eq '"2001:db8:10::5"' "$(json_field "$R" system.network.ipv6_addresses.0.address)" "ipv6 address"
assert_eq 'true' "$(json_field "$R" system.network.ipv6_default_route)" "ipv6 default route"
assert_eq 'true' "$(json_field "$R" system.time.ntp_synchronized)" "ntp synchronized"
assert_eq '"available"' "$(json_field "$R" system.kernel_net.bbr)" "bbr loadable module detected"
assert_eq 'false' "$(json_field "$R" system.kernel_net.ip_forward)" "ip_forward"
assert_eq '"available"' "$(json_field "$R" system.modules.wireguard)" "wireguard module available"
assert_eq '0' "$(json_field "$R" system.firewall.nftables_tables)" "nftables tables"
assert_eq '"nf_tables"' "$(json_field "$R" system.firewall.iptables_backend)" "iptables backend"
assert_eq '0' "$(json_field "$R" system.firewall.iptables_rules)" "policies are not counted as rules"
assert_eq 'null' "$(json_field "$R" system.firewall.ufw_active)" "ufw absent -> null"
assert_eq '"pass"' "$(test_field "$R" cpu_crypto_accel status)" "readiness: AES pass"
assert_eq '"pass"' "$(test_field "$R" tun_device status)" "readiness: tun pass"
assert_eq '"pass"' "$(test_field "$R" tcp_bbr_available status)" "readiness: bbr pass"
assert_eq '"warn"' "$(test_field "$R" udp_buffer_size status)" "readiness: small UDP buffers warn"
assert_eq '212992' "$(test_field "$R" udp_buffer_size metrics.rmem_max_bytes)" "udp buffer metric"
assert_eq '"warn"' "$(test_field "$R" listening_ports status)" "readiness: busy ports warn"
assert_contains "$(test_field "$R" listening_ports reason)" "443/tcp (xray)" "busy port names its process"
assert_contains "$(test_field "$R" listening_ports reason)" "51820/udp" "busy udp port listed"
assert_not_contains "$(test_field "$R" listening_ports reason)" "443/udp" "free port not listed"
assert_eq "" "$(stub_calls_not_allowed)" "only allow-listed read-only commands were run"

echo "# --redact-ip"
run_fixture_json --redact-ip
assert_true "redacted report matches schema" validate "$R"
body=$(cat "$R")
assert_not_contains "$body" "203.0.113.10" "ipv4 removed from JSON"
assert_not_contains "$body" "2001:db8:10::5" "ipv6 removed from JSON"
assert_eq '"<ip-1>"' "$(json_field "$R" system.network.ipv4_addresses.0.address)" "ipv4 label"
assert_eq '"<ip-2>"' "$(json_field "$R" system.network.ipv6_addresses.0.address)" "ipv6 label"
assert_eq 'true' "$(json_field "$R" run.redacted)" "run.redacted true"
human=$("$REPO_ROOT/qvk" run --offline --redact-ip 2>/dev/null)
assert_not_contains "$human" "203.0.113.10" "ipv4 removed from human output"
assert_contains "$human" "<ip-1>/24 (public)" "human output shows label"
human=$("$REPO_ROOT/qvk" run --offline 2>/dev/null)
assert_contains "$human" "203.0.113.10/24 (public)" "without --redact-ip the address is shown"
assert_contains "$human" "VPN readiness" "human readiness section"
assert_contains "$human" "in use: 443/tcp (xray), 51820/udp" "human busy ports"

echo "# ubuntu24-lxc-arm64 (minimal container)"
use_host_fixture ubuntu24-lxc-arm64
run_fixture_json
assert_eq 0 "$?" "run exits 0"
assert_true "report matches schema" validate "$R"
assert_eq '"lxc"' "$(json_field "$R" system.virtualization.type)" "lxc via /run/systemd/container"
assert_eq 'true' "$(json_field "$R" system.virtualization.container)" "container"
assert_eq 'null' "$(json_field "$R" system.cpu.model)" "arm64 without model name -> null"
assert_eq 'false' "$(json_field "$R" system.cpu.aes)" "arm64 Features without aes"
assert_eq '"arm64"' "$(json_field "$R" system.arch)" "arch arm64"
assert_eq '1420' "$(json_field "$R" system.network.interface_mtu)" "veth MTU"
assert_eq '"private"' "$(json_field "$R" system.network.ipv4_addresses.0.class)" "private address"
assert_eq '[]' "$(json_field "$R" system.network.ipv6_addresses)" "no ipv6"
assert_eq 'false' "$(json_field "$R" system.network.ipv6_default_route)" "no ipv6 route"
assert_eq 'null' "$(json_field "$R" system.time.ntp_synchronized)" "no timedatectl -> null"
assert_eq 'null' "$(json_field "$R" system.kernel_net.bbr)" "no /lib/modules -> bbr unknown"
assert_eq 'null' "$(json_field "$R" system.kernel_net.rmem_max_bytes)" "no net.core sysctl -> null"
assert_eq 'true' "$(json_field "$R" system.kernel_net.ip_forward)" "ip_forward on"
assert_eq 'null' "$(json_field "$R" system.modules.wireguard)" "wireguard unknown"
assert_eq 'null' "$(json_field "$R" system.firewall.iptables_backend)" "no iptables -> null"
assert_eq '"warn"' "$(test_field "$R" cpu_crypto_accel status)" "readiness: no AES warn"
assert_eq '"warn"' "$(test_field "$R" tun_device status)" "readiness: no tun warn"
assert_eq '"unknown"' "$(test_field "$R" tcp_bbr_available status)" "readiness: bbr unknown"
assert_eq '"unknown"' "$(test_field "$R" udp_buffer_size status)" "readiness: udp buffers unknown"
assert_eq '"warn"' "$(test_field "$R" listening_ports status)" "readiness: ports from /proc/net"
assert_eq '"proc"' "$(test_field "$R" listening_ports details.source)" "ports source is /proc/net"
assert_contains "$(test_field "$R" listening_ports reason)" "80/tcp" "listening 80/tcp found"
assert_contains "$(test_field "$R" listening_ports reason)" "443/udp" "bound 443/udp found"
assert_not_contains "$(test_field "$R" listening_ports reason)" "443/tcp" "established 443 is not a listener"
assert_eq "" "$(stub_calls_not_allowed)" "only allow-listed read-only commands were run"
human=$("$REPO_ROOT/qvk" run --offline 2>/dev/null)
assert_contains "$human" "lxc (container)" "container label"

finish_tests
