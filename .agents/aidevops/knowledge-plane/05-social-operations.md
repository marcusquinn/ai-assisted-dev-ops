<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Social Corpus Operations

Social collection is read-only and follows a fixed order: official API, account
archive, then browser-gap capture. A browser artifact is not accepted merely
because it is available; an explicit private gap record must first identify a
provider stream whose API/archive coverage is partial or unavailable.

## Provider extension contract

Each provider manifest is private mode-0600 JSON. Contract version 1 requires:

- an opaque `provider` ID and unique provider-neutral `streams`;
- `collection_routes` exactly `api`, `archive`, `browser_gap` in that order;
- an empty `write_operations` array;
- `browser_gap.read_only` and `browser_gap.checkpointed` set to `true`.

Validate a manifest before implementation or collection:

```bash
knowledge-social-helper.sh provider-validate --manifest provider.json
```

Provider adapters normalize records into the existing account, object, activity,
media, coverage, and raw-batch schema. Provider-only fields remain inside
`provider_json`. New adapters must preserve opaque local connection IDs, reject
credential-shaped fields, use independent stream checkpoints, expose hard cost
budgets, and add pagination, terminal-failure, replay, and write-reachability
tests. No provider may add engagement or other platform mutations.

Schema v5 applies the shared source contract without merging physically
specialized stores. Each private social database owns one opaque corpus identity;
every `fetch_batches` row points to one `evidence_sources` raw record, and the
normalized object, activity, and media rows are exposed only as
`canonical_evidence_projections`. Migration from v4 backfills these links in one
transaction without rewriting raw gzip artifacts, cursors, coverage, or provider
rows. Replay preserves both evidence and projection IDs.

Candidate implementation is provider-specific, not one generic social adapter.
Mastodon #29221, GitHub #29222, Stack Exchange #29223, Miniflux #29224,
Readwise Reader #29225, FreshRSS #29350, Lemmy #29227, public-only Hacker News
issue #29228, Hashnode #29323, beehiiv #29319, and Ghost #29318 are now live. Each
route owns its identity contract, stream allowlist, checkpoint semantics, and
negative write-reachability tests. Raindrop.io remains optional; Inoreader,
Wallabag, Feedly, Instapaper, and Pocket are deferred or rejected for the reasons
in `.agents/content/social-provider-candidates.md`.

Notion Sites #29322 is also live as an integration-scoped document route. It is
not a public-site crawler: the selected bot workspace and an explicit root-page
UUID allowlist are rebound before every content request. Details:
`.agents/content/social-notion-sites.md`.

The maintained planning and gap inventory is
`06-social-provider-capabilities.md`. A matrix entry is not implementation
authority: every provider child must revalidate current official API/export
access, required scopes, installed dependency symbols, retention, and terms
before adding a route.

Substack has no enabled collection route. Its official publication ZIP and
subscriber CSV have no published stable publication identity or versioned schema;
public RSS is partial publication syndication rather than authenticated account
history. The read-only MCP surface is limited to eligible Bestseller publication
analytics, requires interactive sign-in and consent, and explicitly excludes
profile and Notes activity. No manifest, provider registry entry, helper command,
RSS/browser fallback, or persistence path is added. The evidence and activation
gate are recorded in `.agents/content/social-substack.md`.

Google Sites has no enabled collection route. The deprecated Sites API is
classic-only and cannot access rebuilt Sites. Drive exposes a Sites MIME type and
file metadata, but its supported export table provides no Sites content format or
modern revision-history route. User Takeout is an identity/schema-unverified
export candidate, the Data Portability API has no Sites scope, and organization
export requires super-admin authority. No provider registry entry, helper command,
Drive OAuth request, Takeout importer, browser fallback, or persistence path is
added. The evidence and activation gate are recorded in
`.agents/content/social-google-sites.md`.

## Live account collection

Live collectors verify the selected stable account before the first evidence
write. Each invocation owns one stream lease and fencing token, spends a bounded
request budget, and atomically commits the raw boundary envelope, normalized
rows, coverage, receipt, and next checkpoint. A terminal or malformed page keeps
the previous checkpoint. Snapshot streams never infer deletion from partial
coverage.

Ghost collection binds an opaque operator-selected publication ID to the exact
frontend URL returned by unauthenticated `GET /ghost/api/admin/site/` before
every page. Four independent snapshot streams use only Ghost v6 Content API GET
routes for published posts, pages, public tags, and public authors. The Content
credential is isolated in a child process and never reaches evidence; redirects,
Admin authentication, mutation-capable routes, members, newsletters, comments,
and automated exports are unreachable. Details: `.agents/content/social-ghost.md`.

