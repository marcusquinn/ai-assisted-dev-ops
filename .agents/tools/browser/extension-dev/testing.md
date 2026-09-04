---
description: Browser extension testing - cross-browser verification, E2E testing, debugging
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Extension Testing - Cross-Browser QA

Use the extension's existing runner and real loaded-extension path by default.
The runner, E2E, and CI sections below are options for an explicitly requested
testing-infrastructure objective, not instructions to create them during routine
extension development. See `reference/ci-gate-policy.md`.

**Decision tree**:

```text
Project-owned unpacked extension with existing runner? → Playwright (Chromium only)
chrome://extensions or arbitrary installed extension?  → Manual verification; not an extension-bridge QA target
No existing runner?                                  → Manual verification; do not create infrastructure for routine QA
Debug service worker?        → chrome://extensions → Inspect service worker
Debug content scripts?       → DevTools → Sources → Content scripts
Cross-browser verification?  → Chrome + Firefox + Edge (manual or CI)
```

**Test levels**: Unit → Integration → E2E → Cross-browser → Performance

## Stable Unpacked-Extension Workflow

For authenticated testing in an existing Chrome profile, configure the project
to build the unpacked extension to one stable project-relative directory. Do not
copy builds to changing temporary directories or hardcode a developer's absolute
path.

1. Build the extension to the configured directory, such as
   `.output/chrome-mv3/`.
2. Open `chrome://extensions`, enable Developer mode, and use **Load unpacked**
   once for that directory.
3. After each rebuild, use the extension card's **Reload** action, then reload
   the target page before testing.
4. Only while the user is available interactively, use Microsoft's Playwright
   Extension for existing-profile page sessions, approve only the intended tab
   group, and run the authenticated-tab preflight. Otherwise use a separate
   Playwright browser, with Brave preferred. A Playwright persistent context is
   a separate profile and must not be treated as the user's authenticated
   session.

For extension UI QA, distinguish the project-owned unpacked build from browser
manager and user-installed pages before browser actions. `chrome://extensions`
and arbitrary installed extensions have no supported automated bridge route. Do
not attempt to reach them through an existing-session extension or launch a
replacement browser or profile. The headed persistent-context E2E route below
is supported only when the project already has a runner and stable build path.

When the linked worktree is intentionally disposable but Chrome must retain one
stable unpacked-extension path, deploy the reviewed build to an allowlisted
non-Git directory with `deployment-copy-helper.sh`. Review its dry-run change set
first and keep the expected commit plus generated-tree digest bound to the copy.
Do not use manual `rsync --delete`, make the canonical checkout writable, or
relax the pre-edit worktree gate. The deployment and recovery contract is in
`reference/dirty-worktree-preservation.md` under “Audited deployment to a
non-Git target”.

## Unit Tests

```bash
npm run test   # Vitest (recommended with WXT)
npx --no-install jest  # Existing Jest alternative
```

## E2E Testing (Playwright)

Playwright loads unpacked extensions in Chromium only (`headless: false` required; Firefox not supported):

```typescript
import { test, chromium } from '@playwright/test';
import path from 'path';

test('extension popup works', async () => {
  const pathToExtension = path.resolve('.output/chrome-mv3');
  const context = await chromium.launchPersistentContext('', {
    headless: false,
    args: [`--disable-extensions-except=${pathToExtension}`, `--load-extension=${pathToExtension}`],
  });

  // Extract extension ID from service worker URL
  const sw = context.serviceWorkers()[0] ?? await context.waitForEvent('serviceworker');
  const extensionId = sw.url().split('/')[2];

  const popup = await context.newPage();
  await popup.goto(`chrome-extension://${extensionId}/popup.html`);
  await popup.click('button#action');
  await popup.waitForSelector('#result');
  await context.close();
});
```

## Debugging

| Target | How |
|--------|-----|
| Service Worker | `chrome://extensions` → find extension → "Inspect views: service worker" |
| Content Scripts | DevTools (F12) → Sources → Content scripts → set breakpoints |
| Popup | Right-click extension icon → "Inspect popup" |

**Storage inspection** (DevTools console in any extension context):

```javascript
chrome.storage.local.get(null, console.log);
chrome.storage.sync.get(null, console.log);
```

## Manual Testing Checklist

| Check | Chrome (`.output/chrome-mv3/`) | Firefox (`.output/firefox-mv2/`) | Edge (`.output/chrome-mv3/`) |
|-------|-------------------------------|----------------------------------|------------------------------|
| Popup opens and functions | ☐ | ☐ | ☐ |
| Content scripts inject | ☐ | ☐ | ☐ |
| Service worker handles events | ☐ | — | — |
| Storage persists across sessions | ☐ | ☐ | ☐ |
| Options page saves preferences | ☐ | ☐ | ☐ |
| Side panel works (if applicable) | ☐ | — | ☐ |
| Permissions requested correctly | ☐ | ☐ | ☐ |
| Firefox-specific APIs handled | — | ☐ | — |
| No console errors | ☐ | ☐ | ☐ |

Firefox: load temporary add-on from `.output/firefox-mv2/` (or MV3). Edge: same build as Chrome.

## Cross-Browser CI

Configure this only when CI test integration is explicitly requested or already
required by repository policy.

```yaml
name: Extension Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: npm ci && npm run build
      - run: npx playwright install chromium && npm run test:e2e
```

## Pre-Submission Checklist

- [ ] Applicable configured/required unit and E2E checks pass; do not add a missing suite solely for submission verification
- [ ] Manual testing complete in Firefox and Edge
- [ ] No console errors or warnings
- [ ] Permissions minimal and justified; CSP configured
- [ ] No hardcoded API keys or secrets
- [ ] Extension works in incognito mode (if applicable)
- [ ] Handles offline gracefully; memory usage reasonable

## Related

- `tools/browser/extension-dev/development.md` — Development setup
- `tools/browser/extension-dev/publishing.md` — Store submission
- `tools/browser/playwright.md` — Playwright testing
- `tools/browser/chrome-devtools.md` — Chrome DevTools
