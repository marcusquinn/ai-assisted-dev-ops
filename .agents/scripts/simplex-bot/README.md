<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# aidevops SimpleX Bot

Channel-agnostic gateway with SimpleX Chat as the first adapter.

## Prerequisites

- [Bun](https://bun.sh/) >= 1.0.0
- SimpleX Chat CLI running as WebSocket server (`simplex-chat -p 5225`)

## Setup

```bash
cd .agents/scripts/simplex-bot
bun install
```

## Configuration

The bot loads config from three sources (highest priority first):

1. **Environment variables** — `SIMPLEX_PORT`, `SIMPLEX_HOST`, etc.
2. **Config file** — `~/.config/aidevops/simplex-bot.json`
3. **Defaults** — built-in defaults

### Config File

```json
{
  "port": 5225,
  "host": "127.0.0.1",
  "displayName": "AIBot",
  "autoAcceptContacts": false,
  "businessAddress": false,
  "autoAcceptFiles": false,
  "autoJoinGroups": false,
  "logLevel": "info",
  "execApproval": {
    "approvalTimeoutMs": 43200000
  },
  "sessionIdleTimeout": 300
}
```

Pending command approvals remain valid for 12 hours by default. Override
`execApproval.approvalTimeoutMs` with a duration in milliseconds when needed.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SIMPLEX_PORT` | `5225` | WebSocket port for SimpleX CLI |
| `SIMPLEX_HOST` | `127.0.0.1` | WebSocket host |
| `SIMPLEX_BOT_NAME` | `AIBot` | Bot display name |
| `SIMPLEX_AUTO_ACCEPT` | `false` | Auto-accept contact requests |
| `SIMPLEX_LOG_LEVEL` | `info` | Log level (debug/info/warn/error) |
| `SIMPLEX_TLS` | `false` | Use TLS for WebSocket |
| `SIMPLEX_BUSINESS_ADDRESS` | `false` | Enable business address mode |

## Usage

```bash
# Start the bot (SimpleX CLI must be running on port 5225)
bun run start

# Development mode (auto-reload)
bun run dev

# Type checking
bun run typecheck
```

## Built-in Commands

### Core

| Command | DM | Group | Description |
|---------|:--:|:-----:|-------------|
| `/help` | Y | Y | Show available commands |
| `/status` | Y | Y | Show aidevops system status |
| `/ask <question>` | Y | Y | Ask AI a question |
| `/ping` | Y | Y | Check bot responsiveness |
| `/version` | Y | Y | Show bot version |

### Tasks

| Command | DM | Group | Description |
|---------|:--:|:-----:|-------------|
| `/tasks` | Y | Y | List open tasks from TODO.md |
| `/task <description>` | Y | - | Create a new task |

### Execution

| Command | DM | Group | Description |
|---------|:--:|:-----:|-------------|
| `/run <command>` | Y | - | Execute aidevops CLI command (requires approval) |

### Group Management

| Command | DM | Group | Description |
|---------|:--:|:-----:|-------------|
| `/invite @user` | - | Y | Invite user to group |
| `/role @user <role>` | - | Y | Set member role |
| `/broadcast <msg>` | Y | - | Send to all contacts |

### Voice & File

| Command | DM | Group | Description |
|---------|:--:|:-----:|-------------|
| `/voice` | Y | Y | Process voice note attachment |
| `/file` | Y | Y | Process file attachment |
| `/sessions` | Y | - | Show active bot sessions |

## Architecture

```text
SimpleX CLI (WebSocket :5225)
    |
SimplexAdapter (src/index.ts)
    |--- ContactHandler (handlers/contact.ts)
    |--- MessageHandler (handlers/message.ts)
    |--- GroupHandler (handlers/group.ts)
    |--- FileHandler (handlers/file.ts)
    |
CommandRouter -> CommandHandlers (src/commands.ts)
    |
SessionStore (src/session.ts) — SQLite WAL
    |
Config (src/config.ts) — env > file > defaults
    |
Runner (src/runner.ts) — aidevops CLI bridge
```

The bot is designed as a channel-agnostic gateway. SimpleX is the first adapter.
Future adapters (Matrix, etc.) can plug into the same command router.

### Event Handling

| Event | Handler | Description |
|-------|---------|-------------|
| `newChatItems` | message.ts | Incoming messages, command routing |
| `contactConnected` | contact.ts | New contact via address |
| `receivedContactRequest` | contact.ts | Contact request (auto-accept off) |
| `acceptingBusinessRequest` | contact.ts | Business address connection |
| `receivedGroupInvitation` | group.ts | Bot invited to group |
| `joinedGroupMember` | group.ts | Member joined group |
| `deletedMemberUser` | group.ts | Bot removed from group |
| `rcvFileDescrReady` | file.ts | Incoming file ready |
| `rcvFileComplete` | file.ts | File download complete |

### Business Address Mode

When `businessAddress: true`, each connecting customer gets a dedicated group chat.
This enables support-team patterns where multiple agents can join the customer's group.

## Adding Custom Commands

```typescript
import type { CommandDefinition } from "./types";

const myCommand: CommandDefinition = {
  name: "mycommand",
  description: "My custom command",
  groupEnabled: true,
  dmEnabled: true,
  handler: async (ctx) => {
    return `Hello, ${ctx.args.join(" ") || "world"}!`;
  },
};

// Register with the bot adapter
bot.registerCommand(myCommand);
```

## Related

- `.agents/services/communications/simplex.md` — SimpleX subagent documentation
- `.agents/scripts/simplex-helper.sh` — CLI helper script
- `.agents/tools/security/opsec.md` — Operational security guidance
- `todo/tasks/t1327-brief.md` — Task brief with full architecture decisions
- `todo/tasks/t1327.1-research.md` — Research report with API details
