<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Agent-team integrations source review

## Purpose

Preserve the evidence and architecture established before mission decomposition so future feature briefs do not have to repeat the complete Buzz/aidevops investigation. Mutable upstream behavior must still be revalidated before implementation.

## Baselines

- **aidevops mission worktree:** branch `feature/auto-20260804-180147` in a linked worktree created for the planning session.
- **Buzz source checkout:** read-only local checkout at commit `0afeac8a7c173fd3ede8a22e27919e63161bf07c` on `main`, cloned with blob filtering after the initial full clone timed out.
- **Cloudron Buzz package:** inspected only to establish that the package deploys the relay/forge application rather than aidevops/OpenCode workers. No package changes were made.
- **Repository changes before mission capture:** none. The source review was non-mutating.

## Confirmed aidevops integration seams

### Canonical agent discovery

Primary agents are discovered from root-level `.agents/*.md` files by `.agents/scripts/lib/agent_config.py:246-278`. The current discovery output contains 13 agents:

| Display name | Provider-facing default slug | Default workload tier |
|--------------|------------------------------|-----------------------|
| Build+ | `build-plus-aidevops` | standard |
| Automate | `automate-aidevops` | standard |
| Business | `business-aidevops` | standard |
| Content | `content-aidevops` | thinking |
| Health | `health-aidevops` | standard |
| Legal | `legal-aidevops` | standard |
| Marketing-Sales | `marketing-sales-aidevops` | standard |
| PR | `pr-aidevops` | thinking |
| Product | `product-aidevops` | standard |
| Reports | `reports-aidevops` | standard |
| Research | `research-aidevops` | standard |
| SEO | `seo-aidevops` | standard |
| Vault | `vault-aidevops` | thinking |

The framework specialist `.agents/aidevops.md` is deliberately skipped as a primary OpenCode agent and should be represented in collaboration interfaces as `aidevops-guide`, not added to the primary registry.

Canonical workload tiers and current model/reasoning mappings live in `.agents/configs/model-routing-table.json:7-19`. Provider adapters must store tiers or resolved runtime variants, not permanent concrete model IDs.

### Setup and runtime configuration

- Non-interactive setup deploys agents and updates runtime configuration through `setup.sh:1518-1568`.
- OpenCode agent configuration is generated from canonical discovery; `default_agent` is set by `.agents/scripts/agent-discovery.py:42-50`.
- Local testing during the source review confirmed that `OPENCODE_CONFIG_CONTENT` can select a canonical `default_agent` and apply an agent `variant` such as `high` without changing the persistent user configuration.
- The existing OpenCode title plugin sanitizes an incoming title, preserves its base, and appends `· AIDevOps <version>` at `.agents/plugins/opencode-aidevops/session-title-suffix.mjs:44-62`.
- Direct interactive OpenCode, headless workers, Pulse, and routines already have distinct lifecycle and authority paths. A collaboration provider should call those paths rather than reproduce them.

### Existing communications and forge patterns

- Matrix currently maps rooms to runners, resolves entities, persists session context, applies a privacy filter, and dispatches through OpenCode/runner helpers: `.agents/services/communications/matrix-bot.md:20-45,83-138`.
- Cross-machine forge job coordination uses GitHub as the shared source of truth and a seven-layer dedup chain: `.agents/reference/cross-runner-coordination.md:11-39,192-205`.
- `.agents/scripts/platform-helper.sh:4-27` detects GitHub, GitLab, Gitea, and local repositories but fully implements only GitHub operations; Forgejo needs explicit compatible detection/capabilities.
- `~/.config/aidevops/repos.json` already distinguishes registration, maintenance, Pulse, local-only operation, role, roots, and per-repository runner settings. Project/interface mappings should reference registered repository identity rather than move or duplicate checkouts.

## Confirmed Buzz behavior and gaps

### Managed-agent provisioning

- `CreateManagedAgentRequest` and `UpdateManagedAgentRequest` expose runtime, model, provider, environment, response policy, and startup fields but no provider-neutral external ID, manager ownership, last-applied hash, managed-field set, or revision/CAS contract: `desktop/src-tauri/src/managed_agents/types/requests.rs:132-256`.
- The external CLI implements `draft-create` and `draft-update`. Both publish an ephemeral request to Buzz Desktop and explicitly report that nothing changes until the owner reviews and saves it: `crates/buzz-cli/src/commands/agents.rs:12-85`.
- Consequence: current safe onboarding is owner-reviewed and stateful. Unattended reconciliation must not be simulated through repeated drafts or display-name matching.

