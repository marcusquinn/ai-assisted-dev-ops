---
description: Best practices for AI-assisted coding
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AI-Assisted Coding Best Practices

<!-- AI-CONTEXT-START -->

## Quick Reference

- **SC2155**: Separate `local var` and `var=$(command)`
- **S7679**: Never use `$1` directly — assign to named locals
- **S1192**: `readonly CONSTANT` for strings used 3+ times
- **S1481**: Remove unused variables or enhance functionality
- **Explicit returns**: Every function must end with `return 0` or error code
- **Pre/post**: Run `.agents/scripts/linters-local.sh` before and after changes
- **Targets**: SonarCloud <50 issues, 0 critical violations, 100% feature preservation

<!-- AI-CONTEXT-END -->

> **IMPORTANT**: Supplementary to [AGENTS.md](../../AGENTS.md). For conflicts, AGENTS.md takes precedence.

## Shell Script Standards (MANDATORY)

Required for SonarCloud/CodeFactor/Codacy compliance. Full rule reference: `code-standards.md`.

```bash
# Function structure — local params, explicit return
function_name() {
    local param1="$1"
    local param2="$2"
    # logic
    return 0
}

# SC2155: separate declaration from command substitution
local variable_name
variable_name=$(command_here)

# S1192: constant for strings used 3+ times
readonly CONTENT_TYPE_JSON="Content-Type: application/json"
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"
```

**S1481 (unused variables):** Prefer enhancing functionality over deleting — the variable often signals missing logic.

## Quality Tools

- `.agents/scripts/linters-local.sh` — run before and after changes
- `fix-content-type.sh`, `fix-auth-headers.sh`, `fix-error-messages.sh` — targeted fixers
- `coderabbit-cli.sh review`, `codacy-cli.sh analyze`, `sonarscanner-cli.sh analyze`

## Runtime Behaviour Patterns

Patterns that cause silent failures, infinite loops, and race conditions. Static analysis cannot catch these.

**Prevention rule:** Before implementing any pattern below, enumerate the complete state space — every possible state, event, and status value including errors. Implement handlers for all of them before writing the happy path.

### Runtime Evidence Signals

Use an existing app, staging, sandbox, or integration path. These signals do not
by themselves justify creating a new test harness.

| Pattern | Risk | Required runtime evidence |
|---------|------|-----------------|
| `switch`/`case` on status/state | Missing entry states | Trigger each state |
| `while true` / unbounded loops | Infinite loop | Verify termination |
| `setTimeout`/`setInterval` | Timer leak | Verify cleanup |
| Payment/checkout flows | Duplicate charge | Full payment flow |
| Auth token refresh | Race condition | Concurrent requests |
| Webhook handlers | Missing event types | Send each event type |
| Database migrations | Irreversible | Exercise on staging first |

Full patterns and code examples: [`runtime-patterns.md`](runtime-patterns.md)

**Key rules:**

- **State machines**: Handle all possible states with explicit defaults. Guard transitions to prevent double-processing.
- **Polling**: Every loop must have four termination conditions — success, timeout, terminal failure, max iterations.
- **Backoff**: Use exponential backoff for long-running polls to avoid hammering APIs.
- **Quiescence**: For UI polling, wait for stability over a duration, not a single passing check.
