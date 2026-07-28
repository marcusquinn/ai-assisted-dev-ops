<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Discourse Account Knowledge Collection

`knowledge-social-helper.sh sync-discourse` collects bounded account-visible
metadata from one hosted or self-hosted Discourse installation. Each profile is
one installation connection. The collector never treats equal user, topic, post,
or group IDs on different installations as the same social identity.

## Runtime and authorization contract

The collector uses Python's standard-library `urllib.request.Request`,
`urllib.request.build_opener`, `urllib.request.HTTPRedirectHandler`,
`urllib.parse.urlencode`, and `urllib.parse.urlsplit` exports. These exports were
verified with Python 3.14.3 on 2026-07-28. No `pydiscourse`, `discourse-api`, or
`discourse_api` client was installed or imported, so there is no third-party
response or error mapping to drift from the installed runtime.

Configure one profile through secure environment injection:

```text
DISCOURSE_<PROFILE>_BASE_URL
DISCOURSE_<PROFILE>_USER_API_KEY
DISCOURSE_<PROFILE>_ORIGIN_KEY
DISCOURSE_<PROFILE>_USER_API_SCOPE=read
```

The API key must be a current-user User API key issued with the exact `read`
scope. Core currently maps `read` to GET requests only, while `write` permits GET,
POST, PATCH, PUT, and DELETE. The child rejects any profile that does not declare
exactly `read`; it does not accept admin API keys or `Api-Username`
impersonation. Scope declaration is an operator assertion, so the transport also
enforces an exact path/query allowlist and constructs only `method="GET"`
requests.

`ORIGIN_KEY` must be a securely stored, random value of at least 32 bytes. The
base must be HTTPS, contain no credentials, query, fragment, encoded path, or dot
segment, and may include a fixed installation subpath. Redirects are not
followed. HMAC-SHA-256 over the canonical base and profile-specific origin key
produces the 24-character installation namespace. Changing either the origin or
key breaks connection rebinding, while another corpus/key cannot dictionary-map
or correlate the persisted namespace. The host, subpath, and origin key never
enter records, checkpoints, receipts, collector output, or errors.

Use `--account-id user_<NUMERIC_ID>` so even one- or two-digit Discourse IDs meet
the provider-neutral opaque CLI contract. The child calls
`GET /session/current.json`, compares its numeric ID with that selector, and
binds the returned username and installation fingerprint. It repeats the same
identity read before every page. A changed user, username, profile origin, or
connection binding fails before that page can persist evidence or advance a
checkpoint.

## Implemented streams

| Stream | Exact read route | Coverage |
|---|---|---|
| `authored_topics` | `GET /user_actions.json`, action filter `4` | Authored topic metadata and excerpts, offset pagination, newest-topic watermark. |
| `authored_posts` | `GET /user_actions.json`, action filter `5` | Authored reply/post metadata and excerpts, offset pagination, newest-post watermark. |
| `likes` | `GET /user_actions.json`, action filter `1` | Full paginated current-state snapshot of API-visible likes given by the selected user. |
| `bookmarks` | `GET /u/{selected_username}/bookmarks.json` | Full paginated current-state snapshot, bounded to 20 per page; provider pagination URLs are treated only as a boolean continuation signal and are never followed. |
| `notifications` | `GET /notifications.json` | Full paginated current-state snapshot of notification IDs, types, read flags, topic references, and timestamps. Pagination uses the numeric total, never the returned URL; the side-effect-prone `recent` query is unreachable. |
| `private_messages` | `GET /topics/private-messages/{selected_username}.json` | Full paginated snapshot of received/private topic-list metadata only, permission-gated by the selected account. |
| `sent_messages` | `GET /topics/private-messages-sent/{selected_username}.json` | Full paginated snapshot of sent private-topic metadata only, permission-gated by the selected account. |
| `reading_state` | `GET /u/{selected_username}/topic-tracking-state.json` | Bounded current topic tracking snapshot, not a historical reading-event log. |
| `groups` | allowlisted fields already returned by `GET /session/current.json` | Current selected-user group memberships and owner/message flags. |
| `category_preferences` | `GET /session/current.json`, then `GET /categories.json` | Watched, tracked, muted, regular, and watched-first-post category IDs resolved against visible category metadata. Unknown private IDs remain explicit unresolved records. |

