---
description: Matrix bot integration for dispatching messages to AI runners
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Matrix Bot Integration

## Quick Reference

- **Purpose**: Bridge Matrix rooms to aidevops runners via OpenCode with entity-aware context
- **Script**: `matrix-dispatch-helper.sh [setup|start|stop|status|map|unmap|mappings|sessions|test|logs|cleanup-invites]`
- **Config**: `~/.config/aidevops/matrix-bot.json` (600 permissions)
- **Data**: `~/.aidevops/.agent-workspace/matrix-bot/`
- **Session DB**: `~/.aidevops/.agent-workspace/memory/memory.db` (shared entity tables, SQLite WAL)
- **Entity helper**: `entity-helper.sh` (identity resolution, Layer 0/1 interaction logging)
- **SDK**: `matrix-bot-sdk`, `better-sqlite3` (npm); Node.js >= 18, jq, OpenCode server, Matrix homeserver

## Architecture

```text
Matrix Room --> Matrix Bot --> OpenCode / runner-helper.sh --> AI session
                    |
                    v
              memory.db (shared)
              +-- entities / entity_channels / entity_profiles  (Layer 2)
              +-- interactions      (Layer 0: immutable log)
              +-- conversations     (Layer 1: summaries)
              +-- matrix_room_sessions
```

**Message flow**: `!ai <prompt>` → pure core-v1 normalization → permission/room-to-runner evidence → durable event claim → entity resolution → L0 log → load exact room+actor context (L2 profile + L1 summary + L0 recent) → dispatch → post response + reaction.

**Session lifecycle**: First accepted room+actor event creates a session and durable receipt (L0 immutable log) → idle for `sessionIdleTimeout` → AI summarises to L1 (L0 never deleted) → next message from the same room+actor is primed with profile + summary → actor/runner changes clear mutable upstream state → SIGINT/SIGTERM compacts active sessions before exit.

## Setup

**Prerequisites**: Matrix homeserver (Synapse recommended), bot account + access token, OpenCode server, at least one runner. Dry-run: `matrix-dispatch-helper.sh setup --dry-run`.

### Cloudron (Recommended)

```bash
# 1. Install Synapse: Dashboard > App Store > Matrix Synapse > Install
# 2. Create bot user (App > Terminal):
/app/code/env/bin/register_new_matrix_user -c /app/data/configs/homeserver.yaml http://localhost:8008
# 3. Get access token:
curl -s -X POST "http://localhost:8008/_matrix/client/v3/login" \
  -H "Content-Type: application/json" \
  -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"aibot"},"password":"YOUR_PASSWORD"}' \
  | python3 -m json.tool   # copy access_token
# 4. homeserver.yaml: enable_registration: false, remove 'federation' from resources. Restart.
# 5. Create unencrypted rooms via Element (NOT FluffyChat -- forces encryption)
# 6. Configure + map + start:
matrix-dispatch-helper.sh setup
runner-helper.sh create code-reviewer --workdir ~/Git/myproject
matrix-dispatch-helper.sh map '!roomid:yourdomain.com' code-reviewer
matrix-dispatch-helper.sh start --daemon
```

**Stale invites** (bot crashes on startup): `matrix-dispatch-helper.sh cleanup-invites`

### Manual Synapse

```bash
register_new_matrix_user -c /etc/synapse/homeserver.yaml http://localhost:8008 \
  --user aibot --password "secure-password" --no-admin
curl -X POST "https://matrix.example.com/_matrix/client/v3/login" \
  -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"aibot"},"password":"secure-password"}' \
  | jq -r '.access_token'
```

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `homeserverUrl` | required | Matrix homeserver URL |
| `accessToken` | required | Bot's access token |
| `allowedUsers` | `""` (all) | Comma-separated allowed user IDs |
| `defaultRunner` | `""` | Runner for unmapped rooms |
| `roomMappings` | `{}` | Room ID -> runner name |
| `botPrefix` | `!ai` | Command prefix |
| `ignoreOwnMessages` | `true` | Ignore bot's own messages |
| `maxPromptLength` | `3000` | Max prompt length |
| `responseTimeout` | `600` | Max seconds to wait for runner |
| `sessionIdleTimeout` | `300` | Idle timeout before compaction |

