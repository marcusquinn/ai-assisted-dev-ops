<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Reach and Capture

Use this registry when an agent needs to choose the lowest-agency way to reach,
capture, stage, or mine web content. Route and doctor commands are advisory:
they report available local primitives and emit a route decision without
contacting arbitrary targets. Profile, cookie, and egress broker commands mutate
only private reach metadata under the aidevops agent workspace.

## Capability Registry

| Capability | Backend key | Agency | Use first when | Local readiness signal | Artifact plane |
|------------|-------------|--------|----------------|------------------------|----------------|
| Fetch/static parse | `fetch` | 1 | Public/static pages, obvious JSON, no login | `curl` or `python3` present | caller-selected |
| Crawl4AI/WaterCrawl crawler | `crawler` | 2 | Many public pages, sitemaps, docs, structured extraction | `crawl4ai-helper.sh`, `watercrawl-helper.sh`, or `site-crawler-helper.sh` | caller-selected |
| Deterministic browser | `browser` | 3 | Known UI flow, forms, downloads, repeatable selectors | `agent-browser-helper.sh`, `browser-qa-helper.sh`, or Playwright tooling | traces/screenshots/downloads |
| Persistent profile | `persistent_profile` | 4 | Recurring logged-in workflows with approved stored state | `dev-browser-helper.sh` or browser profile storage | `browser-profiles` workspace |
| Cookie-session reuse | `cookie_session` | 4 | Authenticated API calls from an existing approved session | `sweet-cookie` tooling or `anti-detect-helper.sh` cookies support | storage state/cookie export |
| Anti-detect profile | `anti_detect_profile` | 6 | Authorized profile or fingerprint isolation need | `anti-detect-helper.sh` | profile workspace |
| Proxy/VPN | `proxy_vpn` | 6 | Authorized geo, isolation, or reputation separation need | `anti-detect-helper.sh proxy` support or VPN/proxy helper | proxy metadata |
| `_inbox` capture | `inbox_capture` | storage | Human-visible capture, triage, or later processing | `inbox-helper.sh` | `_inbox` |
| `_knowledge` staging | `knowledge_staging` | storage | Durable reusable knowledge or indexed research | `knowledge-helper.sh` | `_knowledge` |
| `_performance` logging | `performance_logging` | telemetry | Repeatable workflow measurement | `performance`/metrics helpers when present | `_performance` |
| `_feedback` mining | `feedback_mining` | telemetry | Mine prior failures, reviews, comments, or outcomes | feedback/quality helpers when present | `_feedback` |

## Route Decision Schema

`reach-helper.sh route --format json` returns one JSON object with this shape:

```json
{
  "backend": "fetch|crawler|browser|persistent_profile|cookie_session|anti_detect_profile|manual_review",
  "agency_level": 1,
  "mode": "static|crawl|deterministic_browser|profile|cookie_session|authorized_stealth|manual",
  "headed": false,
  "profile_policy": "none|avoid|use_existing_approved_profile|required|blocked",
  "cookie_policy": "none|avoid|reuse_approved_session|required|blocked",
  "proxy_policy": "none|avoid|authorized_only|required|blocked",
  "budgets": {
    "max_iterations": 3,
    "max_tool_calls": 12,
    "max_token_estimate": 6000,
    "stop_after_repeated_success": 2,
    "stop_on_permanent_failure": true,
    "route_decision_ttl_seconds": 86400
  },
  "efficiency_policy": ["prefer API/fetch", "prefer DOM/text over screenshots", "reuse leases", "reuse route decisions within TTL"],
  "offload": "local|worker|manual",
  "offload_reason": "sanitized reason",
  "routine_candidate": false,
  "compute_notes": ["sanitized compute constraints"],
  "capture_destination": "caller_selected|_inbox|_knowledge|_performance|_feedback",
  "audit_refs": {
    "todo_id": "",
    "issue_ref": "",
    "pr_ref": "",
    "capture_ref": "",
    "performance_ref": "",
    "feedback_ref": "",
    "route_decision_id": "reach-route-..."
  },
  "failure_policy": "sanitized retry and stop policy",
  "failover_order": ["fetch", "crawler", "browser"],
  "safety_notes": ["sanitized notes only"],
  "expected_artifacts": ["sanitized artifact kinds only"],
  "blocked_reason": ""
}
```

Routing follows `.agents/workflows/auto-browse.md`: fetch/static parse first,
then crawler, deterministic browser, persistent profile or cookie reuse for
approved authenticated work, and anti-detect/proxy only for explicit authorized
isolation needs. Private/manual authentication without an approved reusable
session returns `manual_review` with `blocked_reason` set instead of attempting
capture.

