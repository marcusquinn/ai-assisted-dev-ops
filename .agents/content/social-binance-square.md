---
description: Binance Square read-ingestion evidence and fail-closed no-route disposition
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

# Binance Square Account Knowledge

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Importer**: none; no Binance Square provider module or social-helper
  command exists
- **Official surface**: Binance publishes a Square OpenAPI skill for creating
  posts and uploading media; it explicitly excludes reading and account
  management
- **Current disposition**: **No** for every requested read, export, event, and
  private-account category
- **Credential boundary**: Square publishing keys and Binance exchange,
  trading, wallet, Pay, Merchant, and account-security credentials are rejected
  as ingestion authority
- **Browser route**: disabled; public pages do not prove account identity or
  authenticated completeness, and cookie/session scraping is not permitted
- **Activation rule**: enable only after Binance documents a Square-specific,
  read-only route with stable creator identity, scopes, schemas, pagination,
  retention, and replay behavior

No importer, API reader, export parser, event receiver, or browser route is
enabled.

<!-- AI-CONTEXT-END -->

## Evidence boundary

The official surfaces and local runtime were checked on 2026-07-31. The worker
runtime has Python 3.14.3, and no `binance`, `binance_connector`,
`binance_sdk_spot`, or `binance_square` Python module is installed. No
third-party client symbols, response fields, scopes, pagination contract, or
error codes are mapped.

Binance's official Skills Hub repository describes itself as an agent skills
marketplace. Its pinned Square Post skill says that the skill only creates new
posts and must not be used for reading, searching, commenting, liking, editing,
deleting, scheduling, or managing existing Square posts:
https://github.com/binance/binance-skills-hub/blob/3bf89edb7eea313c36688d21cd4512f9f501b57d/skills/binance/square-post/SKILL.md.

The same official skill documents a `BINANCE_SQUARE_OPENAPI_KEY`, points creators
to https://www.binance.com/square/creator-center/home, and supports text, image,
article, and video publication. Its scope section explicitly excludes reading,
listing, searching, editing, deleting, interactions, profiles, account
management, scheduling, and drafts. This is current evidence of a mutation-only
publishing surface, not permission to repurpose that key for ingestion.

The pinned repository state is dated 2026-07-23:
https://github.com/binance/binance-skills-hub/commit/3bf89edb7eea313c36688d21cd4512f9f501b57d.
The Square skill first appears in the official history on 2026-03-06:
https://github.com/binance/binance-skills-hub/commit/a59c603ff29451122ae219cbc11be651fe606c5a.

Current file trees for Binance's official Postman collection, Python and
JavaScript public API connectors, Spot API documentation, public API Swagger,
and CLI contain no Square-specific path. Their documented exchange/public API
scope is not evidence of Square social-read support. No current official
Square-specific account export, data-download schema, webhook, event stream, or
authenticated read API was verified in the reviewed official sources.

This disposition records only what the dated official evidence proves. It does
not infer that an absent route can never be introduced.

## Requested coverage

| Requested category | Current official evidence | Disposition |
|---|---|---|
| Account and creator profile | The official skill excludes profiles and account management | **No** |
| Authored posts and articles | Official OpenAPI creates new content but does not read, list, search, edit, or delete existing content | **No** |
| Revisions, deletion history, and drafts | Editing, deleting, scheduling, and drafts are explicitly excluded | **No** |
| Comments, replies, and mentions | Commenting is excluded; no read route or export schema was verified | **No** |
| Likes and reactions | Liking and other interactions are excluded; no read route was verified | **No** |
| Bookmarks and saved state | No supported read, export, or event route was verified | **No** |
| Follows, subscriptions, lists, topics, and feeds | No supported account-state route or export schema was verified | **No** |
| Notifications and messages | No supported read, export, or event route was verified | **No** |
| Media, live, and audio metadata | The publishing skill uploads new image/video media only; it does not read existing media or live/audio history | **No** |
| Campaigns, rewards, and monetization | No read-only Square route was verified; financial or creator-payment data remains protected | **No** |
| Private state and account history | No authenticated read route or documented account archive was verified | **No** |
| Public Square pages | Public pages are not authenticated owner evidence and cannot establish private completeness or deletion history | **No** |

An absent route is not evidence that the account has no records. Every category
remains unavailable rather than becoming successful empty coverage. No current
official export generation limit, delivery time, schema version, download
expiry, or retention period was verified.

## Financial and mutation isolation

Binance Square is treated only as a social-content provider candidate. Generic
Binance spot, margin, futures, wallet, transfer, withdrawal, deposit, Pay,
Merchant, KYC, account, device, and security APIs are different authority
surfaces and are never fallbacks for Square. API-key presence, a Binance login,
or access to a public Square page cannot establish a read route.

The known Square OpenAPI key authorizes publishing. Because it is
mutation-capable and the official skill documents no read operation, an
ingestion command must not accept, store, inspect, validate, or exercise it.
Likewise, exchange or financial credentials must fail before any network
request. No collected text may become a trading instruction or input to order,
transfer, wallet, payment, outreach, publishing, commenting, liking, following,
or messaging tools.

No public-page, browser-cookie, session-token, undocumented endpoint, or
reverse-engineered mobile route is an approved fallback. Public evidence can be
referenced manually as public evidence, but it cannot be persisted as selected
account coverage.

The negative contract is enforced by
`.agents/tests/test-knowledge-social-binance-square.sh`.

## Activation checklist

Before enabling Binance Square ingestion:

1. Obtain a current official Square-specific read API, owner export, or event
   contract. A publishing API, generic exchange API, public page, or privacy
   request without a stable documented artifact is insufficient.
2. Verify the exact Binance account and Square creator/profile identity from
   provider-controlled fields before any raw or normalized persistence. Never
   persist login, KYC, balance, order, position, wallet, transfer, payment, or
   account-security data.
3. Record the narrow read scopes, authentication type, endpoint or export
   version, response schema, pagination, deletion/revision semantics, rate
   limits, replay behavior, generation limits, expiry, and retention.
4. Reject credentials that permit trading, orders, transfers, withdrawals,
   deposits, wallets, payments, account/security changes, publishing, comments,
   likes, follows, or messages before network access.
5. Add independent bounded streams and checkpoints only for categories proven
   by official fixtures. Unknown and absent categories remain explicit gaps.
6. Test identity mismatch, rebinding, scope rejection, malformed and terminal
   responses, pagination or export replay, protected-data scrubbing, stale
   leases, final identity fences, and zero financial or social side effects.
7. Keep Square evidence, credentials, receipts, and checkpoints separate from
   every Binance exchange, wallet, payment, and account-operation store.
8. Update the dated capability evidence only after the official route and
   synthetic fixtures agree; never infer fields or errors from another Binance
   product.

## Retention and privacy

No retention grant follows from the public publishing skill. Future Square
evidence may contain third-party personal data, financial discussion, private
relationships, messages, customer identity, or monetization details. Keep live
credentials, account and creator identifiers, exports, signed links, private
content, and collected evidence out of git, issues, fixtures, command output,
and shared workspaces.
