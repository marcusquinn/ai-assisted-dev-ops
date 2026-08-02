# Readwise Reader Account Knowledge Evidence

Checked 2026-08-02 against the official Reader API, privacy policy, and terms.

## Implemented evidence

- `GET /api/v2/auth/` returns `204` for a valid token but no stable account ID.
  Live collection therefore requires a deployment-owned account identifier,
  binding key, and expected HMAC of that identifier plus access token. A wrong but
  valid token cannot silently collect another account; token rotation requires an
  intentional expected-binding update.
- `GET /api/v3/list/` returns up to 100 documents and an opaque
  `nextPageCursor`. `updatedAfter`, category filters, and optional
  `withHtmlContent` support bounded document, note, state, progress, location, and
  HTML streams with one-second update overlap.
- `GET /api/v3/tags/` supplies a separately checkpointed opaque-cursor tag stream.
- Document results include tags, notes, location, category, reading progress,
  parent relationships, timestamps, summary, and optional HTML. The collector
  emits only explicit allowlisted fields.
- List and tag routes are documented at 20 requests per minute per token. The
  collector caps each invocation at 19 requests including initial identity and
  per-page identity rebinding, and preserves `Retry-After` on `429` responses.
- No Readwise or Reader client package is installed. Python 3.14.3 standard-library
  HTTP exports were verified locally and provide fixed-origin, redirect-free GETs.

## Explicit boundaries

- The official API supplies no provider-owned stable account identifier. Local
  deployment binding is mandatory and remains an explicit **Gate**, not a claim
  of provider identity parity.
- List responses do not prove complete deletion history or a complete account
  export. Privacy controls provide a separate user export route.
- The privacy policy says retention depends on purpose, sensitivity, risk, and
  legal requirements. The terms allow service storage practices and limits to
  change and disclaim failure-to-store liability.
- Reader save, update, bulk-update, delete, and webhook-management routes are
  unreachable. Only the fixed auth, document-list, and tag-list GET paths exist.

## Official references

- <https://readwise.io/reader_api>
- <https://readwise.io/privacy>
- <https://readwise.io/tos>
