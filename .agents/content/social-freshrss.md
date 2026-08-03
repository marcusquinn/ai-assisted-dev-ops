# FreshRSS Account Knowledge Evidence

Checked 2026-08-02 against the official FreshRSS Google Reader, Fever, OPML,
mobile-access documentation, and current upstream API source. The worker runtime
provides Python 3.12.3 standard-library HTTP, JSON, SQLite, and HTML parsing; no
third-party FreshRSS client is installed or required.

## Implemented evidence

- Profiles bind an exact credential-free HTTPS FreshRSS root to a keyed local
  installation fingerprint. `POST /api/greader.php/accounts/ClientLogin` sends
  the dedicated API username/password as form data, retains the returned
  `Auth` value only inside the guarded child, and is the sole reachable POST.
- `GET /api/greader.php/reader/api/0/user-info` verifies that `userId`,
  `userName`, and `userProfileId` all match the selected case-sensitive
  username. The installation fingerprint plus current API identity forms the
  durable account binding and is rechecked before every data page.
- Subscription and folder/tag snapshots use exact `subscription/list` and
  `tag/list` GET routes. Built-in state streams are not mislabeled as user tags.
  Partial snapshots never imply remote deletion.
- Items use the reading-list stream with bounded `n`, oldest-first `r=o`, opaque
  `continuation`, bounded-window digest cycle detection, and a one-second `ot`
  overlap after initial exhaustion. Unread
  uses the documented read-state exclusion; starred uses the exact starred-state
  stream. State is derived from item categories without inventing an explicit
  unread category.
- Authenticated OPML uses the exact `subscription/export` GET route. Strict XML
  parsing is byte/item/depth/node bounded, rejects declarations that can define
  entities, and
  preserves only safe feed metadata and folder ancestry. FreshRSS cURL extension
  attributes and credential-shaped URL path, query, or fragment data cannot
  enter evidence.
- Seven streams (`items`, `unread`, `starred`, `subscriptions`, `folders`,
  `tags`, and `opml`) own independent continuation/snapshot checkpoints. Login,
  identity, and data reads spend explicit request units; generic social leases
  fence each atomic raw-evidence, normalized-row, coverage, receipt, and
  checkpoint commit.
- Invocation budgets are capped at 20 HTTP request units: one initial identity
  verification plus at most six login/identity/data page groups. Combined with
  the 1,000-item page cap and 8 MiB response cap, one invocation can process at
  most 6,000 records before a resumable bounded stop.

## Fever fallback boundary

FreshRSS documents Fever as the less capable fallback, with at most 50 items per
`since_id`/`max_id` request. Current Fever authentication requires `api_key` in
the body of every POST, and the same endpoint accepts mutation fields. That
conflicts with this collector's verified invariant that only ClientLogin may
POST and every data route must GET. Fever therefore remains fallback-only
evidence, not a live adapter route; it must not be silently selected when a
Google Reader read fails. A future implementation needs a provider-supported
GET/session authentication boundary or a separately reviewed contract.

## Explicit boundaries

- The dedicated API password is mutation-capable. Modification tokens,
  subscription edits, tag edits, mark-all-read actions, imports, and Fever write
  fields are unreachable by exact route, query, body, and HTTP-method allowlists.
- Operator retention and the current database state bound available history.
  API completion proves only the requested window, not pre-retention state or a
  complete account archive.
- OPML is an independent subscription snapshot, not proof of item, state, or
  deletion completeness. Hidden feeds can differ between API and OPML views.
- Redirects are never followed and their bodies and locations are discarded;
  sanitized terminal status may persist without advancing the prior checkpoint.
  Cross-installation targets, malformed continuations, oversized pages,
  credential-shaped data, and identity mismatch fail before page persistence.

## Official references

- <https://freshrss.github.io/FreshRSS/en/developers/06_GoogleReader_API.html>
- <https://freshrss.github.io/FreshRSS/en/developers/06_Fever_API.html>
- <https://freshrss.github.io/FreshRSS/en/developers/OPML.html>
- <https://freshrss.github.io/FreshRSS/en/users/06_Mobile_access.html>
- <https://github.com/FreshRSS/FreshRSS/blob/edge/p/api/greader.php>
- <https://github.com/FreshRSS/FreshRSS/blob/edge/p/api/fever.php>
