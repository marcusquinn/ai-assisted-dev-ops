---
description: Attach to a live Chromium session via local CDP helper or Playwright
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  grep: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Chromium Debug Use

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Reuse an already-open Chrome/Chromium/Brave/Edge/Vivaldi session instead of launching a fresh browser
- **Mechanism**: Start the browser with `--remote-debugging-port=9222`, then attach with the local CDP helper or Playwright CDP
- **Helper**: `.agents/scripts/chromium-debug-use-helper.sh` (Node 22+, raw CDP, no Playwright dependency)
- **Skill entry**: `tools/browser/chromium-debug-use/SKILL.md`
- **Best for**: Logged-in/manual-auth flows, extension-heavy sessions, debugging real state, handoff between manual and scripted work
- **Not for**: Isolated parallel test runs, Firefox/WebKit, or hostile sites where exposed remote debugging is unsafe

**Core rule**: This pattern attaches to a live browser profile. Treat it as stateful and non-isolated. Prefer fresh Playwright contexts for reproducible tests.

<!-- AI-CONTEXT-END -->

## Enable Only for This Investigation

Use this path only when aidevops explicitly needs to inspect or automate your live Chromium-family browser. Do not leave remote debugging enabled as a standing default.

`--remote-debugging-port=9222` grants local processes profile-level access (cookies, local storage, logged-in tabs) until the browser is closed or restarted without the flag.

Security boundaries:

- Bind to loopback only: `http://127.0.0.1:9222`, not a LAN IP.
- Prefer a temporary `--user-data-dir` so investigation state is isolated and easy to discard.
- For interactive selected-tab consent instead of profile-level debugging, use the official Playwright Extension route in `tools/browser/playwright.md` only while the user is available.

## Start a Debuggable Browser

All Chromium-family browsers use the same flags. Use a dedicated profile when possible.

```bash
# Replace <browser-path> with the binary for your browser:
#   Chrome (macOS):    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
#   Brave:             "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
#   Edge:              "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
#   Vivaldi:           "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi"
#   Chromium:          chromium
#   Ungoogled Chromium:"/Applications/Ungoogled Chromium.app/Contents/MacOS/Ungoogled Chromium"
#   Linux:             which google-chrome / which chromium / /opt/...
#   Windows:           where chrome.exe
<browser-path> \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chromium-debug-use-profile
```

Verify the endpoint:

```bash
curl http://127.0.0.1:9222/json/version
```

Use loopback only. Never expose the debug port to untrusted networks.

**Ungoogled Chromium**: if `/json/version` is not exposed, treat that build as unsupported and fall back to standalone Playwright with Brave preferred, another supported CDP browser, or—only for interactive user-owned tabs—the Playwright Extension in Chrome/Edge/Chromium.

## Use the Local Helper

The helper provides a direct CDP command surface without requiring Playwright or Puppeteer.

```bash
# browser version / endpoint sanity check
.agents/scripts/chromium-debug-use-helper.sh version

# list open tabs and target prefixes
.agents/scripts/chromium-debug-use-helper.sh list

# inspect one page
.agents/scripts/chromium-debug-use-helper.sh snapshot <target>
.agents/scripts/chromium-debug-use-helper.sh html <target> main
.agents/scripts/chromium-debug-use-helper.sh eval <target> "document.title"

# interact lightly in the live session
.agents/scripts/chromium-debug-use-helper.sh click <target> "button[type='submit']"
.agents/scripts/chromium-debug-use-helper.sh type <target> "hello world"
.agents/scripts/chromium-debug-use-helper.sh screenshot <target> /tmp/chromium-debug-use.png
```

Notes:

- Commands default to `http://127.0.0.1:9222`, then fall back to browser `DevToolsActivePort` discovery.
- Override with `--browser-url http://127.0.0.1:9333` or `CHROMIUM_DEBUG_USE_BROWSER_URL=...`.
- Uses raw CDP over WebSocket with a per-tab daemon — repeated commands do not reconnect.
- Run `list` first, then use the displayed target prefix for page-specific commands.

## Attach with Playwright

```javascript
import { chromium } from 'playwright';

const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
const context = browser.contexts()[0];
const page = context.pages()[0] ?? await context.newPage();

await page.goto('https://example.com');
console.log({ title: await page.title(), url: page.url() });

await browser.close(); // disconnects; does not close the live browser
```

If an HTTP endpoint is unavailable, read `webSocketDebuggerUrl` from `/json/version` and attach directly:

```javascript
const browser = await chromium.connectOverCDP(
  'ws://127.0.0.1:9222/devtools/browser/<id>'
);
```

