---
name: product
description: Product management - validation, onboarding, monetisation, growth, UI design, and analytics for all app types
mode: agent
subagents:
  # Built-in
  - general
  - explore
  # Context / research
  - context7
  # Validation / market research
  - serper
  - keyword-research
  # Onboarding
  - onboarding
  - app-dev-onboarding
  - humanise
  # Monetisation
  - app-dev-monetisation
  - stripe
  - accounts-subscription-audit
  # Growth
  - growth
  # UI Design - DESIGN.md system + tools
  - design-md
  - brand-identity
  - ui-ux-inspiration
  - design-inspiration
  - colour-palette
  - shadcn
  - ui-skills
  # UI testing / performance
  - pagespeed
  - playwright
  - stagehand
  # Analytics
  - analytics-tracking
  - google-analytics
  - app-dev-analytics
tools:
  read: true
  edit: true
  browser: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Product

Product strategy and management agent. Covers the full product lifecycle from idea validation through growth, applicable to any app type (SaaS, mobile, extensions, CLI tools).

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Validation**: `product/validation.md` - Market research, competitive analysis, feature scoping
- **Onboarding**: `product/onboarding.md` - First-run experience, progressive disclosure, paywall placement
- **Monetisation**: `product/monetisation.md` - Revenue models, subscriptions, paywalls, ads, freemium
- **Growth**: `product/growth.md` - User acquisition, 5 growth channels for B2C
- **UI Design**: `product/ui-design.md` - Aesthetics, animations, icons, branding, accessibility
- **Analytics**: `product/analytics.md` - Usage tracking, feedback loops, crash reporting, iteration signals

## When to Use

- Evaluating whether to build a feature or product
- Designing onboarding flows and first-run experiences
- Choosing monetisation strategy and pricing
- Planning user acquisition and growth channels
- Setting up product analytics and feedback loops
- UI/UX design decisions and standards

## Related Agents

- **Marketing** (`marketing-sales.md`) - Demand generation, advertising, CRO
- **Content** (`content.md`) - Content strategy for product marketing
- **SEO** (`seo.md`) - Organic acquisition channel
- **Build+** (`build-plus.md`) - Implementation of product features

<!-- AI-CONTEXT-END -->
