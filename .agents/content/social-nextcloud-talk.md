<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Nextcloud Talk Knowledge Collection

`knowledge_social_nextcloud_talk.py` collects bounded, account-visible evidence
from explicitly allowlisted rooms on one Nextcloud installation. The provider is
not registered in `knowledge-social-helper.sh` yet; shared registration and the
aggregate capability matrix belong to #28867.

## Runtime and private profile

The adapter was validated with Python 3.14 standard-library `urllib.request` and
`urllib.parse` exports. It imports no Nextcloud client package. Configure each
installation through secure environment injection:

```text
NEXTCLOUD_TALK_<PROFILE>_BASE_URL=https://cloud.example.invalid
NEXTCLOUD_TALK_<PROFILE>_USERNAME=selected-account
NEXTCLOUD_TALK_<PROFILE>_APP_PASSWORD=<secure-value>
NEXTCLOUD_TALK_<PROFILE>_ORIGIN_KEY=<random-value-at-least-32-bytes>
NEXTCLOUD_TALK_<PROFILE>_ALLOWED_ROOMS=<comma-separated-room-tokens>
NEXTCLOUD_TALK_<PROFILE>_EXPECTED_SERVER_MAJOR=32
NEXTCLOUD_TALK_<PROFILE>_EXPECTED_TALK_MAJOR=22
```

Store values with `aidevops secret set NAME` or another mode-0600 secret store.
Never put URLs, usernames, tokens, room names, app passwords, origin keys,
webhook headers, files, or messages in repository configuration. An app password
is a revocable account credential, not an endpoint-scoped grant. Use a dedicated
account with membership only in intended rooms, then apply the room-token
allowlist as a second boundary.

The base URL must be exact HTTPS with no credentials, query, fragment, encoded
path, or redirect. HMAC-SHA-256 over the canonical base URL and private origin
key creates an installation namespace. Account, room, participant, message, and
attachment IDs are opaque and installation-scoped; equal native IDs on separate
servers cannot collide.

## Identity and capability fence

Before collection and before every page, the isolated child performs only GET
requests and verifies:

1. `/ocs/v2.php/cloud/capabilities` reports the configured Nextcloud and Talk
   major versions and includes `chat-v2` plus `conversation-v4`.
2. `/ocs/v2.php/cloud/user` is the configured account.
3. `/ocs/v2.php/apps/spreed/api/v4/room` contains every configured room token as
   a current membership.
4. The selected opaque room identity still maps to the same allowlist position.

Version, account, installation, room, or membership drift stops before raw
evidence or checkpoints advance. Responses are capped at 16 MiB. Room lists are
capped at 100 configured rooms, participants at 500 per room, and chat pages at
200 messages. `--budget` is a hard bounded-read allowance.

## Streams and persistence

| Stream | Official GET surface | Behavior |
|---|---|---|
| `capabilities` | cloud capabilities, current user, Talk rooms | Records exact tested versions and an allowlist of knowledge-relevant features. |
| `rooms` | Talk API v4 `/room` | Stores allowlisted room type, name, current membership role, read-only state, expiration, activity, unread count, call state, and federation observation. |
| `participants` | Talk API v4 `/room/{token}/participants` | Stores bounded user, guest, email, and federated participant snapshots independently per room. |
| `messages` | Talk API v1 `/chat/{token}` | Reads history with `lookIntoFuture=0`, `setReadMarker=0`, `noStatusUpdate=1`, and `markNotificationsAsRead=0`; follows only `X-Chat-Last-Given`. |

Each top-level stream has its own lease and database checkpoint. The messages
cursor additionally carries a separate opaque watermark and current history
position for every allowlisted room. Initial history and later refreshes converge
on the same object IDs. A final lease fence atomically commits raw OCS evidence,
normalized rows, coverage, receipt, and the next cursor.

Messages preserve replies, edit timestamps, deletion observations, aggregated
reactions, mentions, system events, call summaries, poll/object-share signals,
and message-linked attachment metadata when returned by the tested version and
account. Attachment URLs and paths are discarded. `_files.py` validates already
authorized bytes against MIME, size, digest, and hard byte budgets, but live
WebDAV hydration stays disabled until file identity and authorization can be
revalidated without broadening Files access.

## Webhooks and honest gaps

OCS history is the recovery authority. The optional webhook module verifies the
exact backend plus `HMAC-SHA256(random-header || raw-body)`, rejects non-allowlisted
rooms, produces replay-stable event IDs, and marks every event for OCS
reconciliation. It is not wired as a standalone persistence or recovery route.

Coverage remains unavailable rather than complete for content removed before
observation, history outside retention/membership/expiration, encrypted or
otherwise unreadable content, complete reaction actor history, separately fetched
poll details, call recording content, attachment bytes, and webhook-only history.
Authorization loss, malformed OCS envelopes, unsupported versions, 401/403/404,
429, 5xx, maintenance, and federation failures preserve the prior cursor.

No send-message, reaction mutation, moderation, participant, room, call, poll,
file-share, read-marker, or bot write route is accepted. Existing Talk dispatch
credentials and outbound code remain separate.

## Verification

```bash
bash .agents/tests/test-knowledge-social-nextcloud-talk.sh
bash .agents/tests/test-knowledge-social-sync.sh
bash .agents/tests/test-knowledge-social.sh
python3 -m compileall -q .agents/scripts
.agents/scripts/linters-local.sh --changed
```

Synthetic Talk 21 and Talk 22 fixtures cover multi-instance identity, room and
message pagination, independent room resume, replay-stable IDs, edits/deletions,
reactions, replies, mentions, guests/federation, call and poll observations,
attachment budgets, webhook signatures, terminal authorization, credentials,
and a static GET-only reachability check.

## Official evidence checked 2026-07-31

- [Talk capabilities](https://nextcloud-talk.readthedocs.io/en/latest/capabilities/)
- [Global API status](https://nextcloud-talk.readthedocs.io/en/latest/global/)
- [Conversation API v4](https://nextcloud-talk.readthedocs.io/en/latest/conversation/)
- [Participant API v4](https://nextcloud-talk.readthedocs.io/en/latest/participant/)
- [Chat API v1](https://nextcloud-talk.readthedocs.io/en/latest/chat/)
- [Reaction API](https://nextcloud-talk.readthedocs.io/en/latest/reaction/)
- [Poll API](https://nextcloud-talk.readthedocs.io/en/latest/poll/)
- [Bots and webhooks](https://nextcloud-talk.readthedocs.io/en/latest/bots/)
