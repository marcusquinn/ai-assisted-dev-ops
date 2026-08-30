---
id: no-glob-for-discovery
ttsr_trigger: mcp_glob|Glob tool|glob pattern
severity: warn
repeat_policy: after-gap
gap_turns: 5
tags: [efficiency, tools]
enabled: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Prefer faster file discovery methods over Glob:

- Use `git ls-files '<pattern>'` for git-tracked files (instant)
- Use `fd -e <ext>` or `fd -g '<pattern>'` for untracked/system files
- Use `rg --files -g '<pattern>'` for content + file list
- If `fd` is unavailable, use `rg --files -g '<pattern>'` or a scoped `git ls-files`; do not fall back to broad `find` or Glob-first discovery
- Only use Glob as a last resort when Bash is unavailable
