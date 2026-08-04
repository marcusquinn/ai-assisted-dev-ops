<!-- aidevops:brief-schema=v2 -->
# t18195: Add reversible Buzz Desktop OpenCode ACP compatibility remediation to setup and update

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `Buzz Desktop OpenCode ACP compatibility` → 0 hits — no relevant lessons
- [x] Discovery pass: no related commits, merged PRs, or open PRs found on target files
- [x] File refs verified: existing setup, CLI, README, and architecture refs checked at HEAD; new-file parents exist
- [x] Tier: `tier:standard` — trust boundary and rollback policy are resolved, but stateful migration implementation remains
- [x] Seeded draft PR decision recorded: skipped — implementation remains in this issue-owned interactive session

## Origin

- **Created:** 2026-08-04
- **Session:** batch-2026-08-04
- **Created by:** ai-interactive (batch mode via /new-task --batch)
- **Task ref:** none

## What

Add a bounded macOS integration that detects Buzz Desktop 0.5.4, repairs OpenCode
agent records whose missing `acp` argument causes ACP initialization timeouts,
and records enough private state for a safe field-level rollback. Run the
idempotent reconciliation during interactive setup and non-interactive updates,
and expose explicit status/apply/rollback commands for operators.

## Why

Buzz Desktop 0.5.4 drops the OpenCode preset's declared `acp` argument (upstream
block/buzz#4764 and PR #4765), launching the OpenCode TUI instead of its ACP
server and timing out initialization after 60 seconds. The affected release does
not expose an agent-arguments field in its UI, so users otherwise need a custom
launcher script and later manual cleanup. Aidevops can apply a narrower,
reversible record migration automatically while preserving the app's sensitive
agent store and avoiding whole-file rollback over subsequent user changes.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The compatibility boundary, mutation scope, and rollback
contract are decided, but a stateful third-party configuration migration requires
standard implementation judgment and runtime verification.

## How (Approach)

### Files to Modify

- NEW: `.agents/scripts/buzz-desktop-helper.sh` — version detection, guarded
  status/apply/rollback/reconcile commands, atomic store mutation, private
  manifest/backup lifecycle, and app-running safety gate.
- EDIT: `setup.sh:1486-1607,1636-1731` — run bounded reconciliation after agent
  helper deployment in non-interactive update and interactive setup paths.
- EDIT: `aidevops.sh:995-1051,1711-1923` — expose `aidevops buzz`.
- NEW: `.agents/tests/test-buzz-desktop-helper.sh` — isolated fixtures for
  detection, idempotency, rollback, app-running refusal, unknown versions,
  preservation of unrelated/custom records, and setup/CLI wiring.
- EDIT: `README.md:90-115` — document the operator command and automatic setup/
  update behavior.
- EDIT: `TODO.md` and this brief — task lifecycle metadata only.

### Complete Write Surface

- **Callers/readers:** Buzz reads `~/Library/Application Support/xyz.block.buzz.app/agents/managed-agents.json`; `setup.sh` and `aidevops.sh` call the new helper.
- **Writers/mutation paths:** the new helper updates only `.agent_args` for exact OpenCode records
  with absent/empty args; Buzz remains the normal writer for every other field.
- **Tests/fixtures:** `.agents/tests/test-buzz-desktop-helper.sh` owns synthetic app, store, process, and version fixtures under an isolated HOME.
- **Schemas/config:** no schema change; the helper accepts Buzz's JSON array and preserves unknown keys. A mode-600 manifest under `~/.aidevops/state/` records affected public
  keys and original argument arrays; mode-600 backups live under an aidevops-
  owned backup directory with bounded retention.
- **Generated/deployed mirrors:** no generated source; existing agent deployment copies the helper to `~/.aidevops/agents/scripts/` before setup/update reconciliation.
- **Migrations/backfills:** both setup paths call idempotent `reconcile`; direct CLI calls route through `aidevops buzz`; only exact affected version `0.5.4` is backfilled.
- **Cleanup/rollback paths:** rollback restores only unchanged aidevops-owned `agent_args` fields;
  backups are retained for bounded recovery and never printed.

### Implementation Steps

1. Implement platform, app-version, process, store, ownership/symlink, dependency,
   and affected-record detection without reading secret values into shell output.
