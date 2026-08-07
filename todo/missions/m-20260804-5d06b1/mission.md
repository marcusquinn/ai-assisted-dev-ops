---
id: "m-20260804-5d06b1"
title: "Build provider-neutral agent-team integrations for aidevops and aidevops.app"
status: active
mode: full
repo: "aidevops"
created: "2026-08-04"
started: "2026-08-04"
completed: ""

budget:
  time_hours: 0
  money_usd: 0
  token_limit: 0
  alert_threshold_pct: 80

model_routing:
  orchestrator: thinking
  workers: standard
  research: simple
  validation: standard

preferences:
  tech_stack: [bash, python, typescript, rust, tauri, opencode, acp, nostr]
  deploy_target: "aidevops.app, local and remote aidevops runners, and provider adapters"
  test_framework: "repository-native unit, contract, security, migration, and integration tests"
  ci_provider: "existing repository CI providers"
  coding_style: "provider-neutral core, thin adapters, deterministic security boundaries, progressive disclosure"
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Build provider-neutral agent-team integrations for aidevops and aidevops.app

> Let people configure, operate, and safely share aidevops agent teams through Buzz, Matrix, aidevops.app, and future collaboration interfaces without duplicating orchestration or coupling aidevops to one app, forge, model provider, community, or machine.

## Origin

- **Created:** 2026-08-04
- **Created by:** Marcus Quinn and AI DevOps
- **Session:** OpenCode interactive planning session
- **Context:** A source review of Buzz and aidevops established a feasible architecture for exposing aidevops agents through Buzz. Follow-up direction added an Infrastructure > Integrations control plane in aidevops.app, reusable app-specific agent teams, adaptive trust-based ingress scanning, ongoing upstream compatibility monitoring, and an optional Private PI agent for private, guided Buzz onboarding.

## Scope

**Goal:** Deliver a provider-neutral team-interface plane that can detect, configure, reconcile, observe, and safely operate collaboration providers; expose it through an Infrastructure > Integrations section in aidevops.app; provision dedicated or shared agent teams for aidevops and other applications; route conversational and delegated work into the correct existing aidevops execution mode; and continuously detect provider drift as Buzz, Matrix, and later integrations evolve.

**Success criteria:**

- One provider-neutral contract represents providers, communities, identities, conversations, teams, channels, forums, projects, connectors, runners, authority, desired state, reconciliation, and compatibility status.
- Buzz is the first adapter and Matrix is migrated behind the same contract without regressing its existing room, entity, session, and runner behavior.
- aidevops.app exposes Infrastructure > Integrations setup and management backed by the same core APIs and helpers used by CLI/setup automation; no security or reconciliation logic exists only in the UI.
- The current 13 primary aidevops agents and the `aidevops` framework specialist are generated from canonical discovery, not a duplicated hard-coded registry.
- Other applications can define dedicated teams, cloned specialists, or explicitly shared specialist capabilities with isolated identity, memory, workspace, credential, and authority scopes.
- aidevops can optionally add a clearly AI-labelled, app-scoped Private PI agent to managed Buzz configuration; it guides users through onboarding, proposes contextual next steps, and produces owner-reviewable findings that improve and standardise onboarding without autonomous configuration writes.
- Reconciliation is idempotent and non-destructive: user-customized fields are preserved, security-critical drift fails closed, missing upstream capabilities fall back to owner-reviewed plans, and records are never adopted by display-name matching alone.
- Buzz conversations, direct interactive sessions, delegated headless jobs, Pulse, routines, remote runners, and local models keep distinct lifecycle ownership and do not dispatch duplicate work.
- Trust and content screening are risk-adaptive: low-overhead structural controls apply universally, expensive scanning is performed once at ingress only where provenance, membership, content, attachment, or requested capability raises risk.
- Verified membership grants only the configured role/capability scope; it never implicitly grants administrator, secret, destructive, publication, or release authority.
- Multiple machines cannot emit duplicate work under one logical identity; active-passive operation is supported first and multi-active operation requires a distributed lease with fencing.
- Upstream source monitoring records supported versions and baselines, detects relevant changes, runs compatibility fixtures, deduplicates findings, and creates worker-ready follow-up work only for verified actionable drift.
- Release/update messages are posted at most once per provider/community/version and only after the deployed aidevops version is verified.
- Security, privacy, latency, token, and compute overhead are measured by trust profile so safeguards remain proportionate rather than universally expensive.

**Mode:** full

**Non-goals:**

