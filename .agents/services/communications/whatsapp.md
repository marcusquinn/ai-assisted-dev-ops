---
description: WhatsApp bot via Baileys (TypeScript, unofficial WhatsApp Web API) — QR linking, multi-device, messaging, access control, aidevops runner dispatch, Matterbridge bridging
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

# WhatsApp Bot Integration (Baileys)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Library**: [Baileys](https://github.com/WhiskeySockets/Baileys) — TypeScript, MIT, unofficial WhatsApp Web API; `npm install baileys`
- **Runtime**: Node.js 20+ or Bun; multi-device (up to 4 linked devices, no phone after pairing)
- **Encryption**: Signal Protocol E2E. Auth: QR (`printQRInTerminal: true`) or pairing code (`sock.requestPairingCode("1234567890")`); sessions invalidated after ~14 days inactivity
- **Session store**: File-based (`useMultiFileAuthState`); SQLite/Redis/PostgreSQL require custom `AuthenticationState`
- **JID format**: individual `<phone>@s.whatsapp.net` | group `<id>@g.us` | broadcast `status@broadcast` (phone: country code + number, no `+`)
- **Reconnect**: `loggedOut` → delete `auth_info/`, new QR; `restartRequired` → 1s; `connectionClosed`/`connectionLost`/`timedOut` → 5s; default → 15s
- **Docs**: https://whiskeysockets.github.io/Baileys/

| Criterion | WhatsApp (Baileys) | Business API | SimpleX | Matrix |
|-----------|--------------------|-----------------------|---------|--------|
| Official API | No (reverse-engineered) | Yes (Meta-approved) | N/A | N/A |
| Cost | Free | Per-conversation | Free | Free |
| Account ban risk | Yes (ToS violation) | No | No | No |
| Metadata privacy | Poor (Meta harvests) | Poor | Excellent | Moderate |
| Best for | Existing WA users, prototyping | Production messaging | Max privacy | Team collab |

<!-- AI-CONTEXT-END -->

## Knowledge-ingestion safety boundary

This page documents an unofficial messaging bot. It is not an approved knowledge
collector. Do not use Baileys, linked WhatsApp Web sessions, browser automation,
reverse-engineered databases, or backup decryption to ingest chats. The account
ban and Terms-of-Service risks documented below are disqualifying for knowledge
collection, including private history mining.

Knowledge ingestion is limited to user-authorized chat exports and identity- plus
signature-verified official WhatsApp Business Platform webhooks. See
`content/social-whatsapp.md` for the read-only routes, explicit coverage gaps,
privacy rules, and current official references. No code in that collector can
send messages, mutate templates or groups, link a personal session, or contact
an unofficial endpoint.

## Minimal Setup

```typescript
import makeWASocket, { DisconnectReason, useMultiFileAuthState, WASocket } from "baileys"
import { Boom } from "@hapi/boom"; import pino from "pino"
async function startBot(): Promise<void> {
  const { state, saveCreds } = await useMultiFileAuthState("./auth_info")
  const sock: WASocket = makeWASocket({ auth: state, logger: pino({ level: "warn" }), printQRInTerminal: true, browser: ["aidevops Bot", "Chrome", "1.0.0"] })
  sock.ev.on("creds.update", saveCreds)
  sock.ev.on("connection.update", ({ connection, lastDisconnect }) => {
    if (connection === "close") {
      const code = (lastDisconnect?.error as Boom)?.output?.statusCode
      if (code !== DisconnectReason.loggedOut) setTimeout(() => startBot(), 3000)
    }
  })
  sock.ev.on("messages.upsert", async ({ messages, type }) => {
    if (type !== "notify") return
    for (const msg of messages) {
      if (msg.key.fromMe || !msg.message) continue
      const text = msg.message.conversation || msg.message.extendedTextMessage?.text || ""
      if (text.startsWith("/ping")) await sock.sendMessage(msg.key.remoteJid!, { text: "pong" })
    }
  })
}; startBot()
```

## Messaging and Group API

