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
| Skool | **No** posts, comments, and course content | **No** reactions and saved state | **No** notifications and messages | **No** memberships, follows, and groups | **No** courses and calendar feeds | **Export/No** admin membership-question answers only. The official Zapier surface is narrow event automation, the export schema and identity contract are unpublished, and provider policy excludes browser collection. |
| Discourse | **Live** topics and posts | **Live/Partial** likes, bookmarks, and current reading state | **Live/Gate/Partial** notifications and private-topic metadata; **No** message bodies | **Live/Partial** groups and category preferences; **No** unverified Follow plugin | **No** watched/tracked topic inventories until search behavior is verified | Ten User API `read` streams with per-installation namespaces, repeated identity checks, exact GET routes, redirect rejection, and explicit plugin/export/history gaps. |
| NodeBB | **Live** topics and posts | **Live/Partial** votes, bookmarks, watched topics, and category state | **Live/Partial** notifications and chat-room metadata; **No** message bodies | **Live/Partial** follows and groups | **No** plugin-provided lists | Thirteen independently checkpointed core GET streams with per-installation identity, bounded pagination, and explicit admin/plugin/export/history gaps. |
| Mastodon | **Live/Partial** authored statuses | **Live/Partial** favourites and bookmarks | **Live/Gate/Partial** notifications; **No/Gate** conversations | **Live/Partial** followers, following, and followed tags | **Live/Partial** lists; **No** nested membership | Eight exact-origin GET-only streams preserve opaque `Link` cursors and expose federation, moderation, deletion, export, and operator-retention gaps. |
| GitHub | **Live/Partial** contribution calendar and repositories | **Live/Partial** stars and subscriptions; **No** complete reactions | **Live/Gate/Partial** notifications | **Live/Gate/Partial** followers, following, and organizations | **Live/Gate/Partial** user lists and visible Projects v2 | Ten numeric/node-identity-bound streams preserve REST `Link` and GraphQL `pageInfo` cursors; token family, visibility, migration expiry, deletion, and audit authority remain explicit. |
| Stack Exchange | **Live/Partial** posts, questions, answers, and comments | **Live/Partial** favourites; **No** complete votes | **Live/Gate/Partial** inbox and notifications | **Live/Partial** associated site accounts; **No** follows | **No** | Eight network-plus-site-identity-bound GET streams obey `has_more`, `backoff`, quota, and 100-item page limits while preserving archive and inaccessible-history gaps. |
| Miniflux | **Live/Partial** feed entries | **Live/Partial** read, removed, starred, and tagged state | **No** | **Live/Partial/Export** subscriptions | **Live/Partial/Export** categories and tags | Eight keyed-installation account streams use five exact GET routes, ascending entry-ID backfill, one-second `changed_after` overlap, bounded snapshots, and explicit operator-retention gaps. |

## Integrated provider families

These independently implemented contracts are registered by canonical provider ID
and explicit aliases. `provider-run` requires an exact supported mode and never
falls back to another provider or to an outbound mutation route.

| Provider | Implemented mode | Explicit gaps and boundaries |
|---|---|---|
| Slack | **Live** Web API; **Live/Export** approved archive | Workspace identity, token visibility, plan retention, and export authority remain explicit. |
| Discord | **Live/Gate** bounded bot-visible reads | User-token automation and unavailable private history remain unsupported. |
| WhatsApp | **Live/Export** consumer chat archives; **Live/Gate** Business webhook events | No consumer-account polling or mutation route. |
| Signal | **Live/Manual** offline `signal-cli` receive-event import | No remote account API, history scraping, or send reachability. |
| Nextcloud Talk | **Live** multi-instance reads | Instance identity, room membership, retention, and webhook coverage remain explicit. |
| Gumroad | **Live/Gate** seller-account reads | Buyer/seller visibility and unavailable private or mutation categories remain explicit. |
| Google Business Profile | **Live/Gate** account/location reads | Listing writes and other management authority are isolated from collection. |
| Telegram | **Live/Export** account archive; **Live/Gate** bot events | No user-account polling, private-history inference, or bot mutation route. |
| Binance Square | **No** | Officially verified surfaces are mutation-only; no adapter, export, browser, or credential route is registered. |
| Bluesky / AT Protocol | **Live** repository/AppView reads | Chat remains separately permissioned; account identity is a stable DID. |
| Forem | **Live** multi-instance reads | `dev-community` and `dev.to` are aliases of `forem`, not separate providers. |

HubSpot Community remains a Discourse installation and is not registered as a
separate provider family.

## Recommended candidates

