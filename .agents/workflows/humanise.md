---
description: Apply the adaptable final Humanise pass to product-facing copy
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Apply the final Humanise pass to product-facing copy. An explicit invocation may process any supplied prose.

Text to humanise: $ARGUMENTS

## Quick Reference

- **Purpose**: Preserve brand voice while removing generic AI patterns from final copy
- **Patterns**: `content/humanise.md` (24 named patterns with triggers and fixes)
- **Upstream**: [blader/humanizer](https://github.com/blader/humanizer) · `humanise-update-helper.sh check`

## Process

1. Read `content/humanise.md` for the full pattern list
2. Load current project brand evidence and approved examples when present
3. Identify patterns diagnostically while preserving facts, terminology, typography, and layout
4. Rewrite the final copy; add a review note only when a claim, meaning, or brand decision needs attention

## Usage

```text
/humanise [paste text here]
/humanise path/to/content.md
```

## Output Format

```text
[The rewritten text]

[Only when needed: Review note — claim, meaning, or brand decision requiring attention]
```
