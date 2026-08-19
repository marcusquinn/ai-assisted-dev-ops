---
description: Visual verification workflow for UI, layout, and design changes
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

# UI Verification Workflow

<!-- AI-CONTEXT-START -->

**Purpose**: Verify UI/layout/design changes across devices, catch browser errors, validate accessibility.
**Trigger**: CSS, layout, responsive design, UI components, visual changes, or task descriptions containing: layout, responsive, design, UI, UX, visual, styling, CSS.
**Principle**: Never self-assess "looks good" — use the real rendered product path with existing browser/runtime helpers and evidence. Do not create a standalone Playwright script or visual-test harness for routine verification.

<!-- AI-CONTEXT-END -->

## Workflow

### 1. Responsive Decision Pass

Before choosing layout behaviour, check the repo's `DESIGN.md` `Responsive Behaviour` section and nearby component examples. If conventions are clear, follow them. If absent or inconsistent, use responsive best practices by default; when multiple patterns are viable, report 2-3 options with trade-offs and choose the one that best fits the repo brand, theme, content density, and accessibility constraints.

Record the decision before screenshots: breakpoints covered, navigation orientation, wrapping/overflow strategy, touch target expectations, readability/text scaling, theme variants, and reduced-motion handling where relevant. This is a decision pass, not a broad E2E mandate.

### 2. Screenshots + Error Check

> **NEVER `fullPage: true`** for AI vision review — exceeds 8000px, hard-crashes session. Viewport-sized only. See `reference/screenshot-limits.md` and AGENTS.md "Screenshot Size Limits".

Use the existing `browser-qa-helper.sh` or the repository's already configured browser workflow. For routine UI work, check only the affected page at desktop and one relevant mobile viewport. Capture a before baseline only when it will change the implementation/review decision. Broaden to tablet, landscape, theme, or additional edge viewports only for responsive-critical changes, new layout systems, or release readiness.

```bash
browser-qa-helper.sh smoke --url "$DEV_URL" --pages "$AFFECTED_PATHS"
browser-qa-helper.sh screenshot --url "$DEV_URL" \
  --pages "$AFFECTED_PATHS" --viewports desktop,mobile --max-dim 1568
```

Do not turn these commands into a committed one-off script. If the helper or an existing project workflow cannot cover a material uncertainty, explain the gap before proposing new browser-test infrastructure.

**With Chrome DevTools MCP:** `captureConsole({logLevel:'error'})`, `analyzeCSSCoverage({reportUnused:true})`, `monitorNetwork({filters:[...]})`.

**Check for**: JS errors, failed requests (404s, CORS), CSS warnings, mixed content, deprecation warnings, layout shift (CLS), horizontal overflow, unintended wrapping/truncation, navigation orientation changes, touch target size/spacing, text scaling/readability, light/dark theme regressions, and reduced-motion behaviour when animations are present.

### 3. Accessibility Verification

Always check accessibility relevant to the changed surface, using the smallest existing route that provides evidence. A full matrix is for broad component/layout changes and release readiness, not every CSS edit.

```bash
~/.aidevops/agents/scripts/accessibility-helper.sh audit <url>
~/.aidevops/agents/scripts/accessibility-helper.sh playwright-contrast <url>
~/.aidevops/agents/scripts/accessibility-audit-helper.sh axe <url>
```

| Check | Tool | WCAG |
|-------|------|------|
| Colour contrast | `playwright-contrast` | 1.4.3 AA |
| Keyboard navigation | Playwright `page.keyboard` | 2.1.1 A |
| Focus visibility | Screenshot with `:focus` | 2.4.7 AA |
| Heading structure | axe-core / pa11y | 1.3.1 A |
| Touch targets | Device emulation | 2.5.8 AA |
| Text scaling | Viewport at 200% zoom | 1.4.4 AA |

**Dark mode / reduced motion:** Check both themes when the changed surface supports or affects them. Check reduced motion when animations or transitions changed.

### 4. Report

```markdown
## UI Verification Report
### Screenshots — <selected affected viewports>: [before when decision-relevant] [after] -- <what changed>
### Responsive Behaviour — conventions checked, devices tested, key layout/navigation/wrapping decisions, follow-up issues
### Browser Errors — <none or list>
### Accessibility — contrast pass/fail, keyboard pass/fail, axe violations
### Issues Found — [device] <description> [S1/S2/S3]
```

---

## Design Principles Checklist

Apply the principles relevant to the changed surface; report observed violations as `[S1/S2/S3] <principle> -- <description>`. Do not manufacture a broad audit for an unrelated small edit.

### Severity