### OpenCode ACP model, effort, and title behavior

- Buzz exposes a model through `BUZZ_ACP_MODEL` and a static session title through `BUZZ_ACP_SESSION_TITLE`: `crates/buzz-acp/src/config.rs:421-430`.
- The OpenCode preset launches `opencode acp` but preset metadata has no model, provider, or thinking environment fields and marks automatic installation false: `desktop/src-tauri/src/managed_agents/discovery/presets.rs:54-75,126-132`.
- Buzz sends the configured title out of band as `_meta.sessionTitle` on `session/new`: `crates/buzz-acp/src/acp.rs:620-667`.
- Buzz composes `Agent · #channel`, caps the configured title at 80 characters, and does not include the first initiating user: `crates/buzz-acp/src/config.rs:573-632`.
- New sessions resolve channel context once; live sessions are not retitled after later profile/channel renames. The correct initiator semantics are therefore the first verified actor whose accepted event creates that channel session.
- Target title: `Buzz · @initiator · <agent> · #channel · AIDevOps <version>`. Human-readable labels are display only; authority continues to use the verified pubkey.

### Permissions and inbound actor context

- Buzz ACP defaults to `bypassPermissions`: `crates/buzz-acp/src/config.rs:432-444`.
- Permission requests are automatically answered with the `allow_once` option when one exists: `crates/buzz-acp/src/acp.rs:1873-1956`.
- Setting the permission mode to `default` does not remove the per-tool auto-approval behavior. Therefore Buzz ACP cannot currently serve as the human approval boundary for a write-capable aidevops agent.
- Buzz prompt formatting includes event ID, channel, kind, sender display label, npub, hex pubkey, time, content, tags, and parsed thread fields: `crates/buzz-acp/src/queue.rs:1072-1147`.
- The inbound author gate supports owner-only, allowlist, anyone, and nobody, with additional DM hardening and same-owner sibling checks: `crates/buzz-acp/src/lib.rs:218-257`.
- Observer control events explicitly receive client-side signature, owner, and freshness checks at `crates/buzz-acp/src/lib.rs:834-869`. Canvas events also have an explicit verification path. The ordinary relay-event path needs a focused test to prove equivalent client-side verification; relay-side verification alone is not sufficient defense in depth for privileged execution.

### Teams and workflows

- Buzz teams have stable IDs, names, descriptions, instructions, and persona membership. Public fields synchronize as signed kind:30176 events while install-local fields remain local: `desktop/src-tauri/src/managed_agents/team_events.rs:1-84`.
- Teams are suitable for roster and shared instruction layering, not dynamic planning, task claims, worktrees, or multi-agent orchestration.
- Workflow triggers include message, reaction, diff, schedule, and webhook; actions include message, DM, topic, reaction, webhook, approval request, and delay: `crates/buzz-workflow/src/schema.rs:33-147`.
- `RequestApproval` currently suspends with a token while persistence and approval event emission remain TODO: `crates/buzz-workflow/src/executor.rs:650-668`.
- Consequence: use workflows for deterministic low-risk automation; do not treat current workflow approval as a completed consequential gate.

### Projects and communities

- Buzz uses standard Smart HTTP Git transport and NIP-34 repository metadata. Multi-repository projects use kind:30621 grouping without gaining authority over member repositories: `VISION_PROJECTS.md:11-73`.
- A project, repository, forge API, conversation/channel binding, and local execution root are separate concepts. Existing external repositories should bind without migration.
- Buzz community boundaries are selected by host. Identity may be portable while profiles, DMs, memberships, project state, memory, and history remain community-scoped.

### Project-scoped Buzz channels and OpenCode roots

