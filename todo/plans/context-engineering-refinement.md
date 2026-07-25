# Context Engineering and Model-Tier Refinement

## Goal

Refine aidevops context engineering so accumulated guidance remains complete
and trustworthy while each model receives only the relevant invariants,
interfaces, and triggered references. Standardise authored workload semantics
on provider-agnostic `simple`, `standard`, and `thinking` tiers, then validate
the refinement without broad behavioural regression.

## Maintainer Directions to Preserve

- Everything in aidevops came from a need. Preserve hard-won knowledge,
  including rare outliers, unless evidence proves it obsolete or fully
  superseded.
- Recover directive provenance before deleting, consolidating, or relocating
  guidance. Preserve the protected lesson at its reliable decision point or
  enforcement layer; default to no change when preservation is uncertain.
- This is a review and refinement exercise, not change for its own sake.
  Aidevops is mostly working well, so prefer small, evidenced corrections over
  broad rewrites.
- Consolidate what has been learned while building aidevops and the other
  repositories and processes that use it. Optimise for capability and verified
  outcomes, not the lowest instruction count.
- Keep these directions and the active implementation state durable through
  context compaction.
- Complete the authorised full loop through verified merge. Publication or
  release is not authorised by this task.

## Canonical Workload Semantics

- **`simple`**: follow complete, bounded instructions without unresolved
  design decisions.
- **`standard`**: build or fix using established patterns, normal judgment,
  and recovery.
- **`thinking`**: plan, design, refactor, or resolve consequential trade-offs.

Provider and model names belong in the runtime routing table, ordered by
maintainer preference for each workload tier. Broader model evaluation compares
like-for-like workloads with equivalent context, tools, and verification within
the same tier.

Concrete historical model names remain valid evidence in changelogs, incident
records, benchmark results, signatures, and compatibility fixtures. Migrate
only places where provider families are incorrectly used as abstract authored
tiers.

## Preservation Constraints

- Do not perform blanket prompt slimming.
- Keep safety and security invariants inline where they must be seen before
  relevance is known.
- Keep intentional reinforcement at distinct decision boundaries.
- Preserve exact `oldString`/`newString` contracts for fully resolved
  `tier:simple` work; these are execution interfaces, not illustrative
  examples.
- Do not mandate article-inspired rituals globally. Add blind-spot,
  assumptions, deviation, or reference-applicability fields only where their
  trigger and decision value are clear.
- Do not create another overlapping simplification agent. Clarify ownership
  among Agent Review, Code Simplifier, Agent Testing, and automated optimisers.

## Evidence Found During Review

1. Generated `/agent-review` command bodies repeat hard `<50/<100` targets even
   though the canonical review guide treats instruction counts as diagnostic
   heuristics and requires provenance recovery.
2. The comprehension benchmark was only partly migrated to canonical tiers:
   helper fallbacks and fixtures still use legacy provider-family names, state
   has no `tier_minimum`, and critical instruction surfaces lack scenarios.
3. Autoagent and Autoresearch can treat unchanged metrics as sufficient proof
   for instruction deletion even though their test coverage is incomplete and
   they do not load the newer directive-provenance gate.
4. `/define` mandates exactly two probes and implementation scaffolds for every
   code task, conflicting with thinking-tier problem-first guidance.
5. Older guidance still contains qualified conflicts around recursive task
   permissions, permission-to-apply fixes, provider-specific model labels, and
   the boundary between judgment and deterministic hooks.

## Implementation Phases

### Phase 1: Repair the measurement foundation

- Canonicalise comprehension helper and fixture tiers.
- Make all-tier failure and expected-tier mismatches truthful.
- Correct documentation that claims integrations not currently wired.
- Add deterministic regression coverage for canonical tiers and failure
  reporting.
- Add focused scenarios for Build Agent, Agent Review, and Define.

### Phase 2: Canonical semantic instruction review

