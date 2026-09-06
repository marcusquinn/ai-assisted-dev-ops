---
name: build-agent
description: Agent design and composition - creating efficient, token-optimized AI agents
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Build-Agent - Composing Efficient AI Agents

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Budget**: ~50-100 instructions per agent is a maintainability heuristic; investigate overages, don't cut solely to hit the count; root AGENTS.md universally applicable only
- **Subdivision**: Docs >~300 lines → split into entry point + sub-docs; don't cut to hit a line count
- **MCP servers**: Disabled globally, enabled per-agent
- **Code refs**: `rg "pattern"` search patterns, not `file:line` (line numbers drift)
- **Subagents**: `agent-review.md` (review), `agent-testing.md` (testing)
- **Slash command**: `/build-agent {name} {kind} [category]` → `.agents/scripts/commands/build-agent.md` (interactive harness for creating new agents)
- **Related**: `@code-standards`, `.agents/aidevops/architecture.md`, `.agents/aidevops/purpose.md`, `tools/browser/browser-automation.md`
- **After creating/promoting**: in a source worktree run `AIDEVOPS_AGENTS_DIR="<worktree>/.agents" .agents/scripts/subagent-index-helper.sh generate`; without the override the helper targets the deployed agent tree
- **Behavioural verification when material**: reuse an existing `agent-test-helper.sh` suite or a bounded live prompt; do not create a suite by default
- **Workload tier**: Author `simple`, `standard`, or `thinking`; the preference-ordered runtime mapping in `tools/context/model-routing.md` selects concrete providers/models.
- **Improvement contract**: All agents inherit `reference/self-improvement.md`; add only domain-specific evidence triggers, sensitivity boundaries, and promotion routes
- **Purpose and ownership**: Read `.agents/aidevops/purpose.md` before changing value, repository/forge ownership, or cross-domain delegation semantics; preserve its decisions through the delivered route.

<!-- AI-CONTEXT-END -->

## Main Agent vs Subagent

| Aspect | Main Agent | Subagent |
|--------|-----------|----------|
| **Scope** | Broad domain | Specific tool/service/task |
| **Role** | Coordinates, strategic | Focused independent execution |
| **Location** | Root of `.agents/` | `tools/`, `services/`, `workflows/` |
| **MCP tools** | NEVER enable directly | Enable per-agent |

Execution role does not limit useful domain knowledge. For a bounded primary-domain
child or lighter canonical subset, use `reference/agent-routing.md` "Focused domain
delegation". Derive knowledge from the verified canonical source, not a hand-written
parallel prompt. Keep the child's tools, authority, effort and resource ownership
inside the parent envelope; source readiness never grants permission.

## Subagent YAML Frontmatter (Required — omitting defaults to read-only)

```yaml
---
description: Brief description of agent purpose
mode: subagent
tools:
  read: true      # Low risk
  write: false    # Medium risk - adds files
  edit: false     # Medium risk - changes files
  bash: false     # High risk - arbitrary execution
  glob: true      # Low risk
  grep: true      # Low risk
  webfetch: false # Low risk
  task: true      # Medium risk - delegates work
---
```

- **MCP tool patterns** (subagents only): `context7_*: true`, `wordpress-mcp_*: true`. Injected by plugin at startup — do not set in `opencode.json` directly.
- **MCP tool filtering** (future `includeTools` — 17k→1.5k token savings): `mcp_requirements: { chrome-devtools: { tools: [navigate_page, take_screenshot] } }`
- **Main-branch write restrictions**: Interactive sessions use a linked worktree for every edit. Only headless bookkeeping and explicitly planning-only workers may use the narrow exception enforced by `pre-edit-check.sh`; follow `workflows/pre-edit.md` instead of duplicating its allowlist.
- **Adding a new MCP** (two files required — plugin is authoritative, not `opencode.json`):
  1. `mcp-registry.mjs` `getMcpRegistry()`: `{ name, command/url, eager: false, toolPattern: "foo_*", globallyEnabled: false }`
  2. `agent-loader.mjs` `AGENT_MCP_TOOLS`: `"my-agent": ["foo_*"]`
  Then add `foo_*: true` to the agent's frontmatter `tools:` block for documentation.
- **Source of truth**: `.agents/` → deployed to `~/.aidevops/agents/` by `setup.sh`. Stubs: `~/.config/opencode/agent/` via `generate-opencode-agents.sh`.
- **Deployment sync**: changes in `.agents/` require `./setup.sh`. Offer to run on create/rename/move/merge/delete.

## Folder Organization