- OpenCode 1.18.9 exposes `opencode acp --cwd <project-path>` as the supported working-directory argument. Buzz launch configuration should therefore pass ACP argv such as `["acp", "--cwd", "<canonical-project-path>"]`; no reviewed evidence establishes an environment variable as an equivalent cwd contract.
- OpenCode session listing, discovery, and resume visibility are directory/project scoped. Every project channel must start ACP at the canonical project root so one channel cannot discover or resume another project's sessions.
- `~/.config/aidevops/repos.json` is the existing project/repository registration source. The later feature brief must define canonical enabled-project eligibility instead of treating every checkout, path, or forge record as a channel.
- Linked worktrees are execution artifacts of their canonical project and must not materialize independent Buzz channels. Missing paths, disabled registrations, duplicate canonical paths, and stale mappings fail closed.
- Channel display names derive from provider-safe stable project slugs, but reconciliation binds through a stable external channel identity. Editable display names never authorize adoption, overwrite, or ownership transfer.
- Each channel resolves exactly one configured project/team agent. Missing or ambiguous agent mappings block plan/apply instead of falling back to a global agent.
- Current Buzz provisioning remains owner-reviewed until stable external IDs, managed-field ownership, revision/CAS, and supported apply semantics are available. Plans must separate managed fields from user-owned/customized channel fields and preserve three-way reconciliation.
- aidevops v3.32.223 separately delivers the `~/.buzz` Tabby profile for Buzz-scoped work. Project-channel materialization depends on and complements that profile; it must not replace, merge, or silently rewrite it.
- Plans, logs, issues, and public diagnostics use privacy-safe project references. Private repository names and canonical local paths remain local and redacted from public artifacts.
- Isolation keys include project, community, configured agent, execution root, and runner node so session discovery and resume cannot cross those boundaries.

#### Required later implementation-brief contract

1. Define eligibility rules for canonical, enabled `repos.json` projects.
2. Define provider-safe stable slug normalization and collision handling.
3. Bind stable external channel identity independently of editable display names.
4. Resolve the configured project/team agent explicitly; missing or ambiguous mappings fail closed.
5. Launch OpenCode ACP with argv containing `--cwd <canonical-project-path>`.
6. Exclude linked worktrees, missing paths, disabled projects, and duplicate registrations.
7. Declare managed versus user-owned channel fields and three-way reconciliation behavior.
8. Keep draft/apply owner-reviewed until Buzz supports safe unattended provisioning.
9. Keep plans and logs privacy-safe so private repository names and local paths do not enter public artifacts.
10. Isolate sessions across projects, communities, agents, execution roots, and runner nodes.

#### Future acceptance criteria

- Exactly one intended channel is planned per eligible canonical project, and repeated reconciliation creates no duplicates.
- Slug collisions are reported and block apply; renamed projects retain stable identity rather than being adopted by display name.
- User-created or customized channels are preserved, and each managed channel attaches only its configured project agent.
- ACP starts at the project's canonical root through `--cwd`, and session listing from that root exposes only the appropriate project namespace.
- Missing paths, missing agents, stale mappings, duplicate paths, linked worktrees, and unsupported Buzz capabilities fail closed.
- Tests cover renamed projects, duplicate paths, linked worktrees, slug collisions, user-owned drift, and unavailable roots.

## Target provider-neutral architecture

```text
Buzz / Matrix / future collaboration UI / aidevops.app
                         |
                  provider adapter
                         |
           normalized event + provenance
                         |
              team-interface broker
             /          |           \
     conversation   delegated job   outbox/status
      OpenCode ACP   headless flow   provider API
                         |
               Pulse / routines / forge
```

### Core responsibilities

- Provider discovery and capability negotiation
- Community/account/identity inventory
- Desired-state generation and plan/apply separation
- Managed versus user-owned fields and three-way reconciliation
- Normalized inbox/outbox events and immutable correlation
- Actor/role/capability authorization
- Adaptive ingress screening and content-addressed verdict cache
- Agent-team templates and app-specific instances
- Resource mappings for channels, forums, projects, repositories, roots, and runners
- Idempotency ledger, loop prevention, acknowledgements, and receipts
- Runner-node leases and fencing
- Compatibility baselines, drift classification, and monitoring
- Secret-reference validation and redacted audit records

### Normalized event minimum

```text
schema_version
provider
provider_version
community_id
conversation_id
thread_id
event_id
parent_event_id
actor.subject_id
actor.display_name
actor.type
actor.verified_roles
signature_verified
target_agent_id
app_team_id
content
attachment metadata/digests
requested_operation
authority_scope
trust_profile
scan_verdict_ref
correlation_id
idempotency_key
occurred_at
```

The model may reason about this envelope, but cannot mint or widen it. Tool wrappers and the broker enforce it.

## Adaptive trust and scanning recommendation

The local owner's ability to perform the same operation directly in OpenCode is relevant to overhead, but not sufficient to trust all content they forward. Separate actor trust, content provenance, attachment risk, and requested capability.

### Always-on low-cost controls

