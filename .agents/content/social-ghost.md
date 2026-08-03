---
description: Identity-bound Ghost public publication knowledge collection
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

# Ghost Publication Knowledge

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Collector**: `knowledge-social-helper.sh sync-ghost`
- **Live evidence**: published posts, resource pages, public tags, and public
  authors through four independently checkpointed Ghost v6 Content API streams
- **Identity**: an opaque profile `SITE_ID` plus the exact configured `SITE_URL`,
  rechecked against unauthenticated `GET /ghost/api/admin/site/` before every page
- **Authentication**: public-read Content API credential only; Admin API keys,
  staff tokens, user sessions, and JWT generation are unreachable
- **Isolation**: exact GET paths, fixed v6 header, rejected redirects, bounded
  response/page sizes, no arbitrary filters, and no browser or mutation fallback
- **Private categories**: members, newsletters, staff, drafts, and comments remain
  gated or unavailable; no private record is normalized

<!-- AI-CONTEXT-END -->

## Evidence boundary

The route and official documentation were checked on 2026-08-02. The worker
runtime is Python 3.12.3. Standard-library `urllib.request`, `urllib.parse`, and
`json` exports are present. Python `requests` and `jwt` happen to be installed,
but this adapter imports neither. Neither `@tryghost/content-api` nor
`@tryghost/admin-api` is installed in the repository. The official clients are
therefore reference evidence rather than runtime dependencies.

Ghost's current Content API is a stable, read-only surface rooted at
`https://{admin_domain}/ghost/api/content/`. A custom integration supplies a hex
Content API credential in the `key` query parameter. Ghost explicitly describes
that credential as safe for browser/public-data use, while warning that private
sites should still control distribution:
https://docs.ghost.org/content-api.md.

The current JavaScript client documentation identifies
`@tryghost/content-api` and says integrations should set `version: "v6.0"`:
https://docs.ghost.org/content-api/javascript.md. This implementation uses the
equivalent `Accept-Version: v6.0` header. Ghost responds with `Content-Version`
when version negotiation is used, and documents stable API compatibility for a
minimum of two years:
https://docs.ghost.org/faq/api-versioning/.

The unauthenticated Admin `site` endpoint returns the frontend URL and Ghost
version, including when the admin and frontend domains differ. It is the only
Admin-path request in the allowlist and carries no credential:
https://docs.ghost.org/admin-api/site/overview.md.

## Implemented Content API contract

| Category | Disposition | Exact route and boundary |
|---|---|---|
| Posts | **Live/Partial** | `GET /ghost/api/content/posts/`; published/currently visible content only |
| Pages | **Live/Partial** | `GET /ghost/api/content/pages/`; resource pages, not dynamic routes |
| Tags | **Live/Partial** | `GET /ghost/api/content/tags/` with fixed `visibility:public`; internal and unused tags excluded |
| Authors | **Live/Partial** | `GET /ghost/api/content/authors/`; only authors associated with published posts, with location/social/profile media omitted |
| Members | **Gate/No** | Stable Admin reads exist but expose email, geolocation, notes, subscriptions, payment metadata, activity, suppression state, and signed unsubscribe URLs; no route is enabled |
| Newsletters | **Gate** | Stable Admin reads exist, but the same integration authority also exposes newsletter mutation; no minimum read-only credential is documented |
| Comments | **No/Gate** | No stable comment endpoint is listed for integrations in the current Admin API contract; theme rendering is not an account-history API |
| Exports | **Export/Gate** | Owner-driven Content & settings JSON is documented in Ghost Admin; no automated export endpoint or fixture-validated importer is enabled |

Official resource and parameter contracts:

- posts: https://docs.ghost.org/content-api/posts.md
- pages: https://docs.ghost.org/content-api/pages.md
- tags: https://docs.ghost.org/content-api/tags.md
- authors: https://docs.ghost.org/content-api/authors.md
- parameters and maximum 100-item pages:
  https://docs.ghost.org/content-api/parameters.md
- numeric `meta.pagination` shape:
  https://docs.ghost.org/content-api/pagination.md

Posts and pages request only the documented `html,plaintext` formats. Tags and
authors request only `count.posts`. The child serializes an allowlist of stable
IDs, titles/names, slugs, public text, and timestamps before evidence crosses the
process boundary. URLs, code injection, images, social handles, author location,
and unknown response fields are discarded. Tags must still report public
visibility after the server-side filter.

