---
description: Playwright CLI - headless browser automation CLI designed for AI agents (Microsoft official)
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

# Playwright CLI - Browser Automation for AI Agents

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Install**: `npm install -g @playwright/cli@latest` (or `bun install -g`)
- **GitHub**: https://github.com/microsoft/playwright-cli
- **Skill**: `/plugin marketplace add microsoft/playwright-cli` then `/plugin install playwright-cli`
- **License**: Apache-2.0

**Core Workflow** (optimal for AI):

```bash
playwright-cli open https://example.com
playwright-cli snapshot                    # Get accessibility tree with refs
playwright-cli click e2                    # Click by ref from snapshot
playwright-cli fill e3 "test@example.com"  # Fill by ref
playwright-cli type "search query"         # Type into focused element
playwright-cli screenshot
playwright-cli close
```

**Key Advantages**: Ref-based selection (deterministic `e1`/`e2`/`e3` targeting from snapshots), `--session` for parallel isolated instances, headless by default (`--headed` for debugging), persistent profiles (cookies/storage preserved), built-in tracing, Microsoft-maintained (`@playwright/cli`).

**Performance**: Navigate+screenshot ~1.9s, form fill ~1.4s (~2s cold start).

**vs agent-browser**: Simpler ref syntax (`e5` vs `@e5`), built-in tracing, Microsoft-maintained. agent-browser has more CLI commands but slower cold start (~3-5s).

**Existing browser mode**: only in an interactive session with the user available, playwright-cli can use Microsoft's Playwright Extension for approved existing tabs; see `tools/browser/playwright.md`. Normal headed/headless work should use a separate browser, with Brave preferred through Playwright direct.

**When to use**: AI agent automation (forms, clicks, navigation), CI/CD pipelines, parallel browser sessions, tasks that don't need existing browser state.

<!-- AI-CONTEXT-END -->

## Installation

```bash
bun install -g @playwright/cli@latest     # Bun (preferred; without global install: bunx @playwright/cli)
npm install -g @playwright/cli@latest     # npm alternative (without global install: npx -y @playwright/cli)
playwright-cli --help                     # Verify
```

## Commands Reference

### Core

```bash
playwright-cli open <url>               # Navigate to URL
playwright-cli close                    # Close the page
playwright-cli type <text>              # Type text into focused/editable element
playwright-cli click <ref> [button]     # Click element (left/right/middle)
playwright-cli dblclick <ref> [button]  # Double-click element
playwright-cli fill <ref> <text>        # Clear and fill input
playwright-cli drag <startRef> <endRef> # Drag and drop between elements
playwright-cli hover <ref>              # Hover over element
playwright-cli select <ref> <value>     # Select dropdown option
playwright-cli upload <file>            # Upload file(s)
playwright-cli check <ref>              # Check checkbox/radio
playwright-cli uncheck <ref>            # Uncheck checkbox
playwright-cli snapshot                 # Get accessibility tree with refs
playwright-cli eval <func> [ref]        # Evaluate JavaScript
playwright-cli dialog-accept [prompt]   # Accept dialog (with optional prompt text)
playwright-cli dialog-dismiss           # Dismiss dialog
playwright-cli resize <width> <height>  # Resize browser window
playwright-cli open <url> --headed      # Show browser window (debugging)
```

### Navigation / Keyboard / Mouse

```bash
playwright-cli go-back                  # Navigate back
playwright-cli go-forward               # Navigate forward
playwright-cli reload                   # Reload page
playwright-cli press <key>              # Press key (Enter, ArrowDown, Tab, etc.)
playwright-cli keydown <key>            # Press key down
playwright-cli keyup <key>              # Release key
playwright-cli mousemove <x> <y>        # Move mouse to position
playwright-cli mousedown [button]       # Press mouse button
playwright-cli mouseup [button]         # Release mouse button
playwright-cli mousewheel <dx> <dy>     # Scroll mouse wheel
```