Route budgets are hard discovery defaults for repeatable work: stop after the
configured iteration/tool/token estimate, after repeated success without material
improvement, or immediately on permanent failures such as authorization, scope,
payment, posting, destructive action, or missing manual consent gates. Efficiency
policy is explicit in every route: prefer API/fetch before browser, prefer text
and DOM extraction over screenshots, reuse approved profile/cookie leases, and
reuse a prior route decision within the TTL when objective, auth, and scope still
match.

Headed/headless selection is conservative. Public static fetches and public
crawls are headless. Login, MFA, manual consent, CAPTCHA, payment, posting,
form-submit, and destructive actions are headed/manual-gated. Stable recurring
public captures can graduate to a headless worker/routine after the route is
sanitized and repeated success is recorded.

Offload decisions distinguish compute cost from trust boundary. Short public
fetches stay local; long crawls and recurring public captures may offload to a
worker/routine. Sensitive profile, cookie, credential, or private-scope work does
not offload unless a private workspace and credential references are explicitly
available. Audit refs link TODO tasks, GitHub issues/PRs, capture artifacts,
performance records, feedback themes, and the deterministic `route_decision_id`.

`reach-helper.sh watch --once --dry-run --format json` and
`reach-routine.sh --format json` are report-only by default. They do not create
issues, write comments, mutate cookies/profiles, contact targets, or promote
captures; use them as safe periodic preflight hooks before scheduling recurring
reach/capture work.

`route --auth cookie|profile` consults the private broker metadata before it
sets `cookie_policy` or `profile_policy`. Missing or expired broker state keeps
the policy at `required`; an unexpired cookie registration or profile lease
allows `reuse_approved_session` or `use_existing_approved_profile`.

## Profile and Cookie Broker

`reach-helper.sh profile lease|release|status --format json` and
`reach-helper.sh cookie status|register|clear --format json` manage private
lease metadata only. The broker does not import cookies, launch browsers, or
touch the underlying profile directory.

Private state is stored under:

```text
~/.aidevops/.agent-workspace/reach/
├── .observation-id-key # private keyed-ID material, mode 600
├── leases/             # profile lease metadata, mode 600 JSON files
├── cookie-sessions/    # cookie source metadata, mode 600 JSON files
├── egress-profiles/    # location/egress metadata, mode 600 JSON files
└── observations/
    ├── evidence/       # immutable SHA-256-addressed evidence, mode 600
    └── records/        # private search-observation records, mode 600 JSON
```

Profile lease files contain these fields: `schema_version`, `target_key`,
`profile_name`, `profile_type`, `auth_mode`, `cookie_source`, `owner`,
`created_at`, `expires_at`, `sensitivity`, and sanitized `notes`. Cookie session
metadata stores the private source path locally plus a safe label/hash for
output. `profile lease` refuses to overwrite an unexpired lease unless `--force`
is present, so parallel workers do not silently reuse or mutate the same approved
session state.

Safe logging rules:

- Command output may include target hashes, profile names, profile types, safe
  labels, expiry timestamps, and boolean status fields.
- Command output must not include cookie values, bearer tokens, proxy
  credentials, private paths, raw private target strings, or browser profile
  state paths.
- Cookie source paths may exist only inside private metadata files in the reach
  workspace; issue, PR, and transcript output uses the safe label/hash instead.

## Location and Egress Profiles

`reach-helper.sh egress register|status|clear --format json` defines private,
provider-neutral location profiles without contacting a target or activating a
VPN/proxy. A registration binds a supported browser class, egress class,
location/locale, usage scope, session mode, and optional aidevops secret name.
It never accepts a raw proxy URL as `--credential-ref` and never prints the
secret-reference name.

```bash
aidevops secret set REACH_PROXY_US_EAST
reach-helper.sh egress register \
  --name account-us-east \
  --browser brave \
  --class residential \
  --scope account \
  --session-mode stable \
  --country US \
  --region NY \
  --city "New York" \
  --timezone America/New_York \
  --locale en-US \
  --credential-ref REACH_PROXY_US_EAST \
  --format json
```

Supported egress classes are `direct`, `vpn`, `socks5`, `residential`, `isp`,
and `mobile`. Supported browser classes are `brave`, `chromium`, `edge`,
`chrome`, `firefox`, and `mullvad`; Brave is the default. Proxy-backed classes
require a credential reference. Direct profiles reject one. VPN profiles may
omit one when the tunnel is managed outside Reach.

Use `--scope account` only with `--session-mode stable`; the broker rejects
rotating account profiles. Public observations may declare rotating egress, but
only to sample an authorized location pool—not to evade blocks, access controls,
robots, terms, or rate limits. Region and city are stored privately but status
output exposes only whether they are configured. Runtime adapters must resolve
credential references through approved secret storage and must verify actual
egress separately before claiming a location.

