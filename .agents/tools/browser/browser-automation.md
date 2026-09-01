---
description: Browser automation tool selection and usage guide
mode: subagent
tools:
  read: true
  bash: true
  grep: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Browser Automation - Tool Selection Guide

<!-- AI-CONTEXT-START -->

## Decision Tree

Prefer: fastest tool → ARIA snapshots over screenshots (50-200 tokens vs ~1K) → headless over headed → CLI for AI agents. Playwriter is always headed (attaches to your browser). If bundled Chromium hits bot protection or launch instability, retry with Brave via Playwright/CDP before declaring browser automation unavailable.

For repeatable browser operations or web data mining that should learn, optimize,
persist profile state, or graduate into reusable private workflows, start with
`/auto-browse` and `auto-browse.md`; it orchestrates the tools below rather than
replacing them.

```text
EXTRACT?
  Web search + crawl → WaterCrawl | Bulk CSS/XPath → Crawl4AI | One-off authenticated → curl-copy
  Need login first → Playwright/dev-browser then extract | Unknown structure → Crawl4AI LLM / Stagehand

AUTOMATE?
  Password manager/extensions:
    Already unlocked → Playwriter | Unlock once → dev-browser | Programmatic → Playwright + Bitwarden CLI
  Live already-open Chromium/Chrome session:
    Inspect current state / understand workflow first → chromium-debug-use
    Flow understood, need repeatable automation → Playwright / dev-browser / Playwriter / Stagehand
  Parallel sessions: speed → Playwright | CLI → playwright-cli/agent-browser --session
  Persistent login: with extensions → dev-browser | without → playwright-cli/storageState
  Proxy: direct → Playwright/Crawl4AI | via extension → Playwriter
  Self-healing/unknown structure → Stagehand (NL, slowest)
  AI agent CLI-first → playwright-cli (Microsoft) or agent-browser (Vercel, Rust)
  Just fast → Playwright direct (0.9s form fill)

EXTENSION UI QA?
  chrome://extensions or arbitrary installed user extension → Stop before browser actions; unsupported by Playwriter
  Project-owned unpacked extension with existing runner → Headed Chromium persistent-context runner → extension-dev/testing.md
  No existing extension runner → Manual verification; do not create one or launch a replacement profile

DEBUG/INSPECT → Chrome DevTools MCP (dev-browser :9222 or any Playwright instance)

ANTI-DETECT?
  Quick stealth: Chromium → stealth-patches.md | Firefox → fingerprint-profiles.md
  Full stack → anti-detect-browser.md | Multi-account → browser-profiles.md | Proxy/geo → proxy-integration.md

TEST your app?
  QA pipeline → browser-qa-helper.sh | Mobile E2E → Maestro | Device emulation → playwright-emulation.md
  CI/CD → playwright-cli, agent-browser, or Playwright
```

## AI Page Understanding (ARIA preferred)

```javascript
const aria = await page.locator('body').ariaSnapshot();          // ~0.01s, 50-200 tokens
const text = await page.evaluate(() => document.body.innerText); // ~0.002s, text length
const elements = await page.evaluate(() =>
  [...document.querySelectorAll('input, select, button, a')].map(el => ({
    tag: el.tagName.toLowerCase(), type: el.type, name: el.name || el.id,
    text: el.textContent?.trim().substring(0, 50),
  }))
);
```

## Benchmarks (2026-01-24, macOS ARM64, headless, warm daemon — reproduce: `browser-benchmark.md`)

Overhead: dev-browser +0.1-0.4s | agent-browser +0.5-1.5s (cold) | Stagehand +1-5s (AI) | Playwriter +1-2s (CDP).

| Test | Playwright | dev-browser | agent-browser | Crawl4AI | Playwriter | Stagehand |
|------|-----------|-------------|---------------|----------|------------|-----------|
| Navigate + Screenshot | **1.43s** | 1.39s | 1.90s | 2.78s | 2.95s | 7.72s |
| Form Fill (4 fields) | **0.90s** | 1.34s | 1.37s | N/A | 2.24s | 2.58s |
| Data Extract (5 items) | 1.33s | **1.08s** | 1.53s | 2.53s | 2.68s | 3.48s |
| Multi-step (click+nav) | **1.49s** | 1.49s | 3.06s | N/A | 4.37s | 4.48s |

## Feature Matrix