Mastodon collection uses a user token bound to one exact HTTPS home instance and
rechecks `GET /api/v1/accounts/verify_credentials` before every page. Authored
statuses, favourites, bookmarks, notifications, followers, following, followed
tags, and lists have independent snapshot checkpoints. Complete same-origin
`Link` targets are preserved as opaque cursors; redirects and write scopes are
rejected. Conversations, nested list membership, exports, federation,
moderation, deletion, and operator retention remain explicit gaps. Details:
`.agents/content/social-mastodon.md`.

Lemmy collection uses a selected user token and rechecks authenticated
`GET /api/v3/site` identity plus exact server version before every page. Lemmy
1.x routes only through v4 opaque `page_cursor` reads; 0.19.x routes only through
v3 numeric page/limit reads. Authored posts/comments, saved/liked posts/comments,
version-specific inbox evidence, and community subscriptions have independent
checkpoints; v4 additionally exposes multicommunities. Numeric resource IDs are
installation-namespaced while ActivityPub IDs remain evidence. Federation,
operator retention, settings exports, private-message bodies, complete vote
history, deletion, and opposite-version routes remain explicit gaps. Details:
`.agents/content/social-lemmy.md`.

GitHub collection binds `GET /user` numeric and node IDs to GraphQL `viewer`
identity before every page. Contributions, repositories, stars, notifications,
followers, following, organizations, subscriptions, user lists, and visible
Projects v2 have independent snapshot checkpoints. Exact REST `Link` targets
and GraphQL `pageInfo` cursors remain opaque. Token-family capability limits,
reactions, migration expiry, deletion, private visibility, and organization
audit authority remain explicit gaps. Details: `.agents/content/social-github.md`.

Stack Exchange collection binds OAuth `/me` network `account_id`, selected
`api_site_parameter`, and site `user_id` before every page. Authored posts,
questions, answers, comments, favourites, inbox, notifications, and associated
accounts have independent per-site checkpoints. Pages stop before persistence on
`backoff` or quota exhaustion and continue only while `has_more`. Votes, follows,
subscriptions, lists, projects, complete archives, and inaccessible site history
remain explicit gaps. Details: `.agents/content/social-stack-exchange.md`.

Hacker News collection observes an exact case-sensitive public username before
each bounded official item GET. The username remains an explicitly mutable public
selector, never authenticated identity. A versioned cursor retains the complete
bounded submitted-ID slice so resume is independent of newly prepended IDs.
Missing users/items and deleted/dead tombstones produce explicit unavailable
coverage; votes, favourites, inbox, notifications, relationships, subscriptions,
lists, removed content, and private state remain unavailable. Details:
`.agents/content/social-hacker-news.md`.

Hashnode collection binds the authenticated GraphQL viewer ID and username before
every page, then revalidates publication and authored-content ownership. Profile,
owned publications, authored posts, publication drafts, comments and likes
received on authored posts, followers, and following have independent opaque
checkpoints. Nine fixed query documents are reachable; arbitrary GraphQL,
mutations, subscriptions, redirects, partial responses, and unowned resources are
rejected. Publication and draft visibility remains Pro- and authority-gated;
authored comments elsewhere, reaction history, messages, notifications, nested
comment replies, and an unversioned historical export remain explicit gaps.
Details: `.agents/content/social-hashnode.md`.

Miniflux collection binds `/v1/me` user identity to a keyed exact HTTPS
installation before every page. Entries, read, removed, starred, tags, feeds,
categories, and OPML have independent checkpoints. Entry backfill advances by
ascending ID; later runs use `changed_after` with a one-second overlap. Only five
exact GET routes are reachable despite mutation-capable API keys. Operator cleanup,
pre-retention state, complete archives, and deletion inference remain explicit
gaps. Details: `.agents/content/social-miniflux.md`.

FreshRSS collection allows only the non-mutating Google Reader ClientLogin POST,
then binds `user-info` identity to a keyed exact HTTPS installation before every
GET-only data page. Items, unread, starred, subscriptions, folders, tags, and
OPML have independent checkpoints; item pages preserve opaque continuations and
overlap incremental timestamps by one second. A 20-request-unit invocation fuse,
page item cap, response byte cap, and continuation-cycle detection bound replay.
Modification tokens and write routes are unreachable. Fever remains fallback-only
evidence rather than a live route because its current authentication requires a
POST on a mutation-capable endpoint. Details: `.agents/content/social-freshrss.md`.

