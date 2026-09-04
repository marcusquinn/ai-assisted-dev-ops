---
name: chromium-debug-use
description: Attach to a user's already-open Chromium-family browser for live inspection and light interaction after explicit local approval
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Chromium Debug Use

Read `tools/browser/chromium-debug-use.md` first.

## Use This Skill When

The user wants to inspect or lightly interact with something already open in a Chromium-family browser (Chrome, Brave, Edge, Vivaldi, Chromium) before committing to a heavier automation tool.

## Workflow

1. Confirm explicit, user-approved live-session investigation.
2. If the debug port is not yet open, have the user launch with the flag from `tools/browser/chromium-debug-use.md`.
3. Use `.agents/scripts/chromium-debug-use-helper.sh version` and `list` to confirm access.
4. Prefer `snapshot`, `html`, and `eval` to understand the page before using `click`, `type`, `navigate`, or `screenshot`.
5. Once the flow is understood, hand off to the best-fit longer-term tool:
   - `tools/browser/playwright.md` — repeatable isolated automation
   - `tools/browser/dev-browser.md` — aidevops-managed persistent profile
   - `tools/browser/playwright.md` — official extension mode for selected tabs in the user's normal browser
   - `tools/browser/chrome-devtools.md` — performance, network, and console inspection

## Safety

- Local-only and temporary; the user must have enabled the debug path for this investigation.
- Prefer loopback endpoints and temporary profiles.
- Do not use this path for unrelated tabs or long-lived background control.

## Commands

```bash
.agents/scripts/chromium-debug-use-helper.sh version
.agents/scripts/chromium-debug-use-helper.sh list
.agents/scripts/chromium-debug-use-helper.sh snapshot <target>
.agents/scripts/chromium-debug-use-helper.sh html <target> [selector]
.agents/scripts/chromium-debug-use-helper.sh eval <target> "document.title"
.agents/scripts/chromium-debug-use-helper.sh click <target> "button.submit"
.agents/scripts/chromium-debug-use-helper.sh type <target> "hello world"
.agents/scripts/chromium-debug-use-helper.sh screenshot <target> /tmp/page.png
```

Use `--browser-url http://127.0.0.1:9222` when the session is not on the default endpoint.