- Provider signature/provenance verification
- Membership/role resolution
- Event and operation idempotency
- Schema and maximum-size validation
- MIME/type and path-boundary validation
- Control-character and unsafe archive/path checks
- Credential-safe logs and outbound secret scanning
- Deterministic capability/authority check

### Conditional controls

- Deterministic prompt-injection pattern scan for shared members and all external/bridged content
- Semantic/LLM scan only when deterministic findings, unusual encoding, external attachments, or elevated requested actions warrant it
- Sandboxed extraction only for attachments actually needed by the task
- Human review/quarantine for active documents, executables, archives, macros, or capability-escalating payloads

### Cache and overhead contract

Cache a verdict by:

```text
content_digest
attachment_digests
provider/provenance class
trust profile
scanner engine/version
policy version
requested capability class
```

Do not rerun the same scan for every specialist. Invalidate when any key input changes. Measure p50/p95 latency, CPU, tokens, cache hit rate, attachment extraction time, and false-positive/negative fixtures before choosing defaults.

## aidevops.app Integrations section

Place a provider-neutral **Integrations** section under **Infrastructure**. Provider cards and detail pages are generated from capabilities rather than hard-coded Buzz/Matrix assumptions.

### Provider overview

- Detected / not installed / unsupported
- Connected accounts and communities
- Runtime/provider versions and compatibility state
- Authentication/identity readiness without exposing secrets
- Enabled agent teams and active runners
- Channel/forum/project mappings
- Health, drift, pending owner review, and last successful reconciliation

### Setup flow

1. Detect provider and dependencies.
2. Show install guidance; never silently install.
3. Connect account/community using secret references.
4. Select workspace/project roots.
5. Select or compose an agent-team template.
6. Map channels, forums, projects, and connector accounts.
7. Select trust profiles and role capabilities.
8. Review desired-versus-actual plan and managed/user-owned fields.
9. Apply through supported provider API or submit owner-reviewed drafts.
10. Verify live status and record compatibility baseline.

### Management flow

- Enable/disable without deleting provider state
- Review and resolve drift
- Edit user-owned fields
- Accept/reject framework-owned updates
- Rotate/revoke identities
- Start/stop or relocate runner bodies
- Inspect leases, correlations, failures, and audit events
- Re-run doctor/compatibility checks
- Roll back one provider/community independently

## App-specific agent teams

The initial aidevops team is only one manifest. Other applications may use:

- a product-specific Build+/Product/Research team;
- a customer-support team with shared Legal/Content specialists;
- a dedicated release/operations team;
- private local personas;
- a shared stateless research or SEO capability.

Isolation defaults:

| Concern | Dedicated/cloned agent | Shared capability |
|---------|------------------------|-------------------|
| Signing identity | Unique per app/community | Caller/team identity publishes result |
| Conversation memory | App/team namespace | None or request-scoped only |
| Workspace roots | Explicit app roots | Supplied scoped roots per request |
| Credentials | App/team references | Capability-specific brokered references |
| Audit | Agent identity + actor | Capability + caller identity + actor |
| Reputation/profile | App-specific | Not represented as a persistent teammate |

## Execution ownership

| Input/mode | Owner | Integration behavior |
|------------|-------|----------------------|
| Buzz/Matrix conversation | Provider ACP/chat adapter | Answer/read/draft under conversational policy |
| Direct interactive OpenCode | Existing interactive session | Preserve normal aidevops lifecycle |
| Explicit implementation request | Authority broker + headless runtime helper | Create one scoped delegated job with worktree/forge lifecycle |
| Pulse | Existing Pulse | Provider receives status only; no duplicate schedule |
| Routine | Existing routine scheduler | Provider may trigger an explicit routine command or receive reports |
| Remote runner | Runner service | Advertise capability, acquire lease, execute scoped job |
| Local model/persona | Local runtime | Restricted policy and private scope by default |

## Reconciliation contract

For each managed field:

1. Compare desired value, last applied value, and actual value.
2. If actual equals last applied, update to desired.
3. If actual differs, preserve it as user-modified and report drift.
4. If a mandatory security field differs, disable execution or require review rather than silently preserve or overwrite.
5. Use revision/CAS on apply and retry only after re-reading actual state.
6. Never delete automatically; retire/archive through explicit reviewed policy.
7. Never identify/adopt a record from its editable name alone.

Current Buzz lacks the metadata/API required for unattended application. Owner-reviewed drafts are the safe compatibility mode.

## Multi-machine identity and coordination

Maintain separate IDs for logical agent, provider identity, app team, community, and runner node.

