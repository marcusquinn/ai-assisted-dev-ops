---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18203: Generate the canonical aidevops agent roster from discovery metadata

## Pre-flight

- [x] Memory recall: `canonical aidevops agent roster discovery stable IDs workload tiers framework guide` → 0 hits — no reusable stored lesson found.
- [x] Discovery pass: 0 commits, 0 merged PRs, and 0 open PRs touch the exact roster targets; recent agent-discovery commits do not generate a provider-neutral team-interface roster.
- [x] File refs verified: 9 canonical discovery, frontmatter parsing, tier, app-team schema, framework-guide, smoke-test, architecture, mission, and source-review references checked against current merged source.
- [x] Tier: `tier:standard` — source inclusion, stable-ID derivation, tier defaults, framework-guide handling, output schema, failure behavior, and regression boundaries are decided below.
- [x] Seeded draft PR decision recorded: skipped — a partial generator without live add/remove propagation, duplicate-ID rejection, and existing discovery regressions would be unsafe for adapters to consume.

## Origin

- **Created:** 2026-08-05
- **Session:** OpenCode interactive mission `m-20260804-5d06b1`
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** t18201
- **Blocked by:** none — F1.3 merged through PR #29510
- **Conversation context:** The app-team contract stores canonical `template_agent_id` and provider-neutral workload tiers but deliberately does not hard-code the current agent list. Milestone 2 now needs a deterministic live roster for adapters and launch overlays.

## What

Refactor the shared canonical discovery library to expose primary-agent source
metadata, then add a deterministic roster generator and version-1 schema. The
generator emits the current 13 root-discovered primary agents plus one
`aidevops` framework guide, with stable IDs, source references/digests, display
names, descriptions, roles, and `simple|standard|thinking` workload tiers.

The roster is generated to stdout by default and may be atomically written only
when an explicit output path is supplied. It does not edit OpenCode/Claude
configuration, choose a concrete provider/model, create provider agents, or
copy instruction bodies into team manifests.

## Why

Hard-coding 13 names in Buzz, aidevops.app, or OpenCode overlays would drift as
agents are added, removed, renamed, or retiered. The existing
`discover_primary_agents()` function already defines canonical inclusion and
ordering, but its runtime config dictionaries omit the stable source metadata
needed by team-interface consumers. One shared source iterator prevents a
second discovery algorithm.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The generator contract and compatibility behavior are fully
specified, but safely refactoring shared discovery and validating deterministic
schema output requires normal multi-file implementation judgment.

## PR Conventions

This is a leaf child of parent t18201. Use a closing keyword for this issue and
a non-closing parent reference. Do not close the parent or implement the
OpenCode launch overlay from this branch.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Shared discovery must retain both OpenCode and Claude smoke behavior while the complete roster/schema/add-remove test matrix lands together.
- **Status:** `not-created`
- **Freshness evidence:** Exact-path discovery, live canonical enumeration, frontmatter tiers, app-team references, and framework-guide source were refreshed on 2026-08-05.
- **Verification run:** Live inspection found 13 primary sources; Content, PR, and Vault explicitly use `thinking`, the other ten default to `standard`; implementation tests are unrun.
- **Stale-assumption warning:** Re-run live discovery and check source frontmatter immediately before implementation if any root `.agents/*.md` or discovery library changed.

## How (Approach)

### Progressive Context Plan

- **Read first:** this brief's Worker Quick-Start and `.agents/scripts/lib/agent_config.py:24-45,150-157,163-179,235-278` — these define inclusion, names, ordering, tiers, and the refactor seam.
- **Then load:** `.agents/schemas/team-interface/app-team-v1.schema.json:40-61` and `.agents/reference/team-interface-app-teams.md:44-60` — these define the consuming ID/tier boundary.
- **Load only if:** frontmatter or discovery compatibility is unclear — `.agents/scripts/lib/discovery_utils.py:36-83` and `.agents/scripts/tests/test-agent-discovery-smoke.sh:45-119`.
- **Why:** generate one portable roster without duplicating current names, provider models, runtime permissions, or instruction contents.
- **Stop when:** live and fixture discovery, stable IDs, source digests, tier defaults, framework-guide inclusion, deterministic output, and existing discovery compatibility each have a focused assertion.

### Worker Quick-Start

