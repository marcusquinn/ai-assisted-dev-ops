<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Notion Sites Knowledge Collection

`knowledge_social_notion.py` collects one bounded tree from explicit page UUIDs
through the official Notion API. It does not crawl a published Notion Site. A
public Site URL allows web viewing only and is never accepted as an account ID,
root selector, API credential, or collection grant.

## Current capability disposition

Checked against current official documentation on 2026-08-02. **Live** means the
fixture-tested adapter is reachable; **Gate** means the configured connection
must have the provider capability and content access; **Export** is a separate
owner/admin route not implemented by this adapter; **No** means the route is
deliberately unreachable.

| Category | Disposition | Boundary |
|---|---|---|
| Published root page and nested blocks/pages | **Live/Gate/Partial** | Integration bot, expected workspace UUID, and explicit root page UUIDs must all match. Only descendants returned by the API are scheduled. |
| Child databases and data-source rows | **Live/Gate/Partial** | Only `child_database` blocks discovered below a root are retrieved. Only their returned data-source IDs are queried. Linked references are not followed. |
| Open/unresolved page and block comments | **Live/Gate/Partial** | Disabled by default; requires the connection's read-comment capability. |
| Resolved comments | **Export/Gate** | The public API does not return them. HTML/workspace exports can include comments under owner/admin authority. No export importer is exposed here. |
| Notion-hosted files | **Live/Gate/Partial** metadata; **No** bytes | Kind and expiry metadata are retained without the signed URL. The one-hour URL is never fetched or persisted. |
| External files, embeds, bookmarks, and link previews | **No** fetch | Their presence is retained as URL-free metadata; targets, redirects, iframes, and previews are never fetched. |
| Workspace-wide Search | **No** | Search is title-oriented, eventually indexed, and not exhaustive. It is neither an authorization source nor an inventory route. |
| Unlisted public Site pages or Site metadata | **No** | A Site URL alone proves neither account identity nor integration access. |
| Workspace export | **Export/Gate** | UI export requires member/admin authority; Admin API export is Enterprise-only and uses separate organization-bot scope. |
| Mutations, webhooks, browser capture, or public crawling | **No** | No create/update/delete route, webhook listener, browser, arbitrary URL, or crawler is reachable. |

## Identity and authorization contract

The secret profile contains one integration token and non-secret expected
bindings named `NOTION_<PROFILE>_WORKSPACE_ID` and
`NOTION_<PROFILE>_ROOT_PAGE_IDS`. Root IDs are a comma-separated allowlist of
1–20 UUIDs; URLs and names are rejected. The profile may also set:

- `NOTION_<PROFILE>_INCLUDE_COMMENTS=true|false` (default `false`);
- `NOTION_<PROFILE>_MAX_DEPTH` (default 8, hard maximum 20);
- `NOTION_<PROFILE>_MAX_PAGES` (default 500, hard maximum 10,000);
- `NOTION_<PROFILE>_MAX_BLOCKS` (default 5,000, hard maximum 100,000);
- `NOTION_<PROFILE>_MAX_BYTES` (default 16 MiB, hard maximum 256 MiB).

Store the access token as `NOTION_<PROFILE>_ACCESS_TOKEN` with `aidevops secret`;
never place its value in a command, issue, fixture, or log. Invoke the canonical
registry route with the expected workspace UUID as `--account-id`:

```bash
aidevops secret NOTION_WORK_ACCESS_TOKEN -- \
  knowledge-social-helper.sh provider-run \
  --provider notion-sites --mode live -- \
  --alias personal:default \
  --connection-id CONNECTION_ID \
  --account-id EXPECTED_WORKSPACE_UUID \
  --stream site_tree --profile work \
  --budget 21 --page-size 100
```

`GET /v1/users/me` must return a bot in the exact configured workspace before
the first write and before every content request. Profile roots and limits must
also equal the values bound into the durable cursor. Rotating a profile to a
different workspace, root set, or budget fails before evidence advances.

## Traversal, pagination, and persistence

The child process can reach only these reviewed fixed-origin routes:

| Purpose | Method and route |
|---|---|
| Bot/workspace identity | `GET /v1/users/me` |
| Root or discovered page properties | `GET /v1/pages/{uuid}` |
| One level of block children | `GET /v1/blocks/{uuid}/children` |
| Discovered child database metadata | `GET /v1/databases/{uuid}` |
| Rows in a discovered data source | `POST /v1/data_sources/{uuid}/query` |
| Optional unresolved comments | `GET /v1/comments?block_id={uuid}` |

The query POST is an official read operation with a body limited to
`page_size` and an opaque `start_cursor`; it cannot carry a filter, mutation, or
caller-selected URL. Every other provider request is GET. Redirects are rejected.

The versioned cursor binds workspace, roots, comment policy, API version, limits,
the pending descendant queue, scheduled IDs, and cumulative page/block/byte
counts. Provider `next_cursor` values remain opaque. Child pages, nested blocks,
and data-source rows are scheduled only from a response whose parent matches the
current queue head. `link_to_page`, copied synced-block sources, relations,
mentions, and Search never add tasks.

Each content step reserves two request units: one identity recheck and one data
read. The identity observation reserves one unit. The reader paces live calls
below the documented average three requests/second per connection and preserves
`Retry-After` on 429/529 responses. Budget exhaustion leaves the last atomic
checkpoint resumable. A malformed page, non-advancing cursor, incomplete result,
parent/workspace mismatch, depth/page/block/byte/queue exhaustion, credential-
shaped text, terminal response, or stale lease commits neither that response nor
its next checkpoint.

Raw evidence contains the adapter's URL-free projection, not expiring signed
file URLs. Normalized rows preserve plain text, timestamps, stable UUIDs, parent
bindings, publication presence, file disposition, and explicit unavailable
coverage. They do not claim a complete workspace, deletion history, resolved
comment history, relation closure, or indefinite retention.

## Official evidence

- Sites publishing and public visibility:
  <https://www.notion.com/help/public-pages-and-web-publishing>
- API authentication and cursor pagination:
  <https://developers.notion.com/reference/intro>
- Internal connection content access:
  <https://developers.notion.com/guides/get-started/internal-connections>
- Bot and workspace identity:
  <https://developers.notion.com/reference/get-self>
- Page properties and the 25-reference limit:
  <https://developers.notion.com/reference/retrieve-a-page>
- Recursive block-child reads:
  <https://developers.notion.com/reference/get-block-children>
- Databases, data sources, and the 10,000-result query boundary:
  <https://developers.notion.com/reference/retrieve-database>,
  <https://developers.notion.com/reference/query-a-data-source>
- Unresolved comments and capability gate:
  <https://developers.notion.com/reference/list-comments>
- Expiring file URLs:
  <https://developers.notion.com/guides/data-apis/retrieving-files>
- Per-connection/workspace rate and payload limits:
  <https://developers.notion.com/reference/request-limits>
- Search incompleteness:
  <https://developers.notion.com/reference/search-optimizations-and-limitations>
- UI exports and backups:
  <https://www.notion.com/help/export-your-content>,
  <https://www.notion.com/help/back-up-your-data>
- Enterprise Admin API export:
  <https://developers.notion.com/reference/admin/enqueue-space-export>
