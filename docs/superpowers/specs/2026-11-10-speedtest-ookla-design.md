# Design — Speedtest by Ookla

Date: 2026-11-10. Status: approved. The user approved replacing the unreliable public iperf3 matrix with official Speedtest.net testing and explicitly authorized automatic Ookla CLI installation.

## Intent and behavior

- Every normal `qvk run` performs one Speedtest by Ookla measurement.
- If `speedtest` is missing, configure the official signed Ookla APT source and install its CLI package without prompting. Do not fetch and execute an installer script.
- `--offline` skips installation and measurement.
- Record one JSON/human result, or a concise install/test error. Never expose raw CLI output.

## Approaches

1. Official Ookla CLI via signed APT source (chosen): authentic Speedtest.net service and structured results; package/source are persistent changes on normal runs, avoided by `--offline`.
2. Public iperf3 servers (rejected): shared endpoints produced inconsistent failures.
3. Curl download probe (rejected): not Speedtest.net and lacks comparable upload measurement.

## Constraints and non-goals

- No traffic-cap promise: `--max-traffic-mb` remains unsupported because Ookla cannot enforce a byte limit.
- Support only project platforms Debian 12/13 and Ubuntu 22.04/24.04.
- Bound repository/key downloads, APT operations, and the Speedtest invocation.
- Tests use mocked CLI/package tools only; no real bandwidth tests in CI.
