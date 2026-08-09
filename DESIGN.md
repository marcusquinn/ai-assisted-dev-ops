---
version: alpha
name: AI DevOps Framework
description: Developer-first automation interface using terminal-native black surfaces, cyan prompt branding, compact cards, and system typography.
colors:
  primary: "#66d9f2"
  secondary: "#8b949e"
  tertiary: "#238636"
  neutral: "#000000"
  background: "#030707"
  surface: "#161b22"
  surface-raised: "#21262d"
  on-surface: "#c9d1d9"
  on-primary: "#0d1117"
  on-tertiary: "#ffffff"
  outline: "#30363d"
  accent-hover: "#8ce8ff"
  muted: "#6e7681"
  success: "#3fb950"
  warning: "#fbbf24"
  error: "#da3633"
  error-hover: "#f85149"
typography:
  headline-display:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"
    fontSize: 32px
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"
    fontSize: 24px
    fontWeight: 700
    lineHeight: 1.2
  headline-md:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"
    fontSize: 18px
    fontWeight: 600
    lineHeight: 1.3
  body-lg:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.55
  body-md:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.5
  body-sm:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.45
  label-md:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"
    fontSize: 12px
    fontWeight: 600
    lineHeight: 1.2
rounded:
  none: 0px
  sm: 4px
  md: 6px
  lg: 8px
  xl: 12px
  full: 9999px
spacing:
  unit: 4px
  xs: 4px
  sm: 8px
  md: 12px
  lg: 16px
  xl: 20px
  gutter: 16px
  margin: 20px
components:
  dashboard-page:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    padding: 20px
  card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: 16px
  card-hover:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.lg}"
  input-default:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.xl}"
    padding: 8px 12px
  button-primary:
    backgroundColor: "{colors.tertiary}"
    textColor: "{colors.on-tertiary}"
    typography: "{typography.body-md}"
    rounded: "{rounded.md}"
    padding: 8px
  button-primary-hover:
    backgroundColor: "#2ea043"
    textColor: "{colors.on-primary}"
    rounded: "{rounded.md}"
  button-secondary:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.on-surface}"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    padding: 6px
  button-secondary-hover:
    backgroundColor: "{colors.outline}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.md}"
  button-danger:
    backgroundColor: "{colors.error}"
    textColor: "{colors.on-tertiary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    padding: 6px
  button-danger-hover:
    backgroundColor: "{colors.error-hover}"
    textColor: "{colors.on-primary}"
    rounded: "{rounded.md}"
  badge-success:
    backgroundColor: "{colors.success}"
    textColor: "{colors.on-primary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    padding: 4px
  badge-warning:
    backgroundColor: "{colors.warning}"
    textColor: "{colors.on-primary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    padding: 4px
  badge-neutral:
    backgroundColor: "{colors.muted}"
    textColor: "{colors.on-tertiary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    padding: 4px
  badge-error:
    backgroundColor: "{colors.error}"
    textColor: "{colors.on-tertiary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    padding: 4px
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: AI DevOps Framework

## Overview

AI DevOps is a developer-operations framework and OpenCode plugin. Its interface language should feel like a reliable engineering console: dark by default, compact, status-led, and evidence-oriented. The current implemented UI evidence is the MCP Server Dashboard in `.opencode/server/mcp-dashboard.ts`, which uses GitHub-dark colours, compact cards, system fonts, blue focus/highlight states, green primary actions, red destructive actions, and 4px/8px spacing increments.

Design goals:

- Keep operational state obvious: running, stopped, error, authenticated, last update, and command actions should scan quickly.
- Use compact terminal-only status glyphs: show ⚪ from the first submitted root-session message and preserve it through descriptive title generation, 🔴 while retrying after errors, 🟡 when a permission decision is required, and 🟢 when the root session is awaiting input. Retain the descriptive title and opt-out so colour is never the only essential status affordance; keep glyphs out of stored session titles so issue/PR prefixes remain first in search results.
- Preserve developer trust with native system typography, code-friendly contrast, visible borders, and restrained motion.
- Use compact density for dashboards and sidebars, but keep controls at least 44px high when touch use is plausible.
- Prefer semantic tokens over one-off values so generated reports, OpenCode UI surfaces, and dashboard screens stay consistent.

