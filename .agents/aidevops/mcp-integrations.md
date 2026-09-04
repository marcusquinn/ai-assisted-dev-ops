---
description: Advanced MCP integrations for AI DevOps
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Advanced MCP Integrations for AI DevOps

<!-- AI-CONTEXT-START -->

## Quick Reference

**Setup All**: `bash .agents/scripts/setup-mcp-integrations.sh all`
**Generate Templates**: `bash .agents/scripts/setup-mcp-integrations.sh templates`
**Help**: `bash .agents/scripts/setup-mcp-integrations.sh --help`
**Validate**: `bash .agents/scripts/validate-mcp-integrations.sh`

| Category | Integration | Key Requirement |
|----------|-------------|-----------------|
| Browser & Web | Chrome DevTools MCP | `npx chrome-devtools-mcp@latest` |
| | Playwright MCP | `npx -y @playwright/mcp@0.0.79 --headless --isolated` |
| | Cloudflare Browser Rendering | Server-side scraping (account ID + API token) |
| SEO & Research | Ahrefs MCP | `AHREFS_API_KEY` (passed as `API_KEY` via wrapper) |
| | Perplexity MCP | `PERPLEXITY_API_KEY` |
| | Google Search Console | `GOOGLE_APPLICATION_CREDENTIALS` (service account JSON) |
| Document Processing | Unstract MCP | `UNSTRACT_API_KEY` + `API_BASE_URL` (Docker, self-hosted default) |
| Mobile Testing | iOS Simulator MCP | macOS + Xcode + Facebook IDB |
| Development | Claude Code MCP | Forked server (`github:marcusquinn/claude-code-mcp`) |
| | Next.js DevTools MCP | |
| | Context7 MCP | Real-time library docs |
| | LocalWP MCP | WordPress database access |
| | Cloudflare Code Mode MCP | OAuth via `mcp.cloudflare.com` |
| | MCPorter | Discover, call, compose, generate CLIs for MCP servers |
| | OpenAPI Search MCP | Remote Cloudflare Worker, no auth |
| Media Generation | Higgsfield MCP | Browser OAuth state + request-bound refresh proxy |

**Config Location**: `configs/mcp-templates/` beneath the aidevops repository or deployed `~/.aidevops/` root, independent of the caller's working directory.

**Security**: MCP servers are a trust boundary -- they access conversation context, credentials, and network. Verify source, scan dependencies (`npx @socketsecurity/cli npm info <pkg>`), and scan source (`skill-scanner scan /path`) before installing. See `tools/mcp-toolkit/mcporter.md` "Security Considerations".

<!-- AI-CONTEXT-END -->

## Setup Commands

### Chrome DevTools MCP

```bash
claude mcp add chrome-devtools npx chrome-devtools-mcp@latest
# VS Code: code --add-mcp '{"name":"chrome-devtools","command":"npx","args":["chrome-devtools-mcp@latest"]}'
```

