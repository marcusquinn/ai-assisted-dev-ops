<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Gumroad Seller Knowledge Collection

`knowledge_social_gumroad.py` collects bounded seller evidence from four exact
Gumroad API v2 GET routes. It is intentionally provider-specific until #28867
registers all commerce collectors in the shared helper.

## Connection and protected-data contract

Configure one private profile through secure environment injection:

```text
GUMROAD_<PROFILE>_ACCESS_TOKEN
GUMROAD_<PROFILE>_PII_KEY
```

`PII_KEY` is an operator-generated random value of at least 32 bytes and must be
stable for one profile. The child uses it only to produce deterministic HMAC
aliases for customer and affiliate email addresses. Direct email, customer name,
address, postal code, custom fields, license value, card visual/type, bank visual,
PayPal address, tracking URL, and processor transaction ID are discarded before
raw evidence crosses the child boundary. Tokens and the HMAC key never enter
requests, logs, status, checkpoints, or evidence.

Use `gumroad_<USER_ID_WITH_TRAILING_EQUALS_REMOVED>` as `--account-id`. This
canonical account namespace converts Gumroad's padded `user_id` into the shared
corpus identifier grammar without persisting a second account identity. Use a
dedicated token with only the streams' required grants; sales require
`view_sales`, and payouts require `view_payouts`.
Identity is checked before collection and before every page. The isolated child
constructs only `method="GET"` requests to a fixed API origin, rejects redirects,
and accepts only `/user`, `/products`, `/sales`, and `/payouts`.

## Implemented streams

| Stream | Official route | Normalized coverage |
|---|---|---|
| `profile` | `GET /v2/user` | Stable seller ID and bounded display metadata; email is omitted. |
| `products` | `GET /v2/products` | Product state, prices/currency, variants/options, tags, publication/deletion flags, shipping/subscription state, and only a file-metadata-presence flag. |
| `sales` | `GET /v2/sales` | Orders, product/customer aliases, quantities, variants, price/fee/tax/shipping amounts, refunds, chargebacks/disputes, shipping state, subscriptions, license presence, and affiliate aliases/amounts. |
| `payouts` | `GET /v2/payouts` | Current/upcoming payout amount, currency, status, dates, and processor; bank/PayPal identifiers are omitted. |

Sales and payouts are `protected_business` evidence. Corpus isolation remains the
authorization boundary: do not share the containing corpus without an explicit
grant appropriate for customer and financial evidence. Product-scoped active
subscriber and offer-code fan-out remain explicit gaps rather than hidden empty
streams. Subscription and license state available on sales is retained without
license secrets.

Every listing uses the documented opaque `next_page_key`; returned next-page URLs
are never followed. Each stream owns an independent cursor and first-page
watermark. API responses may contain up to the configured 100-item safety cap.
The provider does not document a read-rate limit or retention guarantee, so the
collector uses a 3-1000 request-unit budget and records both limitations.

## Exports, webhooks, and unavailable categories

The dashboard has sales, audience, affiliate, and payout export workflows, but
current official source does not publish one stable seller export schema and
generation creates server state. No export generation, polling, download, or CSV
import is wired.

Resource subscriptions support sale, refund, dispute, dispute-won, cancellation,
subscription-updated, subscription-ended, and subscription-restarted events.
Creating one is a `PUT`; current documentation does not define a receiver
signature. Events are therefore neither registered nor trusted as evidence. API
reads remain the reconciliation authority.

No verified seller read route was found for a complete affiliate directory,
balance, posts/updates, workflows/emails, community/messages, or downloadable
digital-file contents. Deleted resources and history are limited to records the
current API still returns. These categories are persisted as unavailable coverage,
not successful empty streams. Browser/storefront automation is prohibited.

The following documented mutation families are unreachable: product create,
update, delete, enable/disable and file/variant/offer edits; sale refunds, shipping
updates, receipt resend; license changes; resource-subscription create/delete;
and profile/content/email changes. Collector source contains no POST, PUT, PATCH,
or DELETE request constructor.

## Official evidence checked 2026-07-31

- [Gumroad API documentation](https://gumroad.com/api)
- [Current open-source Gumroad release](https://github.com/antiwork/gumroad/releases/tag/v2026.07.31.32)
- [Seller API setup and OAuth help](https://github.com/antiwork/gumroad/blob/main/app/views/help_center/articles/contents/_280-create-application-api.html.erb)
- [User endpoint source](https://github.com/antiwork/gumroad/blob/main/app/javascript/components/ApiDocumentation/Endpoints/User.tsx)
- [Product endpoint source](https://github.com/antiwork/gumroad/blob/main/app/javascript/components/ApiDocumentation/Endpoints/Products.tsx)
- [Sales endpoint source](https://github.com/antiwork/gumroad/blob/main/app/javascript/components/ApiDocumentation/Endpoints/Sales.tsx)
- [Subscriber endpoint source](https://github.com/antiwork/gumroad/blob/main/app/javascript/components/ApiDocumentation/Endpoints/Subscribers.tsx)
- [Payout endpoint source](https://github.com/antiwork/gumroad/blob/main/app/javascript/components/ApiDocumentation/Endpoints/Payouts.tsx)
- [Resource-subscription endpoint source](https://github.com/antiwork/gumroad/blob/main/app/javascript/components/ApiDocumentation/Endpoints/ResourceSubscriptions.tsx)
