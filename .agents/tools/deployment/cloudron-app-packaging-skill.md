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
- **Last upstream review**: `fcea39616e6e` ("Update the skill for cloudron sync"); no local import changes required beyond keeping the native guide and skill pointers aligned.

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

```dockerfile
FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c
RUN mkdir -p /app/code
WORKDIR /app/code
COPY . /app/code/
RUN ln -sf /run/app/config.json /app/code/config.json
RUN chmod +x /app/code/start.sh
CMD [ "/app/code/start.sh" ]
```

**Base image requirement:** the final stage MUST use the SHA-pinned `cloudron/base:5.0.0` tag above. Platform tooling (file manager, web terminal, log viewer) depends on utilities provided by this base image. Multi-stage builds are fine for compilation, but the final stage always lands on pinned `cloudron/base`. Current SHA tracked at [hub.docker.com/r/cloudron/base/tags](https://hub.docker.com/r/cloudron/base/tags).

Multi-stage builds are acceptable for compilation, asset bundling, or other build-time work. Only the final stage must use the pinned Cloudron base image.

```dockerfile
FROM node:20 AS build
WORKDIR /build
COPY . .
RUN npm ci && npm run build

FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c
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
- **Build service**: `cloudron build login` sends source to a remote Docker Builder app; use `cloudron build logs --id <id>`, `cloudron build status --id <id>`, and `cloudron build push --id <id>` for remote builds.

Use `cloudron build reset` to clear saved repository/image info.

## Examples

Published apps are open source: https://git.cloudron.io/packages. Browse by framework: [PHP](https://git.cloudron.io/explore/projects?tag=php) | [Node](https://git.cloudron.io/explore/projects?tag=node) | [Python](https://git.cloudron.io/explore/projects?tag=python) | [Ruby/Rails](https://git.cloudron.io/explore/projects?tag=rails) | [Java](https://git.cloudron.io/explore/projects?tag=java) | [Go](https://git.cloudron.io/explore/projects?tag=go) | [Rust](https://git.cloudron.io/explore/projects?tag=rust)
