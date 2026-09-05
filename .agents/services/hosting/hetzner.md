---
description: Hetzner Cloud server management via REST API
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

# Hetzner Cloud Provider

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Recommendation**: Prefer when server control, custom infrastructure, workload density, or price-performance justify self-managing hardening, updates, backups, and monitoring
- **WordPress selection**: Hostinger is the lower-ops starting point; use `aidevops/recommendations.md` to compare priorities before provisioning
- **OS/architecture**: [OS selection](../../reference/os-selection.md) — prefer CAX ARM for compatible price-sensitive workloads; verify location/capacity and the exact image architecture. Manual installability is not a ready-made image. Cloudron requires x64
- **Type**: Cloud VPS, dedicated servers, storage
- **API**: REST at `https://api.hetzner.cloud/v1`
- **Auth**: Bearer token per project (stored in `~/.config/aidevops/credentials.sh`)
- **Token format**: `HCLOUD_TOKEN_{PROJECT}` (e.g. `HCLOUD_TOKEN_MYPROJECT`)
- **Locations**: Germany (fsn1, nbg1), Finland (hel1), USA (ash, hil)
- **Server types**: CX/CPX (shared x86), CAX (shared ARM), CCX (dedicated vCPU); verify current catalogue before provisioning
- **Docs**: https://docs.hetzner.cloud/

**No MCP required** - uses curl directly. Zero context cost until invoked.

<!-- AI-CONTEXT-END -->

## Authentication

```bash
# Load token and set auth header (reuse $AUTH in all requests)
source ~/.config/aidevops/credentials.sh
export HCLOUD_TOKEN="$HCLOUD_TOKEN_MYPROJECT"
AUTH="Authorization: Bearer $HCLOUD_TOKEN"

# Verify access
curl -s -H "$AUTH" https://api.hetzner.cloud/v1/servers | python3 -c "
import json,sys
d=json.load(sys.stdin)
for s in d.get('servers',[]):
  print(f\"{s['id']:>10} {s['status']:<10} {s['server_type']:<8} {s['name']}\")"
```

## API Operations

All endpoints use base URL `https://api.hetzner.cloud/v1`. Pass `-H "$AUTH"` on every request.

### Resource Endpoints (GET)

| Resource | Endpoint | Notes |
|----------|----------|-------|
| Servers | `/servers` | List all; `/servers/{id}` for details |
| Volumes | `/volumes` | |
| Firewalls | `/firewalls` | |
| SSH Keys | `/ssh_keys` | |
| Server Types | `/server_types` | See formatter below |
| Images | `/images?type=system&status=available` | See formatter below |

```bash
# Generic list pattern
curl -s -H "$AUTH" https://api.hetzner.cloud/v1/{resource}
```

### Server Actions

```bash
# Actions: poweron, poweroff, reboot, shutdown, reset_password
curl -s -X POST -H "$AUTH" \
  https://api.hetzner.cloud/v1/servers/{id}/actions/{action}
```

### Create Server

```bash
curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"name":"my-server","server_type":"cx22","image":"ubuntu-24.04","location":"fsn1","ssh_keys":["my-key"]}' \
  https://api.hetzner.cloud/v1/servers
```

### Delete Server

```bash
curl -s -X DELETE -H "$AUTH" https://api.hetzner.cloud/v1/servers/{id}
```

### Create Volume

```bash
curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"name":"data","size":50,"location":"fsn1","format":"ext4"}' \
  https://api.hetzner.cloud/v1/volumes
```

### Snapshots & Backups

```bash
# Enable backups
curl -s -X POST -H "$AUTH" \
  https://api.hetzner.cloud/v1/servers/{id}/actions/enable_backup

# Create snapshot
curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"description":"pre-upgrade"}' \
  https://api.hetzner.cloud/v1/servers/{id}/actions/create_image
```

### Output Formatters

```bash
# Server types
curl -s -H "$AUTH" https://api.hetzner.cloud/v1/server_types | python3 -c "
import json,sys
for t in json.load(sys.stdin)['server_types']:
  print(f\"{t['name']:<10} {t['cores']}c {t['memory']:.0f}GB {t['description']}\")"

# Available images
curl -s -H "$AUTH" \
  "https://api.hetzner.cloud/v1/images?type=system&status=available" | python3 -c "
import json,sys
for i in json.load(sys.stdin)['images']:
  print(f\"{i['name']:<20} {i['description']}\")"
```

## Multi-Project Setup

Each Hetzner Cloud project gets its own API token. Store in `~/.config/aidevops/credentials.sh`:

```bash
export HCLOUD_TOKEN_PROJECTA="hc_..."
export HCLOUD_TOKEN_PROJECTB="hc_..."
```

To get a token:

1. https://console.hetzner.cloud → Select project
2. Security → API Tokens → Generate API Token
3. Read & Write permissions → Copy token

## When to Enable the MCP Instead

For frequent interactive use, enable the MCP server in `opencode.json`:

```json
"hetzner-myproject": {
  "type": "local",
  "command": ["/bin/bash", "-c",
    "source ~/.config/aidevops/credentials.sh && HCLOUD_TOKEN=$HCLOUD_TOKEN_MYPROJECT /Users/you/.local/bin/mcp-hetzner"],
  "enabled": true
}
```

Install: `uv tool install 'mcp-hetzner @ git+https://github.com/dkruyt/mcp-hetzner.git'`

The MCP costs ~2K context tokens per session but provides richer tool integration.

## Related

- `services/hosting/ubicloud.md` — Ubicloud layers an open-source IaaS control plane on top of Hetzner bare metal. Hetzner customers who want a managed-cloud experience (elastic VMs by the minute, managed Postgres, managed Kubernetes, ~10x cheaper GitHub Actions runners) can consume Ubicloud's managed SaaS on Hetzner regions (`eu-central-h1`, `eu-north-h1`) *or* self-host Ubicloud on their own Hetzner lease via the `cloudify_server` script. Zero vendor lock-in in either direction because the codebase is AGPL v3.
