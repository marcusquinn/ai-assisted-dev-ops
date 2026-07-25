---
description: Compare AI model capabilities using offline embedded data only (no web fetches)
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Compare AI models using only embedded reference data. No web fetches, no API calls.

Target: $ARGUMENTS

## Instructions

Run the appropriate helper subcommand based on `$ARGUMENTS`:

```bash
~/.aidevops/agents/scripts/compare-models-helper.sh list                        # all models
~/.aidevops/agents/scripts/compare-models-helper.sh compare <model1> <model2>  # specific models
~/.aidevops/agents/scripts/compare-models-helper.sh recommend "<task>"         # task-based recommendation
~/.aidevops/agents/scripts/compare-models-helper.sh pricing                    # pricing overview
~/.aidevops/agents/scripts/compare-models-helper.sh capabilities               # capability matrix
```

**Do NOT fetch any web pages.** Note the "Last updated" date in output for data freshness.

Present results as a structured comparison table:
- Pricing per 1M tokens (input and output)
- Context window sizes
- Capability matrix
- Task suitability recommendations
- canonical aidevops workload tier (`simple`, `standard`, or `thinking`) for each model

## Examples

```bash
/compare-models-free claude-sonnet-4-6 gpt-4o   # compare specific models
/compare-models-free --task "summarization"      # task recommendation
/compare-models-free --pricing                   # all pricing
/compare-models-free --capabilities              # capabilities matrix
```
