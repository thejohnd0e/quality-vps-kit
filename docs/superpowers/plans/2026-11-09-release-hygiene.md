# Release hygiene Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing versioning and release flow of `qvk` safe and repeatable: one command verifies that `VERSION`, the git tag and `install.sh` agree, a tag push builds and publishes the release assets, and the procedure is written down.

**Architecture:** `scripts/release.sh` gains a validation pass (`--check`) shared by local runs and CI. A new `.github/workflows/release.yml` runs the offline suite, the checks, the existing tarball build, and `gh release create` on `v*` tags. `CHANGELOG.md` and `docs/release.md` record the changes and the procedure.

**Tech Stack:** Bash, `git`, `sha256sum`, GitHub Actions with the preinstalled `gh` CLI (no third-party actions beyond `actions/checkout`).

**Spec:** `docs/superpowers/specs/2026-11-09-claude-ip-risk-design.md` (context) and this plan's own "Procedure" section.

## Global Constraints

- Existing release artifacts stay the same: `quality-vps-kit-<version>.tar.gz` from `git archive` + `SHA256SUMS`, published as GitHub release assets under tag `v<version>`.
- `install.sh` keeps its pinned default (`QVK_VERSION:-<version>`); it must never point at a version whose assets do not exist.
- Version and tag must be identical; a published tag is never moved or deleted — a mistake gets a new patch release.
- No new runtime dependency for `qvk` itself; the release workflow may use only `actions/checkout` and the preinstalled `gh`.
- CI stays network-free except for the release publishing step itself.
- `bash -n` and `shellcheck -x -S style` must stay clean; `bash tests/run.sh` must pass.
- Do not force-push, do not rewrite published tags.

## Review Focus

- `VERSION`, the git tag and the `install.sh` default drifting apart — the failure that silently ships the previous tarball. `--check` must fail. Pinned in Task 1 tests.
- The tag pointing at an older commit than `HEAD` (or `VERSION` bumped on top of the tag). `--check` must fail. Pinned in Task 1 tests.
- A dirty working tree at release time. `release.sh` must refuse. Pinned in Task 1 tests.
- Publishing before the tests run, so a broken tree becomes a public release. The workflow order is asserted in Task 3.
- A release published without one of the two assets, which makes `install.sh` fail for users. Task 3 ends with an asset check and Task 4 documents the manual verification.

---

### Task 1: `scripts/release.sh --check`

**Files:**
- Modify: `scripts/release.sh` (whole file, 27 lines today)
- Create: `tests/unit/test_release.sh`

**Interfaces:**
- Produces: `scripts/release.sh [--check] [output-dir]`. With `--check` it validates and exits without building; without it, validation runs first and then the tarball is built as today. Validation failures print `release.sh: <problem>` to stderr and exit 2. Success prints `release.sh: checks passed: v<version>`.
- Checks, in this order: inside a git work tree; clean tracked tree (`git status --porcelain --untracked-files=no` empty); `VERSION` is tracked and matches `^[0-9]+\.[0-9]+\.[0-9]+$`; tag `v<version>` exists (`git rev-parse -q --verify "refs/tags/v$version"`); that tag resolves to `HEAD`; `install.sh` contains `QVK_VERSION:-<version>`.

- [ ] **Step 1: Write the failing test.** `tests/unit/test_release.sh` sources `tests/lib/assert.sh`, skips with `echo "skipped: git not installed"; exit 0` when `command -v git` fails, and for each case builds a throwaway repo in `$(mktemp -d)` containing copies of `scripts/release.sh`, `install.sh` and `VERSION`, then `git init -q`, `git add .`, `git -c user.email=t@t -c user.name=t commit -qm t`, `git tag v<version>`. Cases:

