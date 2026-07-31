---
description: Discord bot integration — discord.js (TypeScript), bot setup (Developer Portal, intents, OAuth2), DM/guild/thread messaging, slash commands, interactive components v2, role-based routing, access control, privacy/security assessment, aidevops runner dispatch, Matterbridge bridging
mode: subagent
tools: { read: true, write: false, edit: false, bash: true, glob: false, grep: false, webfetch: false, task: false }
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Discord Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Bot SDK**: `discord.js` v14+ (TypeScript/Node.js, Apache-2.0)
- **API**: Discord REST API v10 + Gateway WebSocket
- **Developer Portal**: [discord.com/developers/applications](https://discord.com/developers/applications)
- **Docs**: [discord.js.org](https://discord.js.org/) | [discord.com/developers/docs](https://discord.com/developers/docs)
- **Requires**: Node.js >= 18, bot token from Developer Portal

**Privacy**: Discord is centralized — all data passes through Discord Inc. servers. No E2E encryption. Use for community engagement, not confidential communications. For sensitive AI dispatch, prefer Matrix or SimpleX.

<!-- AI-CONTEXT-END -->

## Bot Setup

### 1. Create Application and Bot

1. [discord.com/developers/applications](https://discord.com/developers/applications) → "New Application" → note **Application ID**
2. **Bot** tab → "Add Bot" → copy token: `aidevops secret set DISCORD_BOT_TOKEN`
3. Settings: **Public Bot**: Off | **Message Content Intent**: On only when the bot must receive message fields outside Discord's documented privileged-intent exceptions

### 2. Gateway Intents

| Intent | Privileged | Required for |
|--------|-----------|--------------|
| `Guilds` | No | Guild/channel structure, roles |
| `GuildMessages` | No | Message and reaction Gateway events in guild channels |
| `GuildMembers` | Yes | Member join/leave, role changes |
| `MessageContent` | Yes | Reading message text (non-slash) |
| `DirectMessages` | No | Events for DMs in which the bot participates; not arbitrary user DM history |

Privileged intents require manual approval for bots in 100+ guilds (Developer Portal > Bot > Privileged Gateway Intents). **Recommendation**: Use slash commands as primary interaction — avoids `MessageContent` privileged intent.

### 3. OAuth2 Bot Invite

**OAuth2** > **URL Generator** → scopes: `bot`, `applications.commands` → permissions: Send Messages, Send Messages in Threads, Embed Links, Attach Files, Read Message History, Use Slash Commands, Add Reactions, Manage Threads.

Those permissions are for the interactive bot described in this guide. A
read-only knowledge collector should use a separate application/credential with
only View Channel and Read Message History on explicit allowlisted surfaces. See
`content/social-discord.md`; never reuse its credential for sends, reactions,
moderation, role changes, webhooks, or channel/thread management.

```text
https://discord.com/oauth2/authorize?client_id=YOUR_APP_ID&permissions=326417591296&scope=bot+applications.commands
```

## Installation

```bash
mkdir discord-bot && cd discord-bot && npm init -y
npm i discord.js && npm i -D typescript tsx @types/node
```

## Slash Commands

### Register

```typescript
import { REST, Routes, SlashCommandBuilder } from "discord.js";

const commands = [
  new SlashCommandBuilder()
    .setName("ask").setDescription("Ask the AI a question")
    .addStringOption((opt) =>
      opt.setName("prompt").setDescription("Your question").setRequired(true)
    ),
].map((cmd) => cmd.toJSON());

const rest = new REST().setToken(process.env.DISCORD_BOT_TOKEN!);
// Global (up to 1 hour to propagate) or per-guild (instant, for development):
await rest.put(Routes.applicationCommands(process.env.DISCORD_APP_ID!), { body: commands });
```

### Handle

```typescript
import { Client, GatewayIntentBits, Events } from "discord.js";

const client = new Client({
  intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages, GatewayIntentBits.DirectMessages],
});
client.once(Events.ClientReady, (c) => console.log(`Logged in as ${c.user.tag}`));

client.on(Events.InteractionCreate, async (interaction) => {
  if (!interaction.isChatInputCommand() || interaction.commandName !== "ask") return;

  const prompt = interaction.options.getString("prompt", true);
  const runner = interaction.options.getString("runner") ?? "code-reviewer";

  await interaction.deferReply(); // must respond within 3s; deferReply extends to 15 min
  try {
    const result = await dispatchToRunner(runner, prompt);
    if (result.length <= 2000) {
      await interaction.editReply(result);
    } else {
      await interaction.editReply({
        content: "Response attached:",
        files: [{ attachment: Buffer.from(result, "utf-8"), name: "response.md" }],
      });
    }
  } catch (err) {
    await interaction.editReply(`Error: ${(err as Error).message}`);
  }
});

const token = process.env.DISCORD_BOT_TOKEN;
if (!token) throw new Error("DISCORD_BOT_TOKEN not set");
client.login(token);
```

## Interactive Components v2

```typescript
import {
  ActionRowBuilder, ButtonBuilder, ButtonStyle,
  StringSelectMenuBuilder, ModalBuilder, TextInputBuilder, TextInputStyle,
} from "discord.js";

// Buttons — reply with components, handle via isButton()
const row = new ActionRowBuilder<ButtonBuilder>().addComponents(
  new ButtonBuilder().setCustomId("approve").setLabel("Approve").setStyle(ButtonStyle.Success),
  new ButtonBuilder().setCustomId("reject").setLabel("Reject").setStyle(ButtonStyle.Danger)
);
await interaction.reply({ content: "Review this PR?", components: [row] });
client.on(Events.InteractionCreate, async (i) => {
  if (i.isButton() && i.customId === "approve") await i.update({ content: "Approved!", components: [] });
});

// Select menu — handle via isStringSelectMenu()
const select = new ActionRowBuilder<StringSelectMenuBuilder>().addComponents(
  new StringSelectMenuBuilder().setCustomId("runner-select").setPlaceholder("Choose a runner")
    .addOptions({ label: "Code Reviewer", value: "code-reviewer" }, { label: "SEO Analyst", value: "seo-analyst" })
);

// Modal (text input form) — show via showModal(), handle via isModalSubmit()
const modal = new ModalBuilder().setCustomId("task-modal").setTitle("Create Task");
modal.addComponents(
  new ActionRowBuilder<TextInputBuilder>().addComponents(
    new TextInputBuilder().setCustomId("task-title").setLabel("Task Title").setStyle(TextInputStyle.Short).setRequired(true)
  )
);
await interaction.showModal(modal);
```

## Messaging Patterns

```typescript
import { EmbedBuilder, AttachmentBuilder, ChannelType } from "discord.js";

// Channel message + embed
const channel = await client.channels.fetch("CHANNEL_ID");
if (channel?.isTextBased()) {
  await channel.send({ embeds: [
    new EmbedBuilder().setTitle("Runner Status").setColor(0x00ff00)
      .addFields({ name: "code-reviewer", value: "Online", inline: true }).setTimestamp()
  ]});
}

// DM — bot-initiated; handle incoming DMs via MessageCreate (filter message.guild === null)
const user = await client.users.fetch("USER_ID");
await user.send("Your task has been completed.");

// Thread, file attachment, reaction
const thread = await message.startThread({ name: "AI Discussion", autoArchiveDuration: 60 });
await channel.send({ files: [new AttachmentBuilder(Buffer.from("content", "utf-8"), { name: "output.md" })] });
await message.react("✅");
```

## Role-Based Routing and Access Control

Config at `~/.config/aidevops/discord-bot.json` (600 permissions). Store `botToken` in gopass, not in this file.

```json
{
  "guildId": "YOUR_GUILD_ID",
  "botToken": "stored-in-gopass",
  "roleRouting": { "developer": "code-reviewer", "seo-team": "seo-analyst", "ops": "ops-monitor" },
  "channelRouting": { "dev-chat": "code-reviewer", "seo-room": "seo-analyst" },
  "defaultRunner": "code-reviewer",
  "allowedRoles": ["developer", "seo-team", "ops", "admin"],
  "adminRoles": ["admin"],
  "maxPromptLength": 3000,
  "responseTimeout": 600
}
```

Resolution order: explicit `--runner` option > channel name > highest matching role > `defaultRunner`.

**Access control**: Check `allowedGuilds`, `allowedChannels`, `allowedUsers`, `allowedRoles` in order — return false on first mismatch.

**Rate limiting**: Sliding-window via `Map<userId, number[]>` — filter timestamps within `windowMs`, reject if count >= max, push new timestamp.

## Integration with aidevops Runners

```typescript
import { spawnSync } from "node:child_process";

function dispatchToRunner(runner: string, prompt: string): string {
  // spawnSync with argument array bypasses shell injection (;, |, &&, $(), backticks)
  const child = spawnSync("runner-helper.sh", ["dispatch", runner, prompt], {
    encoding: "utf-8", timeout: 600_000, env: { ...process.env, RUNNER_TIMEOUT: "600" },
  });
  if (child.error) throw child.error;
  if (child.status !== 0) throw new Error(`Runner failed (${child.status}): ${child.stderr}`);
  return child.stdout.trim();
}
```

**Recommended slash commands**:

| Command | Description | Runner |
|---------|-------------|--------|
| `/ask <prompt>` | General AI question | Role-based routing |
| `/review <file>` | Code review request | `code-reviewer` |
| `/seo <url>` | SEO analysis | `seo-analyst` |
| `/status` | Bot and runner status | (local) |
| `/deploy <project>` | Trigger deployment | `ops-monitor` |
| `/task <description>` | Create a task | (local — creates TODO entry) |

## Voice Channels

Requires `@discordjs/voice @discordjs/opus sodium-native`. Enables speech-to-text → AI dispatch → text-to-speech workflows. See `tools/voice/speech-to-speech.md`.

```typescript
import { joinVoiceChannel, createAudioPlayer, createAudioResource } from "@discordjs/voice";

const connection = joinVoiceChannel({ channelId: "VOICE_CHANNEL_ID", guildId: guild.id, adapterCreator: guild.voiceAdapterCreator });
const player = createAudioPlayer();
player.play(createAudioResource("./response.mp3"));
connection.subscribe(player);
```

## Matterbridge Integration

Discord is natively supported by [Matterbridge](https://github.com/42wim/matterbridge). See `services/communications/matterbridge.md` for full configuration.

```toml
[discord.myserver]
Token="Bot YOUR_BOT_TOKEN"
Server="My Server Name"

[[gateway]]
name="discord-matrix-bridge"
enable=true
  [[gateway.inout]]
  account="discord.myserver"
  channel="general"
  [[gateway.inout]]
  account="matrix.home"
  channel="#general:example.com"
```

**Bridge note**: Messages bridged to Matrix/SimpleX lose E2E encryption at the bridge boundary. Discord-side messages remain visible to Discord Inc. regardless.

## Deployment

```bash
# PM2 (recommended)
npm i -g pm2
pm2 start src/bot.ts --interpreter tsx --name discord-bot
pm2 save && pm2 startup
```

For systemd: create `/etc/systemd/system/discord-bot.service` with `Type=simple`, `ExecStart=tsx src/bot.ts`, `Restart=on-failure`, then `systemctl enable --now discord-bot`.

**Health monitoring**: Listen on `Events.ShardReconnecting` and `Events.ShardError`. Poll `client.ws.ping` every 30s and warn if > 500ms.

## Limits

| Scope | Limit |
|-------|-------|
| Message length | 2000 chars (use file attachment, embeds up to 6000, or threads) |
| Global rate | 50 requests/second |
| Per-channel send | 5/5s |
| Initial interaction response | 3 seconds (use `deferReply()`) |
| Deferred response edit | 15 minutes |
| Component/modal interaction | 3 seconds (use `deferUpdate()`) |

discord.js handles rate limiting automatically.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Bot not responding to slash commands | Verify commands are registered; check guild vs global scope |
| "Missing Access" error | Re-invite bot with correct permissions |
| "Missing Intent" error | Enable in Developer Portal > Bot > Privileged Intents |
| Interaction timeout (3s) | Use `deferReply()` before long operations |
| Bot offline after deploy | Check token; verify `client.login()` is called; check process manager logs |
| Slash commands not appearing | Global commands take up to 1 hour; use guild commands for instant testing |
| Cannot read message content | Enable `MessageContent` intent, or switch to slash commands |

## Related

- `services/communications/matterbridge.md` — Multi-platform chat bridge
- `services/communications/matrix-bot.md` — Matrix bot (federated, E2E capable)
- `services/communications/simplex.md` — SimpleX Chat (maximum privacy)
- `services/communications/xmtp.md` — XMTP (Web3 messaging, agent SDK)
- `tools/security/opsec.md` — Operational security guidance
- `tools/voice/speech-to-speech.md` — Voice pipeline for audio interactions
- `tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- discord.js Docs: https://discord.js.org/
- Discord Developer Docs: https://discord.com/developers/docs