## Colors

The canonical palette is derived from the dashboard CSS in `.opencode/server/mcp-dashboard.ts`:

| Token | Value | Use |
|---|---:|---|
| `background` / `neutral` | `#0d1117` | Page background, input background, code wells |
| `surface` | `#161b22` | Cards, authentication bar, raised panels |
| `surface-raised` | `#21262d` | Secondary buttons and low-emphasis controls |
| `outline` | `#30363d` | Borders, dividers, hover fills |
| `on-surface` | `#c9d1d9` | Primary text on dark surfaces |
| `secondary` | `#8b949e` | Body metadata, helper copy, inactive labels |
| `muted` | `#6e7681` | Lowest-emphasis timestamps and stopped/unknown badges |
| `primary` | `#58a6ff` | Headings, focus, hover border, selected highlights |
| `tertiary` | `#238636` | Primary action and running status |
| `success` | `#3fb950` | Authenticated/success text |
| `warning` | `#fbbf24` | Warnings and cautionary evidence badges |
| `error` | `#da3633` | Error status and destructive actions |
| `error-hover` | `#f85149` | Error text and danger hover |

Contrast rules:

- Use `#c9d1d9` or white text on `#0d1117`, `#161b22`, `#21262d`, `#238636`, and `#da3633`.
- Do not use muted text below 12px; pair `#6e7681` only with non-critical metadata.
- Blue `#58a6ff` is an accent, not the primary CTA colour; reserve CTA fill for green `#238636` unless the action is navigation/focus.

## Typography

Use native system UI fonts for app and dashboard surfaces:

```css
font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
```

Scale:

- Display: 32px / 700 / 1.15 for handoff covers and major report titles.
- Large heading: 24px / 700 / 1.2 for page-level headings.
- Medium heading: 18px / 600 / 1.3 for card titles; matches the dashboard `.card-title` size.
- Body: 14px / 400 / 1.5 for dashboard controls and normal UI copy.
- Small: 12px / 400-600 for badges, metadata, helper text, and compact buttons.

Code snippets and command examples may use `SFMono-Regular`, `Consolas`, `Liberation Mono`, `Menlo`, or `monospace`, but the primary interface remains system sans.

## Layout

Use a compact 4px base with an 8px rhythm:

- Page padding: 20px on dashboard-like pages.
- Grid gap: 16px; dashboard cards use `repeat(auto-fill, minmax(300px, 1fr))`.
- Panel/card padding: 16px.
- Form/control horizontal rhythm: 8px or 12px gaps.
- Workspace scroll containers and page/form grids should use content-sized rows (`align-content: start`, form grid items `align-items: start`) so cards and controls never stretch vertically to fill spare viewport space.
- Form controls should fill their column width with a 44px minimum height; labels stay attached to their controls with an 8px internal gap.
- Sidebar width: 420px default, 320px minimum, 640px maximum from `.opencode/ui/chat-sidebar/constants.ts`.
- Message and panel content should use a readable max width near 600px when not in a dashboard grid.

Keep dashboard layouts responsive through fluid grids rather than fixed breakpoints. On narrow screens, cards stack to a single column and action rows may wrap.

## Elevation & Depth

Depth is border-led rather than shadow-led:

- Use `1px solid #30363d` for card, auth bar, input, and button boundaries.
- Use `#161b22` panels over `#0d1117` page background.
- Use `#21262d` for secondary action surfaces.
- Hover depth changes border or fill colour, not position.
- Reserve heavy shadows for generated browser/PDF report previews, not operational dashboards.

## Shapes

Radius is compact and functional:

- 4px for code chips and very small inline elements.
- 6px for inputs and buttons.
- 8px for cards, panels, and auth bars.
- 12px for larger generated report containers.
- Full radius for status badges and pills.

Avoid large rounded marketing cards in operational screens unless the surface is a report preview or handoff artifact.

## Components

Core component rules:

