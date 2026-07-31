<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Native SDK upstream assessment

## Status

- **Decision:** Watch releases, adapt selected patterns, and avoid a production dependency.
- **Upstream:** <https://github.com/vercel-labs/native>
- **Reviewed baseline:** `v0.7.0` at `7636ec3686e5de7c36c1330fc0358adb8fb6c514`
- **Reviewed:** 2026-07-31
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

## v0.7.0 release review

The `v0.6.3...v0.7.0` comparison contains three commits and 74 changed files:
Windows canvas-smoke stabilization, a reusable native code component, and the
release version bump. The code component adds deterministic theme-token syntax
highlighting, Markdown-fence reuse, optional logical line numbers, wrapped and
two-axis scrolling modes, cross-chunk selection and copy, and viewport-aware
rendering that preserves retained source while bounding display-list command and
text demand.

The Windows smoke change retries structural reads that race a snapshot file's
truncate-and-rewrite publication instead of silently substituting fallback
geometry. Package-manifest changes only advance core, CLI, example, and optional
platform-binary versions from `0.6.3` to `0.7.0`; no new dependency was added.
The release does not report a security fix, React/WebView integration change,
automation-protocol or record/replay change, or packaging, signing, and update
change.

The release-note injection scan was clean. The relevant-diff scan flagged the
Unicode test fixture `é́界` as a possible encoding pattern; inspection confirmed
that it is rendering test data, not an instruction. No upstream instruction,
bundled skill, install command, or repository command was followed.

Classification:

- **Adapt pattern:** any future syntax-highlighted log, configuration, or command
  surface should retain raw source for selection and copying while rendering
  only visible content under explicit resource budgets. It should degrade the
  affected surface rather than reject the whole frame, preserve indentation,
  use a plain fallback for unknown languages, expose an accessible label, and
  test long, Unicode, wrapped, unwrapped, line-numbered, and transformed content.
- **Adapt pattern:** if aidevops GUI smoke tests ever read a concurrently rewritten
  snapshot, require a bounded retry for a complete structural marker and fail
  explicitly when it never appears. Prefer atomic publication when aidevops owns
  the writer rather than normalizing partial reads as valid state.
- **Ignore for current implementation:** browser-native rendering already owns
  code selection, scrolling, and accessibility in the Vite/React interface, and
  current GUI smoke tests do not consume Native's canvas snapshots. The new
  component and Windows/Wine hardening do not change the generated macOS
  launcher, local API, packaging, or current GUI test paths.
- **Do not adopt:** no current architecture requirement justifies importing the
  pre-1.0 SDK, platform binaries, bundled skill, eval workspace, or Vercel
  services. The existing portability and trust-boundary decision remains
  unchanged.

No implementation issue is warranted. Revisit these patterns only if aidevops
adds a high-volume syntax-highlighted surface, a custom renderer, or mutable
snapshot polling.

## v0.6.3 release review

The `v0.6.2...v0.6.3` comparison contains two commits: a native textarea
editing correction and the release version bump. The change adds visual-line
and document-boundary keyboard navigation, bounded per-editor undo and redo,
macOS Edit-menu integration, shift-click extension, preserved indentation, and
atomic CRLF caret and deletion behavior. It also keeps controlled text models
synchronized during history replay and adds regression coverage for the native
canvas and markdown-viewer paths.

The published package manifests only advance the core, CLI, and optional
platform-binary versions. The release does not report a security fix, new
production dependency, React/WebView integration change, accessibility or
automation protocol change, or packaging, signing, and update change.

Classification:

- **Adapt pattern:** any future custom native text editor should treat keyboard
  and OS-menu commands as one behavior surface. Its acceptance tests should
  cover wrapped visual-line navigation, selection extension, undo/redo model
  synchronization, indentation, IME composition, and CRLF boundaries, including
  failure-atomic replay when retained storage is bounded.
- **Ignore for current implementation:** aidevops uses browser-native text
  controls in its Vite/React interface and does not implement Native's canvas
  textarea or controlled `TextBuffer` history. The fixes therefore do not alter
  the generated Swift/WKWebView shell or current GUI test and packaging paths.
- **Do not adopt:** no current architecture requirement justifies importing the
  pre-1.0 SDK, platform binaries, bundled skill, eval workspace, or Vercel
  services. The existing portability and trust-boundary decision remains
  unchanged.

No implementation issue is warranted. Revisit the interaction test matrix only
if aidevops introduces a custom native text surface rather than browser-native
controls.

## v0.6.2 release review

The `v0.6.1...v0.6.2` comparison contains three commits: a container-background
rendering fix, cross-platform desktop overlay-window support, and the release
version bump. The release does not report a security fix, signing/update change,
or new production dependency.

The overlay work adds transparent, always-on-top, click-through, and passive-show
window options. It applies those options before first visibility, reveals canvas
windows after an alpha-correct first frame, and documents explicit backend
limits: transparent Chromium windows are rejected on macOS, transparent Windows
windows must be chromeless and cannot contain WebViews or native child views,
and Wayland cannot guarantee topmost placement.

Classification:

- **Adapt pattern:** if aidevops adds a top-level desktop overlay, require
  presentation policy to be installed atomically before reveal, preserve focus
  unless activation is explicit, wait for the first composited frame, and expose
  backend capability failures instead of silently degrading.
- **Ignore for current implementation:** the existing generated Swift/WKWebView
  shell uses in-window AppKit overlays and has no requirement for a transparent
  top-level HUD. The container-background fix applies to Native's canvas layout,
  not the aidevops Vite/React or Swift rendering paths.
- **Do not adopt:** no current architecture requirement justifies importing the
  pre-1.0 SDK, platform binaries, bundled skill, eval workspace, or Vercel
  services. The existing portability and trust-boundary decision remains
  unchanged.

No implementation issue is warranted. Revisit the overlay pattern only when a
concrete cross-platform HUD, click-through status surface, or passive window
requirement is accepted.

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
