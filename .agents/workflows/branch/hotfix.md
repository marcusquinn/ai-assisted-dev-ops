---
description: Hotfix worktree ref - urgent production fixes
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Hotfix Worktree Ref

<!-- AI-CONTEXT-START -->

| Aspect | Value |
|--------|-------|
| **Worktree ref prefix** | `hotfix/` |
| **Commit** | `fix: [HOTFIX] description` |
| **Version** | Patch bump (1.0.0 → 1.0.1) |
| **Create linked worktree from** | **Latest tag** (not `main`) — fix matches production, not unreleased changes |
| **Urgency** | Immediate; can bypass normal review if authorized |

```bash
git fetch --tags
latest_tag=$(git describe --tags --abbrev=0)
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add hotfix/{description} --base "$latest_tag"
# Then cd into the linked worktree path printed by the helper before editing.
```

<!-- AI-CONTEXT-END -->

## When to Use

- Critical production bugs, security vulnerabilities, data corruption, service outages

If it can wait for the normal release cycle, use `bugfix/` instead.

## Workflow

1. Apply the minimal fix only.
2. Verify immediately through the affected production-facing path and standard logs; run applicable existing required checks.
3. Fast-track review, or deploy directly if authorized.
4. Merge back to `main` via PR unless the user explicitly authorizes an emergency direct release.

### After Deployment

- [ ] Add focused regression protection now when acceptance/repository policy or a named security, destructive-operation, portability, or contract risk requires it; otherwise consider it after behaviour stabilises. Do not create test infrastructure without approval
- [ ] Document the incident
- [ ] Review how the issue escaped

## Examples

```bash
hotfix/critical-auth-bypass
hotfix/production-database-lock
hotfix/payment-processing-failure
```

```bash
fix: [HOTFIX] prevent authentication bypass

CRITICAL SECURITY FIX
- Add missing permission check
- Validate session token

Deploy immediately. Full audit to follow.
```
