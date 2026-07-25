<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Autoagent — Hypothesis Types

Sub-doc for `autoagent.md`. Loaded during Step 2 (Loop) for hypothesis generation.

---

## The 6 Hypothesis Types

| # | Type | Edit surface | Primary signal source |
|---|------|-------------|----------------------|
| 1 | Self-healing | Scripts, error handlers, workflow docs | Error-feedback patterns, session failures |
| 2 | Tool optimization | Helper scripts, tool docs | Command frequency, error rates, timeout patterns |
| 3 | Instruction refinement | Agent `.md` files, prompts | Directive provenance, comprehension scenarios, delivery gaps |
| 4 | Tool creation | New helper scripts | Capability gaps from failed tasks |
| 5 | Agent composition | Subagent routing, model tiers | Task taxonomy, cost/quality tradeoffs |
| 6 | Workflow optimization | Command docs, routines | Pulse throughput, PR merge rates |

---

## Type Definitions

### Type 1: Self-Healing

Fix recurring failure patterns so the framework recovers automatically. Edit: helper scripts (retry logic, fallback paths), workflow docs (recovery steps), error handlers (silent → actionable). Signal: error-feedback patterns, session miner failures, pulse dispatch failures.

**Good:** "Add retry loop (3x) to `gh` API calls in `dispatch-helper.sh` to handle transient 503s" · "Add `set -e` guard to `pre-edit-check.sh` to prevent silent failures on missing git" · "Document recovery steps for `worktree already exists` error in `git-workflow.md`"

**Bad:** "Rewrite dispatch-helper.sh from scratch" (too broad) · "Add logging to every function" (low signal value)

---

### Type 2: Tool Optimization

Improve existing helper scripts to reduce failure rates, execution time, or token usage. Edit: helper scripts (optimize sequences, reduce subprocess spawning), tool docs (clarify error-causing patterns), configuration (timeouts, retry counts, batch sizes). Signal: command error rates, timeout patterns, linter violations.

**Good:** "Replace sequential `gh api` calls with `--jq` flag to reduce subprocess count in `issue-sync-helper.sh`" · "Add `--no-pager` to `git log` calls in `session-miner-pulse.sh` to prevent TTY hangs" · "Cache `gh auth status` result in `pulse-wrapper.sh` instead of calling per-repo"

**Bad:** "Rewrite helper in Python" (architectural decision, not optimization) · "Add more comments" (no metric impact)

---

### Type 3: Instruction Refinement

Improve agent `.md` files and prompts while preserving the lessons and interfaces they deliver. Edit: agent `.md` files (tighten proven repetition, clarify activation boundaries), `AGENTS.md` (retain invariants while moving triggered detail behind reliable pointers), subagent docs (progressive disclosure). Signal: directive provenance, target-specific comprehension failures, delivery gaps, and assembled-context conflicts; token ratio and git churn only identify review pressure.

**Good:** "Tighten two exact duplicates after history and activation analysis prove they reach the same decision boundary" · "Replace a 3-sentence webfetch warning with an equivalent invariant plus a reliably triggered reference" · "Move non-interface rationale from `git-workflow.md` to a reference while testing every route that must load it"

**Bad:** "Merge every 'Read before Edit' occurrence" (may erase boundary reinforcement) · "Delete a rare rule because aggregate tests stayed green" (absence of coverage is not evidence) · "Add more examples to every rule" (increases context without demonstrated value)

---

### Type 4: Tool Creation

Create new helper scripts to fill capability gaps from failed tasks. Edit: new scripts in `.agents/scripts/`, new reference docs in `.agents/reference/`, new command docs in `.agents/scripts/commands/`. Signal: capability gaps from failed tasks, repeated manual workarounds in session transcripts.

**Good:** "Create `worktree-status-helper.sh` to list all active worktrees with their task IDs and ages" · "Create `pr-health-helper.sh` to check PR age, review status, and CI state in one command" · "Create `signal-aggregator.sh` to run all signal sources and output ranked findings JSON"

