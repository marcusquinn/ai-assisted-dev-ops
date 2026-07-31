<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Bluesky and AT Protocol Account Knowledge Collection

`knowledge_social_bluesky.py` collects one bounded account stream at a time.
The stable account key is the DID. Handles and PDS locations are mutable aliases;
changing either does not create another account. Every page repeats DID and
service-fingerprint checks before the shared atomic evidence/checkpoint commit.

## Runtime and authorization

No AT Protocol client dependency is installed. The collector uses Python's
standard-library `urllib` exports and the lexicons at official atproto commit
`5782f195e834b5af80e5bcc163c4247893b95e0a` (checked 2026-07-31). This avoids
inventing SDK methods while preserving exact XRPC NSIDs.

Inject one private profile through the secure credential environment:

```text
BLUESKY_<PROFILE>_ACCESS_TOKEN
BLUESKY_<PROFILE>_HANDLE
BLUESKY_<PROFILE>_PDS_URL
BLUESKY_<PROFILE>_APPVIEW_SERVICE
BLUESKY_<PROFILE>_AUTH_MODE=app_password_session
BLUESKY_<PROFILE>_CHAT_ENABLED=0
BLUESKY_<PROFILE>_CHAT_SERVICE
```

Set `CHAT_ENABLED=1` only for a separately authorized chat service. AppView and
chat service values are DID URL identities with service fragments; their reads
are proxied through the independently verified PDS with `Atproto-Proxy`. The
access JWT is therefore never sent to an operator-configured AppView/chat
origin. The isolated child can construct only HTTPS `GET` requests to an exact
query allowlist. XRPC procedures—including record writes,
follow/like/repost/list/feed/moderation/preference/notification mutations and
chat sends/reactions/deletes—are unreachable. Redirects, URL credentials,
queries, fragments, non-root service paths, unsafe profile names, and missing
tokens fail closed. `AUTH_MODE=oauth` is rejected because this stdlib boundary
does not implement mandatory DPoP proofs and nonce rotation. A short-lived
access JWT from an app-password session is accepted; the write-capable session
does not widen the local GET-only route boundary.

Use the DID, not the handle, as `--account-id`. `resolveHandle` verifies the
configured alias. The live adapter independently resolves `did:plc` through the
PLC directory, requires its `#atproto_pds` service to equal the configured PDS,
then uses `describeRepo` as a second fence. PDS and AppView/chat service
identities are stored only as 24-character SHA-256 fingerprints. A legitimate
PDS migration restarts a stale service-fenced cursor
for the same DID and converges by AT URI/CID rather than rebinding the account.

## Authority and stream map

| Authority | Streams | Source contract |
|---|---|---|
| PDS repository | `profile`, `posts`, `reposts`, `likes`, `follows`, `blocks`, `lists`, `list_items`, `feed_generators`, `starter_packs`, `labeler_services` | `com.atproto.repo.listRecords`; preserves AT URI, CID, collection/rkey content, and current record revision evidence. |
| PDS sync | `repo_status`, `blobs` | `com.atproto.sync.getRepoStatus` and `listBlobs`; blob metadata only. |
| AppView | `author_feed`, `notifications`, `preferences`, `bookmarks`, `mutes`, `appview_lists`, `appview_starter_packs`, `labels` | Derived/current account views with independent cursors and explicit AppView provenance. Notifications cover retained mentions/replies/quotes; preferences carry saved/custom feeds and moderation choices when returned. |
| Chat | `chat_conversations`, `chat_log` | Separately gated `chat.bsky.convo.listConvos` and `getLog`; messages, reactions, and deletions remain chat events, never repository truth. |
| Export | `repository_export` | Explicit unavailable coverage until a private CAR sample validates bounded binary import. No export procedure is invoked. |

Each stream has an independent cursor and a hard request budget. `--page-size`
is 1-100 and `--budget` is 7-1000 request units. Three units are reserved for
independent PLC, repository, and handle identity checks; each page costs four
units for repeated identity fences plus its data query. Provider cursors are wrapped
with DID, stream, and service identity. A changed service safely restarts that
stream; a changed DID or cross-stream cursor fails closed. Repository/AppView/
chat overlap converges through DID plus AT URI/CID or a content-derived fallback,
without treating missing AppView state as a repository deletion.

Complete historical tombstones, CAR bytes, blob bytes, PDS migration history,
and chat export remain explicit unavailable coverage. Fixture evidence can
normalize provider-supplied tombstones and revisions, but the snapshot APIs do
not claim a complete deletion history. Rate limits, denied private/chat access,
malformed JSON, service rebinding, and cursor errors preserve prior evidence and
do not advance checkpoints.

## Official evidence checked 2026-07-31

- [Official atproto source](https://github.com/bluesky-social/atproto)
- [Verified lexicon commit](https://github.com/bluesky-social/atproto/commit/5782f195e834b5af80e5bcc163c4247893b95e0a)
- [AT Protocol DID contract](https://atproto.com/specs/did)
- [AT Protocol OAuth contract](https://atproto.com/specs/oauth)
- Repository and sync lexicons under `lexicons/com/atproto/repo` and `lexicons/com/atproto/sync`
- Bluesky actor, feed, graph, bookmark, notification, and labeler lexicons under `lexicons/app/bsky`
- Separately authorized chat lexicons under `lexicons/chat/bsky`

The local dependency check found neither Python `atproto` nor npm
`@atproto/api`; runtime mappings therefore use only the verified official
lexicon symbols above.
