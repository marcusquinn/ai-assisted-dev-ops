---
description: Content guidelines for AI copywriting
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Content Guidelines for AI Copywriting

Structural copy rules for website content, especially local-service pages. Tone, vocabulary, and personality come from `context/brand-identity.toon` if present; this doc covers structure only. Brand identity maintenance: `tools/design/brand-identity.md`.

## Rules

- **Tone**: Authentic, local, professional but approachable, British English
- **Spelling**: British (`specialise`, `colour`, `moulding`, `draughty`, `centre`)
- **Paragraphs**: One sentence per paragraph; split at 3+ lines
- **Sentences**: Short & punchy; spaced em-dashes (` — `) instead of subordinate clauses — e.g. "We finish them with marine-grade coatings — they resist swelling." not "...coatings, which means that they are built specifically..."
- **SEO**: Bold **keywords** naturally; use long-tail variations ("Jersey heritage properties", "granite farmhouse windows"); never stuff
- **Avoid**: "We pride ourselves...", "Our commitment to excellence...", "Elevate your home with...", repeating brand name at sentence start (prefer "We make..." over "Trinity Joinery crafts..."), empty trailing blocks (`<!-- wp:paragraph --><p></p><!-- /wp:paragraph -->`), Markdown in HTML fields
- **HTML fields**: `<strong>`, `<em>`, `<p>`, `<h2>`, `<ul><li>` — not Markdown (`**bold**` won't render)
- **WP fetch**: `wp post get ID --field=content` (singular `--field`, not `--fields` — avoids `Field/Value` table artefacts)
- **Workflow**: Fetch → Refine → Structure → Update → Verify

## Content Update Workflow

1. **Fetch:** `wp post get 123 --field=content > file.txt`
2. **Refine:** Apply these guidelines.
3. **Structure:** Keep valid block markup such as `<!-- wp:paragraph -->...`.
4. **Update:** `wp post update 123 content.txt`
5. **Verify:** Flush provider caches and check the frontend. On a legacy Closte estate, follow `services/hosting/closte.md` "Mutation Guard" and confirm Development Mode is disabled.

## Example Transformation

**Before (AI/generic):**
> Trinity Joinery uses durable hardwoods treated to resist Jersey's salt air and humidity effectively. Expert carpenters apply marine-grade finishes for long-lasting protection with minimal upkeep.

**After (human/local):**
> Absolutely.
>
> We know how harsh the salt air and damp can be.
>
> That's why we use high-performance, rot-resistant timbers like Accoya and Sapele.
>
> We finish them with marine-grade coatings — ensuring they resist swelling, warping and weathering.

Apply these rules to product page updates unless a project-specific brief overrides them. For social and video variants, see `content/platform-personas.md`.
