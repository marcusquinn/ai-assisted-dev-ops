---
description: AI DevOps framework architecture context
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AI DevOps Framework Context

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Services**: 25+ integrated (hosting, DNS, Git, code quality, email, etc.)
- **Pattern**: `./.agents/scripts/[service]-helper.sh [command] [account] [target] [options]`
- **Config**: `configs/[service]-config.json.txt` (template) → `configs/[service]-config.json` (gitignored)
- **Categories**: Infrastructure (4), Deployment (1), Git (4), DNS (5), Code Quality (4), Security (1), Email (1)
- **MCP Ports**: 3001 (LocalWP), 3002 (Vaultwarden), 3003+ (code audit, git platforms)
- **Extension**: See `.agents/aidevops/extension.md`

<!-- AI-CONTEXT-END -->

## Supported Runtime Integrations

Claude Code, OpenCode and [Codex CLI](../tools/ai-assistants/codex-cli.md) support interactive workflows. Canonical agents, workflows, and
workload tiers remain provider-agnostic; generated adapters and runtime
configuration supply runtime-specific commands, tools, and concrete model mappings.

Key OpenCode integrations: agents via `generate-opencode-agents.sh`, generated slash
commands, the compaction plugin at `.agents/plugins/opencode-aidevops/`, the
near-empty compatibility placeholder at `.agents/prompts/build.txt`, and native
tools at `.opencode/tool/*.ts`.

### OpenCode Native Tools (`.opencode/tool/`)

Files in `.opencode/tool/` are **OpenCode plugin tools** — TypeScript modules loaded by the Bun runtime, NOT shell-script wrappers. Before deleting any `.ts` file, check for unique logic (DB access, API calls, state management) — only thin wrappers are redundant.

| File | Purpose |
|------|---------|
| `ai-research.ts` | Routes isolated research queries through configured OpenCode providers |
| `session-rename.ts` | Renames sessions via direct SQLite write — no HTTP API exists |

The native `ai_research` tool uses canonical `simple`, `standard`, and `thinking`
workload tiers. The headless OpenCode runtime owns model availability, provider
selection, credential isolation, and inference transport. A per-child ceiling
reduces the `research-only` profile to inference-only because the parent supplies
all requested agent and file context in a private bounded artifact. Legacy
`haiku`, `sonnet`, and `opus` inputs remain aliases; exact provider-neutral token
usage and output-token enforcement are reported as unavailable or advisory when
the selected runtime does not expose them.

## Judgment and Deterministic Enforcement

Use model judgment for open-ended decisions; use deterministic automation for
mechanics whose correct outcome can be specified and tested.

aidevops replaced a 37,000-line deterministic supervisor because scripts were
encoding prioritisation, triage, stuck detection, and trade-offs without enough
context. Preserve that lesson: agent guidance owns judgment semantics and helpers
may collect evidence, but a script must not silently decide an open-ended policy.

Deterministic hooks, validators, wrappers, and CI checks should enforce syntax,
schemas, path safety, idempotency, exact state transitions, and other reproducible
invariants. State or tracking is justified only when the workflow has an explicit
owner, lifecycle, privacy boundary, and recovery contract.

**Decision test:** If reasonable models could choose differently from the same
evidence, improve the owning decision rule and expose better evidence. If the
expected result is mechanically decidable, implement or strengthen deterministic
enforcement and retain the concise invariant until delivery is verified. Use
`.agents/tools/build-agent/agent-review.md` before changing instruction semantics.

### Operational update and privilege boundary

`aidevops update` is a user-space operational transaction: it must never launch
an editor, pager, composition flow, or privileged repair implicitly. A stale
root-owned component is reported as a machine-readable deferred action and is
reconciled only by an explicit human-owned scoped setup command in an attached
terminal. Non-TTY execution must not consume inherited or cached sudo authority.

Source-read exceptions follow the same low-friction/least-privilege invariant.
One human decision may sign an exact, bounded manifest of tracked files from one
Git worktree for one user, runtime session, reason, content set, and TTL. It must
not authorize directories, additional paths, another worktree, changed bytes, or
shell execution. Regression coverage lives in
`test-aidevops-update-transaction.sh`, `test-setup-source-access-broker.sh`,
`test-source-access-helper.py`, and `test-source-access-approval.mjs`.

