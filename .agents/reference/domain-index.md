<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Domain Index

Read subagents on-demand when trigger words clearly match. Full index: `subagent-index.toon`.

This index describes what is catalogued, not what is usable now. Query `scripts/capability-readiness-helper.py query [capability] --runtime <runtime>` and gate routing with its `route` command. Canonical machine-readable definitions and generated counts are in `configs/capability-registry.json` and `reference/capability-registry.md`.

| Domain | Trigger words | Entry point |
|--------|---------------|-------------|
| Business | company ops, strategy, finance, invoice, receipts, runners | `business.md`, `business/company-runners.md` |
| Accounting | bookkeeping, bank statements, reconciliation, chart of accounts, debtors, creditors, management accounts, cash flow | `business/accounting.md` |
| Accounting software | QuickFile, Xero, QuickBooks, FreeAgent, Sage, Zoho Books, accounting integration | `business/accounting-software.md` |
| Planning | plan, define, roadmap, tasks, brief, decomposition, beads | `workflows/plans.md`, `scripts/commands/define.md`, `tools/task/beads.md` |
| Legal | legal, compliance, privacy policy, terms, contract, GDPR | `legal.md`, `tools/legal/legal-research.md` |
| Code quality | lint, review, smells, standards, simplify, audit | `tools/code-review/code-standards.md` |
| Git/PRs/Releases | git, PR, branch, merge, release, changelog, version | `workflows/git-workflow.md`, `tools/git/github-cli.md`, `workflows/release.md` |
| GitHub event ingress | GitHub webhook, webhook onboarding, GitHub API optimisation, GitHub API optimization, Cloudflare Tunnel | `reference/github-webhook-onboarding.md`, `reference/github-api-transport.md`, `services/networking/netbird.md`, `services/hosting/cloudflare.md` |
| Reports/Documents/PDF | PDF, document, report, reporting, report agent, client audit, scorecard, board pack, styled report, report components, evidence badges, source ledger, report preview, A4, US Letter, slides, pandoc, forms, extraction | `reports.md`, `reports/general.md`, `reports/exporters.md`, `reports/routine-handoff.md`, `reports/outputs.md`, `scripts/commands/report-render.md`, `tools/document/document-creation.md`, `tools/pdf/overview.md`, `tools/conversion/pandoc.md` |
| OCR | OCR, receipt scan, invoice scan, image text, PaddleOCR | `tools/ocr/overview.md`, `tools/ocr/paddleocr.md`, `tools/ocr/glm-ocr.md` |
| macOS Operations | Activity Monitor, process efficiency, background processes, Login Items, launchd, LaunchAgents, LaunchDaemons, system extensions, legacy apps, macOS cleanup | `tools/automation/macos-activity-cleaner.md`, `scripts/commands/macos-activity-cleaner.md`, `tools/security/local-permissions-check.md`, `tools/terminal/optimise-macos-indexing-backups.md` |
| Product (shared) | product, onboarding, monetisation, growth, analytics, UX | `product/validation.md`, `product/onboarding.md`, `product/monetisation.md`, `product/growth.md`, `product/ui-design.md`, `tools/design/design-md.md`, `product/analytics.md` |
| App Stack | app stack, starter, static site, monorepo, desktop framework, Electron, Tauri, GPUI, workspace model, metadata-driven app | `tools/app-stack.md`, `tools/app-stack/decision-matrix.md` |
| Browser/Mobile | browser, Playwright, screenshot, mobile, app, extension, Swift, SwiftUI, Xcode, iOS, macOS, simulator preview, serve-sim | `tools/browser/browser-automation.md`, `tools/browser/browser-qa.md`, `tools/browser/browser-use.md`, `tools/browser/chromium-debug-use.md`, `tools/browser/skyvern.md`, `tools/mobile/app-dev.md`, `tools/mobile/app-dev-swift.md`, `tools/mobile/swift-xcode-agent-workflow.md`, `tools/mobile/app-store-connect.md`, `tools/mobile/serve-sim.md`, `tools/browser/extension-dev.md` |
| Content/Video/Voice | blog, article, video, script, social, X/Twitter, xurl, newsletter, voice | `content.md`, `content/social-xurl.md`, `tools/video/video-prompt-design.md`, `tools/voice/speech-to-speech.md`, `tools/voice/transcription.md` |
| Public Relations | PR, public relations, press, journalist, media list, pitch, newsjacking, coverage tracking, reactive comment, newsworthiness | `pr.md`, `public-relations/getting-started.md` |
| Design | UI, UX, brand, visual, inspiration, design system | `tools/design/design-md.md`, `tools/design/ui-ux-inspiration.md`, `tools/design/ui-ux-catalogue.toon`, `tools/design/brand-identity.md` |
| Blender/3D | Blender, Blender Lab MCP, blender-mcp, blend file, Geometry Nodes, 3D scene analysis | `tools/design/blender.md` |
| SEO | SEO, GEO, AI search, ranking, keyword, search intent, conversational query, autocomplete, query fan-out, GSC, schema, sitemap, backlinks, search trends | `seo.md`, `seo/conversational-search-intent.md`, `seo/keyword-research.md`, `seo/google-search-console.md` |
| Paid Ads/CRO | ads, Meta Ads, CRO, landing page, copy, funnel | `marketing-sales/meta-ads.md`, `marketing-sales/ad-creative.md`, `marketing-sales/direct-response-copy.md`, `marketing-sales/cro.md` |
| WordPress | WordPress, WP, plugin, theme, MainWP, LocalWP, wp-cli, production clone | `tools/wordpress.md`, `workflows/wordpress-local-clone.md` |
| Shopify | Shopify, Liquid, Admin API, store, product catalog | `configs/mcp-templates/shopify-dev-mcp-config.json.txt` — set `platform:shopify` in repos.json to auto-enable Shopify Dev MCP. |
| Communications | chat, Slack, Discord, Matrix, Telegram, WhatsApp, Signal | `services/communications/bitchat.md`, `services/communications/convos.md`, `services/communications/discord.md`, `services/communications/google-chat.md`, `services/communications/imessage.md`, `services/communications/matterbridge.md`, `services/communications/matrix-bot.md`, `services/communications/msteams.md`, `services/communications/nextcloud-talk.md`, `services/communications/nostr.md`, `services/communications/signal.md`, `services/communications/simplex.md`, `services/communications/slack.md`, `services/communications/telegram.md`, `services/communications/urbit.md`, `services/communications/whatsapp.md`, `services/communications/xmpp.md` |
| Team interfaces | Buzz, virtual assistant server, shared AI team, agent identity, repository collaboration | `tools/ai-assistants/buzz-team-interface.md`, `reference/team-interface-buzz-provisioning.md`, `reference/team-interfaces.md` |
| Email | email, mailbox, deliverability, SMTP, newsletter, Google Workspace | `tools/ui/react-email.md`, `services/email/email-agent.md`, `services/email/email-mailbox.md`, `services/email/email-actions.md`, `services/email/email-intelligence.md`, `services/email/email-providers.md`, `services/email/email-security.md`, `services/email/email-testing.md`, `services/email/email-composition.md`, `services/email/email-inbound-commands.md`, `services/email/google-workspace.md` |
| Outreach | cold email, sales outreach, leads, Smartlead, Instantly, warmup | `services/outreach/cold-outreach.md`, `services/outreach/smartlead.md`, `services/outreach/instantly.md`, `services/outreach/manyreach.md` |
| Payments | Stripe, RevenueCat, subscriptions, billing, procurement | `services/payments/revenuecat.md`, `services/payments/stripe.md`, `services/payments/procurement.md` |
| Auth troubleshooting | auth, login, OAuth, API key, token, credentials | `tools/credentials/auth-troubleshooting.md` |
| Vault/Protected Data | vault, encrypted memory, protected data, lock, unlock, rekey, device trust, remote lock, remote unlock, secure sync, fleet trust, needs_vault | `vault.md`, `reference/vault.md`, `workflows/vault-setup.md`, `workflows/vault-fleet.md`, `scripts/commands/vault.md` |
| Security/Encryption | security, secrets, prompt injection, OPSEC, audit, encryption | `tools/security/tirith.md`, `tools/security/opsec.md`, `tools/security/prompt-injection-defender.md`, `tools/security/tamper-evident-audit.md`, `tools/credentials/encryption-stack.md`, `scripts/secret-hygiene-helper.sh` |
| Database/Local-first | Postgres, Drizzle, migration, schema, PGlite, local-first, accounts, contacts, RLS | `tools/database/pglite-local-first.md`, `services/database/postgres-drizzle-skill.md`, `tools/app-stack/database-foundation.md` |
| Vector Search | vector, embeddings, RAG, semantic search, zvec | `tools/database/vector-search.md`, `tools/database/vector-search/zvec.md` |
| Local Development | localhost, local dev, Traefik, mkcert, preview proxy | `services/hosting/local-hosting.md` |
| Operating-system selection | distro choice, Linux desktop, server OS, Omarchy, Kubuntu, Alpine, Rocky Linux, AlmaLinux, NixOS, Parrot OS, Kali VM, Tails, Hetzner ARM, ARM64 image | `reference/os-selection.md`, `aidevops/recommendations.md`, `reference/platform-support.md` |
| Node server administration | Node.js server, Node runtime, Node LTS/EOL, npm/pnpm/Yarn/Bun drift, PM2, systemd Node, next start, SSR server, event-loop lag, heap OOM, memory leak, CPU/RAM spike | `tools/runtime/node-server-admin.md` |
| Hosting/Deployment | deploy, hosting, WordPress hosting, managed hosting, VPS, Fly, Coolify, Vercel, Daytona, cloud | `aidevops/recommendations.md`, `services/hosting/hostinger.md`, `services/hosting/hetzner.md`, `services/hosting/cloudflare.md`, `tools/deployment/hosting-comparison.md`, `tools/deployment/fly-io.md`, `tools/deployment/coolify.md`, `tools/deployment/vercel.md`, `tools/deployment/uncloud.md`, `tools/deployment/daytona.md` |
| Networking/VPN | VPN, mesh, NetBird, Tailscale, Nostr VPN, FIPS, remote compute network | `services/networking/netbird.md`, `services/networking/tailscale.md`, `services/networking/nostr-vpn.md` |
| Infrastructure | GPU, containers, OrbStack, remote dispatch, servers | `tools/infrastructure/cloud-gpu.md`, `tools/containers/orbstack.md`, `tools/containers/remote-dispatch.md` |
| Networking/VPN | VPN, mesh, WireGuard, Tailscale, NetBird, Obscura, MPR, multi-party relay, Mullvad, QUIC obfuscation | `services/networking/tailscale.md`, `services/networking/netbird.md`, `services/networking/obscuravpn.md` |
| Accessibility | accessibility, WCAG, a11y, contrast, screen reader | `tools/accessibility/accessibility-audit.md` |
| OpenAPI exploration | OpenAPI, API spec, endpoint search, schema discovery | `tools/context/openapi-search.md` |
| Local models | local model, llama.cpp, GGUF, Hugging Face, offline | `tools/local-models/local-models.md`, `tools/local-models/huggingface.md`, `scripts/local-model-helper.sh` |
| Bundles | bundle, preset, project profile, model routing override | `bundles/*.json`, `scripts/bundle-helper.sh`, `tools/context/model-routing.md` |
| Agent routing | agent, specialist, route, dispatch, primary agent | `reference/agent-routing.md` |
| Model routing | model, tier, Haiku, Sonnet, Opus, fallback, budget | `tools/context/model-routing.md`, `reference/orchestration.md` |
| Orchestration | pulse, workers, dashboard, headless, dispatch, supervisor | `reference/orchestration.md`, `tools/ai-assistants/headless-dispatch.md`, `scripts/commands/pulse.md`, `scripts/commands/dashboard.md` |
| Upstream watch | upstream, dependency watch, release monitor, source tracking | `scripts/upstream-watch-helper.sh`, `.agents/configs/upstream-watch.json` |
| Testing infrastructure | testing setup, install test framework, new harness, fixtures, coverage setup | `scripts/commands/testing-setup.md`, `tools/testing-setup.md`, `scripts/testing-setup-helper.sh` |
| Agent/MCP dev | build agent, create agent, MCP server, mcporter, plugin | `tools/build-agent/build-agent.md`, `tools/build-mcp/build-mcp.md`, `tools/mcp-toolkit/mcporter.md` |
| Self-Improvement | self-improve, learning, autoagent, framework issue, pattern | `reference/self-improvement.md`, `tools/autoagent/autoagent.md`, `scripts/commands/autoagent.md` |
| Framework | aidevops, setup, architecture, skills, framework docs | `aidevops/architecture.md`, `scripts/commands/skills.md` |

**Creating reports**: When a user asks to create a report, client audit, evidence-led PDF, board pack, scorecard, or report preview, read `reports/general.md` first, then the matching domain report doc and `reports/exporters.md`. Keep `report.md` or `report.json` canonical; use `/report-render` only for derived HTML/PDF output.

**Creating report agents**: When a report will repeat, read `reports/routine-handoff.md` and `tools/build-agent/build-agent.md`. Deterministic collection belongs in `run:` steps; `agent:Reports` owns evidence interpretation, narrative, recommendations, and handoff tasks.

**Creating agents**: When a user asks to create, build, or design an agent — regardless of which primary agent is active — always read `tools/build-agent/build-agent.md` first. It contains the tier prompt (draft/custom/shared), design checklist, and lifecycle rules.

**Routine feature verification**: Keep ordinary “verify/prove this works” requests with Build+ and `reference/ci-gate-policy.md`; they do not trigger testing-infrastructure setup. Load `tools/build-agent/agent-testing.md` only for explicit agent-behaviour testing.
