---
description: LinkedIn content creation, posting, and analytics via API
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

# LinkedIn Content Subagent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Publishing API**: Community Management API via OAuth 2.0; vetted access
- **Read collector**: Member Data Portability Member Snapshot API; EEA/Swiss gate
- **Docs**: https://learn.microsoft.com/en-us/linkedin/marketing/
- **Collector**: `knowledge-social-helper.sh sync-linkedin`
- **Auth**: Externally provisioned member OAuth token; never a browser session
- **Related**: [bird.md](bird.md) (X/Twitter), [reddit.md](reddit.md) (Reddit)

**Post types**: Text (3k chars), Article (long-form), Carousel (PDF, 300p), Document (PDF/PPT/DOC, 100MB), Poll (2-4 options, 1-2 wks), Image (up to 9), Video (10 min max)

<!-- AI-CONTEXT-END -->

## API Setup

1. Create app at https://www.linkedin.com/developers/apps
2. Request Community Management API access (requires app review)
3. Configure redirect URI and obtain client ID/secret

```bash
aidevops secret set LINKEDIN_CLIENT_ID
aidevops secret set LINKEDIN_CLIENT_SECRET
aidevops secret set LINKEDIN_ACCESS_TOKEN
```

**Key endpoints**: `GET /v2/userinfo` (profile), `POST /v2/posts` (create), `POST /v2/images?action=initializeUpload` (media), `GET /v2/organizationalEntityShareStatistics` (analytics)

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.linkedin.com/v2/posts" \
  -d '{"author":"urn:li:person:ID","lifecycleState":"PUBLISHED","visibility":"PUBLIC","commentary":"Post text here","distribution":{"feedDistribution":"MAIN_FEED"}}'
```

## Read-only account knowledge

Evidence was revalidated against official documentation on 2026-07-27. The
collector deliberately does not import, invoke, or share credentials with
`linkedin-automation.py`.

### Route decision

- Community Management is a vetted product. Its documented read scopes cover
  administered organizations and member analytics, not a general personal
  history reader. LinkedIn also states that `r_member_social` is closed to new
  access requests. See
  https://learn.microsoft.com/en-us/linkedin/marketing/increasing-access and
  https://learn.microsoft.com/en-us/linkedin/marketing/community-management/community-management-overview.
- Member Data Portability is the verified personal-data route. Third-party apps
  require business verification/review and `r_dma_portability_3rd_party`; only
  EEA members can consent. The member product is available to EEA and Swiss
  members. See
  https://learn.microsoft.com/en-us/linkedin/dma/member-data-portability/member-data-portability-3rd-party/
  and
  https://learn.microsoft.com/en-us/linkedin/dma/member-data-portability/member-data-portability-member/.
- The Member Snapshot endpoint is GET-only, historical, and fixed to LinkedIn
  API version `202312`. Its `total` and paging links can omit data from offline
  systems, so the collector advances `start` after every successful page and
  completes only on the documented `No data found for this memberId` response. See
  https://learn.microsoft.com/en-us/linkedin/dma/member-data-portability/shared/member-snapshot-api.
- The changelog route retains only the preceding 28 days, recommends hourly
  reads, and allows `count` from 1 through 50. It is not used by the first
  collector because snapshots provide the narrower historical route. See
  https://learn.microsoft.com/en-us/linkedin/dma/member-data-portability/shared/member-changelog-api.

The member-product overview names `r_dma_portability_self_serve`, while the
Snapshot API permission table names `r_dma_portability_member`. The collector
does not guess between these official names or implement OAuth provisioning; it
accepts only an already provisioned token and verifies its member authorization
before the first read and again before every page.

### Implemented streams

| Stream | Official snapshot domain | Disposition |
|---|---|---|
| `authored_posts` | `MEMBER_SHARE_INFO` | Live/Gate |
| `authored_articles` | `ARTICLES` | Live/Gate |
| `comments` | `ALL_COMMENTS` | Live/Gate |
| `reactions` | `ALL_LIKES` | Live/Gate |
| `saved_items` | `ACTOR_SAVE_ITEM` | Live/Gate |
| `messages` | `INBOX` | Live/Gate |
| `following` | `MEMBER_FOLLOWING` | Live/Gate |
| `connections` | `CONNECTIONS` | Live/Gate |
| `company_follows` | `COMPANY_FOLLOWS` | Live/Gate |
| `groups` | `GROUPS` | Live/Gate |
| Newsletter subscriptions | None listed | No |

The authoritative domain list is
https://learn.microsoft.com/en-us/linkedin/dma/member-data-portability/shared/snapshot-domain.
The collector stores each successful response as immutable raw evidence. Because
the official domain page does not define each record's field schema, normalized
rows contain only a content-addressed identity and provenance, not guessed or
bulk-copied fields. Credential-shaped keys fail before raw or normalized
persistence.

### Account archive fallback

LinkedIn's account download is a validated export fallback, including Articles,
Comments, Connections, Groups, Member Follows, Messages, Reactions, Saved Items,
Shares, and Company Follows. Specific categories can arrive within 10 minutes;
the larger archive and several activity categories can take up to 48 hours, and
the download remains available for 72 hours. See
https://www.linkedin.com/help/linkedin/answer/a1339364.

No archive importer is exposed yet: the official page documents categories but
not a stable file schema, and no private sample was accepted into git. This is an
explicit Export disposition, not simulated live coverage. The current official
lists do not identify newsletter subscriptions as a snapshot or archive
category.

### Safety and retention

- Store the selected token outside git as
  `LINKEDIN_<PROFILE>_ACCESS_TOKEN`; use `aidevops secret set` rather than a
  plaintext project file.
- Pass the opaque token portion of the authorized member URN as `--account-id`;
  do not use a profile URL slug.
- Member Portability data may be stored with the member's consent and a
  continuing legal basis, and must be deleted on member request or linked
  account closure. See https://www.linkedin.com/legal/l/portability-api-terms.
- Marketing API member social activity has a separate 48-hour storage boundary;
  do not mix Marketing and Portability data. See
  https://learn.microsoft.com/en-us/linkedin/marketing/data-storage-requirements.
- LinkedIn's API terms prohibit scraping, crawling, browser-derived unofficial
  content, and credential proxying. See
  https://www.linkedin.com/legal/l/api-terms-of-use.

```bash
knowledge-social-helper.sh sync-linkedin \
  --connection-id conn_linkedin --account-id MEMBER_ID \
  --stream authored_posts --profile personal --budget 11 --page-size 10