**Bad:** "Create a helper for every existing command" (no signal, preemptive bloat) · "Create a GUI dashboard" (out of scope for CLI framework)

**Gate:** Gap must appear in at least 2 independent signal sources. If not → defer.

---

### Type 5: Agent Composition

Improve subagent routing, model tier assignments, or agent boundaries to reduce cost and improve quality. Edit: `reference/agent-routing.md` (routing table), `reference/task-taxonomy.md` (model tiers), subagent index (add/remove/rename), agent frontmatter (`model:` tier). Signal: task taxonomy analysis, cost/quality tradeoffs from pulse logs, PR merge rates by agent.

**Good:** "Change `code-simplifier` from `standard` to `simple` after equivalent-workload evidence shows the task is mechanical" · "Add explicit routing rule for 'audit' tasks → `auditing` subagent (currently falls through to general)" · "Split `build-agent.md` into separate 'compose' and 'review' agents — different tools needed"

**Bad:** "Use `thinking` for everything" (cost increase without signal) · "Merge all subagents into one" (destroys progressive disclosure)

---

### Type 6: Workflow Optimization

Improve command docs and routines to increase pulse throughput and PR merge rates. Edit: command docs in `.agents/scripts/commands/`, workflow docs in `.agents/workflows/`, routine configs in `.agents/configs/`. Signal: pulse throughput metrics, PR merge rates, time-to-merge distributions.

**Good:** "Add explicit 'check for existing PR before creating' step to `full-loop.md` to prevent duplicate PRs" · "Move review bot polling from 60s to 30s intervals in `review-bot-gate.md` — bots respond faster" · "Add `--skip-preflight` shortcut to `full-loop.md` for hotfix tasks (currently requires manual flag)"

**Bad:** "Remove all quality gates" (blocked by safety constraints) · "Add more steps to every workflow" (increases complexity without signal)

---

## Progression Strategy

| Phase | Iterations | Primary types | Rationale |
|-------|-----------|--------------|-----------|
| 1 | 1–5 | Self-healing (1), Instruction refinement (3) | Low risk, high signal, direct feedback loop |
| 2 | 6–15 | Tool optimization (2), Instruction refinement (3) | Systematic single-variable changes |
| 3 | 16–25 | Tool creation (4), Agent composition (5) | Higher complexity, builds on earlier findings |
| 4 | 26–35 | Workflow optimization (6), combinations | Cross-cutting changes |
| 5 | 36+ | Evidence-backed simplification | Reduce mechanics or context only after semantic and behavioural gates pass |

**Override rules:**
- If `HYPOTHESIS_TYPES` is set in the research program, only use listed types regardless of phase
- If a signal source produces high-priority findings for a specific type, prioritize that type regardless of phase
- Never repeat a discarded hypothesis (check `FAILED_HYPOTHESES`)

---

## Hypothesis Generation Rules

1. **One change per hypothesis.** Never bundle multiple changes — makes keep/discard ambiguous.
2. **Prefer high-impact, low-risk changes.** Estimate constraint-failure probability before applying.
3. **Use signal findings as input.** Hypotheses without signal backing are lower priority.
4. **Check safety and semantic constraints first.** Load `autoagent/safety.md`; instruction-semantic candidates must also satisfy `.agents/tools/build-agent/agent-review.md`.
5. **Treat simplification as a candidate, not proof.** Keep it only when the applicable semantic-preservation gate passes and the relevant metric improves.

---

## Overfitting Test (Universal)

Before committing to any hypothesis, ask: **"If this exact test/signal disappeared, would this still be a worthwhile framework improvement?"**

- **Yes** → proceed (generalizable improvement)
- **No** → discard (overfitting to current test suite or signal)

This prevents the autoagent from gaming its own metric.

For instruction-semantic hypotheses, also ask whether the changed directive's rare
activation and exclusion cases are represented. If not, record `provenance_fail`
and preserve the directive rather than treating missing coverage as a successful
test.