Examples: version bumping, file discovery, credential lookup, schema validation,
and safety guards belong in tools; dispatch priority, diagnosis, decomposition,
and trade-offs remain model judgment. See `reference/progressive-disclosure.md`
for prompt-to-hook migration.

## Agent Architecture

**Build+** is the unified coding agent for planning and implementation:

- **Intent detection**: Auto-detects deliberation vs execution mode
- **Planning**: Parallel explore agents, investigation phases, synthesis
- **Execution**: Pre-edit git check, quality gates, autonomous iteration
- **Specialist subagents**: `@aidevops` for framework ops, `@plan-plus` for planning-only

## Agent Design Patterns

Implements proven patterns from Lance Martin (LangChain), validated across Claude Code, Manus, and Cursor.

| Pattern | aidevops Implementation |
|---------|------------------------|
| **Give Agents a Computer** | `~/.aidevops/.agent-workspace/`, helper scripts, bash tools |
| **Multi-Layer Action Space** | Per-agent MCP filtering via `generate-opencode-agents.sh`, ~12-20 tools/agent |
| **Progressive Disclosure** | Subagent tables in AGENTS.md, read-on-demand, YAML frontmatter |
| **Offload Context** | `.agent-workspace/work/[project]/` for persistent files |
| **Cache Context** | Stable instruction prefixes, avoid reordering between calls |
| **Isolate Context** | Subagent markdown files with specific tool permissions |
| **Ralph Loop** | `workflows/ralph-loop.md`, `full-loop-helper.sh` |
| **Evolve Context** | `/remember`, `/recall` with SQLite FTS5, `memory-helper.sh` |

### MCP Lifecycle Pattern

| Factor | MCP | curl subagent |
|--------|-----|---------------|
| Tool count | 25+ | 5-10 endpoints |
| Auth | OAuth2 token exchange | Simple Bearer/Basic/API key |
| Session frequency | Most sessions | Occasional |
| Statefulness | Persistent connection | Stateless REST |

**Two-tier MCP strategy** (all MCPs use `eager: false` and start disabled):

1. **Explicit activation agents** (`activationAgent`): a bounded profile can use `aidevops_mcp` to connect its registry-approved MCP. Playwright is the preferred browser implementation; Playwriter remains explicit legacy compatibility.
2. **Per-agent permission only** (`globallyEnabled: false`): tool patterns stay hidden globally and are exposed only on the owning agent profile.

**How it works:** OpenCode treats `enabled: false` as disconnected, not automatic lazy loading. An explicit activation agent calls the registry-allowlisted `aidevops_mcp` tool, which uses OpenCode's MCP connect API and waits for the asynchronous status to report `connected`. An observed `failed` or `error` status gets one bounded disconnect/reconnect reset; direct API errors, authentication requirements, timeouts, and a second failed status remain terminal. The MCP tools appear on the following model step and can be disconnected when work is complete. There are no idle MCP processes or tool-schema cost in unrelated sessions. The plugin registry is authoritative; do not edit generated `opencode.json` MCP entries directly.

**Adding runtime activation for an MCP requires:**
1. `mcp-registry.mjs` — add the MCP plus an explicit `activationAgent`, `agentSource`, and `modelTier`.
2. `agent-mcp-tools.mjs` — keep its tool pattern restricted to the owning agent.
3. A focused activation test — prove registry allowlisting, global denial, and bounded agent registration without recursive leaf discovery.

**Replaced by curl subagent** (removed): hetzner, serper, ahrefs, hostinger — simple REST, no persistent state needed.

**Migrate MCP → curl subagent when:** simple REST with Bearer/Basic auth, <10 endpoints, no complex state, all patterns fit one markdown file. Saves ~2K context tokens permanently.

## Extension Guide

Full guide: `.agents/aidevops/extension.md`. Naming conventions: `tools/build-agent/build-agent.md`.

**Summary:** Helper scripts at `.agents/scripts/[service-name]-helper.sh`, config templates at `configs/[service-name]-config.json.txt`, docs at `.agents/[SERVICE-NAME].md`. Required functions: `check_dependencies`, `load_config`, `get_account_config`, `api_request`, `list_accounts`, `show_help`, `main`. Update `.gitignore`, `README.md`, `setup-wizard-helper.sh` after adding.

**Security standards** (all services): API token validation, rate limiting awareness, secure credential storage, input validation, error message sanitization, audit logging, confirmation prompts for destructive operations.

