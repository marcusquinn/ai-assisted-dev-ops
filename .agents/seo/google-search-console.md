---
description: Google Search Console via MCP (gsc_* tools) with curl fallback
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Google Search Console Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

| | |
|---|---|
| **Access** | MCP `gsc_*` tools (primary), curl + OAuth2 (fallback) |
| **API** | `https://searchconsole.googleapis.com/v1/` |
| **Auth** | `~/.config/aidevops/gsc-credentials.json` (service account, `chmod 600`) |
| **Metrics** | clicks, impressions, ctr, position |
| **Dimensions** | query, page, country, device, searchAppearance |

## Setup

1. Google Cloud Console → enable **Search Console API** → Service Account → JSON key → `~/.config/aidevops/gsc-credentials.json` (`chmod 600`)
2. GSC → Property → Settings → Users → add service account email (or bulk-add via Playwright script below)
3. Verify: `python3 -c "import json; d=json.load(open('$HOME/.config/aidevops/gsc-credentials.json')); print(d['client_email'])"`

## MCP Tools (`gsc_*`)

| Tool | Purpose | Key params |
|------|---------|------------|
| `gsc_list_sites` | List verified properties | — |
| `gsc_search_analytics` | Search performance | `siteUrl`, `startDate`, `endDate`, `dimensions[]`, `rowLimit` |
| `gsc_url_inspection` | URL indexing status | `inspectionUrl`, `siteUrl` |
| `gsc_submit_sitemap` | Submit sitemap | `siteUrl`, `feedpath` |
| `gsc_delete_sitemap` | Remove sitemap | `siteUrl`, `feedpath` |
| `gsc_list_sitemaps` | List sitemaps | `siteUrl` |

**Common patterns**: top queries (`dimensions: ["query"]`, `orderBy: impressions`), page performance (`dimensions: ["page"]`, `orderBy: clicks`), CTR opportunities (`impressions > 100`, `ctr < 0.05`), device/geo breakdown.

### Conversational Query Candidates

- Preserve raw query/page rows, then classify a derived copy with
  `conversational-search-intent.md`; use segmented RE2 discovery patterns from
  `seo-regex.md` rather than one catch-all expression.
- Keep raw rows only in an authorized private evidence location and assign a
  privacy status. Sanitize or aggregate query samples before reports, exports,
  comments, or public artifacts; never expose sensitive query text or paths.
- Prompt-shaped wording is a candidate signal, not proof of AI Mode or another
  answer-engine surface unless the source explicitly supplies that dimension.
- GSC query rows are not conversation sessions. Do not invent antecedents for
  refinements such as “more”, “those”, or “yes, pricing”.
- Keep query, page, date range, country/device where relevant, clicks,
  impressions, CTR, and position attached to each evidence cluster.

## MCP Configuration

> `@anthropic/google-search-console-mcp` is internal/unreleased. If unavailable via npm, use curl fallback or check with aidevops maintainer.

```json
{
  "mcpServers": {
    "google-search-console": {
      "command": "npx",
      "args": ["-y", "@anthropic/google-search-console-mcp"],
      "env": { "GOOGLE_APPLICATION_CREDENTIALS": "~/.config/aidevops/gsc-credentials.json" }
    }
  }
}
```

## curl Fallback

Requires `pip install PyJWT requests`.

```bash
ACCESS_TOKEN=$(python3 -c "
import json, time, jwt, requests
creds = json.load(open('$HOME/.config/aidevops/gsc-credentials.json'))
now = int(time.time())
payload = {'iss': creds['client_email'], 'scope': 'https://www.googleapis.com/auth/webmasters.readonly',
           'aud': creds['token_uri'], 'iat': now, 'exp': now + 3600}
signed = jwt.encode(payload, creds['private_key'], algorithm='RS256')
r = requests.post(creds['token_uri'], data={'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer', 'assertion': signed})
print(r.json()['access_token'])
")

# List sites
curl -s "https://searchconsole.googleapis.com/v1/sites" -H "Authorization: Bearer $ACCESS_TOKEN"

# Search analytics
curl -s -X POST "https://searchconsole.googleapis.com/v1/sites/https%3A%2F%2Fexample.com/searchAnalytics/query" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
  -d '{"startDate": "2025-01-01", "endDate": "2025-01-20", "dimensions": ["query", "page"], "rowLimit": 25}'

# Inspect URL (submit for indexing: indexing.googleapis.com/v3/urlNotifications:publish)
curl -s -X POST "https://searchconsole.googleapis.com/v1/urlInspection/index:inspect" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
  -d '{"inspectionUrl": "https://example.com/page", "siteUrl": "https://example.com"}'
```

## Bulk Property Setup

Adds service account to all GSC properties via Playwright. Requires `npm install playwright`, Chrome logged into Google, Owner access.

```javascript
import { chromium } from 'playwright';
const SERVICE_ACCOUNT = "your-service-account@project.iam.gserviceaccount.com";
// Chrome profile: macOS ~/Library/Application Support/Google/Chrome/Default
//                 Linux ~/.config/google-chrome/Default

async function main() {
    const browser = await chromium.launchPersistentContext(
        '/Users/USERNAME/Library/Application Support/Google/Chrome/Default',
        { headless: false, channel: 'chrome' }
    );
    const page = await browser.newPage();
    await page.goto("https://search.google.com/search-console", { waitUntil: 'networkidle' });
    await page.waitForTimeout(2000);
    const domains = [...new Set([...((await page.content()).matchAll(/sc-domain:([a-z0-9.-]+)/g))].map(m => m[1]))];
    console.log(`Found ${domains.length} properties`);
    for (const domain of domains) {
        try {
            await page.goto(`https://search.google.com/search-console/users?resource_id=sc-domain:${domain}`, { waitUntil: 'networkidle' });
            await page.waitForTimeout(400);
            const content = await page.content();
            if (content.includes("don't have access") || content.includes(SERVICE_ACCOUNT)) continue;
            await page.click('text=ADD USER');
            await page.waitForTimeout(400);
            await page.keyboard.type(SERVICE_ACCOUNT, { delay: 5 });
            await page.keyboard.press('Enter');
            await page.waitForTimeout(1000);
            console.log(`  Added ${domain}`);
        } catch (e) { console.error(`  Error ${domain}: ${e.message}`); }
    }
    await browser.close();
}
main().catch(console.error);
```

## Troubleshooting

- **Empty results `{}`**: Service account not added to any GSC properties — use Playwright script above
- **"No access to property"**: Service account needs Full or Owner role; domain must be verified in GSC
- **Connection issues**: `ls -la ~/.config/aidevops/gsc-credentials.json` · `opencode mcp list`

<!-- AI-CONTEXT-END -->
