<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Standard Brief Format (tier:standard)

For tasks following established patterns with normal implementation judgment and recovery. Make the task implementation-ready with verified files, resolved boundaries, reference patterns, and focused verification. Provide skeletons when they reduce invention, not when they would fabricate an unresolved decision.

## Format

```markdown
### Context and Decisions

- {Resolved scope/behaviour decision}
- {Non-goal or compatibility boundary}
- {Material assumption and evidence}

### Files to Modify

- `EDIT: path/to/file.ts:45-60` — {what to change and why}
- `NEW: path/to/new-file.ts` — {purpose, model on `path/to/reference.ts`}

### Implementation Steps

1. Read `path/to/reference.ts` for the existing pattern
2. {Step with code skeleton:}

\`\`\`typescript
// Function signature and structure — worker fills in logic
export function handleAuth(req: Request): Response {
  // TODO: validate token using pattern from middleware/auth.ts:12
  // TODO: check role using checkRole() at roles.ts:22
}
\`\`\`

3. {Verification step}

### Done When

- `shellcheck .agents/scripts/{file}.sh` exits 0
- `gh pr view --json state` shows MERGED
- Issue closed with closing comment linking PR
```

## Key principles

- **Resolved skeletons, not false precision**: Provide function signatures and structure after boundaries are known; leave genuine design choices explicit
- **Reference patterns**: Point to existing code that demonstrates the pattern
- **Line ranges**: Use `file:line-line` format for clarity
- **Normal judgment**: Worker adapts established patterns and handles known errors/edge cases within the stated boundaries

## Recovery paths (mandatory)

Include a `### Done When` section to prevent indefinite exploration, and provide fallback searches for each file/function reference; workers stop on first miss without them.

For each implementation step:

```markdown
1. Read `.agents/scripts/pulse-wrapper.sh:4254` — the `auto_approve_maintainer_issues()` function
   - **If not found at that line:** `grep -n 'auto_approve_maintainer_issues' .agents/scripts/pulse-wrapper.sh`
   - **If function was renamed/removed:** check `git log --oneline -5 .agents/scripts/pulse-wrapper.sh`
```

For each file reference:

```markdown
- EDIT: `.agents/scripts/memory-pressure-monitor.sh:877-888`
  - Fallback: `grep -n 'cmd_daemon' .agents/scripts/memory-pressure-monitor.sh`
```
