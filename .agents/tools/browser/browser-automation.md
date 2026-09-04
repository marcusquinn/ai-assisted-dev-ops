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

Prefer: fastest tool → ARIA snapshots over screenshots (50-200 tokens vs ~1K) → headless over headed → CLI for AI agents. For normal headed or headless work, use a separate Playwright browser with Brave preferred so automation does not interrupt the user's activity. Microsoft's Playwright Extension is an interactive-only exception when an available user explicitly needs selected tabs from their existing browser.

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
    User present + current browser required → Playwright Extension | Unlock once → dev-browser | Programmatic → standalone Playwright + Bitwarden CLI
  Live already-open Chromium/Chrome session:
    Inspect current state / understand workflow first → chromium-debug-use
    Interactive selected tabs → Playwright Extension | Repeatable isolated flow → standalone Playwright (Brave preferred) / dev-browser / Stagehand
  Parallel sessions: speed → Playwright | CLI → playwright-cli/agent-browser --session
  Persistent login: with extensions → dev-browser | without → playwright-cli/storageState
  Proxy: direct → standalone Playwright/Crawl4AI | interactive use of existing browser's proxy/VPN → Playwright Extension
  Self-healing/unknown structure → Stagehand (NL, slowest)
  AI agent CLI-first → playwright-cli (Microsoft) or agent-browser (Vercel, Rust)
  Just fast → Playwright direct (0.9s form fill)

EXTENSION UI QA?
  chrome://extensions or arbitrary installed user extension → Stop before browser actions; use manual verification
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

Overhead: dev-browser +0.1-0.4s | agent-browser +0.5-1.5s (cold) | Stagehand +1-5s (AI).

| Test | Playwright | dev-browser | agent-browser | Crawl4AI | Stagehand |
|------|-----------|-------------|---------------|----------|-----------|
| Navigate + Screenshot | **1.43s** | 1.39s | 1.90s | 2.78s | 7.72s |
| Form Fill (4 fields) | **0.90s** | 1.34s | 1.37s | N/A | 2.58s |
| Data Extract (5 items) | 1.33s | **1.08s** | 1.53s | 2.53s | 3.48s |
| Multi-step (click+nav) | **1.49s** | 1.49s | 3.06s | N/A | 4.48s |

## Feature Matrix

| Feature | Playwright | playwright-cli | dev-browser | agent-browser | Crawl4AI | Stagehand |
|---------|-----------|----------------|-------------|---------------|----------|-----------|
| Headless | Yes; extension mode is headed | Yes | Yes | Yes | Yes | Yes |
| Session persist | storageState/profile/existing tabs | Profile dir | Profile dir | state save/load | user_data_dir | Per-instance |
| Proxy | Full or existing browser | No | Via args | No | Full | Via args |
| Extensions | Persistent context or official existing-session extension | No | Yes | No | No | Possible |
| Self-healing/NL | No | No | No | No | LLM only | Yes |
| Setup | npm install; extension optional | npm install -g | Server running | npm install | pip/Docker | npm + API key |

## Inspect First, Then Formalize

Use `chromium-debug-use` when the fastest path is to inspect a browser session that is already open, confirm what the user is doing now, or learn a flow before deciding how to automate it long-term.

| If you learned... | Stay or hand off to... | Why |
|-------------------|------------------------|-----|
| You just need to inspect the live session, read DOM state, click lightly, or capture the current flow | `chromium-debug-use` | Fastest path to what is already open |
| The flow should become reproducible, isolated, parallel, or CI-friendly | `tools/browser/playwright.md` | Fresh contexts are better for repeatable automation |
| The flow needs a managed persistent profile that aidevops can keep reusing | `tools/browser/dev-browser.md` | Better long-lived state than a user-owned live browser |
| An available user explicitly wants selected-tab consent in their everyday browser instead of a separate profile | `tools/browser/playwright.md` extension mode | Official extension limits each interactive client to its selected tab group |
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

Standalone Playwright prefers Brave for headed and headless work, with bundled Chromium as fallback; it also supports Edge/Chrome/Mullvad. Its interactive-only existing-session extension documents Chrome, Edge, and Chromium, not Brave. Crawl4AI and Stagehand also support Chromium-family browsers. Bundled Chromium only: playwright-cli, agent-browser, WaterCrawl. macOS: `/Applications/{Brave Browser,Microsoft Edge,Google Chrome}.app/Contents/MacOS/{name}` · Mullvad: `/Applications/Mullvad Browser.app/Contents/MacOS/mullvadbrowser`. Set `AIDEVOPS_PLAYWRIGHT_BROWSER=chromium` to force bundled Chromium or `AIDEVOPS_PLAYWRIGHT_EXECUTABLE=/path/to/browser` for a specific engine. Config: `~/.config/aidevops/browser-prefs.json`.

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

Per-tool docs: `playwright.md` · `playwright-cli.md` · `chromium-debug-use.md` · `dev-browser.md` · `agent-browser.md` · `crawl4ai.md` · `stagehand.md`. Legacy explicit-only compatibility: `playwriter.md`. Ethics: respect ToS, rate limit (2-5s delays), no spam, legitimate use only, no personal data without consent.