- Recommended default: one provider signing identity per logical agent/community.
- Do not copy signing secrets to multiple active machines.
- Active-passive replicas may take over only after lease expiry/revocation and a higher fencing token.
- Multi-active implementations use separate visible provider identities or a strong coordinator that rejects stale fencing tokens on every side effect.
- Existing forge task dedup remains authoritative for issue/PR jobs; conversational leases solve a different duplicate-publication problem.
- Machines advertise roots, runtimes, local models, network access, secret eligibility, and trust level. Dispatch chooses only a matching eligible node.

## Channels, forums, and connectors

- Create resources only for configured accounts/mappings.
- Use channels for synchronous conversation and operational status.
- Use forums for durable asynchronous discussions, issues, and bridged external sources.
- Use Projects for repository/group context, not as a replacement for the forge adapter.
- Default email/social/external connector output to draft-only.
- Preserve source account, external message ID, thread mapping, cursor, content digest, and provenance.
- Prevent bridge loops by recording inbound/outbound receipt IDs and refusing events carrying the integration's own correlation marker.

Suggested opt-in aidevops resources:

- `#aidevops` for questions and handoffs
- restricted `#aidevops-ops` for health/runners
- optional `#aidevops-updates` for deduplicated verified releases

## Source compatibility monitoring

Extend the existing upstream-watch pattern rather than build a second scheduler.

### Stored compatibility metadata

- Provider and adapter version
- Supported version/tag range
- Last known-good tag and commit
- Last checked tag/commit/time
- Watched source paths/symbols
- Fixture version and result
- Known limitations and required feature flags
- Open drift task/issue references

### Buzz watched surfaces

- Managed-agent create/update records and API commands
- ACP model, effort, title, event, permission, and session lifecycle
- Team record/event and reconciliation semantics
- Workflow triggers/actions/approval executor
- Project/repository/NIP contracts
- Remote-agent and relay-mesh execution contracts
- Release/install packaging interfaces used by detection

### Routine flow

1. Detect a new upstream release/tag or relevant baseline commit.
2. Fetch metadata and only the bounded watched diff needed for classification.
3. Run prompt-injection scanning on untrusted release/issue text before use.
4. Classify: no impact, documentation, compatible adapter change, feature opportunity, breaking contract, or security/permission impact.
5. Run contract fixtures when source/API semantics changed.
6. Deduplicate against existing missions, tasks, issues, PRs, and merged fixes.
7. Create a worker-ready leaf issue only when the premise is verified and paths/tests are known; otherwise record a decision-ready mission note.
8. Update compatibility state after terminal verification, never while CI is merely pending.

## Update announcements

Emit only after setup/update completion and active version verification. Idempotency key:

```text
sha256(provider | community_id | "aidevops-release" | version)
```

Use one announcer lease across machines. A failed or rolled-back update never emits success. Availability notices are optional and separate from installed-version announcements.

## Finalized first implementation surfaces

Milestone 1 contract evidence and current runtime discovery resolved the first
two Milestone 2 leaves on 2026-08-05:

- F2.1 uses `.agents/scripts/team-interface-helper.sh` as a thin shell entry,
  `.agents/scripts/team-interface-core.mjs` for Ajv-backed config/state/planning,
  `.agents/scripts/team-interface-adapters.mjs` as the trusted static adapter
  registry, `.agents/schemas/team-interface/runtime-v1.schema.json`,
  `configs/team-interface-config.json.txt`,
  `.agents/reference/team-interface-runtime.md`, and focused runtime fixtures.
- F2.1 does not edit `config.jsonc` or
  `.agents/configs/aidevops-config.schema.json`. The dedicated working config is
  `~/.config/aidevops/team-interface.json`; a later global config change may add
  only enablement and path/document references.
- F2.2 refactors `.agents/scripts/lib/agent_config.py` to expose the canonical
  source iterator, then adds `.agents/scripts/team-interface-agent-roster.py`,
  `.agents/schemas/team-interface/agent-roster-v1.schema.json`, roster reference
  documentation, and live/sandbox tests. It derives IDs and workload tiers from
  source metadata and includes `.agents/aidevops.md` separately as
  `agent.aidevops-guide`.
- F2.3 and F2.4 receive adapter file decisions only after the F2.1 registry
  interface merges. F2.5 receives OpenCode overlay file decisions only after
  the F2.2 roster interface merges.
