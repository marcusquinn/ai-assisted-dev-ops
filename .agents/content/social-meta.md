---
description: Bounded Facebook, Instagram, and Threads account knowledge ingestion
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Meta Account Knowledge

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Collector**: `knowledge-social-helper.sh sync-meta`
- **Products**: `facebook`, `instagram`, or `threads`; select exactly one
- **Auth**: externally provisioned product token, never a browser session
- **Live routes**: managed Facebook Page posts, Instagram Professional media,
  and Threads posts, authored replies, or mentions
- **Isolation**: one filtered token, stable identity, provider namespace, stream
  registry, checkpoint, and coverage record per product
- **Mutation boundary**: collector modules issue only allowlisted `GET` requests

<!-- AI-CONTEXT-END -->

## Evidence boundary

The account-knowledge routes were revalidated on 2026-07-27. The local runtime
has Python 3.14.3 and standard-library `urllib.request.Request` and `urlopen`
exports. `facebook-sdk`, `facebook-business`, `requests`, and `urllib3` are not
installed. The collector therefore maps only HTTP status classes and documented
response fields; it does not import a third-party Meta client or guess SDK error
symbols.

The official Python Business SDK release `25.0.3`, published 2026-07-17, is the
version reference for Facebook and Instagram Graph surfaces:
https://github.com/facebook/facebook-python-business-sdk/releases/tag/25.0.3.
Its generated Page object exposes the GET-only `/posts` edge and documented Page
Post fields:
https://github.com/facebook/facebook-python-business-sdk/blob/542e10e31c40f7925f9ac03c000922a2fd0a2365/facebook_business/adobjects/page.py.
Its generated IG User object exposes the GET-only `/media` edge and the selected
media fields:
https://github.com/facebook/facebook-python-business-sdk/blob/542e10e31c40f7925f9ac03c000922a2fd0a2365/facebook_business/adobjects/iguser.py.

The official Threads sample is the route and field reference for app-scoped
identity, `/me/threads`, `/me/replies`, and `/me/mentions`:
https://github.com/fbsamples/threads_api. The source checkpoint reviewed was
https://github.com/fbsamples/threads_api/commit/854fc140a37e20f6a7086cf3ee0065f99d41f646.
The sample source uses `graph.threads.com`; its synchronized Postman collection
still names `graph.threads.net`. The collector sends reads only to the current
sample source host and accepts cursor metadata from either official host after
requiring the exact versioned edge and matching `after` cursor.

## Authorization boundary

Store each token outside git as:

```text
META_<PROFILE>_<FACEBOOK|INSTAGRAM|THREADS>_ACCESS_TOKEN
```

Use `aidevops secret set` rather than a project file. The parent process exposes
only the token for the selected profile and product to the read subprocess.
Facebook, Instagram, and Threads tokens are not interchangeable merely because
Meta operates each product.

| Product | Stable identity | Required gate recorded by the collector |
|---|---|---|
| Facebook | Selected numeric managed Page ID | Page access token, Page authority, `pages_read_engagement`; `pages_show_list` is relevant to external provisioning; app review applies outside app-role accounts. |
| Instagram | Selected numeric Page-connected IG User ID | Business or Creator account, connected Facebook Page, `instagram_basic`, `pages_read_engagement`, and applicable review. Personal accounts are not accepted as covered. |
| Threads | App-scoped numeric `/me` ID | Threads app user token and product-specific reviewed scopes: `threads_basic`, plus `threads_read_replies` or `threads_manage_mentions` for the selected stream. |

Official Facebook Login for Business context:
https://developers.facebook.com/docs/facebook-login/facebook-login-for-business.
The official Instagram sample records the Business-account, connected-Page, and
Page-task gates at https://github.com/fbsamples/original-coast-clothing-ig and
links the product overview at
https://developers.facebook.com/docs/instagram-api/overview#pages and
https://developers.facebook.com/docs/instagram-api/overview#tasks.

The official Threads sample requests `threads_basic`, `threads_read_replies`,
and `threads_manage_mentions` among its product permissions. See
https://github.com/fbsamples/threads_api/blob/854fc140a37e20f6a7086cf3ee0065f99d41f646/src/index.js
and the access-token guide at
https://developers.facebook.com/docs/threads/get-started/get-access-tokens-and-permissions.
Token provisioning and long-lived-token refresh remain operator-owned; see
https://developers.facebook.com/docs/threads/get-started/long-lived-tokens.

