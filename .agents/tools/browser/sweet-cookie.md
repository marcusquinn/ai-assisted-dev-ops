---
description: Browser cookie extraction for automation and session reuse
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

# Sweet Cookie - Browser Cookie Extraction

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Extract browser cookies for automation, session reuse, authenticated scraping
- **Libraries**: `@steipete/sweet-cookie` (TypeScript, cross-platform) | `SweetCookieKit` (Swift, macOS-only)
- **Use when**: reusing browser sessions, authenticated API calls, bypassing automation detection, CI/CD auth state
- **Don't use when**: fresh browser automation -> agent-browser/stagehand; unauthenticated scraping -> crawl4ai

```text
Need cookies from existing browser session?
    +-> TypeScript/Node.js? --> @steipete/sweet-cookie
    +-> Swift/macOS native? --> SweetCookieKit
    +-> App-bound cookies (Chrome 127+)? --> Chrome extension
```

<!-- AI-CONTEXT-END -->

## @steipete/sweet-cookie (TypeScript)

Cross-platform extraction for Node.js (>=22, `node:sqlite`) and Bun (`bun:sqlite`).

```bash
npm install @steipete/sweet-cookie   # or: pnpm add / bun add
```

```typescript
import { getCookies, toCookieHeader } from '@steipete/sweet-cookie';

// Basic extraction
const { cookies, warnings } = await getCookies({
  url: 'https://example.com/',
  names: ['session', 'csrf'],
  browsers: ['chrome', 'edge', 'firefox', 'safari'],
});
await fetch('https://api.example.com/data', {
  headers: { Cookie: toCookieHeader(cookies, { dedupeByName: true }) }
});

// Multiple origins (OAuth/SSO)
await getCookies({
  url: 'https://app.example.com/',
  origins: ['https://accounts.example.com/', 'https://login.example.com/'],
  names: ['session', 'xsrf'], browsers: ['chrome'], mode: 'merge',
});

// Specific browser profile
await getCookies({ url: 'https://example.com/', browsers: ['chrome'], chromeProfile: 'Default' });
await getCookies({ url: 'https://example.com/', browsers: ['edge'], edgeProfile: 'Profile 1' });

// Inline cookies (CI/CD — no browser DB access)
await getCookies({ url: 'https://example.com/', inlineCookiesFile: '/path/to/cookies.json' });
await getCookies({ url: 'https://example.com/', inlineCookiesJson: '{"cookies": [...]}' });
await getCookies({ url: 'https://example.com/', inlineCookiesBase64: 'eyJjb29raWVzIjogWy4uLl19' });
```

### Environment Variables

| Variable | Example |
|----------|---------|
| `SWEET_COOKIE_BROWSERS` | `chrome,safari,firefox` |
| `SWEET_COOKIE_MODE` | `merge` or `first` |
| `SWEET_COOKIE_CHROME_PROFILE` | `Default` |
| `SWEET_COOKIE_EDGE_PROFILE` | `Default` |
| `SWEET_COOKIE_FIREFOX_PROFILE` | `default-release` |
| `SWEET_COOKIE_LINUX_KEYRING` | `gnome`, `kwallet`, `basic` |
| `SWEET_COOKIE_CHROME_SAFE_STORAGE_PASSWORD` | (keychain password) |

### Browser Support

| Browser | macOS | Windows | Linux |
|---------|-------|---------|-------|
| Chrome  | Yes   | Yes     | Yes   |
| Edge    | Yes   | Yes     | Yes   |
| Firefox | Yes   | Yes     | Yes   |
| Safari  | Yes   | -       | -     |

**App-Bound Cookies (Chrome 127+):** Install extension from `apps/extension` in sweet-cookie repo -> export as JSON/base64/file -> use `inlineCookiesFile`/`inlineCookiesJson`.

## SweetCookieKit (Swift)

macOS-only. Requirements: macOS 13+, Swift 6. Install: `.package(url: "https://github.com/steipete/SweetCookieKit.git", from: "0.2.0")`

```swift
import SweetCookieKit

let client = BrowserCookieClient()
let store = client.stores(for: .chrome).first { $0.profile.name == "Default" }
let query = BrowserCookieQuery(domains: ["example.com"], domainMatch: .suffix, includeExpired: false)
let cookies = try client.cookies(matching: query, in: store!)

// Iterate all browsers
for browser in Browser.defaultImportOrder {
    let results = try client.records(matching: query, in: browser)
}

// Chromium Local Storage & LevelDB
let entries = ChromiumLocalStorageReader.readEntries(for: "https://example.com", in: levelDBURL)
let tokens = ChromiumLevelDBReader.readTokenCandidates(in: levelDBURL, minimumLength: 80)
```

CLI: `swift run SweetCookieCLI stores` | `swift run SweetCookieCLI export --domain example.com --format json`

## Security

- Chrome/Edge trigger Keychain access prompts on macOS
- Safari requires Full Disk Access
- Some browsers lock cookie DB while running — close first
- Chromium cookies encrypted; sweet-cookie decrypts via OS keychain
- Swift keychain handler: `BrowserCookieKeychainPromptHandler.shared.handler = { context in /* .chromiumSafeStorage */ }`

## Related

- [sweet-cookie (TS)](https://github.com/steipete/sweet-cookie) | [SweetCookieKit (Swift)](https://github.com/steipete/SweetCookieKit) | [Docs](https://sweetcookie.dev)
- Bird (X/Twitter CLI): auto-extracts cookies -> `tools/social-media/bird.md`
- Crawl4AI: `crawl4ai https://app.example.com --cookies /path/to/cookies.json`
- `tools/browser/agent-browser.md` (CLI browser automation) | `tools/browser/stagehand.md` (AI browser) | `tools/browser/playwright.md` (official existing-session extension)
