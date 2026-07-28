<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# NodeBB Account Knowledge Collection

`knowledge-social-helper.sh sync-nodebb` collects bounded account-visible data
from one hosted or self-hosted NodeBB installation. Each profile is one exact
installation connection. Equal user, topic, post, category, group, notification,
or room IDs on different installations never become the same corpus identity.

## Runtime, token, and installation contract

The collector uses Python standard-library `urllib.request.Request`,
`urllib.request.build_opener`, `urllib.request.HTTPRedirectHandler`,
`urllib.parse.urlencode`, and `urllib.parse.urlsplit`. These local exports were
verified before implementing provider response and error handling. No NodeBB
client package is imported, so the adapter maps only current official HTTP
schemas rather than an unverified installed dependency.

Configure one profile through secure environment injection:

```text
NODEBB_<PROFILE>_BASE_URL
NODEBB_<PROFILE>_BEARER_TOKEN
NODEBB_<PROFILE>_ORIGIN_KEY
NODEBB_<PROFILE>_TOKEN_TYPE=user
```

Use a dedicated **user** bearer token. NodeBB master tokens require `_uid` and
can impersonate arbitrary users; the collector rejects every token-type
declaration except `user` and never sends `_uid`. The HTTP boundary constructs
only `method="GET"` requests. NodeBB bearer authentication can create a temporary
server session and API-usage metadata, so “read-only” means no forum content,
relationship, notification, chat, moderation, export, or plugin mutation.

`ORIGIN_KEY` must be a securely stored random value of at least 32 bytes. The
base URL must be HTTPS and contain no credentials, query, fragment, encoded path,
or dot segment; a fixed installation subpath is allowed. Redirects are rejected.
HMAC-SHA-256 over the canonical base and the profile-specific origin key creates
a 24-character installation namespace. The host, subpath, token, and origin key
never enter persisted evidence, checkpoints, receipts, output, or errors.

Use `--account-id user_<NUMERIC_UID>`. Before collection and before every page,
the child calls `GET /api/self`, matches the positive `uid`, and binds the
returned `userslug` and installation fingerprint. Account, slug, origin, or
connection rebinding fails before persistence or checkpoint advancement.

## Implemented core streams

| Stream | Exact core read route | Coverage |
|---|---|---|
| `capabilities` | `GET /api/v3/ping`, then `GET /api/config` | v3 reachability plus allowlisted account-visible flags; exact version and plugin inventory remain explicit admin-only gaps. |
| `authored_topics` | `GET /api/user/{selected_userslug}/topics?page=N` | Caller-visible authored topic metadata/content with an independent incremental watermark. |
| `authored_posts` | `GET /api/user/{selected_userslug}/posts?page=N` | Caller-visible authored post metadata/content with an independent incremental watermark. |
| `upvoted` | `GET /api/user/{selected_userslug}/upvoted?page=N` | Current accessible upvoted post set, not immutable vote history. |
| `downvoted` | `GET /api/user/{selected_userslug}/downvoted?page=N` | Current accessible downvoted post set, not immutable vote history. |
| `bookmarks` | `GET /api/user/{selected_userslug}/bookmarks?page=N` | Current permission-gated bookmark snapshot. |
| `watched_topics` | `GET /api/user/{selected_userslug}/watched?page=N` | Current followed/watched topic snapshot. |
| `category_state` | `GET /api/user/{selected_userslug}/categories?page=N` | Visible category subscription/watch state. |
| `following` | `GET /api/user/{selected_userslug}/following?page=N` | Current visible outbound follows. |
| `followers` | `GET /api/user/{selected_userslug}/followers?page=N` | Current visible inbound follows. |
| `groups` | `GET /api/user/{selected_userslug}/groups` | Current profile-visible group memberships; hidden/plugin semantics stay installation-specific. |
| `notifications` | `GET /api/notifications?page=N` | Paginated account-visible retained notifications without marking them read. |
| `chat_rooms` | `GET /api/v3/chats?start=N&perPage=M` | Current authorized room metadata only; message bodies are not enabled. |

