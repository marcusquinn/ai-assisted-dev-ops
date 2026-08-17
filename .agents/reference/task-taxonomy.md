---
description: Canonical routing taxonomy — domain labels and workload tier labels for task creation and dispatch
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Taxonomy: Domain and Workload Tier Classification

Canonical source for `/new-task`, `/save-todo`, `/define`, and `/pulse`. When a domain or tier changes, update **only this file** — command docs point here, not duplicate the tables.

## Domain Routing Table

Apply a domain tag only when the task clearly belongs to a specialist agent. Code work stays unlabeled and routes to Build+.

| Domain Signal | TODO Tag | GitHub Label | Agent |
|--------------|----------|--------------|-------|
| SEO audit, keywords, GSC, schema markup, rankings | `#seo` | `seo` | SEO |
| Blog posts, articles, newsletters, video scripts, social copy | `#content` | `content` | Content |
| Email campaigns, FluentCRM, landing pages | `#marketing` | `marketing` | Marketing |
| Invoicing, receipts, financial ops, bookkeeping | `#accounts` | `accounts` | Accounts |
| Compliance, terms of service, privacy policy, GDPR | `#legal` | `legal` | Legal |
| Tech research, competitive analysis, market research, spikes | `#research` | `research` | Research |
| CRM pipeline, proposals, outreach | `#sales` | `sales` | Sales |
| Social media scheduling, posting, engagement | `#social-media` | `social-media` | Social-Media |
| Video generation, editing, animation, prompts | `#video` | `video` | Video |
| Health and wellness content, nutrition | `#health` | `health` | Health |
| Code: features, bug fixes, refactors, CI, tests | *(none)* | *(none)* | Build+ (default) |

**Rule:** Omit the domain tag for code tasks. Build+ is the default.

## Workload Tier Table

Tiers describe the work and route it through centrally configured model chains.
The pulse resolves labels via `model-availability-helper.sh resolve <tier>`; runtime
configuration owns concrete provider/model selection. Label every task with the
lowest tier that has a credible one-pass path to a safe, complete result.

| Tier | TODO Tag | GitHub Label | Workload contract |
|------|----------|--------------|-------------------|
| simple | `tier:simple` | `tier:simple` | Decision-complete, low-consequence execution contract with exact actions and focused verification |
| standard | `tier:standard` | `tier:standard` | Implementation-ready work using established patterns with normal local judgment and recovery |
| thinking | `tier:thinking` | `tier:thinking` | Consequential unresolved decisions, novel design, or synthesis-heavy problem solving |

## Canonical Assignment Policy

Tier assignment is a judgment over the complete work contract. File count, line
count, elapsed-time estimates, acceptance-criteria count, and isolated keywords
are evidence, never standalone tier gates. A one-file architecture decision can
require `tier:thinking`; several independent verbatim replacements can remain
`tier:simple`.

Apply this order:

1. **Keep authority and safety gates separate.** Missing permission, secrets,
   policy approval, billing authority, or destructive-operation confirmation is
   a blocker, not a reason to select a more capable tier.
2. **Select `tier:thinking` when a consequential decision is unresolved.** This
   includes architecture, product behaviour, trust/security/privacy boundaries,
   irreversible migration or rollback strategy, novel cross-system failure modes,
   or a problem whose evidence must be synthesized before the write surface is
   knowable. The dispatch-path risk override below is also `tier:thinking`.
3. **Select `tier:simple` only when every simple contract condition is proven.**
   The exact action or complete content is supplied; targets and the existing
   pattern are verified; no semantic, design, sequencing, error-recovery, or
   compatibility choice remains; impact is bounded, reversible, and low
   consequence; and focused verification plus rollback are known.
4. **Otherwise select `tier:standard`.** This is the default for ordinary code,
   debugging, refactoring, review, documentation, and bounded security-sensitive
   implementation. Standard workers may adapt an established pattern, coordinate
   a known write surface, and recover from known errors within decided boundaries.

When uncertainty is only about whether work is mechanical, choose `tier:standard`.
When uncertainty is itself a consequential decision listed in step 2, choose
`tier:thinking`.

### Decision Evidence

| Axis | `tier:simple` evidence | `tier:standard` evidence | `tier:thinking` trigger |
|------|------------------------|--------------------------|-------------------------|
| Specification | Verbatim replacement, complete new content, or exact deterministic transform | Goal and boundaries resolved; implementation details remain | The solution boundary or write surface depends on a decision |
| Novelty | Exact known pattern, no adaptation | Established pattern adapted locally | No adequate pattern; alternatives and trade-offs must be evaluated |
| Consequence | Reversible, low-impact, no trust-boundary change | Bounded production/security change with known rollback | Consequential or irreversible choice is unresolved |
| Coordination | Independent actions with no shared-state sequencing | Known multi-file/component coordination | Cross-system ownership, ordering, or failure semantics must be designed |
| Context | Targets and decisive context are supplied | Normal repository discovery and focused references | Synthesis dominates the task or decisive context cannot fit a normal worker pass |
| Verification | Focused command and rollback are explicit | Tests and recovery follow known patterns | The verification strategy or safety proof must be designed |

### Security and Trust Boundaries

