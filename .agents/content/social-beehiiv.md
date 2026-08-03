<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# beehiiv account knowledge

Checked on 2026-08-03. The enabled route is deliberately publication-scoped and
posts-only. It is not a general beehiiv workspace, audience, or export client.

## Current disposition

| Category | Disposition | Boundary |
|---|---|---|
| Publications | **Gate/Live** | A creator-ownership attestation bound to one configured `pub_...` ID is required; its exact ID, name, and organization must be the only publication visible to the credential. |
| Posts | **Gate/Live/Partial** | After the ownership and identity gate, confirmed post metadata plus `free_web_content`; future scheduled items are skipped, premium expansion and statistics are never requested. |
| Subscriptions | **Gate/Export/No** | The API and dashboard export expose email, status, tier, custom fields, and statistics. No subscriber endpoint or import route is enabled without a separate account-knowledge need, authorization, and field-by-field minimization. |
| Segments | **Gate/No** | Segment membership can return subscription IDs or subscriber records. No route is enabled. |
| Exports | **Export** | Creator-initiated post and subscriber CSV exports exist; dashboard automation is prohibited and no schema is treated as stable without a private fixture. |

## Official contract

The current official developer index identifies API v2 and the fixed
`https://api.beehiiv.com/v2` origin:
<https://developers.beehiiv.com/llms.txt>. Requests use bearer authentication.
API keys may be restricted to selected publications; a restricted key returns
only allowed publications from `GET /v2/publications`, while out-of-scope IDs
return `404`:
<https://developers.beehiiv.com/welcome/create-an-api-key.md>.

OAuth authorization-code clients can request the separate
`publications:read`, `posts:read`, `subscriptions:read`, and `segments:read`
scopes. This collector needs only the first two and does not implement the OAuth
authorization exchange itself:
<https://developers.beehiiv.com/oauth2.md>.

The enabled calls are exactly:

- `GET /v2/publications?limit=2&page=1` for publication scope and identity;
- `GET /v2/publications/{publicationId}/posts` with `status=confirmed`,
  `expand=free_web_content`, ascending creation order, and bounded page/limit.

Official endpoint schemas:
<https://developers.beehiiv.com/api-reference/publications/index.md> and
<https://developers.beehiiv.com/api-reference/posts/index.md>.

The general API guide recommends opaque `cursor`, `next_cursor`, and `has_more`
pagination, and deprecates page offsets beyond a hard page-100 boundary. The
current publication and post endpoint schemas still document `page`,
`total_pages`, and `total_results`. The adapter follows the endpoint-specific
schema, versions its local page cursor, caps requests at page 100, and records
partial coverage instead of claiming an exhaustive history:
<https://developers.beehiiv.com/welcome/pagination.md>.

The organization-wide limit is 180 requests per minute. Each page costs two
provider requests because identity is rechecked immediately before the post
read; the initial identity costs one. The CLI caps an invocation at 59 requests,
honors `RateLimit-Reset` or a valid `Retry-After`, and persists no new checkpoint
for `429` or another terminal response:
<https://developers.beehiiv.com/welcome/rate-limiting.md>.

## Identity and authorization boundary

Each local profile supplies `BEEHIIV_<PROFILE>_ACCESS_TOKEN`,
`BEEHIIV_<PROFILE>_PUBLICATION_ID`,
`BEEHIIV_<PROFILE>_PUBLICATION_NAME`, and
`BEEHIIV_<PROFILE>_ORGANIZATION_NAME`, plus
`BEEHIIV_<PROFILE>_CREATOR_OWNED_PUBLICATION_ID` as an explicit deployment-owner
attestation. The attested and configured publication IDs must match. The
command's `--account-id` must equal that ID. Before state is loaded and before
every post page, the provider requires the attestation, exactly one visible
publication, and exact ID, name, and organization equality. A workspace-wide
credential with multiple visible publications is rejected even if the requested
ID is valid.

The API does not expose an immutable human owner ID or prove legal ownership, so
the additional local value is an operator attestation rather than a provider
claim. Without it, the live route is gated before any API call or state advance.
Fixtures prove missing, mismatched, and response-level ownership attestations
fail closed; they do not claim to prove legal ownership. The deployment owner
remains responsible for attesting only a creator-owned publication and, for API
keys, restricting the key to that publication. Mutable name and organization
checks intentionally fail closed until local expectations are updated after a
legitimate rename.

## Privacy and persistence

Retained post fields are stable post ID, title/subtitle, public author
attribution, timestamps, status, subject/preview text, slug/web URL, audience,
platform, content tags, selected SEO metadata, visibility flags, and
paywall-enforced free web HTML. Author names are retained because they are direct
publication-content attribution. No remote media is fetched.

The adapter never requests or stores subscriber emails, custom fields, tiers,
segment membership, newsletter-list membership, per-recipient events, click
detail, post statistics, or premium HTML. Credential-shaped fixture/provider
payloads fail before raw or normalized persistence. Every successful page writes
one immutable bounded response and its normalized projection atomically under a
lease-fencing token; replay is content-addressed and stale leases cannot advance
evidence or cursors.

beehiiv's privacy policy uses purpose-based retention rather than promising one
universal history window, so deletion and pre-retention history remain explicit
gaps: <https://www.beehiiv.com/privacy>. The terms preserve creator ownership of
submitted content while prohibiting unauthorized automated extraction; this
route uses documented APIs only: <https://www.beehiiv.com/tou> and
<https://www.beehiiv.com/aup>.

## Exports and plans

The official dashboard workflow can export all post metadata/content and Quick
or Full subscriber CSVs. Jobs are asynchronous and download links expire after
24 hours. The public API index documents no export-job route, so the collector
does not automate the dashboard, email links, redirects, or browser sessions:
<https://www.beehiiv.com/support/article/12258595483543-exporting-post-content-or-subscriber-data-from-beehiiv>.

Current pricing advertises API access across publication plans but product and
endpoint entitlement can change. `401`, `403`, and publication-hidden `404`
responses are terminal authorization/availability evidence, never a reason to
fall back to scraping: <https://www.beehiiv.com/pricing>.

## Usage

```bash
aidevops secret BEEHIIV_PERSONAL_ACCESS_TOKEN \
  BEEHIIV_PERSONAL_PUBLICATION_ID BEEHIIV_PERSONAL_PUBLICATION_NAME \
  BEEHIIV_PERSONAL_ORGANIZATION_NAME \
  BEEHIIV_PERSONAL_CREATOR_OWNED_PUBLICATION_ID -- \
  knowledge-social-helper.sh sync-beehiiv --alias personal:default \
  --connection-id CONNECTION_ID --account-id PUBLICATION_ID \
  --stream posts --profile personal --budget 19 --page-size 100
```

The credential remains in the secret execution context. Never put it in command
arguments, fixtures, logs, corpus rows, issue text, or repository files.
