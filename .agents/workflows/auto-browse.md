---
description: Auto-browse workflow — learn, optimize, and graduate repeatable browser operations and web data-mining workflows
agent: Build+
mode: subagent
model: standard
tools:
  read: true
  write: true
  edit: true
  bash: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Auto-browse Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Convert authorized browser operations and web data-mining tasks into reliable, lower-cost repeatable workflows.
- **Command**: `/auto-browse [instruction]`.
- **Private state**: `~/.aidevops/.agent-workspace/auto-browse/<workflow-id>/`.
- **Private promoted agents**: prefer `~/.aidevops/agents/custom/auto-browse/` after user review; keep raw run traces in the private state folder.
- **Shareable artifacts**: sanitized plans only under `todo/auto-browse/<slug>/` or `todo/tasks/`.
- **Core rule**: discover with high-agency browser tools only as needed, then graduate the cheapest reliable artifact.

<!-- AI-CONTEXT-END -->

## Step 1: Resolve Invocation

```text
if $ARGUMENTS is empty:                 → Intake Mode
elif $ARGUMENTS starts with "--review":  → Review Existing Private Run
elif $ARGUMENTS starts with "--plan":    → Sanitized Shareable Plan Mode
else:                                    → Objective Mode
```

### Intake Mode

Ask only what materially affects safety or tool choice:

1. Target site(s) or app(s).
2. Goal and desired output.
3. Authorization basis: owned account, client-approved, public data, test/staging, or other.
4. Allowed actions: view, download, edit profile, submit forms, post/comment/message, purchase/pay, admin/destructive.
5. Final-submit policy: stop before final submit/payment/post, or pre-approved routine with explicit limits.
6. Auth/session plan: existing browser session, aidevops-managed profile, cookies/storage state, official API, or user will log in manually.
7. Persistence need: disposable, sandbox, persistent, warm, or containerized profile.
8. Proxy/VPN/geo need and authorization.
9. Data scope, privacy constraints, and output format.
10. Verification criteria and whether the result should become a private workflow or sanitized repo plan.

Summarize the inferred objective, safety policy, storage location, and first tool choice before acting. In headless mode, proceed only when the instruction already contains enough context; otherwise produce a blocked intake summary listing missing fields.

## Step 2: Safety Gate

Stop for explicit confirmation before:

- creating accounts, identities, or profiles on external services;
- posting, commenting, messaging, reacting, following, or publishing content unless the routine and exact limits are pre-approved;
- final submit on legal, compliance, financial, government, HR, or client-impacting forms;
- payments, purchases, subscriptions, checkouts, or saved-payment changes;
- destructive/admin changes, deletion, permission changes, or data mutation beyond stated scope;
- anti-detect, proxy, VPN, geo-routing, CAPTCHA solver, or profile-rotation use for a target;
- extracting personal/private data beyond the stated scope.

Use secure references for credentials (`aidevops secret`, gopass, or documented credential refs). Never write credential values, cookies, bearer tokens, private client names, or private local paths into repo artifacts or chat.

## Step 3: Choose Minimum-Agency Tool

Use the cheapest viable level first, escalating only when evidence shows the cheaper path failed.

| Level | Use first when | Tools/docs |
|-------|----------------|------------|
| Fetch/API/static parse | Public/static pages, obvious JSON, no login | `webfetch`, shell fetches only for trusted URLs, parsers |
| Authenticated API discovery | Dashboard data, hidden XHR, export endpoints | `curl-copy.md`, `sweet-cookie.md`, `chrome-devtools.md` |
| Crawler/extractor | Many pages, sitemap/docs, structured content | `crawl4ai.md`, `watercrawl.md`, `seo/site-crawler.md` |
| Deterministic browser | Known flow, forms, downloads, repeatable UI; standalone Brave preferred | `playwright.md`, `playwright-cli.md`, `agent-browser.md` |
| Persistent profile | Recurring logged-in workflows | `dev-browser.md`, `browser-profiles.md` |
| Interactive existing browser | User is available, has a live session, and approves selected tabs or inspection | `playwright.md` extension mode, `chromium-debug-use.md` |
| High-agency discovery | Dynamic/fuzzy/visual flows where selectors fail | `stagehand.md`, `browser-use.md` (CLI 3.0), `skyvern.md` |
| Authorized stealth/profile stack | Legitimate profile/proxy/geo isolation need | `anti-detect-browser.md`, `proxy-integration.md` |

