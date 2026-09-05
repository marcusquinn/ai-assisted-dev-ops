<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Optional GitHub webhook onboarding

**Outbound-only polling is the default and remains a complete operating mode.**
No public server, domain, VPN, tunnel, or webhook secret is required to use
aidevops. Offer this guide during GitHub onboarding or when someone asks for
faster event handling or further API optimisation; do not silently provision it.
A missing webhook secret means this optional integration is not configured, not
that the core installation is broken.

Webhooks provide authenticated invalidations and targeted PR wake hints. They do
not replace GitHub reads at action boundaries, grant merge authority, or guarantee
fewer requests. Leave polling and its cadence unchanged, even after setup. See
[transport and freshness](github-api-transport.md) and the
[efficiency benchmark](github-api-efficiency.md) before claiming savings.

## 1. Choose an ingress route

GitHub must reach a stable **public HTTPS** endpoint. A private NetBird address,
an Access-protected browser page, or a healthy local listener alone is not enough.

| Route | Choose when | Cost and operating responsibility |
|-------|-------------|-----------------------------------|
| No webhook | Outbound-only simplicity is preferred | Existing polling; no ingress to operate |
| Cloudflare Tunnel | You have a Cloudflare-managed domain and an always-on receiver host | Tunnel is available on all plans; domain, host, current plan limits, and Cloudflare dependency still matter |
| NetBird native Reverse Proxy | You already operate a compatible proxy cluster and accept its beta status | Verify current plan/feature access; self-hosting adds DNS, TLS, upgrades, and public proxy operation |
| Public VPS gateway over NetBird | You want your own public edge, including with Cloudron-hosted NetBird management | VPS, domain, TLS, proxy updates, mesh policy, monitoring, and backups are yours |

**Cloudflare Zero Trust is a product suite; Cloudflare Tunnel is the connector.**
Access SSO is a separate authentication layer. Neither installing a private VPN
nor enabling Zero Trust automatically publishes a GitHub-compatible endpoint.

Before any live setup, confirm repository-admin authority, ingress ownership,
the specific host/domain, any billing, and approval to expose this route. Review
[public launch](../workflows/public-launch-checklist.md) and
[preflight](../workflows/preflight.md). Do not expose the worker shell, dashboard,
management API, or other local services alongside the receiver.

## 2. Prepare the receiver locally

Use an always-on machine with an installed aidevops runtime, Python 3, authenticated
GitHub CLI, and the existing managed-repository/Pulse configuration. Run as that
same dedicated user, not root. The receiver can trigger the existing merge
pipeline: start with a repository whose automation policy you understand.

1. Generate a high-entropy secret in your password manager. Store it locally via
   the interactive prompt; never put its value in chat, command arguments, Git,
   logs, or a URL:

   ```bash
   aidevops secret set GITHUB_WEBHOOK_SECRET
   ~/.aidevops/agents/scripts/pulse-merge-webhook-receiver.sh --check
   ```

2. The same value will go in repository **Settings → Webhooks → Secret**. This is
   **not** an Actions secret and does not replace `gh auth login`. The receiver
   resolves the named environment variable, the private
   `~/.config/aidevops/credentials.sh` fallback (mode `600`), or
   `gopass` at `aidevops/GITHUB_WEBHOOK_SECRET`. Verify non-interactive secret access
   under the service user too. A successful shell check does not prove a locked
   password store will work after reboot.
3. Read `~/.aidevops/agents/configs/webhook-receiver.conf`. Defaults are
   `127.0.0.1:9301`, `POST /webhook`, and a 1 MiB body limit. Keep loopback for a
   same-host Cloudflare connector. Use service environment overrides rather than
   editing the deployed config, which updates can replace.
4. Start the receiver in a dedicated terminal:

   ```bash
   ~/.aidevops/agents/scripts/pulse-merge-webhook-receiver.sh run
   ```

5. In another terminal, request local `/health` on port `9301` with an HTTP client;
   expect `200` and `ok`. This proves the listener, not external delivery. Do not
   launch a second receiver if the port is already owned by its service.

