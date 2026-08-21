---
description: Screen marketing copy guidelines with an optional local-service website profile
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

# Screen Marketing Copy Guidelines

Structural defaults for product-facing websites, blogs, and social copy. Use one sentence per paragraph to prevent walls of text; other media follow `content/production-writing.md` "Medium-aware layout". Tone, vocabulary, spelling, and personality come from `context/brand-identity.toon` or the project brief. Brand identity maintenance: `tools/design/brand-identity.md`.

## Screen copy rules

- **Paragraphs**: One sentence per paragraph by default; split any remaining wall of text
- **Sentences**: Keep them direct and readable. Spaced em dashes (` — `) are welcome as follow-on breaks when they help — e.g. "We finish them with marine-grade coatings — they resist swelling."
- **SEO**: Bold **keywords** naturally; use project-specific long-tail variations such as "[location] [service]"; never stuff
- **Avoid**: "We pride ourselves...", "Our commitment to excellence...", "Elevate your home with...", repeating brand name at sentence start (prefer "We make..." over "Trinity Joinery crafts..."), empty trailing blocks (`<!-- wp:paragraph --><p></p><!-- /wp:paragraph -->`), Markdown in HTML fields

## Local-service voice profile

Apply these only when the project brief or brand identity selects them:

- **Tone**: Authentic, local, professional but approachable
- **Spelling**: British (`specialise`, `colour`, `moulding`, `draughty`, `centre`)

## WordPress content profile

Apply these when the target stores WordPress or HTML content:

- **HTML fields**: `<strong>`, `<em>`, `<p>`, `<h2>`, `<ul><li>` — not Markdown (`**bold**` won't render)
- **WP fetch**: `wp post get ID --field=content` (singular `--field`, not `--fields` — avoids `Field/Value` table artefacts)
- **Workflow**: Fetch → Refine → Structure → Update → Verify

## WordPress content update workflow

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
> We finish them with marine-grade coatings — they resist swelling, warping and weathering.

Apply the screen layout to product pages, blogs, and social copy by default. Apply the local-service profile only when project evidence supports it. For social and video variants, see `content/platform-personas.md`.
