---
description: Score AI responses with weighted evaluation criteria
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
model: standard
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Response Scoring Framework

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Evaluate real model outputs with structured scoring
- **Use for**: Task-type model selection, prompt before/after tests, reproducible benchmarks
- **Command**: `/score-responses` (interactive evaluation)
- **Helper**: `response-scoring-helper.sh [init|prompt|record|score|compare|leaderboard|export|history|criteria]`
- **Criteria**: Correctness (30%), Completeness (25%), Code Quality (25%), Clarity (20%)
- **Storage**: SQLite at `~/.aidevops/.agent-workspace/response-scoring.db`

<!-- AI-CONTEXT-END -->

## Scoring Criteria (1–5 scale, weighted average)

| Criterion | Weight | 1 | 3 | 5 |
|-----------|--------|---|---|---|
| Correctness | 30% | Major errors | Mostly correct, minor issues | Fully correct |
| Completeness | 25% | Missing major requirements | Covers main, misses edge cases | Comprehensive including edge cases |
| Code Quality | 25% | Poor structure, no error handling | Reasonable structure, some best practices | Clean, idiomatic, well-structured |
| Clarity | 20% | Confusing, poorly organized | Understandable but could be clearer | Crystal clear, well-organized |

## Workflow

### 1. Create prompt

```bash
response-scoring-helper.sh prompt add \
  --title "FizzBuzz in Python" --text "Write a Python function..." \
  --category "coding" --difficulty "easy"
# Or: --file prompts/rest-api.txt
```

### 2. Record responses

```bash
response-scoring-helper.sh record \
  --prompt 1 --model claude-sonnet-4-6 \
  --text "def fizzbuzz():..." \
  --time 2.3 --tokens 150 --cost 0.0005
# Or: --file responses/gpt4o-output.txt
```

### 3. Score

```bash
response-scoring-helper.sh score \
  --response 1 \
  --correctness 5 --completeness 4 --code-quality 5 --clarity 4
```

### 4. Compare and rank

```bash
response-scoring-helper.sh compare --prompt 1        # or --json
response-scoring-helper.sh leaderboard               # or --category coding
response-scoring-helper.sh export --csv > scores.csv
```

## Integration

| Tool | Purpose |
|------|---------|
| `compare-models-helper.sh recommend "task"` | Candidate models by spec |
| `model-availability-helper.sh check <model>` | Verify availability |
| `response-scoring-helper.sh` | **Actual response quality** |
| `model-routing.md` | Leaderboard → tier assignments |

## Pattern Tracker Integration (t1099)

Scores feed the shared pattern tracker:

- **On score**: `SUCCESS_PATTERN` (weighted avg >= 3.5) or `FAILURE_PATTERN` (< 3.5), tagged with model tier + category
- **On compare**: Winner → `SUCCESS_PATTERN` with comparison metadata
- **Bulk sync**: `response-scoring-helper.sh sync` (`--dry-run` to preview). Disable: `SCORING_NO_PATTERN_SYNC=1`
- **Tier mapping**: Full model names (for example, `claude-sonnet-4-6`) map to
  canonical workload tiers (`simple`, `standard`, or `thinking`) for comparable
  result grouping

Outputs feed `/route <task>` and `/patterns recommend --task-type <type>` with real A/B data.

## Database Schema

```sql
prompts     -- Evaluation prompts with category and difficulty
responses   -- Model responses with timing and cost metadata
scores      -- Per-criterion scores (1-5) with scorer attribution
comparisons -- Comparison records with winner tracking
```

## Related

- `tools/ai-assistants/compare-models.md` — model spec comparison
- `tools/context/model-routing.md` — cost-aware routing
- Cross-session memory — pattern tracking, model recommendations (replaces archived `pattern-tracker-helper.sh`)
- `scripts/model-availability-helper.sh` — provider health checks
- `scripts/model-registry-helper.sh` — model version tracking
