---
description: npm cache, runtime bundle, backup, and log storage lifecycle policies
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Storage Lifecycle Store Policies

## npm Cache Monitoring

`aidevops status` gives the npm cache a bounded ten-second size probe and warns
when an exact measurement exceeds 10 GiB. Set
`AIDEVOPS_NPM_CACHE_WARN_BYTES` to tune that advisory threshold. A timeout stays
visible and never becomes cleanup authority; run `npm-cache-helper.sh status`
for an explicit longer scan after npm-heavy work.

The helper keeps npm in control of every mutation. `verify` runs `npm cache
verify`, which checks integrity and garbage-collects unneeded data. `clean` is a
dry run unless both `--apply` and `--confirm clean-npm-cache` are present; the
confirmed path invokes `npm cache clean --force` rather than deleting files
directly. Neither shared inventory nor scheduled maintenance cleans external
package-manager data automatically.

## Runtime Bundle Retention Overrides

The 30-day, 30-bundle, and 8 GiB runtime-bundle limits are project defaults, not
universal recommendations. Operators can set integer environment overrides for
the update or setup process without changing framework policy:

```bash
AIDEVOPS_RUNTIME_BUNDLE_RETENTION_SECONDS=604800 \
AIDEVOPS_RUNTIME_BUNDLE_MAX_COUNT=5 \
AIDEVOPS_RUNTIME_BUNDLE_MAX_BYTES=1073741824 \
aidevops update
```

Invalid values fall back to the project defaults. These remain soft candidate
limits: the active bundle, previous rollback bundle, Pulse-pinned bundle, and
every live-leased bundle remain protected even when an override is lower than
the protected bundle count or bytes.

On macOS, persist these values for scheduled updates under the
`com.aidevops.aidevops-auto-update` label in
`~/.config/aidevops/plist-env-overrides.json`; the generated auto-update
LaunchAgent injects them into its environment. See
`reference/plist-env-overrides.md` for the file format and setup steps.

## Runtime Bundle Dependency Decision

Runtime activation continues to verify the OpenCode host's existing dependency
tree first and installs declared dependencies inside a staged bundle only when
that verification fails. A new lock-keyed shared dependency store is deferred:
it would introduce shared mutable ownership, concurrent-install locking, cache
integrity, and offline rollback dependencies into otherwise immutable bundles.
The measured duplication is instead bounded by pruning unreferenced bundles.
This preserves atomic activation and makes each retained rollback bundle
self-verifying without making npm's global cache framework-owned.

## Explicit Runtime Bundle Rollback

Normal setup remains monotonic: it rejects an older framework version or a
strict ancestor of the active source commit. Operators can inspect eligible
retained bundles and perform the separate audited transition with:

```bash
aidevops runtime-bundle list
aidevops runtime-bundle rollback --bundle-id <id> --reason "<operator reason>"
```

The command accepts a bundle ID from the managed inventory, never a path. It
requires matching validated manifests, a manifest-bound bundle ID, the retained
source commit, matching version and runtime sentinel hashes, and CLI/plugin
integrity before taking the same mutation lock as setup. The active link,
previous-runtime link, and deployed-SHA stamp are then changed atomically per
file and verified as one transaction. Any post-switch failure restores the
captured active root, previous link, and stamp.

The former active bundle becomes the new rollback point. Existing process
leases and the bounded Pulse runtime pin continue naming their immutable roots;
rollback neither deletes nor rewrites them. Every allowed or blocked attempt is
recorded in the hash-chained runtime-bundle rollback audit log with the operator
reason, outcome, mode, and source/target bundle IDs, versions, and Git SHAs.
Retention can remove an unreferenced bundle before an operator selects it, so
`runtime-bundle list` is the authoritative eligibility inventory at execution
time. A later successful setup or update may move the global link forward again.

## Coordinated Backup and Log Policies

Setup, headless-runtime failure evidence, and Pulse remain separate storage
producers. Coordination means they publish compatible inventory records; it does
not grant a generic helper authority to delete across `~/.aidevops`.

- Setup accepts only timestamp-named snapshot directories that it created. It
  measures all candidates, protects the newest rollback snapshot, computes an
  oldest-first dry run, validates a producer-specific confirmation token, and
  stages exact paths in `.retention-trash` before removal. A symlink, unexpected
  name, sizing failure, or metadata failure preserves every snapshot.
- Headless runtime applies the same plan/confirm/stage sequence only to older
  excerpts for the same sanitized session key. The newest excerpt is unresolved
  recovery evidence and remains protected regardless of age or size. Ambiguous
  names and symlinks are unknown rather than cleanup candidates.
- Pulse retains its descriptor-preserving gzip-and-truncate implementation.
  Active files are never unlinked, so concurrent writers retain valid file
  descriptors, and its existing combined cold-archive byte cap remains the only
  cleanup authority for Pulse logs.

An interrupted staged cleanup leaves either the original or an attributable
producer-local trash copy. Inventory includes trash bytes as protected until a
producer can complete or an operator can diagnose the interrupted action.
