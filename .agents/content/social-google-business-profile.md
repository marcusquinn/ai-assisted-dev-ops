# Google Business Profile knowledge source

`knowledge_social_google_business_profile.py` is an isolated, read-only collector
for one explicitly selected Google Business Profile location. The historical
Google My Business name is an alias only. The collector cannot edit listings,
verify a location, publish or delete posts/media, answer reviews or questions,
send messages, manage bookings, or invoke any other platform mutation.

## Current capability record

Verified against the current service families and REST resource shapes on
2026-07-30. Production enablement must re-check the project's API access and the
resource fields before first use because Business Profile products are approval
gated and have changed independently.

| Evidence | Service and read route | Disposition |
|---|---|---|
| Google identity | Google OAuth user-info `GET /oauth2/v3/userinfo` | Required identity fence; request `openid` and bind the immutable subject locally. Email is neither requested nor persisted. |
| Accounts and organizations | Account Management v1 `GET /accounts/{account}` | Required account fence. An optional organization selector is fetched and matched independently. Account lists are not used for fuzzy discovery. |
| Location identity and profile | Business Information v1 `GET /locations/{location}` with an explicit read mask | Supported: title, description, contacts, categories, address/service area, website, hours, labels, opening state, metadata, relationships, more-hours, and service items. |
| Attributes | Business Information v1 `GET /locations/{location}/attributes` | Supported as an independent snapshot stream. |
| Media | Business Profile v4 `GET /accounts/{account}/locations/{location}/media` | Supported only while the approved project exposes this legacy-version read surface. |
| Local posts/updates | Business Profile v4 `GET /accounts/{account}/locations/{location}/localPosts` | Supported only while the approved project exposes this legacy-version read surface. |
| Reviews and owner replies | Business Profile v4 `GET /accounts/{account}/locations/{location}/reviews` | Supported. Review text and replies are protected customer content. Reviewer profile details are not normalized. |
| Verification/account state | Verifications v1 `GET /locations/{location}/VoiceOfMerchantState` plus Account Management and location metadata | Partial: state is observable; verification actions are deliberately unreachable. |
| Daily performance | Business Profile Performance v1 `GET /locations/{location}:fetchMultiDailyMetricsTimeSeries` | Supported for a bounded trailing window, including impressions, website clicks, call clicks, and direction requests when authorized. Metric date and dimension payloads remain provider provenance. |
| Search keywords | Business Profile Performance v1 `GET /locations/{location}/searchkeywords/impressions/monthly` | Supported for a bounded completed-month window when authorized. |
| Questions and answers | No current selected Business Profile read route | Unavailable coverage, never browser-scraped. |
| Calls | Aggregate `CALL_CLICKS` may be available in performance | Caller identity, call recordings, and call history are unavailable. |
| Bookings, messages, followers | No current general owner-history route selected | Unavailable coverage. Messaging history is not represented by stale/deprecated products. |
| Products | Services may be present in `serviceItems`; no current general product-catalog owner route is selected | Product coverage is unavailable rather than inferred from posts. |
| Historical/deleted data | Current API pages only | Complete history and deleted resources are unavailable. Provider retention and project policy apply. |
| Owner/manager export | No versioned official Business Profile export schema is selected | Export replay is disabled. A future parser requires a documented schema plus exact account/location identity; names and addresses are never merge keys. |

All live routes are hardcoded service-specific GET allowlists. Pagination accepts
only an opaque `nextPageToken`. The adapter uses Python's standard-library HTTP
exports; `googleapiclient` is intentionally not installed or required by the
current dependency lock.

## Private connection profile

Store the OAuth token and selectors in the private aidevops credential profile,
never in a repository. For profile alias `primary`, the guarded subprocess reads:

```text
GOOGLE_BUSINESS_PROFILE_PRIMARY_ACCESS_TOKEN
GOOGLE_BUSINESS_PROFILE_PRIMARY_GOOGLE_SUBJECT
GOOGLE_BUSINESS_PROFILE_PRIMARY_ACCOUNT_ID
GOOGLE_BUSINESS_PROFILE_PRIMARY_ORGANIZATION_ID   # optional
GOOGLE_BUSINESS_PROFILE_PRIMARY_LOCATION_ID
```

The token needs only `openid` and the Business Profile management scope required
by Google's read APIs. API access and project approval are separate from OAuth
consent. Do not broaden scopes to work around a denied API family. Keep the
profile name opaque; diagnostics expose neither selectors, business/customer
text, tokens, nor provider error bodies.

The public `--account-id` argument is the opaque location selector ID, not a
display name or address. Before persistence, the child verifies the Google
subject, exact business account, optional exact organization, and exact location.
It repeats that complete fence immediately before every page. Account and
location IDs are namespaced by the corpus connection; duplicate business names
cannot converge across locations.

## Collection and budgets

Run the provider CLI directly until shared registration lands in the provider
aggregate task:

```bash
python3 .agents/scripts/knowledge_social_google_business_profile.py \
  --alias personal:default \
  --connection-id conn_gbp_primary_location \
  --account-id location_selector \
  --stream reviews \
  --profile primary \
  --budget 11 \
  --page-size 50
```

The budget is a hard logical collection-unit limit: one identity phase plus two
units per persisted provider page. A live identity fence performs three exact
GETs, or four when an organization is configured. A page surrounds its single
stream GET with complete identity fences so hierarchy drift cannot reach the
checkpoint commit. Each HTTP response is capped at 8 MiB, requests time out after
60 seconds, pages cap at 100 items, and child execution is bounded at 120 seconds.
Rate-limit responses preserve the prior page cursor and record a sanitized retry
time. Permission denial, unavailable API family, malformed page, identity drift,
lease loss, timeout, or quota stop cannot advance evidence.

Streams are independent by connection/location/stream lease and cursor:

```text
location_profile attributes media local_posts reviews verification_state
performance search_keywords
```

Run `--status` for local state without a provider call. A successful raw page,
normalized rows, coverage, and cursor commit atomically through the canonical
social evidence contract. Replays converge by provider resource ID; metric
refreshes use the same provider metric identity. No fuzzy business name, address,
review text, keyword, or timestamp matching is allowed.

## Privacy and coverage

Raw pages stay under the private mode-0600 corpus. Review/customer text and owner
replies carry `protected_customer_content:true`; diagnostics return only bounded
counts and failure classes. Performance/search evidence remains tied to its
metric/date/dimension provider payload. Coverage always records Q&A, call
records, bookings, messages, followers, products, owner export, and deleted or
complete historical data as unavailable unless a later independently reviewed
official route replaces that disposition.

Fixtures contain synthetic IDs and text and require no Google credential or API
approval:

```bash
bash .agents/tests/test-knowledge-social-google-business-profile.sh
python3 -m compileall -q \
  .agents/scripts/knowledge_social_google_business_profile.py \
  .agents/scripts/_knowledge_social_google_business_profile*.py
```