`--page-size` is 1-20 for routes that accept a client limit. Private-message
topic lists use the installation's fixed page size and reject responses over 100
items. Reading-state, group, category, and identity preference snapshots reject
responses over 1000 items. The 8 MiB response cap remains independent of these
item limits. The initial identity read reserves one request unit and each page
reserves two units for identity rebinding plus at most one selected data route.
The groups stream conservatively reserves the same amount even though its data
comes from the repeated identity response. `--budget` is a hard 3-1000-unit
allowance.

Every stream has an independent cursor under its connection. Authored-content
offsets carry the previous newest-item watermark; mutable likes, bookmarks,
notifications, messages, reading state, groups, and category preferences rescan
as snapshots so changed flags/counts are not hidden behind a stable resource ID.
Successful raw page, normalized rows, coverage, cursor, and receipt commit
atomically under the final lease fence, and exact replay is content-addressed.
The boundary serializes only allowlisted IDs, bounded text, timestamps, counts,
booleans, and preference levels. Provider error bodies, URLs, avatars, email
fields, secure uploads, and credential-shaped keys never cross into persistence.

## Explicit gaps, exports, retention, and terms

Every successful page records unavailable coverage for:

- `account_archive`: no current private sample has validated the archive schema;
- `followers` and `following`: the official Follow feature is an optional plugin
  and its unpaginated installation behavior is not enabled here;
- `watched_topics` and `tracked_topics`: search-based inventories remain disabled
  until current-version fixtures prove pagination and side-effect behavior;
- `private_message_bodies`: thread bodies, attachments, and secure uploads are
  intentionally outside the metadata collector;
- `complete_reading_history`: core exposes current tracking state, not a
  documented complete event history.

Core archive initiation is `POST /export_csv/export_entity`, creates server
state, consumes a non-admin daily allowance, and can act on another user when
privileged. Current source retains generated user exports for roughly two days,
but does not publish a stable archive packaging/schema contract. The collector
therefore cannot initiate, poll, download, or import an archive. A future manual
import requires a separately validated, user-initiated private sample.

There is no universal self-hosted retention or plugin contract. Installation
version, settings, authorization, moderation, and site policy govern what the
current user can read and how long it remains available. CDCK's privacy policy
applies to its own processing, not every customer installation. The Meta
Discourse terms prohibit automated access except their stated exception; those
terms do not automatically govern another installation. Operators must verify
authorization and the selected installation's terms before enabling a profile.
The adapter records `installation_policy_and_current_user_visibility` rather
than claiming complete history or a universal retention window.

No browser collector, mutation route, archive action, admin path, plugin path,
or outbound operation is wired for Discourse.

## Official evidence checked 2026-07-28

- [Discourse API Documentation](https://docs.discourse.org/openapi.json)
- [User API key scopes](https://github.com/discourse/discourse/blob/main/app/models/user_api_key_scope.rb)
- [Current session controller](https://github.com/discourse/discourse/blob/main/app/controllers/session_controller.rb)
- [Current-user serializer](https://github.com/discourse/discourse/blob/main/app/serializers/current_user_serializer.rb)
- [User actions controller](https://github.com/discourse/discourse/blob/main/app/controllers/user_actions_controller.rb)
- [User action types](https://github.com/discourse/discourse/blob/main/app/models/user_action.rb)
- [Users controller](https://github.com/discourse/discourse/blob/main/app/controllers/users_controller.rb)
- [Notifications controller](https://github.com/discourse/discourse/blob/main/app/controllers/notifications_controller.rb)
- [Core routes](https://raw.githubusercontent.com/discourse/discourse/main/config/routes.rb)
- [Export CSV controller](https://github.com/discourse/discourse/blob/main/app/controllers/export_csv_controller.rb)
- [User export retention model](https://github.com/discourse/discourse/blob/main/app/models/user_export.rb)
- [Official Discourse Follow plugin](https://github.com/discourse/discourse-follow)
- [Discourse privacy policy](https://www.discourse.org/privacy)
- [Meta Discourse terms](https://meta.discourse.org/tos)
