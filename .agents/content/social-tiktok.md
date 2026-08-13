---
description: Approval-bound TikTok publishing capability and identity gates
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# TikTok Publishing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Route**: approval-bound outbound queue only
- **Supported intent**: one selected-account video post with approved caption and
  opaque media reference
- **Required gates**: official transport, exact account identity, product write
  authority, approved immutable intent, and immediate identity recheck
- **Default state**: catalogued/deployed but unavailable without operator-configured
  official credentials and transport

<!-- AI-CONTEXT-END -->

The adapter never uses browser automation, cookies, or a personal-account
workaround. It receives no credential values from the queue. Operators provision
any official token outside git through `aidevops secret set`; account scopes,
app review, media rights, disclosure requirements, and product eligibility stay
runtime gates.

The queue binds every request to one operation ID for idempotency. Identity must
match the approved account before a publish request. A stable accepted publish ID
with an ambiguous result is recorded as `unknown` and must reconcile before any
operator-approved follow-up; it is never blindly replayed. Receipts, diagnostics,
and test fixtures retain opaque IDs and failure classes only, not captions,
media, or credentials.

Unsupported: comments, messages, likes, follows, browser/persona automation,
and any account or media type not explicitly available through the official
operator-configured transport.