## Shell Helper Initialization

All shell scripts under `.agents/scripts/**/*.sh` MUST follow the canonical shared-variable initialization pattern. Short rule: source `shared-constants.sh` OR guard fallbacks with `[[ -z "${VAR+x}" ]]`. Never declare `RED`, `GREEN`, `YELLOW`, `BLUE`, `PURPLE`, `CYAN`, `WHITE`, or `NC` at top level without a guard, and never `readonly` those names outside `shared-constants.sh` itself.

Why the rule exists: PR #18728 fixed one instance of an unguarded re-assignment colliding with `readonly` in `shared-constants.sh`, which had killed `setup.sh` under `set -Eeuo pipefail` and broke auto-update for 4 days (GH#18702 primary, GH#18693 cascade victim). The same bug shape is latent in 18 other helpers today — this section exists to prevent the next occurrence.

Full guide with Patterns A/B/C, banned patterns, audit data, and migration checklist: **`reference/shell-style-guide.md`**. CI enforcement ships in t2053 Phase 2 via `shell-init-pattern-check.sh`.

## Knowledge Organization Model

The `.agents/` directory organizes knowledge along two axes: **strategy** (what to do) and **execution** (how to do it). Full conventions in `tools/build-agent/build-agent.md` "Folder Organization".

**Main agents** at root (e.g., `marketing-sales.md`, `seo.md`) own domain strategy. Their matching directories contain extended strategy knowledge loaded on demand.

| Directory | Contains | Used by |
|-----------|----------|---------|
| `tools/` | Capabilities — browser, git, database, code review, deployment | Any agent |
| `services/` | Integrations — hosting, payments, communications, email providers | Any agent |
| `workflows/` | Processes — git flow, release, PR review | Any agent |
| `reference/` | Operating rules — planning, sessions, security | Any agent |

**Scripts:** All scripts live flat in `scripts/` — shared utilities callable by any agent. Prefix naming (`email-*`, `seo-*`, `browser-*`) provides grouping. `*-helper.sh` = agent-callable; other `.sh` = framework infra.

**Flat files over nested folders:** Prefer prefix-based names over subdirectories. Max depth from `.agents/`: 2 levels. See `tools/build-agent/build-agent.md`.

## Top-Level Repository Layout Policy

The repository root is a public contract, not a scratch space. New top-level files or directories must fit one of these classes and be added to `.agents/configs/repo-layout-policy.conf` with a one-line rationale before they are introduced:

- **Public entrypoints:** user-facing commands and repo metadata such as `setup.sh`, `aidevops.sh`, `README.md`, `LICENSE`, `VERSION`, and governance docs.
- **Framework internals:** implementation and source-of-truth framework assets such as `.agents/`, `configs/`, `templates/`, `tests/`, `setup-modules/`, and temporary root shell modules pending cleanup.
- **Runtime and plugin surfaces:** runtime integration packages such as `.claude-plugin/`, `.opencode/`, and editor/runtime config files.
- **Packaging surfaces:** distribution and package-manager assets such as `bin/`, `scripts/`, `homebrew/`, `package.json`, and lock/dependency files.
- **Repo-local data planes:** underscore-prefixed local working areas such as `_knowledge/`, `_cases/`, `_campaigns/`, `_inbox/`, `_feedback/`, `_projects/`, `_performance/`, and `_reports/`.
- **Docs and planning:** documentation and task surfaces such as `.wiki/`, `docs/`, `todo/`, `TODO.md`, and model/reference docs.
- **Generated or ignored tooling surfaces:** intentionally tracked tool config and generated-input files such as `.github/`, `.qlty/`, lint configs, Repomix configs, and scanner config.

Run `.agents/scripts/repo-layout-audit-helper.sh --check` to audit tracked top-level drift. The audit is non-destructive: it reports unknown paths and recommends likely homes, but never moves files.

## Storage Lifecycle

Framework storage ownership, safety classes, convergence rules, and the
read-only reporting contract are defined in
`reference/storage-lifecycle.md`. Store-specific cleanup must preserve that
contract and fail closed when ownership or active-reference evidence is
unavailable.

**Ingested skills** retain the `-skill` suffix as a provenance marker for automated upstream update checks. On ingestion, upstream structure is transposed to `{name}-skill.md` + `{name}-skill/`. See `tools/build-agent/add-skill.md`.
