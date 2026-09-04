---
name: business
description: Company orchestration - accounting, finance, legal, marketing, operations, and sales agents
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
subagents:
  - company-runners
  - accounting
  - accounting-software
  - accounts-receipt-ocr
  - accounts-subscription-audit
  - marketing-sales
  - legal
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Business - Company Orchestration Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Orchestrate AI agents across company functions (HR, Accounting, Finance, Operations, Marketing)
- **Pattern**: Named runners per function, coordinated via pulse supervisor (t109)
- **Scripts**: `runner-helper.sh`, `mail-helper.sh`, `/pulse`, `/full-loop`
- **Accounting**: `business/accounting.md`; provider catalogue: `business/accounting-software.md`
- **Subagents**: `accounting.md`, `accounting-software.md`, `accounts-receipt-ocr.md`, `accounts-subscription-audit.md`, `marketing-sales.md`, `legal.md`
- **Runner configs**: `business/company-runners.md`

<!-- AI-CONTEXT-END -->

## Architecture

```text
Pulse supervisor (every 2 min, stateless)
├── Fetches GitHub state (issues, PRs)
├── Observes outcomes (stale PRs, failures)
├── Dispatches to available worker slots
└── Exits

Named Runners:
├── hiring-coordinator   — Recruitment pipeline
├── finance-reviewer     — Accounting, reconciliation, cash flow, and control review
├── ops-monitor          — Infrastructure monitoring
├── marketing-scheduler  — Campaign scheduling
└── support-triage       — Customer issue classification
```

**Flow**: Task arrives (issue/TODO/mailbox) → pulse dispatches to specialist or runner → worker executes the provider-neutral domain workflow → pulse observes outcomes → files improvement issues if patterns emerge.

## Guardrails

Inherited from `/full-loop` and worktree isolation:

- **Scope**: Path/tool whitelists per runner via AGENTS.md
- **Audit**: Git commits and PR history
- **Rollback**: Worktree isolation — each runner works in its own worktree
- **Judgment**: `/full-loop` decides stop/retry/escalate

Accounting, finance, and legal runners require dedicated worktrees + PR review gates. Accounting work follows `business/accounting.md`; select integrations through `business/accounting-software.md`, and never post entries, make payments, or file returns without the required approval and read-back verification.

## Setting Up Runners

Create via `runner-helper.sh`. Each runner gets a personality file at `~/.aidevops/.agent-workspace/runners/<name>/AGENTS.md`. Full templates and bootstrap script: `business/company-runners.md`.

```bash
runner-helper.sh create hiring-coordinator \
  --description "Recruitment - job posts, screening, scheduling" --model sonnet
runner-helper.sh create finance-reviewer \
  --description "Accounting review - reconciliation, controls, reporting" --model sonnet
runner-helper.sh create ops-monitor \
  --description "Infrastructure - uptime, deploys, incidents" --model haiku

runner-helper.sh list                                          # Show all runners
runner-helper.sh run hiring-coordinator "Review latest 3 applications"  # Manual dispatch
```

Pulse handles dispatch automatically. For manual one-off tasks, use `/full-loop` directly.

## Cross-Function Workflows

Multi-department tasks use chained GitHub issues. Pulse routes by label:

```bash
# New hire onboarding (3 departments)
gh issue create --repo <owner/repo> --title "Onboard: Confirm offer" --label "hiring"
gh issue create --repo <owner/repo> --title "Onboard: Setup payroll" --label "finance"
gh issue create --repo <owner/repo> --title "Onboard: Provision accounts" --label "ops"
```

Sequenced single-department work (e.g., monthly close) uses multiple issues with the same label — pulse processes in order.

## Pre-flight Questions

1. Which functions need autonomous agents vs. human-triggered workflows?
2. Escalation path when agent encounters out-of-scope work?
3. Budget and rate limits per function?
4. Which operations require human approval?
5. How are cross-function handoffs tracked and audited?
6. For accounting work, which entity, period, currency, provider, account alias, and approval authority apply?
