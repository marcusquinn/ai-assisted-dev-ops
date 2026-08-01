---
description: Safe WhatsApp knowledge ingestion from explicit chat exports or verified official business webhooks
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# WhatsApp Knowledge Ingestion

WhatsApp evidence has two isolated, read-only routes:

1. a chat export created deliberately by the user; or
2. a WhatsApp Business Platform `messages` webhook whose raw body, app-secret
   signature, WABA ID, and receiving phone-number ID all verify.

There is no fallback to WhatsApp Web, Baileys, browser automation, personal
sessions, local database extraction, cloud-backup access, or backup decryption.
If neither safe route supplies a category, coverage records it as unavailable.

## User chat exports

WhatsApp's help pages describe exporting one individual or group chat, with or
without media. As revalidated on 2026-07-31, the documented limits are the latest
40,000 messages without media or 10,000 with media. WhatsApp does not publish a
stable machine-readable transcript schema. The collector therefore requires an
explicit format and fixed UTC offset instead of guessing locale or timezone.
One fixed offset is only user-asserted provenance; split exports at daylight-saving
transitions or accept partial timestamp coverage rather than inventing offsets.

Supported parser profiles:

| Profile | Timestamp shape |
|---------|-----------------|
| `android-us-12h` | `M/D/YY, H:MM AM - Sender: text` |
| `android-dmy-24h` | `D/M/YYYY, HH:MM - Sender: text` |
| `ios-us-12h` | `[M/D/YY, H:MM:SS AM] Sender: text` |
| `ios-dmy-24h` | `[D/M/YYYY, HH:MM:SS] Sender: text` |

First run a no-write plan:

```bash
python3 ~/.aidevops/agents/scripts/knowledge_social_whatsapp.py export \
  --archive /path/to/whatsapp-export.zip \
  --connection-id private_connection_alias \
  --conversation-id private_conversation_alias \
  --format android-dmy-24h \
  --timezone +01:00 \
  --observed-at 2026-07-31T12:00:00Z \
  --dry-run
```

Remove `--dry-run` only after the counts and selected format are correct. The
ZIP must contain exactly one UTF-8 transcript. Archive members are bounded and
checked for traversal, duplicate paths, encryption, links, compressed and actual
size, compression ratio, item count, and elapsed time. Archive input defaults to
128 MiB and cannot exceed 512 MiB; `--max-seconds` defaults to 30 and cannot
exceed 300. Media is streamed for hashing rather than retained in parser memory.
Media links require an exact unique basename. Missing media remains explicit
partial coverage.

Exports preserve multiline text, participant display aliases, normalized times,
duplicate occurrence ordinals, system notices, and embedded media hashes. They
do not claim structured reply, reaction, edit, deletion, or complete-history
coverage because WhatsApp does not document those fields in its export format.

## Official business webhooks

The Business Platform path is prospective. It is not a personal-account route
and it has no general `GET messages` history endpoint. The collector accepts
only `whatsapp_business_account` `messages` changes after all of these checks:

- `X-Hub-Signature-256` is HMAC-SHA-256 of the exact raw body using the app secret;
- `entry.id` equals the configured WABA ID;
- `metadata.phone_number_id` equals the configured receiving phone ID; and
- every accepted message, status, media, reaction, and reply reference has a
  bounded provider identity and timestamp. Provider-supplied media digests are
  validated as 32-byte base64 values but remain unverified until bytes hydrate.

Store the app secret securely, never in repository files or command history:

```bash
aidevops secret set WHATSAPP_APP_SECRET
```

The offline adapter reads the secret from `WHATSAPP_APP_SECRET` and the signature
from `WHATSAPP_WEBHOOK_SIGNATURE` by default, keeping both out of process
arguments. A
production HTTP receiver should pass the unmodified request body and signature
header directly to `parse_business_webhook`, persist before acknowledging, and
never log payloads, phone numbers, WABA IDs, signatures, or message text.

Inbound text, reply context, reactions, media metadata, and delivery statuses
are normalized when present. Media download is intentionally unreachable in
this collector; a later authorized hydrator must enforce official URL expiry,
MIME, hash, byte, and retention limits. Template lifecycle, missed events,
personal groups, history before subscription, and a complete retrospective
edit/delete audit remain explicit gaps.

## Replay, privacy, and retention

- Raw exports and webhook bodies are SHA-256 addressed in the private corpus.
- Replaying identical bytes with an identical normalized manifest creates no
  duplicate batch, message, media, activity, or checkpoint. A parser, format,
  timezone, identity, or normalized-output change creates a separate manifest
  revision over the same immutable raw blob so prior evidence remains readable.
- Export and business-event streams use separate fenced leases and checkpoints.
- Stable normalized participant keys are hashed. Display aliases and any raw
  provider identifiers remain private inside the access-controlled corpus.
- Parser or Graph API changes require explicit versioned evidence revisions; they
  never silently rewrite or delete prior raw evidence.
- A source deletion, disappearing message, or missing attachment never causes
  automatic canonical deletion.

## Official evidence reviewed 2026-07-31

- [Android chat export](https://faq.whatsapp.com/1180414079177245/?cms_platform=android)
- [iPhone chat export](https://faq.whatsapp.com/196737011380816/?cms_platform=iphone)
- [Cloud API overview](https://developers.facebook.com/docs/whatsapp/cloud-api/overview)
- [Webhook components](https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/components)
- [Graph API webhook verification](https://developers.facebook.com/docs/graph-api/webhooks/getting-started)
- [Cloud API data privacy and security](https://developers.facebook.com/docs/whatsapp/cloud-api/overview/data-privacy-and-security)
- [Media reference](https://developers.facebook.com/docs/whatsapp/cloud-api/reference/media)
- [WhatsApp Terms of Service](https://www.whatsapp.com/legal/terms-of-service)
- [WhatsApp Business Terms](https://www.whatsapp.com/legal/business-terms)

Meta and WhatsApp documentation is version- and account-sensitive. Revalidate
the pinned Graph API payload fields, retention, group eligibility, and terms
before enabling a live receiver. An undocumented field is preserved only as raw
evidence or reported as a gap; it is never treated as stable authority.