| Provider family | Authored content | Interactions and curation | Mentions or messages | Relationships and subscriptions | Lists or custom feeds | Current disposition |
|---|---|---|---|---|---|---|
| Mastodon | **Live/Partial** | **Live/Partial** favourites and bookmarks | **Live/Gate/Partial** notifications; **No/Gate** conversations | **Live/Partial** follows and followed tags | **Live/Partial** lists; **No** nested membership | #29221 implements exact-origin identity-bound reads with opaque `Link` cursors and explicit federation/operator-retention gaps. |
| Bluesky / AT Protocol | **Live** records | **Live** likes and reposts | **Live/Gate** notifications; **No/Gate** chat | **Live** follows | **Live** lists and feeds | DID-bound repository/AppView reads with separate chat authorization. |
| Lemmy | **API/Gate** versioned authored content | **API/Gate** saved and liked state | **API/Gate** unified v4 or split v3 inbox | **API/Gate** communities; **No** person follows | **API/Gate** v4 multicommunities | Rank 7, #29227. Implement only behind exact v4/v3 discovery; namespace local IDs and preserve opaque version-sensitive cursors. |
| Stack Exchange | **Live/Partial** authored content | **Live/Partial** favourites; **No** complete vote history | **Live/Gate/Partial** inbox and notifications | **Live/Partial** associated site accounts; **No** follows | **No** | #29223 implements network plus per-site identity, mandatory `backoff` and quota stops, bounded paging, and explicit archive/completeness gaps. |
| GitHub | **Live/Partial** contributions | **Live/Partial** stars and subscriptions; **No** complete reactions | **Live/Gate/Partial** notifications; **No** discussions | **Live/Gate/Partial** follows, organizations, and repositories | **Live/Gate/Partial** user lists and Projects v2 | #29222 implements numeric/node identity, token-family gates, opaque mixed-API cursors, and no complete reaction or social export claim. |
| Hacker News | **API/Partial** public submissions and comments | **No** private votes or saved items | **No** | **No** | **No** | Rank 8, #29228. Bounded public history only, keyed by case-sensitive username and item ID; never infer private state. |
| Miniflux | **Live/Partial** feed items | **Live/Partial** read, removed, starred, and tagged state | **No** | **Live/Partial/Export** subscriptions | **Live/Partial/Export** categories/tags | #29224 implements keyed installation/user identity, exact GET-only routes, incremental overlap, snapshots, and explicit operator-retention gaps. |
| FreshRSS | **API/Export** feed items | **API** unread and starred state | **No** | **API/Export** subscriptions | **API/Export** folders/tags | Rank 6, #29226. Allow one non-mutating login POST, then GET-only Google Reader collection; reconcile OPML and keep Fever fallback-only. |
| Readwise Reader | **API/Export** saved documents | **API/Export** tags, state, notes, and progress | **No** | **No** | **API/Export** tags and locations | Rank 5, #29225. Strong cursor/update contract, but implementation is gated on expected-account binding because token validation has no stable account ID. |
| Other readers/read-later | **API/Export/Gate/No** | **API/Export/Gate/No** | **No** | **API/Export/Gate/No** | **API/Export/Gate/No** | Raindrop optional; Inoreader and Wallabag deferred; Feedly and Pocket rejected; Instapaper remains unverified. |

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
- **Live Discourse:** `.agents/scripts/knowledge_social_discourse.py`,
  `.agents/scripts/_knowledge_social_discourse*.py`, and
  `.agents/tests/test-knowledge-social-discourse.sh` prove ten independently
  checkpointed account streams, corpus-local keyed installation fingerprints,
  current-user rebinding, bounded GET-only routes, redirect and write isolation,
  credential rejection, scope-gated message metadata, terminal coverage,
  content-addressed replay, and final lease fencing.
  `.agents/content/social-discourse.md` records the current User API `read`
  scope, core routes and pagination, hosted/self-hosted variability, optional
  Follow plugin, archive mutation/retention boundary, installation terms, and
  explicit unsupported categories checked on 2026-07-28.
- **Live NodeBB:** `.agents/scripts/knowledge_social_nodebb.py`,
  `.agents/scripts/_knowledge_social_nodebb*.py`, and
  `.agents/tests/test-knowledge-social-nodebb.sh` prove thirteen independently
  checkpointed core streams, keyed installation namespaces, repeated `/api/self`
  identity checks, dedicated-user bearer-token policy, bounded page/start
  cursors, exact GET routes, redirect and mutation isolation, sanitized terminal
  coverage, credential rejection, replay, and lease-fenced atomic persistence.
  `.agents/content/social-nodebb.md` records NodeBB v4.14.2 core Read/v3 API
  evidence, public capability limits, admin-only version/plugin discovery,
  account-visible permissions, exports, retention, terms, and explicit plugin,
  message-body, and history gaps checked on 2026-07-28.
