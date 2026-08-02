# Miniflux Account Knowledge Evidence

Checked 2026-08-02 against the official Miniflux API and configuration references.

## Implemented evidence

- `GET /v1/me` returns the current numeric user ID and username. Collection binds
  that identity to a keyed fingerprint of the configured exact HTTPS installation
  and rechecks it before every persisted page.
- Preferred API-key authentication uses the `X-Auth-Token` header. Application API
  keys are mutation-capable, so the provider child constructs only `GET` requests,
  rejects redirects, and allowlists only `/v1/me`, `/v1/entries`, `/v1/feeds`,
  `/v1/categories`, and `/v1/export`.
- `GET /v1/entries` supports `status`, `starred`, ascending `order=id`, `direction`,
  `limit`, `after_entry_id`, and `changed_after`. Initial replay advances by entry
  ID. Incremental runs overlap the persisted changed timestamp by one second so
  equal-boundary updates can replay idempotently.
- Feed and category reads are bounded snapshots. `GET /v1/export` supplies an OPML
  subscription snapshot; partial snapshots never imply deletion.
- Entry records expose current read, removed, starred, and tag state. Dedicated
  streams retain independent checkpoints and neutral activity evidence.
- The current API documents official Go and Python clients, but no Miniflux client
  package is installed in the runtime. The provider therefore uses Python 3.14.3
  standard-library `urllib` exports verified locally.

## Explicit boundaries

- Operator cleanup is configurable: read entries default to archive after 60 days,
  unread entries after 180 days, and `-1` retains all. Current API state cannot
  prove complete pre-retention history.
- Feed/category/OPML snapshots are bounded by request, byte, and item limits and do
  not prove deletion when incomplete.
- No API-key, feed credential, password, or credential-shaped response field may
  enter raw or normalized evidence.
- Mutation routes for imports, feed refresh, entry updates, bookmarks, categories,
  users, and API keys are unreachable.

## Official references

- <https://miniflux.app/docs/api.html>
- <https://miniflux.app/docs/configuration.html>
