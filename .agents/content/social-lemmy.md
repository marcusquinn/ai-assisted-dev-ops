<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Lemmy Account Knowledge Collection

`knowledge-social-helper.sh sync-lemmy` collects bounded account-visible evidence
from one exact Lemmy home instance. The collector discovers the authenticated
local person and exact server version before selecting a route and before every
persisted page. It never treats the v3 and v4 APIs as interchangeable.

## Runtime, profile, and identity contract

No `lemmy-js-client` package is installed in the collector runtime. Python 3.12.3
standard-library `urllib.request.Request`, `build_opener`,
`HTTPRedirectHandler`, `urlencode`, and `urlsplit` exports were verified before
implementing the HTTP and error contracts. The child creates only
`method="GET"` requests, rejects redirects, caps responses at 8 MiB, and accepts
only an exact allowlisted path/query shape.

Configure one profile through secure environment injection:

```text
LEMMY_<PROFILE>_BASE_URL
LEMMY_<PROFILE>_ACCESS_TOKEN
LEMMY_<PROFILE>_ORIGIN_KEY
LEMMY_<PROFILE>_AUTH_MODE=user_token
```

The base URL must be an HTTPS origin without credentials, subpath, query, or
fragment. `ORIGIN_KEY` must be a securely stored random value of at least 32
bytes. HMAC-SHA-256 over that key and the canonical origin produces a private
24-character installation namespace. The host, token, and origin key never enter
evidence, cursors, receipts, output, or errors. Only a selected user token is
accepted; service, application, administrator, and mutation profiles are not
wired.

Use `--account-id person_<POSITIVE_NUMERIC_ID>`. `GET /api/v3/site` is the
cross-version discovery route. The child requires
`my_user.local_user_view.person`, matches its local numeric ID, requires
`local=true`, and retains the person's ActivityPub identity. Lemmy 1.x uses the
v4 family and its `person.ap_id`; Lemmy 0.19.x uses the v3 family and
`person.actor_id`. Malformed and all other versions fail closed.

Instance-local person, post, comment, community, notification, reply, mention,
and multicommunity IDs are persisted only as a resource kind plus a digest under
the installation namespace. Equal numeric IDs on different instances therefore
cannot collide. Provider ActivityPub IDs remain in allowlisted evidence for
federated identity and citation.

## Version-specific live streams

| Stream | Lemmy 1.x / API v4 | Lemmy 0.19.x / API v3 |
|---|---|---|
| `authored_posts` | `GET /api/v4/person/content?type_=posts` | `GET /api/v3/user`, `posts` envelope |
| `authored_comments` | `GET /api/v4/person/content?type_=comments` | `GET /api/v3/user`, `comments` envelope |
| `saved_posts` | `GET /api/v4/account/saved?type_=posts` | `GET /api/v3/post/list?saved_only=true` |
| `saved_comments` | `GET /api/v4/account/saved?type_=comments` | `GET /api/v3/comment/list?saved_only=true` |
| `liked_posts` | `GET /api/v4/account/liked?type_=posts&like_type=liked_only` | `GET /api/v3/post/list?liked_only=true` |
| `liked_comments` | `GET /api/v4/account/liked?type_=comments&like_type=liked_only` | `GET /api/v3/comment/list?liked_only=true` |
| `notifications` | `GET /api/v4/account/notification/list` | Not sent to v3; use the split streams. |
| `replies` | Not sent to v4; represented by unified notifications. | `GET /api/v3/user/replies` |
| `mentions` | Not sent to v4; represented by unified notifications. | `GET /api/v3/user/mention` |
| `subscriptions` | `GET /api/v4/community/list?type_=subscribed` | `GET /api/v3/community/list?type_=Subscribed` |
| `multicommunities` | `GET /api/v4/multi_community/list?type_=subscribed` | Unavailable in the verified v3 contract. |

Every supported stream has its own connection checkpoint. A v4 checkpoint stores
the server-provided `next_page` as an opaque `page_cursor`; its versioned envelope
binds the exact server version and can never decode as a v3 cursor. A v3
checkpoint stores only the next positive numeric `page` and never reaches a v4
route. `--page-size` is 1-50. After a completed authored or inbox backfill, a
later run starts from the newest page and crosses the prior timestamp by one
second before stopping, allowing boundary records to replay idempotently. Saved,
liked, subscription, and multicommunity state has no verified membership-action
timestamp, so those streams rescan to provider exhaustion as current-state
snapshots without inferring deletion.

The initial identity read costs one request unit. Every page reserves two more:
one `/api/v3/site` identity/version recheck and one version-specific data read.
`--budget` is a hard 3-1000 request-unit allowance. Raw response, normalized rows,
coverage, cursor, and receipt commit atomically under a final lease fence. Exact
replay is content-addressed. Credential-shaped data, malformed pages, identity or
instance rebinding, exact-version drift, terminal responses, and stale leases do
not advance the previous checkpoint.

## Explicit boundaries

Every successful page records these unavailable or partial-history boundaries:

- home-instance visibility is not complete federated history;
- operator permissions and retention can remove or hide earlier evidence;
- settings and backup routes are not a verified complete account export;
- private-message bodies are not collected, including through v4 notification
  metadata;
- current saved/liked state is not immutable vote or curation history;
- deleted or purged content is unavailable through current account reads; and
- v4 notifications/multicommunities and v3 split inbox routes remain mutually
  exclusive version gaps.

No private-message body route, settings mutation, save/like action, notification
mark-read action, follow action, administrator route, browser collector,
non-GET request, or outbound operation is reachable from this provider.

## Official evidence checked 2026-08-02

- <https://join-lemmy.org/api/main>
- <https://join-lemmy.org/lemmy-js-client-docs/v0.19/classes/LemmyHttp.html>
- <https://join-lemmy.org/docs/print.html#api>
