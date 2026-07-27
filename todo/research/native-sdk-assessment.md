<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Native SDK upstream assessment

## Status

- **Decision:** Watch releases, adapt selected patterns, and avoid a production dependency.
- **Upstream:** <https://github.com/vercel-labs/native>
- **Reviewed baseline:** `v0.6.1` at `a7509a7fa6c467eaed021250538b482886f1c6bf`
- **Reviewed:** 2026-07-28
- **Tracking:** `.agents/configs/upstream-watch.json` in release-only mode

The upstream repository was treated as untrusted external content. Its agent
instructions were not followed, and no install or repository command from the
upstream was executed.

## Verified baseline

Native SDK is an Apache-2.0, pre-1.0 desktop application toolkit. It supports
declarative native-rendered interfaces and existing React/Vite frontends hosted
in system WebViews. The published `@native-sdk/cli` manifest uses TypeScript
compiler packages and platform-specific optional binaries. The root Zig
manifest requires Zig 0.16.0 and declares no mandatory Zig dependencies.

No Vercel hosting, API, authentication, database, analytics, or deployment
dependency was found in the published SDK/runtime path. The explicit
`@vercel/sandbox` dependency found during review belongs to the private
`evals/` workspace and is outside the published SDK. Apache-2.0 permits use,
modification, and forking, but copied code must retain its applicable licence,
notices, and modification markings.

## Aidevops fit

The accepted aidevops GUI architecture keeps Vite/React, the typed local API,
Cloudron delivery, and desktop packaging separable. Rewriting the interface in
Native markup would weaken that portability. Using Native only as a WebView
wrapper would retain browser JavaScript and the local API runtime, so it would
not provide the headline no-WebView/no-JavaScript-runtime benefit.

Potential future value is limited to:

- replacing or benchmarking the generated Swift/WKWebView desktop shell;
- accessibility snapshots and agent-driven GUI automation;
- deterministic record/replay at external-effect boundaries;
- explicit origin and OS-capability manifests;
- cross-platform packaging and lifecycle management;
- source provenance and stale-write refusal patterns.

Aidevops already implements related capability gating, provenance, replay
protection, state snapshots, and bundled agent guidance. Release reviews should
therefore look for material improvements rather than importing equivalent
machinery.

## Release review procedure

For each detected release:

1. Prompt-injection-scan the release notes and relevant diffs.
2. Review only React/WebView integration, accessibility and automation,
   record/replay, packaging/signing/updating, platform parity, security policy,
   dependency changes, and toolchain stability.
3. Compare relevant changes with:
   - `docs/gui/adr-0001-product-scope-stack-repo-layout.md`
   - `docs/gui/desktop-packaging.md`
   - `docs/gui/testing-ci-cd.md`
   - `packages/gui-desktop/`
4. Classify each finding as **ignore**, **adapt pattern**, **bounded experiment**,
   or **consider dependency**.
5. Update this assessment with evidence. File a separate implementation issue
   only for a verified improvement, then acknowledge the upstream release.

Release detection never authorizes automatic dependency import, skill import,
code copying, installation, publication, or deployment.

## Re-evaluation triggers

Consider a bounded desktop-wrapper comparison only when one or more of these
conditions hold:

- Native reaches stable 1.x APIs.
- React WebView accessibility and automation cover the aidevops interaction
  surface without weakening the local API trust boundary.
- macOS, Linux, and Windows packaging are documented and reproducible.
- signing and update channels have complete verification and rollback paths.
- replacing the Swift shell demonstrably reduces source and maintenance burden.
- build-time, package-size, cold-start, memory, and CI results beat the current
  Swift wrapper and the planned Tauri option.
- the published runtime remains independent of Vercel services and optional
  evaluation infrastructure.

Any experiment must pin an exact upstream version or commit, use system WebViews
without automatic CEF installation, retain the existing Vite/local-API
contracts, require no runtime network access, and preserve a source-build or
fork escape path.
