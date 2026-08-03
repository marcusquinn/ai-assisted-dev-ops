<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Hashnode Account Knowledge Collection

`knowledge_social_hashnode.py` collects bounded, read-only evidence for one
authenticated Hashnode author. It uses the official GraphQL endpoint with nine
fixed read-query documents; callers cannot supply GraphQL text, operation names,
fields, or mutation-capable routes.

## Identity and authority contract

Configure one personal access token through secure environment injection:

```text
HASHNODE_<PROFILE>_PAT
```

Use `--account-id` with the stable ID returned by the authenticated `me` query.
Before collection and every page, the child re-reads `me` and requires both that
ID and the selected username to match. Publication, post, draft, comment target,
and reaction target reads additionally verify that their author or publication
owner is the selected account. Team publications or provider-side permission
changes therefore fail closed rather than widening collection.

## Implemented streams

| Stream | Fixed read surface | Disposition |
|---|---|---|
| `profile` | authenticated `me` | **Live** |
| `publications` | authenticated viewer's owned publications | **Live/Gate**: publication access remains provider-plan-bound |
| `posts` | selected user's authored posts | **Live** |
| `drafts` | drafts inside each verified owned publication | **Live/Gate**: requires provider-side publication and Pro access |
| `comments` | comments received on verified authored posts | **Live/Partial**: nested reply pages and comments authored elsewhere are not available |
| `reactions` | accounts in `likedBy` on verified authored posts | **Live/Partial**: this is received likes, not the viewer's reaction history |
| `followers` | authenticated viewer followers | **Live/Partial**: current visible snapshot only |
| `following` | authenticated viewer follows | **Live/Partial**: current visible snapshot only |

Messages, notifications, account-centric authored-comment history, and
account-centric reaction history have no verified official query and remain
**No**. The privacy policy provides an account-data access route, but the public
JSON export guide is historical and publishes neither a current versioned schema
nor a stable identity contract. Archive ingestion therefore remains
**Export/Gate** until a current private fixture proves those boundaries.

## Pagination, cost, and persistence

Every stream owns an independent versioned checkpoint. Simple GraphQL
connections preserve their opaque `endCursor`. Drafts, comments, and reactions
use versioned nested state so the outer publication or post cursor cannot be
confused with the inner connection cursor. A repeated cursor, malformed edge,
partial GraphQL response, or ownership mismatch stops before page persistence.

The initial identity query costs one local unit. Every page reserves two units:
one repeated identity query and one fixed stream query. `--budget` is 3-1000 and
`--page-size` is 1-50, below the documented ordinary 100-item and draft 50-item
connection limits. The official guidance also documents a maximum query depth of
10, a 100 KB request body, and an advisory request ceiling; the collector's fixed
documents and local budget are stricter independent fuses.

Successful pages atomically commit immutable raw evidence, normalized rows,
coverage, a receipt, and the next checkpoint. Terminal responses append bounded
diagnostic evidence without advancing or replacing the prior checkpoint.
Credential-shaped values, stale leases, partial GraphQL errors, malformed nodes,
redirects, arbitrary queries, subscriptions, and mutations are rejected.

## Completeness and retention boundaries

Snapshot completion means only that the current API-visible connection was
exhausted; it never infers deletion. Visibility can depend on account state,
publication ownership, team authority, and Hashnode Pro access. Hashnode does not
publish a complete social-activity ledger or a fixed retention guarantee for all
account categories, so historical completeness and deleted resources remain
explicit gaps.

## Official evidence checked 2026-08-02

- <https://github.com/Hashnode/gql-skill>
- <https://github.com/Hashnode/gql-skill/blob/ebd06df0fe29d00d2e7f6e3673fefdbe8ef57b3d/skills/gql-api/SKILL.md>
- <https://github.com/Hashnode/gql-skill/blob/ebd06df0fe29d00d2e7f6e3673fefdbe8ef57b3d/skills/gql-api/references/schema.graphql>
- <https://github.com/Hashnode/gql-skill/blob/ebd06df0fe29d00d2e7f6e3673fefdbe8ef57b3d/skills/gql-api/references/queries.md>
- <https://github.com/Hashnode/gql-skill/blob/ebd06df0fe29d00d2e7f6e3673fefdbe8ef57b3d/skills/gql-api/references/auth-and-roles.md>
- <https://github.com/Hashnode/gql-skill/blob/ebd06df0fe29d00d2e7f6e3673fefdbe8ef57b3d/skills/gql-api/references/errors-and-limits.md>
- <https://github.com/Hashnode/support/blob/ef1109bb3e0b05549d235871db7d040aa2e08142/docs/export-articles.md>
- <https://hashnode.com/privacy>
- <https://hashnode.com/terms>
