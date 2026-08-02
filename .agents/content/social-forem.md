<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Forem Account Knowledge Collection

`knowledge_social_forem.py` exposes a provider-local collector contract for a
hosted or self-hosted Forem installation. DEV Community is the first named
installation, but every profile is bound to one exact origin. Equal user,
article, tag, or relationship IDs on separate installations never become the
same corpus identity. Shared CLI registration and capability-matrix claims are
deferred to #28867.

## Runtime, API key, and installation contract

The collector uses Python standard-library `urllib.request.Request`,
`urllib.request.build_opener`, `urllib.request.HTTPRedirectHandler`,
`urllib.parse.urlencode`, and `urllib.parse.urlsplit`. Those local exports were
verified before implementing provider response and error handling. No Forem
client package is imported.

Configure one profile through secure environment injection:

```text
FOREM_<PROFILE>_BASE_URL
FOREM_<PROFILE>_API_KEY
FOREM_<PROFILE>_ORIGIN_KEY
FOREM_<PROFILE>_AUTH_MODE=user_api_key
```

Use a user-generated API key for the selected account. The provider sends the
official API v1 media type in `Accept` and the key only in the `api-key` header.
The HTTP boundary constructs only `method="GET"` requests. Read-only means no
article, reaction, follow, moderation, message, notification, organization,
export, or account mutation; normal server access logging may still occur.

`ORIGIN_KEY` must be a securely stored random value of at least 32 bytes. The
base URL must be HTTPS and contain no credentials, query, fragment, encoded
path, dot segment, or `/api`/`/admin` suffix; a fixed installation subpath is
allowed. Redirects are rejected. HMAC-SHA-256 over the canonical base and the
profile-specific origin key creates a 24-character installation namespace. The
host, subpath, API key, and origin key never enter persisted evidence,
checkpoints, receipts, output, or errors.

Use `--account-id user_<NUMERIC_ID>`. Before collection and before every page,
the child calls `GET /api/users/me`, matches the positive `id`, and binds the
returned `username` and installation fingerprint. Account, username, origin, or
connection rebinding fails before persistence or checkpoint advancement. The
identity serializer drops fields such as email, website, location, social
handles, image URLs, and badges before the child returns data.

## Implemented API v1 streams

| Stream | Exact official read route | Coverage |
|---|---|---|
| `authored_articles` | `GET /api/articles/me/all?page=N&per_page=M` | Current authenticated user's published and unpublished article index records. Every returned author ID must equal the selected account. |
| `reading_list` | `GET /api/readinglist?page=N&per_page=M` | Current saved-article snapshot. Forem documents these as `save` reactions; the provider does not claim complete reaction history. |
| `followed_tags` | `GET /api/follows/tags` | Current followed-tag snapshot. The official route documents no pagination, so the provider accepts one bounded page only. |
| `followers` | `GET /api/followers/users?page=N&per_page=M&sort=-created_at` | Current inbound follower snapshot ordered newest first. No outbound-follow claim is made. |

`--page-size` is 1-100. Paginated endpoints use only numeric `page` and
`per_page`; followers additionally use the fixed `-created_at` sort. The current
official schema does not expose a next cursor, so a full page advances by one
page and a short page completes the snapshot. This can make one final empty
request when the count is an exact page multiple, but never follows response
URLs. Responses are capped at 8 MiB and each page at 100 items.

The initial identity read costs one request unit. Every page reserves two more:
one identity recheck and one data route. `--budget` is a hard 3-1000 request-unit
allowance. Every installation and stream has an independent cursor. All four
mutable lists rescan as bounded snapshots because article publication state and
relationship membership can change. Raw response, normalized rows, explicit
coverage, cursor, and receipt commit atomically under the shared final lease
fence. Exact replay is content-addressed.

Only allowlisted IDs, bounded titles/descriptions/names, timestamps, slugs, and
counts cross the provider boundary. Error bodies, URLs, images, emails, API
keys, credentials, arbitrary response fields, and account-private profile data
do not.

## Explicit gaps, exports, retention, and terms

Every successful page records unavailable coverage for account-wide authored
comments, reactions beyond the reading-list projection, outbound following,
organization membership, notifications, messages, account exports,
deleted/purged content, and installation retention.

The official API v1 schema includes article-specific comments and reaction
mutation routes but does not establish a complete selected-user authored-comment
or reaction-history route. Public article comments therefore cannot stand in
for account-wide history. The schema likewise does not establish account-bound
routes for outbound user follows, organization memberships, notifications, or
messages. Admin, browser/session, search, and public-profile fallbacks remain
disabled.

No stable official user-export route or fixture-validated archive schema was
identified in the checked API specification and source tests. The provider does
not initiate, discover, download, or import exports. Each installation's own
terms, privacy notice, permissions, retention, moderation, and deletion rules
govern collection; DEV-specific policy does not automatically govern another
Forem installation. Operators must validate installation authorization outside
the corpus before configuring a profile.

## Official evidence checked 2026-08-01

- Forem docs revision `27a0a24d87d423a52041b01803bb8453b0581e1b`.
- Forem source revision `84ef2b91b415b6cc86c39ca55c0ffb8522751b69`.
- [Official API guidance](https://github.com/forem/forem-docs/blob/main/docs/api.md)
- [Official API v1 specification](https://github.com/forem/forem-docs/blob/main/api_v1.json)
- [API v1 article request specifications](https://github.com/forem/forem/blob/84ef2b91b415b6cc86c39ca55c0ffb8522751b69/spec/requests/api/v1/articles_spec.rb)
- [API v1 article documentation tests](https://github.com/forem/forem/blob/84ef2b91b415b6cc86c39ca55c0ffb8522751b69/spec/requests/api/v1/docs/articles_spec.rb)
- [API v1 followed-tag documentation tests](https://github.com/forem/forem/blob/84ef2b91b415b6cc86c39ca55c0ffb8522751b69/spec/requests/api/v1/docs/followed_tags_spec.rb)
- [API v1 follower documentation tests](https://github.com/forem/forem/blob/84ef2b91b415b6cc86c39ca55c0ffb8522751b69/spec/requests/api/v1/docs/followers_spec.rb)
