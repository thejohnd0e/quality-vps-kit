# Releasing quality-vps-kit

## Version sources

The tool version is repeated in three places:

- `VERSION` — used by `qvk version` and reports;
- the git tag `v<version>` — the release identity and archive source;
- the pinned default in `install.sh` (`QVK_VERSION`).

Run `bash scripts/release.sh --check` on a clean checkout to verify these agree,
that the tag points to `HEAD`, and that the working tree has no tracked changes.
The regular `scripts/release.sh [output-dir]` performs the same check before it
builds `quality-vps-kit-<version>.tar.gz` and `SHA256SUMS`.

## Cutting a release

1. Move the relevant items from `## [Unreleased]` in `CHANGELOG.md` to a dated
   `## [x.y.z] - YYYY-MM-DD` section.
2. Update `VERSION` and the `QVK_VERSION` default in `install.sh` to the same
   `x.y.z` value.
3. Run `bash tests/run.sh` and `bash scripts/release.sh --check`.
4. Commit the release metadata, for example `git commit -m "release: vX.Y.Z"`.
5. Create an annotated tag on that commit:
   `git tag -a vX.Y.Z -m "quality-vps-kit X.Y.Z"`.
6. Push the branch and tag: `git push origin master --follow-tags`.

The tag workflow runs the offline tests and release check, builds the two assets,
and publishes the GitHub Release. It does not publish if a check fails.

## Verifying

Check that the release has both assets:

```bash
gh release view vX.Y.Z --json assets
```

Then verify the one-line runner selects the new version:

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/quality-vps-kit/master/install.sh | bash -s -- version
```

The output should end with `qvk (quality-vps-kit) X.Y.Z`.

## If something is wrong

Never move or delete a published tag. If a release has a defect or incomplete
assets, fix it and publish a new patch version; the existing tag and artifacts
remain immutable.

## Schema version

The report's `schema_version` is independent of the tool's SemVer. It stays
`0.x` until 1.0; see [architecture, D5](architecture.md#d5-report-schema-and-versioning)
for schema compatibility and bumping rules.
