---
description: Run browser tool benchmarks to compare performance across all installed tools
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

# Browser Tool Benchmarking Agent

Runs standardised benchmarks across all browser automation tools and updates `browser-automation.md` with results. Scripts in `browser-benchmark-scripts.md`.

```bash
/browser-benchmark              # Run all benchmarks
/browser-benchmark playwright   # Run specific tool only
/browser-benchmark --test navigate
/browser-benchmark --update-docs
```

## Test Matrix

Target: `https://the-internet.herokuapp.com`. 3 runs per tool, report median. Network variance ~0.2-0.5s.

| Test | Measures |
|------|----------|
| Navigate + Screenshot | Cold page load + render capture |
| Form Fill (4 fields) | Input interaction + submit + navigation |
| Data Extraction (5 rows) | DOM query + structured data return |
| Multi-step (click + nav) | Sequential interaction + URL change |
| Reliability (3 runs) | Variance across repeated Navigate runs |

## Tool Coverage

| Tool | Scope | Setup |
|------|-------|-------|
| Playwright | Full | `npm init -y && npm i playwright` in `~/.aidevops/playwright-bench/` |
| dev-browser | Full | `dev-browser-helper.sh setup` (server: `dev-browser-helper.sh start-headless`) |
| agent-browser | Full | `agent-browser-helper.sh setup` (first run slower — discard or note) |
| Crawl4AI | Navigate + extract only | `python3 -m venv ~/.aidevops/crawl4ai-venv && pip install crawl4ai` |
| Stagehand | Full (AI-dependent latency) | `npm init -y && npm i @browserbasehq/stagehand` in `~/.aidevops/stagehand-bench/` — needs `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` |
| Playwriter (legacy, not recommended) | Full | Retained only for historical comparison; skip unless explicitly benchmarking an existing setup |

## Running Benchmarks

```bash
cd ~/.aidevops/.agent-workspace/work/browser-bench/
node bench-playwright.mjs | tee results-playwright.json
bash bench-agent-browser.sh | tee results-agent-browser.txt
source ~/.aidevops/crawl4ai-venv/bin/activate && python bench-crawl4ai.py | tee results-crawl4ai.json
OPENAI_API_KEY=... node bench-stagehand.mjs | tee results-stagehand.json
# dev-browser: bun x tsx ~/.aidevops/dev-browser/skills/dev-browser/bench.ts | tee ~/results-dev-browser.json
```

## Updating Documentation

Update the Performance Benchmarks table in `browser-automation.md`:

1. Median of 3 runs per test; bold fastest time per row
2. Update "Key insight" section if relative performance changed
3. Record environment: `date && uname -a && node --version && python3 --version`

## Adding New Tools

1. Add benchmark script per patterns in `browser-benchmark-scripts.md`
2. Add tool to Tool Coverage table; run full suite
3. Update `browser-automation.md` tables (Performance, Feature Matrix, Parallel, Extensions)
