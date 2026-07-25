---
description: Mission-aware browser QA — Playwright-based visual testing for milestone validation, detecting layout bugs, broken links, missing content, and accessibility issues
mode: subagent
model: standard  # structured checking with coordinated judgment
tools:
  read: true
  write: true
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Browser QA for Milestone Validation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Visual and functional QA for mission milestones with UI components
- **CLI**: `browser-qa-helper.sh run|screenshot|links|a11y|smoke --url URL --pages "/ /about"`
- **Invoked by**: `workflows/milestone-validation.md` (Phase 3) during mission orchestration
- **Tool stack**: Playwright (primary, fastest) > Stagehand (fallback, self-healing) > DevTools (companion)
- **Output**: JSON/markdown reports with screenshots, broken links, accessibility issues, console errors
- **When to use**: Milestone has UI components and criteria mention pages, visual layout, responsive design, user flows, or frontend rendering

**Key files**:

| File | Purpose |
|------|---------|
| `scripts/browser-qa-helper.sh` | CLI for all browser QA operations |
| `scripts/accessibility/playwright-contrast.mjs` | WCAG contrast ratio checking |
| `tools/browser/browser-automation.md` | Tool selection guide (when to use what) |
| `tools/browser/playwright.md` | Playwright API reference |
| `workflows/milestone-validation.md` | Parent workflow that invokes browser QA |

<!-- AI-CONTEXT-END -->

## How to Think

- **Acceptance criteria drive everything.** Read the milestone's `Validation:` field. Each criterion becomes a specific check. "Homepage renders correctly" → navigate to `/`, verify no console errors, verify content present, screenshot at desktop and mobile.
- **Prefer lightweight checks.** ARIA snapshots (~50-200 tokens) tell you more about page structure than screenshots (~1K vision tokens). Use screenshots for visual regression; ARIA for functional checks (forms, navigation, interactive elements).
- **Report with evidence.** Every failure includes: what was expected, what was found, and a screenshot or ARIA snapshot proving it.

## QA Pipeline

### Step 1: Start the Application

The milestone validation worker handles server startup (see `workflows/milestone-validation.md` "Dev Server Management"). If invoked directly:

```bash
if [[ -f "package.json" ]] && jq -e '.scripts.dev' package.json &>/dev/null; then
  npm run dev &
  DEV_PID=$!
fi
browser-qa-helper.sh smoke --url http://localhost:3000 --pages "/"
```

### Step 2: Smoke Test (Always First)

```bash
browser-qa-helper.sh smoke --url http://localhost:3000 --pages "/ /about /dashboard /login"
```

Checks: HTTP 2xx, console errors, failed network requests, body has text, page title exists.

- Console errors on load → React hydration failure, missing API, etc.
- Network errors → missing assets, broken API calls, CORS issues
- Empty body → rendering crash, blank page bug

### Step 3: Screenshot Capture

```bash
# Desktop + mobile (default)
browser-qa-helper.sh screenshot --url http://localhost:3000 \
  --pages "/ /about /dashboard" \
  --viewports desktop,mobile

# All viewports including tablet
browser-qa-helper.sh screenshot --url http://localhost:3000 \
  --pages "/ /about /dashboard" \
  --viewports desktop,tablet,mobile \
  --full-page \
  --max-dim 4000
```

**Viewport definitions**:

| Name | Width | Height |
|------|-------|--------|
| desktop | 1440 | 900 |
| tablet | 768 | 1024 |
| mobile | 375 | 667 |

