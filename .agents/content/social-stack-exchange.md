<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Stack Exchange Account Knowledge Collection

`knowledge_social_stack_exchange.py` collects bounded, read-only API v2.3
evidence for one selected Stack Exchange site account. Durable identity combines
the network `account_id`, configured `api_site_parameter`, and per-site `user_id`.
Equal local user or content IDs on different sites never collide.

## Profile and authority contract

Configure credentials through secure environment injection:

```text
STACK_EXCHANGE_<PROFILE>_ACCESS_TOKEN
STACK_EXCHANGE_<PROFILE>_SITE=stackoverflow
STACK_EXCHANGE_<PROFILE>_SCOPES="read_inbox private_info"
```

Scopes are optional unless the selected stream requires one. `inbox` requires
`read_inbox`. `write_access` and unknown scopes are rejected, and the child has
no write routes. Access tokens are sent only through the authorization header;
tokens, response credentials, and arbitrary private fields never persist.

Use `--account-id account_<NETWORK_ACCOUNT_ID>`. Before collection and every
page, the child calls `GET /2.3/me` for the configured site and verifies the
network and site user IDs. No evidence is committed until rebinding succeeds.

## Implemented streams

| Stream | Official GET route | Scope |
|---|---|---|
| `posts` | `/me/posts` | identify |
| `questions` | `/me/questions` | identify |
| `answers` | `/me/answers` | identify |
| `comments` | `/me/comments` | identify |
| `favorites` | `/me/favorites` | identify |
| `inbox` | `/me/inbox` | `read_inbox` |
| `notifications` | `/me/notifications` | authenticated account |
| `associated_accounts` | `/me/associated` | identify |

The initial identity request costs one unit and every page reserves two more for
identity rebinding and one stream read. `--budget` is 3-1000 and `--page-size` is
1-100.

Each stream has an independent versioned page cursor containing the configured
site. Collection advances only while the response wrapper says `has_more`.
Malformed wrappers, `backoff`, zero quota, credential-shaped fields, terminal
responses, and lease loss preserve the previous checkpoint. `backoff` seconds
become an explicit retry epoch; the local request, item, response-byte, and page
limits remain stricter independent fuses.

All transport requests target exact allowlisted paths under
`https://api.stackexchange.com/2.3`, use `GET`, reject redirects, and accept only
allowlisted paging, site, and filter parameters. The built-in `withbody` filter
retains authored text while normalization discards unselected fields.

## Boundaries

Successful pages record unavailable coverage for complete votes, follows,
subscriptions, lists, projects, a verified complete account archive, and site
history outside current API visibility. Associated-account responses expose site
URLs but not a complete cross-network archive. Snapshot completion never infers
deletion.

The API documents a default 10,000-request user/application daily quota, a
30-request/second/IP ceiling, method-specific `backoff`, and heavy caching.
Collectors avoid speculative pages and stop on every returned `backoff` or quota
exhaustion. Mandatory account rebinding is the only intentionally repeated
identity request; stream page requests advance monotonically.

## Official evidence checked 2026-08-02

- <https://api.stackexchange.com/docs>
- <https://api.stackexchange.com/docs/authentication>
- <https://api.stackexchange.com/docs/me-associated-users>
- <https://api.stackexchange.com/docs/me-posts>
- <https://api.stackexchange.com/docs/me-favorites>
- <https://api.stackexchange.com/docs/me-inbox>
- <https://api.stackexchange.com/docs/paging>
- <https://api.stackexchange.com/docs/throttle>
