---
description: Bug fixing workflow for AI assistants
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

# Bug Fixing Workflow

## 1. Understand the Bug

| Question | Why |
|----------|-----|
| Expected vs actual behavior | Defines goal and problem |
| Steps to reproduce | Enables testing |
| Impact and scope | Prioritizes fix |
| Root cause | Prevents symptom-only fixes |

Identify root cause before writing code. Document findings in the commit message.

## 2. Fix

- Minimal changes only — no new features, no refactoring
- Maintain backward compatibility
- Comment explaining *why* the fix works
- Verify the exact failure through its existing production-facing path, reproduction, logs, or framework diagnostics
- Add focused regression coverage only when requested, required by acceptance/repository policy or a named security, destructive-operation, portability, or contract risk, or when it is the lowest-cost way to resolve material uncertainty; never invent test infrastructure without approval

## 3. Verify

- [ ] Bug is fixed, no regression in related functionality
- [ ] The real reproduction or affected product path now works and standard logs show no related failure
- [ ] Applicable existing targeted tests and affected-package quality checks pass
- [ ] Latest and minimum supported versions are checked when the reported failure or compatibility contract requires them

```bash
# Existing project-specific check when applicable, then changed-file quality gates
~/.aidevops/agents/scripts/linters-local.sh --changed
```

Do not run a full-repository gate for generic completion evidence. Broaden only
when the fix changes shared config, root tooling, the dependency graph,
cross-package contracts, or release infrastructure.

**Frontend bugs (CRITICAL):** HTTP 200 does NOT verify frontend fixes — server returns 200 even when React crashes client-side. Use browser screenshot via `dev-browser-helper.sh start`. See `tools/ui/frontend-debugging.md`.

## 4. Commit and Document

Conventional commit with issue reference:

```bash
git commit -m "fix(scope): brief description (#NNN)

- Root cause: what was wrong
- Fix: how this resolves it"
```

Update CHANGELOG (`## [Unreleased] → ### Fixed`) and README/docs if fix affects user-facing behavior.

## 5. Version Increment

| Increment | When |
|-----------|------|
| **PATCH** | Most bug fixes (no API/behavior change) |
| **MINOR** | Fix introduces new behavior or deprecates old |
| **MAJOR** | Fix requires breaking changes |

Only bump version after fix is confirmed working. Use `version-manager.sh release patch` for aidevops releases.

## 6. Hotfix (Critical Production Bugs)

For bugs requiring immediate release, create a safe linked worktree from the latest tag:

```bash
git tag -l "v*" --sort=-v:refname
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add hotfix/v{VERSION} --base v{LATEST_TAG}
# Critical: cd into the linked worktree path printed by the helper before editing;
# otherwise commits land in the canonical checkout and can disrupt active agents.
# Apply minimal fix, bump PATCH, commit, tag, push
# Merge back to main after release
```

Standard bugs use the normal worktree + PR flow via `/full-loop`.

---

## Common Bug Patterns

| Type | Fix Strategy |
|------|-------------|
| **Null/Undefined** | Safe access with fallback: `user?.name ?? 'Unknown'` |
| **Race Conditions** | async/await, locks, initialization order |
| **Memory Leaks** | Clean up listeners, clear timers, release references |
| **API/Network** | Error handling, retries with backoff, timeouts, response validation |
| **Security** | Validate inputs, escape outputs, parameterized queries, check permissions |

---

## Completion Checklist

- [ ] Root cause identified and documented in commit
- [ ] Fix is minimal and focused — no unrelated changes
- [ ] Reported failure is verified through the real reproduction/path; applicable existing tests pass
- [ ] Changed-file/affected quality checks pass (`linters-local.sh --changed` for aidevops)
- [ ] CHANGELOG updated, docs updated if user-facing