**Size guardrails (GH#4213):** `browser-qa-helper.sh screenshot` is the ONLY path with automatic size guardrails. Default resize target: `4000px` max dimension; Anthropic hard limit: `8000px`. All other paths (Playwright MCP `browser_screenshot`, raw Playwright code, `ui-verification.md`) have zero automatic protection — use `fullPage: false` or manually resize before sending to vision API:

```bash
sips --resampleHeightWidthMax 1568 screenshot.png --out screenshot-resized.png  # macOS
magick screenshot.png -resize "1568x1568>" screenshot-resized.png               # ImageMagick
```

See `tools/vision/image-understanding.md` for per-provider limits.

**What to look for**: layout breaks, missing images/icons, text truncation, mobile hamburger menu, footer positioning, form alignment.

### Step 4: Broken Link Detection

```bash
browser-qa-helper.sh links --url http://localhost:3000 --depth 2
```

Checks all `<a href>` internal links (same origin, depth 2). 2xx/3xx = ok, 4xx/5xx = broken. Common findings: 404s from renamed pages, API endpoints returning errors without auth.

> Crawler only follows absolute `http*` URLs. Placeholder links (`#`, `javascript:void(0)`) require regex scan or manual review.

### Step 5: Accessibility Checks

```bash
browser-qa-helper.sh a11y --url http://localhost:3000 --pages "/ /about" --level AA
```

Checks: contrast ratios (WCAG AA: 4.5:1 normal, 3:1 large), missing alt text, form labels, heading hierarchy, `lang` attribute, page title, empty buttons/links.

### Step 6: Content Verification (Mission-Aware)

Read acceptance criteria, then verify each with Playwright:

```javascript
// Example: "Homepage shows product name and pricing"
const page = await browser.newPage();
await page.goto('http://localhost:3000');
const bodyText = await page.evaluate(() => document.body.innerText);
const hasProductName = bodyText.includes('ProductName');
const heroExists = await page.locator('.hero, [data-testid="hero"]').count() > 0;
const ctaExists = await page.locator('a:has-text("Get Started"), button:has-text("Sign Up")').count() > 0;
```

Use Stagehand `observe()`/`extract()` when page structure is unknown or criteria are vague ("page looks professional"). Prefer Playwright for speed when you know what to look for.

## Interpreting Results for the Orchestrator

| Finding | Severity | Blocks Milestone? |
|---------|----------|-------------------|
| Page returns 5xx | Critical | Yes |
| Console error on load | Critical | Yes |
| Blank page (no content) | Critical | Yes |
| Broken internal link (404) | Major | Yes |
| Layout break at required viewport | Major | Yes |
| Missing content from acceptance criteria | Major | Yes |
| Contrast ratio failure (AA) | Major | Yes (if a11y is in criteria) |
| Missing alt text | Minor | No (note in report) |
| Heading hierarchy skip | Minor | No (note in report) |
| Console warning (not error) | Minor | No (note in report) |
| Missing form label | Minor | No (unless forms are in criteria) |

## Advanced: Visual Regression

```bash
# Baseline (after Milestone 1 passes)
browser-qa-helper.sh screenshot --url http://localhost:3000 \
  --pages "/" --output-dir /path/to/mission/assets/baseline-m1

# After Milestone 2 features merge
browser-qa-helper.sh screenshot --url http://localhost:3000 \
  --pages "/" --output-dir /path/to/mission/assets/current-m2

# Compare (pixel diff — requires ImageMagick)
compare -metric RMSE baseline-m1/index-desktop-1440x900.png current-m2/index-desktop-1440x900.png diff.png
```

Pixel-perfect comparison is brittle (font rendering, animation timing). Use for detecting major layout shifts only. Diff > 5% RMSE warrants investigation.

## Related

- `scripts/browser-qa-helper.sh` — CLI tool for all browser QA operations
- `workflows/milestone-validation.md` — Parent workflow (invokes this for UI milestones)
- `workflows/mission-orchestrator.md` — Mission orchestrator (Phase 4 triggers validation)
- `tools/browser/browser-automation.md` — Tool selection guide
- `tools/browser/playwright.md` — Playwright API reference
- `tools/browser/stagehand.md` — Stagehand for unknown page structures
- `scripts/accessibility/playwright-contrast.mjs` — WCAG contrast checking
- `tools/accessibility/accessibility-audit.md` — Full accessibility audit workflow
