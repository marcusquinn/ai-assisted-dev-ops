---
description: Milestone validation — verify milestone completion by running tests, build, linting, browser QA, and integration checks, then report results and create fix tasks on failure
mode: subagent
model: standard  # validation requires coordinated judgment, not architecture
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Milestone Validation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Validate a completed milestone meets its acceptance criteria before the mission advances
- **Script**: `scripts/milestone-validation-worker.sh`
- **Invoked by**: Mission orchestrator (Phase 4) after all milestone features complete
- **Output**: Pass/fail report; fix tasks created on failure

| File | Purpose |
|------|---------|
| `scripts/milestone-validation-worker.sh` | Validation runner |
| `workflows/mission-orchestrator.md` | Orchestrator that invokes validation |
| `tools/browser/browser-qa.md` | Browser QA subagent |
| `scripts/browser-qa-helper.sh` | Playwright-based visual testing CLI |
| `scripts/accessibility/playwright-contrast.mjs` | Contrast/accessibility checks |
| `templates/mission-template.md` | Mission state file format |
| `workflows/postflight.md` | Similar pattern for release validation |

<!-- AI-CONTEXT-END -->

## Role

You are a QA engineer. Run every check that could catch a regression, layout bug, broken link, or missing feature — then report clearly what passed and what failed. You are not implementing features; you are verifying them.

**Validation is pass/fail, not subjective.** Every check must have a clear criterion. "Looks good" is not a result. "All 5 pages render without console errors, all links return 2xx, hero image loads in <3s" is.

**Block quickly, diagnose fully.** On the first blocking failure, mark the milestone failed — but continue running remaining checks to collect the full failure set so the orchestrator can create targeted fix tasks.

**Use the cheapest tool that works.** `curl` + status codes for most checks. Playwright only for rendered output, JS-dependent content, or visual layout. Stagehand only when page structure is unknown.

## Lifecycle Position

```text
Features dispatched → Features complete → MILESTONE VALIDATION → Next milestone (or fix tasks)
```

Triggered when: all milestone features have status `completed` (PRs merged in Full mode, commits landed in POC mode), orchestrator sets milestone to `validating`, orchestrator dispatches this worker.

## What It Validates

### Automated Checks (Always Run)

| Check | What it does | Detected via |
|-------|-------------|--------------|
| **Dependencies** | Ensures deps are installed | `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod` |
| **Test suite** | Runs the project's test framework | `npm test`, `pytest`, `cargo test`, `go test` |
| **Build** | Verifies the project builds cleanly | `npm run build`, `cargo build`, `go build` |
| **Linter** | Runs project linting | `npm run lint`, `ruff`, `tsc --noEmit`, `shellcheck` |

### Framework Detection

| Signal | Framework | Test command | Build command |
|--------|-----------|-------------|---------------|
| `bun.lockb` / `bun.lock` | Bun | `bun test` | `bun run build` |
| `pnpm-lock.yaml` | pnpm | `pnpm test` | `pnpm run build` |
| `yarn.lock` | Yarn | `yarn test` | `yarn run build` |
| `package.json` | npm (fallback) | `npm test` | `npm run build` |
| `pyproject.toml` / `setup.py` | Python | `pytest` | — |
| `Cargo.toml` | Rust | `cargo test` | `cargo build` |
| `go.mod` | Go | `go test ./...` | `go build ./...` |
| `.agents/scripts/` | Shell (aidevops) | `shellcheck` | — |

### Browser QA (UI Milestones)

When validation criteria mention UI, pages, visual, layout, responsive, or milestone features include frontend components, run the browser QA pipeline via `scripts/browser-qa-helper.sh`:

| Check | What it does | Command |
|-------|-------------|---------|
| **Smoke test** | Console errors, network failures, basic rendering | `browser-qa-helper.sh smoke --url URL --pages "/ /about"` |
| **Screenshots** | Multi-viewport visual capture | `browser-qa-helper.sh screenshot --url URL --viewports desktop,mobile` |
| **Broken links** | Crawl internal links, verify 2xx responses | `browser-qa-helper.sh links --url URL --depth 2` |
| **Accessibility** | WCAG contrast, ARIA, heading hierarchy, labels | `browser-qa-helper.sh a11y --url URL --level AA` |
| **Full pipeline** | All of the above in sequence | `browser-qa-helper.sh run --url URL --pages "/ /about"` |

See `tools/browser/browser-qa.md` for severity mapping and content verification patterns.

### Optional Checks

| Check | When | Flag |
|-------|------|------|
| **Playwright browser tests** | UI milestones with existing test suite | `--browser-tests` |
| **Browser QA (visual testing)** | UI milestones, especially POC mode without test suite | `--browser-qa` |
| **Custom validation criteria** | Per-milestone criteria from mission file | Automatic (reads `**Validation:**` field) |