- Do not make Buzz, Matrix, aidevops.app, or any future interface the authoritative aidevops orchestrator, scheduler, worktree manager, or forge state store.
- Do not silently install collaboration apps, create unused channels/forums, enable write-capable agents, or publish externally.
- Do not overwrite user-edited names, avatars, models, startup preferences, team memberships, channel mappings, or other declared user-owned fields.
- Do not treat a username, display name, channel membership, prompt instruction, or model judgment as an authorization boundary.
- Do not rescan identical trusted content independently for every agent or every turn; ingress results are content-addressed and reused within their policy lifetime.
- Do not exempt external attachments, bridged content, or capability-escalating requests merely because a trusted local owner submitted them.
- Do not share long-lived memory, credentials, private workspace roots, or mutable identity keys across unrelated app teams by default.
- Do not clone one signing/private identity onto multiple concurrently active machines without a lease and fencing mechanism.
- Do not migrate repositories to Buzz or any forge merely to bind them to a project or conversation.
- Do not ship deceptive human impersonation. Optional private personas remain clearly AI-labelled and use original or appropriately licensed identity assets for distributed templates.
- Do not let Private PI profile people, inspect unrelated private data, contact external parties, publish findings, or change Buzz configuration without explicit user authority and the normal plan/review/apply gates.
- Do not create all implementation issues at mission creation. Brief and issue each leaf feature when its milestone dependencies and current upstream evidence are known.

**Constraints:**

- Canonical aidevops agents, workload tiers, execution workflows, and forge operations remain runtime/provider/interface agnostic.
- OpenCode and Claude Code remain supported runtimes; Buzz/OpenCode-specific configuration belongs in generated adapters or launch overlays.
- Existing aidevops worktree, headless, Pulse, routine, release, approval, secret, privacy, and audit invariants remain authoritative.
- Current Buzz agent CLI submits owner-reviewed drafts and does not provide safe unattended provisioning; unattended reconciliation waits for stable external IDs, managed ownership metadata, revision/CAS semantics, and a supported apply API.
- Current Buzz ACP permission behavior is not a sufficient approval boundary for write-capable conversational agents; the first usable profile is read-only with explicit broker handoff for mutations.
- Community state and local roots are scoped per provider/community. Portable identity never implies portable history, memory, authority, or credentials.
- Configuration stores public identifiers and secret references only. Private keys/tokens remain in approved secret storage and never appear in manifests, UI payloads, logs, issues, or prompts.
- Mission features may span aidevops, aidevops.app, Buzz upstream, packaging/deployment repositories, and provider-specific test fixtures. Each repository follows its own contribution and release workflow.
- Budgets are intentionally unset during capture. Each feature brief must include an evidence-based estimate before issue creation or dispatch.

## Trust and ingress policy

Screening is layered and risk-adaptive rather than a single mandatory expensive pass.

| Profile | Typical source | Default screening | Default capabilities |
|---------|----------------|-------------------|----------------------|
| `owner-local` | Verified owner using an owner-controlled local machine/interface | Signature/provenance, size/type/path controls, dedup, secret-output guard; no semantic prompt scan for ordinary direct text | Configured owner capabilities, while destructive/security/billing/release gates remain explicit |
| `trusted-team` | Verified member in an approved team/channel on managed shared infrastructure | Universal structural checks plus cached deterministic prompt-pattern scan; semantic escalation only for suspicious content, external attachments, or high-risk actions | Role-scoped capabilities; no implicit admin or secret authority |
| `shared-member` | Verified non-admin user intentionally given selected AI capabilities | Deterministic prompt-injection scan before model use, sandboxed attachment extraction, broker-enforced action scope | Read/answer/draft by default; explicitly granted non-admin operations only |
| `external-bridged` | Unknown user, public forum, email/social connector, webhook, or unverified bridge | Strict scan/quarantine, content limits, attachment isolation, provenance labelling, no direct local execution | Read-only or draft-only; privileged work requires trusted review and a new authorized job |

Rules common to every profile:

- Authorization is deterministic and independent of the content scanner.
- Scan once at ingress and cache by content hash, scanner/policy version, provenance class, and attachment digest.
- Re-scan when content, provenance, policy version, or requested capability changes.
- Validate event signatures, schemas, sizes, MIME/type claims, path boundaries, correlation IDs, and idempotency keys even for trusted owners.
- Extract large or active attachments only when needed, in a bounded sandbox; metadata-only preflight is the default.
- Internally generated signed events may skip semantic scanning but never structural validation, authorization, or output-secret checks.

## Agent-team model

Each product/application may declare a team manifest with:

- stable team and app IDs;
- dedicated agent instances;
- specialist templates to clone with isolated identity/memory;
- shared stateless specialist capabilities;
- provider/community bindings;
- repository/project/workspace roots;
- trust profile and authority scopes;
- model workload tiers, not fixed provider/model IDs;
- channel/forum/connector mappings;
- runner and local-model eligibility;
- managed versus user-owned fields.

Supported specialist modes:

1. **Dedicated:** app-specific identity, memory, channels, credentials, and workspace.
2. **Cloned specialist:** canonical specialist instructions copied into an isolated app identity and namespace.
3. **Shared capability:** one stateless capability service used by multiple teams while each request retains separate actor, app, community, project, and audit context.

Shared capability must not mean shared conversation memory or a shared signing identity. Default to cloned specialists whenever output is published as a team member or needs app-specific memory/reputation.

### Private PI onboarding agent