```text
.agents/
├── AGENTS.md           # Entry point (ALLCAPS)
├── {agent}.md          # Main agents at root (lowercase, strategy/what)
├── {agent}/            # Extended knowledge for that agent (flat files)
├── tools/              # Cross-domain capabilities (how to do it)
├── services/           # External integrations (how to connect)
├── workflows/          # Process guides (how to process)
├── reference/          # Operating rules (how to operate)
├── scripts/            # Shared helper scripts (flat, cross-domain)
├── scripts/commands/   # Slash command definitions
├── configs/            # Configuration templates and schemas
├── bundles/            # Project-type presets
├── templates/          # Reusable templates
├── rules/              # Enforced constraints
├── tests/              # Agent test suites
├── custom/             # User's private agents (survives updates)
└── draft/              # R&D experimental (survives updates)
```

**Placement test:** "Would another agent use this independently?" Yes → `tools/`/`services/`/`workflows/`/`reference/`. No → `{agent}/`.

### The `{name}.md` + `{name}/` Convention

- **Single-file**: `{name}.md` — no directory needed
- **Multi-file**: `{name}.md` (entry point, always loaded) + `{name}/` (extended knowledge, on demand)
- Prefer flat files with prefix-based naming (`marketing-sales/meta-ads*.md`). Max depth: 2 levels. Subdirectory only when a prefix group exceeds ~20 files.

### Scripts: Flat by Design

Scripts flat in `scripts/` — cross-domain, any agent can call any script. Prefix naming (`email-*`, `seo-*`) for grouping. `*-helper.sh` = agent-callable; other `.sh` = framework infra. `scripts/commands/` = slash commands.

### Ingested Skills

External skills retain `-skill` suffix (provenance marker for `skill-update-helper.sh`). Structure flattened on ingestion: `SKILL.md` → `{name}-skill.md`; `{name}-skill/references/*.md` → `{name}-skill/{topic}.md`; nested `CHEATSHEET/*.md` → `{name}-skill/cheatsheet-{topic}.md`. See `add-skill.md`.

### Naming Conventions

- **Files**: lowercase-hyphens (`kebab-case`). ALLCAPS for entry points only. Python: `snake_case`.
- **Scripts**: `[domain]-[function]-helper.sh` (agent-callable), `[name].sh` (framework infra).
- **Subagent discovery**: `find -mindepth 2` skips root-level main agents.
- **File structure** — main agents: `# Name` → AI-CONTEXT Quick Reference → docs. Subagents: YAML frontmatter + content.
- **Slash commands**: NEVER define inline in main agents. Generic → `scripts/commands/{command}.md`. Domain-specific → `{domain}/{subagent}.md`.

## Model Tier Selection

Author workload semantics, not provider families. Frontmatter uses `model: simple|standard|thinking`; `tools/context/model-routing.md` owns the current preference-ordered provider/model mapping. Concrete names belong in that mapping or in dated outcome/benchmark evidence, not as abstract tier definitions. Record outcomes with `/remember "SUCCESS/FAILURE: agent with model — reason"`. Full routing guidance: `tools/context/model-routing.md`, `reference/task-taxonomy.md`.

| Tier | Workload contract | Agent use |
|------|-------------------|-----------|
| `tier:simple` | Complete, bounded instructions with no unresolved design choice | Mechanical execution of prescriptive briefs with exact code blocks |
| `tier:standard` | Established patterns plus normal implementation judgment and recovery | Code, review, debugging, documentation, and multi-file coordination |
| `tier:thinking` | Planning, design, refactoring, or consequential trade-offs | Architecture, novel problems, security analysis, and work decomposition |

| Situation | Action |
|-----------|--------|
| >75% success, 3+ comparable samples | Use pattern data to justify a workload-tier override |
| Insufficient data | Use routing rules, record outcomes |
| Contradicts routing rules | Note conflict in agent docs |

### Designing tier-aware output

Agents that *create work* (issues, briefs, review findings) should format output so the implementing worker can be dispatched at `tier:simple`:

- **Provide verbatim code**: `Current` / `Proposed` blocks should be exact oldString/newString, not paraphrased descriptions. Historical benchmark evidence: Haiku achieved 100% success with exact code and 0% with "change X to Y" descriptions.
- **Include file paths with line ranges**: `path/to/file.ts:45-60`, not "the auth module".
- **One finding = one edit**: Don't bundle multiple changes into a single narrative finding. Each discrete edit should be a separate, mechanically executable step.
- **Add verification**: A bash one-liner the worker runs after applying the edit.

This applies to: code-simplifier findings, quality-feedback issues, review-feedback issues, and any agent that creates `auto-dispatch` work items.

## Quality Checking

Linter order: (1) deterministic (ShellCheck, ESLint, Ruff/Pylint), (2) static analysis (SonarCloud, Secretlint), (3) LLM review (CodeRabbit — architectural only). Prefer `bun`/`bunx` over `npm`/`npx`. Never send an LLM to do a linter's job. Prefer official docs, RFCs, source code, first-party data over outdated tutorials or vendor claims.

## Agent Design Checklist

