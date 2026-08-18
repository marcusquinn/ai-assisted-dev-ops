---
description: TypeScript monorepo app-stack defaults for web, API, desktop, mobile, and extension surfaces
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# TypeScript Monorepo App Stack

Use when the product has durable app state, shared domain logic, multiple surfaces, or a roadmap likely to add desktop/mobile/extension clients.

## Default shape

```text
apps/
  web/          # React/Next web app
  api/          # API/server runtime when not colocated with web
  worker/       # background jobs/schedules when not hosting-native
  desktop/      # Electron/Tauri shell, or separate Rust workspace for GPUI
  mobile/       # Expo app when needed
  extension/    # WXT extension when needed
packages/
  db/           # Drizzle schema, migrations, repositories
    migrations/ # generated SQL and Drizzle metadata snapshots
    src/schema/ # table definitions and relations, re-exported by index.ts
  domain/       # entities, services, workflow rules, validation
  api/          # route adapters, DTOs, errors, API metadata
  jobs/         # job handlers, schedules, queues when shared across runtimes
  ui/           # shared components/tokens
  config/       # eslint/tsconfig/tailwind/build config
  sdk/          # typed client/API helpers
```

Add surfaces only when a user workflow requires them; keep package boundaries ready so later surfaces are cheap.

## Defaults

- Language: TypeScript by default; a deliberately selected GPUI/native desktop client uses Rust or the platform language at that boundary.
- Web: React/Next for product UX.
- Data: Postgres + Drizzle + migrations; RLS for workspace/user boundaries.
- Validation: shared schemas in domain/API packages.
- UI: component library package with design tokens and accessibility rules.
- Background jobs: explicit `apps/worker` / `packages/jobs` or hosting-native queue/cron; see `operations-jobs-scheduling.md`.
- Local-first desktop/extension cache: PGlite only when Postgres schema reuse is worth the startup/performance trade-off.
- Desktop framework: use `desktop-frameworks.md`; a GPUI client can reuse service contracts and generated API types, but not React UI packages or browser-only TypeScript code.

## Package rules

- `packages/db` owns table definitions, relations, migration helpers, and seed data.
- `packages/db/drizzle.config.ts` points `out` to `./migrations` and `schema` to `./src/schema/index.ts`.
- `packages/db/migrations/` and `packages/db/migrations/meta/` are versioned source artifacts.
- `packages/domain` owns business rules and metadata interpretation; avoid framework imports.
- `packages/api` owns route adapters, transport-specific middleware, DTOs, errors, and API metadata.
- `packages/jobs` owns background handlers, schedule definitions, queue names, and retry policies when workers are not fully hosting-native.
- `packages/ui` owns presentational components and interaction primitives.
- Apps compose packages; apps do not become dumping grounds for reusable logic.
- Keep server-only code out of renderer/mobile/extension bundles.

## Verification

- Show the planned directory tree before implementation.
- Confirm which surfaces are in-scope now.
- Confirm database ownership and migration command.
- Confirm migration files live under `packages/db/migrations/` unless the app intentionally has multiple databases.
- Run typecheck, lint, tests, and surface-specific build for changed packages.
- For UI changes, use `workflows/ui-verification.md` for browser evidence.