Private PI is an optional aidevops-managed Buzz agent, not a default framework identity. It is created only when the user selects it during Buzz onboarding or later enables it through the provider-neutral team configuration.

- Scope inputs to explicitly selected Buzz capability/configuration metadata, user-approved onboarding progress, and the current app/team context.
- Provide contextual setup guidance, reusable checklists, feature-discovery ideas, and structured friction findings that can improve versioned onboarding templates.
- Keep memory, identity, workspace, and model capabilities private and app-scoped; prefer restricted local-model execution where available and preserve transparent AI identity.
- Require owner review before findings alter shared onboarding templates or managed Buzz configuration; route any mutation through the same deterministic plan/review/apply contract as other integrations.
- Never investigate people, infer sensitive traits, ingest unrelated private sources, or turn onboarding observations into external monitoring or publication.

## Milestones

Milestones are sequential. Features within a milestone may be parallelized only where their dependencies and repositories do not overlap. Every feature receives a worker-ready brief before implementation.

### Milestone 1: Provider-neutral contracts and threat model

**Status:** complete
**Estimate:** 19h
**Validation:** Versioned schemas and reference documentation define the complete provider, resource, identity, trust, desired-state, reconciliation, event, authority, compatibility, and app-team contracts; fixtures prove deterministic validation and no secrets are represented.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 1.1 | Define the team-interface provider, capability, community, identity, resource, inbox/outbox, and compatibility contracts | t18193 | complete | 4h | vladimirdulov | #29505 |
| 1.2 | Define adaptive ingress trust profiles, scan caching, attachment handling, and deterministic authority enforcement | t18194 | complete | 3.5h | alex-solovyev | #29518 |
| 1.3 | Define app-team manifests for dedicated, cloned, and shared specialists with identity/memory/workspace isolation | t18196 | complete | 3.5h | vladimirdulov | #29510 |
| 1.4 | Define managed-field ownership, three-way reconciliation, revision/CAS, retirement, rollback, and audit semantics | t18197 | complete | 4h | marcusquinn | #29528 |
| 1.5 | Define upstream compatibility metadata, watched surfaces, change classification, and actionable-drift lifecycle | t18198 | complete | 4h | marcusquinn | #29526 |

### Milestone 2: Read-only core and initial provider adapters