## Search-result Observations

`reach-helper.sh observation record --input <private-json> --format json`
validates and privately records evidence captured elsewhere. The command does
not launch a browser, call a search API, activate an egress profile, or contact a
target. Input follows
`.agents/schemas/reach-search-observation-v1.schema.json`; both the mode-0600
input and referenced mode-0600 evidence file must already exist.

```json
{
  "schema_version": 1,
  "evidence_class": "search_result_observation",
  "engine": "brave",
  "collection_method": "browser",
  "query": "private query",
  "observed_at": "2026-08-05T12:00:00Z",
  "egress_profile": "public-us-east",
  "device_class": "desktop",
  "signed_in": false,
  "authorization_basis": "public_data",
  "result_surface": "web",
  "evidence_path": "private-result.html",
  "evidence_media_type": "text/html"
}
```

The recorder accepts Brave, Google, and Bing browser observations. `search_api`
currently supports Brave only and requires `storage_authorization_basis` set to
`personal_use`, `provider_terms`, or `provider_permission`. This field records
the operator's storage assertion; Reach does not independently verify provider
terms or permissions. Browser observations reject the API-only field. Evidence
is limited to 25 MiB and `application/json`, `text/html`, or `text/plain`; JSON
containing common credential-shaped fields fails closed.

Signed-in observations require `owned_account` or `client_approved` authority,
browser collection, and a stable account-scoped egress profile. Output includes
an opaque, workspace-keyed observation ID, evidence digest, engine, country, and
safe environment classes, but never the query, source path, exact city/region,
secret reference, keyed-ID material, or copied evidence path. Egress remains
`configured_unverified` until a future runtime adapter independently verifies
the actual connection.

Search-result observations are contemporaneous evidence, not reconstructed
history. They remain separate from Google/Microsoft account exports and from
LLM-derived answers; the recorder rejects alternate evidence classes. Replay is
idempotent, and promotion into `_knowledge` requires the normal reviewed staging
path rather than treating the Reach record as authoritative account history.

## Health Doctors

`reach-helper.sh network doctor --format json` reports sanitized proxy/VPN
readiness. It may expose provider class, check keys, boolean availability, and
generic status values. It must not print IP addresses, proxy credentials,
session IDs, cookies, private target strings, or local private paths.

`reach-helper.sh fingerprint doctor --format json` reports sanitized browser and
fingerprint/profile readiness. Profile types follow the anti-detect browser
decision tree: persistent, clean, warm, or disposable. Doctor output is local
readiness only and does not contact arbitrary targets.

## Failure Classes and Failover

`reach-helper.sh classify-failure --format json` emits:

- `failure_class`: one of `success`, `network_timeout`, `proxy_unhealthy`,
  `rate_limited`, `captcha_required`, `bot_block`, `auth_required`,
  `scope_forbidden`, `selector_drift`, `content_empty`, or `unknown`.
- `temporary`: whether backoff or a route change may plausibly succeed.
- `retry_after_seconds`: conservative minimum wait before retrying.
- `next_action`: sanitized action guidance.
- `safe_to_failover`: whether an authorized alternate route may be used.
- `requires_authorization`: whether new approval/session/scope is required.
- `notes`: sanitized operational constraints.

Failover is safe only for temporary classes such as `network_timeout`,
`proxy_unhealthy`, `rate_limited`, `captcha_required`, `bot_block`, and
`content_empty`, and only within the existing authorization boundary. Do not
retry the same blocked identity after `bot_block`; switch only to a healthy,
authorized profile/proxy or stop. `selector_drift` requires extraction repair,
not identity failover. `auth_required` and `scope_forbidden` are hard stops:
never recommend proxy, VPN, fingerprint, cookie, or profile failover without new
authorization for that scope.

## Safety Boundaries

- Do not contact arbitrary targets during `doctor` or `capabilities` checks.
- Do not print credentials, cookie values, proxy auth, local private paths, or
  raw private target strings in route output.
- Do not pass raw proxy URLs to Reach egress commands. Store the complete value
  with `aidevops secret set NAME` and register only `--credential-ref NAME`.
- Keep authenticated account sessions on a stable, location-consistent egress
  profile. Rotation is limited to authorized public observations.
- Keep account exports, search-result observations, and LLM-derived answers in
  separate evidence classes; none may masquerade as another.
- Do not use proxy, VPN, fingerprint, profile, or cookie changes to bypass
  authentication, authorization, robots, rate-limit, or terms boundaries.
- Treat proxy, inbox, knowledge, performance, and feedback mutation as follow-up
  work with separate task briefs and verification. Profile and cookie broker
  mutation is limited to private metadata leases and registrations.
