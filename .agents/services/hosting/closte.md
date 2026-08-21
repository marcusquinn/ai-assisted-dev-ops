---
description: Legacy Closte managed WordPress hosting operations and migration
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Closte Provider Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Status**: Legacy provider knowledge retained for existing Closte estates, migration, and offboarding
- **New deployments**: Do not recommend Closte; select Hostinger, Hetzner, or Cloudflare according to the user's priorities via `aidevops/recommendations.md`
- **Type**: Managed WordPress hosting with LiteSpeed, object cache, and CDN layers
- **Authentication**: Closte supplies password-based SSH access; key authentication may not be available
- **Credentials**: Inject the four `SITE_SSH_*` secrets only into a subprocess; never retrieve values or create plaintext password files
- **Mutations**: Enable Development Mode first and install reliable cleanup that disables it on every exit path
- **Multisite**: Resolve the target site and pass `--url=<SITE_URL>` to every site-scoped WP-CLI command

<!-- AI-CONTEXT-END -->

## Legacy Scope

Use this guide to operate, migrate, or retire sites that are already on Closte.
For a renewal, expansion, or new hosting decision, reassess the workload against
Hostinger, Hetzner, and Cloudflare rather than carrying Closte forward by default.
Preserve the operational safeguards below while an existing Closte site remains
in service.

## Project Context

Keep instance-specific values in the initialized project, not this reusable provider guide:

- `.aidevops/deployments.yaml` records placeholder-backed deployment fields and secret names.
- `.aidevops/wordpress.yaml` records WordPress, multisite, and LocalWP context.
- Secret values stay in the aidevops secret backend and never enter either manifest.

Initialize with `aidevops init deployment-context` or `aidevops init wordpress-context`.

## Credentials and SSH

Closte password authentication commonly requires `sshpass` for non-interactive commands. Install it through the operator-approved package-management process; do not download binaries from unverified locations.

Use one generic site-prefixed set of secret names. Replace the `SITE` prefix only
when a machine must distinguish multiple sites. Each command prompts for the value
without displaying it:

```bash
aidevops secret set SITE_SSH_HOST
aidevops secret set SITE_SSH_PORT
aidevops secret set SITE_SSH_USER
aidevops secret set SITE_SSH_PASSWORD
```

Before connecting, obtain the SSH host-key fingerprint through a trusted Closte control-plane channel and add that verified key to the operator-managed `known_hosts`. Never use `StrictHostKeyChecking=no`, accept an unexpected replacement key, or treat `ssh-keyscan` output alone as identity proof.

```bash
aidevops secret SITE_SSH_HOST SITE_SSH_PORT SITE_SSH_USER SITE_SSH_PASSWORD -- sh -c '
  ssh-keygen -F "$SITE_SSH_HOST" || exit 1
  SSHPASS="$SITE_SSH_PASSWORD"
  export SSHPASS
  exec sshpass -e ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$HOME/.ssh/known_hosts" -p "$SITE_SSH_PORT" "$SITE_SSH_USER@$SITE_SSH_HOST"
'
```

The secret wrapper injects values only into `sh` and its children. The agent must
not print, retrieve, interpolate, or inspect them. Use the same strict host-key
options for `scp` or `rsync` over SSH. Project context stores the four secret names,
not their values.

## Mutation Guard

Closte caching can hide changes. Any file, database, plugin, theme, option, or content mutation requires Development Mode. Establish cleanup immediately after enabling it so interruption and command failure cannot leave the site in Development Mode.

Run this inside the verified remote shell, replacing placeholders from project context:

```bash
wp closte devmode enable --url="<SITE_URL>"
trap 'wp closte devmode disable --url="<SITE_URL>" >/dev/null 2>&1 || true' EXIT HUP INT TERM

<MUTATION_COMMAND>

wp cache flush --url="<SITE_URL>"
```

The exit trap is the authoritative cleanup. An explicit disable may be run after verification, but do not remove the trap until the remote shell exits. If enablement fails, stop before mutation. If disablement cannot be confirmed, report the site as requiring operator cleanup.

Read-only inventory commands do not require Development Mode. Database exports and backup creation are operational reads but can consume resources; confirm scope and available storage before running them.

## Multisite and Cache Verification

Resolve network topology before site-scoped work:

```bash
wp core is-installed --network
wp site list --fields=blog_id,url,archived,deleted
wp option get home --url="<SITE_URL>"
wp option get siteurl --url="<SITE_URL>"
```

After a mutation:

1. Flush object cache for the exact site with `wp cache flush --url="<SITE_URL>"`.
2. Purge page cache and CDN through the approved Closte controls when relevant.
3. Verify the intended site with an authenticated or cache-bypassed request.
4. Verify another multisite site was not changed.
5. Confirm Development Mode is disabled.
6. Record the backup or rollback reference and verification evidence.

Do not infer success from one cached browser response. Compare WP-CLI state and an independent HTTP/browser check.

## File Transfer

Keep exports and archives outside Git. For project-managed transfers, use a path ignored by `.aidevops/.gitignore`, verify free space and checksums, and delete local and remote temporary artifacts after validation.

```bash
aidevops secret SITE_SSH_HOST SITE_SSH_PORT SITE_SSH_USER SITE_SSH_PASSWORD -- sh -c '
  SSHPASS="$SITE_SSH_PASSWORD"
  export SSHPASS
  exec sshpass -e scp -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$HOME/.ssh/known_hosts" -P "$SITE_SSH_PORT" "$SITE_SSH_USER@$SITE_SSH_HOST:<REMOTE_EXPORT>" "<PRIVATE_LOCAL_PATH>"
'
```

For a production clone into LocalWP, follow `.agents/workflows/wordpress-local-clone.md`.
