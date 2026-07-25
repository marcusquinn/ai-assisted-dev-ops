---
description: Official X API operations through the xurl CLI
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Xurl - Official X API Operations

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Use when**: reading/searching X, bookmarks, timelines, mentions, posting, replies, quotes, likes, reposts, follows, DMs, media uploads, or raw X API v2 calls.
- **Default tool**: `.agents/scripts/xurl-helper.sh` for guarded agent execution; use raw `xurl` only when the helper cannot express a safe read-only request.
- **Runtime model**: use the host agent's current model/provider connection (OpenCode xAI, Anthropic, etc.); `xurl` auth is only for X API access and is separate from model-provider auth.
- **Multi-account**: use `--app APP_NAME` for a specific X developer app/subscription context and `--username HANDLE` for a specific authenticated X account.
- **Auth check**: `xurl-helper.sh status` then `xurl-helper.sh whoami`; never read `~/.xurl`.
- **Write safety**: ad hoc writes require explicit user intent and `--confirm-write`; scheduled/shared-account post, reply, like, and bookmark actions use the owner-only approval-bound social operation queue.
- **Fallback**: `content/social-bird.md` can use browser cookies when official API access is unavailable, but `xurl` is preferred because it uses the official X API.

<!-- AI-CONTEXT-END -->

## Security Rules

- Never read, print, parse, summarize, upload, or send `~/.xurl` to model context.
- Never ask the user to paste X credentials, client IDs, client secrets, access tokens, refresh tokens, cookies, or bearer tokens into chat.
- Never run `xurl auth apps add` with inline secrets from an agent session. The user registers app credentials manually in their terminal.
- Never pass `--verbose`, `-v`, `--bearer-token`, `--consumer-key`, `--consumer-secret`, `--access-token`, `--token-secret`, `--client-id`, or `--client-secret`.
- Treat DMs, protected/private account data, bookmarks, and timelines as sensitive. For ad hoc requests, summarize minimally and do not persist raw output unless the user explicitly asks. An explicitly requested authorized corpus sync stores immutable response evidence under that corpus's policy.

## User Setup Boundary

The user completes one-time X developer app and OAuth setup outside the agent:

```bash
xurl auth apps add my-app --client-id YOUR_CLIENT_ID --client-secret YOUR_CLIENT_SECRET
xurl auth oauth2 --app my-app
xurl auth default my-app
xurl auth status
xurl whoami
```

If OAuth succeeds but commands return 401, tell the user to re-run OAuth with the same app that owns the client credentials: `xurl auth oauth2 --app my-app`, then `xurl auth default my-app`.

## Multiple Accounts and Subscriptions

`xurl` stores isolated app/account profiles, so aidevops can operate multiple brands, client accounts, developer apps, and X API subscription tiers from one machine without sharing secrets in chat.

- Use one app profile per X developer app or subscription tier: `--app client-a`, `--app brand-main`, `--app research-readonly`.
- Use `--username @handle` when the selected app has tokens for multiple X accounts.
- Always run `xurl-helper.sh whoami --app APP --username @handle` before a write action to confirm the account being used.
- Do not assume OpenCode xAI/Grok subscription identity is the same as the X account used by `xurl`; model subscriptions and X API subscriptions are separate permission planes.

Examples:

```bash
.agents/scripts/xurl-helper.sh whoami --app brand-main --username @brand
.agents/scripts/xurl-helper.sh search "from:brand launch" --app brand-main --username @brand --limit 10
.agents/scripts/xurl-helper.sh post "Approved post" --app brand-main --username @brand --confirm-write
```

## Guarded Helper

Use the helper for normal agent work:

```bash
.agents/scripts/xurl-helper.sh status
.agents/scripts/xurl-helper.sh whoami
.agents/scripts/xurl-helper.sh search "aidevops" --limit 10
.agents/scripts/xurl-helper.sh read 1234567890
.agents/scripts/xurl-helper.sh bookmarks --limit 20
.agents/scripts/xurl-helper.sh post "Draft approved by user" --confirm-write
.agents/scripts/xurl-helper.sh run -- /2/users/me
```

The helper rejects secret-bearing flags and verbose output, maps common read/write actions to `xurl`, and blocks write actions unless `--confirm-write` is present.

## Authorized Social Corpus Sync

Use the provider-neutral helper to collect one bounded official stream into a
catalog-resolved corpus:

```bash
.agents/scripts/knowledge-social-helper.sh sync-x \
  --alias personal:default --connection-id CONNECTION_ID \
  --account-id X_ACCOUNT_ID --stream authored --budget 10 \
  --media-policy metadata --app PROFILE --username HANDLE
```