Prefer ARIA snapshots and DOM/text extraction over screenshots. Use screenshots for visual evidence only and obey screenshot size limits.

## Step 4: Create Private Run State

For private workflow execution, create or reuse:

```text
~/.aidevops/.agent-workspace/auto-browse/<workflow-id>/
├── objective.md
├── constraints.md
├── strategy.md
├── runs.tsv
├── profile-policy.md
├── credentials-needed.md
├── traces/
├── screenshots/
├── downloads/
├── helpers/
├── generated-agent.md
└── verification.md
```

Use `.agents/templates/auto-browse-strategy-template.md` and `.agents/templates/auto-browse-profile-policy-template.md` for the first two reusable files. Do not create repo `todo/` files for account-specific content.

For generalized shareable plans, create only sanitized artifacts:

```text
todo/auto-browse/<slug>/
├── brief.md
├── generalized-strategy.md
└── implementation-plan.md
```

## Step 5: Run Learning Loop

Each iteration:

1. Read `strategy.md` and the current safety policy.
2. For repeatable capture/data-mining work, run `aidevops reach doctor` and
   `aidevops reach route --objective "<sanitized objective>" --format json` as a
   reusable preflight before high-agency browser discovery.
3. Pick the minimum-agency tool for this attempt, respecting route budgets,
   headed/headless mode, offload guidance, and audit refs.
4. Run the attempt with rate limits and scoped authorization.
5. Capture evidence: command/tool, runtime, result, failures, screenshots/traces/download paths where safe.
6. Inspect network/DOM/output for cheaper deterministic paths.
7. Append `runs.tsv` with success, runtime, browser steps, tool calls, token/cost estimate, fragility, and discovered path.
8. Update `strategy.md` with what to keep, stop doing, or try next.

Stop after 3–5 iterations, when the task succeeds twice without material improvement, or when blocked by a safety gate or missing credential/authorization.

## Step 6: Graduate

Graduate the lowest-agency reliable artifact:

| Discovery | Graduate to |
|-----------|-------------|
| Stable public/official endpoint | API recipe + helper/parser |
| Static or crawlable content | Crawl4AI/WaterCrawl/site-crawler schema |
| Stable UI selectors | Playwright/agent-browser script |
| Recurring logged-in workflow | Private custom agent + profile policy |
| Fuzzy UI only | Stagehand/browser-use CLI 3.0/Skyvern-backed private agent with fallback notes |
| Framework-generalizable pattern | Sanitized `todo/auto-browse/...` plan or task brief |

Promoted private workflow agents should be written for user review before hot-loading:

```text
~/.aidevops/agents/custom/auto-browse/<workflow-slug>.md
```

Raw traces, cookies, storage state, downloads, and account-specific notes remain in the private run folder.

## Step 7: Verify

Before declaring the workflow reusable:

- Run a fresh minimal verification path.
- Confirm it respects the safety gate and stops before final submit/payment/post unless pre-approved.
- Confirm private artifacts are outside the repo.
- Confirm any `todo/` artifact is sanitized.
- Record verification in `verification.md` with command/tool evidence, not intent.

## Subagent Roles

Role contracts live in `.agents/tools/browser/auto-browse-subagents.md`. Dedicated runtime agents can be added later; until then, the auto-browse workflow should explicitly switch between these roles or dispatch focused prompts with that file as context:

- **intake** — gathers target, authorization, action scope, persistence, proxy/container needs, and verification.
- **router** — chooses the minimum-agency tool and escalation path.
- **explorer** — discovers UI flows, selectors, network calls, auth requirements, and download behavior.
- **data-miner** — optimizes extraction with APIs, fetches, crawlers, parsers, and schemas.
- **operator** — executes authorized login, navigation, profile edits, forms, uploads/downloads, and posting workflows.
- **profile-manager** — manages profile class, cookies/storage state, proxy/VPN/container metadata, expiry, and cleanup.
- **safety-gate** — blocks or confirms high-impact actions.
- **graduator** — writes private agents/helpers or sanitized repo briefs.
- **verifier** — proves fresh-run reliability and records evidence.

## Related

- `.agents/tools/browser/auto-browse.md`
- `.agents/tools/browser/auto-browse-subagents.md`
- `.agents/tools/browser/browser-automation.md`
- `.agents/templates/auto-browse-strategy-template.md`
- `.agents/templates/auto-browse-profile-policy-template.md`
- `.agents/templates/auto-browse-workflow-agent-template.md`
