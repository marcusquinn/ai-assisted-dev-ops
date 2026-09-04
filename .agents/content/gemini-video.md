---
description: Generate and download videos through an authorized Gemini account using a persistent Brave profile controlled by Playwright
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

# Gemini Video

Read `content/gemini-media-browser.md` and follow its account, browser,
allowance, safety, and delivery contract.

Use modality `video`. Detect the available video model and controls from the
authenticated UI rather than hard-coding a plan entitlement. Accept normal
provider-downloaded MP4, WebM, or MOV assets. Discover download support,
generation duration, and quota units from the live UI.

Video jobs can be asynchronous: use bounded polling, preserve the browser
session on timeout, and report a recoverable pending state instead of
resubmitting. Success requires the requested video in
`~/Downloads/Gemini/<account-alias>/Videos/`, its SHA-256 sidecar, and an
evidence-qualified allowance report.
