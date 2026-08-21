<!-- aidevops:brief-schema=v2 -->

# t18299: Score readable exact-match .com domain candidates

## Pre-flight

- [x] Memory recall: `exact match domain scoring word segmentation` → 0 hits — no relevant stored lessons.
- [x] Discovery pass: repository search found no word-segmentation dependency or licensed frequency list; 0 merged/open PRs match this scorer.
- [x] File refs verified: 5 references and all new-file parent directories checked at HEAD.
- [x] Tier: `tier:thinking` — the worker must resolve a licensing-safe, reproducible phrase-evidence strategy before implementing lexical scoring.
- [x] Seeded draft PR decision recorded: skipped — no unverified segmentation algorithm or word list should anchor the implementation.

## Origin

- **Created:** 2026-08-21
- **Session:** `opencode:interactive-2026-08-21`
- **Created by:** `ai-interactive`
- **Parent task:** `t18295` / #30492
- **Blocked by:** `t18296` / #30493; dispatch remains blocked until the native `blockedBy` relationship is verified.
- **Conversation context:** Reduce hundreds of thousands of auction rows to readable exact-match `.com` candidates using explainable evidence, while keeping model-generated business ideas out of the quantitative score.

## What

Implement a deterministic candidate and scoring module over normalized listings. It must canonicalize domains, reject or flag obvious low-quality/risk patterns, derive one or more evidence-backed phrase readings, calculate named score components, persist score-run provenance, and export the explanation for every score.

Before coding lexical segmentation, select and document a reproducible, redistribution-safe phrase source: provider keyword query when exact, operator-supplied local lexicon, or a clearly licensed compact frequency resource. Do not silently depend on a host dictionary or model output.

## Why

The product value lies in curation. An opaque model score would be hard to audit and could conflate readability, demand, valuation, and legal risk. Deterministic components let later Google Ads/Trends observations improve ranking without rewriting why a candidate was selected.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The trust boundary is fixed, but the repository has no verified lexical resource. Licensing, portability, and false-positive trade-offs must be resolved with evidence before implementation.

## PR Conventions

This leaf PR closes #30496 and may reference the parent with `For #30492`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** A premature algorithm would anchor workers to an unlicensed or non-portable word source.
- **Status:** `not-created`
- **Freshness evidence:** Repository/dependency searches on 2026-08-21 found no existing segmentation implementation.
- **Verification run:** Discovery only; scoring behavior unverified.
- **Stale-assumption warning:** Re-check merged foundation fields and dependency manifests before choosing a lexical resource.

## How (Approach)

### Progressive Context Plan

- **Read first:** merged `.agents/scripts/domain_opportunity_contract.py` and `domain_opportunity_store.py` — listing fields and score persistence.
- **Read next:** `.agents/seo/keyword-research.md:95-116` — existing opportunity score vocabulary; do not reuse SERP-specific weights blindly.
- **Load only if:** licence files and provenance for a compact data asset — before adding any redistributable lexical data; v1 adds no runtime dependency.
- **Why:** Separate evidence collection, lexical readability, and commercial ranking while preserving redistribution rights.
- **Stop when:** Phrase-source licensing, score components, defaults, and false-positive behavior are documented and fixtureable.

### Worker Quick-Start

```text
Hard defaults: .com only; ASCII lower-case; no hyphens; no digits; configurable length/word-count bounds.
Exact-match proof: concatenate normalized phrase tokens and require equality with the SLD.
Never infer search demand from readability; Google Ads child owns demand metrics.
Never let an LLM-generated phrase/category alter the deterministic score.
Trademark matching is a risk flag for review, not legal clearance or an automatic accusation.
```

### Files to Modify

- `NEW: .agents/scripts/domain-opportunity-score.py` — CLI for score, explain, and candidate export.
- `NEW: .agents/scripts/domain_opportunity_scoring.py` — phrase evidence, hard filters, component scoring, configuration, and store writes.
- `NEW: .agents/scripts/tests/fixtures/domain-opportunity/scoring-candidates.jsonl` — synthetic positive, ambiguous, malformed, digit/hyphen, and risk-flag examples.
- `NEW: .agents/scripts/tests/test-domain-opportunity-scoring.py` — deterministic score, explanation, rerun, and negative-boundary coverage.
- `NEW or EDIT only after licence verification: .agents/data/domain-opportunity-words.*` — optional redistributable lexical resource; omit when provider/operator evidence is sufficient.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/domain-opportunity-score.py` reads current listings through `.agents/scripts/domain_opportunity_store.py`; final integration reads persisted score components.
- **Writers/mutation paths:** `.agents/scripts/domain_opportunity_scoring.py` writes score runs/components only through `.agents/scripts/domain_opportunity_store.py`; it does not mutate auction observations or keyword metrics.
- **Tests/fixtures:** `.agents/scripts/tests/test-domain-opportunity-scoring.py` reads `.agents/scripts/tests/fixtures/domain-opportunity/scoring-candidates.jsonl`; optional lexical data requires licence/provenance assertions.
- **Schemas/config:** `.agents/schemas/domain-opportunity-record.schema.json` plus versioned policy constants in `.agents/scripts/domain_opportunity_scoring.py` define v1 behavior without a new shared configuration file.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` deploys scripts and any verified redistributable data; runtime score rows/exports remain local.
- **Migrations/backfills:** Use the foundation score tables without editing `.agents/scripts/domain_opportunity_store.py`; a missing phrase-evidence or score writer is an exact foundation blocker, not an in-leaf migration.
- **Cleanup/rollback paths:** Removing `.agents/scripts/domain-opportunity-score.py` leaves source evidence intact; rerunning an older policy selects its own policy version rather than deleting newer scores.