## Common Patterns

### Reuse manual login

1. Start Chromium with remote debugging.
2. Complete login or CAPTCHA manually.
3. Attach with Playwright CDP.
4. Continue scripted actions in the same session.

### Inspect existing tabs

```javascript
const pages = browser.contexts().flatMap(ctx => ctx.pages());
for (const page of pages) {
  console.log(page.url());
}
```

### Pair with Chrome DevTools MCP

```bash
npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222
```

Use CDP attachment for automation and DevTools MCP for performance, network, and console inspection against the same live browser.

## Tool Selection

Rule of thumb: inspect and gather facts with `chromium-debug-use`, then formalize the durable workflow with the stronger-purpose browser tool.

| Need | Prefer |
|------|--------|
| Reuse a whole live Chromium profile | Chromium Debug Use (this doc) |
| Interactively approve selected tabs in your everyday browser while you are available | `tools/browser/playwright.md` extension mode |
| Inspection/perf analysis without reusing your active session | `tools/browser/chrome-devtools.md` |
| Persistent local profile managed by aidevops | `tools/browser/dev-browser.md` |
| Fast isolated headed/headless automation / repeatable scripts / CI | `tools/browser/playwright.md` with Brave preferred |
| Natural-language experimentation before locking in selectors | `tools/browser/stagehand.md` |

Chrome/Brave/Edge/Vivaldi require relaunching with the debug flag (profile-level consent). Microsoft's Playwright Extension instead uses connection approval and selected tab groups in Chrome/Edge/Chromium, but only belongs in an interactive user-present session. Both routes are local and user-approved; upstream does not document Brave extension support.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `ECONNREFUSED` on `9222` | Browser was not started with `--remote-debugging-port=9222` |
| No pages found | Open a tab manually or create one with `context.newPage()` |
| Attach works but state is wrong | Wrong profile launched; verify `--user-data-dir` |
| Browser closes unexpectedly | Another tool owns the session or profile lock; use a dedicated debug profile |
| Browser policy blocks remote debugging | Use `tools/browser/playwright.md` extension mode or `tools/browser/chrome-devtools.md --headless` |
| Don't want to relaunch browser | Use `tools/browser/playwright.md` extension mode instead of profile-level CDP attach |
| Ungoogled Chromium never exposes `/json/version` | Treat that build as unsupported; switch to Chrome/Brave/Edge/Vivaldi/Chromium |
| Need repeatable tests | Stop using live-session attach; launch a fresh Playwright context instead |

## Future Scope: Electron and macOS Automation

> **v1 scope boundary**: Everything above describes supported v1 behavior — attaching to Chromium-family browsers launched with `--remote-debugging-port`. This section documents the extension envelope for future work only.

### Electron Apps

Electron embeds Chromium and can expose a CDP endpoint, but there is no universal contract. CDP attachment may work when the app is launched with `--remote-debugging-port=N` and does not strip or conflict with that flag. Support is app-specific: each app controls whether the debug port is exposed; apps with auto-update or code signing may reject modified launch arguments; some apps (VS Code, Figma desktop, Slack) accept the flag in dev builds but block it in production.

**Decision rule:** Verify the target app exposes a working `/json/version` endpoint when launched with the debug flag. If not, this workflow does not apply.

### macOS App and Window Automation

| Layer | Can do | Cannot do |
|-------|--------|-----------|
| AppleScript / `osascript` | Activate apps, bring windows to front, send menu commands, switch tabs in Safari/Chrome | Read DOM state, execute JS, intercept network requests |
| Accessibility API (`AXUIElement`) | Enumerate windows and UI elements for apps that expose the accessibility tree | Access web content inside a `WKWebView` or Electron `BrowserWindow` |

**Decision rule:** Use macOS automation only as a discovery or focus layer before handing off to CDP or Playwright. Do not attempt to replace CDP for any task requiring DOM or JS access.

### Explicit Out-of-Scope for v1

- Safari via CDP (uses WebKit Inspector Protocol, not CDP)
- Firefox (uses its own remote debugging protocol)
- Electron apps without a confirmed working debug port
- macOS Accessibility API for reading web page content
- iOS simulators or real devices (use Maestro or `tools/mobile/`)

## Related

- `tools/browser/browser-automation.md` - browser tool selection
- `tools/browser/playwright.md` - fresh browser automation and CDP usage
- `tools/browser/dev-browser.md` - managed persistent Chromium profile on port 9222
- `tools/browser/chrome-devtools.md` - inspection and performance tooling over the same debug port