| Level | Definition | Action |
|-------|------------|--------|
| **S1 Blocker** | Prevents use or legal/compliance risk (invisible text, unreachable keyboard element, missing `alt`, touch target <24px) | Fix before complete |
| **S2 Major** | Significantly degrades usability/brand (paragraph >740px, body text <16px, missing hover state, logo not linking home) | Fix before complete |
| **S3 Minor** | Noticeable but doesn't block use (orphaned word, fourth font family, inconsistent icon sizing) | Fix if low effort; else log |

### Typography

| Rule | Verification |
|------|-------------|
| Paragraph width <=740px (~75 chars/line) | Inspect `max-width`; screenshot at desktop-lg |
| Body text >=16px; supplementary >=14px | Playwright `evaluate()` computed `font-size` |
| Max 3 font families (headings, body, code) | Inspect computed `font-family`; flag 4th |
| Distinct font weights (700 headings, 400 body, 600 labels) | Verify in screenshots |
| Line height >=1.4 body, >=1.2 headings | Inspect computed `line-height` |
| No character overlap from letter spacing; verify custom fonts at small sizes/bold | Visual check |
| No single words on final line; use `text-wrap: balance`/`pretty` | Visual check at multiple widths |

### Layout and Spacing

| Rule | Verification |
|------|-------------|
| Spacing scale (4/8/12/16/24/32/48px); consistent between similar elements | Inspect padding |
| Text never touches container edges | Screenshot; verify breathing room |
| Elements within a section share alignment | Verify labels/headings/body align |
| Similar elements (cards, buttons, icons) same size | Verify repeated elements uniform |
| Brand logos have adequate clear space | Screenshot; verify breathing room |
| Smooth adaptation across breakpoints; works for varying content lengths | Test short/long content |
| Desktop-first layouts still work on narrow mobile, mobile landscape, tablet, desktop, and desktop-lg | Screenshot named breakpoints; inspect overflow and stacking |
| If repo responsive conventions are unclear, document best-practice fallback or 2-3 options with trade-offs | Report Responsive Behaviour decision |

### Interaction and Accessibility

| Rule | Verification |
|------|-------------|
| Touch targets min 44x44px (aim); never below 24x24px; adequate spacing | Playwright `evaluate()` bounding boxes on mobile |
| All clickable elements have visible hover change | Playwright `hover()` + screenshot comparison |
| Links in paragraphs: bold, underlined, distinct colour (not colour-only) | Inspect styles on `<a>` within `<p>` |
| Descriptive `alt` on images; `alt=""` on decorative; `aria-label`/`aria-labelledby` on interactive (preferred over `title`) | Playwright `evaluate()` audit `<img>` |
| Icons reinforce meaning; understandable without label or paired with text | Visual check |
| Scroll wheel works on all scrollable areas; no scroll trapping | Playwright `mouse.wheel()` on body and scroll containers |

### Colour, Theming, and Information Architecture

| Rule | Verification |
|------|-------------|
| Conventional colour associations: red=error, amber=warning, green=success, blue=info | Visual check |
| Text highlighting adequate contrast in both light/dark modes | Test both `colorScheme` values |
| Brand logo in nav links to `/` or site root | Playwright `evaluate()` logo `<a>` href |
| Visual hierarchy via layout, size, weight, whitespace — not colour alone; primary CTA most prominent | Screenshot check |
| CSS classes, component names, design tokens follow consistent convention (BEM, utility-first, or token-based) | Code review |

### Usability (Mom Test)

Evaluate against `seo/mom-test-ux.md` after technical checks: Clarity (goal clear in 10s?), Simplicity (no clutter?), Consistency (same elements behave same?), Feedback (interactions produce response?), Discoverability (findable without instructions?), Forgiveness (recoverable from mistakes?). S1/S2 failures must be fixed before complete.

---

## Quick Verification (Minimal)

This is the default for routine UI work: screenshot at desktop plus one mobile viewport when layout, spacing, typography, wrapping, or navigation can change; check console errors and the relevant contrast, text/touch-target, and overflow risks. Use the full workflow only for significant layout changes, new components, responsive redesigns, or release readiness.

## Build Workflow Integration

- **Step 8 (Verification)**: Use Quick Verification by default. Run the broader steps only when change scope or risk requires them; existing unit/integration tests remain complementary evidence when applicable.
- **Step 9 (Validate)**: Include report as evidence. "Browser (UI)" = *actual browser screenshots*, not self-assessment.

**Skip when**: Backend-only, docs-only, CI/CD config, DB migrations (unless affecting displayed data), API-only (unless affecting rendered content). When in doubt, run quick verification — under 30 seconds.

## Related

- `tools/browser/playwright-emulation.md` — Device presets and emulation configuration
- `tools/browser/chrome-devtools.md` — Browser debugging and performance inspection
- `tools/accessibility/accessibility.md` — WCAG compliance testing
- `tools/browser/browser-automation.md` — Tool selection decision tree
- `tools/browser/pagespeed.md` — Performance testing (includes accessibility score)