```bash
# consistent repo -> 0
run_check; assert_eq 0 "$?" "consistent repo passes"
# tag missing
git tag -d "v$version"; run_check; assert_eq 2 "$?" "missing tag rejected"
# VERSION bumped after tagging
printf '0.1.2\n' >VERSION; git -c ... commit -qam bump; run_check; assert_eq 2 "$?" "VERSION ahead of tag rejected"
# install.sh default does not match
sed -i 's/QVK_VERSION:-[0-9.]*/QVK_VERSION:-9.9.9/' install.sh; run_check; assert_eq 2 "$?" "install.sh drift rejected"
# dirty tree
echo x >>install.sh; run_check; assert_eq 2 "$?" "dirty tree rejected"
# --check builds nothing
assert_true "no dist dir" test ! -e "$T/dist"
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/unit/test_release.sh`
Expected: FAIL on the first assertion (the current script always builds and exits 0).

- [ ] **Step 3: Implement.** Add an argument loop: `--check` sets `check_only=1`, otherwise the first non-flag argument is the output dir. Put the existing tarball code after the validation. Validation is a function `_release_check` returning non-zero on the first failed check with its message; keep `set -euo pipefail`.

- [ ] **Step 4: Run the test**

Run: `bash tests/unit/test_release.sh`
Expected: `RESULT: OK`.

- [ ] **Step 5: Commit**

```bash
git add scripts/release.sh tests/unit/test_release.sh
git commit -m "release: verify version, tag and install.sh agree"
```

---

### Task 2: `CHANGELOG.md`

**Files:**
- Create: `CHANGELOG.md`

**Interfaces:**
- Produces: Keep a Changelog layout (`# Changelog`, an `## [Unreleased]` section, then `## [0.1.1] - <date>` and `## [0.1.0] - 2026-11-08`), with `### Added` / `### Changed` subsections. Task 5 fills the `0.1.1` date.

- [ ] **Step 1: Write the file.** `Unreleased` gets nothing (it is emptied at release time). `0.1.1` gets one `### Added` bullet: the `netcoffee` IP-intelligence source and `ip_intelligence.claude_risk` (level, reasons, restricted-region check), noting it is informational and does not change the verdicts. `0.1.0` gets the first-release summary: `doctor`, `run --profile quick|full`, read-only VPN readiness, egress/NAT/geo consensus, HTTP reachability, `--redact-ip`, `--lang en|ru`, `install.sh` runner. Add the two-line header explaining that versions follow SemVer for the tool and that `schema_version` follows `docs/architecture.md` D5.

- [ ] **Step 2: Verify**

Run: `grep -q '## \[0.1.1\]' CHANGELOG.md && grep -q 'claude_risk' CHANGELOG.md && echo ok`
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: add changelog"
```

---

### Task 3: `.github/workflows/release.yml`

**Files:**
- Create: `.github/workflows/release.yml`
- Test: `tests/unit/test_release.sh` (append a workflow-order check)

**Interfaces:**
- Consumes: `scripts/release.sh --check` and `scripts/release.sh <dir>` from Task 1.
- Produces: a workflow triggered on `push` of tags `v*`, `permissions: contents: write`, one job on `ubuntu-24.04`: checkout with `fetch-depth: 0`; `bash tests/run.sh` with `QVK_REQUIRE_SHELLCHECK: "1"`; `bash scripts/release.sh --check`; `bash scripts/release.sh dist`; `gh release create "$GITHUB_REF_NAME" dist/quality-vps-kit-*.tar.gz dist/SHA256SUMS --title "quality-vps-kit ${GITHUB_REF_NAME#v}" --generate-notes` with `GH_TOKEN: ${{ github.token }}`; a final `gh release view "$GITHUB_REF_NAME" --json assets` step.

- [ ] **Step 1: Write the failing check.** Append to `tests/unit/test_release.sh`: read `.github/workflows/release.yml`, and assert the byte offset of `tests/run.sh` is lower than that of `gh release create`, and that the file contains `tags:` with `v*`, `contents: write`, and `gh release view`. Use `grep -b` or `awk` to compare positions; a missing file must fail.

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/unit/test_release.sh`
Expected: FAIL — the workflow file does not exist.

- [ ] **Step 3: Implement the workflow.** Only `actions/checkout@v4`; every other step is a shell command. Keep the job name `publish` and the step order from the Interfaces block; no secrets beyond `github.token`.

- [ ] **Step 4: Run the test and the offline suite**

