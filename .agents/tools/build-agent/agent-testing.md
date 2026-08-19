---
name: agent-testing
description: Agent testing framework - validate agent behavior with isolated AI sessions
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Agent Testing Framework

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `agent-test-helper.sh [run|run-one|compare|baseline|list|create|results|help]`
- **Shipped suites**: `.agents/tests/*.json` (repo-shipped, version-controlled)
- **User suites**: `~/.aidevops/.agent-workspace/agent-tests/suites/`
- **Results/Baselines**: `~/.aidevops/.agent-workspace/agent-tests/{results,baselines}/`
- **CLI**: Auto-detects `opencode` (override with `AGENT_TEST_CLI`)
- **Flow**: Loads JSON suite → sends primary-agent prompts via `opencode run --format json` (CLI) or `opencode serve` (HTTP) → validates responses
- **Subagent suites**: Set suite-level `"command": "aidevops-<name>"`; each prompt runs through `opencode run --command`. Do not use `agent` alone for a `mode: subagent` target because OpenCode falls back to its primary agent.
- **Server mode**: `POST /session` → `POST /session/:id/message` → extract text → delete. Override host/port with `OPENCODE_HOST`/`OPENCODE_PORT`
- **When to use**: Validate agent changes before merging, regression-test after AGENTS.md/subagent edits, compare behavior across models, smoke-test after framework updates
- **Scope rule**: Reuse shipped/existing suites first. Create or expand a suite only when explicitly requested or when a bounded scenario is the lowest-cost way to resolve material behavioural uncertainty; this agent is not a routine post-edit requirement.

<!-- AI-CONTEXT-END -->

## Test Suite Format

```json
{
  "name": "build-agent-tests",
  "agent": "Build+",
  "model": "anthropic/claude-sonnet-4-6",
  "timeout": 120,
  "tests": [
    {
      "id": "instruction-budget",
      "prompt": "What is the recommended instruction budget for agents?",
      "expect_contains": ["50", "100"],
      "expect_not_contains": ["unlimited"],
      "min_length": 50
    }
  ]
}
```

Per-test `agent`, `model`, `timeout` override suite-level defaults.
`command` is suite-level and takes precedence over `agent` for dispatch.

### Validation Fields

| Field | Type | Description |
|-------|------|-------------|
| `expect_contains` | `string[]` | Response must contain each string (case-insensitive) |
| `expect_not_contains` | `string[]` | Response must NOT contain any of these |
| `expect_regex` | `string` | Response must match this regex (case-insensitive) |
| `expect_not_regex` | `string` | Response must NOT match this regex |
| `min_length` | `number` | Minimum response length in characters |
| `max_length` | `number` | Maximum response length in characters |
| `skip` | `boolean` | Skip this test |

## Commands

```bash
agent-test-helper.sh run path/to/suite.json
agent-test-helper.sh run smoke-test
agent-test-helper.sh run-one "What is your primary purpose?"
agent-test-helper.sh run-one "List your tools" --expect "bash"
agent-test-helper.sh run-one "Explain git workflow" --agent "Build+" --model "anthropic/claude-sonnet-4-6" --timeout 60
agent-test-helper.sh baseline smoke-test
agent-test-helper.sh compare smoke-test
agent-test-helper.sh create my-new-tests
agent-test-helper.sh list
agent-test-helper.sh results [suite-name]
agent-test-helper.sh run agents-md-knowledge || { echo "Agent tests failed"; exit 1; }
```

## Shipped Test Suites

| Suite | Tests | Purpose |
|-------|-------|---------|
| `smoke-test` | 3 | Quick agent responsiveness and identity check |
| `agents-md-knowledge` | 5 | Core AGENTS.md instruction absorption |
| `git-workflow` | 4 | Git workflow knowledge validation |
| `node-server-admin` | 5 | Node runtime policy, safety, performance evidence, and handoffs |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENT_TEST_CLI` | auto-detect | Force `opencode` |
| `AGENT_TEST_MODEL` | (suite default) | Override model for all tests |
| `AGENT_TEST_TIMEOUT` | `120` | Default timeout in seconds |
| `OPENCODE_HOST` | `localhost` | OpenCode server host |
| `OPENCODE_PORT` | `4096` | OpenCode server port |

## Related

- `build-agent.md` — Agent design and composition
- `agent-review.md` — Reviewing and improving agents
- `tools/ai-assistants/headless-dispatch.md` — Headless dispatch patterns
- `tools/ai-assistants/opencode-server.md` — OpenCode server API
