# shellcheck shell=bash
# English message catalog (default). Keys are stable identifiers; values are
# printf formats. JSON reports always use this catalog.
# shellcheck disable=SC2034

declare -gA QVK_MSG_EN
QVK_MSG_EN=(
  [usage]='Usage: qvk <command> [options]

Read-only evaluation of a fresh VPS before using it as a VPN/proxy server.
Run it as root right after logging in over SSH.

Commands:
  doctor        Show platform support, privileges and available tools (root not required)
  run           Run the checks and produce a report (requires root)
  version       Print the version
  help          Show this help

Options for run:
  --profile quick|full    Check profile (default: quick). In v0.1 "full" adds no load tests
  --format human|json     Output format (default: human, or json when --output is given)
  --output FILE           Write the report to FILE (mode 0600) instead of stdout
  --offline               Do not contact any external internet resource
  --redact-ip             Replace IP addresses in the report with stable labels
  --allow-load            Load tests: not implemented in v0.1
  --max-traffic-mb N      Traffic limit for load tests: not implemented in v0.1

Common options:
  --lang en|ru            Language of human-readable output (JSON is always English)
  -h, --help              Show help

Exit codes: 0 report produced (any verdict), 1 usage error, 2 not root or
unsupported platform, 3 internal error, 130 interrupted.'

  [err.unknown_command]='unknown command: %s (see "qvk --help")'
  [err.unknown_option]='unknown option for "%s": %s'
  [err.missing_value]='option %s requires a value'
  [err.bad_value]='invalid value for %s: %s (expected: %s)'
  [err.load_not_implemented]='load tests are not implemented in v0.1 (--allow-load / --max-traffic-mb); planned for v0.2'
  [err.not_root]='"qvk run" must be run as root (log in with "ssh root@<vps>"); current uid: %s'
  [err.unsupported_platform]='unsupported platform: %s (supported: Debian 12/13, Ubuntu 22.04/24.04 on amd64/arm64)'
  [err.bash_too_old]='bash %s is too old; bash >= 4.4 is required'
  [err.missing_required]='missing required tools: %s (qvk never installs packages; see "qvk doctor")'

  [doctor.title]='qvk doctor: %s %s'
  [doctor.section.platform]='Platform'
  [doctor.section.required]='Required tools'
  [doctor.section.optional]='Optional tools'
  [doctor.section.devices]='Devices'
  [doctor.os]='OS'
  [doctor.arch]='Architecture'
  [doctor.bash]='Bash'
  [doctor.privileges]='Privileges'
  [doctor.supported]='supported'
  [doctor.unsupported]='unsupported'
  [doctor.unknown_os]='unknown (no readable os-release)'
  [doctor.bash_old]='too old, bash >= 4.4 required'
  [doctor.root]='root'
  [doctor.not_root]='not root (uid %s): "qvk run" will refuse; log in as root'
  [doctor.found]='found'
  [doctor.missing]='missing'
  [doctor.tun_present]='present'
  [doctor.tun_absent]='absent (most VPN servers need it)'
  [doctor.install_hint]='qvk never installs packages. To add missing required tools:
  apt-get install -y %s'
  [doctor.ready]='Result: ready for "qvk run"'
  [doctor.not_ready]='Result: not ready'
  [doctor.ready_need_root]='Result: platform is ready; log in as root to run checks'

  [opt.jq]='JSON validation and pretty-printing'
  [opt.iconv]='cleaning invalid UTF-8 in reports'
  [opt.ping]='ICMP RTT'
  [opt.tracepath]='path MTU and route (profile full)'
  [opt.mtr]='route loss statistics'
  [opt.iperf3]='throughput tests (v0.2)'
  [opt.dig]='extended DNS checks'
  [opt.ss]='listening ports'
  [opt.chronyc]='clock synchronization status'
  [opt.timedatectl]='clock synchronization status'
  [opt.systemd-detect-virt]='virtualization type'
  [opt.git]='updating a checkout'

  [report.title]='quality-vps-kit report'
  [report.run_id]='Run ID'
  [report.profile]='Profile'
  [report.started]='Started'
  [report.finished]='Finished'
  [report.os]='OS'
  [report.arch]='Architecture'
  [report.kernel]='Kernel'
  [report.offline]='Offline mode'
  [report.verdicts]='Verdicts'
  [report.area.target_self_check]='Target self-check'
  [report.area.client_reachability]='Client reachability'
  [report.missing]='missing evidence: %s'
  [report.saved]='Report saved to %s'
  [progress.inventory]='collecting system inventory (about 2 s)...'
  [report.section.system]='System'
  [report.section.readiness]='VPN readiness'
  [report.virt]='Virtualization'
  [report.container]='container'
  [report.cpu]='CPU'
  [report.vcpus]='%s vCPU'
  [report.memory]='Memory'
  [report.mem_value]='%s MB total, %s MB available, swap %s MB'
  [report.disk]='Disk /'
  [report.disk_value]='%s MB total, %s MB free'
  [report.load]='Load average'
  [report.steal]='CPU steal'
  [report.steal_value]='%s%% (one %s s sample; not a verdict)'
  [report.iface]='Interface'
  [report.ipv4]='IPv4'
  [report.ipv6]='IPv6'
  [report.no_v6_route]='no IPv6 default route'
  [report.ntp]='NTP synchronized'
  [report.firewall]='Firewall'
  [report.tables]='%s tables'
  [report.rules]='%s rules'
  [report.ip_forward]='IP forwarding'
  [report.wireguard]='WireGuard module'
  [report.none]='none'
  [unknown]='unknown'
  [verdict.suitable]='suitable'
  [verdict.unsuitable]='unsuitable'
  [verdict.indeterminate]='indeterminate'
  [yes]='yes'
  [no]='no'

  [status.pass]='PASS'
  [status.warn]='WARN'
  [status.fail]='FAIL'
  [status.unknown]='UNKNOWN'
  [status.skipped]='SKIPPED'
  [status.error]='ERROR'

  [test.cpu_crypto_accel]='CPU AES acceleration'
  [test.tun_device]='/dev/net/tun'
  [test.tcp_bbr_available]='TCP BBR'
  [test.udp_buffer_size]='UDP buffers'
  [test.listening_ports]='VPN ports'

  [rd.unknown]='cannot be determined'
  [rd.aes_yes]='present'
  [rd.aes_no]='absent: TLS/QUIC is CPU-bound, prefer ChaCha20-Poly1305'
  [rd.tun_yes]='present'
  [rd.tun_no]='absent: userspace VPNs (amneziawg-go, wireguard-go) will not run; Xray and kernel WireGuard do not need it'
  [rd.bbr_yes]='available (current: %s)'
  [rd.bbr_no]='not available in this kernel'
  [rd.udpbuf_ok]='rmem_max %s MB, wmem_max %s MB'
  [rd.udpbuf_low]='rmem_max %s KB, wmem_max %s KB: low for QUIC/Hysteria. Not applied by qvk: sysctl -w net.core.rmem_max=%s net.core.wmem_max=%s'
  [rd.ports_free]='free: %s'
  [rd.ports_busy]='in use: %s'

  [reason.not_implemented]='network checks are not implemented yet in this build; only system and VPN-readiness facts were collected'
  [reason.no_probe]='standalone run cannot test reachability from a client network; a client-side probe is required (v0.2)'
)
