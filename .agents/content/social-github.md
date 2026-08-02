<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GitHub Account Knowledge Collection

`knowledge_social_github.py` collects bounded, read-only evidence from one
GitHub.com user account. It combines the immutable REST numeric account ID with
the GraphQL node ID. Mutable login is retained only as display and route context.
Resource IDs use type-qualified digests of provider IDs.

## Profile and authority contract

Configure credentials through secure environment injection:

```text
GITHUB_<PROFILE>_ACCESS_TOKEN
GITHUB_<PROFILE>_TOKEN_FAMILY=classic_pat|fine_grained_pat|oauth_user_token
GITHUB_<PROFILE>_SCOPES="read:user,notifications"
```

`SCOPES` records declared classic OAuth scopes; provider-side authorization
remains authoritative. Notifications reject fine-grained PAT profiles because
the documented endpoint does not support them. Other missing permissions remain
explicit provider capability outcomes rather than completeness claims.

Use `--account-id account_<NUMERIC_ID>`. Before collection and every page, the
child reads REST `GET /user` and a fixed GraphQL `viewer` query. REST `id` and
`node_id` must equal GraphQL `databaseId` and `id`; login must also agree. No
evidence is persisted until this binding succeeds.

## Implemented streams

| Stream | Read surface | Pagination |
|---|---|---|
| `contributions` | GraphQL `viewer.contributionsCollection.contributionCalendar` | bounded current calendar |
| `repositories` | REST `GET /user/repos` | `Link` |
| `stars` | REST `GET /user/starred` | `Link` |
| `notifications` | REST `GET /notifications` | `Link` |
| `followers` | REST `GET /user/followers` | `Link` |
| `following` | REST `GET /user/following` | `Link` |
| `organizations` | REST `GET /user/orgs` | `Link` |
| `subscriptions` | REST `GET /user/subscriptions` | `Link` |
| `user_lists` | GraphQL `viewer.lists` | `pageInfo` |
| `projects_v2` | GraphQL `viewer.projectsV2` | `pageInfo` |

The initial identity phase reserves two request units. Every page reserves three
more for repeated REST and GraphQL identity checks plus one stream read.
`--budget` is 5-1000 and `--page-size` is 1-100.

Complete REST `rel=next` URLs and GraphQL `endCursor` strings are stored inside a
versioned opaque checkpoint. REST resume validates HTTPS `api.github.com`, the
exact stream route, allowlisted query keys, unique parameters, and bounded
`per_page`, then replays the URL unchanged. GraphQL variables accept only fixed
read-query cursors. Redirects, REST mutation routes, arbitrary GraphQL text,
mutations, and subscriptions are unreachable.

## Boundaries

Successful pages record unavailable coverage for complete reactions, migration
archives, deleted resources, resources outside current token visibility, and
organization audit logs. User migration archives expire after seven days and do
not contain broad social state. Contribution calendars are bounded views, not a
complete event ledger. Snapshot completion never infers deletion.

Primary and secondary GitHub limits remain authoritative. HTTP 403 and 429
terminal outcomes pause collection without advancing the checkpoint; the local
request, item, and response-byte limits are independent stricter fuses.

## Official evidence checked 2026-08-02

- <https://docs.github.com/en/rest/users/users>
- <https://docs.github.com/en/graphql/reference/users>
- <https://docs.github.com/en/rest/activity/notifications>
- <https://docs.github.com/en/rest/activity/starring>
- <https://docs.github.com/en/rest/migrations/users>
- <https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api>
