---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# Conversation Starter Prompts

Shared prompts for consistent Build+ session opening.

## Inside Git Repository

On session start: check `git branch --show-current`. Run `memory-helper.sh recall --recent --limit 5` — if results, summarize actionable lessons only (no raw dump).

> What are you working on?
>
> **Note** *(on `main` branch)*: For file changes, I'll check for existing branches before proceeding.
>
> **Planning & Analysis** (Build+ deliberation mode)
> 1. Architecture Analysis
> 2. Code Review (`workflows/code-audit-remote.md`)
> 3. Documentation Review
>
> **Implementation** (Build+)
> 1. Feature Development (`workflows/feature-development.md`, `workflows/branch/feature.md`)
> 2. Bug Fixing (`workflows/bug-fixing.md`, `workflows/branch/bugfix.md`)
> 3. Hotfix (`workflows/branch/hotfix.md`)
> 4. Refactoring (`workflows/branch/refactor.md`)
> 5. Preflight Checks (`workflows/preflight.md`)
> 6. Pull/Merge Request (`workflows/pr.md`)
> 7. Release (`workflows/release.md`)
> 8. Postflight Checks (`workflows/postflight.md`)
> 9. Work on Issue (paste GitHub/GitLab/Gitea issue URL)
> 10. Something else (describe)

For implementation tasks (1-4, 9-10): read `workflows/git-workflow.md` first (branch creation, issue URL handling, fork detection), then the relevant workflow subagent.

## Outside Git Repository

> Where are you working?
>
> 1. Local project (provide path)
> 2. Remote services — which service?
>    1. 101domains (`services/hosting/101domains.md`)
>    2. Closte — legacy operations only (`services/hosting/closte.md`)
>    3. Cloudflare (`services/hosting/cloudflare.md`)
>    4. Cloudron (`services/hosting/cloudron.md`)
>    5. Hetzner (`services/hosting/hetzner.md`)
>    6. Hostinger (`services/hosting/hostinger.md`)
>    7. QuickFile (`services/accounting/quickfile.md`)
>    8. SES (`services/email/ses.md`)
>    9. Spaceship (`services/hosting/spaceship.md`)

After selection, read the relevant service subagent.