- **Live Mastodon:** `.agents/scripts/knowledge_social_mastodon.py`,
  `.agents/scripts/_knowledge_social_mastodon*.py`, and
  `.agents/tests/test-knowledge-social-mastodon.sh` prove home-instance identity,
  eight independent streams, exact same-origin RFC Link resume, read-scope and
  GET-only enforcement, credential rejection, terminal coverage, and atomic
  persistence. `.agents/content/social-mastodon.md` records official routes,
  scopes, pagination, default rate limits, exports, and explicit gaps checked on
  2026-08-02.
- **Live GitHub:** `.agents/scripts/knowledge_social_github.py`,
  `.agents/scripts/_knowledge_social_github*.py`, and
  `.agents/tests/test-knowledge-social-github.sh` prove REST plus GraphQL identity
  binding, ten independent streams, opaque mixed-API resume, explicit token-family
  capability, exact REST GET routes, fixed GraphQL read queries, mutation and
  credential rejection, terminal coverage, request accounting, and atomic
  persistence. `.agents/content/social-github.md` records official identity,
  stream, pagination, rate-limit, migration, and completeness evidence checked on
  2026-08-02.
- **Live Stack Exchange:** `.agents/scripts/knowledge_social_stack_exchange.py`,
  `.agents/scripts/_knowledge_social_stack_exchange*.py`, and
  `.agents/tests/test-knowledge-social-stack-exchange.sh` prove network-plus-site
  identity, eight independent streams, bounded page resume, mandatory `backoff`
  and quota stops, read-scope and GET-only enforcement, credential rejection,
  terminal coverage, and atomic persistence. `.agents/content/social-stack-exchange.md`
  records official v2.3 identity, route, OAuth, paging, filter, quota, throttle,
  duplicate-request, and completeness evidence checked on 2026-08-02.
- **Live Miniflux:** `.agents/scripts/knowledge_social_miniflux.py`,
  `.agents/scripts/_knowledge_social_miniflux*.py`, and
  `.agents/tests/test-knowledge-social-miniflux.sh` prove keyed installation/user
  identity, eight independent streams, ascending-ID resume, one-second
  `changed_after` overlap, OPML replay, exact GET-only transport, credential
  rejection, terminal coverage, and atomic persistence.
  `.agents/content/social-miniflux.md` records official current identity, entries,
  feed, category, OPML, authentication, version, and operator-retention evidence
  checked on 2026-08-02.
- **Integrated provider registry:** `.agents/scripts/knowledge_social_registry.py`
  and `.agents/tests/test-knowledge-social-registry.sh` prove order-independent
  registration, collision rejection, exact aliases and modes, no-route failure,
  allowlisted local execution, and the absence of fallback dispatch. Provider-
  focused tests remain the authority for identity, pagination/import replay,
  budgets, persistence, coverage, and mutation isolation.
- **Quora export disposition:** `.agents/content/social-quora.md` records the
  official owner-request route, current public archive observations, absent
  schema and retention guarantees, and the identity-verification gap checked on
  2026-07-28. `.agents/tests/test-knowledge-social-quora.sh` proves that no
  provider module, helper command, or **Live** matrix claim is reachable until
  an identity-bearing private sample validates the companion archive contract.
- **Skool gap disposition:** `.agents/content/social-skool.md` records the
  official Pro-plan Zapier membership events, narrow admin answers export,
  privacy-access rights, absent API/export contracts, and anti-automation terms
  checked on 2026-07-28. `.agents/tests/test-knowledge-social-skool.sh` proves
  that no provider module, helper command, browser selector, or **Live** matrix
  claim is reachable until an identity-bearing official export is validated.
- **All candidate rows:** the provider child owns current official documentation,
  account/export samples, auth scopes, dependency versions, local exported
  symbols, retention evidence, and explicit unsupported findings.
- A child changes a candidate cell to **Live** only after identity mismatch,
  credential rejection, pagination/resume, bounded-stop, terminal-failure,
  replay/idempotency, and write-reachability tests pass.
- If API/archive coverage is partial, persist an explicit coverage gap. Browser
  evidence remains a bounded last resort under `05-social-operations.md`.
- **Recommended candidate evidence:**
  `.agents/content/social-provider-candidates.md` records the official identity,
  API/export, pagination, quota, retention, terms, and unsupported evidence
  checked on 2026-08-02, plus the ranked per-provider child disposition.
