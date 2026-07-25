<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Prescriptive Brief Format (tier:simple)

For bounded changes with exact code blocks and no unresolved design, interpretation, or recovery decisions. The worker executes the interface verbatim and verifies it.

## Format

Every finding/task that targets `tier:simple` MUST include this structure:

```markdown
### Edit 1: {description}

**File:** `{exact/path/to/file.ext}`

**oldString:**
\`\`\`{language}
{exact multi-line content to find — include 2-3 surrounding context lines for unique matching}
\`\`\`

**newString:**
\`\`\`{language}
{exact replacement content — same surrounding context, changed lines in the middle}
\`\`\`

**Verification:**
\`\`\`bash
{one-liner that prints PASS or FAIL}
\`\`\`
```

## Rules for prescriptive content

1. **Context for uniqueness**: oldString must include enough surrounding lines to match exactly once in the file. A single changed line without context may match multiple locations.
2. **Preserve indentation**: Copy whitespace exactly. Tab/space mismatch causes Edit tool failures.
3. **One edit per finding**: Don't bundle multiple changes into a single oldString/newString. If a task requires 3 edits to 3 locations, write 3 separate edit blocks.
4. **New files**: Provide complete file content, not a skeleton. Include imports, function signatures, and all boilerplate.
5. **Verification must be automated**: `grep`, `shellcheck`, `test -f`, `jq .`, etc. Never "verify visually" or "check manually".
6. **Done When is mandatory**: End every issue body with `### Done When` containing a concrete check (e.g., `shellcheck {file}` exits 0, PR merged, issue closed). Without this, a worker may stop after applying the edit without completing the delivery lifecycle.
