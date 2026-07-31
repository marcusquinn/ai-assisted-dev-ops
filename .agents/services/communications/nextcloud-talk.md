---
description: Nextcloud Talk — self-hosted team communication with strongest corporate privacy, Talk Bot API (webhook-based, OCC CLI), server-side encryption, Matterbridge bridging, and aidevops dispatch
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Nextcloud Talk Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

| Item | Value |
|------|-------|
| Type | Self-hosted team communication (AGPL-3.0) — you own everything |
| Bot tool | Talk Bot API (webhook-based, OCC CLI registration) |
| Protocol | HTTP REST + webhook · TLS in transit · AES-256-CTR at rest · WebRTC SRTP/DTLS for 1:1 calls |
| Script | `nextcloud-talk-dispatch-helper.sh [setup\|start\|stop\|status\|map\|unmap\|mappings\|test\|logs]` |
| Config | `~/.config/aidevops/nextcloud-talk-bot.json` (600 permissions) |
| Data | `~/.aidevops/.agent-workspace/nextcloud-talk-bot/` |
| Docs | [Talk docs](https://nextcloud-talk.readthedocs.io/) · [Bots and webhooks](https://nextcloud-talk.readthedocs.io/en/latest/bots/) |

**Key differentiator**: You own server, database, encryption keys, and backups. No third party (including Nextcloud GmbH) has access. Unlike Slack/Teams/Discord: zero external data access. Unlike SimpleX/Signal: full collaboration suite (files, calendar, office, contacts).

```bash
nextcloud-talk-dispatch-helper.sh setup          # Interactive wizard
nextcloud-talk-dispatch-helper.sh map "general" code-reviewer
nextcloud-talk-dispatch-helper.sh start --daemon
```

<!-- AI-CONTEXT-END -->

## Architecture

**Stack**: Talk Room → webhook POST (HMAC-SHA256 over random header + body) → Bot Endpoint (Bun/Node) → `runner-helper.sh` → AI session → OCS API reply → Talk Room.

**Message flow**: signature verify → access control → entity resolution (`entity-helper.sh`) → Layer 0 log → context load → dispatch → headless AI session → OCS API reply + reaction emoji (⏳/✅/❌).

## Installation

Nextcloud 27+ with Talk app (`spreed`), admin OCC access, Node.js ≥18 or Bun, bot endpoint reachable from server.

```bash
sudo -u www-data php /var/www/nextcloud/occ app:install spreed
sudo -u www-data php /var/www/nextcloud/occ app:enable spreed

# Register bot (returns bot ID and shared secret)
sudo -u www-data php /var/www/nextcloud/occ talk:bot:install \
  "aidevops" "http://localhost:8780/webhook" "AI-powered DevOps assistant" "YOUR_SHARED_SECRET_HERE"
sudo -u www-data php /var/www/nextcloud/occ talk:bot:list    # verify
sudo -u www-data php /var/www/nextcloud/occ talk:bot:remove BOT_ID

# Credentials
openssl rand -hex 32
gopass insert aidevops/nextcloud-talk/webhook-secret
# App password: Nextcloud UI → Settings > Security > Devices & sessions > "aidevops-talk-bot"
gopass insert aidevops/nextcloud-talk/app-password

bun add express crypto   # or: npm install express
```

## Bot API Integration

### Webhook Payload

```json
{
  "type": "Create",
  "actor": { "type": "User", "id": "admin", "name": "Admin User" },
  "object": { "type": "Message", "id": "42", "name": "Hello @aidevops, review the latest PR?", "mediaType": "text/markdown" },
  "target": { "type": "Collection", "id": "conversation-token", "name": "Development" }
}
```

### Webhook Handler

```typescript
// nextcloud-talk-bot.ts — HMAC-verified webhook → runner dispatch → OCS reply
import express from "express";
import { createHmac } from "crypto";

const PORT = 8780;
const NEXTCLOUD_URL = process.env.NEXTCLOUD_URL || "https://cloud.example.com";
const BOT_USER = process.env.BOT_USER || "aidevops-bot";
const APP_PASSWORD = process.env.APP_PASSWORD || "";
const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET || "";
const ALLOWED_USERS = new Set(["admin", "developer1", "developer2"]);
const app = express();
app.use(express.raw({ type: "application/json" }));

function verifySignature(body: Buffer, random: string, signature: string): boolean {
  const expected = createHmac("sha256", WEBHOOK_SECRET).update(random).update(body).digest("hex");
  if (expected.length !== signature.length) return false;
  let result = 0;
  for (let i = 0; i < expected.length; i++) result |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  return result === 0;
}

async function ocsPost(path: string, body: object): Promise<void> {
  const auth = Buffer.from(`${BOT_USER}:${APP_PASSWORD}`).toString("base64");
  await fetch(`${NEXTCLOUD_URL}/ocs/v2.php/apps/spreed/api/${path}`, {
    method: "POST", body: JSON.stringify(body),
    headers: { "Content-Type": "application/json", "OCS-APIRequest": "true", "Authorization": `Basic ${auth}` },
  });
}

app.post("/webhook", async (req, res) => {
  const sig = req.headers["x-nextcloud-talk-signature"] as string;
  const random = req.headers["x-nextcloud-talk-random"] as string;
  if (!sig || !random || !verifySignature(req.body, random, sig)) { res.status(401).send("Invalid signature"); return; }
  res.status(200).send("OK");

  const p = JSON.parse(req.body.toString());
  const userId = p.actor?.id, text = p.object?.name || "", msgId = p.object?.id, token = p.target?.id;
  if ((ALLOWED_USERS.size > 0 && !ALLOWED_USERS.has(userId)) || !text.trim()) return;

  await ocsPost(`v1/reaction/${token}/${msgId}`, { reaction: "👀" });
  try {
    const response = await dispatchToRunner(text, userId, token);
    await ocsPost(`v1/chat/${token}`, { message: response });
    await ocsPost(`v1/reaction/${token}/${msgId}`, { reaction: "✅" });
  } catch (error) {
    await ocsPost(`v1/chat/${token}`, { message: `Error: ${error.message}` });
    await ocsPost(`v1/reaction/${token}/${msgId}`, { reaction: "❌" });
  }
});

app.listen(PORT, () => console.log(`Nextcloud Talk bot listening on port ${PORT}`));
```

### OCS API Endpoints

Base: `https://cloud.example.com/ocs/v2.php/apps/spreed/api/` · Auth: `Basic bot-user:app-password` · Header: `OCS-APIRequest: true`

| Action | Method | Path |
|--------|--------|------|
| List conversations | GET | `v4/room` |
| Send message | POST | `v1/chat/TOKEN` · body: `{"message":"..."}` |
| Get messages without read/status side effects | GET | `v1/chat/TOKEN?lookIntoFuture=0&limit=50&setReadMarker=0&noStatusUpdate=1&markNotificationsAsRead=0` |
| Send reaction | POST | `v1/reaction/TOKEN/MESSAGE_ID` · body: `{"reaction":"👍"}` |

Talk supports markdown: `**bold**`, `` `code` ``, headings, lists.

## Security

| Platform | Who can access messages |
|----------|------------------------|
| Slack | Salesforce, workspace admins, law enforcement |
| Teams | Microsoft, tenant admins (eDiscovery), law enforcement |
| Discord | Discord Inc., law enforcement, trust & safety |
| Google Chat | Google, Workspace admins, law enforcement |
| **Nextcloud Talk** | **Only you** — server admin of your own instance |

Better theoretical privacy: SimpleX (no user identifiers) and Signal (E2E everything) — but neither offers self-hosted file collaboration.

**Encryption**: TLS 1.2+ in transit (you control certs/ciphers/HSTS) · AES-256-CTR at rest (you control master key) · 1:1 calls E2E via WebRTC SRTP/DTLS · Group chats NOT E2E (server-side at rest only). Metadata stays on YOUR server — no analytics, no AI training. `assistant` app runs models locally unless you configure external API.

**Compliance**: GDPR (full control), HIPAA/SOC2/ISO 27001 configurable. Jurisdiction = where you host — no CLOUD Act/FISA 702 unless US-hosted. AGPL-3.0 — fully auditable.

**Bot security**: webhook can be localhost/LAN/tunneled (no public internet required) · verify the backend header and HMAC-SHA256 over the random header plus raw body · app passwords are revocable account credentials, not endpoint-scoped API grants · room membership and explicit allowlists provide the collector boundary.

## aidevops Integration

### Helper Commands

```bash
nextcloud-talk-dispatch-helper.sh setup                          # wizard
nextcloud-talk-dispatch-helper.sh map "development" code-reviewer # room→agent
nextcloud-talk-dispatch-helper.sh mappings                        # list all
nextcloud-talk-dispatch-helper.sh unmap "development"
nextcloud-talk-dispatch-helper.sh start --daemon | stop | status
nextcloud-talk-dispatch-helper.sh test code-reviewer "Review src/auth.ts"
nextcloud-talk-dispatch-helper.sh logs [--follow]
```

### Entity Resolution

Matches on `entity_channels` table (`channel=nextcloud-talk`, `channel_id=username`). New users auto-created via `entity-helper.sh create`. Cross-channel links (Matrix, Slack, SimpleX, email) provide full profile. Nextcloud user API enriches display name, email, groups on first contact.

### Configuration

`~/.config/aidevops/nextcloud-talk-bot.json` (600 permissions):

```json
{
  "nextcloudUrl": "https://cloud.example.com",
  "botUser": "aidevops-bot",
  "appPassword": "",
  "webhookSecret": "",
  "webhookPort": 8780,
  "allowedUsers": ["admin", "developer1"],
  "defaultRunner": "",
  "conversationMappings": {
    "development": "code-reviewer",
    "seo-team": "seo-analyst",
    "operations": "ops-monitor"
  },
  "ignoreOwnMessages": true,
  "maxPromptLength": 3000,
  "responseTimeout": 600,
  "sessionIdleTimeout": 300
}
```

Store `appPassword`/`webhookSecret` via `gopass` (preferred) or in config with 600 permissions. Never commit credentials.

## Matterbridge Integration

```toml
# matterbridge.toml — bridge Talk ↔ Matrix (or other self-hosted platforms)
[nextcloud.myserver]
Server = "https://cloud.example.com"
Login = "matterbridge-bot"
Password = "app-password-here"
ShowJoinPart = false

[[gateway]]
name = "dev-bridge"
enable = true

[[gateway.inout]]
account = "nextcloud.myserver"
channel = "development"

[[gateway.inout]]
account = "matrix.myserver"
channel = "#dev:matrix.example.com"
```

**Privacy note**: bridging to external platforms (Slack, Discord, Telegram) means messages leave your server. Self-hosted bridges (Matrix, IRC) preserve the privacy model. See `services/communications/matterbridge.md`.

## Limitations

| Limitation | Mitigation |
|------------|------------|
| Self-hosted maintenance (server, PHP/DB, SSL, backups) | Managed hosting (Hetzner StorageShare, IONOS) or Cloudron |
| Bot API maturity — smaller surface, may change between majors | Pin versions; test upgrades in staging |
| No rich interactive components (text/markdown/reactions/files only) | Slash-command patterns for structured input |
| Group chats not E2E encrypted | Acceptable where you trust your own server |
| Performance depends on hardware | Dedicated TURN (coturn), Redis caching |
| Mobile push requires push proxy or `notify_push` | Additional config beyond base install |
| Smaller ecosystem vs Slack/Discord | Custom integrations via webhook/OCS API |

## Related

- `services/communications/matrix-bot.md` — Matrix (federated, E2E, self-hostable)
- `services/communications/slack.md` — Slack (proprietary, comprehensive API)
- `services/communications/simplex.md` — SimpleX (zero-identifier, strongest metadata privacy)
- `services/communications/signal.md` — Signal (E2E, phone number required)
- `services/communications/matterbridge.md` — Multi-platform bridging
- `scripts/entity-helper.sh` — Entity memory · `scripts/runner-helper.sh` — Runner management
- `tools/security/opsec.md` — OpSec · `services/hosting/cloudron.md` — Simplified Nextcloud hosting
- [Talk docs](https://nextcloud-talk.readthedocs.io/) · [Bot API](https://docs.nextcloud.com/server/latest/developer_manual/digging_deeper/bots.html) · [Server admin](https://docs.nextcloud.com/server/latest/admin_manual/) · [Talk source](https://github.com/nextcloud/spreed) · [Server source](https://github.com/nextcloud/server)
