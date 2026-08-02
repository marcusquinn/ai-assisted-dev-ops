---
description: Substack account, publication export, RSS, and MCP no-route disposition
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

# Substack Account Knowledge

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Importer**: none; no Substack provider module, registry entry, helper command,
  MCP client, RSS collector, or browser route exists
- **Official surfaces**: creator-requested publication ZIP, creator subscriber
  CSV, public publication RSS, privacy access requests, and bestseller-only MCP
  publication analytics
- **Current disposition**: **Export/No** for publication posts and subscriber
  data; **Gate/No** for MCP analytics and privacy access; **No** for Notes,
  reader subscriptions, comments or interactions, and publication membership
- **Blocking gap**: no accepted surface combines stable selected-account or
  publication identity, supported row-level history, documented completeness,
  bounded pagination, and redirect-free authorization
- **Public RSS boundary**: publication syndication is neither authenticated
  account history nor documented complete history
- **Activation rule**: validate a current private official artifact or a future
  redirect-free read contract before adding parsing, persistence, or CLI wiring

No importer, API client, MCP connector, RSS collector, or browser route is
enabled.

<!-- AI-CONTEXT-END -->

## Evidence boundary

The official surfaces and policies were checked on 2026-08-02. The worker
runtime has Python 3.12.3. No `substack`, `substack_api`, or `substackapi` module
is installed, and no such client is declared in the locked requirements. No
third-party endpoint, response field, scope, error code, or client symbol is
mapped.

Substack does not document a general developer API or OAuth application surface
for the requested account history. Cookie names in the privacy policy describe
Substack's own login and consent state; they are not a developer registration,
token, scope, pagination, or account-resource contract:
https://substack.com/privacy.

## Official MCP analytics gate

The official MCP help page documents one identity-bound, read-only surface:
https://support.substack.com/hc/en-us/articles/50834026608916.

It requires the operator to be an Admin of a Bestseller publication, add
`https://mcp.substack.com/api/v1/mcp` to a compatible client, sign in to
Substack, allow access, and select the publication. It exposes publication
dashboard metrics, traffic, settings, subscribers, revenue, and retention. It
cannot publish posts, send Notes, modify the account, access profile data, or
access Notes activity.

That is a **Gate/No** disposition, not an enabled collector. The documented flow
requires interactive sign-in and consent redirects, which this knowledge route
rejects. The page publishes no stable account/publication identifier in tool
responses, tool schema, cursor or pagination contract, request quota, history
window, retention contract, immutable evidence format, or lease-safe replay
semantics. Aggregate post and engagement analytics are not row-level authored
posts, Notes, comments, or personal account interactions.

## Creator-owned exports

The creator export page says a publication owner can generate a ZIP containing
posts, the subscriber list, and related statistics from publication settings:
https://support.substack.com/hc/en-us/articles/360037466012-How-do-I-export-my-posts.

The page does not publish container members, schema/version, publication or
account identity fields, category completeness, draft/Note/comment coverage,
timestamp semantics, generation limits, download expiry, or retention. Without
a current private sample, a parser cannot prove that an artifact belongs to the
selected publication before persisting it. Publication posts therefore remain
**Export/No**.

Substack separately documents creator export of all, visible, or selected
subscriber columns as CSV:
https://support.substack.com/hc/en-us/articles/6314498343700-How-do-I-export-my-email-list-on-Substack.

The documented columns can vary with the selected dashboard view and may include
open or individual-post-view data; subscriber names are not exported. The page
does not publish a versioned schema, stable publication identity inside the
file, completeness marker, row limit, generation quota, expiry, or retention.
This is creator-controlled subscriber data—not the selected reader's list of
subscriptions—and may contain third-party personal data. It remains
**Export/No** until a private sample proves identity and scope.

## Public RSS is not account history

Substack documents one RSS feed per publication at
`https://your.substack.com/feed`:
https://support.substack.com/hc/en-us/articles/360038239391-Is-there-an-RSS-feed-for-my-publication.

The page promises no account authentication, immutable publication identifier,
item schema, history depth, completeness, pagination, request quota, retention,
paywall coverage, deletion semantics, or replay contract. A feed can expose a
current public slice of published posts, but not drafts, authored Notes,
comments, likes, restacks, saved Notes, reader subscriptions, or publication
roles. It must never be represented as complete authenticated account history.

Substack's terms prohibit crawling or scraping pages or data, copying or storing
a significant portion of content, unreasonable infrastructure load, and reverse
engineering:
https://substack.com/tos.

