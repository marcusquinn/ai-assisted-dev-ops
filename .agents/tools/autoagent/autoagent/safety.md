<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Autoagent — Safety Constraints

Sub-doc for `autoagent.md`. Loaded during Step 1 (Setup) before any modifications.

---

## Instruction-Semantic Preservation Gate

Any hypothesis that removes, consolidates, relocates, weakens, or materially
rephrases an instruction must load and satisfy
`.agents/tools/build-agent/agent-review.md` before metric evaluation. This applies
to agents, prompts, workflows, command bodies, templates, and generated/runtime
adapters; the security patterns below are hard minimums, not an allowlist of the
only lessons worth preserving.

Before modification, create an instruction-review record that:

1. Recovers directive provenance from task/issue/PR context, nearby identifiers,
   recent file history, observed failures, and current enforcement.
2. Assembles the canonical source, always-loaded guidance, triggered references,
   generated wrappers, runtime overlays, and adjacent owners that reach the task.
3. States activation and exclusion boundaries and classifies each affected
   directive as an invariant, judgment rule, interface, triggered pointer,
   rationale, or deterministic enforcement candidate.
4. Distinguishes exact duplication from decision-boundary reinforcement,
   runtime variants, and similar-but-different hazards.
5. Names the reliable delivery or enforcement mechanism and target-specific
   behavioural scenarios that preserve both activation and exclusion cases.

After modification, compare the exact diff with that record and run the named
target-specific checks across every changed delivery route. Incomplete provenance,
delivery, or behavioural evidence defaults to preservation: reject the hypothesis,
record `provenance_fail`, and do not run or interpret the aggregate metric. A lower
token count, smaller file, unchanged broad pass rate, or improved composite score
cannot override this gate. Semantically neutral formatting may bypass the gate only
when the diff demonstrably changes no directive or delivery route.

---

## Security Instruction Exemptions

Discard any hypothesis that removes or weakens the following — do not test:

| Category | Detection pattern |
|----------|------------------|
| Credential/secret handling | `credentials`, `NEVER expose`, `gopass`, `secret` |
| File operation safety | `Read before Edit`, `pre-edit-check`, `verify path` |
| Git safety | `pre-edit-check.sh`, `never edit on main`, `worktree` |
| Traceability | `PR title MUST`, `task ID`, `Closes #` |
| Prompt injection | `prompt injection`, `adversarial`, `scan` |
| Destructive operations | `destructive`, `confirm before`, `irreversible` |

Inherited from `autoresearch/agent-optimization.md`. Both layers must hold.

---

## Never-Modify Files

NEVER modify under any safety level:

| File | Reason |
|------|--------|
| `AGENTS.md` security sections | Prompt injection and secret handling — core security posture |
| `.agents/AGENTS.md` security sections | Operational security rules — modification could weaken safeguards |
| `prompts/build.txt` | Near-empty compatibility placeholder; framework rules belong in `.agents/AGENTS.md` |
| `.agents/tools/credentials/gopass.md` | Credential management — modification could expose secrets |
| `.agents/tools/security/prompt-injection-defender.md` | Security threat model — modification weakens defenses |
| `.agents/hooks/git_safety_guard.py` | Git safety hook — modification bypasses pre-edit checks |
| `.agents/configs/simplification-state.json` | Shared hash registry — modification corrupts simplification tracking |

**Enforcement:** Before applying any modification, check the target file against this list. If matched → discard hypothesis immediately, do not test.

---

## Elevated-Only Files

Require `SAFETY_LEVEL=elevated`. Under `standard`, skip hypotheses targeting these files:

| File | Reason |
|------|--------|
| `AGENTS.md` (non-security sections) | Primary user guide and core instruction set — high blast radius |
| `.agents/AGENTS.md` (non-security sections) | Operational guide — changes affect every managed session |
| `.agents/workflows/git-workflow.md` | Git workflow — changes affect all PRs and commits |
| `.agents/workflows/pre-edit.md` | Pre-edit gate — changes affect all file modifications |
| `.agents/reference/agent-routing.md` | Routing table — changes affect all task dispatch |

