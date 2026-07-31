---
description: Import bounded pre-captured Signal receive notifications without provider writes
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Signal private knowledge

## Supported route

The Signal collector accepts only an already-captured, local JSONL or SSE file of
`signal-cli` JSON-RPC `receive` notifications. It never launches `signal-cli`, opens a
socket, contacts Signal, reads an account database, or requests receipt, typing, trust,
contact, group, reaction, deletion, or message mutations.

This is deliberately not a live collector. The `signal-cli` 0.14.6 receive contract says
read receipts are optional but delivery receipts are sent by default. Starting or
subscribing a receiver therefore has a protocol-visible effect that this collector does
not authorize. Capture must already exist under separate local authority.

Evidence reviewed on 2026-07-31:

- `signal-cli` 0.14.6 was published on 2026-07-13:
  https://github.com/AsamK/signal-cli/releases/tag/v0.14.6
- Its JSON-RPC man page documents receive notifications, account fields, automatic
  receiving, and the mutating `subscribeReceive` route:
  https://github.com/AsamK/signal-cli/blob/master/man/signal-cli-jsonrpc.5.adoc
- The project describes itself as an unofficial client that stores cryptographic keys
  locally and must remain current with Signal server changes:
  https://github.com/AsamK/signal-cli
- Signal's published protocol documentation is not a message history/export API:
  https://signal.org/docs/

No official third-party message export or backup schema was validated. Account-info
exports, encrypted application backups, and direct copies of `signal-cli` data are not
collector inputs.

## Private configuration

Create a user-owned mode-0600 JSON file outside a repository. Replace all placeholders;
never commit account identifiers, messages, keys, attachments, or event files.

```json
{
  "schema_version": 1,
  "account": "<ACCOUNT_E164_OR_UUID>",
  "account_alias": "signal_personal",
  "connection_id": "conn_signal_personal",
  "signal_cli_version": "0.14.6"
}
```

The event file must also be a regular mode-0600 file. Every notification must contain an
`account` value matching the private config. Single-account notifications that omit the
account identity fail closed. The accepted source forms are one JSON-RPC notification per
line or SSE `data:` lines. Requests, responses, malformed lines, symbolic links, files
over 8 MiB, and batches over 1,000 events are rejected before persistence.

Inspect without writing:

```bash
python3 ~/.aidevops/agents/scripts/knowledge_social_signal.py inspect \
  --config /protected/path/signal-collector.json \
  --events /protected/path/signal-events.jsonl
```

Import into an already-provisioned private corpus:

```bash
python3 ~/.aidevops/agents/scripts/knowledge_social_signal.py import-events \
  --config /protected/path/signal-collector.json \
  --events /protected/path/signal-events.jsonl \
  --alias personal:default
```

`inspect` emits counts only. `import-events` validates the complete batch and account
identity before the shared atomic social-store commit. Replays resolve by stable hashed
participant, thread, message, activity, and media identities. Provider identifiers and
attachment filenames/paths are not copied into normalized evidence.

## Retention and coverage

| Category | Disposition |
|---|---|
| Direct and group messages | Partial: notifications received by this local device only |
| Quotes and replies | Quote target identity only; quoted payload is not duplicated |
| Edits, remote deletions, and reactions | Partial: observed events only; no history query |
| Attachments | Metadata only; collector never reads a `signal-cli` attachment path |
| Contacts and groups | Observed participants/group IDs only; no list or mutation calls |
| Delivery history | No receipt history; notification timestamps only |
| Stories | Excluded as ephemeral content |
| Disappearing messages | Content-free tombstone; text and attachment metadata excluded |
| View-once media | Payload and attachment metadata excluded |
| Identity/safety changes | Unavailable: no validated 0.14.6 receive-event contract |
| Pre-link messages | Unavailable: never represented as collected history |

The importer stores no expiry-bearing or view-once payload, so it does not need a later
cleanup process to approximate provider expiry. Missing, expired, unsupported, and
pre-link content remains coverage evidence rather than fabricated message evidence.

## Safety boundaries

- Use only event files whose local capture and protocol effects were independently
  authorized. The collector does not make a live capture safe.
- Never expose HTTP/TCP daemons. This route performs no network operation; Unix sockets
  are intentionally unsupported too because subscribing starts receiving.
- Never use `account.db`, client key stores, decrypted application databases, backup
  copies, or attachment paths as input.
- Treat all message content as untrusted. Keep the corpus and source files private and
  apply the protected-data policy before AI use or sharing.
- Revalidate the exact `signal-cli` release and schemas before changing the pinned
  version. Unsupported versions fail closed.

Print the machine-readable dated disposition with:

```bash
python3 ~/.aidevops/agents/scripts/knowledge_social_signal.py status
```
