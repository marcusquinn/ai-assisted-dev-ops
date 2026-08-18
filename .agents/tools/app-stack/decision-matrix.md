---
description: App-stack decision matrix for websites, web apps, desktop apps, mobile apps, and extensions
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# App Stack Decision Matrix

## First decision: site or app?

| Question | Default |
|----------|---------|
| Editors need pages, posts, media library, roles, revisions, forms, SEO plugins, or routine CMS ops? | WordPress |
| Plain marketing/docs site with a few pages, no editor workflow, and no repeated layout scale? | No-build static HTML/CSS/JS |
| Many repeated layouts, content collections, or generated pages without editor workflow? | Static generator after a decision task |
| Authenticated product, dashboard, workflow, or data-heavy UX? | TypeScript monorepo app |

## Application defaults

| Surface | Default | Use when |
|---------|---------|----------|
| Web | React/Next | Main product UX, dashboards, authenticated apps, SSR/SEO where useful |
| API | TypeScript package/API app | Shared validation, typed clients, server-side auth, workflow orchestration |
| Database | Postgres + Drizzle | Durable relational data, RLS, migrations, shared schema typing |
| Desktop | Choose by rendering model | Electron for Chromium/web reuse; Tauri for a lighter webview shell; GPUI for Rust-native GPU-rendered custom UI; platform-native for maximum OS integration |
| Mobile | Expo/React Native | Shared TypeScript product logic and cross-platform iteration |
| Extension | WXT | Cross-browser extension with typed entrypoints and modern build tooling |
| Local-first | PGlite where Postgres schema reuse matters | Desktop/extension CRUD cache or offline-first app slice |

## Escalation rules

- Do not add a framework to a plain static site until maintenance pain is evident.
- Do not add local-first sync until offline/collaboration needs are explicit.
- Do not add multi-tenant complexity until workspace/account isolation is required.
- Do not pick Tauri only for bundle-size aesthetics if Chromium/DevTools/browser integration matters.
- Do not pick GPUI only from speed claims; prototype the critical UI path and account for its pre-1.0 API stability and smaller ecosystem.
- Do not model app-specific business objects before the kernel tables and workspace boundary are clear.

## Verification before committing to a stack

- State the primary user workflow and editing model.
- Identify deployment target, data ownership, offline needs, and collaboration needs.
- Identify which surfaces are required now versus later.
- Link the decision to existing repo files or planned files.
- Document rejected alternatives and the trigger that would reopen the decision.