2. Add an atomic apply path guarded by an aidevops lock, a second process check,
   a mode-600 backup, and an exact `jq` transformation limited to OpenCode records
   with empty arguments. Persist a private manifest only after replacement.
3. Add field-level rollback that changes only manifest-listed records still set
   to `["acp"]`; preserve user-modified records and fail closed on malformed or
   mismatched state.
4. Add idempotent reconcile behavior for the known affected version. Unknown or
   future versions must not be guessed fixed; retain applied remediation until a
   future aidevops release records a verified fixed Buzz version or the operator
   explicitly rolls back.
5. Wire setup/update and CLI help/dispatch, then document the behavior.
6. Verify with isolated fixtures, ShellCheck, scoped quality checks, and one live
   apply/status cycle against the installed Buzz 0.5.4 store while Buzz is closed.

### Hazards and Compatibility

- **Concurrency/atomicity:** require Buzz stopped, acquire an aidevops-owned lock, re-check before same-filesystem atomic replacement, and never follow a symlink.
- **Migration/rollback:** the Buzz store can contain fallback plaintext credentials. Never print or copy
  its content outside mode-600 private state; tests use synthetic records only.
- **Mixed-version/backward compatibility:** preserve all unknown fields and non-target records. Existing custom arguments
  are authoritative and must never be overwritten.
- **Idempotency/retry:** apply and reconcile are idempotent; repeated setup/update calls do not add duplicate arguments or rewrite an already-applied store.
- **Partial failure/recovery:** partial failure before atomic rename leaves
  the source untouched; failure after replacement but before manifest completion
  retains the private backup and reports recovery instructions.
- Rollback is field-level, not whole-file restoration, so later Buzz edits are not
  lost. User-modified target arguments are skipped rather than overwritten.
- Linux, missing Buzz installs, unsupported versions, missing stores, and zero
  matching agents are successful no-ops.

### Verification Before Dispatch

```bash
bash .agents/tests/test-buzz-desktop-helper.sh
shellcheck .agents/scripts/buzz-desktop-helper.sh .agents/tests/test-buzz-desktop-helper.sh
bash -n setup.sh aidevops.sh .agents/scripts/buzz-desktop-helper.sh
.agents/scripts/linters-local.sh --diff
aidevops buzz status
```

- **Surface mapping:** fixture tests cover apply/rollback/reconcile and preservation; ShellCheck and `bash -n` cover helper/setup/CLI shell surfaces; `linters-local.sh --diff` covers repository policy; live status/apply verifies the installed app integration.
- **Broad verification trigger:** root CLI and setup/update orchestration change release infrastructure, so the normal local lint suite and exact-head CI are required before release.
- **Broad verification command:** `.agents/scripts/linters-local.sh`

## Acceptance Criteria

- [ ] Buzz 0.5.4 plus an empty-args OpenCode fixture is changed to `["acp"]`,
      reports applied status, and repeated reconcile makes no further change.
- [ ] Rollback restores only manifest-owned unchanged fields and leaves unrelated
      records, unknown fields, custom arguments, and later user edits untouched.
- [ ] Running Buzz, malformed/symlinked/unowned stores, and unsupported versions
      fail closed or no-op without mutating source data.
- [ ] Setup and update invoke bounded reconciliation after helper deployment;
      `aidevops buzz status|apply|rollback|reconcile` is documented and routed.
- [ ] Focused tests pass; modified shell files are syntax-clean and ShellCheck has
      zero findings; the diff quality gate passes.
- [ ] Negative regression guarantee: unsupported platforms/versions, unrelated
      agents, and custom arguments remain byte-equivalent at their JSON values.

## Context

- Installed evidence: Buzz Desktop 0.5.4, three OpenCode records with empty
  `agent_args`, Buzz stopped at discovery time. No live values were printed.
- Upstream evidence: block/buzz#4764; open fix PR #4765. The affected-version
  registry begins with exact version `0.5.4`; do not infer the first fixed release.
- Rejected approach: silently replacing `/opt/homebrew/bin/opencode` or injecting
  PATH shims would affect non-Buzz callers and create unclear ownership.
- Rejected approach: whole-store rollback could erase later user edits.
- Runtime risk is medium because this mutates configuration. Runtime verification
  uses an installed affected app with Buzz closed, after isolated tests pass.
- Seeded draft PR intentionally skipped: implementation begins immediately in the
  issue-owned interactive full-loop, so a separate seed would add no handoff value.