- **Page shell:** `#0d1117` background, `#c9d1d9` text, 20px padding, system font.
- **Cards:** `#161b22` background, `#30363d` border, 8px radius, 16px padding. Hover changes border to `#58a6ff`.
- **Inputs, selects, and textareas:** use macOS-inspired inset fields: raised dark surface, subtle top highlight, 1px border, 12px radius, 8px 12px padding, native-density 38-44px height, subdued disabled text, and an accent focus ring. Dropdowns should keep the same field shell and use a compact chevron affordance.
- **Primary buttons:** green `#238636` fill with white text; hover `#2ea043`.
- **Secondary buttons:** `#21262d` fill, `#30363d` border, `#c9d1d9` text; hover `#30363d`.
- **Danger buttons:** red `#da3633` fill and border; hover `#f85149`.
- **Status badges:** 4px 8px padding, full pill radius, 12px/500 type. Running is green, stopped/unknown is muted grey, error is red.
- **Metadata:** use `#8b949e` at 12px; use `#6e7681` only for lowest-emphasis timestamps.
- **Focus:** keyboard focus should use blue `#58a6ff` outline or border with at least 2px visible affordance.
- **Provider and integration cards:** group by auth or service family, show provider/account counts, render recommendations with an explicit thumbs-up badge plus text, and keep connection controls metadata-only until audited write routes exist.

### Secrets and Vault access

- Treat Secrets as an operational metadata workspace, not a password manager. Its hierarchy is: explicit Vault state and safe action, value-custody boundary, aggregate readiness cards, then protected reference inventory.
- Locked views may show already-approved aggregate counts and readiness classes, but never reference names, usernames, provider identifiers, paths, masked fragments, prefixes, suffixes, lengths, checksums, values, or copy/reveal controls.
- Unlocked views may show reference names plus non-sensitive configured, missing, or unchecked health. Every row states that values are never displayed and routes management to a secure helper rather than a browser form.
- Distinguish `uninitialized`, `locked`, `unlocked`, `corrupted`, and `unknown` visually and in text. Setup is offered only after authoritative uninitialized metadata; helper errors, partial/legacy responses, and loading states must never open setup.
- Browser dialogs never collect Vault credentials. Desktop actions send only the fixed `init`, `unlock`, or `lock` enum to an AppKit overlay. The native wrapper owns the PTY and accepts passphrases only in `NSSecureTextField` after terminal echo is off; terminal streams and input never cross the WebKit bridge. The direct `aidevops vault init|unlock|lock` CLI remains an equivalent fallback.
- While the secure overlay is active, exclude the window from OS screen capture, disable app/page screenshots, cancel on close, quit, sleep, or session deactivation, and clear native input/output buffers on every exit.
- Populate unlocked reference inventory only from the deterministic names-only helper contract. Validate bounds, ordering, names, backend health, helper ownership, and a post-read unlocked state; locked, unknown, malformed, timed-out, and lock-raced responses clear names immediately.
- Use compact 8px border-led cards, fluid 210px minimum metric/capability grids, a desktop table that becomes labelled cards below 720px, green safe setup/unlock actions, and visible focus rings even when decorative borders are hidden.

## Logo and icon rules

