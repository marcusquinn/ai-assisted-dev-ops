---
description: Proxy integration for anti-detect browsers - residential, SOCKS5, VPN, rotation
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Proxy Integration

<!-- AI-CONTEXT-START -->

Network identity guidance for authorized browser profiles. Reach provides the
provider-neutral metadata boundary for residential, ISP, mobile, SOCKS5, VPN,
and direct egress. Provider/runtime adapters remain responsible for activating
the referenced network path and verifying it before capture.

## Canonical Reach Registration

Store a complete provider connection value in approved secret storage, then
register only its name:

```bash
aidevops secret set REACH_PROXY_US_EAST
reach-helper.sh egress register \
  --name public-us-east \
  --browser brave \
  --class residential \
  --scope public \
  --session-mode stable \
  --country US \
  --timezone America/New_York \
  --locale en-US \
  --credential-ref REACH_PROXY_US_EAST \
  --format json
```

Reach stores private metadata only. It does not print the secret-reference name,
activate the proxy/VPN, contact a target, or claim that the configured location
has been verified.

## Proxy Types

| Type | Detection Risk | Speed | Cost | Best For |
|------|---------------|-------|------|----------|
| **Residential** | Very low | Medium | $1-10/GB | Multi-account, social media |
| **ISP/Static** | Low | Fast | $2-5/IP/mo | Persistent accounts |
| **Datacenter** | High | Very fast | $0.5-2/IP/mo | Scraping, non-sensitive |
| **Mobile** | Very low | Slow | $3-20/GB | Highest trust, mobile apps |
| **SOCKS5 VPN** | Low | Fast | $5-10/mo | Privacy, geo-unblocking |

## Credentials

Use `aidevops secret set NAME`. Keep the complete connection value—including
host, port, username, password, and provider modifiers—inside that secret. Do
not pass it as a command argument or commit it to a profile/config file.

## Provider URL Formats

**DataImpulse** — append modifiers to password with `_`:

```text
http://user:pass@gw.dataimpulse.com:823                          # rotating
http://user:pass_session-abc123@gw.dataimpulse.com:823           # sticky
http://user:pass_country-us_city-newyork@gw.dataimpulse.com:823  # geo-targeted
```

**WebShare:**

```text
http://user:pass@p.webshare.io:80           # rotating
http://user-country-us:pass@p.webshare.io:80  # country targeting
```

**BrightData:**

```text
http://user-zone-residential:pass@brd.superproxy.io:22225                  # rotating
http://user-zone-residential-session-abc:pass@brd.superproxy.io:22225      # sticky
http://user-zone-residential-country-us:pass@brd.superproxy.io:22225       # country
```

**SOCKS5 VPN** (IVPN/Mullvad — requires active subscription + WireGuard):

```text
socks5://10.0.0.1:1080              # provider local (same format for both)
socks5://user:pass@host:1080        # generic with auth
```

## Per-Profile Assignment

Use a stable Reach egress profile for an authenticated account. Public
location sampling may use a separately authorized rotating profile. Runtime
adapters should resolve the registered secret only at execution time and pass
the value in process-local environment or standard input, never in logs or CLI
arguments.

## Health Checking

`reach-helper.sh network doctor --format json` reports local, sanitized
readiness without contacting arbitrary targets. A runtime adapter's explicit
connection test may contact a trusted diagnostic endpoint, but transcript-safe
output must contain only boolean health and expected-vs-observed location
matching—not proxy URLs, credentials, IP addresses, session IDs, or private
paths.

DNS leak prevention: Playwright handles automatically; Camoufox uses `network.proxy.socks_remote_dns = true` (default).

## Rotation Strategies

| Strategy | Use Case |
|----------|----------|
| **Fixed** | Persistent accounts |
| **Rotating** | Authorized public location sampling only |
| **Sticky session** | Login flows (same IP for N minutes) |
| **Round-robin** | Load distribution across proxy list |
| **Geo-targeted** | Match profile's target region |
| **Failover** | Switch on error/block |

Authenticated accounts require fixed/sticky egress for the entire session.
Rotation and failover never authorize bypassing blocks, authentication,
authorization, robots, terms, or rate limits.

## Browser Engine Integration

Proxy config structure is identical across engines — only the wrapper differs:

**Playwright (Chromium):**

```javascript
const browser = await chromium.launch({
  proxy: { server: 'http://gw.dataimpulse.com:823', username: 'user', password: 'pass_country-us_session-abc123' }
});
```

**Camoufox (Firefox):**

```python
with Camoufox(headless=True, proxy={"server": "...", "username": "user", "password": "pass_country-us"}, geoip=True) as browser:
    ...  # geoip=True auto-matches timezone/locale to proxy region
```

**Crawl4AI:**

```python
browser_config = BrowserConfig(proxy_config={"server": "...", "username": "user", "password": "pass_country-us"})
```

## Security

- Never commit proxy credentials — use `aidevops secret set NAME`
- Use sticky sessions for login flows (avoid IP changes mid-session)
- Match proxy geo to profile fingerprint (timezone, locale, geolocation)
- Stop on blocks unless a separate, authorized route is already in scope

<!-- AI-CONTEXT-END -->