- Make Agent Review the canonical context-review rubric.
- Require activation and exclusion boundaries where adjacent agents overlap.
- Classify retained context as invariant, judgment rule, interface, triggered
  pointer, rationale, or deterministic enforcement candidate.
- Scan the assembled context stack for conflicting or stale directives.
- Thin generated command wrappers so they cannot override the canonical guide.
- Route instruction-surface prose tightening through Agent Review and Agent
  Testing rather than allowing size-driven semantic deletion.

### Phase 3: Unknown discovery and briefing

- Make `/define` probes sufficiency-driven and ask only where an answer could
  change scope, architecture, trust boundaries, user-visible behaviour, or
  acceptance criteria.
- Keep simple work mechanically complete, standard work implementation-ready,
  and thinking work problem/constraint/prior-art/decision oriented.
- Add a compact post-draft blind-spot check for material omissions without
  creating another global checklist.
- Record plan deviations and verification coverage at review time when they
  exist; do not require a separate implementation-notes file for routine work.

### Phase 4: Align automated refinement and architecture

- Import Agent Review provenance requirements into Autoagent and Autoresearch.
- Replace unconditional "less is always better" language with semantic
  preservation and target-specific coverage requirements.
- Scope "intelligence over scripts" to judgment calls while retaining hooks and
  validators for deterministic mechanics.
- Align self-improvement permission language with already-authorised, safe,
  in-scope execution while retaining trust and risk gates.
- Remove provider-family names only where they are used as authored tiers.

### Phase 5: Verification and full-loop completion

- Run focused tests after each logical phase.
- Run ShellCheck on changed shell helpers and Markdown lint on changed docs.
- Run canonical tier, command-generation, Agent Review, progressive-load, and
  comprehension regression tests.
- Run `.agents/scripts/linters-local.sh --changed` before PR readiness.
- Review the complete diff for unexplained loss of rules, task/issue IDs,
  rationale, paths, examples that form interfaces, and executable contracts.
- Open the managed PR, resolve review feedback, merge through the full-loop
  gate, record `release:not-requested`, and complete guarded cleanup.

## Primary Files

- `.agents/tools/build-agent/{build-agent,agent-review,agent-testing}.md`
- `.agents/tools/code-review/code-simplifier.md`
- `.agents/scripts/commands/build-agent.md`
- `.agents/scripts/generate-{claude,opencode,runtime-config}-commands*.sh`
- `.agents/scripts/comprehension-benchmark-helper.sh`
- `.agents/scripts/comprehension-lib/`
- `.agents/tests/comprehension/`
- `.agents/workflows/define.md`
- `.agents/workflows/brief.md`
- `.agents/workflows/brief/tier-thinking.md`
- `.agents/workflows/brief/templates.md`
- `.agents/templates/brief-template.md`
- `.agents/aidevops/architecture.md`
- `.agents/reference/{progressive-disclosure,self-improvement,task-taxonomy}.md`
- `.agents/tools/autoagent/`
- `.agents/tools/autoresearch/`

## Acceptance Criteria

- [ ] Canonical authored tiers are `simple`, `standard`, and `thinking`;
      provider/model mappings remain centralised and preference-ordered while
      historical concrete model evidence is untouched.
- [ ] Comprehension fixtures and helper agree on canonical tiers, fail
      truthfully, and cover the reviewed instruction surfaces.
- [ ] `/agent-review` command wrappers cannot reintroduce hard count quotas or
      bypass provenance safeguards.
- [ ] Instruction-surface simplification requires provenance and
      target-specific verification; incomplete evidence defaults to no
      deletion.
- [ ] `/define` asks only decision-relevant questions and does not force
      speculative implementation scaffolds for thinking-tier work.
- [ ] Existing progressive-disclosure, model-routing, command-generation, and
      Agent Review tests pass; changed shell is ShellCheck-clean and changed
      Markdown is lint-clean.
- [ ] `.agents/scripts/linters-local.sh --changed` passes.
- [ ] The final diff contains no unexplained loss of rules, task IDs, rationale,
      paths, or executable contracts.
