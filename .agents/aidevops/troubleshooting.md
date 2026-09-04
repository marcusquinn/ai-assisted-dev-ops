---
description: Troubleshooting guide for common issues
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Troubleshooting Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

**Before reporting a bug**: Check service status pages first.

| Service | Status URL |
|---------|-----------|
| GitHub | https://www.githubstatus.com/ |
| GitLab | https://status.gitlab.com/ |
| Cloudflare | https://www.cloudflarestatus.com/ |
| Hetzner | https://status.hetzner.com/ |
| Hostinger | https://status.hostinger.com/ |
| SonarCloud | https://sonarcloudstatus.io/ |
| Codacy | https://status.codacy.com/ |
| Snyk | https://status.snyk.io/ |

**MCP quick fixes**: Chrome DevTools → install Chrome Canary, fix permissions. Playwright → `npx playwright install`. API auth → verify keys with curl, check env vars. Debug → `DEBUG=chrome-devtools-mcp npx chrome-devtools-mcp@latest`. Diagnostics → `bash .agents/scripts/collect-mcp-diagnostics.sh`. Use exponential backoff for transient failures.

<!-- AI-CONTEXT-END -->

## Chrome DevTools MCP

**Chrome not launching:**

```bash
brew install --cask google-chrome-canary
# or: npx chrome-devtools-mcp@latest --channel=stable
```

**Permission denied:**

```bash
sudo chown -R $(whoami) ~/.cache/puppeteer
chmod +x ~/.cache/puppeteer/*/chrome-*/chrome
```

**Headless mode:** `npx chrome-devtools-mcp@latest --headless=true --no-sandbox`

**Performance args** (add to MCP config):

```json
["--disable-dev-shm-usage", "--disable-gpu", "--disable-background-timer-throttling",
 "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding"]
```

## Playwright MCP

**Browsers not installed:**

```bash
npx playwright install          # all browsers
npx playwright install chromium # specific browser
```

**Launch timeout:** `npx -y @playwright/mcp@0.0.79 --timeout-navigation 60000 --no-sandbox`

**WebKit on Linux:** `npx playwright install-deps webkit`

**"No clients are currently connected":** only for intentional interactive
user-browser access, install Playwright Extension, save
`PLAYWRIGHT_MCP_EXTENSION_TOKEN` with `aidevops secret`, set
`PLAYWRIGHT_MCP_EXTENSION=1`, and ensure the MCP command includes `--extension`.
Never place the token in MCP config or command arguments. See
`tools/browser/playwright.md`.

**Performance args:**

```json
["--disable-dev-shm-usage", "--disable-gpu", "--no-first-run", "--no-default-browser-check"]
```

## API-Based MCP Issues

### Ahrefs "connection closed"

Three causes:

1. **Wrong API key type** — JWT-style tokens (long, with dots) don't work. Use the ~40-char key from https://ahrefs.com/api. Verify: `echo $AHREFS_API_KEY | wc -c` (should be ~40-45).
2. **Wrong env var name** — `@ahrefs/mcp` expects `API_KEY`, not `AHREFS_API_KEY`. Pass explicitly.
3. **OpenCode env blocks don't expand variables** — `"API_KEY": "${AHREFS_API_KEY}"` is literal. Use a bash wrapper:

```json
{
  "ahrefs": {
    "type": "local",
    "command": ["/bin/bash", "-c", "API_KEY=$AHREFS_API_KEY /opt/homebrew/bin/npx -y @ahrefs/mcp@latest"],
    "enabled": true
  }
}
```

**Verify key:** `curl -H "Authorization: Bearer $AHREFS_API_KEY" https://apiv2.ahrefs.com/v2/subscription_info`

### Perplexity rate limiting

```bash
export PERPLEXITY_RATE_LIMIT="10"  # requests per minute
```

### Cloudflare API errors

```bash
export CLOUDFLARE_ACCOUNT_ID="your_account_id"
export CLOUDFLARE_API_TOKEN="your_api_token"
curl -X GET "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"
```

## Debugging

**1. MCP server status:**

```bash
npx chrome-devtools-mcp@latest --test-connection
tail -f /tmp/chrome-mcp.log
```

**2. Validate configuration:**

```bash
python -m json.tool configs/mcp-templates/complete-mcp-config.json
npx chrome-devtools-mcp@latest --config-test
```

**3. Network connectivity:**

```bash
curl -I https://api.ahrefs.com
curl -I https://api.perplexity.ai
curl -I https://api.cloudflare.com
```

**4. Check env vars:**

```bash
[ -n "$AHREFS_API_KEY" ] && echo "AHREFS_API_KEY set (${#AHREFS_API_KEY} chars)" || echo "AHREFS_API_KEY not set"
[ -n "$PERPLEXITY_API_KEY" ] && echo "PERPLEXITY_API_KEY set (${#PERPLEXITY_API_KEY} chars)" || echo "PERPLEXITY_API_KEY not set"
[ -n "$CLOUDFLARE_ACCOUNT_ID" ] && echo "CLOUDFLARE_ACCOUNT_ID set (${#CLOUDFLARE_ACCOUNT_ID} chars)" || echo "CLOUDFLARE_ACCOUNT_ID not set"
[ -n "$CLOUDFLARE_API_TOKEN" ] && echo "CLOUDFLARE_API_TOKEN set (${#CLOUDFLARE_API_TOKEN} chars)" || echo "CLOUDFLARE_API_TOKEN not set"
```

**5. Test MCP config changes** (OpenCode TUI requires restart for `opencode.json` changes):

```bash
opencode run "List available tools from dataforseo_*" --agent SEO
opencode run "Call serper_google_search with query 'test'" --agent SEO 2>&1
```

Workflow: edit `~/.config/opencode/opencode.json` → test with `opencode run` → restart TUI if working → update `generate-opencode-agents.sh` to persist.

Helper: `~/.aidevops/agents/scripts/opencode-test-helper.sh test-mcp dataforseo SEO`

## Monitoring & Logging

**Debug logging:**

```bash
DEBUG=chrome-devtools-mcp npx chrome-devtools-mcp@latest
DEBUG=pw:api npx -y @playwright/mcp@0.0.79
```

**Log locations:** Chrome DevTools: `/tmp/chrome-mcp.log` | Playwright MCP: runtime stderr (no default log file) | API MCPs: `~/.mcp/logs/`

## Recovery Procedures

**Reset MCP configuration:**

```bash
cp ~/.config/mcp/config.json ~/.config/mcp/config.json.backup
rm ~/.config/mcp/config.json
bash .agents/scripts/setup-mcp-integrations.sh all
```

**Clear cache and reinstall browsers:**

```bash
rm -rf ~/.cache/puppeteer ~/.cache/playwright
npx playwright install --force
```

**Emergency fallback:**

```bash
npx chrome-devtools-mcp@latest --safe-mode
npx -y @playwright/mcp@0.0.79 --headless --isolated
```

## Diagnostics & Support

**Collect diagnostics:**

```bash
bash .agents/scripts/collect-mcp-diagnostics.sh
# creates: mcp-diagnostics-$(date +%Y%m%d).tar.gz
```

**Resources:** [MCP GitHub Discussions](https://github.com/modelcontextprotocol/discussions) | [Chrome DevTools MCP Issues](https://github.com/chromedevtools/chrome-devtools-mcp/issues) | [Playwright Community](https://playwright.dev/community)

**Vendor support:** [Ahrefs](mailto:support@ahrefs.com) | [Cloudflare](https://support.cloudflare.com/) | [Perplexity](https://docs.perplexity.ai/)