The alias must grant `knowledge.write`. `connection-id` is an opaque local ID;
`account-id` is the stable X account ID expected from `whoami`. The adapter
rejects an account mismatch before collection and does not allow an existing
connection to be rebound to another account.

Supported streams are `authored`, `mentions`, `likes`, `bookmarks`, `followers`,
and `following`. Each stream owns an independent pagination cursor and
watermark. After initial backfill, authored and mentions use the official
`since_id` delta parameter. Streams without an official delta parameter report
`delta_unavailable` and record the coverage gap without issuing a page request.

`--budget` is a bounded request-cost allowance from 1 to 1000 units, not a retry
count. Terminal authorization, not-found, rate-limit, and provider failures
store credential-filtered immutable evidence but never advance the stream cursor.
Command output contains counts and failure classes rather than private provider
content.

Media policy `none` stores no media rows. `metadata` stores references and
content links only; the adapter never downloads media binaries. The provider
route is externally read-only: it can reach only guarded `whoami` and allowlisted
official raw-read endpoints, never posting or engagement commands.

Fixture and fake-executable tests verify pagination, resume, terminal failures,
credential rejection, and the guarded command route. They do not prove live X
access; live verification requires a separately configured `xurl` profile.

## Approval-Bound Scheduling and Shared Accounts

For personal or workspace corpora, use `knowledge-social-helper.sh` instead of a
bare confirmation flag when an action must be durable, scheduled, or auditable.
The alias must grant owner-only `knowledge.manage`; encrypted workspace members
with read/write grants cannot post as the shared account.

```bash
.agents/scripts/knowledge-social-helper.sh operation-create \
  --alias workspace:example --connection-id CONNECTION_ID \
  --account-id X_ACCOUNT_ID --action reply --target-id POST_ID \
  --body-file approved-reply.txt --scheduled-at EPOCH \
  --app PROFILE --username HANDLE

.agents/scripts/knowledge-social-helper.sh operation-approve \
  --alias workspace:example --operation-id OPERATION_ID --expires-at EPOCH

.agents/scripts/knowledge-social-helper.sh operations-run-due \
  --alias workspace:example --executor-id EXECUTOR_ID --limit 10
```

The body file must be owner-only mode 0600. Approval binds its digest plus the
action, stable account ID, target, app/account selectors, schedule, approver, and
expiry. The runner repeats `whoami` immediately before one mapped write and stores
only a content-free receipt. A provider timeout or non-zero response after that
boundary becomes `unknown` and is never retried automatically; use
`operation-reconcile` only after independently confirming `succeeded` or
`not-sent`.

`notifications-refresh`, `notifications-list`, and `notification-set` project
mentions/replies into the local `unread`, `seen`, `action-required`, `responded`,
and `dismissed` workflow. Operational state and local profile selectors are
excluded from encrypted workspace snapshots.

## Command Map

| Intent | Helper command |
| --- | --- |
| Auth status | `xurl-helper.sh status` |
| Current account | `xurl-helper.sh whoami` |
| Search posts | `xurl-helper.sh search "QUERY" --limit 10` |
| Read post | `xurl-helper.sh read POST_ID_OR_URL` |
| Timeline / mentions | `xurl-helper.sh timeline --limit 20` / `xurl-helper.sh mentions --limit 10` |
| Bookmarks / likes / DMs | `xurl-helper.sh bookmarks --limit 20` / `xurl-helper.sh likes --limit 20` / `xurl-helper.sh dms --limit 10` |
| User lookup | `xurl-helper.sh user @handle` |
| Ad hoc post / reply / quote | add `--confirm-write` after explicit user approval |
| Scheduled/shared post, reply, like, bookmark | use the approval-bound social operation queue |
| Raw read-only API | `xurl-helper.sh run -- /2/users/me` |

## Operating Workflow

1. Confirm the user requested X action and identify read-only vs write/destructive scope.
2. Run `xurl-helper.sh status`; if missing auth, stop and give setup steps without handling secrets.
3. For write actions, draft the exact text first unless the user already provided final copy.
4. Execute with `--confirm-write` only after explicit approval in the current conversation.
5. Return concise results: post ID/link, account acted as, query summary, or failure class. Do not dump raw JSON unless requested.

## OpenCode xAI Note

OpenCode's xAI/Grok provider connection can be used for reasoning by selecting that model in the runtime, but it does not replace X API OAuth. Keep model-provider auth and X API `xurl` auth separate so aidevops can run with any capable model while `xurl` owns X account permissions.