Readwise Reader collection compensates for `/api/v2/auth/` returning no stable
account ID by requiring a deployment-owned account identifier and keyed expected
token binding. A wrong but valid token fails before network collection. Documents,
tags, notes, state, progress, locations, and optional HTML use independent opaque
cursors with one-second `updatedAfter` overlap. Only fixed-origin auth, list, and
tag GET routes are reachable; each invocation is capped below the documented
20-request/minute limit. Provider identity, deletion, complete export, and
retention remain explicit gaps. Details: `.agents/content/social-readwise-reader.md`.

Patreon collection binds API v2 `/identity` creator status to an explicit set of
creator-owned campaigns before every page. Account, campaigns, posts, benefits
and tiers, and current memberships have independent checkpoints. Posts require
`campaigns.posts`; memberships additionally require `campaigns.members`, the
exact `membership-services` purpose, and a local HMAC key. Member names, email,
addresses, direct provider member IDs, and patron-owned memberships are never
requested or persisted. The invocation cap is 99 requests, below the documented
per-token minute limit. Creator CSV export remains unwired because Patreon does
not publish a versioned import schema. Details: `.agents/content/social-patreon.md`.

beehiiv collection requires an explicit creator-ownership attestation, then binds
the configured `pub_...` ID, publication name, and organization name to a
credential whose `GET /v2/publications` result exposes exactly that publication
before every page. Confirmed posts and their
paywall-enforced free web HTML use bounded API-v2 offset pages; the current post
endpoint documents page numbers rather than the API's preferred opaque cursor
shape, so the collector caps the route at page 100 and records partial coverage.
Subscriber records, segments, engagement statistics, premium content, remote
media, exports, redirects, and mutations are unreachable. Details:
`.agents/content/social-beehiiv.md`.

Notion Sites collection binds `/v1/users/me` bot and workspace identity before
every content request. It starts only from explicit root page UUIDs, follows
returned child blocks/pages and database data sources through a durable bounded
queue, and optionally lists unresolved comments when the connection has that
capability. Search, linked-page references, copied synced-block sources, external
embeds, redirects, and file URLs are never traversal targets. File metadata is
retained without URLs or downloads. The exact data-source query POST is the only
non-GET request and cannot mutate provider state. A public Site URL, workspace-
wide visibility, or a valid token without the expected workspace/root binding
never grants collection authority. Details: `.agents/content/social-notion-sites.md`.

X collection uses the guarded official `xurl` helper. Reddit collection uses an
optional PRAW 8 child. YouTube collection uses a standard-library HTTP child and
OAuth user identity; it never reuses the service-account research helper:

```bash
knowledge-social-helper.sh sync-x --alias personal:default \
  --connection-id CONNECTION_ID --account-id ACCOUNT_ID \
  --stream authored --budget 10 --media-policy metadata

aidevops secret REDDIT_DEFAULT_CLIENT_ID REDDIT_DEFAULT_CLIENT_SECRET \
  REDDIT_DEFAULT_USERNAME REDDIT_DEFAULT_PASSWORD REDDIT_DEFAULT_USER_AGENT -- \
  knowledge-social-helper.sh sync-reddit --alias personal:default \
  --connection-id REDDIT_CONNECTION_ID \
  --account-id STABLE_REDDIT_ACCOUNT_ID \
  --stream authored_comments --profile default --budget 10 --page-size 100

aidevops secret YOUTUBE_PERSONAL_ACCESS_TOKEN -- \
  knowledge-social-helper.sh sync-youtube --alias personal:default \
  --connection-id YOUTUBE_CONNECTION_ID --account-id STABLE_CHANNEL_ID \
  --stream authored_videos --profile personal --budget 11 --page-size 50

aidevops secret PATREON_CREATOR_ACCESS_TOKEN PATREON_CREATOR_CAMPAIGN_IDS \
  PATREON_CREATOR_SCOPES -- \
  knowledge-social-helper.sh sync-patreon --alias personal:default \
  --connection-id PATREON_CONNECTION_ID --account-id CREATOR_USER_ID \
  --stream posts --profile creator --budget 20 --page-size 100
```

Every Reddit stream has an independent cursor. Authored content, inbox activity,
curation signals, and other newest-first listings preserve a stable watermark
across interruptions. Subscription listings and the friends, blocked, trusted,
and multireddit/custom-feed snapshots rescan after completion without claiming
that missing rows were deleted. PRAW's available listing window is recorded as a
retention boundary rather than complete account history.