Full options (headless, viewport, logging):

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["chrome-devtools-mcp@latest", "--channel=canary", "--headless=true", "--isolated=true", "--viewport=1920x1080", "--logFile=/tmp/chrome-mcp.log"]
    }
  }
}
```

### Playwright MCP

```bash
npx -y playwright@latest install
claude mcp add playwright -- npx -y @playwright/mcp@0.0.79 --headless --isolated
```

The portable config above launches a separate isolated bundled browser because
static cross-platform client configs cannot safely encode an OS-specific Brave
path. Managed OpenCode and Browser QA automatically prefer installed Brave;
other clients should append `--executable-path <brave-path>` for headed or
headless work. Only during an interactive session with an available user, store
`PLAYWRIGHT_MCP_EXTENSION_TOKEN` with `aidevops secret`, explicitly request
extension mode, and add `--extension` to the MCP command.
Never place the token in MCP config or command arguments. See
`tools/browser/playwright.md`.

### iOS Simulator MCP

```bash
# Prerequisites: macOS, Xcode with iOS simulators, Facebook IDB
brew tap facebook/fb && brew install idb-companion
claude mcp add ios-simulator npx ios-simulator-mcp
```

**Tools**: `ui_tap`, `ui_swipe`, `ui_type`, `ui_view`, `screenshot`, `record_video`, `ui_describe_all`, `install_app`, `launch_app`, `get_booted_sim_id`.

**Env vars**: `IOS_SIMULATOR_MCP_DEFAULT_OUTPUT_DIR`, `IOS_SIMULATOR_MCP_FILTERED_TOOLS`, `IOS_SIMULATOR_MCP_IDB_PATH`.

Per-agent enablement: `tools/mobile/ios-simulator-mcp.md` (disabled globally, enabled on-demand).

### Claude Code MCP (Fork)

```bash
claude mcp add claude-code-mcp "npx -y github:marcusquinn/claude-code-mcp"
```

**One-time setup**: run `claude --dangerously-skip-permissions` and accept prompts.
**Upstream**: https://github.com/steipete/claude-code-mcp (revert if merged).

### MCPorter

```bash
npx mcporter list          # Zero-install
pnpm add mcporter          # Project dependency
brew tap steipete/tap && brew install steipete/tap/mcporter
```

**Core commands**: `list` (discover), `call` (invoke), `generate-cli` (mint CLIs), `emit-ts` (typed clients), `auth` (OAuth), `daemon` (keep warm).

Auto-imports configs from Claude Code, Claude Desktop, Cursor, Codex, Windsurf, OpenCode, VS Code.

See `tools/mcp-toolkit/mcporter.md` for full documentation.

### OpenAPI Search MCP

No installation -- remote Cloudflare Worker, no auth required.

```bash
# Claude Code
claude mcp add --scope user openapi-search --transport http https://openapi-mcp.openapisearch.com/mcp
```

Config for other runtimes (OpenCode uses `~/.config/opencode/opencode.json`; Claude Desktop uses platform-specific `claude_desktop_config.json`):

```json
{
  "openapi-search": {
    "type": "remote",
    "url": "https://openapi-mcp.openapisearch.com/mcp"
  }
}
```

**Tools**: `searchAPIs` (3000+ public APIs), `getAPIOverview`, `getOperationDetails`. Workflow: search -> overview -> details (minimal context usage).

Per-agent enablement: `tools/context/openapi-search.md` (disabled globally, enabled on-demand).

### Higgsfield MCP

Higgsfield's hosted MCP endpoint uses OAuth with the `openid`, `email`, and
`offline_access` scopes. The tracked local proxy preserves the existing schema
compatibility fixes while refreshing an expired access token at the request
boundary. It refreshes before known expiry, or once after an authentication
rejection, and then retries the original MCP request once.

```json
{
  "higgsfield": {
    "type": "local",
    "command": ["node", "/absolute/home/path/.aidevops/agents/scripts/higgsfield-mcp-proxy.mjs"],
    "enabled": false
  }
}
```

The default OAuth state path is
`~/.config/aidevops/higgsfield-mcp-proxy/state.json`. Set the absolute
`HIGGSFIELD_MCP_STATE_PATH` only when migrating an existing connector state.
Use the absolute proxy path printed by the setup command because MCP command
arrays do not consistently expand `~` or `${HOME}` across clients.
Complete initial browser authorization before starting the proxy. A missing,
revoked, or invalid refresh token fails closed with reauthorization guidance;
token values are never logged.

Run `bash .agents/scripts/setup-mcp-integrations.sh higgsfield` for setup details
and `node --test .agents/scripts/tests/test-higgsfield-mcp-proxy.mjs` for the
credential-free lifecycle checks.

### Cloudflare Code Mode MCP

No installation -- remote server, OAuth-authenticated. First connection opens browser OAuth flow to `dash.cloudflare.com`; token stored automatically.

```json
{ "cloudflare-api": { "url": "https://mcp.cloudflare.com/mcp" } }
```

For OpenCode, use `"type": "remote"` wrapper in `~/.config/opencode/config.json`.

**Tools**: Workers (deploy/update/tail), D1 (SQL), KV (get/put/delete/list), R2 (objects/buckets), Pages (projects/deployments), AI Gateway (logs/analytics), DNS, zone analytics.

Per-agent enablement: `tools/api/cloudflare-mcp.md` (disabled globally, enabled on-demand).

### Cloudflare Browser Rendering

```json
{
  "mcpServers": {
    "cloudflare-browser": {
      "command": "npx",
      "args": ["cloudflare-browser-rendering-mcp@latest", "--account-id=your_account_id", "--api-token=your_api_token"]
    }
  }
}
```

### Ahrefs MCP

```bash
# Store in ~/.config/aidevops/credentials.sh:
export AHREFS_API_KEY="your_40_char_api_key"
claude mcp add ahrefs npx @ahrefs/mcp@latest
```

**Important**: Package expects `API_KEY` env var, not `AHREFS_API_KEY`. Use bash wrapper for OpenCode (env blocks don't expand variables):

```json
{
  "ahrefs": {
    "type": "local",
    "command": ["/bin/bash", "-c", "API_KEY=$AHREFS_API_KEY /opt/homebrew/bin/npx -y @ahrefs/mcp@latest"],
    "enabled": true
  }
}
```

### Perplexity MCP

```bash
export PERPLEXITY_API_KEY="your_api_key_here"
claude mcp add perplexity npx perplexity-mcp@latest
```

### Google Search Console MCP

```bash
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"
claude mcp add google-search-console npx mcp-server-gsc@latest
```

### FluentCRM MCP

Not published to npm -- requires local build:

```bash
mkdir -p ~/.local/share/mcp-servers
cd ~/.local/share/mcp-servers
git clone https://github.com/netflyapp/fluentcrm-mcp-server.git
cd fluentcrm-mcp-server && npm install && npm run build