```text
1. Canonical primary inclusion remains root-level Markdown minus SKIP_FILES; ordering remains AGENT_ORDER then case-insensitive display name.
2. Add one shared source-record iterator in agent_config.py and make discover_primary_agents() consume it. Do not create a second glob/filter loop in the roster script.
3. Require explicit frontmatter name metadata for roster entries. Add name: product to product.md so every current primary has one; existing runtime discovery remains backward-compatible for external fixtures lacking name.
4. Stable IDs are agent.<frontmatter-name>. The separately included aidevops.md guide uses agent.aidevops-guide and kind framework_guide.
5. Workload tier is frontmatter model when it is simple, standard, or thinking; otherwise default to standard when absent and fail roster generation when a non-canonical value is present.
6. Source metadata contains a repository/deployment-relative source reference and SHA-256 content digest, never copied instructions, absolute host paths, provider IDs, or model IDs.
7. Default output is canonical JSON on stdout. Explicit --output uses the existing atomic_json_write helper and must not mutate runtime configs.
8. Tests derive expected primary membership from fixture files and canonical discovery; never embed the 13-name list in implementation code.
```

### Files to Modify

- EDIT: `.agents/scripts/lib/agent_config.py:24-45,150-157,163-179,246-278` — expose one source-record iterator and reuse it for existing primary config discovery.
- EDIT: `.agents/product.md:1-5` — add missing canonical `name: product` frontmatter metadata without changing instructions, tools, or routing.
- NEW: `.agents/scripts/team-interface-agent-roster.py` — provider-neutral roster CLI, canonical serialization/digest, validation, stdout, and explicit atomic output.
- NEW: `.agents/schemas/team-interface/agent-roster-v1.schema.json` — closed roster and agent-record contract referencing core stable IDs.
- NEW: `.agents/reference/team-interface-agent-roster.md` — identity, inclusion, tiers, source provenance, consumers, compatibility, and failure behavior.
- NEW: `.agents/scripts/tests/test-team-interface-agent-roster.mjs` — live and sandbox discovery, schema, deterministic, add/remove/rename, tier, duplicate, and regression tests.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/agent-discovery.py` and `.agents/scripts/opencode-agent-discovery.py` continue reading `discover_primary_agents()`; `.agents/scripts/team-interface-agent-roster.py` reads the new shared source iterator; future Buzz/OpenCode/app-team consumers read roster JSON.
- **Writers/mutation paths:** `.agents/scripts/team-interface-agent-roster.py` writes only an explicitly supplied `--output` path through `.agents/scripts/lib/discovery_utils.py::atomic_json_write`; default execution is stdout-only and existing runtime configuration writers remain unchanged.
- **Tests/fixtures:** `.agents/scripts/tests/test-team-interface-agent-roster.mjs` creates temporary agent fixtures and invokes live discovery; `.agents/scripts/tests/test-agent-discovery-smoke.sh` and `.agents/scripts/tests/test-canonical-model-tiers.sh` remain required regressions.
- **Schemas/config:** `.agents/schemas/team-interface/agent-roster-v1.schema.json` is the only new schema; `.agents/product.md` gains metadata, while OpenCode/Claude config schemas and concrete model-routing tables are not modified.
- **Generated/deployed mirrors:** The Python generator and schema deploy with `.agents/`; roster JSON is ephemeral or caller-owned explicit output and is never committed as a duplicated static registry.
- **Migrations/backfills:** Current canonical IDs are introduced from existing frontmatter names, with `product` made explicit before first publication; future name changes require an explicit alias/migration rather than silently reusing a display label.
- **Cleanup/rollback paths:** Reverting `.agents/scripts/team-interface-agent-roster.py`, its schema/reference, and the `agent_config.py` source-iterator refactor restores prior discovery; explicit roster output is caller-owned cache data and may be regenerated, while no provider agent or runtime config requires cleanup.

### Implementation Steps

1. Add `name: product` to Product frontmatter so every current canonical primary has an explicit stable source name. Do not alter its body, mode, subagents, tools, or tier.
2. Refactor `agent_config.py` with a source-record iterator returning path, filename, frontmatter, stable source name, display name, subagent list, and workload-tier metadata in canonical order. Preserve current warnings, tool configuration, return shape, disabled agents, and external fixture fallback in `discover_primary_agents()`.
3. Add a closed draft-2020-12 roster schema with `$id` `urn:aidevops:team-interface:agent-roster:v1`, `schema_version: 1`, `document_type: agent_roster`, stable roster ID/digest, and non-empty unique agent records.
4. Define each record with `agent_id`, `kind`, `display_name`, `description`, `source_ref`, `source_digest`, and `workload_tier`. Restrict kinds to `primary|framework_guide`, tiers to the canonical three, references to relative registered values, and digests to SHA-256.
5. Generate primary IDs as `agent.` plus explicit frontmatter `name`. Include `.agents/aidevops.md` separately as `agent.aidevops-guide`; reject duplicate IDs, missing live canonical names, invalid name syntax, unknown tiers, absolute paths, and concrete provider/model fields.
6. Canonically sort records using existing discovery order, compute each source digest from exact bytes, compute `roster_digest` over canonical records with the digest member omitted, and serialize with stable key order and a trailing newline.
7. Support `--agents-dir`, `--format json`, and optional `--output`. Default agents directory is the deployed `~/.aidevops/agents`; tests pass an explicit repository or sandbox directory. Reject unsupported formats and output aliases to source files.
8. Add live assertions for exactly 13 primaries plus one framework guide at current HEAD, three explicit thinking tiers, ten standard defaults, stable unique IDs, no concrete model/provider values, and schema validity.
9. Add sandbox assertions proving additions/removals propagate without list edits, display/filename rename with unchanged explicit name preserves ID, source-content change alters only its digest/roster digest, duplicate names and non-canonical tiers fail, and output is byte-identical across runs.
10. Run the new roster suite, existing agent discovery smoke and canonical-tier tests, Python compilation, and changed-file lint. Create a WIP checkpoint after focused tests.

### Hazards and Compatibility

- **Concurrency/atomicity:** Stdout generation has no shared state. Explicit output uses atomic replacement; two writers produce complete documents, and callers use `roster_digest` to detect a newer/different snapshot rather than reading partial JSON.
- **Migration/rollback:** This is the first roster version. Stable IDs derive from explicit source names, not display labels; future source-name changes require explicit alias/migration data. Rollback removes additive output without changing provider identities.
- **Mixed-version/backward compatibility:** Existing `discover_primary_agents()` callers retain their tuple/config shape, warnings, ordering, and fallback for test/custom files lacking `name`. Roster generation itself fails closed when canonical deployed primaries lack required names or tiers.
- **Idempotency/retry:** Unchanged source bytes and metadata produce byte-identical JSON and digest. Re-running explicit output is safe; changed membership, tier, description, or source bytes yields a new digest without editing runtime config.
- **Partial failure/recovery:** Any unreadable source, duplicate/invalid ID, bad tier, schema failure, or output error exits nonzero and leaves the previous explicit output intact. No partial roster is emitted as valid and no provider fallback is inferred.

### Verification Before Dispatch

```bash
node .agents/scripts/tests/test-team-interface-agent-roster.mjs
bash .agents/scripts/tests/test-agent-discovery-smoke.sh
bash .agents/scripts/tests/test-canonical-model-tiers.sh
python3 -m py_compile .agents/scripts/lib/agent_config.py .agents/scripts/team-interface-agent-roster.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The roster suite covers source iteration, schema, IDs, tiers, provenance, determinism, and negatives; existing smoke tests protect OpenCode/Claude discovery; canonical-tier tests prevent provider-family regression; compile/lint cover Python, JSON, Markdown, licensing, and secrets.
- **Broad verification trigger:** Not required — shared discovery callers receive focused smoke coverage, and the task does not change setup, model routing, worker dispatch, dependencies, or release infrastructure.