Classify the decision, not the presence of a security keyword:

| Work shape | Tier |
|------------|------|
| Exact documentation, fixture, or identifier update that does not change effective access, trust, secret handling, privacy, egress, or destructive behaviour | `tier:simple` when every simple condition holds |
| Implement a decided validation, authentication, authorization, secret-handling, or policy pattern inside an existing boundary | `tier:standard` |
| Decide or redesign authentication, authorization, cryptography, sandboxing, privacy, egress, secret flow, destructive-operation, or other trust boundaries | `tier:thinking` |
| Attempt to overcome a permission, authentication, policy, provider, or secret gate | Stop; no tier may bypass the gate |

### Context and Decomposition

Context burden matters because loading evidence can consume the worker pass before
implementation starts. Inline decisive data, add a Worker Quick-Start, or split
independent work. Use `tier:thinking` when synthesis is itself the task; do not
promote work merely because a file or checklist is long. Decomposition planning
that must discover boundaries is thinking work; already-decided mechanical phases
normally use `tier:standard`, or `tier:simple` only with complete execution contracts.

### Creation and Generator Contract

At issue creation:

- General-purpose and uncertain generators default to `tier:standard`.
- A generator may emit `tier:simple` only when it emits the complete prescriptive
  contract from `workflows/brief/tier-simple.md` and can prove every simple condition.
- A generator may emit `tier:thinking` when its task shape inherently contains a
  thinking trigger (for example, decomposition planning or broad failure analysis).
- Shape-specific hardcoded `tier:standard` or `tier:thinking` labels remain valid
  when the generator's contract proves that shape; do not infer tiers from a noun.
- Keep exactly one `tier:*` label. Explicit policy upgrades replace lower labels.

See `~/.aidevops/agents/templates/brief-template.md` "Tier checklist" for the structured version used during task creation.

### Deterministic Enforcement

Judgment remains at task creation. Automation enforces only mechanically provable
parts of this policy:

- `issue-sync-lib-ref.sh::_validate_tier_checklist` changes a selected
  `tier:simple` to `tier:standard` when the simple checklist is incomplete or the
  brief lacks an exact execution contract.
- `tier-simple-body-shape-helper.sh` repeats those explicit checks against the
  issue body before dispatch. It does not infer complexity from counts, estimates,
  or keywords.
- `pre-dispatch-validator-helper.sh` applies the evidence-backed self-hosting
  override: work touching the configured worker dispatch/spawn path starts at
  `tier:thinking`, lower tier labels are removed, and dispatch metadata is refreshed.
- Issue-sync's rank ratchet and worker failure escalation never lower a tier that
  has already been raised by evidence.

Both policy checks are non-blocking: dispatch proceeds at the normalized tier.
Emergency bypasses remain `AIDEVOPS_SKIP_TIER_VALIDATOR=1` and
`AIDEVOPS_SKIP_SELF_HOSTING_DETECTOR=1`.

## Cascade Dispatch Model

Initial classification should maximize one-pass completion, but unexpected
failures still escalate with accumulated knowledge:

```text
tier:simple (decision-complete bounded execution)
  ✓ Success → done
  ✗ Failure → structured escalation report on issue → re-dispatch at tier:standard

tier:standard (general implementation and recovery)
  ✓ Success → done (saved exploration tokens via escalation context)
  ✗ Failure → richer escalation report → re-dispatch at tier:thinking

tier:thinking (deep reasoning and consequential decisions)
  ✓ Success → done (had full diagnostic context from both prior attempts)
  ✗ Persistent capability blocker → human review with complete attempt history
```

Each escalation report captures: what was attempted, where it got stuck, what was unclear in the brief, and what was discovered. The next tier starts with this context instead of exploring from zero. See `templates/escalation-report-template.md` for the structured format.

### Escalation Reason Taxonomy

Structured reasons feed back into brief template optimisation:

| Reason | Meaning | Brief improvement |
|--------|---------|-------------------|
| `AMBIGUOUS_BRIEF` | Multiple valid interpretations | More specific code blocks |
| `STALE_REFERENCES` | File paths/lines don't match current state | Verify file state at dispatch time |
| `JUDGMENT_NEEDED` | Multiple valid approaches, can't choose | Specify pattern to follow |
| `MULTI_FILE_COORDINATION` | Non-obvious cross-file dependencies | Add dependency map to brief |
| `ERROR_RECOVERY` | Hit unexpected error, can't self-recover | Add fallback instructions |
| `TOOL_CHAIN_COMPLEXITY` | Too many sequential tool calls | Pre-compute intermediate state |
| `MISSING_CONTEXT` | Brief lacks background for the decision | Add "Context & Decisions" section |
| `CONTEXT_BUDGET_EXCEEDED` | Too much reference material to read before implementing | Inline critical data in brief, add Worker Quick-Start section, consider tier:thinking |

## Command Use

- `/new-task` — classify after brief creation; apply labels via `gh issue edit`
- `/save-todo` — classify during dispatch tag evaluation
- `/define` — classify during task type detection
- `/pulse` — consume labels for agent routing, workload tier selection, and cascade dispatch

See `scripts/commands/pulse.md` "Agent routing from labels" and "Model tier selection" for dispatch behaviour.
