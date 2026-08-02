<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Recommended social provider evidence

Checked on 2026-08-02. These are implementation dispositions, not enabled
collection routes. Every implementation child must revalidate the cited official
contract, installed dependencies, account scopes, and provider behavior before
changing a matrix row to **Live**.

## Ranked implementation candidates

| Rank | Provider | Preferred route | Key boundary |
|---:|---|---|---|
| 1 | Mastodon ([#29221](https://github.com/marcusquinn/aidevops/issues/29221)) | Official account API | Instance-qualified identity, operator-defined retention, and opaque `Link` pagination. |
| 2 | GitHub ([#29222](https://github.com/marcusquinn/aidevops/issues/29222)) | REST plus GraphQL | Durable numeric/node identity; token-family capability differences; no complete reaction ledger. |
| 3 | Stack Exchange ([#29223](https://github.com/marcusquinn/aidevops/issues/29223)) | API v2.3 | Network account plus per-site identity; mandatory backoff and per-site checkpoints. |
| 4 | Miniflux ([#29224](https://github.com/marcusquinn/aidevops/issues/29224)) | Official self-hosted API | GET-only local allowlist because API keys are not read-only scoped. |
| 5 | Readwise Reader ([#29225](https://github.com/marcusquinn/aidevops/issues/29225)) | Official Reader API | Token validation lacks a stable account identifier; deployment must bind an expected account independently. |
| 6 | FreshRSS ([#29226](https://github.com/marcusquinn/aidevops/issues/29226)) | Google Reader API plus OPML | Dedicated API password is mutation-capable; Fever is fallback-only. |
| 7 | Lemmy ([#29227](https://github.com/marcusquinn/aidevops/issues/29227)) | Version-gated v4/v3 APIs | Numeric IDs are instance-local; v4 cursors and features must not be assumed on v3. |
| 8 | Hacker News ([#29228](https://github.com/marcusquinn/aidevops/issues/29228)) | Public Firebase API | Public submitted-item history only; no authenticated or private account state. |

Raindrop.io is a bounded optional bookmark candidate after the eight routes
above. Inoreader is deferred unless an existing Pro account justifies its quota
and lookback limits. Wallabag is deferred behind Reader because the current
official API contract has weaker identity evidence and older password-grant
guidance. Feedly is not a general private-reader route because current access is
enterprise-focused and terms restrict mass export. Instapaper remains deferred
until current official documentation can be verified. Pocket is discontinued.

The eight linked issues are provider-specific implementation authorities. This
research task does not make any candidate route live and does not authorize one
child to widen another provider's identity, permission, or coverage contract.
Bluesky / AT Protocol needs no new child: its DID-bound repository and AppView
collector is already **Live** in the provider registry and capability matrix;
separately permissioned chat remains outside that read contract.

## Federated providers

### Mastodon

- Identity: `GET /api/v1/accounts/verify_credentials`; namespace the returned
  account ID by home instance and retain `uri`/`acct`.
- Candidate streams: authored statuses, favourites, bookmarks, notifications,
  followers/following, followed tags, lists and list members. Conversations need
  separate private-data consent.
- Pagination: IDs are opaque strings. Relationship collections can require the
  complete RFC `Link` URLs because response objects do not expose the internal
  relationship cursor.
- Default documented limits are 300 requests per five minutes per account and
  independently per IP, but instances may override them.
- Exports cover posts/media and selected relationship CSVs, not a complete
  notification/favourite history. Federation, moderation, deletion, and
  instance-specific retention remain explicit gaps.
- Official evidence:
  <https://docs.joinmastodon.org/methods/accounts/#verify_credentials>,
  <https://docs.joinmastodon.org/methods/accounts/#statuses>,
  <https://docs.joinmastodon.org/methods/favourites/>,
  <https://docs.joinmastodon.org/methods/bookmarks/>,
  <https://docs.joinmastodon.org/methods/notifications/>,
  <https://docs.joinmastodon.org/methods/lists/>,
  <https://docs.joinmastodon.org/api/guidelines/#pagination>,
  <https://docs.joinmastodon.org/api/rate-limits/>, and
  <https://docs.joinmastodon.org/user/moving/#export>.

### Lemmy

- Discover the instance version before routing. Current main documentation
  describes `/api/v4`; official 0.19 documentation describes `/api/v3`.
- v4 candidates are authenticated account identity, authored person content,
  saved and liked objects, unified notifications, subscribed communities, and
  multicommunities. v3 needs a separately verified route map and keeps unsupported
  parity explicit.
- Namespace numeric person IDs by home instance and retain ActivityPub `ap_id`.
  Persist v4 `page_cursor` values without parsing them; restart incremental reads
  from newest with overlap because cursors can change in minor versions.
- Settings export is not a complete authored-content, vote, notification, or
  private-message archive. Federation and operator retention create gaps.
- Official evidence: <https://join-lemmy.org/docs/print.html#api>,
  <https://join-lemmy.org/api/main>, and
  <https://join-lemmy.org/lemmy-js-client-docs/v0.19/classes/LemmyHttp.html>.

## Developer and public sources

### GitHub

- Bind `GET /user` numeric `id` and REST `node_id`; verify that node identity
  against GraphQL `User.id`, and never bind mutable login alone.
- Candidate streams include contributions, repositories, stars, notifications,
  followers/following, organizations, subscriptions, user lists, and visible
  Projects v2. Reactions have no complete account-centric history route.
- Follow REST `Link` headers and GraphQL `pageInfo`; honor primary and secondary
  rate limits. Notification support differs across classic PAT, fine-grained PAT,
  OAuth, and GitHub App credentials.
- User migration archives omit broad social state and expire after seven days.
- Official evidence: <https://docs.github.com/en/rest/users/users>,
  <https://docs.github.com/en/graphql/reference/users>,
  <https://docs.github.com/en/rest/activity/notifications>,
  <https://docs.github.com/en/rest/activity/starring>,
  <https://docs.github.com/en/rest/migrations/users>, and
  <https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api>.

### Stack Exchange

- Bind OAuth `/me` network `account_id` plus each site's `user_id` and
  `api_site_parameter` from `/me/associated`.
- Candidate streams are authored posts/questions/answers/comments, favourites,
  inbox, notifications, and associated accounts. Complete votes, follows,
  subscriptions, lists, projects, and a verified account archive remain gaps.
- Page size is at most 100. Continue only while `has_more`; obey `backoff`, daily
  quota, 30 requests/second/IP, and duplicate-request suppression guidance.
- Official evidence: <https://api.stackexchange.com/docs>,
  <https://api.stackexchange.com/docs/authentication>,
  <https://api.stackexchange.com/docs/me-associated-users>,
  <https://api.stackexchange.com/docs/me-posts>,
  <https://api.stackexchange.com/docs/me-favorites>,
  <https://api.stackexchange.com/docs/me-inbox>,
  <https://api.stackexchange.com/docs/paging>, and
  <https://api.stackexchange.com/docs/throttle>.

### Hacker News

- Collect only the public `submitted` IDs for one case-sensitive username and
  resolve a bounded number through the official item API.
- The API exposes no immutable numeric account ID, votes, favourites, inbox,
  notifications, relationships, subscriptions, or custom lists. Missing,
  deleted, and dead items are coverage evidence, never inferred private state.
- Official evidence: <https://github.com/HackerNews/API> and
  <https://hacker-news.firebaseio.com/v0/>.

## Reader and read-later services

### Miniflux

`GET /v1/me` provides identity. Feeds, categories, entries, read/removed/starred
state, tags, OPML, ascending entry-ID bounds, and `changed_after` support bounded
replay. Retention is operator-configurable. Use only GET endpoints even though
application API keys can mutate state. Official evidence:
<https://miniflux.app/docs/api.html> and
<https://miniflux.app/docs/configuration.html>.

### FreshRSS

Use the Google Reader compatibility API for subscriptions, folders/tags, items,
unread and starred state; use OPML as an independent subscription snapshot.
The non-mutating `accounts/ClientLogin` authentication exchange is the sole
allowlisted POST; collection routes remain GET-only. Fever's 50-item
`since_id`/`max_id` flow is fallback-only. The dedicated API password is not
read-only scoped. Official evidence:
<https://freshrss.github.io/FreshRSS/en/developers/06_GoogleReader_API.html>,
<https://freshrss.github.io/FreshRSS/en/developers/06_Fever_API.html>, and
<https://freshrss.github.io/FreshRSS/en/developers/OPML.html>.

### Readwise Reader

The official API provides cursor-paginated documents, tags, notes, state,
progress, optional HTML, and `updatedAfter`; list/tag routes are documented at 20
requests/minute. Token validation proves validity but not the expected account
identity, so implementation remains gated on an independent deployment binding.
Official evidence: <https://readwise.io/reader_api>,
<https://readwise.io/privacy>, and <https://readwise.io/tos>.

### Deferred and rejected readers

- Raindrop.io: technically viable identity, collection/tag/highlight API and
  complete export, but no read-only OAuth scope; defer until bookmark demand
  justifies another provider. Evidence: <https://developer.raindrop.io/> and
  <https://developer.raindrop.io/v1/export.md>.
- Inoreader: read-only OAuth and strong identity, but Pro access, 100 Zone-1
  requests/day, and approximately one-month timestamp lookback make backfills
  fragile. Evidence: <https://www.inoreader.com/developers/rate-limiting>.
- Wallabag: self-hosted export is useful, but password-grant auth and the older
  documented API contract are weaker than Reader. Evidence:
  <https://doc.wallabag.org/developer/api/readme.html>.
- Feedly: enterprise-focused authorization and restrictive export terms are not
  a portable personal-account contract. Evidence:
  <https://developers.feedly.com/reference/authorization.md> and
  <https://developers.feedly.com/reference/feedly-api-terms-of-service.md>.
- Instapaper: no current machine-verifiable official contract was established;
  remain deferred. Pocket: discontinued; do not implement.
