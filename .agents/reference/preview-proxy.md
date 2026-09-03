<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Preview Proxy — Per-Worktree Preview Subdomains

Design: GH#21560

## Problem

Interactive AI sessions create worktrees for all code changes (`~/Git/_worktrees/[<owner>-]<repo>-<branch>/` by default), keeping the canonical repo on the default branch. The user's local dev server is typically pinned to the canonical directory. Changes in a worktree are invisible until the PR merges or the user manually restarts the dev server from the worktree path.

## Solution

A "preview proxy" capability that allocates a unique port per worktree branch and optionally registers a proxy route so every worktree dev server gets its own subdomain:

```text
Worktree:   ~/Git/<webapp>-feature-tNNN-…/
Preview:    https://<branch-slug>.<webapp>.local (port 3142)
Start dev:  AIDEVOPS_PREVIEW_PORT=3142 pnpm dev:web
```

## Architecture

```text
worktree-helper.sh add
  └─ preview_proxy_auto_allocate()        # best-effort, non-fatal
       └─ preview-proxy-helper.sh allocate <slug> <branch>
            ├─ Find free port (pool → global overflow)
            ├─ Write to ~/.aidevops/state/worktree-ports.json
            └─ Backend dispatch (optional)
                 └─ traefik-file.sh pp_backend_register()
                      └─ Write YAML to ~/.local-dev-proxy/dynamic/

worktree-helper.sh remove
  └─ preview_proxy_auto_free()            # best-effort, non-fatal
       └─ preview-proxy-helper.sh free <slug> <branch>
            ├─ Remove from worktree-ports.json
            └─ Backend dispatch (optional)
                 └─ traefik-file.sh pp_backend_deregister()
                      └─ Remove YAML from ~/.local-dev-proxy/dynamic/
```

## Components

| Component | Path | Purpose |
|-----------|------|---------|
| Port allocator | `.agents/scripts/preview-proxy-helper.sh` | Allocates ports, manages state, dispatches backends |
| Traefik backend | `.agents/scripts/preview-proxy-backends/traefik-file.sh` | Writes/removes Traefik v3 dynamic config YAML |
| State file | `~/.aidevops/state/worktree-ports.json` | Port allocation registry |
| Config file | `~/.config/aidevops/preview-proxy.json` | Backend selection, domain template, port pools |

## Port Allocation

- **Project pool**: 3100-3199 (configurable per repo slug)
- **Global overflow**: 3200-3999 (when project pool exhausted)
- Collision detection: `lsof -ti:<port>` before assigning
- Idempotent: re-allocating the same repo+branch returns the existing allocation

## Branch-Slug Sanitization

Branch names are sanitized to DNS-safe subdomain labels:

1. Strip common prefixes (`feature/`, `bugfix/`, `hotfix/`, etc.)
2. Lowercase
3. Replace `[^a-z0-9-]` with `-`
4. Collapse repeated hyphens, trim leading/trailing
5. Truncate to 63 chars (DNS label max); append 4-char hash on collision

Examples:

- `feature/t2999-nav-reorder-tasks-ai` -> `t2999-nav-reorder-tasks-ai`
- `fix/t3001-broken-snapshots` -> `t3001-broken-snapshots`
- `feature/auto-20260429-042841-gh21560` -> `auto-20260429-042841-gh21560`

## Configuration

### Optional: `~/.config/aidevops/preview-proxy.json`

```json
{
  "backend": "traefik-file",
  "config_dir": "/Users/<user>/.local-dev-proxy/dynamic/",
  "domain_template": "{branch_slug}.{repo}.local",
  "port_pool": {
    "default": [3100, 3199],
    "owner/webapp": { "start": 3100, "end": 3149 }
  }
}
```

Without this file, the helper allocates ports and falls back to `http://localhost:<port>`.

### Optional: `.aidevops.json` (per-project)

```json
{
  "preview": {
    "command": "pnpm dev:web",
    "port_env": "PORT",
    "default_port": 3100,
    "ready_check": "http://127.0.0.1:{port}/api/health"
  }
}
```

When present, the helper emits a project-specific start hint (e.g., `PORT=3142 pnpm dev:web`).

## Setup: Traefik Backend

### 1. Traefik with file provider

The Traefik backend writes dynamic YAML configs that Traefik hot-reloads. A typical `docker-compose.yml` for `~/.local-dev-proxy/`:

```yaml
services:
  traefik:
    image: traefik:v3
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./dynamic:/etc/traefik/dynamic:ro
      - ./certs:/etc/traefik/certs:ro
    restart: unless-stopped
```

With `traefik.yml`:

```yaml
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
  websecure:
    address: ":443"

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

tls:
  certificates:
    - certFile: /etc/traefik/certs/local.pem
      keyFile: /etc/traefik/certs/local-key.pem
```

### 2. HTTPS with mkcert

```bash
brew install mkcert
mkcert -install
mkcert -cert-file ~/.local-dev-proxy/certs/local.pem \
       -key-file ~/.local-dev-proxy/certs/local-key.pem \
       "*.myapp.local" "myapp.local"
```

### 3. DNS: wildcard *.local

**Option A: /etc/hosts** (per-subdomain, manual):

```text
127.0.0.1  myapp.local
127.0.0.1  t2999-nav-reorder.myapp.local
```

**Option B: dnsmasq** (wildcard, automatic):

```bash
brew install dnsmasq
echo 'address=/.local/127.0.0.1' >> "$(brew --prefix)/etc/dnsmasq.conf"
sudo brew services start dnsmasq
sudo mkdir -p /etc/resolver
echo 'nameserver 127.0.0.1' | sudo tee /etc/resolver/local
```

## CLI Usage

```bash
# Manual allocation
preview-proxy-helper.sh allocate owner/repo feature/t2999-foo
# → {"port": 3100, "url": "https://t2999-foo.repo.local", "start_hint": "..."}

# Manual free
preview-proxy-helper.sh free owner/repo feature/t2999-foo

# List allocations
preview-proxy-helper.sh list
preview-proxy-helper.sh list owner/repo

# Status
preview-proxy-helper.sh status
```

## Automatic Integration

When `worktree-helper.sh add` creates a worktree, it automatically calls `preview_proxy_auto_allocate` and outputs the preview URL + start hint. When `worktree-helper.sh remove` removes a worktree, it calls `preview_proxy_auto_free`. Both are best-effort and non-fatal — missing helper or config silently skip.

## Backends

### traefik-file (default backend)

Writes YAML files to the Traefik dynamic config directory. Traefik hot-reloads them.

### Adding a new backend

1. Create `.agents/scripts/preview-proxy-backends/<name>.sh`
2. Implement `pp_backend_register <repo_slug> <branch_slug> <port>` and `pp_backend_deregister <repo_slug> <branch_slug>`
3. Set `"backend": "<name>"` in `preview-proxy.json`

Planned backends (out of scope for v1):

- **caddy**: Caddy on-demand TLS
- **nginx**: Nginx reverse proxy
- **cloudflare-tunnel**: Remote previews via Cloudflare Tunnel

## Limitations (v1)

- One preview per worktree (no multi-process apps)
- Does not auto-start the dev server (prints the start hint)
- HTTPS cert auto-issue via mkcert is manual setup
- macOS first; Linux should work but is untested