### Implementation Steps

1. Inspect foundation fields and available provider phrase evidence (`keyword_search_query` or equivalent). Inventory compact licensed-data options only if exact readings remain unavailable.
2. Record the phrase-source decision in code/docs with licence and portability evidence. Prefer provider/operator evidence; do not add a large data dependency merely to maximize coverage.
3. Implement canonical domain validation and configurable hard filters: `.com`, ASCII/punycode policy, length, hyphens, digits, repeated characters, word count, and disallowed/adult terms.
4. Generate phrase candidates with source/confidence. A reading is exact only if normalized token concatenation equals the SLD. Preserve ambiguous alternatives rather than choosing silently.
5. Compute named bounded components rather than one opaque formula: structural/readability, phrase confidence, commercial-intent taxonomy evidence, source freshness, current price fit, provider appraisal/comparable observations, demand metrics, backlink/history signals, and risk/missing-evidence penalties. Components absent from the DB contribute `unknown`, not zero, unless the policy explicitly says otherwise.
6. Version the scoring policy and persist inputs, components, total, eligibility, flags, and calculated time. Re-running the same policy/input hash is idempotent.
7. Keep generated business ideas/categories as optional annotations outside score calculation; final analysis may use them after quantitative ranking.
8. Add fixtures proving exact readings, ambiguity, missing evidence, deterministic reruns, and risk flags without claiming trademark clearance.

### Hazards and Compatibility

- **Concurrency/atomicity:** One policy run writes components and total transactionally; readers never observe a total without its components.
- **Migration/rollback:** Policy versions are append-only observations. Rolling back code preserves existing rows and can still query/export unknown newer policies as raw evidence.
- **Mixed-version/backward compatibility:** Unknown components are ignored only by older renderers with an explicit warning; foundation schema incompatibility fails before writes.
- **Idempotency/retry:** Policy version plus canonical input hash uniquely identifies a score; retry updates no source listing and creates no duplicate components.
- **Partial failure/recovery:** One invalid listing is rejected/flagged with reason while the bounded batch continues; policy-level configuration failure aborts before any scores publish.

### Verification Before Dispatch

```bash
python3 .agents/scripts/domain-opportunity-score.py score --fixture .agents/scripts/tests/fixtures/domain-opportunity/scoring-candidates.jsonl --db "$HOME/.aidevops/.agent-workspace/work/domain-opportunities/scoring-smoke.sqlite"
python3 .agents/scripts/domain-opportunity-score.py explain --db "$HOME/.aidevops/.agent-workspace/work/domain-opportunities/scoring-smoke.sqlite" --domain archeryclasses.com --json
python3 .agents/scripts/tests/test-domain-opportunity-scoring.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Fixture scoring/explain prove the production scoring/store path and component rendering; focused tests prove deterministic and negative boundaries; changed lint covers code, policy, and any licensed asset metadata.
- **Broad verification trigger:** Required only if a redistributed data asset changes licensing or deployed package contents; v1 adds no runtime dependency.

### Recoverability Checkpoint

- [ ] Phrase-source/licence decision and focused fixture score are verified.
- [ ] WIP commit created before broader gates: `wip: add deterministic domain opportunity scoring`
- [ ] Evidence-triggered broad verification then run: packaging/licence gate only if a redistributed data asset is added.

### Files Scope

- `.agents/scripts/domain-opportunity-score.py`
- `.agents/scripts/domain_opportunity_scoring.py`
- `.agents/scripts/tests/fixtures/domain-opportunity/scoring-candidates.jsonl`
- `.agents/scripts/tests/test-domain-opportunity-scoring.py`
- `.agents/data/domain-opportunity-words.*`
- `LICENSES/**`

## Acceptance Criteria

- [ ] Every eligible candidate has at least one exact phrase reading with source/confidence and a component-level score explanation.
- [ ] Hard filters and risk flags are configurable, versioned, and covered by positive plus malformed/ambiguous fixtures.
- [ ] Missing demand/appraisal/history evidence remains explicitly unknown and cannot silently score as measured zero.
- [ ] Re-running the same policy over unchanged evidence creates no duplicate score run/components and yields the same total.
- [ ] No model-generated phrase/business idea, unlicensed word list, host-only dictionary, or legal-clearance claim enters deterministic scoring.
- [ ] Production score/explain, focused tests, and changed-file lint pass; any redistributed data asset includes verified licence and packaging evidence.

## Context & Decisions

- Readability and exact-match structure are separate from search demand.
- Deterministic scoring may consume provider/Google Ads observations but cannot invent them.
- Trademark screening is a review aid, not legal advice; names with plausible conflicts remain flagged for human/legal review.
- Coverage may be lower in v1 if that avoids an opaque or unlicensed segmentation dependency.

## Relevant Files

- `.agents/seo/keyword-research.md:95-116` — current explainable opportunity-score vocabulary.
- `.agents/scripts/domain_opportunity_contract.py` — dependency-created listing/evidence contract.
- `.agents/scripts/domain_opportunity_store.py` — dependency-created score persistence API.
- `.agents/aidevops/architecture.md:61-85` — deterministic mechanics versus model judgment.

## Dependencies

- **Blocked by:** `t18296` / #30493
- **Blocks:** `t18302` / #30499
- **External:** Optional lexical resource only after licence/portability verification; no paid API required.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | Phrase source, licence, foundation fields |
| Implementation | 4h | Filters, components, policy, persistence |
| Verification | 1h | Determinism, ambiguity, missing evidence |
| **Total** | **6h** | |