Named Reddit profile selectors and handles remain local. The child receives only
the selected `REDDIT_<PROFILE>_*` variables, emits an explicit serialized field
allowlist, and cannot reach the separate approval-bound mutation provider.

YouTube requires `youtube.readonly` user OAuth. The child receives only
`YOUTUBE_<PROFILE>_ACCESS_TOKEN`, verifies `channels.list(mine=true)` before each
page, and allows only list endpoints. Uploaded videos, bounded channel activity,
owned playlists and membership, outbound subscriptions, channel-related comments
and complete API-visible replies, and liked videos have independent checkpoints.
Every page reserves one identity plus one list quota unit. Watch history, Watch
Later, saved third-party playlists, and complete authored-comment history remain
explicit unavailable/export-unverified coverage. API metadata carries the current
30-day refresh/delete retention boundary. Details and official evidence:
`.agents/content/social-youtube.md`.

Patreon profiles use `PATREON_<PROFILE>_ACCESS_TOKEN`,
`PATREON_<PROFILE>_CAMPAIGN_IDS`, and `PATREON_<PROFILE>_SCOPES`. Base collection
requires exactly the `identity` and `campaigns` read scopes plus only the optional
stream scope. Membership collection also requires
`PATREON_<PROFILE>_MEMBER_DATA_PURPOSE=membership-services` and a private
`PATREON_<PROFILE>_PII_KEY` of at least 32 bytes. Token issuance and rotation stay
outside the collector, and no Patreon write, webhook, browser, or patron-profile
route is reachable.

## Approval-bound account operations

Outbound account operations are a separate owner-only subsystem; they do not
expand the read-only collector or provider-manifest contract. The authenticated
alias must grant `knowledge.manage`, which encrypted sharing reserves for the
workspace owner. Recipient `knowledge.read` and `knowledge.write` grants never
become posting authority.

Create a draft from a mode-0600 UTF-8 body file, then approve its exact immutable
intent. The connection selects the allowlisted outbound provider; callers cannot
substitute a provider at execution time. Omit `--scheduled-at` for an immediately
due X operation:

```bash
knowledge-social-helper.sh operation-create --alias workspace:example \
  --connection-id CONNECTION_ID --account-id ACCOUNT_ID --action post \
  --body-file approved-post.txt --scheduled-at EPOCH \
  --app PROFILE --username HANDLE

knowledge-social-helper.sh operation-approve --alias workspace:example \
  --operation-id OPERATION_ID --expires-at EPOCH
```

The versioned intent binds the operation ID, connection, stable account ID,
provider, action, target, destination, body and subject digests, local auth/account
selectors, schedule, and creator. Reply uses `--target-id POST_ID` with
`--body-file FILE`; like and bookmark use only `--target-id POST_ID`. Revoke
approval or cancel before a claim with `operation-revoke` or `operation-cancel`.

Reddit uses the same queue. Install PRAW outside the agent session and store one
credential set per named profile as `REDDIT_<PROFILE>_CLIENT_ID`,
`REDDIT_<PROFILE>_CLIENT_SECRET`, `REDDIT_<PROFILE>_USERNAME`,
`REDDIT_<PROFILE>_PASSWORD`, and `REDDIT_<PROFILE>_USER_AGENT`. For example, a
`work` profile creates a self-post with a separately protected one-line subject:

```bash
knowledge-social-helper.sh operation-create --alias workspace:example \
  --connection-id REDDIT_CONNECTION_ID --account-id STABLE_REDDIT_ACCOUNT_ID \
  --action post --destination-id SUBREDDIT_NAME --subject-file subject.txt \
  --body-file approved-post.txt --profile work
```

Reddit reply, like, and bookmark targets use stable `t1_...` comment or `t3_...`
submission fullnames. Like maps to PRAW `upvote()` and bookmark maps to `save()`.
Run the approved operation through the secret execution context so the selected
profile variables exist only in the child environment:

```bash
aidevops secret REDDIT_WORK_CLIENT_ID REDDIT_WORK_CLIENT_SECRET \
  REDDIT_WORK_USERNAME REDDIT_WORK_PASSWORD REDDIT_WORK_USER_AGENT -- \
  knowledge-social-helper.sh operation-run --alias workspace:example \
  --operation-id OPERATION_ID
```

Credential values never belong in command arguments, operation rows, receipts,
or logs.

A private routine may invoke the bounded due runner:

```bash
knowledge-social-helper.sh operations-run-due --alias workspace:example \
  --executor-id EXECUTOR_ID --claim-seconds 300 --limit 10
```