**Status:** active
**Estimate:** 25.5h; all five implementation leaves briefed
**Validation:** A non-mutating CLI/core detects providers, validates configuration, generates stable desired state, reports compatibility/drift, and produces repeatable plans for Buzz and Matrix without installation, credential exposure, or provider writes.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 2.1 | Implement provider registry, config loader, state store, status/doctor commands, and deterministic dry-run planner `[depends:F1.1] [depends:F1.4]` | t18202 | complete | 6h | marcusquinn | #29619 |
| 2.2 | Generate the canonical 13 aidevops agents plus the framework guide from discovery metadata, including workload tiers and stable IDs `[depends:F1.3]` | t18203 | complete | 3.5h | marcusquinn | #29605 |
| 2.3 | Implement the read-only Buzz adapter for installation/runtime detection, communities, agents, teams, and capability reporting `[depends:F2.1]` | t18205 | complete | 5h | marcusquinn | #29636 |
| 2.4 | Refactor the existing Matrix integration behind the same provider/event/authority contract without behavior regression `[depends:F2.1]` | t18207 | in progress (#29646) | 6h | marcusquinn | |
| 2.5 | Generate restricted OpenCode launch overlays for canonical agent selection, workload variant, interface context, and read-only conversational permissions `[depends:F2.2]` | t18208 | claimed (#29647) | 5h | marcusquinn | |

### Milestone 3: aidevops.app Infrastructure > Integrations control plane

**Status:** pending
**Estimate:** unestimated
**Validation:** Users can inspect, configure, plan, review, enable, disable, and diagnose Buzz, Matrix, and future providers from one Integrations section; every operation uses the provider-neutral backend and clearly displays trust, ownership, drift, and side effects before apply.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 3.1 | Specify the aidevops.app Integrations information architecture, backend API boundary, capability-driven provider cards, and navigation placement `[depends:F1.1]` | pending | pending | brief first | | |
| 3.2 | Build provider setup flows for detection, install guidance, authentication references, community selection, roots, and plan review `[depends:F2.1]` | pending | pending | brief first | | |
| 3.3 | Build agent-team, channel, forum, connector, runner, and project mapping management `[depends:F1.3] [depends:F2.2]` | pending | pending | brief first | | |
| 3.4 | Build trust-policy, managed/user field, compatibility, drift, health, audit, and reconciliation views `[depends:F1.2] [depends:F1.4] [depends:F1.5]` | pending | pending | brief first | | |

### Milestone 4: Buzz upstream safety and managed provisioning

**Status:** pending
**Estimate:** unestimated
**Validation:** Upstream-compatible Buzz changes or equivalent supported APIs provide verified ordinary-event handling, fail-closed permission mediation, initiator-aware OpenCode titles, stable externally managed records, owner-review support, and revision-safe reconciliation.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 4.1 | Verify and harden ordinary-event signature/provenance checks at the Buzz ACP client boundary | pending | pending | brief first | | |
| 4.2 | Replace unconditional ACP `allow_once` behavior with explicit fail-closed policy and owner/user approval mediation | pending | pending | brief first | | |
| 4.3 | Add first-verified-initiator context to Buzz-created ACP session titles while preserving channel and aidevops suffix behavior | pending | pending | brief first | | |
| 4.4 | Add stable external IDs, `managed_by`, managed fields, source version/hash, revision/CAS, dry-run diff, and supported apply semantics for agents and teams | pending | pending | brief first | | |
| 4.5 | Deliver owner-reviewed aidevops team onboarding as the fallback until unattended apply satisfies all safety gates `[depends:F2.3] [depends:F2.5]` | pending | pending | brief first | | |

### Milestone 5: App-specific teams, projects, and multi-machine execution

**Status:** pending
**Estimate:** unestimated
**Validation:** At least two distinct app teams can use dedicated and shared specialists without context leakage; projects bind existing repositories without migration; runner identity and leases prevent duplicate conversational or delegated work across machines; optional Private PI onboarding produces private, bounded, repeatable guidance and owner-reviewable improvement findings without autonomous writes.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 5.1 | Instantiate app-specific teams with dedicated and cloned identities, memories, roots, and credentials `[depends:F1.3] [depends:F2.1]` | pending | pending | brief first | | |
| 5.2 | Implement shared specialist capabilities with per-request app/community/actor isolation and no shared publication identity `[depends:F5.1]` | pending | pending | brief first | | |
| 5.3 | Separate Project, Repository, Forge Adapter, Conversation Binding, and Execution Root; add provider capability negotiation `[depends:F1.1]` | pending | pending | brief first | | |
| 5.4 | Add Buzz-native Git/NIP-34, GitLab, Gitea, and Forgejo adapters after the current GitHub implementation `[depends:F5.3]` | pending | pending | brief first | | |
| 5.5 | Add runner-node registration, trust/capability profiles, active-passive leases, monotonic fencing, and stale-writer rejection | pending | pending | brief first | | |
| 5.6 | Add optional Private PI to aidevops-managed Buzz configuration for private app-scoped onboarding guidance, reusable checklists, contextual ideas, and owner-reviewed onboarding-standard improvements, with restricted local-model capabilities and transparent AI identity `[depends:F4.5] [depends:F5.1] [depends:F5.5]` | pending | pending | brief first | | |

### Milestone 6: Channels, forums, connectors, and delegated work

**Status:** pending
**Estimate:** unestimated
**Validation:** Configured accounts materialize only intended channels/forums, external content follows its trust profile, conversational requests can create one authorized delegated job, and status/results return to the originating thread without loops or duplicate side effects. Project-scoped Buzz channels resolve to the intended canonical project, configured agent, and execution root without duplicate materialization or cross-project context leakage.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 6.1 | Implement provider-neutral channel/forum connector accounts, cursors, provenance, bidirectional mappings, draft/publish modes, and selective materialization | pending | pending | brief first | | |
| 6.2 | Implement the authority broker and signed/correlated handoff from conversations to interactive or headless aidevops execution `[depends:F1.2] [depends:F2.5]` | pending | pending | brief first | | |
| 6.3 | Return progress, approvals, results, and failures to the originating thread with loop prevention and content-addressed idempotency `[depends:F6.2]` | pending | pending | brief first | | |
| 6.4 | Publish aidevops release/update messages once per provider/community/version after verified deployment `[depends:F2.1]` | pending | pending | brief first | | |
| 6.5 | Add workflow templates only for deterministic automation; adopt consequential approval gates after upstream executor wiring is complete | pending | pending | brief first | | |
| 6.6 | Materialize one managed Buzz channel per enabled `repos.json` project, named from its stable project slug, attach its configured project agent, and launch OpenCode ACP at its canonical execution root `[depends:F2.2] [depends:F2.3] [depends:F2.5] [depends:F4.4] [depends:F5.1] [depends:F5.3] [depends:F6.1]` | pending | pending | brief first | | |

### Milestone 7: Compatibility monitoring, validation, and staged rollout

**Status:** pending
**Estimate:** unestimated
**Validation:** Automated routines detect relevant provider changes, compatibility fixtures pass across supported versions/providers/trust profiles, overhead is measured, security failures fail closed, documentation is complete, and rollout can be independently disabled or rolled back per provider/community.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 7.1 | Extend upstream watch with Buzz and later provider baselines, scoped source surfaces, release/tag detection, and deduplicated impact classification `[depends:F1.5]` | pending | pending | brief first | | |
| 7.2 | Run adapter contract fixtures against supported/current upstream versions and create worker-ready drift issues only after premise verification `[depends:F7.1]` | pending | pending | brief first | | |
| 7.3 | Benchmark ingress screening latency, tokens, CPU, cache effectiveness, and attachment overhead across all trust profiles `[depends:F1.2]` | pending | pending | brief first | | |
| 7.4 | Validate spoofing, prompt injection, attachment, privilege escalation, duplicate delivery, stale lease, user customization, rollback, and secret-redaction cases | pending | pending | brief first | | |
| 7.5 | Complete operator/user documentation, migration guidance, compatibility matrix, staged enablement, observability, and rollback drills | pending | pending | brief first | | |

## Brief and issue creation protocol

1. Start a fresh context and read this mission plus `research/source-review.md`.
2. Brief Milestone 1 features first. Do not create downstream implementation issues until their contracts/dependencies are sufficiently stable.
3. Run duplicate discovery for each feature against open/merged work before creating an issue.
4. Every brief identifies exact repository and likely files, upstream version/symbol checks, reference patterns, security boundaries, migration behavior, and focused verification.
5. Parent/architecture trackers remain `parent-task`. Leaf implementation issues default to normal auto-dispatch semantics only when they are genuinely worker-ready.
6. Cross-repository features receive separate leaf tasks/PRs linked to this mission; upstream Buzz contributions follow Buzz's DCO/contribution rules and stop at a verified ready PR unless separate merge/publication authority exists.
7. Do not bulk-dispatch the mission. Advance sequential milestones only after validation.

## Open decisions for feature briefs

- Confirm the current aidevops.app repository, backend/API architecture, Infrastructure navigation pattern, and deployment lifecycle before specifying UI files.
- Confirm which Buzz provisioning and permission changes are acceptable upstream versus retained as aidevops adapter behavior.
- Choose the default community identity policy: separate keypair per logical agent/community is recommended; portable identities remain opt-in.
- Choose the first non-aidevops app-team pilot to validate dedicated versus shared specialist behavior.
- Define supported provider version windows and release cadence after initial compatibility fixtures establish maintenance cost.
- Decide which trusted-team actions can bypass semantic scanning while retaining deterministic authorization and structural checks; measure before setting defaults.

## Resources

| Name | Type | Purpose | Status | Notes |
|------|------|---------|--------|-------|
| aidevops repository | infrastructure | Core contracts, helpers, runtime routing, setup, monitoring, and mission state | configured | Use linked worktrees and repository quality gates |
| aidevops.app repository | dependency | Infrastructure > Integrations UI/control plane | inspect before brief | Path and architecture intentionally not assumed in this mission |
| Buzz source checkout | dependency | Adapter/upstream API and compatibility research | available locally | Baseline commit recorded in `research/source-review.md` |
| Buzz community/desktop | infrastructure | Later owner-reviewed and live integration validation | needed later | No credentials required for contract work |
| Matrix integration | dependency | Existing behavior to migrate behind the shared contract | present in aidevops | Preserve entity/session/privacy semantics |
| OpenCode | infrastructure | ACP conversational runtime and existing aidevops agent configuration | configured | Runtime/provider/model routing remains authoritative |
| Provider credentials and signing keys | credential | Live provider and community tests | needed only for integration phases | Store via approved secret helpers; mission files hold references only |

## Budget Tracking

Feature budgets are intentionally deferred until briefs identify repositories, upstream dependencies, and test boundaries.

| Category | Budget | Spent | Remaining | % Used |
|----------|--------|-------|-----------|--------|
| Time (hours) | unestimated | planning only | n/a | n/a |
| Money (USD) | unestimated | $0 | n/a | n/a |
| Tokens | unlimited pending briefs | planning only | n/a | n/a |

| Date | Category | Amount | Description | Milestone |
|------|----------|--------|-------------|-----------|
| 2026-08-04 | time | planning session | Buzz/aidevops source review, architecture synthesis, and mission capture | planning |

## Decision Log

| # | Date | Decision | Rationale | Alternatives Considered |
|---|------|----------|-----------|------------------------|
| 1 | 2026-08-04 | Build a provider-neutral team-interface plane with Buzz as the first adapter | aidevops must remain usable through future apps and interfaces without duplicating provider logic | Embed Buzz directly into setup/orchestration |
| 2 | 2026-08-04 | Add Infrastructure > Integrations to aidevops.app | Users need one control plane for Buzz, Matrix, channels, forums, agent teams, trust, and drift | Provider-specific standalone screens; CLI only |
| 3 | 2026-08-04 | Keep the CLI/core authoritative and make the UI capability-driven | Setup, automation, headless environments, and UI must produce the same plans and safety decisions | UI-only integration logic |
| 4 | 2026-08-04 | Generate 13 primary agents from canonical discovery and add an `aidevops` framework guide | Avoid registry drift while retaining an integration-aware help specialist | Hard-code agent names in Buzz/aidevops.app |
| 5 | 2026-08-04 | Support dedicated, cloned, and shared specialist modes for other app teams | Apps need reusable expertise without identity, memory, credential, or workspace leakage | One global team/identity for every app |
| 6 | 2026-08-04 | Treat shared specialists as isolated capabilities, not shared long-lived personas | Shared publication identity or memory would blur accountability and leak context | Reuse one agent process and memory globally |
| 7 | 2026-08-04 | Use managed-field three-way reconciliation and stable external IDs | Setup/update must evolve framework-owned defaults without overwriting user customizations | Replace whole provider records; match by name |
| 8 | 2026-08-04 | Keep Buzz conversations separate from delegated headless work, Pulse, and routines | Existing aidevops paths already own worktrees, task claims, retries, and scheduling | Run every mode inside Buzz ACP/workflows |
| 9 | 2026-08-04 | Make ingress screening adaptive to verified provenance, role, content, attachments, and requested capability | Full semantic scanning of every trusted local message wastes latency/tokens, while untrusted/shared ingress needs stronger controls | Scan everything identically; trust everything from a local app |
| 10 | 2026-08-04 | Apply universal low-cost structural checks even for the owner-local profile | Trusted users may still forward malicious attachments or external content, and structural validation is cheap | Completely bypass ingress controls for owners |
| 11 | 2026-08-04 | Treat membership as a role signal, never administrator authority | Shared trusted users should access useful capabilities without gaining config, secrets, release, or destructive powers | Binary trusted/untrusted model |
| 12 | 2026-08-04 | Scan once at ingress and cache by content/provenance/policy hash | Prevent repeated scanner overhead across agents and turns without reusing stale verdicts | Per-agent/per-turn rescanning |
| 13 | 2026-08-04 | Require read-only conversational profiles until Buzz permission mediation is fail-closed | Current ACP behavior auto-selects `allow_once` and cannot safely represent user approval | Enable Build+ write tools immediately; rely on prompts |
| 14 | 2026-08-04 | Use Buzz teams for roster/shared instructions, not orchestration | Team records describe membership/instructions while aidevops owns task routing | Encode delegation plans in team membership |
| 15 | 2026-08-04 | Separate Project, Repository, Forge Adapter, Conversation Binding, and Execution Root | Existing repos should bind to collaboration contexts without migration or GitHub coupling | Treat Buzz Project or GitHub repo as the universal project model |
| 16 | 2026-08-04 | Start multi-machine support as active-passive and require fencing for multi-active | Shared signing keys/processes can otherwise publish duplicate or stale work | Best-effort process checks only |
| 17 | 2026-08-04 | Add compatibility monitoring as a first-class mission capability | Buzz and other providers will evolve; stale assumptions must become verified, deduplicated maintenance work | Rely on manual memory/reviews after breakage |
| 18 | 2026-08-04 | Publish update announcements only after verified deployment and once per community/version | Prevent duplicate or false success messages from multiple machines | Post on every update check or setup run |
| 19 | 2026-08-04 | Keep optional investigator personas private, restricted, transparent, and distributable only with original/licensed assets | Preserve user customization without deceptive identity or branding risk | Ship a real-person imitation as a framework default |
| 20 | 2026-08-04 | Define Private PI as an optional aidevops-managed Buzz onboarding agent whose ideas feed owner-reviewed, versioned onboarding improvements | Give users contextual help while turning recurring friction into consistent onboarding without hidden telemetry, unrelated investigation, or autonomous configuration changes | Use only generic agents; enable Private PI by default; publish raw onboarding observations |
| 21 | 2026-08-05 | Use a dedicated versioned team-interface config with optional later `config.jsonc` enablement/path references | Rich provider/team state must remain portable, independently validated, and outside the global framework config | Nest the complete provider/team schema inside `config.jsonc` |
| 22 | 2026-08-05 | Derive canonical roster IDs from explicit agent source metadata and include `aidevops` separately as `agent.aidevops-guide` | Agent additions/removals and display changes must propagate without a duplicated provider list or concrete model IDs | Hard-code the current 13 names in each adapter |

## Mission Agents

| Agent | Purpose | Path | Promote? |
|-------|---------|------|----------|
| None yet | Create only when multiple feature briefs demonstrate a repeated specialist context gap | | pending |

## Research

| Topic | Summary | Source | Date |
|-------|---------|--------|------|
| Buzz and aidevops integration source review | Current provisioning, ACP title/model/permission behavior, teams, workflows, projects, main-agent discovery, runtime modes, Matrix precedent, forge abstraction, and cross-runner coordination are captured with source references. | `research/source-review.md` | 2026-08-04 |

## Progress Log

| Timestamp | Event | Details |
|-----------|-------|---------|
| 2026-08-04T19:06:55Z | Mission created | Captured the complete provider-neutral Buzz/Matrix/aidevops.app integration direction in Full mode. Status remains planning; no task IDs, issues, provider writes, or implementation dispatches were created. |
| 2026-08-04T19:55:19Z | Milestone 1 feature 1.1 briefed | Validated `todo/tasks/t18193-brief.md` as schema-v2 worker-ready, created issue #29494 with `status:available`, and left features 1.2-1.5 unfiled until their own briefs pass readiness. |
| 2026-08-04T20:09:43Z | Milestone 1 feature 1.2 briefed | Validated `todo/tasks/t18194-brief.md` as schema-v2 worker-ready, created issue #29495 with `status:blocked`, and verified its native blocked-by relationship to core-contract issue #29494. |
| 2026-08-04T20:20:13Z | Milestone 1 feature 1.3 briefed | Validated `todo/tasks/t18196-brief.md` as schema-v2 worker-ready, created issue #29501 with `status:blocked`, and verified its native blocked-by relationship to core-contract issue #29494. |
| 2026-08-04T20:28:38Z | Milestone 1 feature 1.4 briefed | Validated `todo/tasks/t18197-brief.md` as schema-v2 worker-ready, created issue #29502 with `status:blocked`, and verified its native blocked-by relationship to core-contract issue #29494. |
| 2026-08-04T20:43:33Z | Milestone 1 feature 1.5 briefed | Validated `todo/tasks/t18198-brief.md` as schema-v2 worker-ready, created issue #29506 with `status:blocked`, and verified its native blocked-by relationship to core-contract issue #29494. All Milestone 1 feature leaves are now implementation-ready and correctly dependency-gated. |
| 2026-08-04T20:45:35Z | Private PI onboarding scope added | Added optional aidevops-managed Buzz provisioning, private app-scoped guidance, reusable checklists, structured improvement findings, owner-reviewed standardisation, and explicit privacy/authority boundaries to feature 5.6. No downstream task or issue was created before its milestone gate. |
| 2026-08-04T21:54:54Z | Issue-sync recovery follow-up filed | Validated `todo/tasks/t18199-brief.md` as schema-v2 worker-ready and created auto-dispatch issue #29517 to add authenticated capability fallback, dual REST/GraphQL repository identity, and retryable unresolved-relationship handling. |
| 2026-08-04T21:56:04Z | Milestone 1 implementation state refreshed | Core feature 1.1 merged in #29505 and app-team manifests 1.3 merged in #29510. Trust feature 1.2 is in recovery after closed #29511, reconciliation feature 1.4 has draft #29513, and compatibility feature 1.5 still needs its stale blocked state reconciled after #29494 closed. |
| 2026-08-04T22:12:31Z | Compatibility dependency released and reconciler follow-up filed | Verified #29494 and every declared/native blocker for #29506 are closed, confirmed there is no operational pause, moved feature 1.5 to `status:available`, and revalidated dispatchability. The canonical reconciler had misclassified descriptive table text as a pause; schema-v2 task t18200 / #29520 now captures the fail-closed context-aware fix. Trust recovery merged in #29518 and closed #29495. |
| 2026-08-05T00:46:13Z | Project-scoped Buzz channel amendment captured | Added planning-only feature 6.6 for one stable, agent-bound Buzz channel per eligible canonical `repos.json` project, with explicit OpenCode ACP `--cwd` execution roots, session isolation, worktree exclusion, stable external identity, and owner-reviewed reconciliation. The separate `~/.buzz` Tabby profile delivered in aidevops v3.32.223 remains a prerequisite and is not replaced. No task ID or leaf issue was created. |
| 2026-08-05T00:48:36Z | Milestone 1 validated and completed | Verified all five leaf issues closed through merged PRs #29505, #29518, #29510, #29528, and #29526. Core, trust, app-team, reconciliation, and compatibility schema/semantic fixture tests all passed from the merged contract stack, completing the Milestone 1 gate and activating the mission for staged Milestone 2 work. |
| 2026-08-05T01:11:33Z | Milestone 2 parent and first leaves allocated | Reserved t18201 as the permanent non-dispatchable Milestone 2 tracker, t18202 for the read-only runtime core, and t18203 for canonical roster generation. Resolved the first config and roster identity boundaries; F2.3-F2.5 remain deliberately unfiled until their direct dependencies merge. |
| 2026-08-05T01:33:56Z | Milestone 2 parent and first leaves published | Created permanent parent #29541 and worker-ready leaves #29542 and #29543, verified all three immutable repository-scoped mappings, both leaves' required labels and unassigned available state, and the native parent/sub-issue hierarchy. A REST quota failure interrupted #29543 post-create finalisation; the existing mapped issue was recovered without duplication through one bounded GraphQL mutation and independently re-read. F2.3-F2.5 remain deliberately unfiled until their direct dependencies merge. |
| 2026-08-05T02:01:53Z | Milestone 2 worker hand-offs recorded | Both ready leaves were claimed by vladimirdulov, then moved to `needs-maintainer-permissions` without an implementation PR. Their mission rows now preserve the permission-blocked hand-off rather than presenting the leaves as unclaimed; no implementation failure or completion is inferred. |
| 2026-08-05T22:10:07Z | Milestone 2 roster completed and runtime core resumed | Verified feature 2.2 merged through PR #29605 and marked it complete, independently unblocking feature 2.5. Maintainer-owned interactive work resumed feature 2.1 / t18202 / issue #29542 after the earlier worker released its permission-blocked claim without a PR or pushed recovery branch. |
| 2026-08-05T23:32:47Z | Milestone 2 runtime core completed | Implemented feature 2.1 through PR #29619: a disabled-by-default provider registry and config loader, guarded local state store, read-only providers/detect/status/doctor commands, and deterministic non-mutating reconciliation planner. Contract, security, state, CLI, and regression suites passed, unblocking the Buzz and Matrix adapter leaves. |
| 2026-08-06T03:41:51Z | Milestone 2 Buzz adapter implementation started | Validated schema-v2 task t18205, created and claimed child issue #29631 beneath parent #29541, and implemented the first static read-only `adapter.buzz` contract with closed provider-neutral inventory, synthetic private-field canaries, and focused schema/runtime/security tests. The feature remains in progress until checkpoint review, PR gates, and merge complete. |
| 2026-08-06T05:10:32Z | Milestone 2 Buzz adapter completed | Feature 2.3 merged through PR #29636 after exact-head review, required checks, read-only source-race hardening, secret-negative fixtures, and Qlty regression verification. The merge closed child #29631 without publishing or deploying a release. |
| 2026-08-06T14:12:51Z | Milestone 2 tracker recovery and final leaves briefed | Diagnosed parent #29541's premature Pulse closure: canonical issue snapshots omitted `body`, so the active single-pass reconciler saw three terminal graph children but not the unchecked parent acceptance criteria or unfiled F2.4/F2.5 plan. Reserved t18206 for fail-closed snapshot/live-body repair, t18207 for Matrix normalization, and t18208 for restricted OpenCode overlays. The parent close contract remains explicitly open until both leaves merge and integrated validation passes. |
| 2026-08-06T14:56:57Z | Milestone 2 tracker reopened and final leaves published | Created and claimed systemic repair #29645, Matrix child #29646, and OpenCode child #29647; linked both feature leaves beneath #29541. Synchronized the closed parent's authoritative keep-open body, verified the marker and all five implementation leaves, then reopened #29541. The local #29645 implementation passes all focused and broad gates and now awaits exact-head PR review. |
| 2026-08-07T00:21:18Z | Milestone 2 Matrix implementation checkpoint | Implemented the static read-only Matrix adapter, deterministic core-v1 ingress, durable provider-event receipts, actor/conversation session isolation, generated-bot integration, secret-negative fixtures, and operator references. Focused suites, runtime/core regressions, ShellCheck, changed-file lint, and both Qlty gates pass; exact-head PR review remains before feature completion. |

## Recovery Log

| Timestamp | Feature | Trigger | Preserved Evidence | Remaining Criteria | Next Safe Route | Status |
|-----------|---------|---------|--------------------|--------------------|-----------------|--------|
| 2026-08-04T20:43:33Z | 1.5 / t18198 | `gh auth status` and the REST repository-identity probe failed after #29506 was created even though live GraphQL identity/quota checks remained healthy, preventing automatic immutable-mapping and relationship finalisation | Existing issue title/body, TODO task identity/ref, exact repository/issue node IDs, and coordinator mapping were verified before any recovery write | Restore `status:blocked` and native blocked-by #29494 without creating a duplicate | Bind the verified immutable mapping, perform one exact native dependency mutation, then re-read labels, assignee, body schema, mapping, dispatchability, and blocked-by state | recovered |
| 2026-08-05T01:33:56Z | 2.2 / t18203 | The GitHub REST repository-identity quota was exhausted after #29543 was created while authenticated GraphQL reads and mutations remained healthy, so automatic post-create tier and hierarchy finalisation stopped at the immutable-mapping gate | Exact issue title/ref, unassigned open state, repository and issue node IDs, coordinator mapping, desired labels, parent task, and exact-title deduplication were verified before recovery | Add `tier:standard`, attach #29543 beneath #29541, and independently verify both children and all required labels without creating another issue | Use the verified immutable mapping and one bounded GraphQL mutation, then re-read the parent, both children, labels, bodies, and native hierarchy | recovered |
| 2026-08-06T06:16:57Z | 2 / t18201 | Pulse closed #29541 after its bodyless canonical snapshot exposed only three terminal native children; the live issue still contained unchecked acceptance criteria and two deliberately unfiled features | Mission rows, t18201 close contract, live issue body, native child graph, closure comment, and exact reconciler/cache paths were preserved | Merge systemic repair #29645, complete linked children #29646/#29647, run integrated validation, and remove the keep-open marker only in the final parent-close PR | Keep #29541 open under its synchronized close contract while each remaining leaf completes through an exact-head reviewed PR | recovered |

## Retrospective

_Completed after mission finishes._

- **Outcomes:** pending
- **Lessons learned:** pending
- **Framework improvements:** pending

### Budget Accuracy

| Category | Budgeted | Actual | Variance |
|----------|----------|--------|----------|
| Time | unestimated | | |
| Money | unestimated | | |
| Tokens | unestimated | | |

### Skill Learning

| Artifact | Type | Score | Promoted To | Notes |
|----------|------|-------|-------------|-------|
| | | | | |