**Enforcement:** Under standard safety, subtract elevated-only matches from broad
targets. Under elevated safety, every target-matched elevated-only file must be
listed in `require_review`; otherwise validation fails before setup. Elevated
safety never permits changes to the security instructions identified above.

---

## Core Workflow Preservation

These workflows must remain functional after any modification (verified by regression gate):

1. **Git workflow**: `pre-edit-check.sh` must exit 0 in a clean safe linked worktree
2. **PR flow**: `gh pr create` must succeed with standard arguments
3. **Task management**: `claim-task-id.sh` must allocate IDs without collision
4. **Pulse dispatch**: `pulse-wrapper.sh` must complete without error on a test repo
5. **Memory system**: `aidevops-memory store` and `recall` must succeed

---

## Pre-Edit and Review Gates

Run `pre-edit-check.sh` from the exact registered experiment worktree before the
first owned-state write. Run it again from each detached candidate worktree before
the first candidate modification. A later constraint invocation is verification,
not a substitute for this write-time gate.

Every candidate path must be an allowed target: reject path escapes, symlinks,
runner-owned state paths, and any changed path outside `ALLOWED_FILES`. Never ignore
or remove out-of-scope dirt silently.

If a candidate changes any path listed in `require_review`, show the complete diff
and obtain explicit interactive approval before committing or fast-forwarding it.
Headless execution cannot grant this approval: checkpoint the candidate, record
`review_required`, remove only the verified disposable candidate, commit the owned
runner state, and stop without creating a PR.

---

## Regression Gate

Before the keep decision on any hypothesis, verify ALL comprehension tests still pass:

```bash
agent-test-helper.sh run .agents/tests/agents-md-knowledge.json --json 2>/dev/null | \
  jq -e '.failed == 0' 2>/dev/null
```

**Rule:** No existing passing comprehension test may start failing (`failed == 0`). A hypothesis that improves the composite score but causes a regression must be discarded.

---

## Candidate Disposition

Never discard changes in the current-best experiment worktree. Every hypothesis
runs in a program-owned disposable candidate worktree created from the current
best commit. Before discarding a candidate:

1. Stage only files permitted by the program target and safety rules.
2. Write the staged binary diff and untracked-file manifest under
   the program-owned `CHECKPOINT_DIR`.
3. Verify the candidate is registered to the experiment repository, is beneath
   the program-specific managed candidate prefix, and is not `WORKTREE_PATH`.
4. Remove only that verified disposable candidate worktree. Stop on any mismatch.

Use this disposition when a constraint fails, metric measurement errors, the
regression gate fails, or a safety violation is detected after modification. Append
the matching result and trajectory, then commit only exact runner-owned state paths
so the stable experiment worktree is clean.

On resume, recover dirt only when every path is an exact runner-owned state path and
its program/TSV/JSONL/checkpoint schema and ownership validation passes. Commit it
with an explicit recovery state message. Any other dirty path stops resume and is
preserved. Never reset, stash, or clean recovery state.

---

## Safety Level Summary

| Safety level | Never-modify | Elevated-only | Regression gate |
|-------------|-------------|--------------|----------------|
| `standard` (default) | Enforced | Skipped | Enforced |
| `elevated` | Enforced | Review-gated | Enforced |

**Note:** `elevated` allows reviewed changes to non-security sections of `AGENTS.md`
and `.agents/AGENTS.md`, plus the listed workflow/routing docs. `.agents/AGENTS.md`
is canonical; `prompts/build.txt` remains never-modify at every safety level.

---

## Constraint Shell Commands

All must pass (exit 0) before a hypothesis is accepted. The first failure
short-circuits, checkpoints and removes the owned candidate, logs
`constraint_fail`, and proceeds to the next hypothesis.

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh
shellcheck --severity=error .agents/scripts/*.sh
markdownlint-cli2 .agents/**/*.md
agent-test-helper.sh run .agents/tests/agents-md-knowledge.json --json | jq -e '.failed == 0'
```