The terms publish no RSS-specific collection or archival exception. This route
therefore does not convert public syndication availability into authority for a
corpus collector, does not guess private endpoints, and does not add an RSS or
browser fallback.

## Requested coverage

| Requested category | Current official evidence | Disposition |
|---|---|---|
| Authored publication posts | Creator-generated publication ZIP; public RSS is only a partial unauthenticated publication feed | **Export/No** |
| Authored Notes and saved Notes | MCP explicitly excludes profile data and Notes activity; no documented feed or export | **No** |
| Reader subscriptions | The reader UI can display and manage subscriptions, but no supported API or export is documented | **No** |
| Creator subscriber list | Creator CSV and publication ZIP exist, but schema and selected-publication identity are unpublished | **Export/No** |
| Authored comments, likes, restacks, replies, and other interactions | No supported account-history API or documented export schema; subscriber analytics are not owner interaction records | **No** |
| Publication ownership, administration, contribution, or membership | MCP verifies one selected Bestseller Admin role but does not expose a complete membership inventory | **Gate/No** |
| Publication performance and subscriber analytics | Read-only MCP for eligible Bestseller Admins requires interactive sign-in and consent | **Gate/No** |
| Privacy access package | Verified legal request may return some personal information, with no published archive schema or requested-category coverage | **Gate/No** |

An absent category is unavailable, not a successful empty result. Public feed
items cannot fill a private account category, and creator subscriber rows cannot
be reclassified as the reader's own subscriptions or interactions.

## Privacy, retention, and identity

The privacy policy says account-associated data includes subscription status and
that eligible users may request a copy or transfer of some personal information.
It targets a response within one month, extendable by two months, and retains
information only as long as reasonably necessary, with possible longer legal
retention:
https://substack.com/privacy.

The California notice extends access rights to all users, requires a verifiable
request, and describes disclosure over the prior 12 months:
https://substack.com/ccpa.

The Help Center also describes a facilitated data-subject access request, but no
machine-readable format, delivery API, archive schema, category list, stable
identity field, polling mechanism, quota, or download lifetime:
https://support.substack.com/hc/en-us/articles/13579313874452-How-do-I-contact-Substack-if-I-want-to-exercise-my-privacy-rights.

Privacy rights are a human identity-verification gate, not a stable collection
API. A future private response is evidence only for its observed scope and must
remain owner-local, purpose-limited, and deletable.

## Why ingestion is disabled

The social-store contract requires an authoritative selected account or
publication identity before any raw or normalized persistence. The publication
ZIP and subscriber CSV have no published identity/schema contract. RSS has no
authenticated identity or completeness contract. MCP is gated analytics,
requires an interactive authorization redirect, and explicitly omits profile
and Notes activity. Privacy access is asynchronous and schema-free.

Implementing from filenames, publication subdomains, display names, public
profiles, guessed JSON endpoints, session cookies, browser automation, or MCP
screenshots would permit wrong-account persistence and bypass provider policy.
No placeholder adapter, registry entry, helper command, or fallback route is
added. `.agents/tests/test-knowledge-social-substack.sh` enforces that negative
contract.

## Activation checklist

Before enabling any Substack route:

1. Revalidate the current official API, MCP, export, RSS, privacy, and terms
   documentation; do not infer a developer API from login cookies or private
   network calls.
2. Obtain a fresh owner-generated artifact through an official workflow and keep
   all posts, subscriber rows, account identifiers, signed links, and filenames
   private.
3. Record only a sanitized manifest of container type, member paths, headings,
   field names, schema markers, generation time, and category presence.
4. Identify an authoritative stable account/publication marker inside every
   artifact and prove an exact match to the operator-selected connection before
   writing raw evidence.
5. Establish category completeness, omissions, pagination/segmentation,
   timestamps, deletion behavior, generation limits, expiry, and permitted local
   retention. Missing categories remain unavailable.
6. Require redirect-free read-only authorization, exact allowlisted origins and
   methods, independent checkpoints, hard request/item/byte budgets, immutable
   evidence, content-addressed replay, atomic persistence, and a final lease
   fence.
7. Test wrong-account/rebinding, malformed and credential-shaped input,
   redirects, pagination/resume, budget stops, replay/idempotency, terminal
   failures, stale and expired leases, schema drift, and static isolation from
   every write, browser, and mutation path.
8. Register and advertise only fixture-proven categories; retain explicit
   **Gate**, **Export**, or **No** coverage for every unsupported surface.