`--page-size` is 1-50 and sets the v3 chat page size. Legacy account routes use
their installation/user-configured page size and are rejected above 100 items.
Provider `pagination.next.active/page` or the v3 chat `nextStart` value controls
continuation; returned URLs are never followed and absent pagination is treated
as complete rather than inferred from an item count. Responses are capped at 8
MiB and one-page snapshots at 100 items. The initial identity read costs one
request unit. Most pages reserve two units for identity rebinding and one data
route; `capabilities` reserves two data requests after rebinding. `--budget` is a
hard 3-1000 request-unit allowance.

Every stream owns an independent cursor under its connection. Authored content
uses a newest-item watermark; mutable account state rescans as bounded snapshots.
Raw response, normalized rows, coverage, cursor, and receipt commit atomically
under a final lease fence. Exact replay is content-addressed. Only allowlisted
IDs, bounded text, timestamps, counts, booleans, and state labels cross the
provider boundary. Error bodies, URLs, avatars, emails, tokens, uploads, and
credential-shaped keys do not.

## Explicit gaps, plugins, exports, retention, and terms

Every successful page records unavailable coverage for exact product version,
plugin inventory, plugin-provided lists, chat message bodies, account exports,
complete vote history, deleted/purged content, and installation retention.

Exact NodeBB version is exposed through an admin development route that also
returns host/process details. Installed and active plugin versions are likewise
admin-only. Core provides no public plugin manifest, while plugins can add
arbitrary routes under `/api/v3/plugins`. This collector therefore uses only
core routes and never widens one installation based on another installation's
plugins. Operators may record version/plugin evidence outside the corpus, but it
does not authorize a plugin route.

Core can download an already-generated `profile` JSON, `posts` CSV, or `uploads`
ZIP export when the selected account has permission. Creating an export is a
POST that creates server state, logs an event, and sends a notification. Because
existing exports are highly sensitive and no private sample has validated an
import contract, neither export creation nor download is wired.

There is no generic public endpoint for an installation's retention, privacy
policy, plugin data, or deletion guarantees. Current permissions, categories,
groups, blocks, moderation, pruning, and site policy bound every result. The
installation's own terms and privacy notice govern authorization; NodeBB Inc.'s
site/hosting terms do not automatically govern independent installations.

No browser collector, admin route, plugin route, `/api/v1` or `/api/v2` write
plugin, export action, non-GET request, or outbound operation is wired for NodeBB.

## Official evidence checked 2026-07-28

- [NodeBB v4.14.2 release](https://github.com/NodeBB/NodeBB/releases/tag/v4.14.2)
- [Official Read API specification](https://try.nodebb.org/assets/openapi/read.yaml)
- [Official REST v3 specification](https://try.nodebb.org/assets/openapi/write.yaml)
- [Current-user schema](https://try.nodebb.org/assets/openapi/read/self.yaml)
- [Config schema](https://try.nodebb.org/assets/openapi/read/config.yaml)
- [Pagination schema](https://try.nodebb.org/assets/openapi/components/schemas/Pagination.yaml)
- [Core account routes](https://github.com/NodeBB/NodeBB/blob/master/src/routes/user.js)
- [Core API routes](https://github.com/NodeBB/NodeBB/blob/master/src/routes/api.js)
- [v4.14.2 account post controller](https://github.com/NodeBB/NodeBB/raw/refs/tags/v4.14.2/src/controllers/accounts/posts.js)
- [v4.14.2 follow controller](https://github.com/NodeBB/NodeBB/raw/refs/tags/v4.14.2/src/controllers/accounts/follow.js)
- [v4.14.2 chat controller](https://github.com/NodeBB/NodeBB/raw/refs/tags/v4.14.2/src/controllers/write/chats.js)
- [Deprecated Write API plugin](https://github.com/NodeBB/nodebb-plugin-write-api)
- [NodeBB GDPR guidance](https://nodebb.org/gdpr)
- [NodeBB privacy policy](https://nodebb.org/privacy)
- [NodeBB terms](https://nodebb.org/tos)
