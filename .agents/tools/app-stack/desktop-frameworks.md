---
description: Desktop framework selection and safety rules for Electron, Tauri, GPUI, and native apps
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Desktop Frameworks

Do not select a desktop framework from headline bundle-size or speed claims. Match the rendering model, ecosystem, team skills, platform requirements, and distribution constraints, then benchmark representative startup, interaction, memory, and packaging workloads.

## Selection guide

| Option | Prefer when | Main trade-off |
|--------|-------------|----------------|
| Electron | Chromium fidelity, DevTools, browser automation, extension reuse, or rich web UI reuse matters | Ships Chromium and Node, increasing bundle and baseline resource costs |
| Tauri | A web UI is still desirable but a system-webview shell, smaller distribution, and narrow Rust command boundary fit | Webview behaviour varies by OS; complex UI remains web-rendered |
| GPUI | A Rust team needs a custom, high-performance, GPU-rendered desktop UI without a browser DOM | Pre-1.0 ecosystem with breaking changes and less documentation/component depth |
| Platform-native UI | Maximum OS integration, accessibility maturity, or platform-specific experience dominates | Separate platform implementations and less cross-platform reuse |

## Use Electron when

- The desktop app is primarily a web app with local capabilities.
- Chromium behaviour, DevTools, or browser automation/debugging is valuable.
- You need extension-adjacent code reuse or web platform APIs.
- PGlite/filesystem storage can run in the main process.

## Consider Tauri when

- Bundle size or a narrow webview-to-Rust boundary dominates.
- The UI is small and does not need Chromium-specific behaviour.
- The team can test system-webview differences on every supported OS.

## Consider GPUI when

- The product benefits from custom rendering, dense interactive surfaces, large lists, or editor-like UI.
- Rust ownership and a GPU-accelerated hybrid immediate/retained rendering model are deliberate choices.
- Web/React component reuse is less valuable than control over rendering and native application behaviour.
- The team accepts a pre-1.0 framework, frequent breaking changes, latest-stable-Rust requirements, and learning from Zed source/examples while documentation matures.

GPUI currently documents Metal rendering on macOS, Wayland/X11 on Linux and FreeBSD, and Win32/DirectWrite on Windows. Verify accessibility, text input/IME, windowing, packaging, signing, and distribution on every target platform before committing. Treat performance as a hypothesis until a representative prototype confirms it. Source: <https://github.com/zed-industries/zed/tree/main/crates/gpui>.

## Electron architecture rules

- Main process owns filesystem, secrets, database, OS integration, and migrations.
- Renderer owns UI only.
- Preload exposes a typed, narrow API.
- Never expose raw SQL or filesystem paths over IPC.
- Prefer named operations (`items:list`, `settings:update`) over generic RPC.
- Validate every IPC payload at the boundary.
- Keep secrets in OS/aidevops secret storage, not renderer local storage.

## Electron local data

- Use Postgres on the server as the canonical store.
- Use PGlite in Electron main process only when shared Postgres schema is useful.
- Bundle migrations as app resources and run them from the main process.
- Use a mutex/queue around local writes; PGlite has single-connection constraints.

## Verification

- Record why Electron, Tauri, GPUI, or platform-native UI won and what evidence would reopen the decision.
- Measure cold/warm startup, idle and active memory, representative interaction latency, binary/package size, and release build time on target hardware.
- Test accessibility, keyboard navigation, IME/text rendering, multiple windows, graphics fallback, signing, packaging, and updates on each supported OS.

For Electron specifically:

- Typecheck main/preload/renderer boundaries.
- Test packaged and dev migration paths.
- Verify renderer cannot call arbitrary SQL, filesystem, or shell commands.
- Verify app launch handles database startup latency with a loading state.