Each runner atomically claims an operation, resolves the stored provider through
the fixed registry, verifies the provider's current identity against the approved
stable account immediately before execution, records a durable provider boundary,
and invokes only mapped `post`, `reply`, `like`, or `bookmark` operations. X uses
the guarded official `xurl` helper; Reddit uses a bounded privacy-safe PRAW child
process. Competing runners cannot create another local attempt. Any timeout,
non-zero exit, malformed receipt, or executor loss after the provider boundary is
`unknown`, never retryable. Resolve it only after external verification:

```bash
knowledge-social-helper.sh operation-reconcile --alias workspace:example \
  --operation-id OPERATION_ID --outcome succeeded --provider-id POST_ID
```

Use `--outcome not-sent` without a provider ID only when verification proves the
write was not accepted. `operations-list` returns bounded, content-free receipt
metadata; it never returns body text, handles, profile names, or raw provider
responses.

## Mention and reply workflow

Notification projection is a mutable local overlay on immutable mention/reply
evidence. Refreshing is idempotent and never resets an existing workflow state:

```bash
knowledge-social-helper.sh notifications-refresh --alias workspace:example
knowledge-social-helper.sh notifications-list --alias workspace:example \
  --status action-required --limit 100
knowledge-social-helper.sh notification-set --alias workspace:example \
  --notification-id NOTIFICATION_ID --status responded
```

Supported states are `unread`, `seen`, `action-required`, `responded`, and
`dismissed`. Listings contain only opaque notification metadata. Drafts,
approvals, attempts, local profile selectors, receipts, and notification workflow
state remain owner-local: shared snapshots neither export nor erase them during a
restore.

## Bounded browser-gap capture

Browser execution remains outside the corpus helper and uses an approved private
profile through the Reach contract. Export only a sanitized mode-0600 JSON
artifact. The importer cannot launch a browser, submit a form, or reuse cookies.

Reach `search_result_observation` records are contemporaneous search evidence,
not account archives and not social browser-gap artifacts. They do not satisfy
an API/archive gap record and cannot be imported as account history. Promotion
requires a separately reviewed knowledge-staging path that preserves the search
observation class and its evidence citation; LLM-derived answers remain separate.

The private gap record identifies `provider`, `stream`, `status` (`partial` or
`unavailable`), `official_routes_exhausted: true`, a sanitized `reason`, and
`observed_at`, and the tested `selector_version`. The capture identifies the same
scope and selector version, opaque connection/account IDs, `read_only: true`,
`checkpoint`, `observed_at`, completion state, and provider-neutral records.

```bash
knowledge-social-helper.sh capture-browser-gap \
  --manifest provider.json --gap gap.json --capture capture.json \
  --max-items 100 --max-bytes 1048576
```

The limits are hard stops. Interrupted captures retain their external checkpoint
and record paused coverage. Replaying the same canonical artifact returns the
same content-addressed batch and does not duplicate objects. Selector drift,
authentication loss, CAPTCHA, or a changed account scope stops that route; it
does not authorize a profile, proxy, or identity change.

## Operator verification

Provider registry routes may be scheduled through the disabled deterministic
`knowledge-collector-routine.sh`. The private source policy owns mode, useful
freshness, minimum and reconciliation intervals, and a runtime budget. Social
arguments still resolve through `provider-run`, so scheduling cannot widen a
provider's supported mode or reach approval-bound outbound operations. Content-
free routine health supplements, but never replaces, atomic provider receipts
and checkpoints.

Before enabling a routine:

1. Confirm the corpus alias resolves only for the authenticated principal.
2. Run API/archive coverage and record the exact remaining stream gap.
3. Validate the provider manifest and dry-run the browser extraction manually.
4. Import one bounded artifact, then replay it to prove idempotency.
5. Inspect coverage, receipts, and citations without printing handles, paths, or
   raw private content.
6. Verify request budgets and terminal rate-limit state remain unchanged by the
   browser route; browser capture never disguises provider API cost.
7. For live collection, verify the selected stable-account identity, each enabled
   stream's independent checkpoint, and honest retention/snapshot coverage.
8. For outbound use, verify exact approval expiry, provider stable-account
   identity, and the private due routine before enabling it.
9. Run corpus, social-store, operation, query, sync, sharing, provider, and
   browser-gap tests.

Shared deployments remain limited to the tested encrypted grant/distribution
contract. Revocation must be verified before cached results are served. Combined
personal/workspace retrieval runs on the authorized user device, and public
diagnostics contain neither private content nor local paths.