## Usage

```bash
# Room-to-runner mapping
matrix-dispatch-helper.sh map '!dev-room:server' code-reviewer
matrix-dispatch-helper.sh mappings
matrix-dispatch-helper.sh unmap '!dev-room:server'

# Operations
matrix-dispatch-helper.sh start --daemon   # Background
matrix-dispatch-helper.sh start            # Foreground (debug)
matrix-dispatch-helper.sh stop
matrix-dispatch-helper.sh status
matrix-dispatch-helper.sh logs [--follow] [--tail 200]
matrix-dispatch-helper.sh test code-reviewer "Review src/auth.ts"

# Runners
runner-helper.sh create code-reviewer --description "Reviews code for security and quality"
runner-helper.sh edit code-reviewer

# Sessions
matrix-dispatch-helper.sh sessions list|stats
matrix-dispatch-helper.sh sessions clear '!room:server'
matrix-dispatch-helper.sh sessions clear-all
```

Trigger: `!ai <prompt>` in any mapped room. One dispatch per room prevents flooding; durable provider-event receipts prevent restart/redelivery duplicates; typing indicators, status reactions, auto-join, and isolated room+actor context remain supported.

## Entity Integration

**Resolution**: the provider sender ID—not its display name—selects `entity_channels`, creates an entity if needed, and is cached per process. Context per prompt: L2 profile → matching L1 room/conversation summary → L0 interactions matching entity + Matrix + room + conversation. Immutable historical interactions are preserved but broader legacy rows are not reused across rooms or actors.

**Storage** (`memory.db`, SQLite WAL): `matrix_room_sessions`, `matrix_event_receipts`, `interactions` (L0 immutable), `conversations` (L1 summaries), `entities`/`entity_channels`/`entity_profiles` (L2 identity). Session schema changes are additive; legacy rows remain readable and are rebound before reuse.

## Security

1. Config stored with 600 permissions; `allowedUsers` restricts triggers
2. Only mapped rooms dispatch to runners; one dispatch per room prevents exhaustion
3. Bot account must NOT have Synapse admin privileges
4. OpenCode server should be localhost-only unless secured; set `OPENCODE_SERVER_PASSWORD` on shared systems
5. Bot cannot read encrypted messages — rooms must have encryption disabled; use Element (not FluffyChat) when creating rooms
6. Accepted events are normalized to stable hashed identities before dispatch; display names never establish identity or authority
7. Event receipts are claimed before typing/reactions/runner effects, and Matrix-facing failures never include raw runner/provider diagnostics

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Bot not responding | `status` + `logs` |
| "Not mapped" error | `map '!room:server' runner` |
| Runner dispatch fails | Ensure OpenCode server running: `opencode serve` |
| Runner not found | `runner-helper.sh create <name> --workdir /path` |
| Access denied | Check `allowedUsers` in config |
| Bot not joining rooms | Invite bot user via Element |
| Bot crashes on startup | `cleanup-invites` |
| Raw JSON in responses | `setup` then restart |
| Stale PID file | `stop` |
| Wrong working directory | `runner-helper.sh status <name>` (verify workdir) |

## Related

- `scripts/entity-helper.sh` — Entity memory system (identity resolution, Layer 0/1/2)
- `scripts/runner-helper.sh` — Runner management
- `scripts/memory-helper.sh` — Memory system (shared memory.db)
- `tools/ai-assistants/headless-dispatch.md` — Headless dispatch patterns
- `tools/ai-assistants/opencode-server.md` — OpenCode server API
- `tools/ai-assistants/openclaw.md` — Alternative: OpenClaw multi-channel bot
- `services/hosting/cloudron.md` — Cloudron platform for hosting Synapse
