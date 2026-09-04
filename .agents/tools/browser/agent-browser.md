---
description: Agent Browser - headless browser automation CLI for AI agents with Rust CLI and Node.js fallback
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

# Agent Browser - Headless Browser Automation CLI

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Install**: `npm install -g agent-browser && agent-browser install` (Linux: `--with-deps`; iOS: `npm install -g appium && appium driver install xcuitest`)
- **Source**: `git clone https://github.com/vercel-labs/agent-browser && pnpm install && pnpm build && agent-browser install`
- **GitHub**: https://github.com/vercel-labs/agent-browser
- **Architecture**: Rust CLI + Node.js fallback, Playwright daemon (auto-starts, persists)
- **Limitations**: No proxy, no extensions, no Chrome DevTools MCP pairing
- **Performance** (warm): navigate+screenshot 1.9s, form fill 1.4s, reliability 0.6s. Cold-start ~3-5s.
- **iOS** (macOS only): `-p ios --device "iPhone 16 Pro"` — Mobile Safari via Appium
- **License**: Apache-2.0 | TypeScript (74%), Rust (22%)
- **Platform**: macOS/Linux ARM64+x64 (native Rust + Node.js fallback); Windows (Node.js only); iOS (macOS only)

**Core workflow** — use refs from `snapshot -i` for deterministic targeting:

```bash
agent-browser open example.com
agent-browser snapshot -i --json   # ARIA tree with refs: button "Submit" [ref=e2]
agent-browser click @e2            # ref-based (deterministic, no DOM re-query)
agent-browser fill @e3 "value"
agent-browser get text @e1 --json  # {"success":true,"data":...}
agent-browser screenshot page.png && agent-browser close
```

**Snapshot flags**: `-i` interactive-only, `-c` compact, `-d <n>` depth limit, `-s <sel>` scope to selector

<!-- AI-CONTEXT-END -->

## Core Commands

```bash
# Navigate
agent-browser open <url> | back | forward | reload
# Interact
agent-browser click <sel>
agent-browser fill <sel> <text>       # clear+fill
agent-browser type <sel> <text>       # type without clear
agent-browser press <key>             # Enter, Tab, Control+a, etc.
agent-browser select <sel> <val>      # dropdown
agent-browser check/uncheck <sel>
agent-browser scroll <dir> [px]       # up/down/left/right
agent-browser drag <src> <tgt> | upload <sel> <files> | hover <sel>
# Read
agent-browser get text/html/value/title/url <sel>
agent-browser get attr <sel> <attr> | get count/box <sel>
agent-browser is visible/enabled/checked <sel>
# Output
agent-browser screenshot [path] [--full] | pdf <path> | eval <js> | close
```

## Selectors

```bash
agent-browser click @e2                                # Ref (recommended — from snapshot)
agent-browser click "#id" | ".class" | "div > button"  # CSS
agent-browser click "text=Submit" | "xpath=//button"   # Text / XPath
agent-browser find role button click --name "Submit"   # Semantic
agent-browser find text "Sign In" click
agent-browser find label "Email" fill "test@test.com"
agent-browser find first ".item" click | find nth 2 "a" text
```

## Sessions, Wait, Storage, Network

Isolated browser per session (cookies, storage, history, auth). Parallel sessions: `--session s1/s2/s3` (3 parallel tested in 2.0s).

```bash
agent-browser --session agent1 open site-a.com         # named session
AGENT_BROWSER_SESSION=agent1 agent-browser click "#btn" # env var
agent-browser session list
agent-browser wait <selector> | <ms> | --text "Welcome" | --url "**/dash" | --load networkidle
agent-browser wait --fn "window.ready === true"
agent-browser cookies | cookies set <name> <val> | cookies clear
agent-browser storage local [<key>] | storage local set <k> <v> | storage local clear
agent-browser storage session
agent-browser network route <url> [--abort | --body <json>] | network unroute [url]
agent-browser network requests [--filter api]
```

## Tabs, Frames, Dialogs, Settings, Debug

```bash
agent-browser tab | tab new [url] | tab <n> | tab close [n] | window new
agent-browser frame <sel> | frame main
agent-browser dialog accept [text] | dialog dismiss
agent-browser set viewport <w> <h> | device <name> | geo <lat> <lng>
agent-browser set offline [on|off] | headers <json> | credentials <u> <p> | media [dark|light]
agent-browser mouse move <x> <y> | down/up [button] | wheel <dy> [dx]
agent-browser open example.com --headed  # Show browser window (debugging only)
agent-browser trace start/stop [path] | console [--clear] | errors [--clear]
agent-browser highlight <sel> | state save/load <path>
```

## iOS Simulator (macOS only)

Env vars: `AGENT_BROWSER_PROVIDER=ios`, `AGENT_BROWSER_IOS_DEVICE="iPhone 16 Pro"`, `AGENT_BROWSER_IOS_UDID=<udid>`. First launch ~30-60s (simulator boot). Real device: UDID via `xcrun xctrace list devices`, sign WebDriverAgent in Xcode.

```bash
agent-browser device list
agent-browser -p ios --device "iPhone 16 Pro" open https://example.com
agent-browser -p ios snapshot -i | tap @e1 | swipe up/down/left/right [px]
agent-browser -p ios screenshot mobile.png | close
```

## Comparison

| Tool | Interface | Selection | Use for |
|------|-----------|-----------|---------|
| **agent-browser** | CLI | Refs + CSS | CLI-first, multi-session, AI agents, cross-platform |
| dev-browser | TypeScript API | CSS + ARIA | TypeScript projects, stateful pages |
| Playwright Extension | MCP/CLI mode | Playwright tools | Interactive access to approved user-owned Chrome/Edge/Chromium tabs |
| Stagehand | SDK | Natural language | Self-healing, natural language |
| Crawl4AI | — | — | Scraping |

## Common Patterns

```bash
# Login — fill, submit, save auth state
agent-browser open https://app.example.com/login && agent-browser snapshot -i
agent-browser fill @e3 "user@example.com" && agent-browser fill @e4 "password"
agent-browser click @e5 && agent-browser wait --url "**/dashboard" && agent-browser state save auth.json

# Form — fill, select, check, submit
agent-browser open https://example.com/form && agent-browser snapshot -i
agent-browser fill @e1 "John Doe" && agent-browser fill @e2 "john@example.com"
agent-browser select @e3 "US" && agent-browser check @e4 && agent-browser click @e5 && agent-browser wait --text "Success"

# Data extraction
agent-browser open https://example.com/products && agent-browser snapshot --json > products.json

# Multi-session parallel
agent-browser --session s1 open https://site-a.com && agent-browser --session s1 state load auth-a.json
agent-browser --session s2 open https://site-b.com && agent-browser --session s2 state load auth-b.json
```