### Screenshots / PDF / Tabs / DevTools

```bash
playwright-cli screenshot               # Screenshot current page
playwright-cli screenshot <ref>         # Screenshot specific element
playwright-cli pdf                      # Save page as PDF
playwright-cli tab-list                 # List all tabs
playwright-cli tab-new [url]            # Create new tab
playwright-cli tab-close [index]        # Close tab
playwright-cli tab-select <index>       # Switch to tab
playwright-cli console [min-level]      # List console messages
playwright-cli network                  # List network requests
playwright-cli run-code <code>          # Run Playwright code snippet
playwright-cli tracing-start            # Start trace recording
playwright-cli tracing-stop             # Stop trace recording
```

### Sessions

```bash
playwright-cli --session=name open <url>  # Use named session
playwright-cli session-list               # List all sessions
playwright-cli session-stop [name]        # Stop session (keeps profile)
playwright-cli session-stop-all           # Stop all sessions
playwright-cli session-delete [name]      # Delete session + profile data
```

Set session via environment: `PLAYWRIGHT_CLI_SESSION=todo-app claude .`

## Examples

### Form Submission

```bash
playwright-cli open https://example.com/form
playwright-cli snapshot
playwright-cli fill e1 "user@example.com"
playwright-cli fill e2 "$PASSWORD"  # Store credentials in env var or secure vault
playwright-cli click e3
playwright-cli snapshot
```

### Multi-Tab + DevTools

```bash
playwright-cli open https://example.com
playwright-cli tab-new https://example.com/other
playwright-cli tab-list
playwright-cli tab-select 0
playwright-cli snapshot
playwright-cli console                     # Check console messages
playwright-cli network                     # Check network requests
```

### Tracing

```bash
playwright-cli open https://example.com
playwright-cli tracing-start
playwright-cli click e4
playwright-cli fill e7 "test"
playwright-cli tracing-stop
# Opens trace viewer with recorded actions
```

## Comparison with Other Tools

| Feature | playwright-cli | agent-browser | Playwright Extension | Stagehand |
|---------|---------------|---------------|----------------------|-----------|
| **Maintainer** | Microsoft | Vercel | Microsoft | Browserbase |
| **Interface** | CLI | CLI | MCP/CLI mode | SDK |
| **Ref syntax** | `e5` | `@e5` | Playwright refs | Natural language |
| **Sessions** | `--session` | `--session` | Selected existing tabs | Per-instance |
| **Tracing** | Built-in | Via Playwright | Via Playwright | Via Playwright |
| **Headless** | Default | Default | No (existing browser) | Default |
| **Extensions** | No in normal mode | No | Existing browser's extensions | Possible |
| **Cold start** | ~2s | ~3-5s (Rust) | Browser-dependent | ~2s |

## Integration with Other Tools

### Chrome DevTools MCP

playwright-cli exposes a CDP endpoint that Chrome DevTools MCP can connect to:

```bash
playwright-cli open https://example.com --headed
# In another terminal:
npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222
```

Use cases: performance profiling, network monitoring, CSS coverage, console error capture. See `tools/browser/chrome-devtools.md`.

### Anti-Detect Browser Stack

| Stealth Level | Tool | Use Case |
|---------------|------|----------|
| None | playwright-cli (default) | Dev testing, trusted sites |
| Medium | rebrowser-patches + playwright-cli | Hide automation signals |
| High | Camoufox + Playwright API | Bot detection evasion, multi-account |

playwright-cli works with rebrowser-patches automatically if installed in the Playwright browsers directory. For maximum stealth with fingerprint rotation, use Camoufox directly. See `tools/browser/anti-detect-browser.md`.

## Related

- `playwright.md` - Core Playwright automation (cross-browser, forms, security, API testing)
- `playwright-emulation.md` - Device emulation (mobile, tablet, viewport, geolocation, locale, dark mode)
- `browser-automation.md` - Tool selection decision tree
