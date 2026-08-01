<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Prescriptive Brief Format (tier:simple)

For reversible, low-consequence work with verified targets, an exact execution
contract, and no unresolved semantic, design, sequencing, compatibility, or
recovery decision. Multiple independent exact actions are allowed; counts alone
do not determine the tier.

## Format

Every finding/task that targets `tier:simple` MUST use one of these contracts.

### Existing-file replacement

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

### Complete new file

```markdown
### New file 1: {description}

**File:** `{exact/path/to/file.ext}`

**Full content:**
\`\`\`{language}
{complete file content with no TODOs, placeholders, or omitted branches}
\`\`\`

**Verification:**
\`\`\`bash
{focused command that prints PASS or FAIL}
\`\`\`
```

### Deterministic non-content operation

```markdown
### Exact transform 1: {rename | move | delete | generated transform}

**Exact transform:** `{complete source → destination/action with no choice left}`

**Verification:**
\`\`\`bash
{focused command that prints PASS or FAIL}
\`\`\`
```

## Rules for prescriptive content

1. **Context for uniqueness**: oldString must include enough surrounding lines to match exactly once in the file. A single changed line without context may match multiple locations.
2. **Preserve indentation**: Copy whitespace exactly. Tab/space mismatch causes Edit tool failures.
3. **One action per block**: Don't bundle unrelated changes into one contract. Write a separate replacement, full-content, or exact-transform block for each action.
4. **New files**: Provide complete file content, not a skeleton. Include imports, function signatures, and all boilerplate.
5. **Verification must be automated**: `grep`, `shellcheck`, `test -f`, `jq .`, etc. Never "verify visually" or "check manually".
6. **Done When is mandatory**: End every issue body with `### Done When` containing a concrete check (e.g., `shellcheck {file}` exits 0, PR merged, issue closed). Without this, a worker may stop after applying the edit without completing the delivery lifecycle.
7. **No consequence laundering**: Exact text does not make a trust-boundary,
   destructive, irreversible, or authority-gated change simple. Use the canonical
   decision order in `reference/task-taxonomy.md` first.
