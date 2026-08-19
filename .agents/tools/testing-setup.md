---
description: Explicit, permission-gated per-repo testing infrastructure setup
agent: Build+
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Testing Infrastructure Setup

Use this workflow only when the user explicitly asks to create or change testing infrastructure. Routine feature/bug verification stays with Build+ and `reference/ci-gate-policy.md`. Discovery and `--verify-only` are safe, but a missing runner, suite, coverage target, or CI gate is not an implied deliverable.

Arguments: $ARGUMENTS

## Workflow

### 1. Discover Existing Infrastructure

Run `testing-setup-helper.sh discover .` and inspect repository-owned configuration:

| Category | Evidence |
|----------|----------|
| Test runners | Existing package scripts/dependencies, language manifests, runner configs |
| Tests/fixtures | Existing `tests/`, `test/`, `__tests__/`, specs, or language-native test files |
| CI | Existing workflow test steps and branch-required checks |
| Coverage | Existing config, commands, and repository threshold |
| Browser/E2E | Existing Playwright, Cypress, Maestro, or project-native setup |

Display what is found and its source. Do not turn an absent category into a recommendation.

### 2. Interpret Bundle Context

Resolve the project bundle with `bundle-helper.sh resolve .`. Bundle quality gates describe tools relevant to a project type; only gates already configured or explicitly selected are actionable. If detection is uncertain, report that instead of treating the `cli-tool` fallback as authority to add tooling.

`testing-setup-helper.sh gaps .` may identify missing bundle candidates. Label them as candidates, never as required gaps.

### 3. Apply the Permission Boundary

The explicit setup request authorises work on its stated target, not every discovered candidate. Before creating any item not named in the request, explain why existing production-facing paths and tooling are insufficient and obtain a specific user selection:

- test runner or harness;
- mock server, fixture framework, or test-only product interface;
- coverage tool or threshold;
- CI test gate or pre-commit hook;
- sample or baseline test suite.

Prefer an already installed alternative when it satisfies the objective. Do not invent a coverage threshold; use an explicit repository or user policy.

With `--non-interactive`, apply only choices explicitly supplied in `$ARGUMENTS` and leave every unspecified candidate unchanged. `--dry-run` reports proposed files without writing them. `--verify-only` runs the existing setup without changing it.

### 4. Configure Only Selected Components

Create only the files the user selected. Do not silently add adjacent coverage, CI, hooks, fixtures, mocks, or sample tests. Record the selected setup in `.aidevops-testing.json` when requested:

```json
{
  "bundle": "web-app",
  "configured_at": "2026-03-26T12:00:00Z",
  "test_runners": ["vitest"],
  "quality_gates": ["vitest"],
  "coverage": { "enabled": false },
  "ci_integration": false,
  "pre_commit_hooks": false
}
```

### 5. Verify and Summarise

Run `testing-setup-helper.sh verify .` for selected/configured runners and report `[pass]`, `[fail]`, or `[skip]` per gate. List every created/modified file and then:

1. Exercise the affected behaviour through its production-facing path.
2. Run `testing-setup-helper.sh status` to check the selected setup.
3. Trigger CI only when CI integration was explicitly selected.
4. Add test cases later only under `reference/ci-gate-policy.md`.

## Available Bundle Integrations (Not Defaults)

| Bundle | Common runner | Secondary | Coverage tool |
|--------|---------------|-----------|---------------|
| `web-app` | vitest | playwright | c8 |
| `library` | language/project-specific | — | project-specific |
| `cli-tool` | bats / existing shell tests | — | kcov |
| `agent` | agent-test-helper.sh | existing shell tests | — |
| `infrastructure` | terraform validate | — | — |
| `content-site` | playwright | lighthouse | — |

This table helps interpret an explicit setup request. It never authorises installation merely because a bundle was detected.

## Related

- `reference/ci-gate-policy.md` — mission-first verification and permission boundary
- `tools/build-agent/agent-testing.md` — agent-specific behavioural testing
- `bundles/*.json` — project-type context and configured quality gates
- `.agents/scripts/testing-setup-helper.sh` — deterministic discovery and verification
