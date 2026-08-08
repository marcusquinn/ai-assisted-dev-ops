---
name: cloudron-app-packaging
description: "Official Cloudron app packaging skill - Dockerfile patterns, manifest, addons, build methods"
mode: subagent
imported_from: external
tools:
  read: true
  write: true
  edit: true
  bash: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudron App Packaging (Official Skill)

Cloudron apps are Docker images plus `CloudronManifest.json`. The platform provides a readonly filesystem, addon services, and a managed backup/restore lifecycle.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Upstream**: [git.cloudron.io/docs/skills](https://git.cloudron.io/docs/skills) (`cloudron-app-packaging`) | [docs.cloudron.io/packaging](https://docs.cloudron.io/packaging/)
- **Reference files**: `cloudron-app-packaging-skill/manifest-ref.md`, `cloudron-app-packaging-skill/addons-ref.md`
- **Also see**: `cloudron-app-packaging.md` (native aidevops guide: helpers, local dev, Dockerfile/start.sh patterns, pre-packaging checks) and `cloudron-app-publishing-skill.md` (required version catalog, public metadata, keyless image/catalog provenance, visual assets, and publication lifecycle)
- **Last upstream review**: `f35dab45cc31` ("backupCommand, restoreCommand skill"); adopted current base-image, Node PATH, PHP, builder, and backup/restore lifecycle guidance.

```bash
npm install -g cloudron
cloudron login my.example.com
cloudron init                    # creates CloudronManifest.json and Dockerfile
cloudron install                 # uploads source, builds on server, installs app
cloudron update                  # re-uploads, rebuilds, updates running app
# For any independently distributed package, initialize and maintain
# CloudronVersions.json and keyless release provenance using
# cloudron-app-publishing-skill.md.
```

<!-- AI-CONTEXT-END -->

## Key Constraints

| Constraint | Detail |
|------------|--------|
| Filesystem readonly | Writable: `/tmp`, `/run` (ephemeral), `/app/data` (persisted, requires `localstorage` addon) |
| Addons for services | Databases, caching, email, auth via addons — env vars injected at runtime, re-read every start |
| Manifest declares all | `CloudronManifest.json`: metadata, ports, addon requirements |
| HTTP only | App listens HTTP — platform handles TLS |
| Memory default | 256 MB (RAM + swap). Set `memoryLimit` in manifest |

## Build Methods (9.1+)

| Method | Command | Notes |
|--------|---------|-------|
| On-server (default) | `cloudron install` / `cloudron update` | Uploads source, builds on server, and rebuilds from backed-up source on restore |
| Local Docker | `cloudron build` → `cloudron install` / `cloudron update` | Requires `docker login` |
| Build service | `cloudron build login` → `cloudron build` | Sends source to a remote builder |

## Dockerfile & `start.sh`

Use `Dockerfile`, `Dockerfile.cloudron`, or `cloudron/Dockerfile`. See `cloudron-app-packaging.md` "Dockerfile Patterns" for stack-specific variants.

### Base images

| App type | Image | Notes |
|----------|-------|-------|
| Non-PHP | `cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e` | No PHP. Node is at `/usr/local/node-24.19.0` and is not on `PATH`. |
| PHP 8.5 | `cloudron/php-base:8.5@sha256:6212759b8992bb2c09083c6ef12fa7a2bb75c13c9aa77a3dd94f593a5b63e1dd` | Prefer when the app supports PHP 8.5. |
| PHP 8.4 | `cloudron/php-base:8.4@sha256:365607342e6b50f4f53d9b524313df4bfe654596baf762ee2e5af58c3498aa4b` | Use when the app is not ready for PHP 8.5. |

For Node apps using `cloudron/base`, set:

```dockerfile
ENV PATH=/usr/local/node-24.19.0/bin:$PATH
```

### Non-PHP structure

```dockerfile
FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e
ENV PATH=/usr/local/node-24.19.0/bin:$PATH
RUN mkdir -p /app/code
WORKDIR /app/code
COPY . /app/code/
RUN ln -sf /run/app/config.json /app/code/config.json
RUN chmod +x /app/code/start.sh
CMD [ "/app/code/start.sh" ]
```

### PHP structure

```dockerfile
FROM cloudron/php-base:8.5@sha256:6212759b8992bb2c09083c6ef12fa7a2bb75c13c9aa77a3dd94f593a5b63e1dd
RUN mkdir -p /app/code
WORKDIR /app/code
RUN a2enmod rewrite php8.5
CMD [ "/app/code/start.sh" ]
```

**Base image requirement:** the final stage MUST use a SHA-pinned `cloudron/base` image, or `cloudron/php-base` for PHP apps. Platform tooling (file manager, web terminal, log viewer) depends on utilities provided by these images. Current non-PHP SHA is tracked at [hub.docker.com/r/cloudron/base/tags](https://hub.docker.com/r/cloudron/base/tags).

Multi-stage builds are acceptable for compilation, asset bundling, or other build-time work. Only the final stage must use the applicable pinned Cloudron base image.

```dockerfile
FROM node:20 AS build
WORKDIR /build
COPY . .
RUN npm ci && npm run build

FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e
ENV PATH=/usr/local/node-24.19.0/bin:$PATH
RUN mkdir -p /app/code
WORKDIR /app/code
COPY --from=build /build/dist /app/code/dist
COPY start.sh /app/code/
RUN chmod +x /app/code/start.sh
CMD [ "/app/code/start.sh" ]
```

### `start.sh` Conventions

- Drop privileges: `exec gosu cloudron:cloudron <cmd>` (e.g. `exec gosu cloudron:cloudron node /app/code/server.js`)
- Reset ownership on every start: `chown -R cloudron:cloudron /app/data`
- Gate first-run setup: `if [[ ! -f /app/data/.initialized ]]; then ...; touch /app/data/.initialized; fi`
- Log to stdout/stderr; fallback logs: `/run/<subdir>/*.log` (two levels deep, autorotated)
- Multiple processes: use `supervisor` or `pm2`; see `cloudron-app-packaging.md` "start.sh Architecture"
- Run database migrations on each start; addon env vars can change across restarts.

### Writable directories

| Path | Persists across restarts | Backed up |
|------|--------------------------|-----------|
| `/tmp` | No | No |
| `/run` | No | No |
| `/app/data` | Yes | Yes (requires `localstorage` addon) |

Put generated runtime config in `/run`. Put persistent user/app data in `/app/data`.

### Memory-aware worker count

```bash
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    memory_limit=$(cat /sys/fs/cgroup/memory.max)
    [[ "${memory_limit}" == "max" ]] && memory_limit=$((2 * 1024 * 1024 * 1024))
else
    memory_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
fi
worker_count=$((memory_limit / 1024 / 1024 / 150))
worker_count=$((worker_count > 8 ? 8 : worker_count))
worker_count=$((worker_count < 1 ? 1 : worker_count))
```

## Manifest Essentials

```json
{
  "id": "com.example.myapp",
  "title": "My App",
  "author": "Jane Developer <jane@example.com>",
  "version": "1.0.0",
  "healthCheckPath": "/",
  "httpPort": 8000,
  "addons": { "localstorage": {} },
  "manifestVersion": 2
}
```

Common fields beyond the minimum:

| Field | Purpose |
|-------|---------|
| `memoryLimit` | Max memory in bytes (default 256 MB) |
| `tcpPorts` / `udpPorts` | Non-HTTP port bindings exposed to the user |
| `httpPorts` | Additional HTTP services on secondary domains |
| `multiDomain` | Enable alias domains |
| `optionalSso` | Allow install without user management |
| `configurePath` | Admin panel path shown in dashboard |
| `postInstallMessage` | Markdown shown after install (supports `<sso>`/`<nosso>` tags) |
| `minBoxVersion` | Minimum platform version required |
| `runtimeDirs` | Writable subdirs of `/app/code` (not backed up, not persisted across updates) |
| `persistentDirs` | Writable dirs persisted across updates but not in filesystem backup; pair with `backupCommand` |
| `backupCommand` / `restoreCommand` | Dump/restore `persistentDirs` into/from `/app/data` during backup/restore |

Full field reference: [manifest-ref.md](cloudron-app-packaging-skill/manifest-ref.md).

## Addons

| Addon | Provides | Key env var |
|-------|----------|-------------|
| `localstorage` | Writable `/app/data` + backup | -- |
| `mysql` | MySQL 8.0 | `CLOUDRON_MYSQL_URL` |
| `postgresql` | PostgreSQL 14.9 | `CLOUDRON_POSTGRESQL_URL` |
| `mongodb` | MongoDB 8.0 | `CLOUDRON_MONGODB_URL` |
| `redis` | Redis 8.4 (persistent) | `CLOUDRON_REDIS_URL` |
| `ldap` / `oidc` | LDAP v3 / OpenID Connect auth | `CLOUDRON_LDAP_URL` / `CLOUDRON_OIDC_DISCOVERY_URL` |
| `sendmail` / `recvmail` | Outgoing SMTP / Incoming IMAP | `CLOUDRON_MAIL_SMTP_SERVER` / `CLOUDRON_MAIL_IMAP_SERVER` |
| `email` | Full SMTP + IMAP + ManageSieve | multiple |
| `proxyauth` | Auth wall | -- |
| `scheduler` | Cron tasks | -- |
| `tls` | App certificate files | `/etc/certs/tls_cert.pem` |
| `turn` | STUN/TURN service | `CLOUDRON_TURN_SERVER` |
| `docker` | Create containers (restricted) | `CLOUDRON_DOCKER_HOST` |

Full env var lists and options: [addons-ref.md](cloudron-app-packaging-skill/addons-ref.md).

## Stack Notes

| Stack | Notes |
|-------|-------|
| Apache | Disable default sites, `Listen 8000`, send errors to stderr, `exec /usr/sbin/apache2 -DFOREGROUND` |
| Nginx | Put temp paths in `/run/` (`client_body_temp_path`, `proxy_temp_path`) and run with supervisor |
| PHP | Symlink sessions to `/run/php/sessions` |
| Java | Read the cgroup memory limit and set `-XX:MaxRAM` |

## Debugging

```bash
cloudron logs [-f]       # view/follow logs
cloudron exec            # shell into app
cloudron debug           # pause app (read-write fs)
cloudron debug --disable # exit debug mode
```

## Build Methods

- **On-server (default)**: `cloudron install` and `cloudron update` upload source and build on the server. No local Docker required; simplest workflow, but it uses server CPU/RAM.
- **Local Docker**: `cloudron build` builds/tags/pushes locally, then `cloudron install` / `cloudron update` detects the built image. Requires Docker and registry auth.
- **Build service**: `cloudron build login` sends source to a remote builder, normally a [Container registry](https://docs.cloudron.io/packages/container-registry/) app; legacy Docker Builder installations remain supported. Use `cloudron build logs --id <id>`, `cloudron build status --id <id>`, and `cloudron build push --id <id>` for remote builds.

Use `cloudron build reset` to clear saved repository/image info.

## Examples

Published apps are open source: https://git.cloudron.io/packages. Browse by framework: [PHP](https://git.cloudron.io/explore/projects?tag=php) | [Node](https://git.cloudron.io/explore/projects?tag=node) | [Python](https://git.cloudron.io/explore/projects?tag=python) | [Ruby/Rails](https://git.cloudron.io/explore/projects?tag=rails) | [Java](https://git.cloudron.io/explore/projects?tag=java) | [Go](https://git.cloudron.io/explore/projects?tag=go) | [Rust](https://git.cloudron.io/explore/projects?tag=rust)
