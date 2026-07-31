# t18187: Fix Pulse scheduler regression rejecting generated routines repositories

## Origin

- **Created:** 2026-07-31
- **Session:** batch-2026-07-31
- **Created by:** ai-interactive (batch mode via /new-task --batch)
- **Task ref:** none

## What

Restore recurring Pulse execution for framework-generated `aidevops-routines`
repositories without weakening the fenced/commented example protection added by
GH#28808. Support the dedicated routines-repository document shape and add a
generator-to-scheduler contract test so future format drift fails in CI.

## Why

GH#28808 restricted discovery to one exact `## Routines` section, but
`init-routines-helper.sh` generates a dedicated `# Routines` document containing
`## Core Routines (framework-managed)` and `## User Routines`. Since deployment,
Pulse has rejected that generated file every cycle as malformed. Routine r916
last ran at `2026-07-28T08:26:33Z`, so it missed Buzz v0.5.2 after the upstream
release on 2026-07-29. The direct monitor still reports the release, proving the
failure is scheduler discovery rather than release detection.

## Tier

**Selected tier:** `tier:standard`

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/pulse-routines.sh` — accept exactly one supported
  routines registry shape while retaining fail-closed fence, comment,
  indentation, and out-of-section handling.
- EDIT: `.agents/scripts/tests/test-pulse-routines-selector.sh` — generate a
  real routines-repository fixture via `init-routines-helper.sh`, prove core and
  user routines are selected, and prove task-section lookalikes remain excluded.

### Implementation Steps

1. Extend `_routine_extract_section` to recognize both the general-project
   `## Routines` section and the dedicated generated `# Routines` document with
   its controlled core/user subsections.
2. Reject duplicate, mixed, malformed, fenced, commented, and unsupported
   boundaries before returning any routine lines.
3. Add an integration regression that calls the production scaffold generator,
   then passes its `TODO.md` through the production scheduler parser.
4. Run focused scheduler tests, ShellCheck, changed-file quality gates, and a
   deployed dry-run against the registered routines repository.

### Verification

```bash
bash .agents/scripts/tests/test-pulse-routines-selector.sh
bash .agents/scripts/tests/test-init-routines-readonly-guard.sh
shellcheck .agents/scripts/pulse-routines.sh .agents/scripts/tests/test-pulse-routines-selector.sh
.agents/scripts/linters-local.sh --files .agents/scripts/pulse-routines.sh,.agents/scripts/tests/test-pulse-routines-selector.sh
```

## Acceptance Criteria

- [ ] A generated `aidevops-routines/TODO.md` exposes r916 and valid user
      routines to the scheduler.
- [ ] General-project `## Routines` registries continue to work unchanged.
- [ ] Fenced, commented, indented, out-of-section, duplicate, mixed, and
      malformed routine definitions do not dispatch.
- [ ] Focused tests and ShellCheck pass.
- [ ] The deployed monitor can detect the current Buzz release through r916's
      configured command.

## Context

The fix belongs in the scheduler compatibility boundary rather than only
rewriting one generated repository: existing installations must recover without
a coordinated migration. Keep Bash 3.2 compatibility and explicit function
returns. Do not relax parsing to whole-file matching, which would reintroduce
GH#28808.