- aidevops.app Integration UI/API files remain unknown until that repository is
  inspected for its current backend, navigation, and deployment boundaries.

## Feature 2.3 refreshed Buzz evidence

The Buzz adapter evidence was refreshed on 2026-08-06 against upstream commit
`e2796d4a8907586b457a65675c2c88c818973173` and installed Buzz Desktop `0.5.5`.
The merged F2.1 runtime remains unchanged at aidevops commit `6a894fa5f`.

- Buzz Desktop identifies the macOS application as `xyz.block.buzz.app`; its
  managed-agent and team stores are `agents/managed-agents.json` and
  `agents/teams.json` below the application-data directory.
- `ManagedAgentRecord` contains safe identity and relationship fields alongside
  private keys, auth tags, environment values, prompts, command paths, errors,
  logs, and local directories. The adapter must parse then project an explicit
  allowlist rather than serialize provider records.
- `TeamRecord` supplies stable ID, name, persona membership, and built-in state,
  but also local source directories and instructions. Inventory exposes only
  stable identity, display label, built-in state, and normalized member refs.
- Communities are stored under the WebKit local-storage key
  `buzz-communities`. The value may contain invite tokens, identity metadata,
  and repository roots; inventory exposes only local community identity, label,
  and the relationship needed to bind managed agents.
- Buzz's internal runtime catalog and Tauri commands are not a supported
  external read API. F2.3 therefore observes only runtime IDs referenced by
  managed-agent records and checks stored PIDs without launching Buzz, ACP,
  package managers, auth probes, or installation commands.
- The first verified installation reader is macOS-only. It reads
  `Info.plist`, bounded application-data JSON, and WebKit SQLite in read-only
  mode. Other platforms report unavailable until their package/data paths are
  verified from current source or packaging evidence.
- The runtime observation schema needs one optional closed provider-neutral
  inventory extension for communities, agents, teams, and runtimes. Existing
  observations without inventory remain valid; semantic validation rejects
  duplicate IDs, dangling refs, and non-canonical ordering.
- Compatibility is known only for Buzz Desktop `0.5.5` at this baseline.
  Unknown versions remain detectable but report unknown compatibility rather
  than inheriting current-version assurances.

The adapter remains a trusted static registry entry. It consumes an opaque
`settings:` reference without resolving credentials and emits no write method,
provider client, raw diagnostic payload, private path, or secret-bearing field.

Initial non-mutating commands:

```text
team-interface-helper.sh providers
team-interface-helper.sh detect --provider buzz
team-interface-helper.sh status --provider buzz
team-interface-helper.sh plan --request plan-request.json
team-interface-helper.sh doctor --provider buzz
```

## Features 2.4 and 2.5 refreshed evidence

See [Milestone 2 final-leaf source review](milestone-2-final-leaves.md) for the
implementation-ready Matrix and restricted OpenCode evidence.

## Required verification families

- Canonical agent additions/removals propagate without list edits.
- Names/slugs normalize deterministically and stable IDs survive user renames.
- User-owned fields survive setup/update and adapter version changes.
- Security-critical drift blocks execution instead of widening authority.
- Trusted owner text takes the low-overhead path; forwarded external attachments receive the appropriate stronger path.
- Shared non-admin members cannot reach admin, secret, destructive, release, or publication operations unless specifically granted.
- Scan cache hits avoid repeated model/CPU work and invalidate on policy/provenance/capability changes.
- Invalid signatures, spoofed actor labels, malformed envelopes, oversized events, unsafe archives, and bridge loops are rejected.
- Conversation profiles cannot mutate even when model output requests tools.
- One authorized conversation event creates at most one delegated job.
- Existing Pulse/routine/interactive claims prevent duplicate dispatch.
- Stale runner leases and fencing tokens cannot publish.
- Provider/community update announcement is emitted once after verified success.
- No secret values enter durable adapter state, logs, UI payloads, prompts,
  issue bodies, or review snapshots. A mode-0600 descriptor-backed SQLite copy
  may exist only in a private temporary directory during its read-only query
  and is removed on every normal exit path.
- Rollback/disable affects one provider/community without breaking direct aidevops use.

## Current recommendation

Begin with Milestone 1 contracts and adaptive trust policy, then implement a read-only provider core. In parallel only where repository boundaries permit, brief the aidevops.app information architecture after inspecting that application's current backend and navigation. Do not start live Buzz provisioning or write-capable ACP execution before the provider ownership/CAS and permission gates are resolved.
