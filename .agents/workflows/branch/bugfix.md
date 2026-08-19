---
description: Bugfix worktree ref - non-urgent bug fixes
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Bugfix Worktree Ref

| Aspect | Value |
|--------|-------|
| **Worktree ref prefix** | `bugfix/` |
| **Commit** | `fix: description` |
| **Version** | Patch bump (1.0.0 → 1.0.1) |
| **Create linked worktree from** | `main` |
| **Examples** | `bugfix/login-timeout`, `bugfix/123-null-pointer` |

```bash
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add bugfix/{description}
# Then cd into the linked worktree path printed by the helper before editing.
```

## When to Use

- Non-urgent bug fixes (can wait for release cycle) or bugs found in dev/staging.
- **Not for** urgent production issues (use `hotfix/`).

## Rules

- **Verification**: Reproduce the reported failure through the existing product path and confirm the fix there. Add a focused regression test only under `reference/ci-gate-policy.md`; new test infrastructure requires user approval.
- **Scope**: Minimal changes only — no new features or refactoring.
- **Investigation**: See `workflows/bug-fixing.md`.

## Commit Format

```text
fix: resolve login timeout on slow connections

- Increase timeout from 5s to 30s
- Add retry logic with exponential backoff

Fixes #123
```
