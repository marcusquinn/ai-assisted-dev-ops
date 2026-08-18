---
name: app-stack
description: Opinionated app-stack selection for static sites, monorepos, desktop, mobile, extensions, and metadata-driven business apps
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# App Stack - Orchestrator

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Plain site**: no-build HTML/CSS/JS unless CMS or repeated-layout scale justifies more.
- **CMS/editorial site**: WordPress; see `tools/wordpress.md`.
- **Application**: TypeScript monorepo, React/Next web-first, Postgres + Drizzle + RLS.
- **Desktop**: choose Electron for web-platform reuse, Tauri for a lighter webview shell, or GPUI/native for Rust-native, GPU-rendered UI; benchmark the actual workload.
- **Mobile**: Expo/React Native unless native Swift/Kotlin constraints dominate.
- **Extension**: WXT; see `tools/ui/wxt.md`.

<!-- AI-CONTEXT-END -->

## Route by task

| Need | Read |
|------|------|
| Pick site/app platform | `app-stack/decision-matrix.md` |
| Build a no-build website starter | `app-stack/static-site-starter.md` |
| Define required/optional public pages, trust pages, schema, docs/API/MCP/CLI surfaces | `app-stack/public-site-surfaces.md` |
| Standardise user-facing record fields and relationships | `app-stack/standard-objects.md` |
| Design TypeScript monorepo app structure | `app-stack/monorepo-app-stack.md` |
| Choose/shape desktop framework | `app-stack/desktop-frameworks.md` |
| Model workspace tenancy/collaboration | `app-stack/workspace-model.md` |
| Design app database foundation | `app-stack/database-foundation.md` |
| Place schemas and migrations | `app-stack/migration-layout.md` |
| Standardise platform/kernel objects | `app-stack/platform-kernel.md` |
| Model change history, merges, and relationships | `app-stack/data-history-relationships.md` |
| Design background jobs, scheduled tasks, and operations | `app-stack/operations-jobs-scheduling.md` |
| Define API and service contracts | `app-stack/api-service-contracts.md` |
| Model identity and security lifecycle | `app-stack/identity-security-lifecycle.md` |
| Plan privacy, sync, scale, and test data | `app-stack/data-protection-sync-scale.md` |
| Choose standard app objects | `app-stack/standard-objects.md` |
| Design RBAC/capabilities | `app-stack/rbac-permissions.md` |
| Design workflows and automations | `app-stack/workflow-architecture.md` |
| Build metadata-driven entities/layouts/workflows | `app-stack/metadata-architecture.md` |
| Add encrypted/local-first collaboration | `app-stack/encrypted-collaboration.md` |
| Shape app/control-room UX shell | `app-stack/ux-shell-patterns.md` |

## Stack doctrine

Prefer boring, shared primitives that compound across apps:

1. Start web-first with TypeScript and React/Next for app UX.
2. Put reusable domain logic, database schema, UI, config, and API clients in packages.
3. Use Postgres + Drizzle as the canonical data model; add RLS from the first multi-user boundary.
4. Keep schema and migration ownership in `packages/db` for monorepos; generated SQL and metadata snapshots are versioned artifacts.
5. Treat metadata as product infrastructure: entity definitions, fields, layouts, views, ACL, workflows, labels, audit, jobs, import/export, API contracts, privacy, and notifications.
6. Use `Workspace` as the data container, permission boundary, AI context boundary, and collaboration scope.
7. Start from standard object packs: issues, labels/tags, users, teams, roles, content/pages, conversations/channels, calendar/CRM activities, files/folders, accounts, contacts, jobs/processes, quotes, invoices, payments, prices, and referrals.
8. Keep public surfaces explicit: `/about`, `/contact`, `/privacy`, `/terms`, docs, API, MCP, CLI, sitemap, schema, and support routes.
9. Keep web/CMS/site routing explicit: WordPress for editors; no-build static for plain sites; static generator only after repeated-layout/content scale proves it.

## Builder interpretation rules

When asked to build a new app or data architecture:

1. Start with `Workspace`, `packages/db`, RLS, users, teams, roles, labels, audit, files, and integrations.
2. Pick canonical object roots from `app-stack/standard-objects.md` before inventing domain tables.
3. Add the standard record field pack from `app-stack/standard-objects.md` before object-specific fields.
4. Use types, labels, views, and metadata before separate tables; split tables only for distinct validation, lifecycle, permissions, integrations, or indexes.
5. Add workflows as definitions plus runtime events/runs; do not hide state machines in UI-only code.
6. Preserve external sync handles for WebDAV, CalDAV, CardDAV, payment, accounting, and forge integrations.
7. Verify one complete path: object → permission → workflow → audit → import/export or sync.

Read order for full app/data design: `monorepo-app-stack.md` → `public-site-surfaces.md` → `workspace-model.md` → `database-foundation.md` → `platform-kernel.md` → `operations-jobs-scheduling.md` → `api-service-contracts.md` → `identity-security-lifecycle.md` → `data-protection-sync-scale.md` → `data-history-relationships.md` → `standard-objects.md` → `rbac-permissions.md` → `workflow-architecture.md` → `metadata-architecture.md` → `migration-layout.md`.

## Related docs

- `services/database/postgres-drizzle-skill.md` — Postgres + Drizzle mechanics.
- `services/database/multi-org-isolation.md` — RLS/tenant isolation patterns.
- `tools/database/pglite-local-first.md` — embedded Postgres for desktop/extension apps.
- `tools/ui/wxt.md` — browser extension framework guidance.
- `tools/mobile/app-dev.md` and `tools/mobile/app-dev-expo.md` — mobile app guidance.
- `tools/monorepo/turborepo.md` — monorepo execution patterns.
- `tools/ui/ui-skills.md` and `workflows/ui-verification.md` — UI implementation and evidence.
