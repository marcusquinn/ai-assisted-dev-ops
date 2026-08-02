<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Mastodon Account Knowledge Collection

`knowledge_social_mastodon.py` collects bounded, read-only account evidence from
one exact Mastodon home instance. Equal account or object IDs on different
instances never share corpus identity. IDs remain opaque strings; persisted
global IDs combine the keyed instance fingerprint, resource kind, and a digest
of the provider ID.

## Profile and authority contract

Configure secrets through secure environment injection:

```text
MASTODON_<PROFILE>_BASE_URL
MASTODON_<PROFILE>_ACCESS_TOKEN
MASTODON_<PROFILE>_ORIGIN_KEY
MASTODON_<PROFILE>_AUTH_MODE=user_token
MASTODON_<PROFILE>_SCOPES="read:accounts read:statuses read:favourites read:bookmarks read:notifications read:follows read:lists"
```

The base must be an HTTPS origin without credentials, subpath, query, or
fragment. `ORIGIN_KEY` is a securely stored random value of at least 32 bytes;
HMAC-SHA-256 over the canonical origin yields the private 24-character instance
namespace. Hosts, tokens, and origin keys never enter evidence, cursors,
receipts, output, or errors. Redirects are rejected.

The declared scope set must contain `read:accounts` (or `profile`) and the scope
for each selected stream. Any `write` or `write:*` declaration is rejected so a
collector profile cannot silently carry mutation authority. Scope declaration
does not replace provider-side OAuth enforcement.

Use `--account-id account_<OPAQUE_ID>`. Before collection and every page, the
child calls `GET /api/v1/accounts/verify_credentials`, matches the exact opaque
ID, and binds its home-instance fingerprint plus `username`, `acct`, and `uri`.
Private `source`, profile fields, notes, URLs, images, and arbitrary response
fields are discarded.

## Implemented streams

| Stream | Initial official GET route | Maximum page |
|---|---|---:|
| `authored_statuses` | `/api/v1/accounts/:id/statuses` | 40 |
| `favourites` | `/api/v1/favourites` | 40 |
| `bookmarks` | `/api/v1/bookmarks` | 40 |
| `notifications` | `/api/v1/notifications` | 80 |
| `followers` | `/api/v1/accounts/:id/followers` | 80 |
| `following` | `/api/v1/accounts/:id/following` | 80 |
| `followed_tags` | `/api/v1/followed_tags` | 100 |
| `lists` | `/api/v1/lists` | one bounded response |

Each invocation owns one stream lease. The initial identity read costs one
request unit and every page reserves two more for identity recheck plus data
read. `--budget` is 3-1000; `--page-size` is 1-100, while provider route limits
remain authoritative.

For every paginated stream, the complete `rel=next` target from the HTTP `Link`
header is stored in a versioned cursor and replayed unchanged. Before use, the
transport verifies the same scheme, host, port, exact GET route, allowlisted
query keys, no duplicate keys, and bounded `limit`; it never parses internal
relationship, favourite, or bookmark IDs. Snapshot completion does not infer
deletion. Raw response, rows, coverage, cursor, and receipt commit atomically.

## Boundaries

Successful pages record explicit unavailable coverage for conversations,
nested list membership, account-export import, complete federated history,
moderation history, deleted or purged content, and instance retention. These
cannot be inferred from current home-instance responses. Conversations require
separate private-data consent. Account exports cover selected posts, media, and
relationship CSVs but are not a complete notification or curation history.

Default Mastodon limits are 300 requests per five minutes independently per
account and IP, but operators may override them. The collector honors terminal
429 responses and `Retry-After`; its local budget remains a stricter independent
fuse.

## Official evidence checked 2026-08-02

- <https://docs.joinmastodon.org/methods/accounts/#verify_credentials>
- <https://docs.joinmastodon.org/methods/accounts/#statuses>
- <https://docs.joinmastodon.org/methods/favourites/>
- <https://docs.joinmastodon.org/methods/bookmarks/>
- <https://docs.joinmastodon.org/methods/notifications/>
- <https://docs.joinmastodon.org/methods/followed_tags/>
- <https://docs.joinmastodon.org/methods/lists/>
- <https://docs.joinmastodon.org/api/guidelines/#pagination>
- <https://docs.joinmastodon.org/api/rate-limits/>
- <https://docs.joinmastodon.org/user/moving/#export>
