<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Social Provider Account-Knowledge Capabilities

This matrix is the planning contract for authenticated, read-only social corpus
collection. It distinguishes implemented routes from candidate official APIs,
account exports, permission-gated access, explicit browser gaps, and categories
for which no safe route has been verified. It does not authorize scraping or a
platform mutation.

## Status vocabulary

| Mark | Meaning |
|---|---|
| **Live** | Implemented as a bounded, fixture-tested collector. |
| **API** | A candidate official API surface exists; its child must revalidate scopes, pagination, retention, terms, and current availability. |
| **Gate** | Official access depends on app review, account type, administrator authority, partner access, or another provider-controlled permission. |
| **Export** | Account archive/import is the primary safe candidate and must be validated against a current private sample before implementation. |
| **Gap** | Browser capture is eligible only after API and export routes are exhausted and a private gap record is approved. |
| **No** | No safe, supported route is currently verified; do not collect this category. |

Multiple marks are ordered by preferred route. `API/Gate/Export` therefore means
try the official API if permission is available, then use a validated account
archive for the remaining category. Until a provider child records fresh
evidence, every mark other than **Live** is a disposition for investigation, not
a claim that the route is enabled.

## Requested providers

| Provider | Authored content | Interactions and curation | Mentions or messages | Relationships and subscriptions | Lists or custom feeds | Current disposition |
|---|---|---|---|---|---|---|
| X | **Live** posts | **Live** likes and bookmarks | **Live** mentions | **Live** followers and following | **Live** owned/followed Lists and account memberships; **No** List timelines | Nine guarded `xurl` streams; bounded List snapshots rescan without inferring deletion. |
| Reddit | **Live** submissions and comments | **Live** saved, votes, and hidden | **Live** mentions, replies, inbox, and sent | **Live** subreddit and account relationships | **Live** multireddits and membership | PRAW 8, bounded one-page reads, independent cursors, and provider-window coverage. |
| YouTube | **Live** uploads; **Live/Partial** activity | **Live** likes; **No/Export** watch history and Watch Later | **Live/Gate** channel-related comments and replies; **No/Export** complete authored history | **Live** outbound subscriptions | **Live** owned playlists and membership; **No/Export** saved playlists | `youtube.readonly` user OAuth, identity recheck per page, bounded list quota, 30-day refresh/delete boundary, and explicit gap rows. |
| LinkedIn | **Gate/Export** | **Gate/Export** | **Export** | **Gate/Export** | **Export/No** | Treat member access as restricted; do not reuse browser engagement automation as a collector. |
| Facebook | **Gate/Export** | **Gate/Export** | **Gate/Export** | **Gate/Export** | **Gate/Export** | Shared Meta authorization needs app-review and product-specific evidence. |
| Instagram | **Gate/Export** media | **Gate/Export** | **Gate/Export** comments and mentions | **Gate/Export** | **Export/No** | Verify Professional versus personal-account coverage before implementation. |
| Threads | **API/Gate/Export** | **API/Gate/Export** | **API/Gate/Export** replies | **Gate/Export** | **No** until verified | Keep authorization and gaps distinct from Facebook and Instagram despite shared Meta identity. |
| Medium | **Export/Gate** | **Export/No** | **Export/No** | **Export/No** | **Export/No** | Archive-first; legacy or restricted integration access is not sufficient evidence for live parity. |
| Quora | **Export** | **Export/No** | **Export/No** | **Export/No** | **No** | No general live account API is accepted without new official evidence. |
| Skool | **Gate/Export/Gap** | **Gate/Export/Gap** | **Gate/Export/Gap** | **Gate/Export/Gap** | **Gate/Export/Gap** | Verify member versus community-admin access and provider terms before selecting any route. |
| Discourse | **API/Export** | **API/Export** | **API/Gate/Export** | **API/Gate/Export** | **API/Gate/Export** | Scope by installation and user/API-key authority; support hosted and self-hosted instances. |
| NodeBB | **API/Gate/Export** | **API/Gate/Export** | **API/Gate/Export** | **API/Gate/Export** | **API/Gate/Export** | Verify core REST routes, enabled plugins, and forum privileges per installation. |

## Recommended candidates

| Provider family | Authored content | Interactions and curation | Mentions or messages | Relationships and subscriptions | Lists or custom feeds | Current disposition |
|---|---|---|---|---|---|---|
| Mastodon | **API** | **API** favourites and bookmarks | **API** notifications | **API** follows | **API** lists | Strong official-API candidate; account for instance-specific retention and limits. |
| Bluesky / AT Protocol | **API** | **API** likes and reposts | **API/Gate** notifications or chat | **API** follows | **API** lists and feeds | Separate repository records, AppView reads, and chat authorization. |
| Lemmy | **API** | **API** saved and votes | **API** replies and mentions | **API** communities | **API/Gate** | Verify instance version and federation-visible versus private account state. |
| Stack Exchange | **API/Export** | **API/Export** | **API/Gate** inbox | **API/Export** associated accounts | **No** until verified | Observe API quota and per-site identity boundaries. |
| GitHub | **API/Export** | **API** reactions, stars, and watches | **API** notifications and discussions | **API** follows, organizations, and repositories | **API/Gate** saved lists/projects | Keep developer-work evidence distinct from general social engagement. |
| Hacker News | **API** public submissions and comments | **No** private votes or saved items | **No** | **No** | **No** | Public account history only; do not infer authenticated/private state. |
| RSS/Atom readers | **API/Export** feed items | **API/Export** reader state where supported | **No** | **Export** subscriptions | **Export** folders/tags | Treat OPML and reader APIs as source-specific adapters, not one universal account API. |
| Read-later services | **API/Export** saved pages | **API/Export** tags and archive state | **No** | **No** | **API/Export** tags/lists | Select maintained services individually; do not assume one provider's API or export contract. |

## Evidence and update discipline

- **Live X:** `.agents/scripts/knowledge_social_x.py` and
  `.agents/tests/test-knowledge-social-x.sh` prove nine implemented streams,
  including independently checkpointed owned, followed, and membership List
  snapshots with stable relationship direction. The 2026-07-26 dependency check
  found no worker-local `xurl`; official v1.3.1 source exposes generic raw GETs
  but no List shortcut. Official endpoints require `list.read`, `tweet.read`,
  and `users.read`; List timelines and archive coverage remain explicitly
  unimplemented.
- **Live Reddit:** `.agents/scripts/knowledge_social_reddit.py`,
  `.agents/scripts/_knowledge_social_reddit*.py`, and
  `.agents/tests/test-knowledge-social-reddit.sh` prove the stream allowlist,
  read-only boundary, cursor behavior, snapshots, and sanitized failures.
- **Live YouTube:** `.agents/scripts/knowledge_social_youtube.py`,
  `.agents/scripts/_knowledge_social_youtube*.py`, and
  `.agents/tests/test-knowledge-social-youtube.sh` prove OAuth-owned identity,
  quota accounting, compound playlist/comment checkpoints, explicit gaps, and a
  GET-only provider boundary. `.agents/content/social-youtube.md` records the
  official route, scope, retention, export, and unsupported evidence checked on
  2026-07-26.
- **All candidate rows:** the provider child owns current official documentation,
  account/export samples, auth scopes, dependency versions, local exported
  symbols, retention evidence, and explicit unsupported findings.
- A child changes a candidate cell to **Live** only after identity mismatch,
  credential rejection, pagination/resume, bounded-stop, terminal-failure,
  replay/idempotency, and write-reachability tests pass.
- If API/archive coverage is partial, persist an explicit coverage gap. Browser
  evidence remains a bounded last resort under `05-social-operations.md`.
