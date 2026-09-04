---
description: Generate and download music through an authorized Gemini account using a persistent Brave profile controlled by Playwright
mode: subagent
model: standard
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Gemini Music

Read `content/gemini-media-browser.md` and follow its account, browser,
allowance, safety, and delivery contract.

Use modality `music`. Detect the available Lyria tier, duration, and controls
from the authenticated UI rather than assuming entitlement. Prefer MP3 for
audio delivery and preserve MP4 when the user requests the generated video
form. Do not infer that a free tier has unlimited allowance.

Success requires the requested track in
`~/Downloads/Gemini/<account-alias>/Music/`, its SHA-256 sidecar, and an
evidence-qualified allowance report.