Each browse response must contain the requested numeric page and limit, a
consistent total/pages pair, exact previous/next values, no more than 100 objects,
and an advancing next page. A malformed page, unexpected resource wrapper,
oversized response, repeated cursor, HTTP terminal result, or credential-shaped
field commits neither raw evidence nor a checkpoint. Snapshot completion never
infers deletion from a later partial run.

The Content API says its cacheable public reads can be fetched without a provider
limit. The collector still budgets one initial identity request and two units per
page (identity recheck plus content read), caps each invocation at 1,000 units,
and caps pages at 100 items. Provider or hosting-layer throttling remains terminal
for the invocation and preserves prior state.

## Admin and PII gate

The Admin API supports integration JWTs, staff access JWTs, and user sessions.
Admin keys are secret `id:hex-secret` values used to mint HS256 tokens with a
maximum five-minute expiry and `/admin/` audience. Current integration
permissions are a fixed set that includes both reads and writes for posts, pages,
tags, tiers, newsletters, offers, members, labels, and other management surfaces:
https://docs.ghost.org/admin-api.md. The official `@tryghost/admin-api` client
demonstrates add/edit/delete and upload methods as well as reads:
https://docs.ghost.org/admin-api/javascript.md.

That credential cannot satisfy a minimum-privilege, read-only collector boundary.
The live child accepts only a hex Content API credential and an exact
`AUTH_MODE=content_api_key`; a colon-delimited Admin key, JWT, Authorization
header, staff token, or session cookie is not accepted or inherited. Exact route
tests reject `/members/`, `/newsletters/`, `/users/`, `/comments/`, `/db/`, and
every POST/PUT/PATCH/DELETE construction.

Members are especially sensitive. The official response includes email, name,
notes, geolocation, subscription and Stripe references, engagement counts,
last-seen state, commenting/suppression state, and an unsubscribe URL:
https://docs.ghost.org/admin-api/members/overview.md. Newsletter records can
include sender addresses and configuration, and their integration endpoint is
also mutable:
https://docs.ghost.org/admin-api/newsletters/overview.md. Neither category is
needed to build public publication knowledge, so minimization is a hard gate
rather than a redaction heuristic.

## Profile and collection

Store profile values outside the repository. Never place a Content credential,
Admin credential, signed token, private site URL, or export in an issue, fixture,
command argument, log, or evidence row.

| Profile variable | Contract |
|---|---|
| `GHOST_<PROFILE>_ADMIN_URL` | Exact HTTPS admin base, including an installation subpath but excluding `/ghost/api/...` |
| `GHOST_<PROFILE>_SITE_URL` | Exact expected HTTPS frontend URL returned by the site identity endpoint |
| `GHOST_<PROFILE>_SITE_ID` | Operator-selected opaque ID; must equal `--account-id` |
| `GHOST_<PROFILE>_CONTENT_API_KEY` | Hex Content API credential; isolated to the child and omitted from output |
| `GHOST_<PROFILE>_ORIGIN_KEY` | At least 32 bytes, used to HMAC the admin origin into a private installation namespace |
| `GHOST_<PROFILE>_AUTH_MODE` | Exactly `content_api_key` |

```bash
knowledge-social-helper.sh sync-ghost \
  --connection-id conn_ghost_publication \
  --account-id ghost_publication \
  --stream posts \
  --profile publication \
  --budget 11 \
  --page-size 100
```

Run pages, tags, and authors separately so each stream owns its cursor, lease,
coverage, and terminal result. A valid credential for another site still fails
because the exact expected frontend URL and keyed admin-origin namespace are
rebound before each content page. HTTP redirects are never followed, including
custom-domain redirects; configure the final admin base and expected frontend
URL explicitly.

## Exports, retention, privacy, and terms

Ghost documents an owner-driven **Content & settings** JSON download in Admin,
plus separate routes/redirects, theme, and image backup steps. It does not
document that UI export as a stable authenticated API endpoint or a complete
members/comments archive:
https://docs.ghost.org/migration/ghost.md. Until a sanitized current owner export
proves identity, schema, completeness, and credential scrubbing, no importer is
registered.

Ghost's hosted-service privacy policy retains personal data only while needed for
the collection purpose, business/legal needs, or applicable law; it gives no
publication-specific API history or deletion SLA:
https://ghost.org/privacy/. Ghost's terms make operators responsible for lawful
content rights and backups, prohibit unauthorized downloading and personal-data
collection, and require avoiding excessive service load:
https://ghost.org/terms/.

Keep each corpus owner-only and purpose-bound. Public API availability is not a
license to retain personal author data indefinitely. Remove evidence when
authority or purpose ends, do not share raw records by default, and never claim
that a completed snapshot includes deleted, unpublished, historical, member, or
comment evidence.
