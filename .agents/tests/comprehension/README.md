<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Comprehension Benchmark

Tests whether agent files are comprehensible at each workload tier (`simple`,
`standard`, `thinking`). The runtime resolves each tier to its current preferred
provider/model mapping; scenario files never encode provider families as tiers.

## Schema

Test scenarios use YAML with this structure:

```yaml
# Required fields
file: .agents/path/to/agent-file.md    # Agent file under test
tier_minimum: simple                     # Expected minimum tier (simple|standard|thinking)

# Scenarios (2-3 per file)
scenarios:
  - name: "short descriptive name"
    prompt: "Task or question to give the model"
    expected:
      contains:                          # Strings that MUST appear in output
        - "keyword"
      not_contains:                      # Strings that MUST NOT appear
        - "forbidden action"
      action:                            # Expected behavioral outcome
        - "skip"                         # e.g., skip, refuse, analyze, list
      min_length: 50                     # Minimum response length (chars)
      max_length: 2000                   # Maximum response length (chars)
    reference_answer: |                  # Thinking-tier ground truth (set at authoring)
      Expected output summary from the thinking tier.
    fast_fail_triggers:                  # Skip adjudication, escalate immediately
      - refusal                          # Model refuses or says "I don't understand"
      - confabulation                    # Hallucinated paths, tools, or task IDs
      - structural_violation             # Core constraint violated (e.g., edits when told analysis-only)
      - disengagement                    # Response <20% expected length with no justification
```

## Execution and Scoring

1. Run the scenario at `simple`, escalating to `standard` and then `thinking`
   until one tier passes.
2. Apply deterministic string, action, and length checks to each response.
3. Send ambiguous responses to the mapped adjudicator with both the expected
   checks and the authored reference answer.
4. Report `unresolved` when no tier passes. An unresolved scenario or an
   expected-tier mismatch makes the command exit non-zero.

Provider comparisons are like-for-like only: keep the workload tier, assembled
prompt, tools, token budget, and verification equivalent while changing the
mapped model. Concrete provider/model names belong in benchmark result evidence,
not in `tier_minimum`.

## Fast-Fail Escalation

These signals skip adjudication and escalate to the next tier immediately:

| Trigger | Detection | Cost |
|---------|-----------|------|
| Refusal | `"I don't understand"`, `"I cannot"`, `"not able to"` | Free (regex) |
| Confabulation | More than three file paths absent from the full agent + task context | Free (set diff) |
| Structural violation | An explicit `expected.action` token is absent | Free (action check) |
| Disengagement | Response length < 20% of `min_length` | Free (length check) |

## Slow-Fail Signals (adjudicate before escalating)

- Output plausible but misses 1-2 expected elements
- Right process, wrong conclusion
- Model adds reasonable steps not in expected output

## Directory Layout

```text
.agents/tests/comprehension/
  README.md                              # This file (schema docs)
  pilot-results.md                       # Pilot run analysis
  {agent-path-slug}.yaml                 # One test file per agent file
```

Slug convention: replace `/` with `--` and drop `.agents/` prefix and `.md`
suffix. Example: `.agents/reference/task-taxonomy.md` becomes
`reference--task-taxonomy.yaml`.

## Running

```bash
# Test one file
.agents/scripts/comprehension-benchmark-helper.sh test <file.yaml>

# Run all tests
.agents/scripts/comprehension-benchmark-helper.sh sweep

# Generate report
.agents/scripts/comprehension-benchmark-helper.sh report

# Update simplification-state.json with tier_minimum results
.agents/scripts/comprehension-benchmark-helper.sh update-state
```

`sweep` writes `.agents/tests/comprehension/results/latest-sweep.json` even when
it returns non-zero. `report` reads that artifact. `update-state` rejects empty,
errored, unresolved, or expected-tier-mismatched sweeps and updates only files
already tracked under `simplification-state.json`'s `files` object.

## Integration Points

- **Implemented:** explicit `update-state` can add reviewed `tier_minimum` evidence
  to existing simplification-state entries.
- **Not wired:** Pulse dispatch does not read per-file comprehension state; it
  resolves task tiers through `.agents/configs/model-routing-table.json`.
- **Not wired:** Code Simplifier does not automatically invoke this benchmark.
  A simplification brief must name the relevant scenario or verification command
  when comprehension evidence is required.

## Cost Control

- Run focused scenario files during development; reserve a full sweep for a
  deliberate benchmark or release gate.
- Deterministic checks avoid adjudication when the response is clearly passing or
  failing.
- Estimate cost from the active runtime mappings and provider pricing rather than
  embedding provider-specific dollar assumptions in the scenario contract.
