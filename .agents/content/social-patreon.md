<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Patreon Creator Account Knowledge Collection

Checked 2026-08-02 against Patreon's official developer documentation, creator
portal, export guidance, support material, and legal policies.

## Implemented boundary

`knowledge-social-helper.sh sync-patreon` collects bounded API v2 evidence only
for explicitly selected campaigns owned by the authenticated creator. Patreon
users can be both patrons and creators, so creator status alone is insufficient:
the child verifies `/identity`, fetches the authenticated user's campaigns, and
proves every configured campaign is owned before the first page and before every
later page.

API v1 client creation was restricted and deprecated on 2026-03-25. The collector
uses only the current API v2 root and Python standard-library HTTP; no Patreon
client package is installed or required. Redirects and every method except `GET`
are unreachable.

Configure one lowercase profile with:

- `PATREON_<PROFILE>_ACCESS_TOKEN`;
- `PATREON_<PROFILE>_CAMPAIGN_IDS`, containing 1-20 comma-separated numeric IDs;
- `PATREON_<PROFILE>_SCOPES`, containing `identity campaigns` and only an optional
  stream scope described below.

Token issuance, refresh, and rotation happen outside the collector. A typical
creator-post run is:

```bash
aidevops secret PATREON_CREATOR_ACCESS_TOKEN PATREON_CREATOR_CAMPAIGN_IDS \
  PATREON_CREATOR_SCOPES -- \
  knowledge-social-helper.sh sync-patreon --alias personal:default \
  --connection-id PATREON_CONNECTION_ID --account-id CREATOR_USER_ID \
  --stream posts --profile creator --budget 20 --page-size 100
```

## Streams and permissions

| Stream | API v2 evidence | Additional gate |
|---|---|---|
| `account` | Selected creator role and configured owned campaign IDs | Base `identity campaigns` scopes |
| `campaigns` | Creator-owned campaign metadata | Base scopes |
| `posts` | Campaign posts visible to the creator token | `campaigns.posts` |
| `benefits` | Campaign benefits and related tier metadata | Base scopes |
| `memberships` | Minimized current entitlement and tier state | `campaigns.members`, purpose, and HMAC key |

The exact accepted scope set is `identity`, `campaigns`, `campaigns.posts`, and
`campaigns.members`. Sensitive identity/member email and address scopes, every
write-prefixed scope, duplicate scopes, and unknown scopes fail before a provider
request. The adapter never accesses the authenticated user's patron memberships.

## Membership-purpose and PII gate

Patreon's creator privacy terms limit member data to providing and administering
membership services. The `memberships` stream therefore remains gated unless all
of these are present:

- `campaigns.members` in the selected profile's exact scope list;
- `PATREON_<PROFILE>_MEMBER_DATA_PURPOSE=membership-services`;
- a private `PATREON_<PROFILE>_PII_KEY` containing at least 32 bytes.

The key converts each direct member ID to a provider-local keyed HMAC identifier.
Only current entitlement amount, free-trial/gift state, patron status, pledge
cadence, and entitled tier IDs are accepted. Names, email addresses, postal
addresses, direct member IDs, and unexpected member attributes are rejected and
cannot enter raw or normalized evidence. Membership rows are marked protected
business evidence, not general social relationships.

## Pagination, budgets, and persistence

Patreon documents cursor pagination through `page[count]`, `page[cursor]`, and
`meta.pagination.cursors.next`. Each stream owns an independent checkpoint. The
cursor envelope also carries the selected campaign and a bounded history of
cursor hashes; a repeated cursor fails instead of looping. Multi-campaign streams
advance through only the explicit campaign allowlist.

The documented limits include 100 requests per minute per access token and 100
requests per two seconds per client, with additional edge limits for repeated bad
requests. One invocation is capped at 99 requests and each page is capped at 100
items. `429` evidence preserves a bounded `Retry-After` value and stops without
advancing the checkpoint.

Every successful page stores its request boundary, raw response, normalized rows,
coverage, receipt, and next cursor atomically under the final lease fence. A
malformed, unauthorized, unavailable, rate-limited, looping, or stale-lease page
cannot advance beyond the last coherent checkpoint.

## Explicit gaps

- Patron-owned memberships, subscriptions, followed creators, and patron payment
  history are not collected. `identity.memberships` is deliberately rejected.
- Comments, direct messages, mentions, likes, curation, lives, webhooks, and every
  mutation route have no collector path.
- Current API visibility is not represented as complete historical, deletion, or
  retention coverage.
- Patreon documents creator pledge-data CSV export, but publishes no stable,
  versioned schema and selected-account binding suitable for this importer. No CSV
  or browser route is enabled.
- Member information remains purpose-limited and deletable even though raw fetch
  evidence is content-addressed; local immutability does not override provider
  privacy or legal obligations.

## Official references

- <https://docs.patreon.com>
- <https://www.patreon.com/portal>
- <https://www.patreon.com/portal/how-to/export-pledge-data>
- <https://www.patreon.com/policy/legal>
- <https://support.patreon.com/hc/en-us/articles/360026912432>
