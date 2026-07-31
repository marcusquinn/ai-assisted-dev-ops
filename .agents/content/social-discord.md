<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Discord Knowledge Collection

`knowledge_social_discord.py` is a provider-specific, read-only collector for an
explicitly configured Discord bot installation. Shared registration is owned by
issue #28867; until that integration lands, invoke the Python entry point directly.
The existing Discord bot guide remains a separate, write-capable integration.

## Runtime and authority contract

The live child uses Python's standard-library `urllib.request.Request`,
`urllib.request.urlopen`, and `urllib.parse.urlencode` against Discord REST API
v10. No Discord SDK is installed or imported. Every network request is a `GET`
to a path matched by a fixed read-route expression. Message sends, reactions,
moderation, channel/thread changes, role changes, and webhook operations have no
route or action in the collector.

Configure one private profile through the secret execution context:

```text
DISCORD_<PROFILE>_BOT_TOKEN
DISCORD_<PROFILE>_APPLICATION_ID
DISCORD_<PROFILE>_GUILD_ID
DISCORD_<PROFILE>_CHANNEL_IDS
DISCORD_<PROFILE>_THREAD_IDS
DISCORD_<PROFILE>_DM_CHANNEL_IDS
DISCORD_<PROFILE>_MESSAGE_CONTENT_INTENT
DISCORD_<PROFILE>_GUILD_MEMBERS_INTENT
DISCORD_<PROFILE>_EXPORT_USER_ID
DISCORD_<PROFILE>_EXPORT_PATH
DISCORD_<PROFILE>_GATEWAY_EVENTS_PATH
```

IDs are comma-separated snowflakes. At least one channel, thread, or bot-visible
DM channel is required. Paths and identifiers stay in private configuration;
only sanitized identity and coverage policy enter the corpus. Store the bot
credential with `aidevops secret set`, never in a profile file or command line.

Before binding a connection, the child reads the current bot user, current
application, and configured guild. It compares all three identities with the
profile and parent request. The same checks run before every page. A changed
bot, application, guild, allowlist, intent declaration, or export-user identity
fails before persistence. Existing connection policy is checked again during
normalization and the final social-store lease fence remains authoritative.

Example before shared command registration:

```bash
python3 ~/.aidevops/agents/scripts/knowledge_social_discord.py \
  --alias personal:default --connection-id DISCORD_CONNECTION_ID \
  --account-id EXPECTED_BOT_USER_ID --stream messages \
  --profile personal --budget 11 --page-size 100
```

## Permissions and intents

Use the smallest bot installation possible:

- `View Channel` and `Read Message History` on every allowlisted guild channel
  and thread;
- `Guilds` Gateway intent for guild/channel/thread lifecycle events;
- `Guild Messages` for guild message and reaction events;
- `Direct Messages` only for DMs in which the bot participates and which are
  explicitly allowlisted;
- `Message Content` when message text, embeds, attachments, and components are
  required outside the documented privileged-intent exceptions;
- `Guild Members` only when complete member snapshots or member events are
  required.

Do not grant Send Messages, Add Reactions, Manage Messages, Manage Threads,
Manage Channels, Manage Roles, moderation, or webhook permissions to the
collector bot. A separately deployed interactive bot must use a different
credential and process boundary.

## Implemented streams

| Stream | Official or operator-authorized route | Coverage |
|---|---|---|
| `messages` | `GET /channels/{channel.id}/messages` for explicit channel, thread, and bot-visible DM IDs | Independent composite snowflake cursor and per-channel newest watermark. Deleted messages and prior revisions require prospective events. |
| `metadata` | Guild channels and roles plus explicit thread lookups | Guild, text, announcement, forum, active-thread, and archived-thread metadata that the bot can currently view. Thread messages require explicit thread allowlisting. |
| `members` | Paginated guild-member list | Current snapshot only and explicitly partial when the Guild Members intent or authority is absent. |
| `gateway_events` | Validated local JSONL spool of official Gateway dispatches | Prospective create/update/delete, reaction, channel, thread, member, and role observations. The collector does not open a WebSocket or send Gateway commands. |
| `account_export` | Operator-supplied official Discord account export ZIP | Idempotent message replay for explicitly allowlisted channels and a configured export user. Export shape and selected categories remain partial coverage. |

REST, Gateway, and export evidence converge on Discord message snowflakes. A
Gateway event is also retained as revision/deletion observation evidence; it
never deletes an earlier raw batch or canonical message. Export replay does not
authorize a user session and is never treated as a credential.

Discord's account-export layout is not a developer API contract. The parser
accepts only safe ZIP paths, bounded entries, channel metadata, and message CSV
files. A changed or malformed package fails closed without advancing the export
cursor. Validate a current private export before relying on category coverage.

## Rate limits, media, and explicit gaps

The HTTP child reads `X-RateLimit-*` and `Retry-After` response headers rather
than hard-coding route limits. A 429 pauses the invocation, records a sanitized
retry epoch, and leaves the last successful cursor unchanged. Authorization,
unavailable-resource, and provider failures are terminal for that invocation.

Attachment snowflakes are canonical media identity. Filenames, MIME types, and
sizes may be retained; signed or expiring CDN URLs are transport data and are
not stored as identity or logged. Hydration remains `remote_only` until a
separate approved media workflow supplies immutable bytes and a digest.

Every successful page keeps these limits visible:

- arbitrary user DM history is unavailable to a bot; only bot-participating,
  explicitly allowlisted DM channels are eligible;
- REST cannot reconstruct deleted messages or prior revisions;
- reaction summaries are collected without unbounded reacting-user hydration;
- Message Content and Guild Members intent gaps remain partial, never complete;
- inaccessible, deleted, archived, or permission-revoked channels remain gaps;
- Gateway spools are prospective and their local retention/resume gaps remain
  explicit;
- exports are snapshots with operator-selected categories and an unstable
  package shape.

Discord Developer Policy prohibits scraping and using API message content to
train machine-learning or AI models without Discord's express permission. This
collector is for authorized private evidence retrieval and does not grant model
training rights. Apply corpus isolation, retention, deletion, and user-consent
rules independently of technical API visibility.

## Official evidence checked 2026-07-31

- [Discord Developer Platform](https://docs.discord.com/developers/intro.md)
- [Application resource and current application](https://docs.discord.com/developers/resources/application.md)
- [Guild resource](https://docs.discord.com/developers/resources/guild.md)
- [Channel, message-history, thread, and archived-thread routes](https://docs.discord.com/developers/resources/channel.md)
- [Gateway](https://docs.discord.com/developers/events/gateway.md)
- [Gateway events](https://docs.discord.com/developers/events/gateway-events.md)
- [Permissions](https://docs.discord.com/developers/topics/permissions.md)
- [Rate limits](https://docs.discord.com/developers/topics/rate-limits.md)
- [Discord Developer Policy](https://docs.discord.com/developers/policies/developer-policy.md)
