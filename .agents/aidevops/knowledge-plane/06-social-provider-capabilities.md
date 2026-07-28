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
| LinkedIn | **Live/Gate/Export** posts and articles | **Live/Gate/Export** comments, reactions, and saved items | **Live/Gate/Export** messages | **Live/Gate/Export** follows, connections, company follows, and groups | **No** newsletter subscriptions | Ten GET-only Member Snapshot streams for eligible EEA/Swiss members; account download remains an unwired export fallback. |
| Facebook | **Live/Gate/Export** managed Page posts; **No/Export** personal profile | **No/Export** curated activity and per-post comments | **No/Export** | **No/Export** personal relationships | **No** | One managed-Page `/posts` stream; app review and Page authority remain explicit, with all personal-account categories excluded. |
| Instagram | **Live/Gate/Export** Professional media | **No/Export** comments and saved activity | **No/Export** mentions | **No/Export** followers and following | **No/Export** saved collections | One Page-connected Business/Creator `/media` stream; personal accounts and unimplemented per-media edges remain explicit. |
| Threads | **Live/Gate/Export** posts | **No/Export** likes and repost history | **Live/Gate/Export** authored replies and mentions; **No** messages | **No/Export** followers and following | **No** custom feeds | Three product-scoped streams with app-scoped identity, independent cursors, and stream-specific permission gates. |
| Medium | **Live/Export** authored posts; **Live/Partial** explicit responses | **Live/Export/No** bookmarks, claps, highlights, and list membership when present | **No** | **Live/Export/No** publication membership and follows when present | **Live/Export/No** owned lists when present | Identity-verified native HTML ZIP import with exact replay, bounded local parsing, and per-archive complete/unavailable coverage; legacy API access is not live parity. |
| Quora | **Export/No** answers, questions, posts, and comments | **Export/No** bookmarks; **No** upvotes and other curation | **No** | **Export/No** user follows; **No** followed topics or Spaces | **No** | The official export has no published schema. Public content samples lack authoritative owner identity, and the companion account-data schema is unpublished; no adapter or CLI route is enabled. |
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
- **Live LinkedIn:** `.agents/scripts/knowledge_social_linkedin.py`,
  `.agents/scripts/_knowledge_social_linkedin*.py`, and
  `.agents/tests/test-knowledge-social-linkedin.sh` prove ten independently
  checkpointed Member Snapshot domains, identity rebinding, content-addressed
  replay, credential rejection, bounded GET-only transport, consent/deletion
  coverage, and static isolation from browser mutation tooling.
  `.agents/content/social-linkedin.md` records the official regional/product
  gates, `202312` endpoint version, 28-day changelog boundary, account export,
  storage terms, and explicit newsletter disposition checked on 2026-07-27.
- **Live Meta products:** `.agents/scripts/knowledge_social_meta.py`,
  `.agents/scripts/_knowledge_social_meta*.py`, and
  `.agents/tests/test-knowledge-social-meta.sh` prove separately namespaced
  Facebook, Instagram, and Threads identities, stream registries, OAuth token
  filters, checkpoints, coverage gaps, GET-only transport, field allowlists,
  cursor sanitization, and atomic fenced persistence. Facebook enables managed
  Page posts, Instagram enables Page-connected Professional media, and Threads
  enables posts, authored replies, and mentions. `.agents/content/social-meta.md`
  records the official SDK/sample versions, account/app-review gates, scopes,
  pagination, retention boundary, export dispositions, and unsupported
  categories checked on 2026-07-27.
- **Live Medium export:** `.agents/scripts/knowledge_social_medium.py`,
  `.agents/scripts/_knowledge_social_medium*.py`, and
  `.agents/tests/test-knowledge-social-medium.sh` prove selected-account
  identity, safe ZIP handling, bounded item/byte costs, immutable original-ZIP
  evidence, content-addressed replay, authored/curated separation, explicit
  response and absent-category gaps, lease fencing, sanitized credential
  rejection, and static isolation from network/browser/outbound mutation paths.
  `.agents/content/social-medium.md` records the official HTML-ZIP export,
  unsupported legacy API, terms, retention, historical community schema
  evidence, and unverified categories checked on 2026-07-28.
- **Quora export disposition:** `.agents/content/social-quora.md` records the
  official owner-request route, current public archive observations, absent
  schema and retention guarantees, and the identity-verification gap checked on
  2026-07-28. `.agents/tests/test-knowledge-social-quora.sh` proves that no
  provider module, helper command, or **Live** matrix claim is reachable until
  an identity-bearing private sample validates the companion archive contract.
- **All candidate rows:** the provider child owns current official documentation,
  account/export samples, auth scopes, dependency versions, local exported
  symbols, retention evidence, and explicit unsupported findings.
- A child changes a candidate cell to **Live** only after identity mismatch,
  credential rejection, pagination/resume, bounded-stop, terminal-failure,
  replay/idempotency, and write-reachability tests pass.
- If API/archive coverage is partial, persist an explicit coverage gap. Browser
  evidence remains a bounded last resort under `05-social-operations.md`.