## Implemented routes

Every invocation verifies the selected identity before collection and again
before each page. A page reserves two request units: one rebinding check and one
list GET. The initial identity check reserves one unit. `--budget` is therefore
3-1000 and `--page-size` is 1-50.

| Product | Stream | Fixed edge | Allowlisted content |
|---|---|---|---|
| Facebook | `posts` | `/{page-id}/posts` | ID, message, created/updated time, parent, permalink, status type |
| Instagram | `media` | `/{ig-user-id}/media` | ID, caption, media type/product type, metadata URL references, permalink, timestamp, username, documented counts |
| Threads | `posts` | `/me/threads` | ID, text, media type/URL reference, permalink, timestamp, username |
| Threads | `replies` | `/me/replies` | Same bounded field set for the selected user's replies |
| Threads | `mentions` | `/me/mentions` | Same bounded field set; stored as observed evidence without fabricating selected-account authorship |

Threads profile and media route references are
https://developers.facebook.com/docs/threads/threads-profiles#retrieve-a-threads-user-s-profile-information
and
https://developers.facebook.com/docs/threads/threads-media#retrieve-a-list-of-all-a-user-s-threads.
Reply traversal semantics are documented at
https://developers.facebook.com/docs/threads/reply-management#replies.

Graph paging URLs are never replayed. The child accepts only an HTTPS URL on an
official product host whose path exactly matches the requested account edge,
extracts a matching opaque `after` cursor, and drops the URL and any query token
before returning data to the parent. Each product/stream cursor is versioned and
stored independently. A successful page, immutable allowlisted response,
normalized rows, coverage, and next cursor commit in one fenced transaction.

```bash
knowledge-social-helper.sh sync-meta --product facebook \
  --connection-id conn_facebook --account-id PAGE_GRAPH_ID \
  --stream posts --profile personal --budget 11 --page-size 25

knowledge-social-helper.sh sync-meta --product instagram \
  --connection-id conn_instagram --account-id IG_GRAPH_ID \
  --stream media --profile personal --budget 11 --page-size 25

knowledge-social-helper.sh sync-meta --product threads \
  --connection-id conn_threads --account-id THREADS_GRAPH_ID \
  --stream posts --profile personal --budget 11 --page-size 25
```

## Explicit coverage and exports

| Product | Category | Disposition |
|---|---|---|
| Facebook | Managed Page-authored posts | Live/Gate |
| Facebook | Personal-profile content, saved/curated activity, relationships, messages | No; Page API authority is not personal-account authority. |
| Facebook | Comments | No in this collector; requires a separately bounded per-post traversal and permission review. |
| Facebook | Account download | Export candidate only; no current private schema was validated and no importer is exposed. |
| Instagram | Professional-account media | Live/Gate |
| Instagram | Comments and mentions | No in this collector; each requires a separate edge, permission, and pagination contract. |
| Instagram | Followers/following and saved collections | No verified Graph list edge. |
| Instagram | Account download | Export candidate only; no current private schema was validated and no importer is exposed. |
| Threads | Posts, authored replies, mentions | Live/Gate with stream-specific scopes. |
| Threads | Like/repost history, follower/following lists, messages, custom feeds | No verified account-list edge. |
| Threads | Account download | Export candidate only; no current private schema was validated and no importer is exposed. |

`Export` is evidence of a possible operator fallback, not successful collection.
No archive route is wired until a current private sample establishes stable file
identity, pagination/replay semantics, credential rejection, and product-local
coverage. Browser capture remains outside this collector and requires the
separate approved browser-gap workflow.

## Retention and safety

- The reviewed official sample is Meta Platform Policy licensed; its policy
  reference is http://developers.facebook.com/policy/. No broader
  collector-specific long-term storage grant was verified.
- Every live stream therefore records the conservative retention boundary
  `delete_when_no_longer_needed_or_authorized_under_meta_platform_terms`.
  Operators must stop collection and remove affected evidence when authority or
  lawful purpose ends, or when provider/user deletion obligations require it.
- Unexpected fields are dropped, but credential-shaped keys anywhere in an
  identity or page item reject the whole page before raw evidence or cursors are
  written.
- HTTP error bodies and exceptions never cross the child boundary. Parent
  diagnostics contain only status-derived failure class and bounded retry time.
- The provider module has no mutation endpoint registry and every constructed
  HTTP request fixes `method="GET"`. It does not import browser or outbound
  operations modules.
