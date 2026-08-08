---
description: Package custom applications for Cloudron deployment
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudron App Packaging Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Docs**: [docs.cloudron.io/packaging](https://docs.cloudron.io/packaging/tutorial/) | [CLI Reference](https://docs.cloudron.io/packaging/cli/) | [Publishing](https://docs.cloudron.io/packaging/publishing/)
- **Source Code**: [git.cloudron.io/packages](https://git.cloudron.io/packages) (200+ official app packages) | [By Technology](https://git.cloudron.io/explore/projects/topics)
- **Forum**: [forum.cloudron.io/category/96](https://forum.cloudron.io/category/96/app-packaging-development)
- **Base Image Tags**: https://hub.docker.com/r/cloudron/base/tags
- **Sub-docs**: [addons-ref.md](cloudron-app-packaging-skill/addons-ref.md) | [manifest-ref.md](cloudron-app-packaging-skill/manifest-ref.md) | [cloudron-git-reference.md](cloudron-git-reference.md)

**Golden Rules** (violations cause package failure):

1. `/app/code` READ-ONLY at runtime — write to `/app/data`; `/run` and `/tmp` for ephemeral data (wiped on restart)
2. Run as `cloudron` user (UID 1000): `exec gosu cloudron:cloudron`
3. Use Cloudron addons (mysql, postgresql, redis) — never bundle databases
4. Disable built-in auto-updaters — Cloudron manages updates via image replacement
5. App receives HTTP — Cloudron's nginx terminates SSL
6. Read env vars fresh on every start (values change across restarts) — never cache at startup
7. Health check path must return HTTP 200 unauthenticated

**File Structure**: `CloudronManifest.json`, `Dockerfile`, `start.sh`, `logo.png` (256×256). Independently distributed packages also keep `CloudronVersions.json`, a Cloudron-format changelog, a publishing runbook, keyless image/catalog provenance, and at least one privacy-reviewed screenshot or 3:1 hero; follow `cloudron-app-publishing-skill.md`.

**CLI Workflow**:

```bash
npm install -g cloudron
cloudron login my.cloudron.example && cloudron init
cloudron build && cloudron install --location testapp
cloudron build && cloudron update --app testapp  # iterate
cloudron logs -f --app testapp
cloudron exec --app testapp   # shell into container
cloudron debug --app testapp  # pause app, writable fs
```

<!-- AI-CONTEXT-END -->

## Pre-Packaging Assessment

Score both axes before writing code. Initial packaging is ~25% of effort; SSO, upgrade testing, backup correctness, and maintenance are 75%. Structural 10+ or compliance 9+ → recommend against packaging.

**Axis A: Structural Difficulty** (max 14: 0-2 Trivial, 3-4 Easy, 5-6 Medium, 7-9 Hard, 10+ Impractical)

| Sub-axis | 0 (Easy) | 1 (Moderate) | 2-3 (Hard) |
|----------|----------|--------------|------------|
| Process count | Single | 2-4 | 5+ or separate containers |
| Data storage | Cloudron addon / SQLite | — | Exotic (Elasticsearch, S3) |
| Runtime | Node/Python/PHP (in base) | Go/Java/Ruby/Rust (binary) | Must compile from source |
| Message broker | None | Redis (Celery/Bull) | Needs AMQP (LavinMQ) |
| Filesystem writes | 0-3 symlinks | 4-8 symlinks | 9+ or needs source patching |
| Authentication | Native LDAP/OIDC or none | Own auth, scriptable | Mandatory browser setup wizard |

**Axis B: Compliance & Maintenance** (max 13: 0-2 Low, 3-5 Moderate, 6-8 High, 9+ Very High)

| Sub-axis | 0 (Low) | 1-2 (Moderate) | 3 (High) |
|----------|---------|----------------|----------|
| SSO quality | Native LDAP/OIDC | Partial SSO / proxyauth | Auth conflicts (e.g., GoTrue) |
| Upstream stability | Stable, semver | Occasional breaking changes | Pre-release, frequent breaks |
| Backup complexity | Cloudron DB + /app/data | SQLite or custom backup | Internal stores needing snapshot APIs |
| Platform fit | HTTP behind reverse proxy | WebSocket (needs nginx config) | Raw TCP/UDP or horizontal scaling |
| Config drift | Env vars, no self-modification | Runtime plugin system | Self-updating, modifies own code |

### Pre-Packaging Research

1. Verify the assessment brief against repository metadata and primary files: current release, activity, and `LICENSE`. Report stale or contradictory inputs instead of silently correcting them.
2. Search the whole tree for Compose files — **the most valuable artifacts** because they reveal the intended topology and true dependency graph — then inspect the relevant `Dockerfile`, dependency manifests, deployment docs, and auth docs (search "LDAP", "OIDC", "SSO", "SAML").
3. Review releases for breaking changes over the latest 20 releases or six months, whichever is shorter. Some projects publish tags without releases, so check both when needed.
4. **Forum search**: `https://forum.cloudron.io/search?term=APP_NAME&in=titles`. Distinguish no prior thread, useful evidence, and a deleted/restricted thread; unsupported claims are leads, not scoring evidence.
5. Gather resource-sizing evidence (documented minimum RAM, Compose limits, and memory issues) and credible roadmap items that could change the score.
6. **App store**: `cloudron appstore search APP_NAME`
7. **Reference apps**: [cloudron-git-reference.md](cloudron-git-reference.md) for apps by technology

For each unresolved question, inspect at most five source files, then record the uncertainty and confidence rather than continuing unbounded source archaeology.

### Scoring Interpretation

- Name the exact released edition, repository, build variant, and topology being scored. Score the mode intended for packaging, not every optional distributed profile; disclose open-core boundaries without penalising features irrelevant to a single-container deployment.
- A pre-built binary satisfies runtime scoring only when it targets Linux amd64 with glibc. Alpine/musl-only or architecture-mismatched artifacts still require a compatible build.
- A stable REST endpoint can make admin bootstrap scriptable even when undocumented, but record the maintenance risk.
- For SSO, score whether the mechanism works and separately report post-login administration such as manual role assignment. Do not mistake application-specific federation endpoints for standards-based SSO.
- For upstream stability, breaking-change history governs the score; release cadence alone moves it by at most one point.
- For platform fit, include companion infrastructure required for advertised features, not only ports opened by the main container. State both footprints.
- Configuration drift measures risk introduced by the package. Core runtime behaviour belongs here only when its write paths or self-modification conflict with Cloudron's read-only model.
- Score released behaviour only. Record credible unshipped changes separately as roadmap risk and state how they would change the score if released.
- Do not move a score for an unsupported forum or issue claim; list it as an unverified risk and say what evidence would confirm it. Round upward only when adjacent scores remain equally defensible after reviewing the evidence.

Use the subtotals to calibrate the first packaging round (excluding assessment research):

| Structural | Compliance | Realistic effort |
|---|---|---|
| 0-2 | 0-2 | 4-8 hours |
| 0-2 | 3-5 | 6-12 hours |
| 3-4 | 3-5 | 10-16 hours |
| 5-6 | any | 16-30 hours |
| 7+ | any | 30+ hours or reconsider |

## Base Image

**Always `FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e`.** The final stage MUST use the SHA-pinned `cloudron/base` — platform tooling (file manager, web terminal, log viewer) depends on utilities in this image. Never start from upstream images — monolithic images bundle databases, reverse proxies, and init systems that conflict with Cloudron (e.g., docassemble: 25 symlinks, 15-20 min boot). Read upstream `docker-compose.yml` for dependencies, then install on `cloudron/base` via package manager. Current SHA tracked at [hub.docker.com/r/cloudron/base/tags](https://hub.docker.com/r/cloudron/base/tags) and in [`cloudron-app-packaging-skill.md`](cloudron-app-packaging-skill.md).

**Multi-stage builds**: Only when build toolchain is exotic. Build in upstream image, `COPY --from` artifacts into final `cloudron/base` stage. **Alpine/musl warning**: musl-compiled binaries won't run on `cloudron/base` (Ubuntu/glibc) — always use glibc builder stage.

**Base image contents (Cloudron 5.1.0, verified 2026-08-07)**: Ubuntu 24.04.4 LTS, Node.js 24.19.0 at `/usr/local/node-24.19.0/bin/node`, Python 3.12.3, Nginx 1.24.0, Apache 2.4.58, Supervisor 4.2.5, gosu 1.19, gcc 13.3.0, ImageMagick 6.9.12, ffmpeg 6.1.1, psql 16.14, mysql 8.0.46, redis-cli 8.10.0, mongosh 2.9.2, yq 4.53.3. Reviewed `cloudron/base:5.1.0` tag digest is `sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e`. **Not included** (install if needed): PHP, Ruby, Go, Java, Rust, pandoc, wkhtmltopdf.

**Community assessment intake (reviewed at `ad446c4136a7`)**: import packaging lessons from the assessment corpus rather than copying whole assessments. Its live-tool findings now define evidence boundaries, scoring-target selection, compound-axis tie-breakers, and effort calibration above. Good follow-up candidates include Huginn (medium structural, moderate maintenance, viable), while AppFlowy Cloud and ejabberd remain poor fits because of multi-service/auth/storage or network-port constraints. Prosody is the stronger XMPP path when raw TCP/TLS/DNS requirements are acceptable.

## CloudronManifest.json

Full field reference: [manifest-ref.md](cloudron-app-packaging-skill/manifest-ref.md). Addon options and env vars: [addons-ref.md](cloudron-app-packaging-skill/addons-ref.md).

Run DB migrations on each start. `localstorage` is MANDATORY for persistent data. General env vars: `CLOUDRON_APP_ORIGIN` (full URL), `CLOUDRON_APP_DOMAIN` (domain only), `CLOUDRON=1`.

**Memory limits** (`memoryLimit` in bytes: 256MB=268435456, 512MB=536870912, 1GB=1073741824): Static/PHP 128-256 MB, Node/Go/Rust 256-512 MB, PHP+workers/Python/Ruby 512-768 MB, Java/JVM 1024+ MB.

**Dynamic worker count from memory limit** (matches upstream Cloudron skill: 1 worker per 150 MB, clamped 1-8):

```bash
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    mem=$(cat /sys/fs/cgroup/memory.max)
    [[ "$mem" == "max" ]] && mem=$((2 * 1024 * 1024 * 1024))
else
    mem=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
fi
workers=$(( mem / 1024 / 1024 / 150 ))      # 1 worker per 150MB
workers=$(( workers > 8 ? 8 : workers ))    # cap at 8
workers=$(( workers < 1 ? 1 : workers ))    # floor at 1
```

**TCP/UDP ports**: Declare in `tcpPorts` manifest field; exposed as env vars (e.g., `XMPP_C2S_PORT`). Apps handle their own TLS termination.

**9.1+ features**: `persistentDirs` (persist dirs without `localstorage`), `backupCommand`/`restoreCommand` (custom backup), SQLite backup: `"localstorage": { "sqlite": { "paths": ["/app/data/db/app.db"] } }`.

## Dockerfile Patterns

```dockerfile
FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx php8.2-fpm php8.2-mysql \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/code
COPY --chown=cloudron:cloudron . /app/code/

# Preserve defaults for first-run initialization
RUN mkdir -p /app/code/defaults && \
    mv /app/code/config /app/code/defaults/config 2>/dev/null || true && \
    mv /app/code/storage /app/code/defaults/storage 2>/dev/null || true

COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh
EXPOSE 8000
CMD ["/app/code/start.sh"]
```

**Runtime-specific patterns:**

- **PHP**: Redirect temp paths to `/run`: `RUN rm -rf /var/lib/php/sessions && ln -s /run/php/sessions /var/lib/php/sessions`. FPM pool: `php_value[session.save_path] = /run/php/sessions`. In start.sh: `mkdir -p /run/php/sessions /run/php/uploads /run/php/tmp`.
- **Node.js**: `RUN npm ci --production && npm cache clean --force` + `ENV NODE_ENV=production`. Keep `node_modules` in `/app/code`.
- **Python**: `ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1` + `RUN pip install --no-cache-dir -r requirements.txt`.

**nginx** — writable temp paths required (fails to start without):

```nginx
client_body_temp_path /run/nginx/client_body;
proxy_temp_path /run/nginx/proxy;
fastcgi_temp_path /run/nginx/fastcgi;
server {
    listen 8000;
    root /app/code/public;
    location / { try_files $uri $uri/ /index.php?$query_string; }
}
```

In start.sh: `mkdir -p /run/nginx/client_body /run/nginx/proxy /run/nginx/fastcgi`

**Apache**:

```dockerfile
RUN rm /etc/apache2/sites-enabled/* \
    && sed -e 's,^ErrorLog.*,ErrorLog "/dev/stderr",' -i /etc/apache2/apache2.conf \
    && sed -e "s,MaxSpareServers[^:].*,MaxSpareServers 5," -i /etc/apache2/mods-available/mpm_prefork.conf \
    && a2disconf other-vhosts-access-log \
    && echo "Listen 8000" > /etc/apache2/ports.conf
```

## start.sh Architecture

Single-process: `exec gosu cloudron:cloudron <cmd>` directly. Multi-process: supervisord. Web servers managing own children (Apache, nginx): direct exec.

```bash
#!/bin/bash
set -eu
FIRST_RUN=false; [[ ! -f /app/data/.initialized ]] && FIRST_RUN=true

mkdir -p /app/data/config /app/data/storage /app/data/logs /run/app /run/php /run/nginx
ln -sfn /app/data/config /app/code/config
ln -sfn /app/data/storage /app/code/storage
ln -sfn /app/data/logs /app/code/logs

[[ "$FIRST_RUN" == "true" ]] && cp -rn /app/code/defaults/config/* /app/data/config/ 2>/dev/null || true

# Config injection (choose one):
# A: envsubst < /app/code/config.template > /app/data/config/app.conf
# B: sed -i "s|APP_URL=.*|APP_URL=${CLOUDRON_APP_ORIGIN}|" /app/data/config/.env

sed -i "s|'auto_update' => true|'auto_update' => false|" /app/data/config/settings.php 2>/dev/null || true
gosu cloudron:cloudron /app/code/bin/migrate --force
chown -R cloudron:cloudron /app/data /run/app
touch /app/data/.initialized
exec gosu cloudron:cloudron node /app/code/server.js
```

**Multi-process supervisord.conf** (repeat `[program:*]` for each process):

```ini
[supervisord]
nodaemon=true
logfile=/dev/stdout
logfile_maxbytes=0
pidfile=/run/supervisord.pid

[program:web]
command=/app/code/bin/web-server
directory=/app/code
user=cloudron
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
```

End of start.sh: `exec /usr/bin/supervisord --configuration /app/code/supervisord.conf`

## Message Broker

No AMQP addon in Cloudron. Two options:

**Option A: Redis (preferred)** — if app supports Redis as broker (Celery does natively):

```python
CELERY_BROKER_URL = os.environ['CLOUDRON_REDIS_URL']
CELERY_RESULT_BACKEND = os.environ['CLOUDRON_REDIS_URL']
```

**Option B: LavinMQ** — lightweight AMQP (~40 MB RAM, drop-in RabbitMQ replacement). Store data under `/app/data/lavinmq`, run as Supervisor program:

```dockerfile
RUN curl -fsSL https://packagecloud.io/cloudamqp/lavinmq/gpgkey | gpg --dearmor -o /usr/share/keyrings/lavinmq.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/lavinmq.gpg] https://packagecloud.io/cloudamqp/lavinmq/ubuntu/ noble main" \
    > /etc/apt/sources.list.d/lavinmq.list && \
    apt-get update && apt-get install -y lavinmq && rm -rf /var/cache/apt /var/lib/apt/lists/*
```

## Common Anti-Patterns

| Anti-pattern | Wrong | Correct |
|---|---|---|
| Missing `exec` in gosu | `gosu cloudron:cloudron node server.js` | `exec gosu cloudron:cloudron node server.js` |
| Non-idempotent start.sh | `cp config.json /app/data/` | `cp -n config.json /app/data/ 2>/dev/null \|\| true` |
| Hardcoded URLs | `"https://myapp.example.com"` | `process.env.CLOUDRON_APP_ORIGIN` |

## Upgrade & Migration

Track version in `/app/data/.app_version`; compare on start to run per-version migration blocks. Migrations MUST be idempotent — use framework migration tracking (Laravel, Django, Rails) or raw SQL with `CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`.

## Managed Package Lifecycle

`aidevops init` detects `CloudronManifest.json`, records
`app_type: cloudron-package` in local `repos.json`, and installs the thin
`.github/workflows/cloudron-package-release.yml` caller when no file already
exists. Configure `cloudron_package.upstream_slug` locally to enable stable-release
comparison. `cloudron_package.upstream_tag_prefixes` defaults to `["v", ""]`,
covering `v1.2.3` and bare `1.2.3` tags. Set a product stream such as
`["desktop-v"]` when a shared upstream publishes tags like `desktop-v0.5.3`;
unrelated `v...` releases are then ignored. The monitor paginates the GitHub
releases API, excludes drafts and prereleases, validates the version remaining
after a configured prefix, and selects the numerically highest matching stable
semantic release. Invalid prefix configuration and repositories with no matching
stable tag fail closed. Compatibility monitoring is enabled by default.
The generated caller pins both the reusable workflow and checked-out validator
to the same full framework commit. Updating that revision is an explicit,
reviewed package change; repeated init never overwrites an existing caller.

Prepare and validate releases without publishing:

```bash
cloudron-package-helper.sh prepare-release 1.2.0 4.5.6 release-notes.md
cloudron-package-helper.sh check-compatibility
cloudron-package-helper.sh check-release v1.2.0
```

`prepare-release` validates first, then updates `CloudronManifest.json` and
inserts a non-empty `CHANGELOG.md` section with rollback on a partial write.
`check-release` requires a matching `vX.Y.Z` tag, valid manifest, non-empty
changelog entry, and the exact pinned final Cloudron base image.

Core routines provide ongoing reporting:

- `r916` runs `cloudron-package-monitor-helper.sh upstream --apply` daily at
  `01:30 UTC` using its version-controlled per-routine timezone override.
- `r917` runs `cloudron-package-monitor-helper.sh compatibility --apply` weekly.

Both routines deduplicate package-local issues, require maintainer-equivalent
issue authority, and fail closed on GitHub/API errors. They never execute
upstream instructions or modify package source.
When GitHub reports a primary or secondary rate limit, `r916` stops before the
next package registration and records a reset-aware deferred attempt. Pulse
retries after the shared cooldown boundary plus bounded jitter instead of using
the generic 15-minute failure retry.

**Publication boundary:** pushing a `vX.Y.Z` tag is the explicit trigger for the
managed caller to validate and create a GitHub release. Tag creation, image
pushes, Cloudron catalog publication, and deployment remain separate operator
actions and require explicit authorization.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| App won't start | `cloudron logs --app testapp` / `cloudron debug --app testapp` |
| Permission denied | `chown -R cloudron:cloudron /app/data` — check for writes to `/app/code` |
| DB connection fails | Verify addon in manifest; `cloudron exec --app testapp` → `env \| grep CLOUDRON` |
| Health check fails | `curl -v http://localhost:8000/health` — verify app listens on httpPort |
| Memory exceeded | Increase `memoryLimit`; check for leaks; optimize worker counts |

## Validation Checklist

```text
[ ] Fresh install + restart (cloudron restart --app) succeed
[ ] Health check returns 200
[ ] File uploads persist across restarts
[ ] Database connections work; email works (if applicable)
[ ] Memory stays within limit
[ ] Upgrade from previous version works
[ ] Backup/restore cycle works
[ ] Auto-updater disabled; logs stream to stdout/stderr
```

## Publishing

Independent/community packages publish registry images through a hosted
`CloudronVersions.json`; they are not submitted by forking the official app
store. Before considering a package complete, initialize the catalog, add the
required `iconUrl`/packager/media metadata, keep a local 256×256 icon and a
privacy-reviewed screenshot or 3:1 hero, and document the release workflow.
Follow `cloudron-app-publishing-skill.md` for testing-state promotion,
append-only catalog maintenance, revocation, public hosting, and optional
listing on [Cloudron Community Apps](https://ca.cloudron.io).
