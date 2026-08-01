---
name: cloudron-app-publishing
description: "Distribute Cloudron apps via CloudronVersions.json version catalogs"
mode: subagent
imported_from: external
tools:
  read: true
  write: true
  edit: true
  bash: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudron App Publishing

Distribute Cloudron apps independently using a `CloudronVersions.json` version catalog. Users add the file's URL in their dashboard or install via `cloudron install --versions-url <url>`.

## Quick Reference

- **Docs**: [docs.cloudron.io/packaging/publishing](https://docs.cloudron.io/packaging/publishing)
- **Upstream skill**: [git.cloudron.io/docs/skills](https://git.cloudron.io/docs/skills) (`cloudron-app-publishing`)
- **Prerequisite**: App must be built with `cloudron build` (local or build service) — on-server builds cannot be published
- **Key file**: `CloudronVersions.json` — version catalog hosted at a public URL
- **Listing**: [Cloudron Community Apps](https://ca.cloudron.io) accepts a public versions URL after the catalog contains a tested release; listing is optional
- **Forum**: [App Packaging & Development](https://forum.cloudron.io/category/96/app-packaging-development)

## Workflow

```bash
cloudron versions init  # creates CloudronVersions.json + DESCRIPTION.md, CHANGELOG, POSTINSTALL.md (edit all placeholders)
cloudron build          # build and push image (first run prompts for Docker repository, e.g. registry/username/myapp)
cloudron versions add --state testing  # add the registry image without exposing it as stable
cloudron versions update --version=1.0.0 --state=published
# host CloudronVersions.json at a public URL
```

`cloudron versions init` also adds missing publishing fields to `CloudronManifest.json` with placeholder values. Edit all placeholders and scaffolded files before adding a version.

## Repository Baseline

Commit these before the first registry build:

- `CloudronVersions.json` initialized as `{ "stable": true, "versions": {} }`; never fabricate an entry before `cloudron build` records a real registry image.
- `CloudronManifest.json` publishing metadata: `id`, `title`, `author`, `description`, `tagline`, `version`, `website`, `contactEmail`, `iconUrl`, `packagerName`, `packagerUrl`, non-empty `tags`, non-empty `mediaLinks`, `changelog`, and `minBoxVersion` of at least `9.1.0`. Add `packageUrl` when the listing must link to the package source repository; this requires `minBoxVersion` 10.0.0.
- A local square 256×256 PNG icon (`icon` normally points to it) and at least one privacy-reviewed product screenshot or hero. `mediaLinks` must use public HTTPS URLs; Cloudron recommends 3:1 images such as 1200×400.
- A Cloudron-format changelog file when using `file://`: each release heading must be exactly `[X.Y.Z]`, because `cloudron versions add` does not parse Keep a Changelog headings such as `## [X.Y.Z]`.
- A short publishing runbook that records the canonical catalog URL, registry/repository ownership, asset provenance, test install, rollback, and Community Apps listing steps without storing credentials.
- A managed GitHub Actions release workflow that creates and verifies keyless provenance for the immutable image digest and exact generated `CloudronVersions.json`; use `reference/release-artifact-provenance.md` before the first publication.

`packageUrl` controls the package-source link in Community Apps and should point to the package repository. It requires `minBoxVersion` 10.0.0. Keep `packagerUrl` pointed at the package maintainer; do not repurpose it as the repository link. Packages that need Cloudron 9.1 compatibility should omit `packageUrl`, while packages that require a repository link should raise the minimum explicitly. `author` and `contactEmail` are deprecated in the manifest reference but are still required by the current CLI version-catalog validator.

Use package-controlled, stable asset URLs where possible. If an upstream asset is used temporarily, preserve a reviewed local copy and replace the remote reference before the upstream URL becomes unstable. Check every URL for an HTTPS 200 response and an image content type before publishing.

## Build Commands

| Command | Purpose |
|---------|---------|
| `cloudron build` | Build and push image (local or remote) |
| `cloudron build --no-cache` | Rebuild without Docker cache |
| `cloudron build --no-push` | Build but skip push |
| `cloudron build -f Dockerfile.cloudron` | Use specific Dockerfile |
| `cloudron build --build-arg KEY=VALUE` | Pass Docker build args |
| `cloudron build reset` | Clear saved repository, image, and build info |
| `cloudron build info` | Show current build config |
| `cloudron build login` / `logout` | Authenticate with remote build service |
| `cloudron build logs --id <id>` | Stream logs for a remote build |
| `cloudron build push --id <id>` | Push a remote build to a registry |
| `cloudron build status --id <id>` | Check status of a remote build |

Build behavior depends on whether a build service is configured:

- **No build service configured** — `cloudron build` uses the local Docker daemon. Requires Docker and registry auth.
- **Build service configured** — `cloudron build` sends source to the remote Docker Builder app, which builds and pushes the image.

## Versions Commands

| Command | Purpose |
|---------|---------|
| `cloudron versions add` | Add current version (reads manifest + last built image) |
| `cloudron versions list` | List all versions with date, image, and publish state |
| `cloudron versions update --version=1.0.0 --state=published` | Change publish state |
| `cloudron versions revoke` | Mark latest published version as revoked |

**Rules:** Do not change the manifest or image of a published version. Treat catalog entries as append-only release records. To ship changes: revoke only when necessary, bump the package version, rebuild, and add a new entry. Never copy a Docker tag or digest into the catalog by hand.

Typical release cycle:

```bash
# 1. Edit code, bump version in CloudronManifest.json
# 2. Build and push
cloudron build

# 3. Add to catalog as a test candidate
cloudron versions add --state testing

# 4. Host the catalog and test a clean install/upgrade via its public URL
cloudron versions list

# 5. Promote the exact tested entry
cloudron versions update --version=1.1.0 --state=published

# 6. Commit and push CloudronVersions.json to hosting
git add CloudronVersions.json && git commit -m "release 1.1.0" && git push
```

Before promotion, verify fresh install, upgrade from the previous published version, restart, backup/restore, health checks, and the public icon/media URLs. Image push, catalog promotion, catalog hosting, and Community Apps submission are publication actions and require explicit authorization.

## Keyless Publication Provenance

For aidevops-packaged community apps, GitHub Actions OIDC/Sigstore provenance is
the default release design. Pin the package image by digest; attest both that OCI
digest and the exact generated catalog bytes; verify each emitted bundle against
the package repository, exact catalog workflow, and protected source ref before
committing or promoting the catalog. Add a no-version-bump path that attests the
existing catalog when this control is first adopted.

Cloudron does not currently verify external Sigstore attestations when importing
`CloudronVersions.json` or applying automatic updates. Describe the result as
tamper evidence and publisher provenance, not client-enforced signing. A checksum
beside the catalog does not close this gap because the same compromised host can
replace both. Full workflow and verification pattern:
`reference/release-artifact-provenance.md`.

## Distribution

- **Dashboard**: add `CloudronVersions.json` URL under Community apps in dashboard settings — updates appear automatically
- **CLI**: `cloudron install --versions-url <url>`
- **Community listing**: sign in to [Cloudron Community Apps](https://ca.cloudron.io), open the publisher's apps, add the same versions URL, and confirm the imported title, icon, screenshot, changelog, and install URL. The listing is optional and does not host the catalog.

## Community Packages (9.1+)

Community packages can be non-free (paid). Publishers keep Docker images private; end users set up a [private Docker registry](https://docs.cloudron.io/docker#private-registry) for access.
