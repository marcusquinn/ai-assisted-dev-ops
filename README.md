<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

![AI DevOps — 14 main agents, 2,200+ sub agents, 2,010+ helper scripts, and 100+ slash commands](docs/assets/og-image.png)

# AI DevOps Framework

**[aidevops.sh](https://aidevops.sh)** is an [OpenCode](https://opencode.ai/) plugin and AI DevOps framework for people who want AI to do useful work across code, infrastructure, business, marketing, content, and creative projects without turning every job into another long, fragile chat.

Most AI tools still leave you doing the hard coordination yourself: finding the right context, choosing a model, protecting secrets, managing branches, watching CI, spotting stuck work, and remembering what went wrong last time. aidevops puts structure around that work so agents can share context, work safely in parallel, spend model budget where it matters, and leave the system better than they found it.

> **Recommended setup:** [OpenCode](https://opencode.ai/) + OpenAI GPT-5.6 Luna / Terra and GPT-6 Astra. aidevops routes Luna to bounded work, Terra to general implementation, and Astra at low reasoning to consequential reasoning and synthesis. Claude models (Anthropic) remain fully supported fallbacks, and other model providers are evaluated as their quality, latency, and cost profiles change.

*"Scope a mission to redesign the landing pages — break it into milestones, dispatch workers in parallel, validate each milestone, and track budget across the whole project."*

**One conversation, autonomous project delivery, with security, teamwork, token efficiency, and quality control built in.**

Founded by [Marcus Quinn](https://github.com/marcusquinn) on 9th November 2025 to help anyone level-up their AI & Open-Source game.

## **The Aim**

**Maximum value for your time and money.** **[aidevops](https://aidevops.sh)** is built for the gap between “the model can probably do this” and “the work is actually done, verified, safe, and worth the cost.”

- Load the right context when it is needed, instead of stuffing every agent, skill, and tool into the prompt.
- Spend tokens and model budget deliberately. Cheap and fast models should handle routine work; stronger models should handle judgement, architecture, review, and risk.
- Keep secrets out of chat. Credentials, tenants, scans, confirmations, and audit logs are part of the workflow, not an afterthought.
- Let people and agents work across machines without trampling each other. Worktrees, branches, PRs, task IDs, mailbox state, and memory keep the work separated and traceable.
- Notice when the system is struggling. Stuck workers, orphaned PRs, stale assignments, CI failures, review-bot traps, and repeated mistakes should become visible signals.
- Improve the framework from real use. Imported skills, session learnings, quality findings, and better patterns should become better agents, hooks, scripts, and docs.
- Optimise for profitable outcomes: useful work shipped, lower supervision cost, safer operations, and decisions that make sense beyond the next prompt.

The result: an AI operations platform that manages projects across every business domain — absorbing everything automatable so you can focus on what matters.

**Built on proven patterns**: aidevops implements [industry-standard agent design patterns](#agent-design-patterns) - including multi-layer action spaces, context isolation, and iterative execution loops.

## **Why This Framework?**

**Beyond single-task AI.** A normal AI harness can be brilliant for one job and still weak at the work around the job. aidevops is for the surrounding discipline: context, routing, safety, git hygiene, collaboration, verification, memory, and follow-through.

**What makes it different:**

- **Pulse supervision** - scheduled checks can dispatch workers, merge ready PRs, close loops, and surface stuck work.
- **Domain agents** - code, automation, product, business, marketing, legal, content, research, SEO, health, reports, and framework work each get their own guidance.
- **Cross-model checks** - risky operations can be reviewed by a second provider to reduce shared failure modes.
- **Service coverage** - hosting, Git platforms, DNS, security, monitoring, deployment, payments, communications, and more are handled through repeatable helpers.
- **Mission work** - larger goals can be split into milestones with validation, budget tracking, and automatic advancement.

---

<!-- Build & Quality Status -->
[![GitHub Actions](https://github.com/marcusquinn/aidevops/actions/workflows/code-quality.yml/badge.svg?branch=main)](https://github.com/marcusquinn/aidevops/actions/workflows/code-quality.yml)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=marcusquinn_aidevops&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=marcusquinn_aidevops)
[![CodeFactor](https://www.codefactor.io/repository/github/marcusquinn/aidevops/badge)](https://www.codefactor.io/repository/github/marcusquinn/aidevops)
[![Maintainability](https://qlty.sh/gh/marcusquinn/projects/aidevops/maintainability.svg)](https://qlty.sh/gh/marcusquinn/projects/aidevops)
[![Codacy Badge](https://app.codacy.com/project/badge/Grade/2b1adbd66c454dae92234341e801b984)](https://app.codacy.com/gh/marcusquinn/aidevops/dashboard?utm_source=gh&utm_medium=referral&utm_content=&utm_campaign=Badge_grade)
[![CodeRabbit](https://img.shields.io/badge/CodeRabbit-AI%20Reviews-FF570A?logo=coderabbit&logoColor=white)](https://coderabbit.ai)

<!-- License & Legal -->
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Copyright](https://img.shields.io/badge/Copyright-Marcus%20Quinn%202025--2026-blue.svg)](https://github.com/marcusquinn)

<!-- Release & Version Info -->
[![Version](https://img.shields.io/badge/Version-3.32.316-blue.svg)](https://github.com/marcusquinn/aidevops/releases)
[![npm version](https://img.shields.io/npm/v/aidevops)](https://www.npmjs.com/package/aidevops)
[![Homebrew](https://img.shields.io/badge/homebrew-marcusquinn%2Ftap-orange)](https://github.com/marcusquinn/homebrew-tap)
[![GitHub repository](https://img.shields.io/badge/github-repository-181717.svg?logo=github)](https://github.com/marcusquinn/aidevops)

<!-- Framework Specific -->
[![Services Supported](https://img.shields.io/badge/Services%20Supported-30+-brightgreen.svg)](#comprehensive-service-coverage)
[![AGENTS.md](https://img.shields.io/badge/AGENTS.md-Compliant-blue.svg)](https://agents.md/)
[![AI Optimized](https://img.shields.io/badge/AI%20Optimized-Yes-brightgreen.svg)](https://github.com/marcusquinn/aidevops/blob/main/AGENTS.md)
[![MCP Servers](https://img.shields.io/badge/MCP%20Servers-20-orange.svg)](#mcp-integrations)
[![API Integrations](https://img.shields.io/badge/API%20Integrations-30+-blue.svg)](#comprehensive-service-coverage)

<!-- Repository Metrics -->
[![Lines of code](docs/metrics/badges/loc.svg)](docs/metrics/repo-metrics.md)
[![Dependencies](docs/metrics/badges/dependencies.svg)](docs/metrics/repo-metrics.md)

[![Languages by lines of code](docs/metrics/badges/languages.svg)](docs/metrics/repo-metrics.md)

## Attribution

aidevops is MIT licensed. Reuse is welcome, including commercial use, provided
the copyright and license notices are retained. If you build a derivative
framework, automation bot, workflow library, or commercial product from aidevops
code or distinctive operating patterns, see [ATTRIBUTION.md](ATTRIBUTION.md) for
the required notices and preferred credit text.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: AI-assisted DevOps automation framework
- **Install**: `npm install -g aidevops && aidevops update`
- **Recommended runtime/models**: OpenCode + OpenAI GPT-5.6 Luna / Terra / GPT-6 Astra
- **Entry**: `aidevops` CLI, `~/.aidevops/agents/AGENTS.md`
- **Stack**: Bash scripts, TypeScript (Bun), MCP servers
- **Recent focus**: evidence-based model routing, indexed worker worktrees, audited deployment copies, release provenance, and OpenCode control-plane safety

### Key Commands

- `aidevops init` - Initialize in any project
- `aidevops update` - Update framework
- `aidevops auto-update` - Automatic update polling (enable/disable/status)
- `aidevops runtime-bundle list` - List retained validated runtime bundles; use `rollback --bundle-id <id> --reason <text>` for an explicit audited rollback
- `aidevops gpt56-context [enable|disable|status]` - Keep GPT-5.6 at a 300K advertised context window in OpenCode (enabled by default), so 80% auto-compaction runs near 240K before long-context pricing; `status` verifies plugin discovery, initialization, hook registration, and effective limits
- `aidevops buzz [status|apply|rollback]` - Inspect or manage Buzz Desktop OpenCode ACP compatibility
- `~/.aidevops/agents/scripts/team-interface-helper.sh [providers|detect|status|doctor|plan]` - Inspect registered collaboration providers, persist read-only observations, or emit deterministic dry-run plans; no provider-write command is exposed
- `aidevops opencode conversation --overlay FILE --dir PATH` - Launch fixed-argv OpenCode ACP with a schema-validated ephemeral team-interface overlay and a final read-only capability guard; see `.agents/reference/team-interface-opencode-overlays.md`
- `aidevops secret` - Manage secrets (gopass encrypted, AI-safe)
- `aidevops source-access` - Manage exact-path, session-bound source-read approvals signed via sudo
- `aidevops security` - Full security assessment (posture, secrets, supply chain)
- `aidevops lint audit` - Audit native lint/format/typecheck commands and repo-verify hooks
- `aidevops lint configure --dry-run` - Preview safe evidence-based lint provisioning
- `aidevops metrics generate` - Generate local LOC, language, and dependency data for README badges or app about pages
- `/onboarding` - Interactive setup wizard (in AI assistant)
- `/design-artifact` - Route artifact-first UI, deck, email, poster, and mobile mockup work
- `/open-design` - Manage the optional Open Design companion studio
- `/auto-browse` - Learn, optimize, and graduate repeatable browser operations and web data-mining workflows
- `/report-render` - Render report-ready Markdown or JSON to HTML with sticky TOC, print CSS, evidence badges, and source cards for PDF export
- `/report-token-use` - Generate a local per-session token, model, compaction, and MCP-use report
- `/report-token-use efficiency --since 7d` - Compare model/effort, reasoning, prompt sizes, cache tokens, and consistently repriced API-equivalent costs without changing the ledger
- `/optimize-tiers` - Optionally investigate unresolved model comparisons with production telemetry and sealed historical replay
- `/pulse` - Run the autonomous supervisor loop for dispatch, merge, diagnostics, and stuck-work recovery
- `/serve-sim` / `serve-sim-helper.sh` - Exercise mobile web flows in simulator-backed local previews

### Agent Structure

- 14 main agents (Build+, Automate, Product, SEO, Marketing-Sales, etc.) with specialist @subagents on demand
- 2,200+ sub agents: individually callable Markdown modules, including skills, workflows and specialist references
- 2,010+ helper scripts across scripting languages, including supporting production modules but excluding tests
- 100+ slash commands for common operations

<!-- aidevops:inventory:start -->
Exact source inventory: **14 main agents**, **2,236 sub agents**, **2,017 helper scripts**, **106 slash commands**.
<!-- aidevops:inventory:end -->

These are tracked source modules and entry points, not counts of running agents. Main agents follow the runtime's discovery exclusions. Sub agents are individually addressable Markdown instruction modules selected by the generator's filename rules, regardless of `mode` metadata; callable skills, workflows and references count too. This measures distinct source paths, not unique flattened runtime names. Helper scripts include production script files and supporting modules across scripting languages, not just `*-helper` filenames. Tests, fixtures, generated/vendor files and duplicate aliases are excluded. Slash commands include valid shipped aliases; their regular source modules also belong to the sub-agent library, so the categories must not be added together. Audit every included path with `bash .agents/scripts/readme-helper.sh counts --inventory`; see [counting rules and hero maintenance](DESIGN.md#readme-hero-counts).

### What You Can Ask aidevops To Do

- Build, fix, review, release, and maintain software with worktrees, PRs, tests, and quality gates.
- Run infrastructure, hosting, DNS, monitoring, security, and deployment workflows.
- Plan products, PRDs, onboarding, monetisation, growth, analytics, and UI direction.
- Operate business, finance, receipts, invoices, marketing, outreach, SEO, content, video, and personal-productivity routines.
- Discover the right capability with `/skills recommend "TASK"`, `/onboarding`, or the OpenCode agent picker.

### Recent framework upgrades

Since the last README feature refresh, aidevops has added or expanded:

- **Local harness evaluation pilot**: compare OpenCode with the aidevops plugin through ChatGPT OAuth and local Docker, with verifier results and context/compaction telemetry. See the [FrontierHarness pilot and measured limitations](.agents/tools/ai-assistants/frontier-harness-eval.md); this is not a leaderboard-superiority claim.
- **Evidence-based model routing**: sealed historical replay evaluates model tiers and reasoning effort against deterministic hidden checks, with isolated macOS and Linux sandboxes and an explicit trusted-local posture that cannot automatically change routing (`.agents/workflows/optimize-tiers.md`).
- **Indexed worker worktrees**: dispatched linked worktrees can initialize branch-local CodeGraph indexes asynchronously, with bounded queues, disk-capacity checks, and failure isolation from worker launch (`.agents/scripts/codegraph-worktree-init-helper.sh`).
- **Audited non-Git deployment copies**: reviewed worktree content can converge into allowlisted stable runtime directories through dry-run manifests, private receipts, verified activation, recovery, and rollback (`.agents/reference/dirty-worktree-preservation.md`).
- **Release provenance recovery**: exact-tip aggregation successors preserve reviewed source manifests when `main` advances, while fenced release lanes continue to block unreviewed or conflicting publication (`.agents/reference/release-aggregation-recovery.md`).
- **OpenCode GUI/control-plane planning**: ADRs, threat model, trust-boundary guidance, and containment rules for a future GUI that stays local-first, auditable, and explicitly separated from secret-bearing helpers (`docs/gui/`).
- **Mobile and simulator workflows**: app-development guidance, App Store Connect support, Expo/Xcode/Swift workflows, Maestro/minisim/iOS Simulator MCP references, and `serve-sim` mobile web testing support (`.agents/tools/mobile/`).
- **Self-hosted runner operations**: lifecycle and storage runbooks, Docker foreground-mode guidance, systemd timer freshness triage, and ExecStop race-guard documentation (`.agents/reference/github-self-hosted-runners.md`).
- **Pulse diagnostics and reliability**: compact API-budget diagnostics, pulse cadence/API diagnostics, GitHub read ramp pacing, configurable worker floors, Renovate dashboard skipping, and more defensive duplicate/blocked-by/rate-limit handling.
- **Worker and PR observability**: worker diagnostic failure families, runtime observability signals, review-thread response scanning, required-check validation, orphan-recovery base handling, and safer automated GitHub write guards.
- **Runtime-neutral safety and evidence contracts**: shared command decisions across supported runtimes, commit-pinned plugin provenance with explicit hook authorization, recognized-client network checks, causal worker lineage, and redacted state snapshots/deltas in the existing observability database.
- **OpenCode runtime polish**: versioned session title suffixes, session archive retention, OAuth pool hardening, debug-error preservation, and reusable shell-env version lookup in the OpenCode plugin.
- **Safer GPT image generation**: native raster dimensions are verified before publication, while canonical-root OpenCode sessions can route output and references into the current session-owned linked worktree without weakening path confinement (`.agents/tools/vision/image-generation.md`).

<!-- AI-CONTEXT-END -->

## **Enterprise-Grade Quality & Security**

**Comprehensive DevOps framework with tried & tested services integrations, popular and trusted MCP servers, and enterprise-grade infrastructure quality assurance code monitoring and recommendations.**

**Vault security model:** aidevops defines protected data classes, provider
routing labels, trust boundaries, and phased encrypted sync architecture in
`.agents/reference/vault.md`. Vault guidance is local-first: third-party AI
providers can only reason over data that has been decrypted into their prompt or
tool context, so provider-side logs/retention remain outside Vault's technical
control. Future local LLM mode reduces provider exposure but not local host
compromise risk.

**Vault passphrase warning:** aidevops cannot recover a lost Vault passphrase.
Save it in a trusted password manager with backups; never paste it into AI chat,
CLI arguments, environment variables, logs, issue comments, or test fixtures.

### Report creation, previews, and PDF exports

Use aidevops to turn evidence bundles into decision-ready reports while keeping Markdown or JSON as the canonical source. Report agents can produce AI-search audits, SEO/GEO scorecards, delivery reviews, campaign reports, board packs, incident summaries, recurring client handoffs, and before/after remediation evidence.

New report capabilities include:

- Markdown-first report anatomy with cover pages, executive summaries, evidence ledgers, source cards, action prompts, appendix links, charts, Mermaid/LaTeX fallbacks, and `verified`, `partial`, `inferred`, or `missing` evidence badges.
- DESIGN.md-backed visual templates plus `basic` no-CSS output for lightweight handoff.
- Browser preview HTML with sticky contents, source-card links, copy buttons, and light/dark theme variants where a style supports them.
- PDF-ready profiles for A4, US Letter, and 16:9 slides. Generated PDF links use `*-a4.pdf`, `*-usletter.pdf`, and `*-slides.pdf` names.
- Versioned examples under `_reports/examples/`; open `_reports/examples/index.html` locally to browse the example reports, rendered styles, and PDF exports.

Create a report:

1. Load `reports/general.md` for structure, then the matching domain report doc such as `reports/seo-geo.md`, `reports/development.md`, `reports/marketing.md`, or `reports/business.md`.
2. Gather source evidence first. Use deterministic `run:` steps or service helpers for collection, then ask the domain agent plus `agent:Reports` to interpret and prioritise.
3. Save canonical source as `report.md` or `report.json` in `_reports/drafts/<report-name>/` while working, or in `_reports/examples/<example-name>/` only after privacy review.
4. Render with `/report-render report.md` or `.agents/scripts/report-render-helper.sh render report.md --template <style> --theme auto --pdf-profile a4 --output report.html`.
5. Export PDFs from Chrome/Chromium using the generated HTML and the A4, US Letter, or slides profiles. Regenerate derived HTML/PDF files instead of hand-editing them.

Create a repeatable report agent:

1. Read `reports/routine-handoff.md` and `tools/build-agent/build-agent.md`.
2. Define the report cadence, evidence collection commands, source IDs, privacy rules, target template/style, and verification gates.
3. Put deterministic collection in `run:` steps and reserve `agent:Reports` for narrative, evidence interpretation, recommendations, and handoff tasks.
4. Store reusable agent instructions in the appropriate agent tier (`custom/` for local/client-specific agents; shared `.agents/` only for broadly reusable framework agents).

## **Security Notice**

**This framework provides agentic AI assistants with powerful infrastructure access. Use responsibly.**

**Capabilities:** Execute commands, access credentials, modify infrastructure, interact with APIs
**Your responsibility:** Use trusted AI providers, rotate credentials regularly, monitor activity

### Security Commands

```bash
aidevops security              # Run ALL checks (posture + hygiene + supply chain)
aidevops security posture      # Interactive security posture setup (gopass, gh auth, SSH)
aidevops security status       # Combined posture + hygiene summary
aidevops security scan         # Secret hygiene & supply chain scan only
aidevops security scan-pth     # Python .pth file audit (supply chain attack vector)
aidevops security scan-secrets # Plaintext credential locations only
aidevops security scan-deps    # Unpinned dependency check
aidevops security check        # Per-repo security posture assessment
aidevops security dismiss <id> # Dismiss a security advisory after taking action
aidevops source-access status  # List temporary source-read approvals
sudo -k /usr/bin/python3 -I -B /etc/aidevops/source-access/source-access-helper.py revoke <approval-id>
```

Running `aidevops security` with no arguments is the single command that covers everything — user security posture, plaintext secret detection, supply chain IoC scanning, and active advisories.

When a read guard identifies only a low-confidence source-code basename match, it emits a scoped request. A maintainer can run the displayed root-broker approval command. Approvals are bound to the exact runtime session, user, Git-tracked regular source path, approved content digest, and guard reason; they expire within 12 hours and never override private-key, environment-file, credential-store, hard-link, symlink, changed-content, cross-worktree, or untracked-file denials. Repeating `--path` while creating a request produces one exact, repository-bound manifest that a human can approve once. The plugin redirects each approved read to its root-controlled immutable snapshot; revocation removes the receipt and every snapshot.

Routine `aidevops update` never requests sudo or launches an editor. When the root-owned broker differs from the active release, update prints a machine-readable deferred action; a human runs `aidevops setup --scope source-access` in an attached terminal. Scoped setup verifies the published signed tag, invalidates inherited sudo, asks for one confirmation, has root fetch the exact reviewed broker bytes directly over TLS, compares those downloads byte-for-byte with the signed Git objects, creates a dedicated root-only signing key under `/etc/aidevops/source-access`, and invalidates sudo again. It never executes or copies the user-writable aidevops deployment as root. The plugin rejects approvals whenever installed broker bytes differ from the active release.

**Security advisories** are delivered via `aidevops update` and shown in the session greeting until dismissed. The scanner never exposes secret values — only file locations and key names. All remediation commands should be run in a separate terminal, not inside AI chat sessions.

**Supply chain hardening:** All Python dependencies are pinned to exact versions (`==`) to prevent malicious package upgrades. The `.pth` file auditor detects known supply chain attack indicators (e.g., the LiteLLM March 2026 PyPI compromise).

## **Quick Start**

### Installation Options

**npm** (recommended - [verified provenance](https://docs.npmjs.com/generating-provenance-statements)):

```bash
npm install -g aidevops && aidevops update
```

> **Note**: npm suppresses postinstall output. The `&& aidevops update` deploys agents to `~/.aidevops/agents/`. The CLI will remind you if agents need updating.

**Bun** (fast alternative):

```bash
bun install -g aidevops && aidevops update
```

**Homebrew** (macOS/Linux):

```bash
brew install marcusquinn/tap/aidevops && aidevops update
```

**Direct from source** (aidevops.sh):

```bash
bash <(curl -fsSL https://aidevops.sh/install)
```

> **Updater recovery for v3.32.213:** If `aidevops update` stops because the
> official framework source checkout is not in the project registry, run the
> direct installer above once, then rerun `aidevops update`. Do not add the
> framework checkout to the downstream project registry or bypass canonical
> remote validation.

**Manual** (git clone):

```bash
git clone https://github.com/marcusquinn/aidevops.git ~/Git/aidevops
~/Git/aidevops/setup.sh
```

**That's it!** The setup script will:
- Clone/update the repo to `~/Git/aidevops`
- Deploy agents to `~/.aidevops/agents/`
- Install the `aidevops` CLI command
- Configure your AI assistants automatically
- Offer to install Oh My Zsh (optional, opt-in) for enhanced shell experience
- Install recommended token-efficiency tooling by default, including RTK for compact `git`/`gh`/test/lint command summaries before output reaches AI context
- Guide you through recommended tools (Tabby, Zed, Git CLIs)
- Ensure all PATH and alias changes work in both bash, zsh, and fish
- When Claude Code is installed, add a `claude` alias that runs `claude --dangerously-skip-permissions` (skips per-tool permission prompts). Re-running setup updates the alias automatically. To grant permissions per-session instead, press **Shift-Tab** inside Claude Code to cycle through permission modes (default → skip permissions → auto-approve).

**New users: Start [OpenCode](https://opencode.ai/) and type `/onboarding`** to configure your services interactively. OpenCode is the recommended tool for aidevops; the default routing uses OpenAI GPT-5.6 Luna, Terra, and GPT-6 Astra across the simple, standard, and thinking tiers. The onboarding wizard will:
- Explain what **[aidevops](https://aidevops.sh)** can do
- Ask about your work to give personalized recommendations
- Show which services are configured vs need setup
- Guide you through setting up each service with links and commands

**After installation, use the CLI:**

```bash
aidevops status           # Check installation and storage/cache health
aidevops doctor           # Detect duplicate installs and PATH conflicts
aidevops update           # Update framework + check registered projects
aidevops auto-update      # Manage automatic update polling (every 10 min)
aidevops runtime-bundle list # Inspect retained validated runtime bundles
aidevops init             # Initialize aidevops in any project
aidevops features         # List available features
aidevops repos            # List/add/remove registered projects
aidevops design           # DESIGN.md detection + brand guideline HTML/PDF exports
aidevops detect           # Scan for unregistered aidevops projects
aidevops upgrade-planning # Upgrade TODO.md/PLANS.md to latest templates
aidevops update-tools     # Check and update installed tools
aidevops uninstall        # Remove aidevops
```

### Optional Blender Lab MCP

[Blender MCP guidance](.agents/tools/design/blender.md) covers source-specific setup, scene analysis, Python API lookup, and the distinction between Blender's Lab project and the independent community `blender-mcp` package. Includes opt-in [OpenCode](configs/blender-lab-opencode-config.json.txt) and [MCP client](configs/blender-lab-mcp-config.json.txt) templates. Nothing is installed or activated automatically: Blender executes generated Python without protective guards, so use an isolated system and disposable scene copies.

### Optional Design Artifact Studio

aidevops now treats design as a self-contained stack with optional peripherals:

- **Google `DESIGN.md` standard**: AI-readable design systems with YAML tokens, linting, previews, and brand/style libraries (`.agents/tools/design/design-md.md`).
- **Init-aware design files**: `aidevops init` records `has_interface` and seeds root `DESIGN.md` for standard repos plus minimal-scope repos with detected GUI/interface markers.
- **Brand guideline exports**: `aidevops design guidelines . --pdf` generates `_reports/brand-guidelines/brand-guidelines.md`, HTML, and A4/US Letter/slides PDFs from `DESIGN.md`.
- **Repo rollout**: `aidevops design survey --json` audits owned initialized GUI repos; `aidevops design issues --apply` files worker-ready auto-dispatch issues for missing `DESIGN.md`/brand-guideline artifacts.
- **Design agents and skills**: brand identity, palettes, UI inspiration, product UI rules, shadcn/Tailwind/UI skills, Nothing-style design, email rendering, Remotion/video, and browser-based UI verification.
- **Artifact routing commands**: `/design-artifact` decides whether to use aidevops-native implementation or a companion artifact studio; `/open-design` manages optional Open Design workflows.
- **Verification gates**: Playwright screenshots, accessibility/contrast checks, email rendering, deck export/fidelity checks, and media smoke tests before generated artifacts are accepted.

Optional companion: [Open Design](https://github.com/nexu-io/open-design) by nexu-io (Apache-2.0) is supported as a **peripheral** for live sandboxed previews, design-skill pickers, `.od/` artifact workspaces, and HTML/PDF/PPTX/ZIP-style exports. aidevops remains canonical for agents, skill ingestion, Google `DESIGN.md`, local hosting, and verification.

```bash
# Inspect optional companion status
open-design-helper.sh status

# Print safe install plan only
open-design-helper.sh install

# Install alongside aidevops only after opting in
open-design-helper.sh install --execute

# Start through aidevops local HTTPS if Open Design only prints localhost
open-design-helper.sh start --https-local open-design
# → https://open-design.local when localdev is configured
```

Imported Open Design skills are not copied verbatim. They are evaluated through aidevops build-agent methodology, deduplicated against existing agents, flattened into aidevops `*-skill.md` structure, attributed to upstream, and given verification commands. See `.agents/tools/design/open-design-ingestion.md` for the full skill-value matrix.

**Project tracking:** When you run `aidevops init`, the project is automatically registered in `~/.config/aidevops/repos.json`. Running `aidevops update` checks all registered projects for version updates. Repository layout changes remain separate and user-invoked: `aidevops repos migrate-layout plan` creates a non-mutating, content-hashed plan, while confirmed apply, status, resume, and rollback operations preserve private receipts and fail closed on drift.

### **Use aidevops in Any Project**

Initialize **[aidevops](https://aidevops.sh)** features in any git repository:

```bash
cd ~/your-project
aidevops init                         # Enable the default feature set
aidevops init planning                # Enable only planning
aidevops init planning,time-tracking  # Enable specific features
aidevops init deployment-context   # Scaffold a deployment manifest
aidevops init wordpress-context    # Scaffold WordPress + deployment manifests
```

This creates:
- `.aidevops.json` - Configuration with enabled features
- `.agents/AGENTS.md` - Project-specific agent context
- `TODO.md` - Quick task tracking with time estimates
- `todo/PLANS.md` - Complex execution plans
- `.beads/` - Task graph database (if beads enabled)
- `.aidevops/deployments.yaml` - Deployment instance inventory (opt-in)
- `.aidevops/wordpress.yaml` - WordPress and LocalWP context (opt-in)

**Available features:** `planning`, `git-workflow`, `code-quality`, `time-tracking`, `database`, `beads`, `sops`, `security`, `deployment-context`, `wordpress-context`. `hosting-context` is an alias for `deployment-context`; `wordpress-context` implies deployment context. The default `all` set intentionally excludes both project-instance context features.

### Per-repo platform setup

After `aidevops init` registers a new repo, run `/setup-git` in your AI assistant
to apply per-repo platform secrets. Most notably, this sets `SYNC_PAT` — a
GitHub Actions secret that lets `issue-sync.yml` push TODO.md auto-completion
past branch protection.

This is distinct from `/onboarding` (per-account credentials like `gh auth login`):
GitHub Actions secrets are scoped per-repo, so each repo needs its own. You need
`gh auth login` to succeed before any per-repo helper can run, so `/onboarding`
comes first, `/setup-git` second.

Run `/setup-git` again whenever you register a new repo with `aidevops repos add`
or when a `SYNC_PAT` advisory appears in the session greeting toast. If you skip
this step, `issue-sync.yml` will post a remediation comment when it hits branch
protection — `/setup-git` walks through the fix.

### Upgrade Planning Files

When aidevops templates evolve, upgrade existing projects to the latest format:

```bash
aidevops upgrade-planning           # Interactive upgrade with backup
aidevops upgrade-planning --dry-run # Preview changes without modifying
aidevops upgrade-planning --force   # Skip confirmation prompt
```

This preserves your existing tasks while adding TOON-enhanced parsing, dependency tracking, and better structure.

**Automatic detection:** `aidevops update` now scans all registered projects for outdated planning templates (comparing TOON meta version numbers) and offers to upgrade them in-place with backups.

### Task Graph Visualization with Beads

[Beads](https://github.com/steveyegge/beads) provides task dependency tracking and graph visualization:

```bash
aidevops init beads              # Enable beads (includes planning)
```

**Task Dependencies:**

```markdown
- [ ] t001 First task
- [ ] t002 Second task blocked-by:t001
- [ ] t001.1 Subtask of t001
```

| Syntax | Meaning |
|--------|---------|
| `blocked-by:t001` | Task waits for t001 to complete |
| `blocks:t002` | This task blocks t002 |
| `t001.1` | Subtask of t001 (hierarchical) |

**Commands:**

| Command | Purpose |
|---------|---------|
| `/ready` | Show tasks with no open blockers |
| `/list-verify` | List verification queue (pending, passed, failed) |
| `/sync-beads` | Sync TODO.md/PLANS.md with Beads graph |
| `bd list` | List all tasks in Beads |
| `bd ready` | Show ready tasks (Beads CLI) |
| `bd graph <id>` | Show dependency graph for an issue |

**Architecture:** **[aidevops](https://aidevops.sh)** markdown files (TODO.md, PLANS.md) are the source of truth. Beads syncs from them for visualization.

**Optional Viewers:** Beyond the `bd` CLI, there are community viewers for richer visualization:
- `beads_viewer` (Python TUI) - PageRank, critical path analysis
- `beads-ui` (Web) - Live updates in browser
- `bdui` (React/Ink TUI) - Modern terminal UI
- `perles` (Rust TUI) - BQL query language

See `.agents/tools/task-management/beads.md` for complete documentation and installation commands.

**Your AI assistant now has agentic access to 30+ service integrations.**

### OpenAI Models in OpenCode (Recommended)

OpenCode with OpenAI is the current recommended aidevops setup. Delegation defaults are GPT-5.6 Luna **medium** for bounded low-consequence work, Terra **high** for established-pattern implementation, and GPT-6 Astra **low** for consequential decisions, architecture, and synthesis-heavy work. Headless thinking workers escalate Astra reasoning **low → medium → high** only on an evidence-bearing capability-limit signal; operational failures never trigger that escalation. Interactive children retain their parent's reasoning ceiling. See [model routing](.agents/tools/context/model-routing.md) for overrides and escalation boundaries.

Optimise through ordinary verified work, retries and parent repair rather than a prerequisite benchmark project. API prices are directional resource-cost estimates, not ChatGPT subscription allowance percentages. See [practical model and effort selection](.agents/tools/context/model-routing.md#practical-model-and-effort-selection) for the strategy, estimate scope and safe escalation rules.

**Authenticate via the pool:**

```bash
aidevops model-accounts-pool add openai
# Restart OpenCode after adding
```

**Why this is the default:**

- **Pragmatic defaults** — reversible choices improved through actual completion and repair evidence, not a claim of benchmark superiority
- **Tiered cost/latency split** — Luna for bounded work, Terra for general implementation, and Astra where deeper judgement is worth the extra budget
- **Provider isolation** — OpenAI accounts rotate independently from Anthropic, Google, Cursor, and local providers
- **Fallback-friendly** — Claude, Gemini, Cursor, and local models remain available when a task or rate-limit profile calls for them

### OpenCode Anthropic OAuth (Supported)

OpenCode includes Anthropic OAuth authentication natively — no API key needed. OAuth is covered by your Claude Pro/Max subscription at zero additional cost.

**Authenticate via the pool (recommended):**

```bash
aidevops model-accounts-pool add anthropic
# Opens browser OAuth flow — no API key required
# Restart OpenCode after adding
```

**Or via the OpenCode TUI:**

Open OpenCode → `Ctrl+A` → Select **Anthropic** → **Login with Claude.ai** → follow browser OAuth flow.

> **Note:** `opencode auth login` prompts for an API key, not OAuth. Use the commands above for subscription-based OAuth access.

**Benefits:**

- **Still fully supported** for users who prefer Claude models or already have Claude Pro/Max
- **Zero marginal cost** for Claude Pro/Max subscribers (covered by subscription)
- **Automatic token refresh** — no manual re-authentication needed
- **Multiple accounts** — add more accounts to the pool for automatic rotation when one hits rate limits
- **Beta features enabled** — extended thinking modes and latest features

### Cursor Models via Pool Proxy

Access Cursor Pro models (Composer 2, Claude 4.6 Opus/Sonnet, GPT-5.x, Gemini 3.1 Pro) in OpenCode through a local gRPC proxy that translates OpenAI-compatible requests to Cursor's protobuf/HTTP2 protocol.

**Setup:**

```bash
# Add your Cursor account to the pool (reads from local Cursor IDE)
oauth-pool-helper.sh add cursor

# Restart OpenCode — Cursor models appear in Ctrl+T model picker
```

**How it works:**

- Reads Cursor credentials from the local IDE state database
- Starts a gRPC proxy that speaks Cursor's native protocol (not the cursor-agent CLI)
- Discovers available models via gRPC and registers them as an OpenCode provider
- Supports true streaming, tool calling, and automatic token refresh
- Falls back gracefully if no Cursor accounts are in the pool

**Benefits:**

- **Zero additional cost** for Cursor Pro subscribers
- **True streaming** — responses stream as they arrive (not buffered)
- **Tool calling** — Cursor's native MCP tool protocol works through the proxy
- **Model discovery** — automatically detects all models available to your account
- **Pool rotation** — multiple accounts with LRU rotation and 429 failover

### Google AI Pool (Gemini CLI / Vertex AI)

Use your Google AI Pro, AI Ultra, or Workspace subscription for Gemini models. Tokens are injected as ADC bearer tokens that Gemini CLI, Vertex AI SDK, and the Gemini API pick up automatically.

**Setup:**

```bash
# Add your Google account to the pool (browser OAuth flow)
aidevops model-accounts-pool add google

# Restart OpenCode — token is injected as GOOGLE_OAUTH_ACCESS_TOKEN
```

**Supported plans:**

- **Google AI Pro** (~$25/mo) — daily Gemini CLI limits
- **Google AI Ultra** (~$65/mo) — higher daily limits
- **Google Workspace** with Gemini add-on — enterprise daily limits

**Isolation guarantee:** Google auth failures never affect Anthropic/OpenAI/Cursor providers. A Google 429 or auth error only puts the Google pool into cooldown.

### GitHub AI Agent Integration

Enable AI-powered issue resolution directly from GitHub. Comment `/oc fix this` on any issue and the AI creates a branch, implements the fix, and opens a PR.

**Security-first design** - The workflow includes:
- Trusted users only (OWNER/MEMBER/COLLABORATOR)
- `ai-approved` label required on issues before AI processing
- Prompt injection pattern detection
- Audit logging of all invocations
- 15-minute timeout and rate limiting

**Quick setup:**

```bash
# 1. Install the OpenCode GitHub App
# Visit: https://github.com/apps/opencode-agent

# 2. Add API key secret for your chosen provider
# Repository → Settings → Secrets → OPENAI_API_KEY or ANTHROPIC_API_KEY

# 3. Create required labels
gh label create "ai-approved" --color "0E8A16" --description "Issue approved for AI agent"
gh label create "security-review" --color "D93F0B" --description "Requires security review"
```

The secure workflow is included at `.github/workflows/opencode-agent.yml`.

**Usage:**

| Context | Command | Result |
|---------|---------|--------|
| Issue (with `ai-approved` label) | `/oc fix this` | Creates branch + PR |
| Issue | `/oc explain this` | AI analyzes and replies |
| PR | `/oc review this PR` | Code review feedback |
| PR Files tab | `/oc add error handling here` | Line-specific fix |

See `.agents/tools/git/opencode-github-security.md` for the full security documentation.

**Supported AI tool:** [OpenCode](https://opencode.ai/) is the recommended and tested AI coding tool for aidevops. All features, agents, and workflows are designed and tested for OpenCode first. The default OpenAI routing maps GPT-5.6 Luna, Terra, and GPT-6 Astra to the simple, standard, and thinking tiers. [Claude](https://claude.ai/) models (Anthropic) remain fully supported fallbacks, and other providers are tested as their capabilities change.

The native `ai_research` tool uses OpenCode's configured providers and canonical `simple`, `standard`, and `thinking` workload tiers; it does not require a specific provider credential.

**Recommended stack:**

- **[OpenCode](https://opencode.ai/)** - The recommended AI coding agent. Powerful agentic TUI/CLI with native MCP support, Tab-based agent switching, LSP integration, plugin ecosystem, and excellent DX. All aidevops features are designed and tested for OpenCode first.
- **[OpenCode Zen](https://opencode.ai/)** - Free tier of OpenCode with included models. Start working with AI straight away at no cost -- no API keys or subscriptions required.
- **OpenAI GPT-5.6 Luna / Terra / GPT-6 Astra** - Recommended tier mapping for aidevops today: Luna for bounded work, Terra for routine implementation, and Astra for consequential reasoning and high-impact decisions.
- **[Claude](https://claude.ai/)** (Anthropic) - Fully supported alternative provider. Claude models remain useful for fallback, cross-provider verification, and users with Claude Pro/Max OAuth access.
- **[Tabby](https://tabby.sh/)** - Recommended terminal. Colour-coded Profiles per project/repo, **auto-syncs tab titles with git/session context and marks OpenCode turns from the first submitted message as ⚪, 🔴, 🟡, or 🟢.**
- **[Zed](https://zed.dev/)** - Recommended editor. High-performance with AI integration (use with the OpenCode Agent Extension).

### Buzz Desktop OpenCode ACP compatibility

Buzz Desktop 0.5.4 can save an OpenCode managed agent without the required
`acp` runtime argument, causing ACP initialization to time out. On macOS,
`aidevops init` and `aidevops update` automatically reconcile affected records
after deploying the current helper. Close Buzz first; if it is running, setup
defers the change and reports the manual command.

```bash
aidevops buzz status    # Inspect compatibility state without changing it
aidevops buzz apply     # Add "acp" only to eligible empty argument lists
aidevops buzz rollback  # Restore only fields changed by aidevops
```

The migration preserves custom runtime arguments and unknown record fields,
uses private backups and rollback state, and fails closed for unsupported Buzz
versions or unsafe store paths. It never prints the managed-agent store, which
can contain fallback credentials.

### Troubleshooting Auth

If you see **"Anthropic Key Missing"**, **"OpenAI Key Missing"**, or the model stops responding, run these commands from any terminal — no working model session required.

**Step 1 — Check pool health**

```bash
aidevops model-accounts-pool status       # counts: available / rate-limited / auth-error
aidevops model-accounts-pool check        # live token validity test per account
```

**Step 2 — Fix based on what you see**

| Symptom | Command |
|---------|---------|
| OpenAI account shows `rate-limited` | `aidevops model-accounts-pool rotate openai` |
| Anthropic account shows `rate-limited` | `aidevops model-accounts-pool rotate anthropic` |
| All accounts in cooldown | `aidevops model-accounts-pool reset-cooldowns` |
| OpenAI account shows `auth-error` | `aidevops model-accounts-pool add openai` (re-auth) |
| Anthropic account shows `auth-error` | `aidevops model-accounts-pool add anthropic` (re-auth) |
| Pool is empty (no accounts) | `aidevops model-accounts-pool add openai` |
| Recently re-authenticated, still broken | `aidevops model-accounts-pool assign-pending openai` |
| Google Gemini CLI rate-limited | `aidevops model-accounts-pool rotate google` |
| Google token expired | `aidevops model-accounts-pool add google` (re-auth) |

**Step 3 — If still broken, re-add the account**

```bash
aidevops model-accounts-pool add openai        # ChatGPT Plus/Pro
aidevops model-accounts-pool add anthropic     # Claude Pro/Max — opens browser OAuth
aidevops model-accounts-pool add cursor        # Cursor Pro (reads from local IDE)
aidevops model-accounts-pool add google        # Google AI Pro/Ultra/Workspace — browser OAuth
aidevops model-accounts-pool import claude-cli # Import from existing Claude CLI auth
```

Restart OpenCode after any `add`, `rotate`, or `reset-cooldowns` to pick up the new credentials.

**Full command reference**

```bash
aidevops model-accounts-pool status            # Pool health at a glance
aidevops model-accounts-pool list              # Per-account detail + expiry
aidevops model-accounts-pool check             # Live API validity test
aidevops model-accounts-pool rotate [provider] # Switch to next available account NOW
aidevops model-accounts-pool reset-cooldowns   # Clear all rate-limit cooldowns
aidevops model-accounts-pool assign-pending <p># Assign stranded pending token
aidevops model-accounts-pool remove <p> <email># Remove an account
```

> **Note:** `reset-cooldowns` clears cooldowns in the pool file. If OpenCode is already running, the in-memory token endpoint cooldown is only cleared when OpenCode restarts or when you use the `/model-accounts-pool reset-cooldowns` slash command inside an active session.

**If you prefer guided help:** Open OpenCode with a free model (OpenCode Zen includes free models that don't require any API key or subscription) and run the auth troubleshooting agent by typing:

```text
@auth-troubleshooting
```

The agent contains the full recovery flow and symptom table. Free models work fine for this — no paid subscription needed.

### Terminal Tab Title Sync

Your terminal tab/window title automatically shows `repo/branch` context when working in git repositories. Interactive OpenCode tabs add ⚪ as soon as the first root-session message is submitted and keep it when the initial title becomes descriptive, 🔴 while retrying after an error, 🟡 while awaiting permission, and 🟢 when finished and awaiting input. This helps identify both the work context and session state across multiple terminal sessions.

**Supported terminals:** [Tabby](https://tabby.sh/), [cmux](https://cmux.dev/), [iTerm2](https://iterm2.com/), [Kitty](https://sw.kovidgoyal.net/kitty/), [Alacritty](https://alacritty.org/), [WezTerm](https://wezfurlong.org/wezterm/), [Hyper](https://hyper.is/), and most xterm-compatible terminals.

**How it works:** The `pre-edit-check.sh` script's primary role is enforcing git workflow protection (blocking edits on main/master branches). As a secondary, non-blocking action, it updates the terminal title via escape sequences. The OpenCode plugin listens for root-session user-message, status, and permission events and updates the same title without changing the stored OpenCode session name. No configuration is needed when dynamic terminal titles are enabled.

**Example format:** `{repo}/{branch-type}/{description}`

See `.agents/tools/terminal/terminal-title.md` for customization options.

**Companion tool:**

- **[claude-code CLI](https://claude.ai/)** - Called from within OpenCode for sub-tasks and headless dispatch

**Collaborator compatibility:** Projects initialized with `aidevops init` include pointer files (`.cursorrules`, `.windsurfrules`, etc.) that reference `AGENTS.md`, helping collaborators using other editors find project context. aidevops does not install into or configure those tools.

**Repo courtesy files:** `aidevops init` scaffolds standard repo files if they don't exist: `DESIGN.md` for GUI/interface repos, `README.md`, `LICENCE` (MIT), `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`. Author name and email are auto-detected from git config. Existing files are never overwritten.

## **Core Capabilities**

**AI-First Infrastructure Management:**

- SSH server access, remote command execution, API integrations
- DNS management, application deployment, email monitoring
- Git platform management, domain purchasing, setup automation
- [WordPress](https://wordpress.org/) management, credential security, code auditing

**Autonomous Orchestration:**

- **[Pulse supervisor](#pulse-supervisor-autonomous-ai-operations)** - Autonomous AI supervisor runs every 2 minutes via launchd — merges ready PRs, dispatches workers, kills stuck processes, detects orphaned PRs, syncs TODO state with GitHub, triages quality findings, and advances missions. No human in the loop
- **[Missions](#missions-multi-day-autonomous-projects)** - Multi-day autonomous projects: `/mission` scopes a high-level goal into milestones and features. The pulse dispatches workers, validates milestones, tracks budget, and advances through the project automatically (`mission-dashboard-helper.sh`)
- **[Multi-model verification](#multi-model-verification-cross-provider-safety)** - Destructive operations (force push, production deploy, data migration) are verified by a second AI model from a different provider before execution. Different providers have different failure modes, so correlated hallucinations are rare
- **Supervisor** - SQLite state machine dispatches tasks to parallel AI agents with retry cycles, batch management, and cron scheduling
- **Runners** - Named headless agent instances with persistent identity, instructions, and memory namespaces
- **`/runners` command** - Batch dispatch from task IDs, PR URLs, or descriptions with concurrency control and progress monitoring
- **Self-hosted runner operations** - GitHub runner lifecycle, storage, Docker foreground mode, systemd timers, and cleanup race guidance for reliable local/hosted worker capacity
- **Mailbox** - SQLite-backed inter-agent messaging for coordination across parallel sessions
- **Worktree isolation** - Each agent works on its own branch in a separate directory, no merge conflicts
- **Budget tracking** - Append-only cost log (`budget-tracker-helper.sh`) with burn-rate analysis and `/budget-analysis` command for model routing decisions
- **Observability** - LLM request/tool capture plus append-only, redacted runtime lifecycle/state evidence with worker correlation and causal lineage in the existing local SQLite database
- **Rate limits and API budget diagnostics** - Per-provider rate-limit configuration, secondary cooldown capture, reset-aware pacing, and compact API budget summaries for pulse and worker decisions

**Project Intelligence:**

- **[Bundles](#project-bundles-auto-configuration)** - Project-type presets that auto-configure model tiers, quality gates, and agent routing per repo. 7 built-in bundles (web-app, library, cli-tool, content-site, infrastructure, agent, schema) with auto-detection from marker files (`bundle-helper.sh`)
- **TTSR rules** - Soft rule engine (`ttsr-rule-loader.sh`) with `.agents/rules/` directory for AI output correction (e.g., no-edit-on-main, no-glob-for-discovery)
- **Unified review** - `/review` applies one evidence and finding contract to issues, PRs, local patches, branches, and commits. Workflow-owned findings are verified and repaired autonomously; ad-hoc human reviews can remain report-only
- **Cross-review** - `/cross-review` dispatches the same prompt to multiple AI models in parallel, diffs results, and optionally auto-scores via a judge model
- **Local models** - Run AI models locally via llama.cpp for free, private, offline inference (`local-model-helper.sh`) with HuggingFace GGUF model management
- **Tech stack lookup** - `/tech-stack` detects technology stacks of URLs or finds sites using specific technologies (Wappalyzer, httpx, nuclei, BuiltWith)
- **IP reputation** - `ip-reputation-helper.sh` checks IP addresses against multiple reputation databases (Spamhaus, ProxyCheck, AbuseIPDB) before VPS purchase or deployment
- **Mobile app guidance** - Expo, Swift/Xcode, App Store Connect, simulator automation, push/onboarding/monetisation/testing, and mobile web previews through `serve-sim`
- **GUI control plane planning** - Local-first product scope, stack and repo-layout ADRs, GUI trust boundaries, and threat model for future aidevops UI surfaces

**Conversational Memory & Entity System:**

- **Entity memory** - Cross-channel relationship continuity (`entity-helper.sh`): people, agents, and services tracked across Matrix, SimpleX, email, and CLI with versioned profiles
- **Conversational memory** - Per-conversation context management (`conversation-helper.sh`): idle detection, immutable summaries, tone profile extraction
- **Three-layer architecture** - Layer 0 (immutable raw log), Layer 1 (tactical summaries), Layer 2 (strategic entity profiles) in shared SQLite

**Communications:**

- **SimpleX bot** - Channel-agnostic gateway with SimpleX Chat as first adapter for AI agent dispatch (`simplex-bot/`)
- **Matterbridge** - Multi-platform chat bridge connecting 20+ platforms including Matrix, Discord, Telegram, Slack, IRC, WhatsApp, XMPP (`matterbridge-helper.sh`)
- **Account knowledge and approval-bound social operations** - Bounded account collection uses guarded X, named PRAW Reddit, and `youtube.readonly` user-OAuth YouTube adapters with stable identity, independent checkpoints, and explicit unsupported coverage. Owner-only immediate/scheduled posts, replies, likes/upvotes, bookmarks/saves, receipts, reconciliation, and mention/reply workflow state remain a separate fixed-provider subsystem. Model-provider auth such as OpenCode xAI/Grok remains separate from social API OAuth (`content/social-xurl.md`, `content/social-reddit.md`, `content/social-youtube.md`, `knowledge-social-helper.sh`)
- **Localdev** - Local development environment manager with dnsmasq, Traefik, mkcert for production-like `.local` domains with HTTPS (`localdev-helper.sh`)

**MCP Toolkit:**

- **MCPorter** - Discover, call, compose, and generate CLIs/typed clients for MCP servers (`mcporter` npm package)
- **OpenAPI Search** - Search and explore any OpenAPI specification via MCP (zero install, Cloudflare Worker)
- **Cloudflare Code Mode** - Full Cloudflare API (2,500+ endpoints) via 2 tools in ~1,000 tokens

**Unified Interface:**

- Standardized commands across all providers
- Automated SSH configuration and multi-account support for all services
- Security-first design with comprehensive logging, code quality reviews, and continual feedback-based improvement

**Quality Control & Monitoring:**

- **Multi-Platform Analysis**: SonarCloud, CodeFactor, Codacy, CodeRabbit, Qlty, Snyk
- **Review gate preferences**: choose whether true review-bot rate limits block merges (`aidevops review-gate owner/repo wait`) or allow merge with follow-up quality coverage (`aidevops review-gate owner/repo pass`, the default). Per-tool overrides are supported, for example `aidevops review-gate owner/repo --tool coderabbitai wait`. Failed, skipped, or placeholder bot states are not treated as rate limits and continue to block until a real review/status appears or a human resolves them.
- **Performance Auditing**: PageSpeed Insights, Lighthouse, WebPageTest, Core Web Vitals (`/performance` command)
- **SEO Toolchain**: 40+ SEO subagents including Semrush, Ahrefs, ContentKing, Screaming Frog, Bing Webmaster Tools, Rich Results Test, programmatic SEO, analytics tracking, schema validation, content analysis, keyword mapping, and AI readiness
- **SEO Debugging**: Open Graph validation, favicon checker, social preview testing
- **Email Deliverability**: SPF/DKIM/DMARC/MX validation, blacklist checking
- **Uptime Monitoring**: Updown.io integration for website and SSL monitoring

## **Imported Skills**

aidevops includes curated skills imported from external sources. Skills support automatic update tracking:

| Skill | Source | Description |
|-------|--------|-------------|
| **cloudflare-platform** | [dmmulroy/cloudflare-skill](https://github.com/dmmulroy/cloudflare-skill) | 60 Cloudflare products: Workers, Pages, D1, R2, KV, Durable Objects, AI, networking, security |
| **heygen** | [heygen-com/skills](https://github.com/heygen-com/skills) | AI avatar video creation API: avatars, voices, video generation, streaming, webhooks |
| **remotion** | [remotion-dev/skills](https://github.com/remotion-dev/skills) | Programmatic video creation with React, animations, rendering |
| **video-prompt-design** | [snubroot/Veo-3-Meta-Framework](https://github.com/snubroot/Veo-3-Meta-Framework) | AI video prompt engineering - 7-component meta prompt framework for Veo 3 |
| **animejs** | [animejs.com](https://animejs.com) | JavaScript animation library patterns and API (via Context7) |
| **caldav-calendar** | [ClawdHub](https://clawdhub.com/Asleep123/caldav-calendar) | CalDAV calendar sync via vdirsyncer + khal (iCloud, Google, Fastmail, Nextcloud) |
| **proxmox-full** | [ClawdHub](https://clawdhub.com/mSarheed/proxmox-full) | Complete Proxmox VE hypervisor management via REST API |

**CLI Commands:**

```bash
aidevops skill add <owner/repo>    # Import a skill from GitHub
aidevops skill add clawdhub:<slug> # Import a skill from ClawdHub
aidevops skill list                # List imported skills
aidevops skill check               # Check for upstream updates
aidevops skill update [name]       # Update specific or all skills
aidevops skill scan [name]         # Security scan skills (Cisco Skill Scanner)
aidevops skill remove <name>       # Remove an imported skill
```

Skills are registered in `~/.aidevops/agents/configs/skill-sources.json` with upstream tracking for update detection.

**Security Scanning:**

Imported skills are automatically security-scanned using [Cisco Skill Scanner](https://github.com/cisco-ai-defense/skill-scanner) when installed. Scanning runs on both initial import and updates -- pulling a new version of a skill triggers the same security checks as the first import. CRITICAL/HIGH findings block the operation; MEDIUM/LOW findings warn but allow. Telemetry is disabled - no data is sent to third parties.

When a [VirusTotal](https://www.virustotal.com/) API key is configured (`aidevops secret set VIRUSTOTAL_MARCUSQUINN`), an advisory second layer scans file hashes against 70+ AV engines and checks domains/URLs referenced in skill content. VT scans are non-blocking -- the Cisco scanner remains the security gate.

| Scenario | Security scan runs? | CRITICAL/HIGH blocks? |
|----------|--------------------|-----------------------|
| `aidevops skill add <source>` | Yes | Yes |
| `aidevops skill update [name]` | Yes | Yes |
| `aidevops skill add <source> --force` | Yes | Yes |
| `aidevops skill add <source> --skip-security` | Yes (reports only) | No (warns) |
| `aidevops skill scan [name]` | Yes (standalone) | Report only |

The `--force` flag only controls file overwrite behavior (replacing an existing skill without prompting). To bypass security blocking, use `--skip-security` explicitly -- this separation ensures that routine updates and re-imports never silently skip security checks.

Scan results are logged to [`.agents/SKILL-SCAN-RESULTS.md`](.agents/SKILL-SCAN-RESULTS.md) automatically on each batch scan and skill import, providing a transparent audit trail of security posture over time.

**Browse community skills:** [skills.sh](https://skills.sh) | [ClawdHub](https://clawdhub.com) | **Specification:** [agentskills.io](https://agentskills.io)

**Reference:**
- [Agent Skills Specification](https://agentskills.io/specification) - The open format for SKILL.md files
- [skills.sh Leaderboard](https://skills.sh) - Discover popular community skills
- [ClawdHub](https://clawdhub.com) - Skill registry with vector search (OpenClaw ecosystem)
- [vercel-labs/add-skill](https://github.com/vercel-labs/add-skill) - The upstream CLI tool (aidevops uses its own implementation)
- [anthropics/skills](https://github.com/anthropics/skills) - Official Anthropic example skills
- [agentskills/agentskills](https://github.com/agentskills/agentskills) - Specification source and reference library

## **Agent Sources (Private Repos)**

Sync agents from private Git repositories into the framework. Private repos keep their own agents, helper scripts, and slash commands — `aidevops sources sync` deploys them alongside the core agents.

```bash
aidevops sources add ~/Git/my-private-agents     # Register a local repo
aidevops sources add-remote git@github.com:u/r.git  # Clone and register a remote repo
aidevops sources list                             # List configured sources
aidevops sources sync                             # Sync all sources
aidevops sources remove my-private-agents         # Remove a source
```

**How it works:** Private repos contain a `.agents/` directory with agent subdirectories. Agents with `mode: primary` in their frontmatter are symlinked to the agents root for auto-discovery as primary agent tabs. Markdown files with `agent:` frontmatter are deployed as `/slash` commands. All sources sync automatically during `aidevops update`.

**Reference:** `.agents/aidevops/agent-sources.md`

## **Agent Design Patterns**

aidevops implements proven agent design patterns identified by [Lance Martin (LangChain)](https://x.com/RLanceMartin/status/2009683038272401719).

| Pattern | Description | aidevops Implementation |
|---------|-------------|------------------------|
| **Give Agents a Computer** | Filesystem + shell for persistent context | `~/.aidevops/.agent-workspace/`, 2,010+ helper scripts |
| **Multi-Layer Action Space** | Few tools, push actions to computer | Per-agent MCP filtering (~12-20 tools each) |
| **Knowledge Graph Routing** | Indexed, cross-referenced agents instead of isolated skills | `subagent-index.toon` routes context across subagent profiles and the wider skills/documentation library — agents discover related context through the graph, not just their own file |
| **Progressive Disclosure** | Load context on-demand | Subagent routing with content summaries, YAML frontmatter, read-on-demand |
| **Offload Context** | Write results to filesystem | `.agent-workspace/work/[project]/` for persistence |
| **Cache Context** | Prompt caching for cost | Stable instruction prefixes |
| **Isolate Context** | Sub-agents with separate windows | Subagent files with specific tool permissions |
| **Multi-Agent Orchestration** | Coordinate parallel agents | TOON mailbox, agent registry, supervisor dispatch |
| **Compaction Resilience** | Preserve context across compaction | OpenCode plugin injects dynamic state at compaction time |
| **Ralph Loop** | Iterative execution until complete | `/full-loop`, `full-loop-helper.sh` |
| **Evolve Context** | Learn from sessions | `/remember`, `/recall` with SQLite FTS5 + opt-in semantic search |
| **Pattern Tracking** | Learn what works/fails | `/patterns` command, `memory-helper.sh` |
| **Token-Efficient Serialisation** | Minimise context overhead for structured data | [TOON format](https://github.com/marcusquinn/aidevops/blob/main/.agents/toon-format.md) — 20-60% token reduction vs JSON/YAML for agent indexes, registries, and data exchange |
| **Token-Efficient Tool Output** | Summarise noisy terminal output without hiding evidence | RTK is installed by default during setup; start with `rtk-helper.sh` for compact supported summaries, then rerun raw/direct commands when filtered output is insufficient; bypass compression for file reads, JSON assertions, exact diffs, security scans, and other verbatim evidence |
| **Cost-Aware Routing** | Match model to task complexity | `model-routing.md` with provider-aware tier guidance, `/route` command |
| **Model Comparison** | Compare models side-by-side | `/compare-models` (live data), `/compare-models-free` (offline) |
| **Response Scoring** | Evaluate actual model outputs | `/score-responses` with structured criteria |

**Key insight**: Context is a finite resource with diminishing returns. aidevops treats every token as precious - loading only what's needed, when it's needed.

See `.agents/aidevops/architecture.md` for detailed implementation notes and references.

### Multi-Agent Orchestration

Run multiple AI agents in parallel on separate branches, coordinated through a lightweight mailbox system. Each agent works independently in its own git worktree while the supervisor manages task distribution and status reporting.

**Architecture:**

```text
Supervisor (pulse loop)
├── Agent Registry (TOON format - who's active, what branch, idle/busy)
├── Mailbox System (SQLite WAL-mode, indexed queries)
│   ├── task_assignment → worker inbox
│   ├── status_report → coordinator outbox
│   └── broadcast → all agents
└── Model Routing (tier-based: GPT-5.6 Luna / Terra / GPT-6 Astra / provider fallbacks)
```

**Key components:**

| Component | Script | Purpose |
|-----------|--------|---------|
| Mailbox | `mail-helper.sh` | SQLite-backed inter-agent messaging (send, check, broadcast, archive) |
| Supervisor | `supervisor-helper.sh` | Autonomous multi-task orchestration with SQLite state machine, batches, retry cycles, cron scheduling, auto-pickup from TODO.md |
| Registry | `mail-helper.sh register` | Agent registration with role, branch, worktree, heartbeat |
| Model routing | `model-routing.md`, `/route` | Cost-aware routing across OpenAI, Anthropic, Gemini, Cursor, Grok, and local providers |
| Budget tracking | `budget-tracker-helper.sh` | Append-only cost log for model routing decisions |
| Observability | `observability.mjs`, `runtime-events.mjs` | LLM/tool metrics plus redacted lifecycle, lineage, and state evidence in one local SQLite database |

**How it works:**

1. Each agent registers on startup (`mail-helper.sh register --role worker`)
2. Supervisor runs periodic pulses (`supervisor-helper.sh pulse`)
3. Pulse collects status reports, dispatches queued tasks to idle workers
4. Agents send completion reports back via mailbox
5. SQLite WAL mode + `busy_timeout` handles concurrent access (79x faster than previous file-based system)

**Compaction plugin** (`.agents/plugins/opencode-aidevops/`): When OpenCode compacts context (at ~200K tokens), the plugin injects current session state - agent registry, pending mailbox messages, git context, and relevant memories - ensuring continuity across compaction boundaries.

**Custom system prompt** (`.agents/prompts/build.txt`): Based on upstream OpenCode with aidevops-specific overrides for tool preferences, professional objectivity, and per-model reinforcements for weaker models.

**Subagent index** (`.agents/subagent-index.toon`): Compressed TOON routing table listing all agents, subagents, workflows, and scripts with model tier assignments - enables fast agent discovery without loading full markdown files.

## **Autonomous Orchestration & Parallel Agents**

**Why this matters:** Long-running tasks -- batch PR reviews, multi-site audits, large refactors, multi-day feature projects -- are where AI agents deliver the most value. Instead of babysitting one task at a time, the supervisor dispatches work to parallel agents, each in its own git worktree, with automatic retry, progress tracking, and batch completion reporting.

### Pulse Supervisor: Autonomous AI Operations

The pulse is the heartbeat of aidevops — an autonomous AI supervisor that runs every 2 minutes via launchd. There is no human at the terminal. It manages the entire development pipeline across all repos registered with `pulse: true`.

**What it does each cycle:**

| Phase | Action |
|-------|--------|
| **Capacity check** | Circuit breaker, dynamic worker slots calculated from available RAM |
| **Merge ready PRs** | Green CI + no blocking reviews → squash merge (free — no worker slot needed) |
| **Fix failing PRs** | Dispatch a worker to fix CI failures or address review feedback |
| **Detect stuck work** | PRs open 6+ hours with no activity → flag or close and re-file |
| **Dispatch workers** | Route open issues to available worker slots, respecting priority and `blocked-by:` dependencies |
| **Advance missions** | Check active multi-day missions, dispatch features, validate milestones, track budget |
| **Triage quality** | Read daily quality sweep findings (ShellCheck, SonarCloud, Codacy, CodeRabbit), create issues for actionable findings |
| **Sync TODOs** | Create GitHub issues for unsynced TODO entries, commit ref changes |
| **Respect API budget** | Use cached/prefetched GitHub metadata, cooldown headers, and ramp pacing before spending more API calls |
| **Kill stuck workers** | Workers running 3+ hours with no PR are killed to free slots |
| **Detect orphaned PRs** | Open PRs with no active worker and no activity for 6+ hours are flagged for re-dispatch |

**Operational intelligence:**

- **Struggle-ratio** — computes `messages / max(1, commits)` for each active worker. High ratio (>30) with >30 min elapsed and zero commits flags the worker as "struggling". Ratio >50 after 1 hour flags "thrashing". Informational signal — the supervisor LLM decides the action (kill, wait, re-dispatch with more context)
- **Circuit breaker** — prevents cascading failures by tracking success/failure rates and tripping when error rate exceeds threshold
- **Dynamic concurrency** — worker slot count adapts to available RAM, not a hardcoded constant
- **API budget diagnostics** — compact reports show GitHub core/search usage, cooldown provenance, cached PR metadata freshness, and pacing decisions before pulse burns through API quota
- **Worker failure families** — headless runtime errors, local runtime diagnostics, blocked-by lookup gaps, provider quota/credit exhaustion, and review-thread remediation issues are classified for targeted redispatch
- **Stale assignment recovery** — tasks assigned to workers that died (no active process, no PR, 3+ hours stale) are automatically unassigned and made available for re-dispatch
- **Priority ordering** — green PRs (free merge) > failing PRs (closer to done) > high-priority/bug issues > active mission features > product repos > smaller tasks > oldest
- **Repository campaign shadow** — an opt-in, default-off projection preserves an oldest-ready frontier, semantic work state, and device-aware runner lanes without changing legacy dispatch or GitHub authority. See `.agents/reference/repository-campaigns.md`

**The pulse is an LLM, not a script.** It reads issue bodies, assesses context, and uses judgment. When it encounters something unexpected — an issue body that says "completed", a task with no clear description, a label that doesn't match reality — it handles it the way a competent human manager would.

```bash
# Pulse runs automatically via launchd (every 2 minutes)
# Manual trigger:
opencode run "/pulse"
```

**See:** `.agents/scripts/commands/pulse.md` for the full supervisor specification.

### Missions: Multi-Day Autonomous Projects

Missions are the highest-level orchestration primitive — autonomous multi-day projects that break a high-level goal into milestones, features, and validation criteria. The pulse supervisor advances them automatically.

```bash
# Scope a mission interactively
/mission "Redesign the landing pages for mobile-first with A/B testing"
```

**How missions work:**

1. `/mission` scopes the goal into milestones with features and acceptance criteria
2. Each feature becomes a TODO entry tagged `mission:mNNN` with a GitHub issue
3. The pulse dispatches features as regular workers (respecting `MAX_WORKERS`)
4. When all features in a milestone complete, the pulse dispatches a **validation worker** to verify integration
5. Passed milestones advance automatically — the next milestone's features are dispatched
6. Budget tracking pauses the mission if any category exceeds the alert threshold (default 80%)

**Two execution modes:**

| Mode | Workflow | Best for |
|------|----------|----------|
| **Full** | Worktree + PR per feature, standard review flow | Production code, collaborative projects |
| **POC** | Direct commits, skip ceremony | Prototypes, experiments, proof-of-concept |

**Mission state** is tracked in a JSON file committed to the repo. Each pulse cycle reads the state, acts on it, and commits updates — so any session (or the next pulse) can pick up where the last one left off.

**See:** `.agents/workflows/mission-orchestrator.md` for the full orchestrator specification, `.agents/scripts/commands/dashboard.md` for the mission progress dashboard.

### Multi-Model Verification: Cross-Provider Safety

High-stakes operations are verified by a second AI model from a different provider before execution. This catches single-model hallucinations before destructive operations cause irreversible damage.

**When verification triggers:**

| Risk Level | Examples | Action |
|------------|----------|--------|
| **Critical** | `git push --force` to main, `DROP DATABASE`, production deploy | Blocked unless second model agrees |
| **High** | Force push to task ref, data migration, secret exposure | Warned, verification recommended |
| **Medium** | Bulk file deletion, config changes | Logged |
| **Low** | Normal edits, test runs | No verification |

**How it works:**

1. `pre-edit-check.sh` screens operations against the high-stakes taxonomy
2. For critical/high operations, `verify-operation-helper.sh` sends the operation context to a second model (different provider than the primary)
3. The verifier independently assesses whether the operation is safe
4. On disagreement, the operation is blocked (critical) or warned (high)
5. All verification decisions are logged for audit

**Why cross-provider?** Same-provider models share training data and failure modes. A GPT hallucination is unlikely to be reproduced by Claude or Gemini, and vice versa. The verifier uses the cheapest suitable model tier, so cost is minimal per check.

**Configuration:** Per-repo via `.agents/reference/high-stakes-operations.md`. Opt-out with `VERIFY_ENABLED=false` (not recommended).

**See:** `.agents/tools/verification/parallel-verify.md` for the verification agent specification.

### Project Bundles: Auto-Configuration

Bundles are project-type presets that auto-configure model tiers, quality gates, and agent routing per repo. Instead of manually configuring each project, bundles detect what kind of project you're working on and apply sensible defaults.

**Built-in bundles:**

| Bundle | Auto-detected by | Model default | Quality gates | Agent routing |
|--------|-----------------|---------------|---------------|---------------|
| `web-app` | `package.json` + framework markers | standard | Full (lint, test, build, a11y) | Build+ default |
| `library` | `package.json` with `main`/`exports` | standard | Full + API docs check | Build+ default |
| `cli-tool` | `bin` field in package.json | standard | ShellCheck, test | Build+ default |
| `content-site` | CMS markers, `wp-config.php` | fast | Lighthouse, SEO | Marketing for content tasks |
| `infrastructure` | `Dockerfile`, `terraform/`, `ansible/` | standard | ShellCheck, security scan | Build+ default |
| `agent` | `AGENTS.md`, `.agents/` | thinking | Agent review, prompt quality | Build+ default |

**Resolution priority:** Explicit `bundle` field in `repos.json` > `.aidevops.json` project config > auto-detection from marker files.

**CLI:**

```bash
bundle-helper.sh detect <repo-path>    # Auto-detect bundle type
bundle-helper.sh resolve <repo-path>   # Show resolved config (with overrides)
bundle-helper.sh show <bundle-name>    # Show bundle defaults
bundle-helper.sh list                  # List all available bundles
```

**See:** `.agents/bundles/` for bundle definitions, `.agents/scripts/bundle-helper.sh` for the CLI.

### Parallel Agents & Headless Dispatch

Run multiple AI sessions concurrently with isolated contexts. Named **runners** provide persistent agent identities with their own instructions and memory.

| Feature | Description |
|---------|-------------|
| **Headless dispatch** | `headless-runtime-helper.sh run` provides canonical model routing, retries, and session isolation |
| **Durable one-shot scheduling** | `aidevops schedule once` queues private, restart-safe delayed work without fake recurring jobs or sleeper processes |
| **Runners** | Named agent instances with per-runner AGENTS.md, config, and run logs (`runner-helper.sh`) |
| **Self-hosted runner runbooks** | GitHub runner storage, lifecycle, Docker foreground mode, timer freshness, and cleanup-race guidance (`.agents/reference/github-self-hosted-runners.md`) |
| **Session management** | Resume sessions with `-s <id>` or `-c`, fork with SDK |
| **Memory namespaces** | Per-runner memory isolation with shared access when needed |
| **SDK orchestration** | `@opencode-ai/sdk` for TypeScript parallel dispatch via `Promise.all` |
| **Matrix integration** | Chat-triggered dispatch via self-hosted Matrix (optional) |

```bash
# Create a named runner
runner-helper.sh create code-reviewer --description "Reviews code for security and quality"

# Dispatch a task (one-shot)
runner-helper.sh run code-reviewer "Review src/auth/ for vulnerabilities"

# Queue one delayed execution and inspect its lifecycle
aidevops schedule once --after 2h --name "Review authentication" \
  --dir ~/Git/example --prompt-file ~/.config/aidevops/prompts/auth-review.md
aidevops schedule status

# Dispatch against warm server (faster, no MCP cold boot)
opencode serve --port 4096 &
runner-helper.sh run code-reviewer "Review src/auth/" --attach http://localhost:4096

# Parallel dispatch via CLI
opencode run --attach http://localhost:4096 --title "Review" "Review src/auth/" &
opencode run --attach http://localhost:4096 --title "Tests" "Generate tests for src/utils/" &
wait

# List runners and status
runner-helper.sh list
runner-helper.sh status code-reviewer
```

**Architecture:**

```text
OpenCode Server (opencode serve)
├── Session 1 (runner/code-reviewer)
├── Session 2 (runner/seo-analyst)
└── Session 3 (scheduled-task)
         ↑
    HTTP API / SSE Events
         ↑
┌────────┴────────┐
│  Dispatch Layer │ ← runner-helper.sh, cron, Matrix bot, SDK
└─────────────────┘
```

**Example runner templates:** [code-reviewer](.agents/tools/ai-assistants/runners/code-reviewer.md), [seo-analyst](.agents/tools/ai-assistants/runners/seo-analyst.md) - copy and customize for your own runners.

**Matrix bot dispatch** (optional): Bridge Matrix chat rooms to runners for chat-triggered AI. Accepted text events normalize through the provider-neutral contract and are durably claimed before dispatch. SQLite context is isolated by room and actor; idle sessions compact to summaries without deleting immutable interaction history.

```bash
# Setup Matrix bot (interactive wizard)
matrix-dispatch-helper.sh setup

# Map rooms to runners (mutable context is isolated by room and actor)
matrix-dispatch-helper.sh map '!dev-room:server' code-reviewer
matrix-dispatch-helper.sh map '!seo-room:server' seo-analyst

# Start bot (daemon mode)
matrix-dispatch-helper.sh start --daemon

# In Matrix room: "!ai Review src/auth.ts for security issues"

# Manage sessions
matrix-dispatch-helper.sh sessions list
matrix-dispatch-helper.sh sessions stats
```

**See:** [headless-dispatch.md](.agents/tools/ai-assistants/headless-dispatch.md) for full documentation including parallel vs sequential decision guide, SDK examples, CI/CD integration, and custom agent configuration. [matrix-bot.md](.agents/services/communications/matrix-bot.md) for Matrix bot setup including Cloudron Synapse guide and session persistence.

### Self-Improving Agent System

Agents that learn from experience and contribute improvements:

| Phase | Description |
|-------|-------------|
| **Review** | Analyze memory for success/failure patterns (`memory-helper.sh`) |
| **Refine** | Generate and apply improvements to agents |
| **Test** | Validate in isolated OpenCode sessions |
| **PR** | Contribute to community with privacy filtering |

**Safety guardrails:**
- Worktree isolation for all changes
- Human approval required for PRs
- Mandatory privacy filter (secretlint + pattern redaction)
- Dry-run default, explicit opt-in for PR creation
- Audit log to memory

### Agent Testing Framework

Test agent behavior through isolated AI sessions with automated validation:

```bash
# Create a test suite
agent-test-helper.sh create my-tests

# Run tests (auto-detects claude or opencode CLI)
agent-test-helper.sh run my-tests

# Quick single-prompt test
agent-test-helper.sh run-one "What tools do you have?" --expect "bash"

# Before/after comparison for agent changes
agent-test-helper.sh baseline my-tests   # Save current behavior
# ... modify agents ...
agent-test-helper.sh compare my-tests    # Detect regressions
```

Test suites are JSON files with prompts and validation rules (`expect_contains`, `expect_not_contains`, `expect_regex`, `min_length`, `max_length`). Results are saved for historical tracking.

**See:** `agent-testing.md` subagent for full documentation and example test suites.

### Voice Bridge - Talk to Your AI Agent

Speak naturally to your AI coding agent and hear it respond. The voice bridge connects your microphone to OpenCode via a fast local pipeline -- ask questions, give instructions, execute tasks, all by voice.

```text
Mic → Silero VAD → Whisper MLX (1.4s) → OpenCode (4-6s) → Edge TTS (0.4s) → Speaker
```

**Round-trip: ~6-8 seconds** on Apple Silicon. The agent can edit files, run commands, create PRs, and confirm what it did -- all via voice.

**Quick start:**

```bash
# Start a voice conversation (installs deps automatically)
voice-helper.sh talk

# Choose engines and voice
voice-helper.sh talk whisper-mlx edge-tts en-GB-SoniaNeural
voice-helper.sh talk whisper-mlx macos-say    # Offline mode

# Utilities
voice-helper.sh devices      # List audio input/output devices
voice-helper.sh voices       # List available TTS voices
voice-helper.sh benchmark    # Test STT/TTS/LLM speeds
voice-helper.sh status       # Check component availability
```

**Features:**

| Feature | Details |
|---------|---------|
| **Swappable STT** | whisper-mlx (fastest on Apple Silicon), faster-whisper (CPU) |
| **Swappable TTS** | edge-tts (best quality), macos-say (offline), facebookMMS (local) |
| **Voice exit** | Say "that's all", "goodbye", "all for now" to end naturally |
| **STT correction** | LLM sanity-checks transcription errors before acting (e.g. "test.txte" → "test.txt") |
| **Task execution** | Full tool access -- edit files, git operations, run commands |
| **Session handback** | Conversation transcript output on exit for calling agent context |
| **TUI compatible** | Graceful degradation when launched from AI tool's Bash (no tty) |

**How it works:** The bridge uses `opencode run --attach` to connect to a running OpenCode server for low-latency responses (~4-6s vs ~30s cold start). It automatically starts `opencode serve` if not already running.

**Requirements:** Apple Silicon Mac (for whisper-mlx), Python 3.10+, internet (for edge-tts). The voice helper installs Python dependencies automatically into the S2S venv.

### Speech-to-Speech Pipeline (Advanced)

For advanced use cases (custom LLMs, server/client deployment, multi-language, phone integration), the full [huggingface/speech-to-speech](https://github.com/huggingface/speech-to-speech) pipeline is also available:

```bash
speech-to-speech-helper.sh setup              # Install pipeline
speech-to-speech-helper.sh start --local-mac  # Run on Apple Silicon
speech-to-speech-helper.sh start --cuda       # Run on NVIDIA GPU
speech-to-speech-helper.sh start --server     # Server mode (remote clients)
```

**Supported languages:** English, French, Spanish, Chinese, Japanese, Korean (auto-detect or fixed).

**Additional voice methods:**

| Method | Description |
|--------|-------------|
| **VoiceInk + Shortcut** | macOS: transcription → OpenCode API → response |
| **iPhone Shortcut** | iOS: dictate → HTTP → speak response |
| **Pipecat STS** | Full voice pipeline: Soniox STT → AI → Cartesia TTS |

**See:** [speech-to-speech.md](.agents/tools/voice/speech-to-speech.md) for full component options, CLI parameters, and integration patterns (Twilio phone, video narration, voice-driven DevOps).

### Scheduled Agent Tasks

Cron-based agent dispatch for automated workflows:

```bash
# Example: Daily SEO report at 9am
0 9 * * * ~/.aidevops/agents/scripts/runner-helper.sh run "seo-analyst" "Generate daily SEO report"
```

**See:** [TODO.md](TODO.md) tasks t109-t118 for implementation status.

## **Requirements**

### **Recommended Hardware**

aidevops itself is lightweight (shell scripts + markdown), but AI model workloads benefit from capable hardware:

| Tier | Machine | CPU | RAM | GPU | Best For |
|------|---------|-----|-----|-----|----------|
| **Minimum** | Any modern laptop | 4+ cores | 8GB | None | Framework only, cloud AI APIs |
| **Recommended** | Mac Studio / desktop | Apple M1+ or 8+ cores | 16GB+ | MPS (Apple) or NVIDIA 8GB+ | Local voice, browser automation, dev servers |
| **Power User** | Workstation | 8+ cores | 32GB+ | NVIDIA 24GB+ VRAM | Full voice pipeline, local LLMs, parallel agents |
| **Server** | Cloud GPU | Any | 16GB+ | A100 / H100 | Production voice, multi-user, batch processing |

**Cloud GPU providers** for on-demand GPU access: [NVIDIA Cloud](https://www.nvidia.com/en-us/gpu-cloud/), [Vast.ai](https://vast.ai/), [RunPod](https://www.runpod.io/), [Lambda](https://lambdalabs.com/). See `.agents/tools/infrastructure/cloud-gpu.md` for the full deployment guide (SSH setup, Docker, model caching, cost optimization).

**Note:** Most aidevops features (infrastructure management, SEO, code quality, Git workflows) require no GPU. GPU is only needed for local AI model inference (voice pipeline, vision models, local LLMs).

### **Software Dependencies**

```bash
# Install dependencies (auto-detected by setup.sh)
brew install sshpass jq curl mkcert dnsmasq fd ripgrep  # macOS
sudo apt-get install sshpass jq curl dnsmasq fd-find ripgrep  # Ubuntu/Debian

# Generate SSH key
ssh-keygen -t ed25519 -C "your-email@domain.com"
```

### **File Discovery Tools**

AI agents use fast file discovery tools for efficient codebase navigation:

| Tool | Purpose | Speed |
|------|---------|-------|
| `fd` | Fast file finder (replaces `find`) | ~10x faster |
| `ripgrep` | Fast content search (replaces `grep`) | ~10x faster |

Both tools respect `.gitignore` by default and are written in Rust for maximum performance.

**Preference order for file discovery:**

1. `git ls-files '*.md'` - Instant, git-tracked files only
2. `fd -e md` - Fast, respects .gitignore
3. `rg --files -g '*.md'` - Fast, respects .gitignore
4. Built-in glob tools - Fallback when bash unavailable

The setup script offers to install these tools automatically.

## **Comprehensive Service Coverage**

### **Infrastructure & Hosting**

- **[Hostinger](https://www.hostinger.com/)**: Shared hosting, domains, email
- **[Hetzner Cloud](https://www.hetzner.com/cloud)**: VPS servers, networking, load balancers
- **[Closte](https://closte.com/)**: Managed hosting, application deployment
- **[Coolify](https://coolify.io/)** *Enhanced with CLI*: Self-hosted PaaS with CLI integration
- **[Cloudron](https://www.cloudron.io/)** *Enhanced with packaging guide*: Server and app management platform with custom app packaging support
- **[Vercel](https://vercel.com/)** *Enhanced with CLI*: Modern web deployment platform with CLI integration
- **[AWS](https://aws.amazon.com/)**: Cloud infrastructure support via standard protocols
- **[DigitalOcean](https://www.digitalocean.com/)**: Cloud infrastructure support via standard protocols

### **Domain & DNS**

- **[Cloudflare](https://www.cloudflare.com/)**: DNS, CDN, security services
- **[Spaceship](https://www.spaceship.com/)**: Domain registration and management
- **[101domains](https://www.101domain.com/)**: Domain purchasing and DNS
- **[AWS Route 53](https://aws.amazon.com/route53/)**: AWS DNS management
- **[Namecheap](https://www.namecheap.com/)**: Domain and DNS services

### **Development & Git Platforms with CLI Integration**

- **[GitHub](https://github.com/)** *Enhanced with CLI*: Repository management, actions, API, GitHub CLI (gh) integration
- **[GitLab](https://gitlab.com/)** *Enhanced with CLI*: Self-hosted and cloud Git platform with GitLab CLI (glab) integration
- **[Gitea](https://gitea.io/)** *Enhanced with CLI*: Lightweight Git service with Gitea CLI (tea) integration
- **[Agno](https://agno.com/)**: Local AI agent operating system for DevOps automation
- **[Pandoc](https://pandoc.org/)**: Document conversion to markdown for AI processing

### **AI Orchestration Frameworks**

- **[Langflow](https://langflow.org/)**: Visual drag-and-drop builder for AI workflows (MIT, localhost:7860)
- **[CrewAI](https://crewai.com/)**: Multi-agent teams with role-based orchestration (MIT, localhost:8501)
- **[AutoGen](https://microsoft.github.io/autogen/)**: Microsoft's agentic AI framework with MCP support (MIT, localhost:8081)

### **Design, UI & Artifact Creation**

- **Google `DESIGN.md` standard**: Canonical AI-readable design systems with YAML tokens, Markdown rationale, linting, Tailwind/DTCG export, and preview generation. aidevops keeps `DESIGN.md` as the source of truth for UI agents.
- **Design library**: 54 brand examples and 12 original style archetypes for agent-ready visual direction, plus palette, brand identity, and UI inspiration workflows.
- **Artifact commands**: `/design-artifact` routes prototype, deck, email, poster, social carousel, and mobile mockup requests; `/open-design` manages optional Open Design companion workflows.
- **[Open Design](https://github.com/nexu-io/open-design)** *Optional peripheral*: Local-first design artifact studio by nexu-io (Apache-2.0) for sandboxed previews, design-skill pickers, `.od/` workspaces, and exports. It installs alongside aidevops only when requested; selected skills are ingested via aidevops build-agent optimisation, not imported verbatim.
- **Local HTTPS previews**: `localdev-helper.sh` can wrap Open Design or other dev servers with mkcert-backed `.local` routes when tools only expose localhost.
- **Verification**: `workflows/ui-verification.md`, `email-design-test-helper.sh`, design preview screenshots, and deck/media smoke tests provide evidence before generated artifacts ship.

### **Mobile App & Simulator Testing**

- **Mobile app stack guidance**: Expo, Swift/Xcode, backend, analytics, monetisation, onboarding, notification, publishing, and test strategy references for mobile delivery (`.agents/tools/mobile/`).
- **Simulator-backed web testing**: `serve-sim` guidance and helpers cover local/mobile preview flows, prompt failure handling, and simulator smoke tests before mobile UI changes ship.
- **Device and automation options**: agent-device, App Store Connect, Maestro, minisim, iOS Simulator MCP, Xcodebuild MCP, and accessibility tooling references help agents choose the right mobile verification path.
- **Mobile-first artifact routing**: `/design-artifact` can route mobile mockups and app screens through the design stack, then hand implementation to mobile/testing specialists.

### **Video Creation**

- **[Video-use](https://github.com/browser-use/video-use)**: Conversational footage editing through the [video-editor runtime adapter](.agents/tools/video/video-use-runtime.md), with a reviewed executable pin, explicit installation, whole-repository update checks and a no-upload synthetic render smoke test. Run `python3 ~/.aidevops/agents/scripts/video-use-helper.py status` to check readiness.
- **[Remotion](https://remotion.dev/)**: Programmatic video creation with React - animations, compositions, media handling, captions
- **[Video Prompt Design](https://github.com/snubroot/Veo-3-Meta-Framework)**: AI video prompt engineering using the 7-component meta prompt framework for Veo 3 and similar models
- **[Kie.ai](https://kie.ai/)**: Unified asynchronous Market API and `kie-helper.sh` workflow for image, video, audio, uploads, callbacks, and credit checks with model-specific JSON pass-through
- **[MuAPI](https://muapi.ai/)**: Multimodal AI API for image/video/audio/VFX generation, workflows, agents, music (Suno), and lip-sync - unified creative orchestration platform
- **[yt-dlp](https://github.com/yt-dlp/yt-dlp)**: YouTube video/audio/playlist/channel downloads, transcript extraction, and local file audio conversion via ffmpeg

### **WordPress Development**

- **[LocalWP](https://localwp.com)**: WordPress development environment with MCP database access
- **[MainWP](https://mainwp.com/)**: WordPress site management dashboard

**Git CLI Enhancement Features:**

- **.agents/scripts/github-cli-helper.sh**: Advanced GitHub repository, issue, PR, and branch management
- **.agents/scripts/gitlab-cli-helper.sh**: Complete GitLab project, issue, MR, and branch management
- **.agents/scripts/gitea-cli-helper.sh**: Full Gitea repository, issue, PR, and branch management

### **Security & Code Quality**

- **[gopass](https://github.com/gopasspw/gopass)**: GPG-encrypted secret management with AI-native wrapper (`aidevops secret`) - subprocess injection + output redaction keeps secrets out of AI context
- **[Vaultwarden](https://github.com/dani-garcia/vaultwarden)**: Password and secrets management
- **[SonarCloud](https://sonarcloud.io/)**: Security and quality analysis (A-grade ratings)
- **[CodeFactor](https://www.codefactor.io/)**: Code quality metrics (A+ score)
- **[Codacy](https://www.codacy.com/)**: Multi-tool analysis with a live quality badge and daily A-grade monitoring
- **[CodeRabbit](https://coderabbit.ai/)**: AI-powered code reviews
- **[Snyk](https://snyk.io/)**: Security vulnerability scanning
- **[Socket](https://socket.dev/)**: Dependency security and supply chain protection
- **[Sentry](https://sentry.io/)**: Error monitoring and performance tracking
- **[Cisco Skill Scanner](https://github.com/cisco-ai-defense/skill-scanner)**: Security scanner for AI agent skills (prompt injection, exfiltration, malicious code)
- **[VirusTotal](https://www.virustotal.com/)**: Advisory threat intelligence via VT API v3 -- file hash scanning (70+ AV engines), domain/URL reputation checks for imported skills
- **[Secretlint](https://github.com/secretlint/secretlint)**: Detect exposed secrets in code
- **[OSV Scanner](https://google.github.io/osv-scanner/)**: Google's vulnerability database scanner
- **[Qlty](https://qlty.sh/)**: Universal code quality platform (70+ linters, auto-fixes)
- **Retired review compatibility**: Historical Gemini Code Assist GitHub reviews remain readable, but the sunset integration is no longer advertised or configurable

### **AI Prompt Optimization**

- **[Repomix](https://repomix.com/)**: Pack codebases into AI-friendly context (80% token reduction with compress mode)
- **[DSPy](https://dspy.ai/)**: Framework for programming with language models
- **[DSPyGround](https://dspyground.com/)**: Interactive playground for prompt optimization
- **[TOON Format](https://github.com/marcusquinn/aidevops/blob/main/.agents/toon-format.md)**: Token-Oriented Object Notation - 20-60% token reduction for LLM prompts

### **Document Processing & OCR**

- **Document Creation Agent** (`document-creation-helper.sh`): Unified document format conversion, template-based creation, and OCR for scanned PDFs/images. Routes to the best available tool (pandoc, odfpy, LibreOffice, Tesseract, EasyOCR, GLM-OCR) based on format pair and availability. Supports 13+ formats (ODT, DOCX, PDF, MD, HTML, EPUB, PPTX, ODP, XLSX, ODS, RTF, CSV, TSV).
- **[LibPDF](https://libpdf.dev/)**: PDF form filling, digital signatures (PAdES B-B/T/LT/LTA), encryption, merge/split, text extraction
- **[MinerU](https://github.com/opendatalab/MinerU)**: Layout-aware PDF-to-markdown/JSON conversion with OCR (109 languages), formula-to-LaTeX, and table extraction (53k+ stars, AGPL-3.0)
- **[Unstract](https://github.com/Zipstack/unstract)**: LLM-powered structured data extraction from unstructured documents (PDF, images, DOCX)
- **[GLM-OCR](https://ollama.com/library/glm-ocr)**: Local OCR via Ollama - purpose-built for document text extraction (tables, forms, complex layouts) with zero cloud dependency

**PDF/OCR Tool Selection:**

| Need | Tool | Why |
|------|------|-----|
| **Format conversion** | Document Creation Agent | Auto-selects best tool, 13+ formats |
| **Complex PDF to markdown** | MinerU | Layout-aware, formulas, tables, 109-language OCR |
| **Quick text extraction** | GLM-OCR | Local, fast, no API keys, privacy-first |
| **Structured JSON output** | Unstract | Schema-based extraction, complex documents |
| **Screen/window OCR** | Peekaboo + GLM-OCR | `peekaboo image --analyze --model ollama/glm-ocr` |
| **PDF text extraction** | LibPDF | Native PDF parsing, no AI needed |
| **Simple format conversion** | Pandoc | Lightweight, broad format support |
| **Scanned PDF OCR** | Document Creation Agent | Auto-detects, routes to Tesseract/EasyOCR/GLM-OCR |

**Quick start:**

```bash
# Document creation agent
document-creation-helper.sh status                          # Check available tools
document-creation-helper.sh install --standard              # Install core tools
document-creation-helper.sh convert report.pdf --to odt     # Convert formats
document-creation-helper.sh convert scan.pdf --to md --ocr  # OCR scanned PDF
document-creation-helper.sh template draft --type letter     # Generate template

# GLM-OCR direct
ollama pull glm-ocr
ollama run glm-ocr "Extract all text" --images /path/to/document.png
```

See `.agents/tools/ocr/glm-ocr.md` for batch processing, PDF workflows, and Peekaboo integration.

### **Communications**

- **[Twilio](https://www.twilio.com/)**: SMS, voice calls, WhatsApp, phone verification (Verify API), call recording & transcription
- **[Telfon](https://mytelfon.com/)**: Twilio-powered cloud phone system with iOS/Android/Chrome apps for end-user calling interface
- **[Matrix](https://matrix.org/)**: Self-hosted chat with bot integration for AI runner dispatch (`matrix-dispatch-helper.sh`)
- **[SimpleX Chat](https://simplex.chat/)**: Privacy-first messaging with AI bot gateway for agent dispatch (`simplex-bot/`)
- **[Matterbridge](https://github.com/42wim/matterbridge)**: Multi-platform chat bridge connecting 20+ platforms (Matrix, Discord, Telegram, Slack, IRC, WhatsApp, XMPP) with SimpleX adapter (`matterbridge-helper.sh`)

### **Animation & Video**

- **[Anime.js](https://animejs.com/)**: Lightweight JavaScript animation library for CSS, SVG, DOM attributes, and JS objects
- **[Remotion](https://remotion.dev/)**: Programmatic video creation with React - create videos using code with 29 specialized rule files
- **[Video Prompt Design](https://github.com/snubroot/Veo-3-Meta-Framework)**: Structured prompt engineering for AI video generation (Veo 3, 7-component framework, character consistency, audio design)

### **Voice AI**

- **Voice Bridge**: Talk to your AI coding agent via speech -- Silero VAD → Whisper MLX → OpenCode → Edge TTS (~6-8s round-trip)
- **[Speech-to-Speech](https://github.com/huggingface/speech-to-speech)**: Open-source modular voice pipeline (VAD → STT → LLM → TTS) with local GPU and cloud GPU deployment
- **[Pipecat](https://github.com/pipecat-ai/pipecat)**: Real-time voice agent framework with Soniox STT, Cartesia TTS, and multi-LLM support

### **Performance & Monitoring**

- **[PageSpeed Insights](https://pagespeed.web.dev/)**: Website performance auditing
- **[Lighthouse](https://developer.chrome.com/docs/lighthouse/)**: Comprehensive web app analysis
- **[WebPageTest](https://www.webpagetest.org/)**: Real-world performance testing from 40+ global locations with filmstrip, waterfall, and Core Web Vitals
- **[Updown.io](https://updown.io/)**: Website uptime and SSL monitoring

### **AI & Documentation**

- **[Context7](https://context7.io/)**: Real-time documentation access for libraries and frameworks
- **Context7 CLI mode**: `npx ctx7 setup --opencode --cli` for docs lookup without MCP transport (useful fallback in shell-first workflows)
- **[Local Models](https://github.com/ggml-org/llama.cpp)**: Run AI models locally via llama.cpp for free, private, offline inference with HuggingFace GGUF model management (`local-model-helper.sh`)

### **Local Development**

- **[Localdev](https://mkcert.dev/)**: Local development environment manager with dnsmasq, Traefik, and mkcert for production-like `.local` domains with HTTPS on port 443 (`localdev-helper.sh`)

## **MCP Integrations**

**Model Context Protocol servers for real-time AI assistant integration.** The framework configures these MCPs for **[OpenCode](https://opencode.ai/)** (TUI, Desktop, and Extension for Zed/VSCode).

### **All Supported MCPs (19 available)**

MCP integrations use reviewed local package runners or remote HTTPS endpoints. Security-sensitive local integrations use exact package pins where required; setup may globally cache selected tools for faster startup. Run `setup.sh` or `aidevops update-tools` to refresh managed tooling.

| MCP | Purpose | Tier | API Key Required |
|-----|---------|------|------------------|
| [Claude Code MCP](https://github.com/steipete/claude-code-mcp) | Claude as sub-agent | Global | No |
| [Amazon Order History](https://github.com/marcusquinn/amazon-order-history-csv-download-mcp) | Order data extraction | Per-agent | No |
| [Chrome DevTools](https://chromedevtools.github.io/devtools-protocol/) | Browser debugging & automation | Per-agent | No |
| [Context7](https://context7.com/) | Library documentation lookup | Per-agent | No |
| [Docker MCP](https://docs.docker.com/ai/mcp-catalog/) | Container management | Per-agent | No |
| [Google Analytics](https://developers.google.com/analytics) | Analytics data | Per-agent | Yes (Google API) |
| [Google Search Console](https://developers.google.com/webmaster-tools) | Search performance data | Per-agent | Yes (Google API) |
| [Grep by Vercel](https://grep.app/) | GitHub code search | Per-agent | No |
| [LocalWP](https://localwp.com/) | WordPress database access | Per-agent | No (local) |
| [macOS Automator](https://github.com/steipete/macos-automator-mcp) | macOS automation | Per-agent | No |
| [Playwright MCP](https://github.com/microsoft/playwright-mcp) | Isolated or extension-connected browser automation | Per-agent | No |
| [QuickFile](https://github.com/marcusquinn/quickfile-mcp) | Guarded multi-account accounting API | On-demand per-agent | Yes |
| [Repomix](https://github.com/yamadashy/repomix) | Codebase packing for AI context | Per-agent | No |
| [Sentry](https://sentry.io/) | Error tracking | Per-agent | Yes |
| [shadcn](https://ui.shadcn.com/) | UI component library | Per-agent | No |
| [Socket](https://socket.dev/) | Dependency security | Per-agent | No |
| [Unstract](https://github.com/Zipstack/unstract) | Document data extraction | Per-agent | Yes |
| [OpenAPI Search](https://openapi-mcp.openapisearch.com/mcp) | Search and explore any OpenAPI spec | Per-agent | No |
| [Cloudflare Code Mode](https://mcp.cloudflare.com/mcp) | Full Cloudflare API (2,500+ endpoints via 2 tools) | Per-agent | Yes (Cloudflare) |

**Tier explanation:**
- **Global** - Tools always available (loaded into every session)
- **Per-agent** - Tools disabled globally, enabled per-agent via config (zero context overhead when unused)

**Performance optimization:** MCPs stay disabled globally and connect on demand when their subagent is invoked. Selected packages may be globally installed or cached, while integrations such as Playwright use an exact pinned package runner to preserve their reviewed CLI contract.

### **SEO Integrations (curl subagents - no MCP overhead)**

These use direct API calls via curl, avoiding MCP server startup entirely:

| Integration | Purpose | API Key Required |
|-------------|---------|------------------|
| [Ahrefs](https://ahrefs.com/api) | SEO analysis & backlinks | Yes |
| [DataForSEO](https://dataforseo.com/) | SERP, keywords, backlinks, on-page | Yes |
| [Serper](https://serper.dev/) | Google Search API (web, images, news) | Yes |
| [Semrush](https://www.semrush.com/api-documentation/) | Domain analytics, keywords, backlinks, competitor research | Yes |
| [ContentKing](https://www.contentkingapp.com/) | Real-time SEO monitoring, change tracking, issues | Yes |
| [WebPageTest](https://www.webpagetest.org/) | Real-world performance testing from 40+ global locations | Yes |
| [Hostinger](https://developers.hostinger.com/) | Hosting management | Yes |
| [NeuronWriter](https://neuronwriter.com/) | Content optimization & NLP analysis | Yes |
| [Outscraper](https://outscraper.com/) | Google Maps & business data extraction | Yes |

### **By Category**

**Context & Codebase:**

- [llm-tldr](https://github.com/parcadei/llm-tldr) - Semantic code analysis with 95% token savings ([details below](#llm-tldr---semantic-code-analysis))
- [Context7](https://context7.com/) - Real-time documentation access for thousands of libraries
- [Repomix](https://github.com/yamadashy/repomix) - Pack codebases into AI-friendly context
- [OpenAPI Search](https://openapi-mcp.openapisearch.com/mcp) - Search and explore any OpenAPI specification (zero install, Cloudflare Worker)
- [MCPorter](https://github.com/steipete/mcporter) - Discover, call, compose, and generate CLIs/typed clients for MCP servers

**Browser Automation** (browser tool suite + anti-detect stack, [benchmarked](#browser-automation)):

- **Auto-browse workflow** - `/auto-browse` orchestrates the tools below to learn messy browser tasks, choose the cheapest reliable path, preserve private profile/session state under `~/.aidevops/`, and graduate reusable private agents or sanitized `todo/` plans
- [Playwright](https://playwright.dev/) - Fastest engine (0.9s form fill); standalone Brave is preferred for headed/headless work, while Microsoft's [Playwright Extension](https://chromewebstore.google.com/detail/playwright-extension/mmlmfjhmonkocbjadbfplnigmagldckm) is reserved for interactive access to approved user-owned tabs
- [playwright-cli](https://github.com/microsoft/playwright-cli) - Microsoft official CLI for AI agents, `--session` isolation, built-in tracing
- [dev-browser](https://github.com/nicholasgriffintn/dev-browser) - Persistent profile, stays logged in, ARIA snapshots, pairs with DevTools
- [agent-browser](https://github.com/vercel-labs/agent-browser) - CLI/CI/CD, `--session` parallel, ref-based element targeting, **iOS Simulator support** (macOS)
- [Crawl4AI](https://github.com/unclecode/crawl4ai) - Bulk extraction, `arun_many` parallel (1.7x), LLM-ready markdown
- [WaterCrawl](https://github.com/watercrawl/watercrawl) - Self-hosted crawling with web search, sitemap generation, JS rendering, proxy support
- [Playwright Recorder](https://chromewebstore.google.com/detail/playwright-recorder/bapaclfmcgookbglclacfgeemaehkkme) - Optional third-party, low-sensitivity human-flow capture into draft test code; pair with written acceptance criteria and review/redact output
- [Stagehand](https://github.com/browserbase/stagehand) - Natural language automation, self-healing selectors
- [browser-use](https://github.com/browser-use/browser-use) - AI-native browser automation, CLI 3.0 Browser Harness, packaged agent skill, Browser Use Cloud, 100-task upstream benchmark
- [Chrome DevTools MCP](https://github.com/nicholasgriffintn/chrome-devtools-mcp) - Companion: Lighthouse, network throttling, CSS coverage (pairs with any tool)
- [Cloudflare Browser Rendering](https://developers.cloudflare.com/browser-rendering/) - Server-side web scraping
- [Peekaboo](https://github.com/steipete/Peekaboo) - macOS screen capture and GUI automation (pixel-accurate captures, AI vision analysis)
- [Sweet Cookie](https://github.com/steipete/sweet-cookie) - Browser cookie extraction for API calls without launching a browser
- **Anti-Detect Stack** ([details](#anti-detect-browser)):
  - [Camoufox](https://github.com/daijro/camoufox) (4.9k stars) - Firefox anti-detect, C++ fingerprint injection, WebRTC/Canvas/WebGL spoofing
  - [rebrowser-patches](https://github.com/nicedayfor/rebrowser-patches) (1.2k stars) - Chromium CDP leak prevention, automation signal removal
  - Multi-profile management - Persistent/clean/warm/disposable profiles (like AdsPower/GoLogin)
  - Proxy integration - Residential, SOCKS5, VPN per profile with geo-targeting

**Mobile & Simulator Testing:**

- [serve-sim](https://github.com/EvanBacon/serve-sim) - Apple Simulator browser preview/control for iOS, iPad, and Apple Watch simulators (setup offers global install on supported Macs)
- [agent-device](.agents/tools/mobile/agent-device.md) - AI-driven mobile app interaction across iOS and Android
- [Maestro](.agents/tools/mobile/maestro.md) - Repeatable YAML E2E flows for mobile apps

**SEO & Research:**

- [Google Search Console](https://developers.google.com/webmaster-tools) - Search performance insights (MCP)
- [Grep by Vercel](https://grep.app/) - Search code snippets across GitHub repositories (MCP)
- [Ahrefs](https://ahrefs.com/api) - SEO analysis, backlink research, keyword data (curl subagent)
- [DataForSEO](https://dataforseo.com/) - Comprehensive SEO data APIs (curl subagent)
- [Serper](https://serper.dev/) - Google Search API (curl subagent)
- **SEO Audit** - Comprehensive technical SEO auditing: crawlability, indexation, Core Web Vitals, on-page optimization, E-E-A-T signals (imported skill from [marketingskills](https://github.com/coreyhaines31/marketingskills))
- **Keyword Research** - Strategic keyword research with SERP weakness detection (via DataForSEO + Serper + Ahrefs)
- **Site Crawler** - Screaming Frog-like SEO auditing: broken links, redirects, meta issues, structured data
- **Domain Research** - DNS intelligence via THC (4.51B records) and Reconeer APIs: rDNS, subdomains, CNAMEs
- [NeuronWriter](https://neuronwriter.com/) - Content optimization with NLP analysis, competitor research, and content scoring (curl subagent)

**Data Extraction:**

- [Outscraper](https://outscraper.com/) - Google Maps, business data, reviews extraction (curl subagent)
- [curl-copy](.agents/tools/browser/curl-copy.md) - Authenticated scraping via DevTools "Copy as cURL" (no browser automation needed)

**Performance & Security:**

- [PageSpeed Insights](https://developers.google.com/speed/docs/insights/v5/get-started) - Website performance auditing
- [Snyk](https://snyk.io/) - Security vulnerability scanning
- [Cloudflare Code Mode](https://mcp.cloudflare.com/mcp) - Full Cloudflare API (2,500+ endpoints) via 2 tools in ~1,000 tokens (DNS, WAF, DDoS, R2, Workers, Zero Trust)
- **IP Reputation** - Multi-provider IP reputation checking (Spamhaus, ProxyCheck, AbuseIPDB) for VPS/proxy vetting (`ip-reputation-helper.sh`)

**WordPress & Development:**

- [LocalWP](https://localwp.com/) - Direct WordPress database access
- [WordPress MCP Adapter](https://github.com/WordPress/mcp-adapter) - Official WordPress MCP for content management (STDIO, HTTP, and SSH transports)
- [Next.js DevTools](https://nextjs.org/docs) - React/Next.js development assistance

**CRM & Marketing:**

- [FluentCRM](https://fluentcrm.com/) - WordPress CRM: contacts, tags, lists, campaigns, automations, smart links, webhooks

**Accounts & Finance:**

- **Provider-neutral accounting** - Bookkeeping, statement imports,
  reconciliation, classifications, chart evolution, debtors/creditors,
  management and investor reports, statutory-return workpapers, and cash-flow
  forecasts with approval and read-back controls (`business/accounting.md`)
- **Accounting software catalogue** - Truthful support states and export
  fallbacks across QuickFile, Xero, QuickBooks, FreeAgent, Sage, Zoho Books,
  FreshBooks, Wave, KashFlow, Clear Books, MYOB, Odoo, and others
  (`business/accounting-software.md`)
- [QuickFile](https://github.com/marcusquinn/quickfile-mcp) - First executable
  reference adapter, activated on demand through `@quickfile`
- [Amazon Order History](https://github.com/marcusquinn/amazon-order-history-csv-download-mcp) - Order data extraction (MCP)

**Document Processing & OCR:**

- [LibPDF](https://libpdf.dev/) - PDF form filling, digital signatures, encryption, merge/split (via helper script)
- [Unstract](https://github.com/Zipstack/unstract) - LLM-powered structured data extraction from PDFs, images, DOCX (MCP)
- [GLM-OCR](https://ollama.com/library/glm-ocr) - Local OCR via Ollama for document text extraction (subagent)

### **Quick Setup**

```bash
# Install all MCP integrations
bash .agents/scripts/setup-mcp-integrations.sh all

# Install specific integration
bash .agents/scripts/setup-mcp-integrations.sh stagehand          # JavaScript version
bash .agents/scripts/setup-mcp-integrations.sh stagehand-python   # Python version
bash .agents/scripts/setup-mcp-integrations.sh stagehand-both     # Both versions
bash .agents/scripts/setup-mcp-integrations.sh chrome-devtools
```

### OpenCode LSP Configuration

OpenCode includes [built-in LSP servers](https://opencode.ai/docs/lsp/) for 35+ languages. For aidevops projects that use Markdown and TOON extensively, add these optional LSP servers to your `opencode.json` for real-time diagnostics during editing:

```json
{
  "lsp": {
    "markdownlint": {
      "command": ["markdownlint-language-server", "--stdio"],
      "extensions": [".md"]
    },
    "toon-lsp": {
      "command": ["toon-lsp"],
      "extensions": [".toon"]
    }
  }
}
```

**Install the servers:**

```bash
npm install -g markdownlint-language-server  # Markdown diagnostics
cargo install toon-lsp                        # TOON syntax validation
```

These catch formatting and syntax issues during editing, reducing preflight/postflight fix cycles.

## **Browser Automation**

Browser tool suite + anti-detect stack + device emulation, benchmarked and integrated for AI-assisted web automation, dev testing, mobile/responsive testing, data extraction, and bot detection evasion. Agents automatically select the optimal tool based on task requirements.

For repeatable browser operations and web data mining, use `/auto-browse`. It runs an intake and learning loop that starts with cheap fetch/API/crawler options, escalates to deterministic or high-agency browser tools only when needed, and then graduates the workflow into a private custom agent, helper, schema, or sanitized `todo/` plan. Account-specific workflows, cookies, profile state, downloads, and traces stay in private aidevops user data; only generalized plans should be committed to the repo.

### Performance Benchmarks

Tested on macOS ARM64, all headless, warm daemon:

| Test | Playwright | playwright-cli | dev-browser | agent-browser | Crawl4AI | Stagehand | browser-use |
|------|-----------|----------------|-------------|---------------|----------|-----------|-------------|
| **Navigate + Screenshot** | **1.43s** | ~1.9s | 1.39s | 1.90s | 2.78s | 7.72s | Agentic; not in local deterministic suite |
| **Form Fill** (4 fields) | **0.90s** | ~1.4s | 1.34s | 1.37s | N/A | 2.58s | Agentic; use for fuzzy forms |
| **Data Extraction** (5 items) | 1.33s | ~1.5s | **1.08s** | 1.53s | 2.53s | 3.48s | Agentic; compress to deterministic when stable |
| **Multi-step** (click + nav) | **1.49s** | ~2.0s | 1.49s | 3.06s | N/A | 4.48s | Upstream BU Bench covers 100 real-world tasks |
| **Parallel** (3 sessions) | **1.6s** | ~2.0s | N/A | 2.0s | 3.0s | Slow | Prefer Browser Use Cloud for scale |

### Feature Matrix

| Feature | Playwright | playwright-cli | dev-browser | agent-browser | Crawl4AI | Stagehand | browser-use |
|---------|-----------|----------------|-------------|---------------|----------|-----------|-------------|
| **Headless** | Yes; extension mode headed | Yes (default) | Yes | Yes (default) | Yes | Yes | Yes |
| **Proxy/VPN** | Full or existing browser | No | Via args | No | Full | Via args | Cloud/profiles |
| **Extensions** | Persistent context or interactive approved user tabs | No in normal mode | Yes (profile) | No | No | Possible | Profile/browser dependent |
| **Password managers** | Interactive approved user tabs only | No | Partial | No | No | No | Profile/browser dependent |
| **Device emulation** | **Full** (100+ devices) | No | No | No | No | Via Playwright | Profile/browser dependent |
| **Parallel sessions** | 5 standalone contexts/2.1s; interactive extension tab groups only | --session | Shared | 3 sess/2.0s | arun_many 1.7x | Per-instance | Cloud for scale |
| **Session persistence** | storageState/profile/existing browser | Profile dir | Profile dir | state save/load | user_data_dir | Per-instance | BrowserProfile / Cloud |
| **Tracing** | Full API | Built-in CLI | Via Playwright | Via Playwright | No | Via Playwright | History + Browser Harness CLI |
| **Natural language** | No | No | No | No | LLM extraction | Yes | Yes |
| **Self-healing** | No | No | No | No | No | Yes | Yes |
| **Agent skill** | No | No | No | No | No | No | `browser-use skill` |
| **iOS Simulator** | No | No | No | **Yes** (macOS) | No | No | No |
| **Maintainer** | Microsoft | Microsoft | Community | Vercel | Community | Browserbase | Browser Use |

### Tool Selection

| Need | Tool | Why |
|------|------|-----|
| **Repeatable browser workflow** | `/auto-browse` | Learns, optimizes, preserves private profile state, and graduates reusable workflows |
| **Fastest automation** | Standalone Playwright with Brave preferred | 0.9s form fill, parallel isolated contexts without disturbing user activity |
| **AI agent (CLI)** | playwright-cli | Microsoft official, `--session` isolation, built-in tracing |
| **Stay logged in** | dev-browser | Profile persists across restarts |
| **Interactive access to your browser** | Playwright Extension | User-present selected-tab access to an existing Chrome/Edge/Chromium session; never for workers/CI, and Brave extension support is unverified |
| **Record expected human flow** | Playwright Recorder (optional) | Produces draft test code for low-sensitivity flows; pair with written acceptance criteria and review/redact output |
| **Bulk extraction** | Crawl4AI | Purpose-built, parallel, LLM-ready output |
| **Self-hosted crawling** | WaterCrawl | Docker deployment, web search, sitemap generation |
| **CLI/CI/CD** | playwright-cli or agent-browser | No server needed, `--session` isolation |
| **iOS mobile testing** | agent-browser | Real Safari in iOS Simulator (macOS only) |
| **Apple Simulator streaming** | serve-sim | Browser-visible iOS/iPad/watch simulator stream and control (macOS Apple Silicon) |
| **Unknown pages** | Stagehand | Natural language, self-healing |
| **High-agency browser tasks** | browser-use | AI-native browser agent, CLI 3.0, Browser Harness, cloud/stealth/CAPTCHA options |
| **Performance debugging** | Chrome DevTools MCP | Companion tool, pairs with any browser |
| **Mobile/tablet emulation** | Playwright | 100+ device presets, viewport, touch, geolocation, locale |
| **Authenticated one-off scrape** | curl-copy | DevTools "Copy as cURL" → paste to terminal/AI |
| **Bot detection evasion** | Anti-detect stack | Camoufox (full) or rebrowser-patches (quick) |
| **Multi-account** | Browser profiles | Persistent fingerprint + proxy per account |

### AI Page Understanding

Agents use lightweight methods instead of expensive vision API calls:

| Method | Speed | Token Cost | Use For |
|--------|-------|-----------|---------|
| ARIA snapshot | ~0.01s | 50-200 tokens | Forms, navigation, interactive elements |
| Text extraction | ~0.002s | Text length | Reading content |
| Element scan | ~0.002s | ~20/element | Form filling, clicking |
| Screenshot | ~0.05s | ~1K tokens (vision) | Visual debugging only |

See [`.agents/tools/browser/browser-automation.md`](.agents/tools/browser/browser-automation.md) for the full decision tree, [`browser-use.md`](.agents/tools/browser/browser-use.md) for Browser Use CLI 3.0 guidance, and [`browser-benchmark.md`](.agents/tools/browser/browser-benchmark.md) for reproducible benchmark scripts.

### Device Emulation

Test responsive layouts and mobile-specific behavior using Playwright's built-in device emulation. Supports 100+ device presets with viewport, user agent, touch events, device scale factor, geolocation, locale/timezone, permissions, color scheme, offline mode, and network throttling.

**Common device presets:**

| Device | Viewport | Scale | Touch |
|--------|----------|-------|-------|
| `iPhone 15` | 393x852 | 3 | Yes |
| `iPad Pro 11` | 834x1194 | 2 | Yes |
| `Pixel 7` | 412x915 | 2.625 | Yes |
| `Galaxy S9+` | 320x658 | 4.5 | Yes |
| `Desktop Chrome` | 1280x720 | 1 | No |

**Emulation capabilities:**

| Feature | Example |
|---------|---------|
| **Device presets** | `devices['iPhone 13']` - viewport, UA, touch, scale |
| **Viewport/HiDPI** | `viewport: { width: 2560, height: 1440 }, deviceScaleFactor: 2` |
| **Geolocation** | `geolocation: { longitude: -74.006, latitude: 40.7128 }` |
| **Locale/timezone** | `locale: 'de-DE', timezoneId: 'Europe/Berlin'` |
| **Color scheme** | `colorScheme: 'dark'` |
| **Offline mode** | `offline: true` |
| **Permissions** | `permissions: ['geolocation', 'notifications']` |
| **Network throttling** | CDP-based Slow 3G / Fast 3G emulation |

**Recipes included:** Responsive breakpoint testing, multi-device parallel testing, touch gesture testing, geolocation-dependent features, dark mode visual regression, and network condition emulation.

See [`.agents/tools/browser/playwright-emulation.md`](.agents/tools/browser/playwright-emulation.md) for complete documentation with code examples.

### Anti-Detect Browser

Open-source alternative to AdsPower, GoLogin, and OctoBrowser for multi-account automation and bot detection evasion.

**Architecture:**

```text
Layer 4: CAPTCHA Solving    → CapSolver (existing)
Layer 3: Network Identity   → Proxies (residential/SOCKS5/VPN per profile)
Layer 2: Browser Identity   → Camoufox (C++ fingerprint injection)
Layer 1: Automation Stealth → rebrowser-patches (CDP leak prevention)
Layer 0: Browser Engine     → Playwright (existing)
```

**Profile Types:**

| Type | Cookies | Fingerprint | Use Case |
|------|---------|-------------|----------|
| **Persistent** | Saved | Fixed per profile | Account management, stay logged in |
| **Clean** | None | Random each launch | Scraping, one-off tasks |
| **Warm** | Saved | Fixed | Pre-warmed accounts (browsing history) |
| **Disposable** | None | Random | Single-use, maximum anonymity |

**Quick Start:**

```bash
# Setup
anti-detect-helper.sh setup

# Create profile with proxy
anti-detect-helper.sh profile create "my-account" --type persistent --os macos

# Launch (Camoufox with auto-generated fingerprint)
anti-detect-helper.sh launch --profile "my-account" --headless

# Test detection (BrowserScan, SannyBot)
anti-detect-helper.sh test --profile "my-account"

# Warm up profile with browsing history
anti-detect-helper.sh warmup "my-account" --duration 30m
```

**Engine Selection:**

| Engine | Stealth Level | Speed | Best For |
|--------|---------------|-------|----------|
| **Camoufox** (Firefox) | High (C++ level) | Medium | Full anti-detect, fingerprint rotation |
| **rebrowser-patches** (Chromium) | Medium (CDP patches) | Fast | Quick stealth on existing Playwright code |

See [`.agents/tools/browser/anti-detect-browser.md`](.agents/tools/browser/anti-detect-browser.md) for the full decision tree and subagent index.

## **Repomix - AI Context Generation**

[Repomix](https://repomix.com/) packages your codebase into AI-friendly formats for sharing with AI assistants. This framework includes optimized Repomix configuration for consistent context generation.

### Why Repomix?

| Use Case | Tool | When to Use |
|----------|------|-------------|
| **Interactive coding** | Augment Context Engine | Real-time semantic search during development |
| **Share with external AI** | Repomix | Self-contained snapshot for ChatGPT, Claude web, etc. |
| **Architecture review** | Repomix (compress) | 80% token reduction, structure only |
| **CI/CD integration** | GitHub Action | Automated context in releases |

### Quick Usage

```bash
# Pack current repo with configured defaults
npx repomix

# Compress mode (~80% smaller, structure only)
npx repomix --compress

# Or use the helper script
.agents/scripts/context-builder-helper.sh pack      # Full context
.agents/scripts/context-builder-helper.sh compress  # Compressed
```

### Configuration Files

| File | Purpose |
|------|---------|
| `repomix.config.json` | Default settings (style, includes, security) |
| `.repomixignore` | Additional exclusions beyond .gitignore |
| `repomix-instruction.md` | Custom AI instructions included in output |

### Key Design Decisions

- **No pre-generated files**: Outputs are generated on-demand to avoid staleness
- **Inherits .gitignore**: Security patterns automatically respected
- **Secretlint enabled**: Scans for exposed credentials before output
- **Symlinks excluded**: Avoids duplicating `.agents/` content

### MCP Integration

Repomix runs as an MCP server for direct AI assistant integration:

```json
{
  "repomix": {
    "type": "local",
    "command": ["repomix", "--mcp"],
    "enabled": true
  }
}
```

> Install globally first: `bun install -g repomix` (done automatically by `setup.sh`)

See `.agents/tools/context/context-builder.md` for complete documentation.

### llm-tldr - Semantic Code Analysis

[llm-tldr](https://github.com/parcadei/llm-tldr) extracts code structure and semantics, saving ~95% tokens compared to raw code. From the [Continuous-Claude](https://github.com/parcadei/Continuous-Claude-v3) project.

```bash
# Install
pip install llm-tldr

# CLI usage
tldr tree ./src                    # File structure with line counts
tldr structure src/auth.py         # Code skeleton (classes, functions)
tldr context src/auth.py           # Full semantic analysis
tldr search "authentication" ./src # Semantic code search
tldr impact src/auth.py validate   # What would change affect?
```

**MCP Integration:**

```json
{
  "llm-tldr": {
    "command": "tldr-mcp",
    "args": ["--project", "${workspaceFolder}"]
  }
}
```

| Feature | Token Savings | Use Case |
|---------|---------------|----------|
| Structure extraction | 90% | Understanding code layout |
| Context analysis | 95% | Comprehensive code understanding |
| Semantic search | N/A | Finding code by meaning |
| Impact analysis | N/A | Change risk assessment |

See `.agents/tools/context/llm-tldr.md` for complete documentation.

## **Cross-Tool Compatibility**

### Agent Skills Standard

aidevops implements the [Agent Skills](https://agentskills.io/) standard for cross-tool compatibility. Skills are auto-discovered by compatible AI assistants.

**Generated SKILL.md files** in `~/.aidevops/agents/` provide skill metadata following the [Agent Skills standard](https://agentskills.io/specification). These are discoverable by any compatible tool.

### Claude Code Plugin Marketplace

aidevops is registered as a **Claude Code plugin marketplace**. Install with two commands:

```bash
/plugin marketplace add marcusquinn/aidevops
/plugin install aidevops@aidevops
```

This installs the complete framework: 14 main agents, 2,200+ sub agents, and 2,010+ helper scripts, including callable skill/reference modules and supporting production script code.

### Importing External Skills

Import skills from GitHub or ClawdHub using the `aidevops skill` CLI:

```bash
# Import from GitHub (auto-detects format)
aidevops skill add owner/repo

# Import from ClawdHub (skill registry with vector search)
aidevops skill add clawdhub:caldav-calendar
aidevops skill add https://clawdhub.com/owner/slug

# More examples
aidevops skill add anthropics/skills/pdf           # Specific skill from multi-skill repo
aidevops skill add vercel-labs/agent-skills         # All skills from a repo
aidevops skill add expo/skills --name expo-dev      # Custom name
aidevops skill add owner/repo --dry-run             # Preview without changes
```

**Supported sources:**
- GitHub repos (`owner/repo` or full URL) — fetched via `git clone`
- [ClawdHub](https://clawdhub.com) (`clawdhub:slug` or full URL) — fetched via Playwright browser automation

**Supported formats:**
- `SKILL.md` - [Agent Skills standard](https://agentskills.io/specification) (preferred)
- `AGENTS.md` - Claude Code agents format
- `.cursorrules` - Cursor rules format (auto-converted)

**Features:**
- Auto-detection of skill format and category placement
- Conflict detection with merge/replace/rename options
- Upstream commit tracking for update detection (`aidevops skill check`)
- Conversion to aidevops subagent format with YAML frontmatter
- Registry stored in `.agents/configs/skill-sources.json`
- Telemetry disabled (no data sent to skills.sh or other services)

**How it differs from `npx add-skill`:**

| | `aidevops skill add` | `npx add-skill` |
|---|---|---|
| **Target** | Converts to aidevops format in `.agents/` | Copies SKILL.md to agent-specific dirs |
| **Tracking** | Git commit-based upstream tracking | Lock file with content hashes |
| **Telemetry** | Disabled | Sends anonymous install counts |
| **Scope** | OpenCode-first | 22+ agents |
| **Updates** | `aidevops skill check` (GitHub API) | `npx skills check` (Vercel API) |

See `.agents/scripts/add-skill-helper.sh` for implementation details.

## **AI Agents & Subagents**

**Agents are specialized AI personas with focused knowledge and tool access.** Instead of giving your AI assistant access to everything at once (which wastes context tokens), agents provide targeted capabilities for specific tasks.

Call them in your AI assistant conversation with a simple @mention

### **How Agents Work**

| Concept | Description |
|---------|-------------|
| **Main Agent** | Domain-focused assistant (e.g., WordPress, SEO, DevOps) |
| **Subagent** | Specialized assistant for specific services (invoked with @mention) |
| **MCP Tools** | Only loaded when relevant agent is invoked (saves tokens) |

### **Main Agents**

Primary agents live at `.agents/<name>.md`. Each is a domain expert with its own system prompt, tool permissions, and subagent roster. MCPs are loaded on-demand per subagent, not per primary agent.

| Name | File | Purpose | Model Tier |
|------|------|---------|------------|
| Build+ | `build-plus.md` | Code: features, bug fixes, refactors, CI, full-loop delivery (default) | thinking |
| Automate | `automate.md` | Scheduling, dispatch, monitoring, background orchestration | standard |
| Aidevops | `aidevops.md` | Framework development — meta-agent for improving aidevops itself | thinking |
| Business | `business.md` | Company orchestration, provider-neutral accounting, finance, invoicing, strategy | standard |
| Content | `content.md` | Content creation across blog, video, audio, image, social | thinking |
| Health | `health.md` | Health and wellness content, fitness, nutrition | thinking |
| Legal | `legal.md` | Legal compliance, terms, privacy, GDPR | thinking |
| Marketing-Sales | `marketing-sales.md` | Email campaigns, CRM, outreach, paid ads, direct response, CRO | thinking |
| Product | `product.md` | Product management, PRDs, roadmaps, requirements capture | thinking |
| Research | `research.md` | Technical and market research, competitive analysis | standard |
| SEO | `seo.md` | SEO audits, keyword research, GSC, schema, technical SEO | thinking |

**Specialist subagents** (e.g. `@wordpress`, `@seo`, Build-Agent, Build-MCP, etc.) live under `.agents/tools/` or as `mode: subagent` files and are invoked via `@mention` when domain expertise is needed. See `subagent-index.toon` for the full roster. For read-only macOS Activity Monitor and background-efficiency audits, use `@macos-activity-cleaner` or `/aidevops-macos-activity-cleaner`.

#### How to invoke a main agent

Launch terminal clients directly with Build+ selected by default, or name a main agent:

```bash
aidevops codex
aidevops codex automate
aidevops claude seo
aidevops opencode research
```

These shortcuts apply each CLI's supported full-access options for the session.
They also support Cursor Agent, Gemini, Continue, Kilo, Kiro CLI, Aider, Amp, Kimi,
Qwen and Droid (which retains its configured interactive autonomy). Use
`aidevops codex --list-agents` to list main agents, `--dry-run` to preview a launch,
and `--native` for native subcommands without injected defaults. See
[interactive runtime launchers](.agents/tools/ai-assistants/runtime-launchers.md)
for aliases, argument forwarding and runtime limitations.

| Client | Invocation |
|---|---|
| **OpenCode** | Tab through the agent picker in the UI — Build+ is the default. Main agents are registered as top-level agents in OpenCode's config. |
| **Claude Code / Codex / Cursor / Droid / Kiro / Continue / Kimi / Qwen / Amp / Windsurf / Gemini CLI** | Slash command, namespaced with the `aidevops-` prefix: `/aidevops-build-plus`, `/aidevops-automate`, `/aidevops-seo`, etc. |
| **Aider** | No native slash command support — use a shell alias: `alias aider-build='aider --message-file ~/.aidevops/agents/build-plus.md'`. |

The `aidevops-` prefix differentiates framework commands from each client's native slash commands and groups them alphabetically in the command picker. It applies to **every** aidevops slash command — not just main agents — so `/aidevops-preflight`, `/aidevops-release`, `/aidevops-commit` etc. all sort together in your `/` menu.

Codex setup/update also installs global `AGENTS.md` guidance, native workflow
skills and compatible lifecycle hooks. Build+ loads by default; use `/skills`
for workflows and `/hooks` to review/trust new hooks. Existing personal settings
are preserved. For full-access launch flags and runtime differences, see
[Codex CLI integration](.agents/tools/ai-assistants/codex-cli.md).

#### Supported AI clients (14)

The framework installs itself across these clients. Slash commands, agent definitions, and (optionally) session-memory mining are wired up per-client by `setup.sh`, gated on per-client feature flags in `.agents/scripts/runtime-registry.sh`.

| Client | Slash commands | Agent dir | Memory mining | Notes |
|---|---|---|---|---|
| OpenCode | ✅ `~/.config/opencode/command/` | config-based | ✅ default | Native tab-through primary agents |
| Claude Code | ✅ `~/.claude/commands/` | ✅ `~/.claude/agents/` | ✅ default | Full feature parity |
| Codex CLI | ✅ native skills + legacy `~/.codex/prompts/` | Workflow skills | ✅ default | `$aidevops-<name>`; legacy `/prompts:aidevops-<name>` |
| Cursor | ✅ `~/.cursor/commands/` (≥1.6) | ✅ `~/.cursor/agents/` | ✅ default | Frontmatter stripped (not supported) |
| Droid (Factory) | ✅ `~/.factory/commands/` | — | opt-in | — |
| Gemini CLI | ✅ `~/.gemini/commands/` | — | opt-in | Converted to TOML (`prompt = """..."""`) |
| Kimi CLI | ✅ `~/.kimi/skills/<name>/SKILL.md` | ✅ `~/.kimi/agents/` | opt-in | Directory-per-skill + auto `name:` matching |
| Qwen Code | ✅ `~/.qwen/commands/` | ✅ `~/.qwen/agents/` | opt-in | Sub-agents + skills |
| Continue | ✅ `~/.continue/prompts/` | — | opt-in | `.prompt` ext + `invokable: true` |
| Kiro | ✅ `~/.kiro/steering/` | — | opt-in | `inclusion: manual` for slash access |
| Kilo Code | custom modes | — | opt-in | Uses modes instead of commands |
| Windsurf | repo-local `.windsurf/workflows/` | — | ❌ (protobuf) | Symlinked by `aidevops init` |
| Amp (Sourcegraph) | repo-local `.agents/commands/` | ✅ `~/.amp/agents/` | ❌ (cloud) | Path match is native |
| Aider | shell alias workaround | — | ❌ (per-repo md) | Native custom commands open upstream |

**Feature flags** per client (`agents` / `commands` / `memory`) live in `runtime-registry.sh` and can be overridden at install time via environment variables:

```bash
AIDEVOPS_FEATURE_MEMORY_CLAUDE_CODE=no setup.sh
AIDEVOPS_FEATURE_COMMANDS_CURSOR=no setup.sh
```

Memory mining defaults are deliberately conservative: only OpenCode, Claude Code, Codex, and Cursor are opted in by default. All other clients default to off — enable them case-by-case after reviewing what the mining job will read.

#### Endgame: progressive disclosure

The long-term direction is to make slash commands and `@mentions` unnecessary altogether. A progressive disclosure layer should load the right domain agents and tools into context based on the nature of the conversation — you should never have to remember agent names or prefix commands. The `aidevops-` slash commands documented above are a stepping stone: they standardise routing across every client we support, and will eventually be auto-invoked by the router rather than typed by hand.

### **Example Subagents with MCP Integration**

These are examples of subagents that have supporting MCPs enabled. See `.agents/` for 2,200+ sub agents, including callable skill, workflow and reference modules organized by domain.

| Agent | Purpose | MCPs Enabled |
|-------|---------|--------------|
| `@hostinger` | Hosting, WordPress, DNS, domains | hostinger-api |
| `@hetzner` | Cloud servers, firewalls, volumes | hetzner-* (multi-account) |
| `@wordpress` | Local dev, MainWP management | localwp, context7 |
| `@seo` | Search Console, keyword research, domain intelligence | gsc, ahrefs, serper, context7 |
| `@dataforseo` | SERP, keywords, backlinks, on-page analysis | (curl subagent) |
| `@domain-research` | DNS intelligence: rDNS, subdomains, CNAMEs (THC + Reconeer) | (API-based) |
| `@serper` | Google Search API (web, images, news, places) | serper |
| `@list-keys` | List all configured API keys and storage locations | (read-only) |
| `@code-standards` | Quality standards reference, compliance checking | context7 |
| `@browser-automation` | Testing, scraping, DevTools | chrome-devtools, context7 |
| `@performance` | Core Web Vitals, network analysis, accessibility | chrome-devtools |
| `@git-platforms` | GitHub, GitLab, Gitea | context7 |
| `@sentry` | Error monitoring, Next.js SDK setup | sentry |
| `@socket` | Dependency security scanning | socket |
| `@security-analysis` | AI-powered vulnerability detection (OSV, Ferret, git history) | osv-scanner, gemini-cli-security |
| `@secretlint` | Detect exposed secrets in code | (Docker-based) |
| `@snyk` | Security vulnerability scanning | (API-based) |
| `@auditing` | Code auditing services and security analysis | (API-based) |
| `@agent-review` | Session analysis, agent improvement (under build-agent/) | (read/write only) |

### **Setup for OpenCode**

```bash
# Install aidevops agents for OpenCode
.agents/scripts/generate-opencode-agents.sh

# Check status
.agents/scripts/generate-opencode-agents.sh  # Shows status after generation
```

### **Claude Marketplace**

aidevops is available in the Claude marketplace:

```bash
/plugin marketplace add marcusquinn/aidevops
/plugin install aidevops-all@aidevops
```

**Agent Skills (SKILL.md):** Auto-discovered from `~/.aidevops/agents/` after running `setup.sh`. Compatible with any tool that supports the [Agent Skills standard](https://agentskills.io/specification).

### **Continuous Improvement with @agent-review**

**End every session by calling `@agent-review`** to analyze what worked and what didn't:

```text
@agent-review analyze this session and suggest improvements to the agents used
```

The review agent will:
1. Identify which agents were used
2. Evaluate missing, incorrect, or excessive information
3. Suggest specific improvements to agent files
4. Generate ready-to-apply edits
5. **Optionally compose a PR** to contribute improvements back to aidevops

**This creates a feedback loop:**

```text
Session → @agent-review → Improvements → Better Agents → Better Sessions
                ↓
         PR to aidevops repo (optional)
```

**Contributing improvements:**

```text
@agent-review create a PR for improvement #2
```

The agent will create a safe linked worktree, apply changes, and submit a PR to `marcusquinn/aidevops` with a structured description. Your real-world usage helps improve the framework for everyone.

**Code quality learning loop:**

The `@code-quality` agent also learns from issues. After fixing violations from SonarCloud, Codacy, ShellCheck, etc., it analyzes patterns and updates framework guidance to prevent recurrence:

```text
Quality Issue → Fix Applied → Pattern Identified → Framework Updated → Issue Prevented
```

## **Slash Commands (OpenCode)**

**Slash commands provide quick access to common workflows directly from the OpenCode prompt.** Type `/` to see available commands.

### **Available Commands**

**Planning & Task Management**:

| Command | Purpose |
|---------|---------|
| `/list-todo` | List tasks with sorting, filtering, and grouping |
| `/save-todo` | Save discussion as task or plan (auto-detects complexity) |
| `/plan-status` | Check status of plans in `TODO.md` and `todo/PLANS.md` |
| `/create-prd` | Create a Product Requirements Document for complex features |
| `/generate-tasks` | Generate implementation tasks from a PRD |
| `/log-time-spent` | Log time spent on a task for tracking |
| `/ready` | Show tasks with no open blockers (Beads integration) |
| `/sync-beads` | Sync TODO.md/PLANS.md with Beads task graph |
| `/remember` | Store knowledge for cross-session recall |
| `/recall` | Search memories from previous sessions |

Plans are tracked in `TODO.md` (all tasks) and `todo/PLANS.md` (complex execution plans). Task dependencies are visualized with [Beads](https://github.com/steveyegge/beads).

**`/list-todo` options:**

| Option | Example | Purpose |
|--------|---------|---------|
| `--priority` | `/list-todo -p` | Sort by priority (high → low) |
| `--estimate` | `/list-todo -e` | Sort by time estimate (shortest first) |
| `--tag` | `/list-todo -t seo` | Filter by tag |
| `--owner` | `/list-todo -o marcus` | Filter by assignee |
| `--estimate` | `/list-todo --estimate "<2h"` | Filter by estimate range |
| `--group-by` | `/list-todo -g tag` | Group by tag, owner, status, or estimate |
| `--plans` | `/list-todo --plans` | Include full plan details |
| `--compact` | `/list-todo --compact` | One-line per task |

**Time Tracking**: Tasks support time estimates as active session time (excluding AFK gaps) with the format `~4h started:2025-01-15T10:30Z`. The `session-time-helper.sh` analyses real session data to calibrate estimates vs actuals.

**Risk Levels**: Tasks support `risk:low/med/high` indicating human oversight needed:

| Risk | Oversight | Example |
|------|-----------|---------|
| `low` | Autonomous | Docs, formatting, simple refactors |
| `med` | Supervised | Feature implementation, API changes |
| `high` | Engaged | Security, data migrations, infrastructure |

Configure time tracking per-repo via `.aidevops.json`.

**Development Workflow** (typical order):

| Command | Purpose |
|---------|---------|
| `/context` | Build AI context with Repomix for complex tasks |
| `/feature` | Start a new feature linked-worktree workflow |
| `/bugfix` | Start a bugfix linked-worktree workflow |
| `/hotfix` | Start an urgent hotfix workflow |
| `/linters-local` | Run local linting (shfmt, ShellCheck, secretlint) |
| `/code-audit-remote` | Run remote auditing (CodeRabbit, Codacy, SonarCloud) |
| `/code-standards` | Check against documented quality standards |
| `/code-simplifier` | Simplify and refine code for clarity and maintainability |
| `/testing-setup` | Interactive per-repo testing infrastructure setup with bundle-aware defaults |
| `/list-keys` | List all configured API keys and their storage locations |
| `/performance` | Web performance audit (Core Web Vitals, Lighthouse, PageSpeed) |
| `/pr` | Unified PR workflow (orchestrates all checks) |
| `/review` | Review an issue, PR, local patch, branch, or commit through the shared review core |
| `/cross-review` | Dispatch prompt to multiple AI models, diff results, auto-score |
| `/tech-stack` | Detect technology stacks of URLs or find sites using specific technologies |
| `/mission` | Scope a high-level goal into milestones and features for autonomous execution |
| `/budget-analysis` | Analyze AI model spend, burn rate, and cost optimization opportunities |
| `/report-token-use` | Generate a local per-session token, model, compaction, and MCP-use report |

**Content Workflow**:

| Command | Purpose |
|---------|---------|
| `/humanise` | Remove AI writing patterns, make text sound human |

**Media**:

| Command | Purpose |
|---------|---------|
| `/yt-dlp` | Download YouTube videos/audio/playlists, extract transcripts, convert local files |

**SEO Workflow**:

| Command | Purpose |
|---------|---------|
| `/keyword-research` | Seed keyword expansion with volume, CPC, difficulty |
| `/autocomplete-research` | Google autocomplete long-tail discovery |
| `/keyword-research-extended` | Full SERP analysis with weakness detection |
| `/webmaster-keywords` | Keywords from GSC + Bing for your verified sites |
| `/neuronwriter` | Content optimization with NLP term recommendations and scoring |
| `/seo-export` | Export SEO data from GSC, Bing, Ahrefs, DataForSEO to TOON format |
| `/seo-analyze` | Analyze exported data for quick wins, striking distance, low CTR |
| `/seo-opportunities` | Combined export + analysis workflow |
| `/seo-audit` | Comprehensive SEO audit: technical, on-page, content, E-E-A-T |

**SEO Debugging & Auditing** (subagents in `seo/`):

| Subagent | Purpose |
|----------|---------|
| `@seo-audit` | Comprehensive SEO audit: technical, on-page, content quality, E-E-A-T |
| `@debug-opengraph` | Validate Open Graph meta tags, preview social sharing |
| `@debug-favicon` | Validate favicon setup across platforms (ico, apple-touch, manifest) |

**Email Deliverability**:

| Command | Purpose |
|---------|---------|
| `/email-health-check` | Check SPF/DKIM/DMARC/MX records and blacklist status |

**Release Workflow** (in order):

| Command | Purpose |
|---------|---------|
| `/preflight` | Run quality checks before release |
| `/changelog` | Update CHANGELOG.md with recent changes |
| `/version-bump` | Bump version following semver |
| `/release` | Full release workflow (bump, tag, GitHub release, auto-changelog) |
| `/postflight` | Verify release health after deployment |

**Auto-Task Completion**: The release workflow automatically marks tasks as complete when commit messages reference them (e.g., `Closes t037`, `Fixes t042`). Tasks in `TODO.md` are updated with `completed:` timestamps.

**Documentation**:

| Command | Purpose |
|---------|---------|
| `/readme` | Create or update README.md (supports `--sections` for partial updates) |

**Meta/Improvement**:

| Command | Purpose |
|---------|---------|
| `/add-skill` | Import external skills from GitHub repos (SKILL.md, AGENTS.md, .cursorrules) |
| `/agent-review` | Analyze session and suggest agent improvements |
| `/session-analysis` | Find evidence-backed harness, model-routing, and repository optimisation opportunities |
| `/session-review` | Review session for completeness and capture learnings |
| `/full-loop` | End-to-end development loop (task → preflight → PR → postflight → deploy) |
| `/preflight-loop` | Run preflight checks iteratively until all pass |
| `/runners` | Batch dispatch tasks to parallel agents (task IDs, PR URLs, or descriptions) |
| `/log-issue-aidevops` | Report issues with aidevops (gathers diagnostics, checks duplicates, creates GitHub issue) |

**AI Model Comparison**:

| Command | Purpose |
|---------|---------|
| `/compare-models` | Compare AI models by pricing, context, capabilities (with live web data) |
| `/compare-models-free` | Compare AI models using offline embedded data only (no web fetches) |
| `/score-responses` | Score and compare actual model responses with structured criteria |
| `/route` | Suggest optimal model tier for a task description |

### Ralph Loop - Iterative AI Development

The **Ralph Loop** (named after Ralph Wiggum's persistent optimism) enables autonomous iterative development. The AI keeps working on a task until it's complete, automatically resolving issues that arise.

**How it works:**

```text
Task → Implement → Check → Fix Issues → Re-check → ... → Complete
         ↑                    ↓
         └────────────────────┘ (loop until done)
```

**Usage:**

```bash
# Run quality checks iteratively until all pass
/preflight-loop --auto-fix --max-iterations <MAX_ITERATIONS>

# Or run changed-file checks directly (the default)
.agents/scripts/linters-local.sh

# Run every broad gate at a release boundary
.agents/scripts/linters-local.sh --full
```

**Note:** Store any API credentials securely via environment variables or `.env` files (never commit credentials to version control).

**Key features:**
- Automatic issue detection and resolution
- Configurable max iterations (prevents infinite loops)
- Works with any quality check (linting, tests, builds)
- Detailed logging of each iteration

See `.agents/workflows/ralph-loop.md` for the full workflow guide.

### Full Loop - End-to-End Development Automation

The **Full Loop** chains all development phases into a single automated workflow:

```text
Task Development → Preflight → PR Create → PR Review → Postflight → Deploy
```

**Usage:**

```bash
# Start a full development loop
/full-loop "Implement feature X with tests"

# With options
/full-loop "Fix bug Y" --max-task-iterations 30 --skip-postflight
```

**Options:**

| Option | Description |
|--------|-------------|
| `--max-task-iterations N` | Max iterations for task (default: 50) |
| `--skip-preflight` | Skip preflight checks |
| `--skip-postflight` | Skip postflight monitoring |
| `--no-auto-pr` | Pause for manual PR creation |

The loop pauses for human input at merge approval, rollback decisions, and scope changes.

See `.agents/scripts/commands/full-loop.md` for complete documentation.

### Git Worktrees - Parallel Branch Development

Work on multiple branches simultaneously without stashing or switching. Each branch gets its own directory.

**Recommended: [Worktrunk](https://worktrunk.dev)** (`wt`) - Git worktree management with shell integration, CI status, and PR links:

```bash
# Install (macOS/Linux)
brew install max-sixty/worktrunk/wt && wt config shell install
# Restart your shell for shell integration to take effect

# Create worktree + cd into it
wt switch -c feature/my-feature

# Create worktree + start any AI CLI (-x runs command after switch)
wt switch -c -x claude feature/ai-task

# List worktrees with CI status and PR links
wt list

# Merge + cleanup (squash/rebase options)
wt merge
```

**Fallback** (no dependencies):

```bash
~/.aidevops/agents/scripts/worktree-helper.sh add feature/my-feature
# Creates: ~/Git/{repo}-feature-my-feature/ (cd there manually)
~/.aidevops/agents/scripts/worktree-helper.sh list
~/.aidevops/agents/scripts/worktree-helper.sh clean
# Read-only count/byte inventory of retained recovery archives
~/.aidevops/agents/scripts/worktree-helper.sh recovery
```

Recovery inventory classifies attributable archives as protected or unknown and
never deletes them. OpenCode session history can aid reconstruction, but it does
not replace archive integrity evidence or authorize cleanup.

**Benefits:**
- Run tests on one branch while coding on another
- Compare implementations side-by-side
- No context switching or stash management
- Each AI session can work on a different branch

**Worktree-first workflow:** The pre-edit check now **enforces** worktrees as the default when creating branches, keeping your main directory on `main`. This prevents uncommitted changes from blocking branch switches and ensures parallel sessions don't inherit wrong branch state.

See `.agents/workflows/worktree.md` for the complete guide and `.agents/tools/git/worktrunk.md` for Worktrunk documentation.

### Session Management - Parallel AI Sessions

Spawn new AI sessions for parallel work or fresh context. The framework detects natural session completion points and suggests next steps.

**Completion signals:**

| Signal | Meaning |
|--------|---------|
| PR merged | Branch work complete |
| Release published | Version shipped |
| All tests passing | Quality gates satisfied |
| User says "done" | Explicit completion |

**Spawning options:**

```bash
# Background session (same terminal)
opencode --non-interactive --prompt "Continue with feature X" &

# New terminal tab (macOS)
osascript -e 'tell application "Terminal" to do script "cd ~/Git/project && opencode"'

# Worktree-based (isolated branch) - recommended
wt switch -c -x opencode feature/next-feature  # Worktrunk: create + start AI CLI
# Or fallback:
# ~/.aidevops/agents/scripts/worktree-helper.sh add feature/next-feature
# cd ~/Git/{repo}-feature-next-feature && opencode
```

**Session handoff pattern:**

When ending a session, the AI provides a continuation prompt for the next session:

```markdown
## Continuation Prompt
[Copy this to start a new session with full context]
```

See `.agents/workflows/session-manager.md` for the complete guide.

### Cross-Session Memory System

**"Compound, then clear"** - Sessions should build on each other. The memory system stores knowledge, patterns, and learnings for future sessions using SQLite FTS5 for fast full-text search, with opt-in semantic similarity search via vector embeddings.

**Slash commands:**

| Command | Purpose |
|---------|---------|
| `/remember {content}` | Store a memory with AI-assisted categorization |
| `/recall {query}` | Search memories by keyword |
| `/recall --recent` | Show 10 most recent memories |
| `/recall --auto-only` | Search only auto-captured memories |
| `/recall --stats` | Show memory statistics |
| `/memory-log` | Show recent auto-captured memories |
| `/patterns {task}` | Show success/failure patterns for a task type |
| `/route {task}` | Suggest optimal model tier for a task |

**Memory types:**

| Type | Use For |
|------|---------|
| `WORKING_SOLUTION` | Fixes that worked |
| `FAILED_APPROACH` | What didn't work (avoid repeating) |
| `CODEBASE_PATTERN` | Project conventions |
| `USER_PREFERENCE` | Developer preferences |
| `TOOL_CONFIG` | Tool setup notes |
| `DECISION` | Process, workflow, or policy choices (naming, release cadence, branching) |
| `CONTEXT` | Background info |
| `ARCHITECTURAL_DECISION` | System-level architecture (service boundaries, data flow, tech stack) |
| `ERROR_FIX` | Bug fixes and patches |
| `OPEN_THREAD` | Unresolved questions or follow-ups |
| `SUCCESS_PATTERN` | Approaches that consistently work |
| `FAILURE_PATTERN` | Approaches that consistently fail |

**Semantic search (opt-in):**

```bash
# Enable semantic similarity search (~90MB model download)
memory-embeddings-helper.sh setup

# Search by meaning, not just keywords
memory-helper.sh recall "how to optimize queries" --semantic
```

**Pattern tracking:**

```bash
# Record what worked (via memory system)
memory-helper.sh store --type SUCCESS_PATTERN --content "Structured debugging found root cause" --tags "bugfix,standard"

# Record what failed
memory-helper.sh store --type FAILURE_PATTERN --content "Blind refactor without tests caused regressions" --tags "refactor"

# Get suggestions for a new task
memory-helper.sh recall "refactor auth middleware" --semantic
```

**Auto-capture:** AI agents automatically store memories using `--auto` flag when they detect working solutions, failed approaches, or decisions. Privacy filters strip `<private>` tags and reject secret patterns.

**CLI usage:**

```bash
# Store a memory
~/.aidevops/agents/scripts/memory-helper.sh store --type "WORKING_SOLUTION" --content "Fixed CORS with nginx headers" --tags "cors,nginx"

# Store auto-captured memory (from AI agent)
~/.aidevops/agents/scripts/memory-helper.sh store --auto --content "Fixed CORS with nginx headers" --type WORKING_SOLUTION

# Recall memories (keyword search - default)
~/.aidevops/agents/scripts/memory-helper.sh recall "cors"

# Recall memories (semantic similarity - opt-in)
~/.aidevops/agents/scripts/memory-helper.sh recall "cors" --semantic

# Show auto-capture log
~/.aidevops/agents/scripts/memory-helper.sh log

# View statistics (includes auto-capture counts)
~/.aidevops/agents/scripts/memory-helper.sh stats

# Maintenance
~/.aidevops/agents/scripts/memory-helper.sh validate   # Check for stale entries
~/.aidevops/agents/scripts/memory-helper.sh prune      # Remove stale memories

# Namespaces (per-runner memory isolation)
~/.aidevops/agents/scripts/memory-helper.sh --namespace my-runner store --content "Runner learning"
~/.aidevops/agents/scripts/memory-helper.sh --namespace my-runner recall "query" --shared
~/.aidevops/agents/scripts/memory-helper.sh namespaces  # List all namespaces
```

**Storage:** `~/.aidevops/.agent-workspace/memory/memory.db` (+ optional `embeddings.db` for semantic search, `namespaces/` for per-runner isolation)

#### Session mining (cross-client)

Beyond explicit `/remember` calls, aidevops can harvest structured session data from each supported AI client's on-disk conversation history. This turns every prior session — regardless of which tool you were using — into searchable context for future sessions.

Per-client storage paths and formats (see `runtime-registry.sh`):

| Client | Storage path | Format | Default |
|---|---|---|---|
| OpenCode | `~/.local/share/opencode/opencode.db` | SQLite | ✅ on |
| Claude Code | `~/.claude/projects/` | JSONL per project | ✅ on |
| Codex CLI | `~/.codex/sessions/` | JSONL, date-partitioned | ✅ on |
| Cursor | `~/Library/Application Support/Cursor/User/workspaceStorage/` | SQLite (`state.vscdb`) | ✅ on |
| Droid | `~/.factory/sessions/` | JSONL per session | opt-in |
| Gemini CLI | `~/.gemini/tmp/` | JSON per session | opt-in |
| Continue | `~/.continue/sessions/` | JSON per session | opt-in |
| Kilo Code | `~/Library/.../kilocode.kilo-code/tasks/` | JSON (Anthropic schema) | opt-in |
| Kiro | `~/Library/Application Support/Kiro/User/workspaceStorage/` | SQLite | opt-in |
| Kimi CLI | `~/.kimi/sessions/<id>/context.jsonl` | JSONL | opt-in |
| Qwen Code | `~/.qwen/tmp/` | JSON per session | opt-in |
| Windsurf | `~/.codeium/windsurf/cascade/` | protobuf (opaque) | ❌ unsupported |
| Amp | server-side (cloud) | needs API auth | ❌ unsupported |
| Aider | `<repo>/.aider.chat.history.md` | markdown transcript | ❌ unsupported |

**Defaults are deliberately conservative.** Only the four tier-1 clients — OpenCode, Claude Code, Codex, and Cursor — have memory mining enabled by default. They have the most mature, stable, documented formats and are the ones most likely to contain the full interactive history you'd want to search.

For every other client, memory mining is **opt-in per runtime**. Enable it with:

```bash
AIDEVOPS_FEATURE_MEMORY_GEMINI_CLI=yes setup.sh
AIDEVOPS_FEATURE_MEMORY_CONTINUE=yes setup.sh
```

**Privacy note.** Session files contain everything you typed — including secrets, credentials, and file contents pasted into prompts. The mining pipeline runs secretlint-style scrubbing at ingestion and defaults to local-only storage. Never sync the memory DB to a shared or cloud location without reviewing what's in it.

See `.agents/memory/README.md` for complete documentation.

### **Installation**

Slash commands are automatically installed by `setup.sh` for both OpenCode and Claude Code:

```bash
# OpenCode commands deployed to:
~/.config/opencode/command/

# Claude Code commands deployed to:
~/.claude/commands/

# Regenerate commands manually:
.agents/scripts/generate-opencode-commands.sh
.agents/scripts/generate-claude-commands.sh
```

Both generators read from the same source (`.agents/scripts/commands/*.md`), ensuring command parity across tools.

### **Usage**

In OpenCode or Claude Code, type the command at the prompt:

```text
/preflight
/release minor
/feature add-user-authentication
```

Commands invoke the corresponding workflow subagent with appropriate context.

---

### **Agent Lifecycle (Three Tiers)**

User-created agents survive `aidevops update`. Agents progress through tiers as they mature:

| Tier | Location | Purpose | Survives Update |
|------|----------|---------|-----------------|
| **Draft** | `~/.aidevops/agents/draft/` | R&D, experimental, auto-created by orchestration tasks | Yes |
| **Custom** | `~/.aidevops/agents/custom/` | User's permanent private agents | Yes |
| **Shared** | `.agents/` in repo | Open-source, distributed to all users | Managed by repo |

**Promotion workflow:** Draft agents that prove useful can be promoted to custom (private) or shared (open-source via PR). Orchestration agents can create drafts in `draft/` for reusable parallel processing context.

### **Creating Custom Agents**

Create a markdown file in `~/.config/opencode/agent/` (OpenCode) or reference in your AI's system prompt:

```markdown
---
description: Short description of what this agent does
mode: subagent
temperature: 0.2
tools:
  bash: true
  specific-mcp_*: true
---

# Agent Name

Detailed instructions for the agent...
```

See `.agents/opencode-integration.md` for complete documentation.

---

## **Usage Examples**

### **Server Management**

```bash
# List all servers across providers
./.agents/scripts/servers-helper.sh list

# Connect to specific servers
./.agents/scripts/hostinger-helper.sh connect example.com
./.agents/scripts/hetzner-helper.sh connect main web-server

# Execute commands remotely
./.agents/scripts/hostinger-helper.sh exec example.com "uptime"
```

### **Monitoring & Uptime (Updown.io)**

```bash
# List all monitors
./.agents/scripts/updown-helper.sh list

# Add a new website check
./.agents/scripts/updown-helper.sh add https://example.com "My Website"
```

### **Domain & DNS Management**

```bash
# Purchase and configure domain
./.agents/scripts/spaceship-helper.sh purchase example.com
./.agents/scripts/dns-helper.sh cloudflare add-record example.com A 192.168.1.1

# Check domain availability
./.agents/scripts/101domains-helper.sh check-availability example.com
```

### **Strategic Keyword Research**

```bash
# Basic keyword research with volume, CPC, difficulty
./.agents/scripts/keyword-research-helper.sh research "seo tools" --limit 20

# Google autocomplete long-tail discovery
./.agents/scripts/keyword-research-helper.sh autocomplete "how to" --provider both

# Extended research with SERP weakness detection
./.agents/scripts/keyword-research-helper.sh extended "keywords" --quick

# Competitor keyword research
./.agents/scripts/keyword-research-helper.sh extended --competitor ahrefs.com --limit 50

# Keyword gap analysis (find keywords competitor ranks for but you don't)
./.agents/scripts/keyword-research-helper.sh extended --gap semrush.com,ahrefs.com

# Domain research (all keywords a domain ranks for)
./.agents/scripts/keyword-research-helper.sh extended --domain example.com --limit 100
```

**Features:**

- **6 Research Modes**: Keyword expansion, autocomplete, domain research, competitor research, keyword gap, extended SERP analysis
- **17 SERP Weaknesses**: Low domain score, no backlinks, thin content, UGC-heavy, non-HTTPS, and more
- **KeywordScore Algorithm**: 0-100 score based on weakness count, volume, and difficulty
- **Multi-Provider**: DataForSEO (primary), Serper (autocomplete), Ahrefs (domain ratings)
- **Locale Support**: US/UK/CA/AU/DE/FR/ES with saved preferences
- **Output Formats**: Markdown tables (TUI) and CSV export to ~/Downloads

### **Quality Control & Performance**

```bash
# Run quality analysis with auto-fixes
bash .agents/scripts/qlty-cli.sh check 10
bash .agents/scripts/qlty-cli.sh fix

# Run chunked Codacy analysis for large repositories
bash .agents/scripts/codacy-cli-chunked.sh quick    # Fast analysis
bash .agents/scripts/codacy-cli-chunked.sh chunked # Full analysis

# AI coding assistance
bash .agents/scripts/ampcode-cli.sh scan ./src
bash .agents/scripts/continue-cli.sh review

# Audit website performance
./.agents/scripts/pagespeed-helper.sh wordpress https://example.com
```

## **Documentation & Resources**

**Wiki Guides:**

- **[Getting Started](.wiki/Getting-Started.md)** - Installation and setup
- **[Configuration Reference](.agents/reference/configuration.md)** - All JSONC/JSON config options, types, defaults, and examples
- **[CLI Reference](.wiki/CLI-Reference.md)** - aidevops command documentation
- **[MCP Integrations](.wiki/MCP-Integrations.md)** - MCP servers setup
- **[Providers](.wiki/Providers.md)** - Service provider configurations
- **[Workflows Guide](.wiki/Workflows-Guide.md)** - Development workflows
- **[The Agent Directory](.wiki/The-Agent-Directory.md)** - Agent file structure
- **[Understanding AGENTS.md](.wiki/Understanding-AGENTS-md.md)** - How agents work

**Agent Guides** (in `.agents/`):

- **[API Integrations](.agents/aidevops/api-integrations.md)** - Service APIs
- **[Browser Automation](.agents/tools/browser/browser-automation.md)** - 8 tools + anti-detect stack: decision tree, parallel, extensions, fingerprinting
- **[Device Emulation](.agents/tools/browser/playwright-emulation.md)** - Mobile/tablet testing: 100+ device presets, viewport, geolocation, locale, dark mode
- **[serve-sim](.agents/tools/mobile/serve-sim.md)** - Apple Simulator browser preview/control for mobile app QA
- **[Anti-Detect Browser](.agents/tools/browser/anti-detect-browser.md)** - Multi-profile management, fingerprint rotation, proxy integration
- **[Web Performance](.agents/tools/performance/performance.md)** - Core Web Vitals, network dependencies, accessibility (Chrome DevTools MCP)
- **[PageSpeed](.agents/tools/browser/pagespeed.md)** - Lighthouse CLI and PageSpeed Insights API
- **[Pandoc](.agents/tools/conversion/pandoc.md)** - Document format conversion
- **[Security](.agents/aidevops/security.md)** - Enterprise security standards

**Provider-Specific Guides:** Hostinger, Hetzner, Cloudflare, WordPress, Git platforms, Vercel CLI, Coolify CLI, and more in `.agents/`

## **Architecture**

```text
aidevops/
├── setup.sh                       # Main setup script
├── AGENTS.md                      # AI agent guidance (dev)
├── .agents/                        # Agents and documentation
│   ├── AGENTS.md                  # User guide (deployed to ~/.aidevops/agents/)
│   ├── *.md                       # 14 main agents, plus excluded root guides
│   ├── scripts/                   # 2,010+ helper scripts (including modules; tests excluded)
│   ├── tools/                     # Cross-domain utilities (video, browser, git, etc.)
│   ├── services/                  # External service integrations
│   └── workflows/                 # Development process guides
├── configs/                       # Configuration templates
├── ssh/                           # SSH key management
└── templates/                     # Reusable templates
```

## **Configuration & Setup**

aidevops is configured through two JSONC/JSON files that control framework behaviour, model routing, quality gates, and user preferences. Both are optional -- sensible defaults apply out of the box.

| File | Purpose | CLI |
|------|---------|-----|
| [`~/.config/aidevops/config.jsonc`](.agents/reference/configuration.md#configjsonc--full-reference) | Framework config: updates, models, safety, quality, orchestration, paths | `aidevops config` |
| [`~/.config/aidevops/settings.json`](.agents/reference/configuration.md#settingsjson--full-reference) | User preferences: onboarding, UI, model routing defaults | `settings-helper.sh` |

**Quick examples:**

```bash
# Disable automatic updates
aidevops config set updates.auto_update false

# Use thinking-tier verification for destructive operations
aidevops config set safety.verification_tier thinking

# View all current config values
aidevops config list

# Validate config against schema
aidevops config validate
```

**Precedence:** Environment variables (`AIDEVOPS_*`) > config file > built-in defaults. See the **[full configuration reference](.agents/reference/configuration.md)** for every option, type, default, and example.

### Service Credentials

Service-specific credentials (hosting, DNS, Git platforms, etc.) use a separate template system:

```bash
# 1. Copy and customize configuration templates
cp configs/hostinger-config.json.txt configs/hostinger-config.json
cp configs/hetzner-config.json.txt configs/hetzner-config.json
# Edit with your actual credentials

# 2. Test connections
./.agents/scripts/servers-helper.sh list

# 3. Install MCP integrations (optional)
bash .agents/scripts/setup-mcp-integrations.sh all
```

See [.agents/reference/configuration.md](.agents/reference/configuration.md#service-configuration-templates) for details on the template system and credential security.

## **Security & Best Practices**

**Credential Management:**

- Store API tokens in separate config files (never hardcode)
- Use Ed25519 SSH keys (modern, secure, fast)
- Set proper file permissions (600 for configs)
- Regular key rotation and access audits

### Multi-Tenant Credential Storage

Manage multiple accounts/clients per service with isolated credential sets:

```bash
# Create a new tenant
credential-helper.sh create client-acme

# Switch active tenant
credential-helper.sh switch client-acme

# Set credentials for current tenant
credential-helper.sh set GITHUB_TOKEN ghp_xxx

# Per-project override (gitignored)
echo "client-acme" > .aidevops-tenant

# Export for scripts
source <(credential-helper.sh export)
```

**Resolution priority:** Project `.aidevops-tenant` → Global active tenant → Default

See `.agents/tools/credentials/multi-tenant.md` for complete documentation.

**Quality Assurance:**

- Multi-platform analysis (SonarCloud, CodeFactor, Codacy, CodeRabbit, Qlty, Snyk)
- Automated security monitoring and vulnerability detection

## **Contributing & License**

**Contributing:**

1. Fork the repository
2. Create safe linked worktree for your contribution
3. Add provider support or improvements
4. Test with your infrastructure
5. Submit pull request

**License:** MIT License - see [LICENSE](LICENSE) file for details
**Created by Marcus Quinn** - Copyright © 2025-2026

---

## **What This Framework Achieves**

**For You:**

- Autonomous project management — dispatch a mission and let AI agents handle milestones, validation, and delivery across days
- Cross-domain operations — code, automation, business, marketing, legal, sales, content, video, research, SEO, social media, health, and accounts managed through one platform
- Multi-model safety — destructive operations verified by a second AI provider before execution
- Enterprise-grade quality — multi-platform analysis, automated security monitoring, continual improvement loops
- Infrastructure management — 30+ service integrations with standardized commands across all providers

**For Your AI Agents:**

- Autonomous supervisor — pulse runs every 2 minutes, merging PRs, dispatching workers, killing stuck processes, advancing missions
- Operational intelligence — struggle-ratio detection, orphaned PR recovery, circuit breaker, dynamic concurrency
- Cost-aware routing — provider-aware model selection across OpenAI, Anthropic, Gemini, Cursor, Grok, and local models with budget tracking
- Progressive context — 2,200+ sub agents available on demand, project bundles auto-configuring quality gates and model tiers
- Self-improving — session mining extracts learnings, quality findings auto-create tasks, patterns feed back into agent prompts

**Get Started:**

```bash
# npm (recommended)
npm install -g aidevops && aidevops update

# Bun (fast alternative)
bun install -g aidevops && aidevops update

# Homebrew
brew install marcusquinn/tap/aidevops && aidevops update

# Direct from source
bash <(curl -fsSL https://aidevops.sh/install)
```

**An AI operations platform for launching and managing projects across every business domain — from code to content, infrastructure to invoicing.**

## Star History

![aidevops stars over time](docs/assets/star-history.svg)
