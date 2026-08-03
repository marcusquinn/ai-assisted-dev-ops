<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Hacker News Public Knowledge Collection

`knowledge_social_hacker_news.py` collects a bounded slice of public submitted
items for one exact, case-sensitive Hacker News username through the official
Firebase v0 API. A username is a mutable public selector, not authenticated or
immutable account identity. The synthetic local selector ID namespaces evidence
without strengthening that public identity claim.

## Public authority contract

Use `--account-id CASE_SENSITIVE_USERNAME`, `--stream submitted`, and
`--profile public`. The profile accepts no credential variables. Before the
first page and before every item read, the child observes the exact public user
route. A changed-case or mismatched returned `id` fails before evidence or a
checkpoint is committed.

Only these redirect-free routes are reachable:

| Observation | Official route shape | Result |
|---|---|---|
| Public selector and submitted IDs | `/v0/user/<username>.json` | Public profile fields plus ordered submitted IDs, or JSON `null` |
| One submitted item | `/v0/item/<positive-id>.json` | One current public item/tombstone, or JSON `null` |

Every transport request uses `GET`. No authentication, mutation, front-page,
updates, traversal, browser, or arbitrary URL route is present. Story URLs are
stored as provider evidence only and are never fetched.

## Budgets, checkpoints, and replay

The initial user observation costs one request unit. Each item page reserves two
units for selector re-observation plus one item GET. `--budget` is 3-1000 units;
`--page-size` selects at most 1-100 submitted IDs. An empty public history is
charged conservatively as one page. User and item responses have independent
2 MiB and 512 KiB byte fuses, and the child output has a fixed aggregate cap.

The versioned cursor contains the complete bounded submitted-ID slice, exact
username, snapshot digest, and next position. Resume therefore follows the
captured slice even if newer IDs appear before the next invocation. Each
successful one-item observation atomically commits raw evidence, normalized
rows, coverage, receipt, and the next cursor under the final lease fence.
Content-addressed replay is idempotent. A malformed response, terminal status,
credential-shaped field, selector mismatch, or stale lease preserves the prior
checkpoint.

## Public coverage boundary

JSON `null` users are recorded as missing public selectors without creating an
authenticated-account claim. Missing, `deleted`, and `dead` submitted items
advance only with explicit item-level unavailable coverage; they never become
empty authored objects. Live items retain the official integer ID, type, public
author attribution, timestamp, text/title, URL, and relationship IDs that the
current response exposes.

Votes, favourites/saved items, inbox, notifications, relationships,
subscriptions, custom lists, removed tombstone content, and every authenticated
or private state remain `unavailable`, not empty. The collector covers only the
bounded current `submitted` slice and does not infer deletion or complete account
history.

## Current official evidence checked 2026-08-02

- <https://github.com/HackerNews/API>
- <https://hacker-news.firebaseio.com/v0/>

The official API documentation identifies usernames as case-sensitive, exposes
only users with public activity, documents the `submitted` and item schemas,
requires clients to tolerate added fields, and currently states that the v0 API
has no rate limit. Its repository remains MIT-licensed and had no separate API
authentication, mutation, retention, or usage-terms contract in the checked
documentation. The collector treats those absences as limits—not permission for
unbounded use—and keeps independent request, item, and byte fuses.