- The approved AI DevOps app mark is the cyan terminal prompt glyph used by the `aidevops.sh` navigation logo and favicon.
- Do not reintroduce the old `AI` letter mark for dock icons, launch/loading states, sidebar/header marks, favicons, or social previews.
- Use a rounded black square with subtle cyan glow, a cyan ring at low opacity, and `#8ce8ff` prompt glyph fill.
- Prompt glyph placement follows the current website asset: `translate(512 522) scale(0.94) translate(-288 -256)` inside a `1024x1024` SVG viewBox.
- Buzz specialist avatars reuse the website's circular `1024x1024` profile-avatar geometry, including the `504` crop radius, `451` safe-detail radius, and `translate(512 521) scale(1.08) translate(-288 -256)` glyph placement. Assign one reviewed hue per stable `agent_id` across the spectrum while preserving the canonical saturation, lightness, near-black background, glow, rings, and wave accents; the Aidevops framework guide remains canonical cyan.
- Specialist avatar hues are decorative identity cues, not status, authority, risk, provider, or workload indicators. Keep assignments deterministic and source/display-name independent, inline them as bounded SVG data URLs for portable Buzz snapshots, and preserve text alternatives in the host interface.
- Distribute specialist hues across the full spectrum in a high-separation display order rather than a monotonic rainbow sequence; neighboring cards should remain distinguishable at small avatar sizes while the Aidevops guide stays canonical cyan.
- Buzz specialist mention names use lowercase dashed `role-host` identifiers, such as `aidevops-marcus-macbook-pro-01` and `seo-marcus-macbook-pro-01`, so typing and provisioning-host identity remain predictable. A host suffix is not proof that model execution is local or on-device; do not encode status, provider, model, permission, or privacy claims in the name.
- Icon SVGs should include accessible names when they are content-bearing; decorative duplicates should be hidden from assistive technology.
- Third-party provider logos may use maintained icon libraries such as `react-icons`/Simple Icons when available; otherwise use a consistent monochrome glyph or initials fallback and keep the brand name visible in text.
- The desktop app launch path should show one branded loading treatment: defer native WebKit startup to the web loading shell, avoid replacing it with a second React-only loader during hydration, and use a compact cyan `>_` prompt followed by `Preparing local GUI` in Inter for any startup status chip.

## Design capture during harness sessions

- Treat `DESIGN.md` as the source of truth for visual direction, branding, UI/UX preferences, iconography, and generated brand handoffs.
- When a harness session receives, discovers, or implements design preferences, update `DESIGN.md` in the same PR as the UI/branding change.
- If `DESIGN.md` is missing, create one or add a worker-ready task with the known files, observed preferences, and verification checklist.
- PR summaries for branding/UI/UX work should call out the `DESIGN.md` update or explicitly explain why no design-system change was needed.

## Do's and Don'ts

Do:

- Use semantic tokens from this file before adding new hex values.
- Keep dashboards compact, structured, and border-defined.
- For chart-heavy operational dashboards, prefer OpenPanel-style space efficiency and Bklit-style compact chart cards: KPI header, tiny delta, bar/sparkline combination, and dense legends that keep Pulse and worker health scannable at a glance.
- Public repository charts should use the GitHub-dark console palette, support matching light and dark surfaces, include accessible SVG titles/descriptions, and remain legible at README width without interaction.
- Use green for safe primary operations and red only for destructive/error states.
- Preserve high contrast and readable 12px+ metadata.
- Keep generated reports and brand handoffs free of private local paths, secrets, raw transcripts, and unrelated repo names.

Don't:

- Add light-only UI surfaces without a matching dark-mode treatment.
- Use blue filled CTAs when green better communicates an operational action.
- Hide error state in colour alone; pair colour with text labels.
- Introduce decorative gradients, glassmorphism, or heavy shadows into operational tooling.
- Use skeleton placeholder brand values in UI or generated guidelines.

## Responsive Behaviour

- Dashboard grids should use auto-fit/auto-fill patterns and collapse to one column below the card minimum width.
- Chat sidebars keep the 320px-640px clamp and default to 420px.
- Button rows may wrap; primary and destructive actions remain visually distinct when wrapped.
- Generated report handoffs should print cleanly to A4, US Letter, and 16:9 slides without clipped tables.
- Maintain keyboard and screen-reader access for every control; existing ARIA labels in `.opencode/ui/chat-sidebar/constants.ts` are the naming pattern.

## Agent Prompt Guide

When implementing AI DevOps UI:

1. Read `DESIGN.md` before changing any dashboard, sidebar, generated report, or browser-facing interface.
2. Reuse the token names and values in the YAML front matter. If a new state is needed, add a semantic token and explain the evidence source.
3. Match the terminal-native operational console style: black/near-black background, raised dark cards, cyan brand/focus highlights, green safe action, red danger/error.
4. Verify contrast for new text/background pairs and keep focus indicators visible.
5. Update this file whenever branding/UI/UX preferences change during a harness session, then include the DESIGN.md update in the same PR.
6. Regenerate brand guideline artifacts after changing this file with `aidevops design guidelines . --pdf`.
