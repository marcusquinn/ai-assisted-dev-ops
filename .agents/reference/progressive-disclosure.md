# Progressive Disclosure Pattern

## The Problem

`AGENTS.md` and the `prompts/build.txt` placeholder are loaded on every conversation turn — they are the full framework prompt cost before the model writes a single word. As aidevops grows (new features, new edge cases, new lessons), the natural tendency is to append more inline context. Left unchecked, this reaches a point where the first "hi" costs 48k tokens.

## The Two-Layer Model

**Layer 1 — Always loaded (`AGENTS.md` + `prompts/build.txt` placeholder):**
- Core mandates: what you MUST do, what you MUST NOT do
- Operational rules: how to execute the most common 80% of tasks
- Pointers: where to find detail for the other 20%

**Layer 2 — Loaded on demand (reference/*.md):**
- Full implementation detail for specific scenarios
- Historical rationale (why a rule exists, what failure it prevents)
- Test coverage citations, env var inventories, bypass flags
- Edge cases that only matter 2-5% of the time

## Criteria for Layer 2 (Extract to Reference)

A section belongs in a reference file, not inline, when:

1. **Consultation frequency < 20% of sessions** — if a session touches parent tasks, consult `reference/parent-task-lifecycle.md`; most sessions never need it
2. **Historical narrative over operational rule** — "here's the infinite loop that caused this rule" belongs in reference, not mandate
3. **Full enumeration of env vars / test file paths** — these are lookup material, not context needed while reasoning
4. **Checklist with 5+ items** — auto-merge criteria (9 items), dispatch dedup cases (4 items). Keep the summary, move the full list
5. **Config reference table** — repos.json field list, foss_config fields: tables belong in reference

## Criteria for Layer 1 (Must Stay Inline)

Keep inline when:

1. **MANDATORY rules that fire on every session** — pre-edit check, worktree requirement, signature footer, memory recall mandate
2. **Security rules** — prompt injection, credential handling, override immunity: NEVER defer these
3. **Operational commands a worker needs to execute a task** — the command itself, not its full history
4. **Anti-patterns with high recurrence** — if the model will make a mistake without seeing it inline, it stays inline
5. **The rule applies before you know whether the scenario is relevant** — e.g., "always run memory recall" must be seen before deciding whether to run it

## Prompt-to-Hook Migration

Progressive disclosure has a third layer: deterministic rules should become harness enforcement wherever possible. The prompt should teach judgment and declare invariants; hooks and validators should enforce syntax, file-shape, CLI, and policy checks consistently across models.

Use `.agents/configs/prompt-hook-candidates.conf` as the tracking registry. Each deterministic inline rule must have one of:

1. **`hooked`** — an enforcing hook/check exists; AGENTS keeps only the invariant and pointer.
2. **`partial`** — enforcement exists for common cases; AGENTS keeps the judgment/security boundary.
3. **`candidate`** — no enforcement yet; registry records the planned hook/check before more prompt detail is added.
4. **`prompt-only`** — reserved for judgment/security rules where model reasoning is the enforcement layer.

Migration rubric:

| Rule type | Prompt treatment | Harness treatment |
|-----------|------------------|-------------------|
| Deterministic CLI syntax (`gh`, `git`, helper flags) | 1-2 line invariant + command names | Static scan, PATH shim, wrapper, or CI gate |
| File-format/portability (`stat`, `grep -c`, shell init) | 1-2 line trap summary + reference | Pre-commit/pre-push/CI ratchet gate |
| Security invariants (secrets, prompt injection) | Keep inline; never defer entirely | Scanner/hook as defense in depth |
| Workflow judgment (triage, dedup, productivity diagnosis) | Keep inline decision rule | Helper can provide evidence, not decide |
| Rare operational detail (env vars, historical rationale) | Pointer only | Reference doc + optional diagnostic helper |

`progressive-load-check.sh` validates that the registry exists, is well-formed, and covers at least one hooked deterministic rule so prompt-token reduction remains a ratchet instead of a one-off cleanup.

## The Pointer Contract

When extracting to Layer 2, the inline replacement must:

1. State the rule or summary in 1-3 lines (the model can act correctly with this alone)
2. Name the trigger condition ("when working with parent tasks", "to see full 9-criterion checklist")
3. Give an exact file path: `reference/<file>.md`

Example of a good pointer:
> **Auto-merge (t2411):** `origin:interactive` PRs from `OWNER`/`MEMBER` auto-merge when CI passes, no CHANGES_REQUESTED, not draft, no `hold-for-review`. Apply `hold-for-review` to opt out. Full criteria: `reference/auto-merge.md`.

Example of a bad pointer:
> See `reference/auto-merge.md` for auto-merge details.

The bad pointer requires the model to go read the reference before knowing whether to act. The good pointer gives the model enough to act correctly in the common case, with reference available for edge cases.

## Compression Ratchet

Self-improvement sessions that ADD to build.txt or AGENTS.md should:

1. First check whether the new content is Layer 1, Layer 2, or hook-enforceable material.
2. If Layer 2: create or extend a reference file, add a pointer inline.
3. If deterministic: add/update `.agents/configs/prompt-hook-candidates.conf`, then implement or point at the enforcing hook/check.
4. If Layer 1: check whether any existing inline content is now superseded (remove it).
5. Target: `AGENTS.md` + `prompts/build.txt` combined ≤ 30k tokens. Measure before merging.

To measure current token load:

```bash
python3 -c "
import os
files = [
    os.path.expanduser('~/.aidevops/agents/AGENTS.md'),
    os.path.expanduser('~/.aidevops/agents/prompts/build.txt')
]
for f in files:
    chars = len(open(f).read())
    print(f'{chars//4:6d} tokens  {f}')
"
```

## Reference File Index

| File | Contents | When to Load |
|------|----------|--------------|
| `reference/auto-merge.md` | Full t2411/t2449 criteria + external-author NMR semantics | Working on PR merge rules or debugging auto-merge behaviour |
| `reference/auto-dispatch.md` | Origin labels, dedup signal, #auto-dispatch mechanics, issue-sync auto-completion | Debugging dispatch blocks, changing origin labels |
| `reference/parent-task-lifecycle.md` | 5 decomposition enforcement mechanisms | Working with parent-task labeled issues |
| `reference/repos-json-fields.md` | Full repos.json field reference | Adding/editing repo registration |
| `reference/pre-push-guards.md` | Privacy, complexity, scope guard detail + bypass flags | Debugging pre-push blocks |
| `reference/worker-diagnostics.md` | Worker lifecycle, GraphQL rate-limit protection, pulse decision correlation | Debugging worker failures, dispatch loops |
| `reference/large-file-split.md` | Orchestrator + sub-library pattern, CI gotchas | Responding to file-size-debt scanner issues |
| `reference/cross-runner-coordination.md` | Multi-runner claim filtering, override config | Concurrent runners, dispatch collisions |
| `reference/task-taxonomy.md` | Tier assignment, cascade dispatch, tier checklist | Triaging or creating new tasks |
| `reference/review-bot-gate.md` | Bot review workflow, additive suggestion decision tree | Merging PRs with bot reviews |