| Feature | Playwright | playwright-cli | dev-browser | agent-browser | Crawl4AI | Playwriter | Stagehand |
|---------|-----------|----------------|-------------|---------------|----------|------------|-----------|
| Headless | Yes | Yes | Yes | Yes | Yes | No | Yes |
| Session persist | storageState | Profile dir | Profile dir | state save/load | user_data_dir | Your browser | Per-instance |
| Proxy | Full | No | Via args | No | Full | Your browser | Via args |
| Extensions | Yes | No | Yes | No | No | Yes | Possible |
| Self-healing/NL | No | No | No | No | LLM only | No | Yes |
| Setup | npm install | npm install -g | Server running | npm install | pip/Docker | Extension click | npm + API key |

## Inspect First, Then Formalize

Use `chromium-debug-use` when the fastest path is to inspect a browser session that is already open, confirm what the user is doing now, or learn a flow before deciding how to automate it long-term.

| If you learned... | Stay or hand off to... | Why |
|-------------------|------------------------|-----|
| You just need to inspect the live session, read DOM state, click lightly, or capture the current flow | `chromium-debug-use` | Fastest path to what is already open |
| The flow should become reproducible, isolated, parallel, or CI-friendly | `tools/browser/playwright.md` | Fresh contexts are better for repeatable automation |
| The flow needs a managed persistent profile that aidevops can keep reusing | `tools/browser/dev-browser.md` | Better long-lived state than a user-owned live browser |
| The user wants tab-by-tab consent in their everyday browser instead of a debug-enabled profile | `tools/browser/playwriter.md` | Extension click keeps the consent boundary narrower |
| The page structure is still fuzzy and you want natural-language exploration before hardening selectors | `tools/browser/stagehand.md` | Better when the next step is exploratory automation |
| The goal is console, network, performance, or general DevTools inspection against the same live browser | `tools/browser/chrome-devtools.md` | Better debugging surface than automation-first CDP commands |

## Parallel Sessions

| Tool | Method | Speed | Isolation |
|------|--------|-------|-----------|
| Playwright | Contexts / browsers | **1.6-2.1s** (3-10 instances) | Context to full process |
| agent-browser | `--session s1/s2/s3` | 3 sessions: 2.0s | Per-session |
| Crawl4AI | `arun_many(urls)` | 5 pages: 3.0s (1.7x) | Shared or isolated |
| dev-browser | `client.page("name")` | Fast | Shared profile |

## Extensions (uBlock Origin example — Playwright/dev-browser)

```javascript
const context = await chromium.launchPersistentContext('/tmp/browser-profile', {
  headless: false,
  args: ['--load-extension=/path/to/ublock-origin-unpacked',
         '--disable-extensions-except=/path/to/ublock-origin-unpacked'],
});
```

## Custom Browsers

Brave/Edge/Chrome/Mullvad: Playwright, Playwriter, Crawl4AI, Stagehand. Bundled Chromium only: playwright-cli, agent-browser, WaterCrawl. macOS: `/Applications/{Brave Browser,Microsoft Edge,Google Chrome}.app/Contents/MacOS/{name}` · Mullvad: `/Applications/Mullvad Browser.app/Contents/MacOS/mullvadbrowser`. Browser QA prefers Brave when installed; set `AIDEVOPS_PLAYWRIGHT_BROWSER=chromium` to force bundled Chromium or `AIDEVOPS_PLAYWRIGHT_EXECUTABLE=/path/to/browser` for a specific engine. Config: `~/.config/aidevops/browser-prefs.json`.

## Debugging

```bash
# Chrome DevTools MCP (dev-browser :9222 or headless)
npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222
npx chrome-devtools-mcp@latest --headless

agent-browser screenshot /tmp/debug.png && agent-browser errors && agent-browser snapshot -i
```

**NEVER use curl to verify frontend fixes** — server returns 200 even when React crashes client-side. Diagnose: screenshot → errors/console → snapshot/URL → analyze → retry → ask user if stuck.

> **Screenshot limit**: Never `fullPage: true` for AI vision — can exceed 8000px (hard-rejected). Resize: `magick screenshot.png -resize "1568x1568>" out.png`. See `reference/screenshot-limits.md`.

<!-- AI-CONTEXT-END -->

Per-tool docs: `playwright.md` · `playwright-cli.md` · `chromium-debug-use.md` · `dev-browser.md` · `agent-browser.md` · `crawl4ai.md` · `playwriter.md` · `stagehand.md`. Ethics: respect ToS, rate limit (2-5s delays), no spam, legitimate use only, no personal data without consent.
