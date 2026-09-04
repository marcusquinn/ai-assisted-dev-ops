---
description: Stateful browser automation with persistent Playwright server
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Dev-Browser - Stateful Browser Automation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Stateful browser automation with persistent page state AND browser profile
- **Runtime**: Bun + Playwright (pages survive script executions)
- **Server**: `~/.aidevops/dev-browser/server.sh` (port 9222)
- **Profile**: `~/.aidevops/dev-browser/skills/dev-browser/profiles/browser-data/`
- **Install**: `bash ~/.aidevops/agents/scripts/dev-browser-helper.sh setup`
- **Benchmarks**: 14% faster, 39% cheaper, 43% fewer turns than Playwright MCP
- **Performance**: navigate 1.4s, form fill 1.3s, extraction 1.1s (+-0.02s)
- **Chrome DevTools MCP**: `npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222`

| Use | Don't Use |
|-----|-----------|
| Local dev servers, multi-step workflows | Interactive access to selected tabs from YOUR browser → Playwright Extension |
| Stay logged in across sessions | Parallel isolated sessions → Playwright direct |
| Source code access for selectors | Natural language automation → Stagehand |

<!-- AI-CONTEXT-END -->

## Security

> **Screenshot size limit (session-crashing)**: NEVER use `fullPage: true` for AI vision review — full-page captures can exceed 8000px (Anthropic hard-rejects images >8000px). Use viewport-sized screenshots for AI. For human review: `magick tmp/full.png -resize "1568x1568>" tmp/full-resized.png`. See `reference/screenshot-limits.md`.

## Setup

```bash
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh setup          # Install (Bun + deps)
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start          # Start (reuses profile)
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start-headless # Start headless
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start-clean    # Start with fresh profile
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh status         # Check status
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh profile        # View profile details
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh reset-profile  # Delete all browser data
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh stop           # Stop server
```

## Usage Pattern

Start the server, then execute scripts via `bun x tsx` heredoc. All scripts run from `~/.aidevops/dev-browser/skills/dev-browser`.

**Script template** (every script follows this structure):

```bash
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";
const client = await connect("http://localhost:9222");
const page = await client.page("main");  // pages persist by name

// ... your operations here ...

console.log({ title: await page.title(), url: page.url() });
await client.disconnect();
EOF
```

**Key principles:**

1. **Small scripts**: each does ONE thing
2. **Evaluate state**: always log state at the end
3. **Use page names**: `"main"`, `"checkout"`, `"login"` — pages persist by name across script executions
4. **Disconnect to exit**: `await client.disconnect()` at the end
5. **Plain JS in evaluate**: no TypeScript inside `page.evaluate()`

## Element Discovery

Three approaches (all use the script template above — only the operations block differs):

**ARIA Snapshot** (unknown page structure):

```typescript
const snapshot = await client.getAISnapshot("main");
console.log(snapshot); // returns elements with refs: e1, e2, ...
```

**Interact with snapshot refs:**

```typescript
const element = await client.selectSnapshotRef("main", "e5");
await element.click();
await waitForPageLoad(page);
```

**Source code selectors** (when you have access to the codebase):

```typescript
await page.click('[data-testid="submit-button"]');
await page.fill('input[name="email"]', 'test@example.com');
```

## Common Operations

All examples below show only the operations block — wrap in the script template above.

**Navigate and screenshot:**

```typescript
await page.goto("http://localhost:3000/dashboard");
await waitForPageLoad(page);
await page.screenshot({ path: "tmp/dashboard.png" }); // viewport-sized (safe for AI)
// await page.screenshot({ path: "tmp/full.png", fullPage: true }); // resize before AI vision
```

**Fill form and submit:**

```typescript
await page.fill('input[name="username"]', 'testuser');
await page.fill('input[name="password"]', 'testpass');
await page.click('button[type="submit"]');
await waitForPageLoad(page);
console.log({ url: page.url(), title: await page.title() });
```

**Extract data:**

```typescript
const heading = await page.textContent('h1');
const items = await page.$$eval('.item', els => els.map(e => e.textContent));
console.log({ heading, items });
```

**Multi-page workflow** — use the same page name across separate script executions to maintain session state (cookies, localStorage):

```bash
# Script 1: Login (page name "app")
# ... page = await client.page("app"); await page.goto(".../login"); fill + submit ...

# Script 2: Navigate (same "app" page — still logged in!)
# ... page = await client.page("app"); await page.goto(".../settings"); ...
```

## Custom Browser Engine

Set `BROWSER_EXECUTABLE` before starting:

```bash
# Brave (built-in ad/tracker blocking), Edge (enterprise SSO, Azure AD), or Chrome
BROWSER_EXECUTABLE="/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
  bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start
```

If the server doesn't expose `executablePath`, use Playwright direct with `launchPersistentContext` for persistent profile + custom browser.

**Extensions** (e.g. uBlock Origin): Start headed (`start`, not `start-headless`), install from Chrome Web Store — persists in profile. Alternative: Brave Shields provides equivalent blocking without extensions.

## Comparison with Other Browser Tools

| Feature | Dev-Browser | Chromium Debug Use | Playwright Extension | Playwright MCP | Stagehand |
|---------|-------------|--------------------|----------------------|----------------|-----------|
| **State** | Persistent aidevops profile | Existing live browser profile | Selected existing tabs | Fresh each call | Fresh |
| **Speed** | Fast (batched) | Fast for live-session reuse | Browser-dependent | Slow (round-trips) | Medium |
| **Context** | Low | Very low | Playwright MCP tools | High (17+ tools) | Low |
| **Approach** | Scripts | CDP attach to current browser | MCP/CLI extension mode | Tool calls | Natural language |
| **Best for** | Dev testing and managed persistent automation | Inspect first, then choose the right automation path | Existing sessions with selected-tab consent | Cross-browser | AI automation |
| **Requires** | Bun + server | Debug-enabled Chromium browser | Official extension | Nothing | API key |

Use `chromium-debug-use` when you need to understand a live session that is already open. Switch to dev-browser when that investigation turns into a repeatable workflow that should keep its own persistent state under aidevops control.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Server not running | `dev-browser-helper.sh status` then `start` |
| Port 9222 in use | `lsof -i :9222` then `kill $(lsof -t -i :9222)` then `restart` |
| Bun not found | `curl -fsSL https://bun.sh/install \| bash` then `source ~/.bashrc` |
| Debug current state | Take a screenshot: `await page.screenshot({ path: "tmp/debug.png" })` |

## Resources

- **GitHub**: https://github.com/SawyerHood/dev-browser
- **License**: MIT
