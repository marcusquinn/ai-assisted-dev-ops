---
description: Structured escalation report for cascade tier dispatch — posted to issues when a worker fails and the task escalates to the next model tier
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Escalation Report Template

Workers post this structured report as an issue comment when they cannot complete a task. The next tier's worker receives this as context, avoiding redundant exploration.

## Template

```markdown
## Escalating from tier:{current_tier}

### Attempted

- {What files were read, what approaches were tried}
- {Specific code changes attempted, if any}
- {Tools used and their output}

### Failed because

- **{REASON_CODE}**: {description of why the attempt failed}
- **{REASON_CODE}**: {additional failure reason if applicable}

### Discovered (reusable by next tier)

- {File state findings — actual line numbers, current code structure}
- {Patterns found in codebase — which approach existing code follows}
- {Dependencies discovered — what calls what, what breaks if changed}
- {Test coverage — which tests exist, which would need updating}

### Partial work

- {Code committed? Branch name? Or "no code committed — changes were exploratory only"}
- {If partial code exists, describe what's done and what remains}

### Brief gaps

- {What was missing or unclear in the brief that blocked completion}
- {Stale references — file paths that don't match current state}
- {Ambiguities — decisions the brief didn't make that the worker couldn't resolve}
```

## Reason Codes

Use these structured codes so the autoresearch optimisation loop can categorise escalation patterns:

| Code | When to use |
|------|------------|
| `AMBIGUOUS_BRIEF` | Brief has multiple valid interpretations; worker couldn't determine which approach to take |
| `STALE_REFERENCES` | File paths, line numbers, or code patterns in the brief don't match the current codebase state |
| `JUDGMENT_NEEDED` | Multiple valid implementation approaches exist; choosing between them requires architectural understanding |
| `MULTI_FILE_COORDINATION` | Changes span multiple files with non-obvious dependencies; edits in one file require coordinated changes elsewhere |
| `ERROR_RECOVERY` | Worker hit an unexpected error (build failure, test failure, tool error) and couldn't determine how to recover |
| `TOOL_CHAIN_COMPLEXITY` | Task requires too many sequential tool operations for the model's planning capacity |
| `MISSING_CONTEXT` | Brief doesn't provide enough background about why the change is needed or how it fits into the broader system |

## Usage

### By workers (automatic)

Workers should post this report when:
1. They've exhausted their approaches and cannot produce a PR
2. They hit a blocker they can identify but cannot resolve
3. Their time/token budget is nearly exhausted with work still remaining

The report should be the **last action** before the worker exits. Post as an issue comment with `gh issue comment`.

### By the pulse (dispatch context)

When the pulse re-dispatches after an escalation, it should include in the dispatch prompt:

```text
Previous attempt at tier:{previous_tier} failed. Review the escalation report
on the issue for context on what was tried and where it got stuck. Do NOT
re-read files or re-try approaches already documented in the escalation report.
```

### By the autoresearch loop (feedback)

The optimisation pipeline parses escalation reports to:
1. Count frequency of each reason code across the corpus
2. Identify which brief template sections need improvement
3. Measure whether brief changes reduce escalation rates

## Examples

### tier:simple → tier:standard (standard worker receives prior context)

```markdown
## Escalating from tier:simple

### Attempted

- Read `src/auth/handler.ts:45-90` — found the authentication entry point
- Applied brief's code skeleton: added `validateToken()` call at line 60

### Failed because

- **STALE_REFERENCES**: Brief says "insert after line 60" but line 60 is now a
  comment block — the file was refactored since the brief was written (commit `abc1234`)
- **JUDGMENT_NEEDED**: Found 3 validation patterns in codebase (middleware at
  `src/middleware/auth.ts:12`, inline at `src/routes/api.ts:88`, decorator at
  `src/decorators/auth.ts:5`) — brief doesn't specify which to follow

### Discovered (reusable by next tier)

- Auth module refactored in commit `abc1234` — current entry point is `validateRequest()` at line 82
- Existing tests in `tests/auth.test.ts` use the middleware pattern (lines 15-45)
- `checkRole()` at `src/auth/roles.ts:22` expects a validated token, not a raw header
- No refresh token handling in current codebase — 3 call sites suggest it's needed

### Partial work

- No code committed — changes were exploratory only

### Brief gaps

- File path `src/auth/handler.ts:60` is stale → actual target: `:82`
- Missing: which validation pattern to follow (middleware vs inline vs decorator)
- Missing: whether to handle refresh tokens (3 call sites suggest yes)
```

### tier:standard → tier:thinking (thinking worker receives both reports)

```markdown
## Escalating from tier:standard

### Attempted

- Reviewed tier:simple escalation report — confirmed stale file references
- Read `src/auth/handler.ts` (full file) — understood the refactored structure
- Implemented middleware-pattern validation following `src/middleware/auth.ts`
- Tests pass locally but the integration test suite fails

### Failed because

- **MULTI_FILE_COORDINATION**: The auth middleware change requires updating the
  request type definition in `src/types/request.ts`, which is imported by 14 other
  files. Updating the type causes cascading type errors across the API layer.
- **ERROR_RECOVERY**: After fixing 8 of 14 type errors, discovered that
  `src/routes/admin.ts` uses a different auth pattern entirely (session-based,
  not token-based). Fixing it requires understanding which routes should use which
  auth strategy — this is an architectural decision.

### Discovered (reusable by next tier)

- The codebase has TWO auth strategies: token-based (API routes) and session-based (admin routes)
- `src/types/request.ts:AuthenticatedRequest` is the shared type — changing it affects both strategies
- Safe approach: create `TokenAuthRequest extends AuthenticatedRequest` for API routes only
- Admin routes (`src/routes/admin.ts`, `src/routes/admin-users.ts`) must NOT be touched
- All 14 affected files listed: [list of files]

### Partial work

- Branch `feature/gh-42-auth-validation` has 3 commits with working middleware + 8/14 type fixes
- Remaining: `src/routes/admin.ts`, `src/routes/admin-users.ts`, `src/routes/dashboard.ts`,
  `src/routes/settings.ts`, `src/routes/billing.ts`, `src/types/request.ts`

### Brief gaps

- Missing: the dual auth strategy architecture (token vs session)
- Missing: which routes use which strategy
- Missing: whether to create a new type or extend the existing one
```
