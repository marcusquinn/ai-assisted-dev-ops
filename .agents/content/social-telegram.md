---
description: Safe Telegram Desktop export and Bot API event-fan-out knowledge ingestion
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Telegram Knowledge Ingestion

Telegram knowledge ingestion is deliberately separate from the write-capable bot
integration. It supports two private, bounded, network-free inputs:

1. an official Telegram Desktop **JSON** account export selected by account and
   chat identity; and
2. append-only Bot API updates delivered by an existing durable webhook or
   polling owner.

The collector never logs in to Telegram, calls the Bot API, starts `getUpdates`,
changes a webhook, downloads a tokenized file, sends a message, or performs chat
administration. HTML exports and TDLib account sessions remain disabled until
their schemas and a practical no-write/session guarantee can be independently
validated.

## Commands

```bash
python3 .agents/scripts/knowledge_social_telegram.py import-export \
  --input /private/export/result.json --connection-id telegram_export \
  --expected-id ACCOUNT_ID --allow-chat CHAT_ID \
  --observed-at 2026-07-30T10:10:00Z --dry-run

python3 .agents/scripts/knowledge_social_telegram.py import-updates \
  --input /private/events/batch.json --connection-id telegram_bot_events \
  --expected-id BOT_ID --owner-id DURABLE_OWNER_ID --allow-chat CHAT_ID \
  --observed-at 2026-07-30T10:20:00Z
```

Use only private paths outside Git. Provision the target corpus first. Keep bot
tokens, webhook headers, phone numbers, chat names/IDs, messages, exports, and
media in owner-only storage; command output is limited to hashes, counts, route
names, and checkpoint state.

## Export contract

- The JSON root must carry the Telegram Desktop provenance marker and one
  `personal_information.user_id` matching `--expected-id`.
- The raw export must contain exactly the explicitly allowlisted chat set; a
  full-account export cannot be partially projected while its unselected raw
  chats are still retained. Message identity is
  `chat:<chat-id>:message:<message-id>`, so an authorized later Bot API event can
  update the same projection without creating a second truth.
- Locale-dependent timestamps require Telegram's Unix timestamp. Otherwise the
  source timestamp must contain an explicit timezone.
- Relative regular media files are copied to immutable private storage under a
  total byte budget. Missing media stays partial coverage; paths never appear in
  receipts.
- Standard exports do not establish normal deletion completeness or Secret Chat
  coverage. HTML exports are preserved as an explicit unsupported route.

## Bot event contract

The collector accepts `telegram-bot-api-update-fanout-v1` envelopes only. The
upstream owner must attest `delivery: append_only_fanout` and
`authenticity_verified: true`, include a verified bot identity, explicit
`allowed_updates`, privacy mode, installation time, per-chat membership/admin
authority, owner ID, and raw `Update` objects. The owner ID is durably bound on
first commit; a competing owner fails before cursor advance.
Every accepted update must be attributable to an allowlisted chat. Standalone
poll answers, unsupported update types, business/guest messages, and ephemeral
message contexts remain explicit gaps rather than risking unscoped evidence or
colliding identities.

Telegram's official Bot API 10.2 documentation states that `getUpdates` and
webhooks are mutually exclusive, unconsumed updates are retained for no longer
than 24 hours, and an update is confirmed only when a later `getUpdates` offset
is submitted. This collector therefore does not own delivery: it advances only
its independent fan-out checkpoint after raw evidence, normalized projections,
coverage, and the current lease fence commit together.

The default Bot API update set excludes `chat_member`, `message_reaction`, and
`message_reaction_count`; those require explicit subscription, and some require
administrator rights. Privacy mode, installation time, membership, chat history
visibility, and channel administration constrain observations. Bots have no
arbitrary pre-install history and no Secret Chat route. General message deletion
updates are unavailable; only connected-business deletion observations are
currently represented.

Bot file identifiers and token-bearing download URLs are transport data. The
fan-out route stores only `file_unique_id`, MIME type, size, and `remote_only`
coverage. A separately authorized private owner may attach bytes in a future
version without giving this collector Bot API access.

The durable owner assigns a chat-scoped, contiguous `fanout_sequence` independent
of Telegram's global `update_id`. Fan-out sequences are deduplicated, sorted, and
required to be contiguous from the durable cursor, so omitted updates for other
chats cannot deadlock an authorized stream. A sequence gap fails without
advancing the cursor. Replayed sequences below that cursor remain immutable raw
observations but cannot overwrite newer message, account, activity, or media
projections.

## Coverage and official evidence

| Surface | Official export | Bot event fan-out |
|---|---|---|
| Direct/group/supergroup/channel messages | Selected exported chats | Prospective messages visible to the bot |
| Topics, replies, quotes, edits, polls, service events | Parsed when represented | Parsed from received update/message fields |
| Reactions and membership | Export snapshot when represented | Permission- and subscription-limited updates |
| Media metadata/bytes | Metadata plus bounded local bytes | Metadata only; no tokenized download |
| Contacts/chats/saved messages/subscriptions | Export-category dependent | No account-wide route |
| Stories | Export-schema gap until validated | No general Bot API story stream |
| Deletions | Not complete | Business deletions only |
| History before installation | Export route | Unavailable |
| Secret Chats | Unavailable in standard Desktop export | Unavailable to bots |

Official references verified on 2026-07-31:

- https://core.telegram.org/bots/api — Bot API 10.2, update types, delivery
  ownership, offsets, retention, webhook secret header, privacy/admin limits,
  and file behavior.
- https://core.telegram.org/tdlib — TDLib is a fully functional custom-client
  library with network and session authority. Its broad method surface does not
  prove a collector-level no-write guarantee, so this implementation records a
  gap instead of opening an account session.
- https://telegram.org/faq — cloud-chat synchronization and device-bound Secret
  Chat boundaries.

Run `bash .agents/tests/test-knowledge-social-telegram.sh` with synthetic data;
live accounts, tokens, sessions, and network access are not test requirements.