### Recoverability Checkpoint

- [ ] Focused tests pass: `node .agents/scripts/tests/test-team-interface-agent-roster.mjs && bash .agents/scripts/tests/test-agent-discovery-smoke.sh`
- [ ] WIP commit created before broad gates: `wip: add canonical team-interface agent roster`
- [ ] Evidence-triggered broad verification then run: not required; run `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Generate one canonical provider-neutral roster without duplicating the agent list or concrete model routing.
- **Preserved user directions:** Include 13 primary agents and the aidevops guide, use stable IDs and workload tiers, propagate source changes automatically, and preserve existing runtime behavior.
- **Trigger and evidence:** not triggered
- **Completed and verified:** Live source count/tier evidence, discovery seams, app-team consumer boundaries, and output decisions are captured here.
- **Remaining acceptance criteria:** Implement and verify source refactoring, schema, generator, documentation, live/sandbox tests, and regression gates.
- **Unsafe route not to repeat:** Do not hard-code 13 names, copy instructions, use display labels as IDs, store concrete provider/model IDs, or overwrite OpenCode/Claude config.
- **Next safe route:** Keep prior discovery untouched, fix the exact source/schema/generation error, and regenerate from verified metadata.
- **Resume condition:** No overlapping root-agent/discovery PR exists and current canonical files still pass source-name/tier preflight.
- **Owner and status:** Assigned implementation worker; not-triggered.

### Files Scope

- `.agents/scripts/lib/agent_config.py`
- `.agents/product.md`
- `.agents/scripts/team-interface-agent-roster.py`
- `.agents/schemas/team-interface/agent-roster-v1.schema.json`
- `.agents/reference/team-interface-agent-roster.md`
- `.agents/scripts/tests/test-team-interface-agent-roster.mjs`

## Acceptance Criteria

- [ ] Current source generates one schema-valid roster containing 13 unique primary records and one `agent.aidevops-guide` framework-guide record in canonical order.

  ```yaml
  verify:
    method: bash
    run: "node .agents/scripts/tests/test-team-interface-agent-roster.mjs"
  ```

- [ ] Content, PR, and Vault resolve to `thinking`; the other ten current primaries and the guide resolve to `standard`; only canonical workload tiers appear.

  ```yaml
  verify:
    method: codebase
    pattern: "thinking|standard|WORKLOAD_TIERS|frontmatter"
    path: ".agents/scripts/tests/test-team-interface-agent-roster.mjs"
  ```

- [ ] Adding or removing a fixture primary propagates without an implementation list edit, while a display or filename rename preserving explicit `name` does not change its stable ID.

  ```yaml
  verify:
    method: codebase
    pattern: "add|remove|rename|stable.*id|frontmatter.*name"
    path: ".agents/scripts/tests/test-team-interface-agent-roster.mjs"
  ```

- [ ] Duplicate or missing canonical names, non-canonical tiers, concrete provider/model values, absolute source paths, and unknown schema fields are rejected without replacing prior output.

  ```yaml
  verify:
    method: codebase
    pattern: "duplicate|missing.*name|non-canonical|provider|model|absolute|unknown|prior.*output"
    path: ".agents/scripts/tests/test-team-interface-agent-roster.mjs"
  ```

- [ ] Existing OpenCode and Claude agent discovery behavior does not regress after the shared source-iterator refactor.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-agent-discovery-smoke.sh && bash .agents/scripts/tests/test-canonical-model-tiers.sh"
  ```

