---
description: Tier optimisation — expand test corpus, run tier telemetry report, and optionally launch autoresearch loop
agent: Build+
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# /optimize-tiers

Manage the cascade tier optimisation pipeline: expand the test corpus, review telemetry, and iterate brief quality.

Topic: $ARGUMENTS

## Subcommands

### `/optimize-tiers report`

Show current tier dispatch telemetry from production data:

```bash
~/.aidevops/agents/scripts/dispatch-ledger-helper.sh tier-report
```

Outputs: total dispatches, success/escalation/failure counts by tier, pass rates, top escalation reasons.

### `/optimize-tiers expand`

Expand the test corpus with recently merged worker PRs. Run weekly or on-demand.

```bash
CORPUS="${HOME}/.aidevops/.agent-workspace/work/tier-corpus"
mkdir -p "$CORPUS"

# Extract new PRs from all pulse-enabled repos
for slug in $(jq -r '.initialized_repos[] | select(.pulse == true) | .slug' ~/.config/aidevops/repos.json); do
  ~/.aidevops/agents/scripts/brief-tier-test-helper.sh extract \
    --repo "$slug" --label origin:worker --max-files 3 --limit 20 \
    --output "$CORPUS"
done

# Report corpus size
echo "Corpus: $(jq 'length' "$CORPUS/index.json") cases"
```

After extraction, generate enriched briefs for new cases:

```bash
~/.aidevops/agents/scripts/brief-tier-test-helper.sh enrich \
  --corpus "$CORPUS" --model sonnet
```

### `/optimize-tiers test`

Run Haiku against the corpus and score results:

```bash
CORPUS="${HOME}/.aidevops/.agent-workspace/work/tier-corpus"
RESULTS="${HOME}/.aidevops/.agent-workspace/work/tier-results.tsv"

~/.aidevops/agents/scripts/brief-tier-test-helper.sh test \
  --corpus "$CORPUS" --model haiku --results "$RESULTS"

~/.aidevops/agents/scripts/brief-tier-test-helper.sh report --results "$RESULTS"
```

### `/optimize-tiers research`

Launch the autoresearch optimisation loop. Iterates brief template changes and measures Haiku success rate improvement.

Read `todo/research/optimize-brief-tiers.md` for the full program definition, then:

1. Review current telemetry (`tier-report`) to identify the dominant escalation reason
2. Form a hypothesis about which brief template change would reduce that reason
3. Modify `~/.aidevops/agents/templates/brief-template.md` or `workflows/brief.md`
4. Re-enrich a subset of corpus cases with the modified template
5. Re-test Haiku on the subset
6. Score and compare against baseline
7. Keep improvement or revert

Budget: 30 iterations max, 3 trials per hypothesis (Haiku output has variance).

## Scheduling

### Weekly corpus expansion (L2)

Add to pulse routine (runs once per week):

```bash
# In pulse-wrapper.sh or as a launchd timer
LAST_EXPAND="${HOME}/.aidevops/.agent-workspace/tmp/tier-corpus-last-expand"
if [[ ! -f "$LAST_EXPAND" ]] || [[ $(( $(date +%s) - $(cat "$LAST_EXPAND") )) -gt 604800 ]]; then
  /optimize-tiers expand
  date +%s > "$LAST_EXPAND"
fi
```

### Production telemetry (L1, always on)

Tier telemetry is recorded automatically by:
- `dispatch-ledger-helper.sh register` — records tier + model at dispatch time
- `dispatch-ledger-helper.sh record-outcome` — records outcome + escalation reason
- Append-only log: `~/.aidevops/.agent-workspace/tmp/tier-telemetry.jsonl`

## Related

- `workflows/brief.md` — centralised brief formatting (the file being optimised)
- `reference/task-taxonomy.md` — tier definitions and cascade model
- `~/.aidevops/agents/templates/brief-template.md` — task brief template (modified by autoresearch)
- `templates/escalation-report-template.md` — escalation reason codes
- `scripts/brief-tier-test-helper.sh` — test harness
- `todo/research/optimize-brief-tiers.md` — autoresearch program definition