```typescript
// Text / mentions / quoted reply / reaction / poll
await sock.sendMessage(groupJid, { text: "@user", mentions: ["user@s.whatsapp.net"] })
await sock.sendMessage(jid, { text: "Reply" }, { quoted: originalMsg })
await sock.sendMessage(jid, { react: { text: "👍", key: originalMsg.key } })
await sock.sendMessage(jid, { poll: { name: "What next?", values: ["A", "B", "C"], selectableCount: 1 } })
// Media: image | audio ptt | document
await sock.sendMessage(jid, { image: readFileSync("./photo.jpg"), caption: "Caption", mimetype: "image/jpeg" })
await sock.sendMessage(jid, { audio: readFileSync("./voice.ogg"), mimetype: "audio/ogg; codecs=opus", ptt: true })
await sock.sendMessage(jid, { document: readFileSync("./report.pdf"), mimetype: "application/pdf", fileName: "report.pdf" })
await sock.sendPresenceUpdate("composing", jid); const buffer = await downloadMediaMessage(msg, "buffer", {})
// Groups
await sock.groupParticipantsUpdate(groupJid, ["user@s.whatsapp.net"], "add"|"remove"|"promote"|"demote")
await sock.groupUpdateSubject(groupJid, "New Name"); await sock.groupSettingUpdate(groupJid, "announcement"|"locked")
const code = await sock.groupInviteCode(groupJid)  // https://chat.whatsapp.com/${code}
```

## Access Control

```typescript
const ALLOWED_USERS = new Set(["1234567890@s.whatsapp.net"]); const ALLOWED_GROUPS = new Set(["120363012345678901@g.us"])
function isAuthorized(jid: string, sender: string): boolean {
  return jid.endsWith("@s.whatsapp.net") ? ALLOWED_USERS.has(jid)
    : jid.endsWith("@g.us") ? ALLOWED_GROUPS.has(jid) && ALLOWED_USERS.has(sender) : false
}
// Rate limiting: 10 msgs/min per sender
const rateLimits = new Map<string, number[]>()
function isRateLimited(sender: string): boolean {
  const now = Date.now(); const recent = (rateLimits.get(sender) || []).filter(t => now - t < 60_000)
  if (recent.length >= 10) return true; recent.push(now); rateLimits.set(sender, recent); return false
}
```

**Permission levels**: Public (`/help`, `/ping`) → Standard (`/ask`) → Privileged (`/run`, `/deploy`) → Owner (`/config`, `/allow`).

## Privacy and Security

**E2E protected** (Signal Protocol): message text, media, calls, group messages, status broadcasts. **NOT protected — Meta metadata harvesting**: contact graph, group membership, usage patterns, device info, IP, timestamps. Backups may use Meta-held keys. Meta AI processes message content when invoked.

**ToS risks**: Account ban (Medium-High) — use dedicated prepaid SIM, not personal number. IP ban (Low-Medium) — residential proxy or VPN. API changes (High) — pin Baileys version. Rate limiting (Medium) — human-like delays (2-5s).

## aidevops Runner Dispatch

```typescript
import { execFileSync } from "child_process"
// ALWAYS execFileSync with arg arrays — never execSync with string interpolation (shell injection)
function dispatchToRunner(runner: string, prompt: string, sender: string): string {
  try {
    return execFileSync("./runner-helper.sh", ["dispatch", runner, prompt], {
      timeout: 120_000, encoding: "utf-8", env: { ...process.env, DISPATCH_SENDER: sender, DISPATCH_CHANNEL: "whatsapp" },
    }).trim() || "(no response)"
  } catch { return "Dispatch failed. Check bot logs." }
}
// Router: check isAuthorized + isRateLimited → commands map
// /ask → dispatchToRunner("general", args, sender)  /run → dispatchToRunner("ops", args, sender) [admin]
```

Scan inbound with `prompt-guard-helper.sh scan "$message"` before dispatch. Validate runner names against an allowlist. See `tools/security/prompt-injection-defender.md`.

## Matterbridge Integration

Bridges WhatsApp to 20+ platforms via [whatsmeow](https://github.com/tulir/whatsmeow) (Go) — no custom bot code. **Note**: E2E encryption is broken at the bridge. See `tools/security/opsec.md`. Build: `go install -tags whatsappmulti github.com/42wim/matterbridge@latest`

```toml
# matterbridge.toml — QR code pairing on first run, no token needed
[whatsapp.mywa]
[[gateway]]
name="wa-matrix-bridge"
enable=true
  [[gateway.inout]]
  account="whatsapp.mywa"
  channel="120363012345678901"  # Group JID without @g.us
  [[gateway.inout]]
  account="matrix.home"
  channel="#bridged:example.com"
```

**Limitations**: No voice/video calls. One account per bot instance. Group size max 1024. Protocol changes can break Baileys without warning. Account ban risk increases with high volume, rapid group ops, or no human-like delays — use a dedicated number.

**Related**: `services/communications/simplex.md` (max privacy) | `services/communications/matrix-bot.md` (Matrix runner dispatch) | `services/communications/matterbridge.md` (multi-platform bridge)
