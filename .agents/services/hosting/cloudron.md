---
description: Cloudron self-hosted app platform
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudron App Platform Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Self-hosted app platform (100+ apps), auto-updates/backups/SSL
- **Host OS**: Vendor-required Ubuntu x64; verify the exact fresh-install release in [Cloudron requirements](https://docs.cloudron.io/installation/) and [OS selection](../../reference/os-selection.md). Do not substitute Rocky/Alpine or assume ARM support
- **Optional GitHub ingress**: [Webhook onboarding](../../reference/github-webhook-onboarding.md) — Cloudron-hosted NetBird provides mesh management, not native public reverse proxy; use Cloudflare Tunnel or a separate public gateway without modifying Cloudron's managed nginx
- **Auth**: API token from Dashboard > Settings > API Access (9.1+: passkey/OIDC login)
- **Config**: `configs/cloudron-config.json`
- **Commands**: `cloudron-helper.sh [servers|connect|status|apps|install-app|update-app|restart-app|logs|backup-app|domains|add-domain|ssl-status|users|add-user|update-user] [server] [args]`
- **CLI ops**: `cloudron-server-ops-skill.md` (full CLI reference)
- **Packaging**: `cloudron-app-packaging.md` (native), `cloudron-app-packaging-skill.md` (upstream)
- **Publishing**: `cloudron-app-publishing-skill.md` (community packages via CloudronVersions.json)
- **API test**: `curl -H "Authorization: Bearer TOKEN" https://cloudron.domain.com/api/v1/cloudron/status`
- **SSH**: `ssh root@cloudron.domain.com` for direct server diagnosis
- **Forum**: [forum.cloudron.io](https://forum.cloudron.io) — search error messages first
- **Docker**: `docker ps -a` (states), `docker logs <container>`, `docker exec -it <container> /bin/bash`
- **DB creds**: `docker inspect <container> | grep CLOUDRON_MYSQL` (redact secrets before sharing)

<!-- AI-CONTEXT-END -->

## Configuration

```bash
cp configs/cloudron-config.json.txt configs/cloudron-config.json
```

```json
{
  "servers": {
    "production": {
      "hostname": "cloudron.yourdomain.com",
      "api_token": "YOUR_CLOUDRON_API_TOKEN_HERE"
    },
    "staging": {
      "hostname": "staging-cloudron.yourdomain.com",
      "api_token": "YOUR_STAGING_CLOUDRON_API_TOKEN_HERE"
    }
  }
}
```

API token: Dashboard > Settings > API Access > Generate.

## Troubleshooting

**Always check [forum.cloudron.io](https://forum.cloudron.io) first** — most post-update issues have forum threads with official workarounds.

### Post-Reboot / Post-Update Diagnostic Playbook

Follow in order — each step narrows the diagnosis.

**Step 1: Context**

```bash
ssh root@my.cloudron.domain.com
uptime                                                          # <10 min = apps still starting
last reboot | head -5
journalctl -b -1 --no-pager | grep -i -E 'cloudron.*update|cloudron-updater'
jq -r '.version // "not found"' /home/yellowtent/box/package.json
```

**Step 2: Resources**

```bash
free -h && df -h / && uptime
```

**Step 3: Container states**

```bash
docker ps -a --format '{{.State}}' | sort | uniq -c | sort -rn
docker ps -a --filter 'status=exited' --format '{{.Names}}\t{{.Status}}' \
  | grep -v -E 'cleanup|archive|housekeeping|previewcleanup|jobs'
```

**Step 4: Box log** (primary diagnostic)

```bash
tail -100 /home/yellowtent/platformdata/logs/box.log
systemctl status box.service
grep 'app health:' /home/yellowtent/platformdata/logs/box.log | tail -5
```

**Step 5: Monitor** (run every 60s)

```bash
echo "=== $(date) ===" && \
docker ps -a --format '{{.State}}' | sort | uniq -c | sort -rn && \
tail -1 /home/yellowtent/platformdata/logs/box.log
```

### Startup Architecture

Startup sequence (prevents premature intervention):

| Phase | Duration | Details |
|-------|----------|---------|
| Infrastructure | 2-3 min | `box.service` → MySQL, PostgreSQL, MongoDB, mail, graphite, sftp, turn (sequential) |
| Redis sidecars | 3-5 min | One per app with Redis addon, started sequentially (~16s each). Initial `ECONNREFUSED` on attempt 1 is normal |
| App containers | 2-5 min | Concurrency limit (~15). `At concurrency limit, cannot drain anymore` and `N apptasks pending` are normal queuing |
| Health checks | 1-2 min | Apps `unresponsive` until HTTP endpoint responds |

**Expected recovery**: 8-15 min for 30+ apps. High load (5-15) and "restarting"/"not responding" in dashboard are normal during this window.

**When to intervene**: After 15 min if box.log shows same Redis container failing repeatedly (>5 attempts) or container state counts aren't changing.

### Normal Startup vs Stuck

| Symptom | Normal | Stuck |
|---------|--------|-------|
| `ECONNREFUSED` in box.log | Attempt 1-2 per Redis, moves on | Same container >5 attempts, never advances |
| `At concurrency limit` | Pending count decreasing | Pending count static >5 min |
| High load average | Decreasing over 5-10 min | Sustained >10 after 15 min |
| Exited containers | Count decreasing | Count static after 10 min |
| `created` state containers | Transitioning to `running` | Stuck >10 min |

### Known 9.x Post-Update Issues

**Redis not starting (9.1.3+)**: `Permission denied` writing PID to `/run/redis`. One stuck Redis blocks entire sequential chain. Forum: search "redis not starting 9.1".

**DB migration failures (8.x→9.x)**: `oidcClients` migration fails if app's `cloudronManifest.json` has no `addons` object. Symptoms: `Cannot read properties of undefined (reading 'oidc')` or `Unknown column 'pending'/'completed'`. Fix: add empty addons objects to MySQL `apps` table, then `cloudron-support --apply-db-migrations`. Forum: search "Error accessing Dashboard after update from 8.x to 9.x".

**Docker network removal failure**: Infrastructure upgrade 49.8.0→49.9.0 fails — "network has active endpoints". All apps stuck in "Configuring". Fix: disconnect endpoints, remove network, restart box service. Forum: search "Apps stuck in Configuring due to failed infrastructure upgrade".

**Services stuck in "Starting services"**: After 9.0.11, infinite `grep -q avx /proc/cpuinfo` loops on VMs without AVX. Forum: search "Update 9.0.11 Broke Services".

**Health monitor stuck**: Apps work but dashboard shows permanent "Starting...". Fix: `systemctl restart box`. Forum: search "apps responsive but showing a permanent Starting status".

### Container State Reference

| State | Meaning | Action |
|-------|---------|--------|
| `Up` | Healthy | Normal |
| `Restarting` | Crash loop | Check logs — likely app/db issue |
| `Exited (0)` | Clean shutdown | Not yet started (normal post-reboot) |
| `Exited (1)` | Error exit | `docker logs <container>` |
| `Exited (137)` | OOM/SIGKILL | `dmesg \| grep -i oom`, check memory limits |
| `Created` | Never started | Waiting in startup queue |

### Key Log Files

| Log | Location | Purpose |
|-----|----------|---------|
| Box service | `/home/yellowtent/platformdata/logs/box.log` | Primary diagnostic |
| Box status | `systemctl status box.service` | Platform running? |
| App logs | `docker logs <container_name>` | Individual app errors |
| Previous boot | `journalctl -b -1 --no-pager -n 50 -p warning` | Pre-reboot events |
| Built-in diag | `cloudron-support --troubleshoot` | Diagnostic checks |
| Version | `jq -r '.version // "not found"' /home/yellowtent/box/package.json` | Current version |

### Database Troubleshooting (MySQL)

```bash
# Find MySQL credentials from app container
docker inspect <app_container> | grep CLOUDRON_MYSQL
# Reveals: CLOUDRON_MYSQL_HOST, PORT, USERNAME, PASSWORD, DATABASE (hex string)

# Connect via the mysql container
docker exec -it mysql mysql -u<username> -p<password> <database>
```

> **Security**: `docker inspect` reveals credentials. Redact passwords before sharing. The `-p$(cat ...)` pattern exposes password in process list — prefer env var injection (see `reference/secret-handling.md` §8.3).

**Charset/Collation Issues** (common after updates):

```sql
-- Check current charset
SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME
FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'your_db_hex';

-- Fix table charset (example for Vaultwarden SSO issue)
ALTER TABLE sso_nonce CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE sso_users CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
```

### App Recovery

**Recovery mode**: Apps > Select App > Advanced > Enable Recovery Mode. Starts with minimal config, bypassing startup scripts. Use for DB repairs, config fixes, manual migrations.

```bash
docker exec -it <app_container> /bin/bash
# Make fixes, then disable recovery mode via dashboard
```

**App startup failure checklist**:

1. Container state: `docker ps -a | grep <app_subdomain>`
2. Logs: `docker logs --tail 200 <container>`
3. Forum: copy error message to forum.cloudron.io search
4. Database: often charset/migration issues
5. Recovery mode if DB fix needed
6. Apply fix (usually SQL from forum)
7. Restart: dashboard or `docker restart <container>`

**App-specific**: Vaultwarden → `tools/credentials/vaultwarden.md` | WordPress → `tools/wordpress/`

## Usage Examples

```bash
# Server management
cloudron-helper.sh servers
cloudron-helper.sh status production
cloudron-helper.sh apps production

# App management (install-app|update-app|restart-app|logs|backup-app)
cloudron-helper.sh install-app production wordpress blog.yourdomain.com
cloudron-helper.sh update-app production app-id

# Domain management (domains|add-domain|ssl-status)
cloudron-helper.sh domains production
cloudron-helper.sh add-domain production newdomain.com

# User management (users|add-user|update-user)
cloudron-helper.sh users production
cloudron-helper.sh add-user production newuser@domain.com
```

## What's New in 9.1

Source: [forum.cloudron.io/topic/14976](https://forum.cloudron.io/topic/14976/what-s-coming-in-9-1) (released to unstable 2026-03-01)

- **Custom app build/deploy**: `cloudron install` uploads source, builds on-server. Source backed up and rebuilt on restore.
- **Community packages**: Third-party apps via `CloudronVersions.json` URL in dashboard. Aidevops-packaged apps use keyless image/catalog provenance, while Cloudron currently does not enforce it client-side. See `cloudron-app-publishing-skill.md` and `reference/release-artifact-provenance.md`.
- **Passkey auth**: FIDO2/WebAuthn. Tested: Bitwarden, YubiKey 5, Nitrokey, native browser/OS.
- **OIDC CLI login**: Browser-based OIDC for CLI. Pre-obtained API tokens still work for CI/CD.
- **Addon upgrades**: MongoDB 8, Redis 8.4, Node.js 24.x
- **ACME ARI**: RFC 9773 certificate renewal information
- **Backup integrity verification UI** and improved progress reporting

## Related Skills and Subagents

| Resource | Path | Purpose |
|----------|------|---------|
| App packaging (native) | `tools/deployment/cloudron-app-packaging.md` | Packaging guide with aidevops helpers |
| App packaging (upstream) | `tools/deployment/cloudron-app-packaging-skill.md` | Official Cloudron skill with manifest/addon refs |
| App publishing | `tools/deployment/cloudron-app-publishing-skill.md` | CloudronVersions.json and community packages |
| Server ops | `tools/deployment/cloudron-server-ops-skill.md` | Full CLI reference for managing apps |
| Git reference | `tools/deployment/cloudron-git-reference.md` | git.cloudron.io packaging patterns |
| Helper script | `scripts/cloudron-helper.sh` | Multi-server management via API |
| Package helper | `scripts/cloudron-package-helper.sh` | Local packaging development workflow |
