---
description: Rename this session
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Rename this session to: $ARGUMENTS

Use the session-rename tool to update the session title. Preserve the first
meaningful title as the stable overall purpose. Later phases should update only
the trailing current context and must not replace that purpose.

Set `replace_purpose: true` only when the user explicitly asks to repurpose the
whole session, including this `/rename` command.

For issue/PR work, keep the work item at the beginning and include the issue/PR title or a recognizable title-based summary: `Issue #123: Fix dispatch title prefix` or `PR #456: Refresh auth workflow tests`.

For generic follow-up work, preserve the source title and add the action at the end when useful: `PR #456: Refresh auth workflow tests — Current: review thread`, not just `PR #456: review-thread response`.

Do not impose an arbitrary length limit; prefer a title that is meaningfully distinguishable in the UI. Keep the automatically appended `· AIDevOps x.y.z` suffix.