**Browser QA vs Browser Tests**: `--browser-tests` runs the project's own Playwright suite (requires `playwright.config.{ts,js}`). `--browser-qa` runs generic visual QA — screenshots, broken link detection, console error capture — without a test suite. Both can be used together.

## Usage

```bash
# Basic validation
~/.aidevops/agents/scripts/milestone-validation-worker.sh \
  ~/Git/myproject/todo/missions/m-20260227-abc123/mission.md 1

# With browser tests (project has playwright.config.ts)
~/.aidevops/agents/scripts/milestone-validation-worker.sh \
  ~/Git/myproject/todo/missions/m-20260227-abc123/mission.md 2 \
  --browser-tests --browser-url http://localhost:3000

# With browser QA (no test suite needed)
~/.aidevops/agents/scripts/milestone-validation-worker.sh \
  mission.md 2 --browser-qa --browser-url http://localhost:3000

# Both browser tests and browser QA
~/.aidevops/agents/scripts/milestone-validation-worker.sh \
  mission.md 2 --browser-tests --browser-qa --browser-url http://localhost:3000

# Browser QA with custom flows
~/.aidevops/agents/scripts/milestone-validation-worker.sh \
  mission.md 2 --browser-qa --browser-url http://localhost:3000 \
  --browser-qa-flows '["/", "/about", "/login"]'

# Report-only (don't update mission state)
~/.aidevops/agents/scripts/milestone-validation-worker.sh \
  mission.md 1 --report-only --verbose
```

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Validation passed — milestone is good to advance |
| `1` | Validation failed — issues found, fix tasks created |
| `2` | Configuration error — missing arguments, bad paths |
| `3` | Mission state error — milestone not ready for validation |

## Failure Handling

### Severity Classification

| Finding | Severity | Blocks Milestone? |
|---------|----------|-------------------|
| Build fails, tests crash | Critical | Yes |
| Page returns 5xx, blank page | Critical | Yes |
| Console error on load | Critical | Yes |
| Broken internal link (404) | Major | Yes |
| Layout break at required viewport | Major | Yes |
| Missing content from acceptance criteria | Major | Yes |
| Contrast ratio failure (AA) | Major | Yes (if a11y is in criteria) |
| Missing alt text | Minor | No (note in report) |
| Heading hierarchy skip | Minor | No (note in report) |
| Console warning (not error) | Minor | No (note in report) |

### On Failure

1. Milestone status set to `failed` in mission state file
2. Progress log entry appended with failure details
3. Fix tasks created (Full mode: GitHub issues; POC mode: logged)
4. Orchestrator re-dispatches fixes and re-validates

### Retry Logic

After `--max-retries` failures (default: 3) on the same milestone, the mission is paused and the user is notified.

```text
Attempt 1: Validate → Fail → Create fix tasks → Dispatch fixes
Attempt 2: Re-validate → Fail → Create fix tasks → Dispatch fixes
Attempt 3: Re-validate → Fail → PAUSE MISSION → Notify user
```

### Fix Task Format (Full Mode)

```markdown
## Milestone Validation Fix

**Mission:** `m-20260227-abc123`
**Milestone:** 2
**Failure:** Test suite (npm test): 3 tests failed in auth.test.ts

**Context:** Auto-created by milestone validation worker.
**What to fix:** Address the specific failure described above.
**Validation criteria:** Re-run milestone validation after fix.
```

Issues are labelled `bug` and `mission:{id}` for traceability.

## Scope vs Postflight

| Aspect | Milestone Validation | Postflight |
|--------|---------------------|------------|
| **Scope** | One milestone within a mission | One release of the entire project |
| **Trigger** | All milestone features complete | After git tag + GitHub release |
| **Checks** | Tests, build, lint, browser tests, browser QA | CI/CD, SonarCloud, security, secrets |
| **On failure** | Create fix tasks, re-validate | Rollback or hotfix release |
| **State** | Mission state file | Git tags, GitHub releases |

## Related

- `workflows/mission-orchestrator.md` — Invokes this worker at Phase 4
- `tools/browser/browser-qa.md` — Browser QA subagent (visual testing details)
- `scripts/browser-qa-helper.sh` — CLI for Playwright-based visual testing
- `tools/browser/browser-automation.md` — Browser tool selection guide
- `scripts/accessibility/playwright-contrast.mjs` — Contrast/accessibility checks
- `workflows/postflight.md` — Similar validation pattern for releases
- `workflows/preflight.md` — Pre-commit quality checks
- `scripts/commands/full-loop.md` — Worker execution per feature
- `scripts/browser-qa-worker.sh` — Browser QA shell wrapper
- `scripts/browser-qa/browser-qa.mjs` — Playwright QA engine
- `templates/mission-template.md` — Mission state file format