```

Python 3.12.3 and the local `urllib.request` exports (`Request`, `urlopen`) were
verified before implementation; no LinkedIn SDK is installed or imported.

### Approved outbound posts

The outbound queue can prepare an approved text `post` for the selected member
only. It verifies the configured member through `memberAuthorizations` before
the write boundary, then uses the official REST Posts route. This is a
capability-gated route: absent write-product eligibility, token scope, or exact
member binding fails closed before mutation. The queue does not emulate a write
through browser automation, support organization posting, or infer access from
the read-only Member Portability product. Receipts retain only operation and
remote post IDs; post body and authorization values remain private.

## Content Best Practices

**Structure**: Hook (1-2 lines, ~210 chars) → Body (`\n` breaks) → CTA → Hashtags (3-5 at end). Bold/italic via Unicode. Emoji 1-3 per post. Limit: 3k chars.

- **Hashtags**: 3-5 max, mix broad (#Leadership) with niche (#DevOps)
- **Timing**: Tue-Thu, 7-8am / 12pm / 5-6pm, 3-5 posts/week
- **Engagement**: Open with hook/bold statement, end with CTA question
- **Stories**: "I" narratives perform 2-3x better
- **Reply**: Respond within 1h for algorithmic boost
- **Repurposing**: Blog → key points + link; Tweet → expand; Talk → carousel; Docs → how-to + code; Reddit → thought leadership

## Analytics

| Metric | Target | API Field |
|--------|--------|-----------|
| Impressions | Trend | `impressionCount` |
| Engagement | >2% good | `engagementRate` |
| Click-through | >1% links | `clickCount` |
| Shares | High-value | `shareCount` |

## Troubleshooting

| Issue | Solution |
|-------|----------|
| 401 | Token expired; re-auth |
| 403 | Missing scope/approval |
| 429 | Daily limit ~100; backoff |
| Hidden | Check visibility; `PUBLIC` |
| Upload | Register first, then PUT |