The log defaults to `~/.aidevops/logs/pulse-merge-webhook.log`. Preserve its private
delivery ledger across restarts; do not delete it to force redelivery. One receiver
uses one shared HMAC key. Attach only repositories within the same trust boundary.
Use isolated receiver instances, ports, secret variables, and state for separate
customers or security boundaries.

## 3A. Cloudflare Tunnel

Use the current [Cloudflare setup walkthrough](https://developers.cloudflare.com/tunnel/setup/).
UI labels below were checked on 2026-09-05; older dashboards may put tunnels under
Zero Trust → Networks → Connectors rather than Networking → Tunnels.

1. Ensure you control a domain on Cloudflare and can create its DNS records.
   Select **Networking → Tunnels → Create Tunnel**, name it for this receiver,
   and select the receiver host's OS and architecture under **Setup Environment**.
2. Install `cloudflared` using the dashboard's **Install and Run** instructions
   on the receiver host. Treat the connector token as a secret; run token-bearing
   setup only in a private local terminal, avoid saved shell history, and never
   paste the command into chat. Select **Continue** after it connects and verify
   **Healthy** status. Restricted egress must allow Cloudflare tunnel connections
   on port `7844` (UDP for QUIC or TCP for HTTP/2), plus required DNS/HTTPS traffic.
3. Under the tunnel's **Routes → Add route → Published application**, select a
   dedicated subdomain of your domain. Set service type **HTTP** and service
   address **127.0.0.1:9301**. A Docker connector's loopback is its own container,
   not the host: prefer same-host native installation for this walkthrough.
4. Limit routing to the exact `/webhook` path where supported (the ingress path
   regex is `^/webhook$`). Retain a catch-all `http_status:404`; if the UI cannot
   restrict the path, add a hostname-scoped edge rule blocking other paths and
   non-POST methods. Keep `/health` private. Save the route and verify the
   generated DNS record and public TLS certificate.
5. Do **not** put an Access login, CAPTCHA, or browser challenge on this endpoint.
   GitHub repository webhooks do not offer an arbitrary static-header field for
   an Access service token. Use the receiver's HMAC validation. Scope any needed
   challenge exception narrowly to this hostname/path; do not disable protection
   across the zone. Preserve request bodies and GitHub signature/event headers.
6. Copy the actual public hostname from your configuration and append `/webhook`
   for GitHub's Payload URL. No secret or query string belongs in that URL.
   Continue at section 4.

Do not use a random quick-tunnel address as durable production configuration.
Cloudflare terminates public TLS and can see webhook payloads, including private
repository metadata; assess that data-processing boundary before opting in.

## 3B. NetBird native Reverse Proxy (optional beta)

A mesh connects enrolled devices privately. Native Reverse Proxy adds a separate
public ingress service; GitHub is not an enrolled mesh peer. See the
[overview](https://docs.netbird.io/manage/reverse-proxy) and
[authentication guide](https://docs.netbird.io/manage/reverse-proxy/authentication).

1. Confirm **Services** permission (Network Admin or higher) and a working proxy
   cluster. For self-hosted installations, follow
   [Enable Reverse Proxy](https://docs.netbird.io/selfhosted/migration/enable-reverse-proxy):
   deploy the documented `netbirdio/reverse-proxy` component, configure its private
   proxy token, and point the proxy domain/wildcard DNS at its public server.
   Default ACME `tls-alpn-01` requires public port `443` with ALPN/TLS passthrough;
   `http-01` instead requires public port `80`. Follow the selected release's
   configuration, not an old copied Compose file.
2. For an external front proxy, the current
   [supported integration](https://docs.netbird.io/selfhosted/external-reverse-proxy)
   for native ingress is Traefik. Nginx/Caddy management-server templates do not
   prove compatibility with this feature. Cloudron's package does not provide it;
   use section 3C or Cloudflare Tunnel instead.
3. Enrol the receiver host. Since the proxy connects to its mesh address, restart
   the receiver with `WEBHOOK_LISTEN_HOST` set to that host's actual NetBird IPv4
   address, not `127.0.0.1` or `0.0.0.0`. Persist this override in its service.
   Restrict mesh policy and the host firewall to the proxy's intended access to
   TCP `9301`; do not grant the mesh general worker/admin access.
4. In **Reverse Proxy → Services → Add Service**, choose **HTTP**, the intended
   domain/subdomain, and the receiver **peer/resource** target, HTTP port `9301`.
   Configure exact `/webhook` routing without stripping or rewriting the path.
   If necessary, add a narrowly scoped filtering proxy to keep other paths private.
5. In **Authentication**, leave additional proxy authentication disabled and
   deliberately confirm the public-access warning. The application is still
   authenticated by GitHub HMAC. Do not enable NetBird-Only Access, SSO, password,
   PIN, or static Header Auth for this GitHub route. NetBird's static header feature
   strips the matching header: **never configure `X-Hub-Signature-256` as static
   proxy authentication**; its value changes with every payload and must reach
   the receiver unchanged.
6. Save, wait for the service to become active, verify DNS/TLS externally, and
   copy its actual public endpoint with `/webhook` into section 4. Any source-IP
   restrictions must admit GitHub's current delivery ranges and have an update
   owner; a fixed guessed range or geographic block can silently lose events.

The proxy operator can read the payload where public TLS terminates. Check current
[self-hosted/cloud feature and licence terms](https://docs.netbird.io/about-netbird/self-hosted-vs-cloud):
self-hosting does not make every enterprise feature free. The reviewed sources
do not establish a paid gate specifically for native Reverse Proxy; verify the
chosen deployment rather than inventing one.

## 3C. Public VPS gateway over NetBird, including Cloudron deployments

This is an ordinary HTTPS reverse proxy using NetBird for backend transport,
**not NetBird's native Reverse Proxy feature**. It can therefore use Caddy or
nginx without the native feature's Traefik requirement.

1. Keep NetBird management where it already runs. The
   [Cloudron NetBird package](https://github.com/marcusquinn/cloudron-netbird-app)
   supports the core mesh but explicitly excludes native reverse proxy because
   Cloudron terminates TLS with nginx. Do not change Cloudron's managed nginx,
   firewall rules, or install an unmanaged proxy alongside it.
2. Provision a **separate** public gateway VPS after approval; choose a compatible
   host using [OS selection](os-selection.md). Install an ordinary maintained
   reverse proxy and enrol this gateway and the receiver into the same NetBird
   management instance. Limit gateway administration to approved operators.
3. Set the receiver's `WEBHOOK_LISTEN_HOST` override to its NetBird IPv4 address.
   Allow only gateway → receiver TCP `9301` in mesh policy and host firewall.
   Verify backend reachability from the gateway; ensure an unrelated mesh peer
   cannot connect. A broad existing allow-all policy overrides the intent of a
   new narrow rule, so inspect the effective policy.
4. Point a dedicated public DNS hostname to the gateway. Configure automated TLS
   renewal and expose public `443` (and `80` if required for ACME). Keep backend
   `9301` closed on public interfaces. Configure the following proxy contract:

   | Setting | Required value |
   |---------|----------------|
   | Public route | Exact `POST /webhook` on the dedicated hostname |
   | Upstream | Receiver's NetBird IPv4 address, HTTP port `9301` |
   | Other paths/methods | Reject; do not publish `/health` or management routes |
   | Request forwarding | Original body bytes, valid Content-Length, unchanged `/webhook` path |
   | Headers | Preserve `X-Hub-Signature-256`, `X-GitHub-Event`, `X-GitHub-Delivery`, and JSON content type |
   | Body limit | At most the receiver's default 1 MiB; do not truncate bodies |
   | Responses | Pass upstream status through; no caching, login redirects, or fake `200` |
   | Logs | No body/secret/header dumps; restrict access and configure rotation |

5. Validate the proxy configuration before reload, verify its certificate and
   renewal, and continue at section 4. A gateway with a local receiver can instead
   forward to loopback without a mesh hop; that is a different exposure boundary
   and should not be confused with reaching a private worker.

Cloudron controls the **management-plane placement** here, not public webhook
delivery. Installing its NetBird app alone does not finish ingress setup.

## 4. Configure GitHub and verify actual delivery

Follow [GitHub's repository webhook UI](https://docs.github.com/en/webhooks/using-webhooks/creating-webhooks).
Use only repositories you administer and intend to connect to this receiver.

1. Open repository **Settings → Webhooks → Add webhook**.
2. Set **Payload URL** to your actual public HTTPS endpoint ending in `/webhook`
   (no trailing slash or query string), **Content type** to `application/json`,
   and **Secret** to the same password-manager value stored in section 2. Keep
   SSL verification enabled. Select **Let me select individual events**.
3. Match the deployed receiver's `WEBHOOK_HANDLED_EVENTS` rather than selecting
   every event. The current defaults are:

   ```text
   check_run, check_suite, status, workflow_run,
   issues, issue_comment, pull_request, pull_request_review,
   pull_request_review_comment, pull_request_review_thread
   ```

   UI names include Check runs/suites, Statuses, Workflow runs, Issues, Issue
   comments, Pull requests, Pull request reviews/comments/threads. Select only
   events offered by the webhook type and your permissions. A repository hook
   does not acquire GitHub App-only coverage by naming an event; record gaps and
   keep polling. Repeat for each intended repository, avoiding duplicate hooks.
4. Select **Active → Add webhook**. Under **Recent Deliveries**, inspect `ping`.
   A correctly signed ping returns **204** with the current receiver: it is an
   authenticated but unhandled event. This is success, not a merge test.
5. Generate an approved, harmless event in the intended test repository (for
   example, a comment on an existing test issue). A handled valid delivery returns
   **200**. Correlate its delivery ID with the receiver log and expected narrow
   invalidation/wake. Do not create a live merge opportunity merely to test ingress.
6. Send an unsigned nonempty JSON POST to the exact public endpoint from an
   external HTTP client, without credentials. Expect **401** from the receiver
   (or an intentional edge denial), never a success. Public unrelated paths must
   be denied. A browser GET of `/webhook` returning `404` is normal.
7. Restart the receiver/connector under their chosen service accounts and repeat
   a new signed event. Confirm polling still runs when ingress is temporarily
   stopped. GitHub does not automatically redeliver failed deliveries; use its
   Recent Deliveries controls after repairing an outage, with polling as backstop.

| Symptom | Check |
|---------|-------|
| DNS/TLS failure or `502` | Hostname, certificate, connector, listener bind, backend route/mesh ACL |
| Redirect, login HTML, CAPTCHA, or `403` | Access/SSO/challenge or source restrictions; narrow the exception |
| `401` at receiver | Missing/mismatched secret or changed body/stripped signature |
| `404` on POST | Exact `/webhook`, hostname route, no path stripping/query/trailing slash |
| `413` | Empty body or receiver size limit; do not silently raise the limit |
| `200 duplicate` | Delivery already recorded; expected replay suppression, not a new dispatch |
| `204` but no wake | Ping/unhandled event; check selected events and test a handled one |
| `200` but no merge | Receipt is not action success; inspect invalidation, queue, and normal eligibility gates |

## 5. Keep it running, or roll it back

After foreground verification, use a user-owned launchd service (macOS), systemd
user service (Linux), or an appropriate supervisor for the selected OS. Run the
same receiver command with its absolute path, a private HOME/state directory, the
bind override if needed, and restart-on-failure. Keep secrets out of service
definitions and verify their secure resolution after login/reboot. Use the
platform's service tooling for `cloudflared`/NetBird/proxy as appropriate. Configure
log rotation and monitor real deliveries, not only `/health`. Sleep/offline hosts
lose the event fast path; do not promise an always-on service on a sleeping laptop.

Rollback: uncheck **Active** on this GitHub webhook, stop only its receiver and
connector/proxy route, then remove only its dedicated DNS/ingress configuration
after confirming it is unused elsewhere. Keep shared tunnels, mesh management,
and other services intact. Rotate a compromised secret in both places; preserve
delivery state. Polling never needed disabling and remains the normal fallback.

Report separately: local check, public TLS/routing, signed handled delivery,
unsigned rejection, restart persistence, and polling fallback. If infrastructure
was not configured, say **documentation prepared; deployment unverified**, not
“webhooks enabled” or “API savings achieved”.