Run: `bash tests/unit/test_release.sh` and `bash tests/run.sh`
Expected: both `RESULT: OK` (the workflow file is not YAML-validated offline — note that in the commit message and ask for a review read of the file).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml tests/unit/test_release.sh
git commit -m "ci: publish release assets on version tags"
```

---

### Task 4: `docs/release.md` and a pointer from the architecture doc

**Files:**
- Create: `docs/release.md`
- Modify: `docs/architecture.md` (D5 "Report schema and versioning" ~83-88)

**Interfaces:**
- Produces: the written procedure that `scripts/release.sh`, the workflow and this plan all assume.

- [ ] **Step 1: Write `docs/release.md`.** Sections: "Version sources" (the three places: `VERSION`, tag `v<version>`, `install.sh` default — `scripts/release.sh --check` enforces agreement); "Cutting a release" (move `Unreleased` to `## [x.y.z] - YYYY-MM-DD`; bump `VERSION` and `install.sh`; `bash tests/run.sh`; commit `release: vX.Y.Z`; `git tag -a vX.Y.Z -m ...`; `git push origin master --follow-tags`; the workflow publishes); "Verifying" (`gh release view vX.Y.Z --json assets` shows both assets, then `curl -fsSL .../install.sh | bash -s -- version` prints the new version); "If something is wrong" (never move or delete a published tag; ship a patch release); "Schema version" (a pointer to `docs/architecture.md` D5: `schema_version` is `0.x` until 1.0, an incompatible JSON change bumps it, the tool version follows SemVer separately).

- [ ] **Step 2: Add the pointer.** In `docs/architecture.md` D5, add one sentence linking `docs/release.md` for the tool version and release procedure.

- [ ] **Step 3: Verify**

Run: `grep -q 'scripts/release.sh --check' docs/release.md && grep -q 'release.md' docs/architecture.md && echo ok`
Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add docs/release.md docs/architecture.md
git commit -m "docs: release procedure and version sources"
```

---

### Task 5: Cut `0.1.1`

**Files:**
- Modify: `VERSION`
- Modify: `install.sh` (the `QVK_VERSION:-` default, line 8)
- Modify: `CHANGELOG.md` (the `0.1.1` heading gets a date)

**Interfaces:**
- Consumes: Task 1's `--check` and Task 4's procedure.
- Produces: a repository where `scripts/release.sh --check` passes with `v0.1.1`.

- [ ] **Step 1: Bump.** `VERSION` → `0.1.1`; `install.sh` default → `0.1.1`; `CHANGELOG.md`: `## [0.1.1] - 2026-11-09`.

- [ ] **Step 2: Commit, then tag** (the check requires a clean tree, so the tag comes after the commit and the check comes after the tag):

```bash
git add VERSION install.sh CHANGELOG.md
git commit -m "release: v0.1.1"
git tag -a v0.1.1 -m "quality-vps-kit 0.1.1"
```

- [ ] **Step 3: Verify locally**

Run: `bash scripts/release.sh --check`
Expected: `release.sh: checks passed: v0.1.1`. If it reports a mismatch, fix the file it names and amend nothing already published — this tag is local until pushed.

- [ ] **Step 4: Full suite**

Run: `bash tests/run.sh`
Expected: `RESULT: OK`.

- [ ] **Step 5: Hand over the push.** Do not push from the agent session. Report the commit and tag, and let the maintainer run `git push origin master --follow-tags` — that push is what triggers the publishing workflow.

---

## Self-review notes

- Coverage: the three-way version drift, tag placement, dirty tree (Task 1); changelog (Task 2); automation with tests before publish and an asset check (Task 3); written procedure and schema-version pointer (Task 4); the actual `0.1.1` release including the Claude-risk feature (Task 5).
- Ordering with the feature plan: execute `2026-11-09-claude-ip-risk.md` first; `0.1.1` then contains it, so the new release procedure is exercised on a release that has a real changelog entry.
- Type consistency: the script flag is `--check` everywhere; the workflow tag pattern is `v*` and matches the tag created in Task 5 (`v0.1.1`); asset names match `scripts/release.sh` (`quality-vps-kit-<version>.tar.gz`, `SHA256SUMS`).
- Deliberately not done: no `CHANGELOG` automation, no semantic-release tooling, no draft releases, no third-party actions.