- [ ] Python, JSON, Markdown, license, and secret quality gates pass.

  ```yaml
  verify:
    method: bash
    run: "python3 -m py_compile .agents/scripts/lib/agent_config.py .agents/scripts/team-interface-agent-roster.py && .agents/scripts/linters-local.sh --changed"
  ```

## Context & Decisions

- Root-level canonical discovery remains authoritative; the roster does not introduce a second include/exclude list.
- Explicit frontmatter `name` is the stable identity source. Product receives its missing name before first roster publication; display labels remain presentation only.
- The framework guide is deliberately separate from primary runtime agents and receives stable ID `agent.aidevops-guide`.
- Workload tiers are routing intent. Runtime-specific model and reasoning-variant resolution remains in existing model-routing/OpenCode seams.
- Source digests provide immutable provenance without copying instructions into portable team manifests.

## Relevant Files

- `.agents/scripts/lib/agent_config.py:24-45,150-157,163-179,235-278` — canonical skip set, tier set, name conversion, ordering, and root discovery.
- `.agents/scripts/lib/discovery_utils.py:16-33,36-83` — atomic output and frontmatter parser.
- `.agents/scripts/agent-discovery.py:21-50,113-153` — current canonical consumer and OpenCode config writer that must not change behavior.
- `.agents/scripts/tests/test-agent-discovery-smoke.sh:45-119,173-237` — sandbox discovery and compatibility pattern.
- `.agents/schemas/team-interface/app-team-v1.schema.json:40-61` — consuming `template_agent_id` and workload-tier fields.
- `.agents/reference/team-interface-app-teams.md:44-60` — canonical discovery/model boundary.
- `.agents/aidevops.md:1-47` — separately included framework guide source.
- `.agents/product.md:1-5` — the only current primary missing explicit `name` metadata.
- `.agents/aidevops/architecture.md:32-59` — provider-neutral runtime and workload-tier rule.

## Dependencies

- **Blocked by:** none — F1.3 app-team manifest contracts merged through #29510.
- **Blocks:** F2.5 restricted OpenCode overlays, F3.3 team mapping management, F5.1 app-team instantiation, and F6.6 project-scoped Buzz channels.
- **External:** Python 3, Node, and repository-pinned Ajv are already present. No model/provider credential, live runtime, network request, package install, or provider account is required.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Source/discovery read | 30m | Reconfirm callers, frontmatter, count, and tiers |
| Shared iterator and generator | 1h 15m | Backward-compatible discovery refactor and CLI |
| Schema and provenance | 35m | Closed records, IDs, digests, canonical output |
| Live/sandbox tests | 50m | Add/remove/rename, duplicates, tiers, determinism, regressions |
| Documentation and gates | 20m | Reference, compile, existing tests, changed lint |
| **Total** | **3h 30m** | |
