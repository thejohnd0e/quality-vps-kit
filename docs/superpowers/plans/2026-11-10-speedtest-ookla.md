# Ookla Speedtest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox syntax.

**Goal:** Replace the iperf server matrix with one Ookla Speedtest and automatic official CLI installation.

**Architecture:** An opt-in Bash module configures the official signed Ookla APT source and installs the package if necessary, then runs one bounded JSON-mode CLI invocation and records one report row.

**Tech Stack:** Bash, curl, gpg, apt-get, timeout, official Ookla CLI.

**Spec:** `docs/superpowers/specs/2026-11-10-speedtest-ookla-design.md`

## Global Constraints

- Installation and bandwidth use occur on every normal run; `--offline` skips both.
- Offline mode does not install or invoke the CLI.
- No remote setup script is executed; package signatures are checked by APT.
- `--max-traffic-mb` is not accepted because the CLI cannot cap traffic.

## Review Focus

- Existing CLI: run exactly once and convert `bandwidth` bytes/s to Mbps.
- Missing CLI: official signing key/source and package are installed; failure is reported without aborting report creation.
- Offline: no installation or test.
- Invalid output, timeout, command failure: safe concise error, no raw diagnostic leakage.
- Default run: invokes Ookla once and installs it first if missing.

### Task 1: Ookla runner and tests

**Files:** `lib/speedtest.sh`, `tests/unit/test_speedtest.sh`

- [x] Test metrics parsing, one test invocation, signed-repository install path, offline behavior, and malformed CLI output.
- [x] Implement bounded installer and runner; use mocked package/download utilities in tests.

### Task 2: CLI, report, and documentation integration

**Files:** `qvk`, `lib/report.sh`, `lib/platform.sh`, `lib/i18n/en.sh`, `lib/i18n/ru.sh`, `schema/report.schema.json`, both READMEs, `docs/architecture.md`, `docs/roadmap.md`, `CHANGELOG.md`.

- [x] Run Ookla on every ordinary invocation; record that the test is enabled in `run.load_test_enabled`.
- [x] Add human/JSON section and English/Russian text; keep traffic cap unsupported.
- [x] Remove iperf runtime, configuration, and tests.
- [x] Run full offline suite and Bash syntax; ShellCheck unavailable. Release check was attempted but cannot access this Windows-created worktree's `.git` pointer from WSL Bash (`not inside a git work tree`).

## Review outcome

- Fixed: reject conflicting APT source files before key download/configuration and refuse mismatched pre-existing dedicated keyrings.
- Fixed: extract only top-level Ookla result objects and reject unbalanced/mismatched JSON delimiters.
- Fixed: record measured transfer bytes instead of reporting zero.
- Full suite: `bash tests/run.sh` → `RESULT: OK`.
- Static: Bash syntax checks pass; ShellCheck was not installed.
