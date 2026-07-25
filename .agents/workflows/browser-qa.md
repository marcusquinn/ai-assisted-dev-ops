---
description: Browser QA — Playwright-based visual testing for milestone validation, detecting layout bugs, broken links, missing content, and console errors
mode: subagent
model: standard  # structured checking with coordinated judgment
tools:
  read: true
  write: false
  edit: false
  bash: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Browser QA

<!-- AI-CONTEXT-START -->

## Quick Reference

| Item | Value |
|------|-------|
| **Scripts** | `scripts/browser-qa-worker.sh` (shell) + `scripts/browser-qa/browser-qa.mjs` (Playwright) |
| **Entry points** | Standalone or `milestone-validation-worker.sh --browser-qa` |
| **Purpose** | Visual smoke QA: screenshots, broken links, console/network errors, empty/error pages |
| **Output** | Text/JSON report plus `{output-dir}/qa-report.json` and screenshots |
| **Prerequisites** | Node.js v18+, Playwright (`npm install playwright && npx playwright install`) |

<!-- AI-CONTEXT-END -->

## When to Use

| Flag | Runs | Use when |
|------|------|----------|
| `--browser-tests` | Project Playwright test suite | Repo already has `playwright.config.{ts,js}` |
| `--browser-qa` | Generic browser smoke QA | Any UI project, especially POC/milestone validation without a dedicated suite |

## Checks

| Check | Detects | Result |
|-------|---------|--------|
| HTTP status | 4xx/5xx responses | Fail |
| Empty page | Body text under 10 chars | Fail |
| Error states | `Application error`, hydration failures | Fail |
| Console errors | JS exceptions, uncaught errors | Fail |
| Network errors | Failed fetch/XHR | Fail |
| Broken links | `<a>` targets returning 4xx/5xx or timing out | Fail |
| Screenshot | Full-page capture for review | Info |
| ARIA snapshot | Accessibility tree snapshot | Info |

JSON summary: `{output-dir}/qa-report.json` — visited/passed/failed pages, broken links, console errors, screenshot paths.

## Usage

```bash
# Standalone — basic, with flows, with output dir, JSON format, skip links, mission-scoped
browser-qa-worker.sh --url http://localhost:3000
browser-qa-worker.sh --url http://localhost:3000 --flows '["/", "/about", "/login"]'
browser-qa-worker.sh --url http://localhost:8080 --output-dir ~/Git/myproject/todo/missions/m001/assets/qa
browser-qa-worker.sh --url http://localhost:3000 --format json --no-check-links
browser-qa-worker.sh --url http://localhost:3000 --mission-file mission.md --milestone 2

# Via milestone validation
milestone-validation-worker.sh mission.md 2 --browser-qa --browser-url http://localhost:3000
milestone-validation-worker.sh mission.md 2 --browser-qa --browser-url http://localhost:3000 \
  --browser-qa-flows '["/", "/about", "/api/health"]'
milestone-validation-worker.sh mission.md 1 --browser-tests --browser-qa --browser-url http://localhost:3000
```

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | All checks passed |
| `1` | QA found failures |
| `2` | Configuration error (missing args, Playwright unavailable) |

## Flows and output

Flows accept a JSON array of path strings or `{url, name}` objects:

```json
["/", "/about", "/contact", "/login"]
[{"url": "/", "name": "homepage"}, {"url": "/dashboard", "name": "dashboard"}]
```

With `--mission-file` and `--milestone`, the worker extracts URL-like patterns from the milestone acceptance criteria.

- Screenshots: `{output-dir}/{hostname}_{path}.png`; failures also get `{hostname}_{path}-error.png`
- JSON: `{output-dir}/qa-report.json` with `baseUrl`, `timestamp`, `viewport`, top-level `passed`, and per-page results (`status`, `title`, `screenshot`, `consoleErrors`, `networkErrors`, `linkResults`, `loadTimeMs`, `passed`, `failures`)

## Related

| Tool | Purpose | Use when |
|------|---------|----------|
| `browser-qa-worker.sh` | Generic browser smoke QA | Milestone validation, manual smoke checks |
| `playwright-contrast.mjs` | WCAG contrast analysis | Accessibility audits |
| `accessibility-audit-helper.sh` | Broader accessibility audit | WCAG compliance reviews |
| `pagespeed` | Performance testing | Core Web Vitals work |
| Project Playwright suite | Project-specific E2E coverage | CI/CD and regression testing |
| `scripts/milestone-validation-worker.sh` | Parent validation worker | — |
| `workflows/milestone-validation.md` | Validation workflow | — |
| `workflows/mission-orchestrator.md` | Mission orchestrator | — |
| `tools/browser/browser-automation.md` | Browser tool selection guide | — |
| `tools/browser/playwright.md` | Playwright reference | — |
