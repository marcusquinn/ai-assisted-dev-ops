<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Agent Routing

## Core rule

Dispatch issue-backed workers with `dispatch-single-issue-helper.sh dispatch NUMBER OWNER/REPO`. It performs deduplication and ownership ceremony, creates the worktree, and forwards the verified runner identity to `headless-runtime-helper.sh`. Use `headless-runtime-helper.sh run` directly only for non-issue headless jobs. Never use bare runtime CLIs: they skip lifecycle reinforcement and can stop after PR creation (GH#5096).

Capability cataloguing is not evidence of live usability. Before routing work that depends on an external tool or service, run `scripts/capability-readiness-helper.py route <capability> --runtime <opencode|claude-code>`. Mandatory dimensions that are false **or unknown** force the declared fallback; the structured response reports the reason and coverage impact. The canonical contract is `configs/capability-registry.json`; generated inventory: `reference/capability-registry.md`.

Every selected agent inherits the ambient improvement contract in
`reference/self-improvement.md`. Commands may expose controls, but routing must
not depend on a user remembering to request learning or feedback capture.

## Routing order

1. Read the task or issue description.
2. If it is clearly code work (`implement`, `fix`, `refactor`, `CI`), use Build+ or omit `--agent`.
3. If trigger words clearly match another domain, resolve its capability readiness. Route to the owner only when every mandatory dimension is true; otherwise use the reported fallback.
4. If uncertain, default to Build+; it can load narrower docs on demand.
5. **Bundle-aware routing (t1364.6):** project bundles can define `agent_routing` overrides. Check with `bundle-helper.sh get agent_routing <repo-path>`. An explicit `--agent` flag wins.

The selected agent changes the system prompt and domain knowledge loaded for the worker.

## Interactive subagent progress

- Use subagents only for independent advisory work; never delegate the active critical path.
- Dispatch at most two children in one batch and do not launch another batch until they return.
- Prefix every delegated prompt with `[effort:simple]`, `[effort:standard]`, or `[effort:thinking]`; use the lowest tier that can reliably complete the task.
- Use `simple` only for bounded, low-consequence advisory work with objective parent-verifiable evidence. The parent must validate the result; fluent output alone is not successful completion.
- A thinking-tier parent does not require thinking-tier children. When reliable, offload bounded, independent, output-heavy discovery, analysis, and tool work to simple or standard children; keep small low-output calls direct when delegation overhead outweighs context savings.
- Batch independent children in one parallel call. Require final-only summaries with the decision, evidence (paths/lines or commands), uncertainty, and next action; raw logs stay in child context and the parent owns synthesis.
- Keep the parent progressing on non-overlapping work. Do not finalize with children pending; use their returned evidence or complete the work locally and disregard late results.
- Subagents must not dispatch further subagents. OpenCode maps the requested effort to the provider and clamps it so child reasoning never exceeds the parent session.
- In interactive OpenCode sessions, an eligible child can end with the exact marker `BLOCKED: capability limit - <evidence>`. The plugin re-prompts that same child session at the next configured tier so prior evidence is retained. Generic blockers, headless dispatch, terminal tiers, and children that attempted side effects never take this automatic path.
- For full-loop work, persist stable unit IDs, dependencies, explicit file/question ownership, effort tier, and a reuse key before dispatch. Parallel-ready units must have disjoint file ownership; overlap is serialized even when capacity is available.
- Effective concurrency is the minimum of the plan cap, mode cap, and available global slots. Interactive batches remain capped at two; headless uses its configured per-task cap.
- Persist completed-unit evidence and reuse it after retries or runtime interruption. The primary repeats delegated exploration only when its evidence is absent, stale, or contradictory.
- Consolidate adversarial review into bounded correctness/concurrency, security/trust, compatibility/quality, and test-adequacy units, followed by one synthesis and one repair pass.

## Primary agents

Full index: `subagent-index.toon`.

| Agent | Trigger words | Use for |
|-------|---------------|---------|
| Aidevops | aidevops, framework, setup, config, troubleshooting, MCP, agent, skill | Framework setup, configuration, troubleshooting, extension, releases |
| Build+ | implement, fix, refactor, bug, CI, tests, PR | Code: features, bug fixes, refactors, CI, PRs (default) |
| Automate | schedule, cron, dispatch, pulse, monitoring, routine | Scheduling, dispatch, monitoring, background orchestration, pulse supervisor |
| SEO | SEO, GEO, AI search, ranking, keyword, search intent, conversational query, autocomplete, query fan-out, GSC, schema, sitemap, backlinks, search trends | SEO/GEO audits, query and keyword research, search-intent analysis, GSC, and schema markup |
| Content | blog, video, script, social, newsletter, audio, image | Media production and distribution: blog, video, audio, image, social, newsletters, AI video generation |
| Marketing-Sales | ads, CRO, email campaign, CRM, copy, outreach, funnel | Email campaigns, FluentCRM, Meta Ads, CRO, direct response copy, CRM pipeline, proposals, outreach |
| PR | PR, public relations, press, journalist, media list, pitch, newsjacking, coverage tracking, reactive comment | Earned media strategy, journalist research, media lists, newsworthiness, newsjacking, pitch critique, coverage tracking |
| Product | product, PRD, roadmap, validation, onboarding, monetisation, growth, analytics, UX | Product management, requirements, validation, onboarding, monetisation, growth, UI/UX, analytics |
| Business | company ops, accounting, bookkeeping, reconciliation, finance, invoice, receipts, cash flow, accounting software, runners | Company operations, provider-neutral accounting, financial ops, invoicing, receipts, provider selection, runner configs, strategy |
| Legal | legal, compliance, privacy policy, terms, contract, GDPR | Compliance, terms of service, privacy policy |
| Vault | vault, encrypted memory, protected data, lock, unlock, rekey, device trust, remote lock, remote unlock, secure sync | Vault setup/management, protected-data routing, encrypted sync/fleet trust, remote lock/unlock-request, secure-message policy |
| Research | research, compare, market, competitor, technical analysis, external tool, repository evaluation, do we already do this, adoption fit | Tech research, competitive analysis, market research, and external tool/repository evaluation; use `reference/external-tool-evaluation.md` for source-level adoption decisions |
| Health | health, wellness, nutrition, fitness, medical lifestyle | Health and wellness content |

Routing boundary: SEO owns search-demand evidence, query provenance, keyword
metrics, and intent/trend interpretation. Research owns the wider market and
competitor synthesis, Content owns topic production, and PR owns current-story
verification, newsworthiness, standing, and journalist-facing action. Hand off
the intent ledger; do not move adjacent-domain judgment into SEO.

For narrower domains such as Reports, App Stack, WordPress, Shopify, Cloudflare, Proxmox, Remotion, CalDAV, public relations, or browser/mobile work, read `reference/domain-index.md` and the relevant skill/subagent entry before defaulting to Build+. For repeatable browser operations or web data mining, route through `/auto-browse` and `.agents/workflows/auto-browse.md` so profile state, safety gates, and private/shareable artifact boundaries are handled consistently.

Product-facing copy such as websites, campaigns, customer email, social posts, and marketing or introductory sections uses `content/humanise.md` by default before delivery. Ordinary replies, engineering documentation, reports, issues, and PRs use the plain-language baseline in `AGENTS.md`; do not load Humanise unless the user explicitly requests it or the passage itself is product copy. An explicit `/humanise` request remains valid for any supplied prose.

## Report routing

Use `agent:Reports` and `reports/general.md` when the task asks for a report, client audit, evidence-led PDF, scorecard, board pack, report preview, source ledger, or recurring report agent. Keep domain collection with the relevant primary/domain agent, then hand the evidence bundle to Reports for structure, citations, recommendations, and export contracts.

For new report agents, read `reports/routine-handoff.md` and `tools/build-agent/build-agent.md`: deterministic collection goes in `run:` steps; `agent:Reports` handles interpretation and narrative; `/report-render` or `scripts/commands/report-render.md` creates derived HTML/PDF previews from canonical `report.md` or `report.json`.

## Dispatch example

```bash
AGENTS_DIR="$(aidevops config get paths.agents_dir)"
AGENTS_DIR="${AGENTS_DIR:-"$HOME/.aidevops/agents"}"
HELPER="${AGENTS_DIR/#\~/$HOME}/scripts/headless-runtime-helper.sh"
# Path is determined by 'paths.agents_dir' in config.jsonc

# Code task (default — Build+ implied)
$HELPER run \
  --role worker \
  --session-key "issue-42" \
  --dir ~/Git/myproject \
  --title "Issue #42: Fix auth" \
  --prompt "/full-loop Implement issue #42 -- Fix authentication bug" &
sleep 2

# SEO task
$HELPER run \
  --role worker \
  --session-key "issue-55" \
  --agent SEO \
  --dir ~/Git/myproject \
  --title "Issue #55: SEO audit" \
  --prompt "/full-loop Implement issue #55 -- Run SEO audit on landing pages" &
sleep 2

# Content task
$HELPER run \
  --role worker \
  --session-key "issue-60" \
  --agent Content \
  --dir ~/Git/myproject \
  --title "Issue #60: Blog post" \
  --prompt "/full-loop Implement issue #60 -- Write launch announcement blog post" &
sleep 2
```
