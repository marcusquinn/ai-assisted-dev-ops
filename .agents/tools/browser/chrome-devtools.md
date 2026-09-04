---
description: Chrome DevTools MCP for debugging and inspection
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
  chrome-devtools_*: true
  # TODO(permission-migration): Replace with permission: chrome-devtools: allow
  # once anomalyco/opencode#6892 is resolved.
mcp:
  - chrome-devtools
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Chrome DevTools MCP - Debugging & Inspection Companion

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Debugging/inspection layer that connects to ANY running Chrome/Chromium instance
- **Not a browser**: Pairs with dev-browser, Playwright, or standalone Chrome
- **Install**: `npx chrome-devtools-mcp@latest`
- **Package**: `chrome-devtools-mcp` (v0.13.0+, maintained by Google)
- **When to use**: Performance auditing, network debugging, SEO analysis, visual regression testing. Use alongside a browser tool, not instead of one.

**Connection methods** (all prefixed with `npx chrome-devtools-mcp@latest`):

| Flag | Use case |
|------|----------|
| `--browserUrl http://127.0.0.1:9222` | dev-browser (port 9222) |
| `--wsEndpoint ws://127.0.0.1:9222/devtools/browser/<id>` | WebSocket direct |
| `--headless` | Launch own Chrome (headless) |
| `--isolated` | Temp profile, auto-cleaned |
| `--proxyServer socks5://127.0.0.1:1080` | Proxy connection |
| `--channel canary` | Chrome Beta/Canary/Dev |
| `--autoConnect` | Chrome 145+, requires `chrome://inspect/#remote-debugging` |

**Capabilities**:

- Performance: `lighthouse()`, `measureWebVitals()` (LCP, FID, CLS, TTFB)
- Network: `monitorNetwork()`, global throttling via `emulate` with `networkConditions`, per-request via `throttleRequest()` / `throttleRequests()` (Chrome 144+)
- Scraping: `extractData()`, `screenshot()` (fullPage, element)
- Debug: `captureConsole()`, CSS coverage, visual regression
- Mobile: `emulateDevice()`, `simulateTouch()` (tap, swipe)
- SEO: `extractSEO()`, `validateStructuredData()`
- Automation: `comprehensiveAnalysis()`, `comparePages()` (A/B testing)

**Best pairings**:

- **playwright-cli + DevTools**: CLI automation + performance profiling (AI agents)
- **dev-browser + DevTools**: Persistent profile + deep inspection
- **Playwright + DevTools**: Speed + performance profiling
- **Playwright Extension + DevTools**: Interactive, user-present access to approved existing tabs + debugging and inspection

**Category toggles** (reduce MCP tool count):

```bash
npx chrome-devtools-mcp@latest --categoryEmulation false --categoryPerformance false
```

<!-- AI-CONTEXT-END -->

## Usage Examples

### Performance

```javascript
await chromeDevTools.lighthouse({ url: "https://example.com", categories: ["performance", "accessibility", "best-practices", "seo"], device: "desktop" });
await chromeDevTools.measureWebVitals({ url: "https://example.com", metrics: ["LCP", "FID", "CLS", "TTFB"], iterations: 5 });
```

### Scraping & Screenshots

```javascript
await chromeDevTools.extractData({ url: "https://example.com", selectors: { title: "h1", description: ".description", links: "a[href]" } });
await chromeDevTools.screenshot({ url: "https://example.com", fullPage: true, format: "png", quality: 90 });
```

### Debugging & Network

```javascript
await chromeDevTools.captureConsole({ url: "https://example.com", logLevel: "error", duration: 30000 });
await chromeDevTools.monitorNetwork({ url: "https://example.com", filters: ["xhr", "fetch", "document"], captureHeaders: true, captureBody: true });
```

### Network Throttling

| | `emulate` (global) | `throttleRequest` (per-request) |
|---|---|---|
| Scope | All requests | Specific URL patterns |
| Precision | Coarse | Fine-grained |
| Chrome version | All | 144+ |

```javascript
// Global — presets: "Slow 3G", "Fast 3G", "Offline"
await chromeDevTools.emulate({ url: "https://example.com", networkConditions: "Slow 3G" });

// Per-request (Chrome 144+) — first match wins
await chromeDevTools.throttleRequests({
  url: "https://example.com",
  rules: [
    { pattern: "**/api/critical", latency: 0, downloadThroughput: -1 },
    { pattern: "**/api/*", latency: 1500, downloadThroughput: 200 * 1024 },
    { pattern: "*.woff2", latency: 500, downloadThroughput: 50 * 1024 }
  ]
});
```

### Mobile

```javascript
await chromeDevTools.emulateDevice({ url: "https://example.com", device: "iPhone 12 Pro", orientation: "portrait" });
await chromeDevTools.simulateTouch({ url: "https://example.com", actions: [{ type: "tap", x: 100, y: 200 }, { type: "swipe", startX: 100, startY: 300, endX: 300, endY: 300 }] });
```

### SEO

```javascript
await chromeDevTools.extractSEO({ url: "https://example.com", elements: ["title", "meta[name='description']", "meta[property^='og:']", "link[rel='canonical']"] });
await chromeDevTools.validateStructuredData({ url: "https://example.com", schemas: ["Organization", "WebSite", "Article"] });
```

### Automation & Visual Testing

```javascript
await chromeDevTools.comprehensiveAnalysis({ url: "https://example.com", includePerformance: true, includeSEO: true, includeAccessibility: true });
await chromeDevTools.comparePages({ urlA: "https://example.com/a", urlB: "https://example.com/b", metrics: ["performance", "visual-diff", "accessibility"] });
await chromeDevTools.visualRegression({ url: "https://example.com", baseline: "/path/to/baseline.png", threshold: 0.1, highlightDifferences: true });
await chromeDevTools.analyzeCSSCoverage({ url: "https://example.com", reportUnused: true, minifyRecommendations: true });
```