# Store in ~/.config/aidevops/credentials.sh:
export FLUENTCRM_API_URL="https://your-domain.com/wp-json/fluent-crm/v2"
export FLUENTCRM_API_USERNAME="your_username"
export FLUENTCRM_API_PASSWORD="your_application_password"
```

OpenCode config (bash wrapper, disabled globally):

```json
{
  "fluentcrm": {
    "type": "local",
    "command": ["/bin/bash", "-c", "source ~/.config/aidevops/credentials.sh && node ~/.local/share/mcp-servers/fluentcrm-mcp-server/dist/fluentcrm-mcp-server.js"],
    "enabled": false
  }
}
```

Per-agent enablement: `services/crm/fluentcrm.md`. Tools: Contacts, Tags, Lists, Campaigns, Email Templates, Automations, Webhooks, Smart Links, Dashboard Stats.

### Unstract MCP

```bash
# Self-hosted (recommended): unstract-helper.sh install
# Or cloud: https://unstract.com/start-for-free/
# Store in ~/.config/aidevops/credentials.sh:
export UNSTRACT_API_KEY="your_api_key_here"
export API_BASE_URL="http://backend.unstract.localhost/deployment/api/your-id/"
```

OpenCode config (Docker, disabled globally):

```json
{
  "unstract": {
    "type": "local",
    "command": ["/bin/bash", "-c", "source ~/.config/aidevops/credentials.sh && docker run -i --rm -v /tmp:/tmp -e UNSTRACT_API_KEY -e API_BASE_URL -e DISABLE_TELEMETRY=true unstract/mcp-server:${UNSTRACT_IMAGE_TAG:-latest} unstract"],
    "enabled": false
  }
}
```

**Tool**: `unstract_tool` -- submits files, polls for completion, returns structured JSON. Set `UNSTRACT_IMAGE_TAG` to pin version.

Per-agent enablement: `services/document-processing/unstract.md`.

## Resources

- [Setup Script](.agents/scripts/setup-mcp-integrations.sh) | [Validation Script](.agents/scripts/validate-mcp-integrations.sh) | [Config Templates](configs/mcp-templates/)
- [Chrome DevTools Guide](.agents/tools/browser/chrome-devtools.md) | [Playwright Guide](.agents/tools/browser/playwright.md) | [Chromium Debug Use Guide](.agents/tools/browser/chromium-debug-use.md)
- [Troubleshooting](.agents/aidevops/mcp-troubleshooting.md)