1. **YAML frontmatter?** All subagents require it
2. **Universally applicable?** >80% of tasks? If not → more specific subagent
3. **Pointer instead?** Use `rg "pattern"` or Context7 MCP if content exists elsewhere
4. **Code example?** Authoritative? Will it drift? Security: placeholders only
5. **Instruction count?** Treat budgets as investigation heuristics; before reducing, recover directive provenance and distinguish exact duplicates from boundary reinforcement (see `agent-review.md`)
6. **Duplicates?** `rg "pattern" .agents/` before adding
7. **Existing agent?** Call and improve vs duplicate — never create a copy
8. **Sources verified?** Primary, cross-referenced
9. **Markdown linting?** MD025/MD022/MD031/MD012. Run `bunx markdownlint-cli2 "path/to/file.md"`
10. **Ambient learning complete?** The inherited contract works without a command; document only domain-specific signals, scope/sensitivity, and verification
11. **Terse pass done?** See below

## Post-Creation Semantic Terse Pass (MANDATORY)

Every loaded token needs decision value, but size reduction is not the success criterion. Apply the canonical rubric in `agent-review.md` before shortening an instruction surface: recover provenance, classify each retained directive, and preserve activation/exclusion boundaries and delivery paths.

**Tighten only with semantic equivalence:** verbose phrasing → direct rule; narrative → preserve the protected rationale and its task/issue evidence; repeated examples → keep an authoritative example only when every boundary remains covered; multi-sentence rule → one sentence only when scope and conditions survive. **Preserve:** task IDs (`tNNN`), issue refs (`GH#NNN`), all rules/constraints, interfaces, triggers, file paths, command examples, code blocks, safety-critical detail.

Verify the target through its delivered runtime context, applicable existing checks, and existing relevant Agent Testing/comprehension scenarios. Add or expand scenarios only when requested, required by the target contract, or when they are the lowest-cost way to resolve material delivery uncertainty; do not create a harness by default. Historical evidence: the t1679 `build.txt` pass reduced bytes by 63% while its 25 protected patterns remained covered; that result is not blanket permission to remove unverified prose. See `agent-review.md` and `tools/code-review/code-simplifier.md` "Instruction surfaces".

## Code Examples: When to Include

**Include:** authoritative with no implementation elsewhere; security-critical template; command syntax IS the doc. **Avoid:** exists in codebase (use search pattern); external library (Context7 MCP); will drift (point to source).

## Self-Assessment Protocol

**Triggers**: Observable failure, user correction, contradiction with primary evidence/codebase, staleness, repeated friction, or a reusable success. **Process**: (1) Preserve the current outcome. (2) Identify and cite the evidence. (3) `rg "pattern" .agents/` — find coordinated surfaces and duplicates. (4) Apply and verify a safe, authorized, in-scope fix; otherwise capture the narrow learning or route a worker-ready task. Ask only at the escalation boundaries in `reference/self-improvement.md`.

## Tool Selection

| Task | Preferred | Avoid |
|------|-----------|-------|
| Find files | `git ls-files` / `fd` | `mcp_glob` |
| Search contents | `rg` | `mcp_grep` |
| Read/Edit files | `mcp_read` / `mcp_edit` | `cat`/`sed` via bash |
| Web content | `mcp_webfetch` | `curl` via bash |
| Remote repo | `mcp_webfetch` README first | `npx repomix --remote` |
| Parallel AI dispatch | OpenCode server API | Multiple TUI instances |

Self-checks: "Faster CLI alternative?" and "Could this return >50K tokens?" See `tools/context/context-guardrails.md`.

## Agent Lifecycle Tiers

| Tier | Location | Survives `setup.sh` | Git Tracked | Purpose |
|------|----------|---------------------|-------------|---------|
| **Draft** | `~/.aidevops/agents/draft/` | Yes | No | R&D, experimental |
| **Custom** | `~/.aidevops/agents/custom/` | Yes | No | User's private agents |
| **Sourced** | `~/.aidevops/agents/custom/<source>/` | Yes | In private repo | Synced from private Git repos |
| **Shared** | `.agents/` in repo | Yes (deployed) | Yes | Open-source, submitted via PR |

Ask user which tier. Draft: `status: draft` + `created` date, promote via PR or discard. Custom: never shared/overwritten. Shared: safe linked worktree + PR, no proprietary info. Orchestration agents: draft reusable patterns, log TODO, reference in Task calls.

## Cache-Aware Prompt Patterns

Stable prefix (variable content at end), critical rules first (primacy effect), AI-CONTEXT blocks for essential stable content, minimize MCP tool churn between sessions.

## Reviewing Existing Agents

See `agent-review.md` for systematic review (instruction budgets, universal applicability, duplicates, code examples, AI-CONTEXT blocks, stale content, MCP configuration).
