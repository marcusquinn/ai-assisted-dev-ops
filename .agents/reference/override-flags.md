---
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
---
# Override / Bypass Flag Reference

> **Context:** The t2377 data-loss bug (GH#19847) was caused by `FORCE_ENRICH=true`
> silently bypassing ALL content-preservation logic with no audit log, no rationale
> check, and no safety floor. This matrix catalogues every operator-facing bypass flag
> in the framework so the pattern is never repeated silently.
>
> **Columns:** Each flag is evaluated against four criteria from the issue rubric:
> - **Owner** — who/what sets this flag (operator, CI, auto-triggered script)
> - **Bypasses** — which specific checks or gates are skipped
> - **Logged?** — is there an `info_log`/`warn_log`/`print_warning` at the bypass site?
> - **Floor?** — is there a minimum invariant the bypass must still respect?
> - **Test coverage** — is the bypass path covered by a regression test?
>
> Discovery command:
>
> ```bash
> rg "FORCE_\w+|SKIP_\w+|OVERRIDE_\w+|BYPASS_\w+|AIDEVOPS_.*_DISABLE" \
>     .agents/scripts/ .agents/hooks/ -l
> ```

---

## High-Risk Bypass Flags (bypass safety checks on data or secrets)

| Flag | Owner file(s) | Bypasses | Logged? | Floor? | Test coverage |
|---|---|---|---|---|---|
| `FORCE_ENRICH` | `issue-sync-helper.sh:988`, `pulse-dispatch-core.sh:1151` | Content-preservation gate in `_enrich_update_issue` — skips brief-file check, sentinel check, and external-body preservation | ✅ log added (t2377 audit) | ✅ Layer 2 (t2377): refuses empty title, empty body, or a stub title beginning with `tNNN:` regardless of flag | ✅ `test-enrich-no-data-loss.sh`, `test-brief-inline-classifier.sh` |
| `FORCE_PUSH` | `issue-sync-helper.sh:831` | CI-only gate for bulk issue creation from TODO.md — allows local push outside GitHub Actions | ✅ log added (t2377 audit) | ❌ No dedup guard against concurrent local+CI push (both see "no existing issue") — document: use `push <task_id>` (single-task path) instead | ❌ No dedicated bypass test |
| `FORCE_CLOSE` | `issue-sync-helper.sh:526` | Evidence check (`_has_evidence`) before closing an issue — requires merged PR or `verified:` field | ✅ log added (t2377 audit) | ✅ `gh issue close` fails if issue does not exist; data-loss floor is the GitHub API itself | ❌ No dedicated bypass test |
| `AIDEVOPS_VM_SKIP_BUMP_VERIFY` | `version-manager-release.sh:86` | `_verify_bump_commit_at_ref HEAD` check — allows tagging a non-bump commit | ✅ log added (t2377 audit) | ✅ git tag command fails if tag already exists; only bypasses pre-condition check | ✅ `test-version-manager-bump-verify.sh` (covers guard; not the bypass itself) |
| `TASK_ID_GUARD_DISABLE` | `.agents/hooks/task-id-collision-guard.sh:40` | Pre-commit hook that verifies `tNNN` task IDs are claimed via `claim-task-id.sh` | ✅ `[task-id-guard][INFO] TASK_ID_GUARD_DISABLE=1 — bypassing` | ✅ git commit proceeds normally; only the ID-collision check is skipped | ✅ `test-task-id-collision-guard.sh` |
| `PRIVACY_GUARD_DISABLE` | `.agents/hooks/privacy-guard-pre-push.sh:32` | Pre-push hook that blocks private repo slugs in public-facing files | ✅ `[privacy-guard][INFO] PRIVACY_GUARD_DISABLE=1 — bypassing` | ✅ git push proceeds normally; only the slug-scan is skipped | ✅ `test-privacy-guard.sh` (via `install-pre-push-guards.sh`) |
| `COMPLEXITY_GUARD_DISABLE` | `.agents/hooks/complexity-regression-pre-push.sh:44` | Pre-push hook that blocks new complexity violations (function >100 lines, nesting >8, file >1500 lines) | ✅ `COMPLEXITY_GUARD_DISABLE=1 — bypassing` | ✅ git push proceeds; only complexity regression check is skipped | ✅ `test-complexity-guard-parallel.sh`, `test-complexity-guard-baseline.sh` |
| `AIDEVOPS_PREPUSH_REPO_VERIFY` | `.agents/hooks/repo-verify-pre-push.sh:50` | Pre-push hook (t3224) that runs target repo's declared `format`/`lint`/`typecheck` before push, with optional auto-fix-and-amend | ✅ `[repo-verify][INFO] AIDEVOPS_PREPUSH_REPO_VERIFY=0 — bypassing` | ✅ git push proceeds; CI still runs format/lint/typecheck | ✅ `test-repo-verify-pre-push-hook.sh` |
| `AIDEVOPS_PREPUSH_AUTOFIX` | `.agents/hooks/repo-verify-pre-push.sh:106` | Modifier (not bypass): `0` disables the autofix-and-amend path, `1` forces it on. Default: ON in headless contexts, OFF interactive | ✅ `[repo-verify][INFO] format autofix skipped (AIDEVOPS_PREPUSH_AUTOFIX=0)` | ✅ Verify still runs; only the autofix step is gated | ✅ `test-repo-verify-pre-push-hook.sh` |

---

## Dispatch / Eligibility Bypass Flags

| Flag | Owner file(s) | Bypasses | Logged? | Floor? | Test coverage |
|---|---|---|---|---|---|
| `AIDEVOPS_SKIP_PREDISPATCH_ELIGIBILITY` | `pre-dispatch-eligibility-helper.sh:194` | Pre-dispatch eligibility gate — checks issue closed state, `status:done`/`status:resolved` labels, recently merged linked PR | ✅ `[dispatch-precheck] AIDEVOPS_SKIP_PREDISPATCH_ELIGIBILITY=1 — bypassing` | ✅ Fail-open on API errors anyway; skip is emergency escape only | ✅ `test-pre-dispatch-eligibility.sh` |
| `AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR` | `pre-dispatch-validator-helper.sh:271` | Per-generator pre-dispatch validators for auto-generated issues | ✅ `AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1 — skipping validator for #N` | ✅ Validator failure is non-fatal by design; skip removes the check entirely | ✅ `test-pre-dispatch-validator.sh` |
| `AIDEVOPS_SKIP_TIER_VALIDATOR` | `tier-simple-body-shape-helper.sh` | Explicit `tier:simple` execution-contract enforcement — allows dispatch of a simple-labelled issue without the contract guard | ✅ `AIDEVOPS_SKIP_TIER_VALIDATOR=1 — bypassing check for #N` | ✅ Worker dispatched regardless; only the normalization is skipped | ✅ `test-tier-simple-body-shape.sh` |
| `SKIP_FRAMEWORK_ROUTING_CHECK` | `claim-task-id.sh:1329` | Framework routing warning that alerts when a framework-level task is filed in a project repo | ✅ log added (t2377 audit) | ✅ ID allocation proceeds normally; only the routing warning is suppressed | ❌ No dedicated test for bypass path |

---

## Verification / Testing Bypass Flags

| Flag | Owner file(s) | Bypasses | Logged? | Floor? | Test coverage |
|---|---|---|---|---|---|
| `AIDEVOPS_SKIP_VERIFY` | `verify-operation-helper.sh:451` | All operation verification (tamper-evident audit logging of operations) | ✅ `log_warn "Verification skipped (AIDEVOPS_SKIP_VERIFY=1)"` | ✅ Documented as "not recommended"; audit log records skip itself | ✅ Internal to verify-operation-helper |
| `SKIP_MERGE_CHECK` | `task-complete-helper.sh:714` | PR merge status check before marking a task complete | ✅ `log_warn "Skipping PR merge check (--skip-merge-check). Use only in tests."` | ✅ warn_log makes intent explicit; floor is CLI restriction (flag only via --skip-merge-check) | ✅ Implicit via `test-task-complete-move.sh` |
| `AIDEVOPS_VM_SKIP_BUMP_VERIFY` | `version-manager-release.sh:86` | Bump-commit verification before creating a release tag | ✅ log added (t2377 audit) | ✅ git tag creation still fails if tag already exists; only pre-condition guard is bypassed | ❌ No dedicated bypass test |

---

## Hook / Pre-Loop Bypass Flags

| Flag | Owner file(s) | Bypasses | Logged? | Floor? | Test coverage |
|---|---|---|---|---|---|
| `SKIP_PREFLIGHT` | `full-loop-helper.sh:120` | Preflight quality-check phase in the AI full-loop | ✅ `print_warning "Preflight skipped"` + `PREFLIGHT_SKIPPED` promise | ✅ No code changes are made during preflight; skip only affects quality reporting | ❌ No dedicated test (full-loop prompt generation) |
| `SKIP_POSTFLIGHT` | `full-loop-helper.sh:141` | Postflight release-health verification phase | ✅ `print_warning "Postflight skipped"` + `POSTFLIGHT_SKIPPED` promise | ✅ Work is already committed/merged before postflight; skip only affects health check | ❌ No dedicated test (full-loop prompt generation) |
| `SKIP_RUNTIME_TESTING` | `full-loop-helper.sh:298,371` | Exported to AI agent context to signal "do not run tests in this loop session" | ✅ Exported value visible in `status` output (`skip_runtime_testing: true`) | ✅ Flag is advisory to the AI, not a code bypass; no hard gate is skipped | ❌ No dedicated test (prompt-level, not code-level gate) |

---

## Worktree / Session Bypass Flags

| Flag | Owner file(s) | Bypasses | Logged? | Floor? | Test coverage |
|---|---|---|---|---|---|
| `AIDEVOPS_SKIP_AUTO_CLAIM` | `worktree-helper.sh:587`, `full-loop-helper.sh:260` | Auto-claim of GitHub issues when creating a worktree (GH#20102) | ✅ log added (t2377 audit) | ✅ Existing interactive-session-helper.sh claim path unaffected; only auto-trigger skipped | ✅ `test-worktree-auto-claim.sh` (Test 7) |
| `WORKTREE_FORCE_REMOVE` | `worktree-helper.sh:927` | Ownership check before worktree removal (t189) | ✅ `print_warning "--force specified, proceeding with removal"` | ✅ Ownership error is shown before proceeding; requires explicit operator intent | ❌ No dedicated test for force-remove bypass |

---

## Sandbox / Runtime Environment Flags

| Flag | Owner file(s) | Bypasses | Logged? | Floor? | Test coverage |
|---|---|---|---|---|---|
| `AIDEVOPS_HEADLESS_SANDBOX_DISABLED` | `headless-runtime-helper.sh:473,573` | Sandbox wrapper for headless workers — falls back to bare `timeout` command | ✅ log added (t2377 audit) | ✅ `timeout` still enforces wall-clock limit; only privilege isolation is removed | ❌ No dedicated test for sandbox-disable path |
| `AIDEVOPS_BASH_REEXECED` | `shared-constants.sh:48,68` | Bash re-exec guard — prevents infinite re-exec loop when modern bash is found | ✅ Implicit: set before `exec`, cleared immediately on bash 4+ (t2201 — no log needed; this is anti-loop internal state, not an operator bypass) | ✅ The anti-loop property holds: flag is cleared on bash 4+, preventing double-guard fire | ✅ `test-bash-reexec-guard.sh` |
| `AIDEVOPS_HEADLESS` / `FULL_LOOP_HEADLESS` / `Claude_HEADLESS` / `GITHUB_ACTIONS` | multiple (pre-edit-check.sh, full-loop-helper.sh, interactive-session-helper.sh) | Mode-detection flags — enable headless-only code paths (e.g., main-branch allowlist for TODO.md). **Not bypass flags** — they activate, not disable, safety gates. | ✅ Each check site tests the env var and routes to different code path | ✅ Headless paths have their own gates (CI-authority rule, pre-edit allowlist) | ✅ `test-pulse-wrapper-headless-export.sh`, `test-stats-wrapper-headless-export.sh` |

---

## Pulse / LLM Supervisor Flags

| Flag | Owner file(s) | Bypasses | Logged? | Floor? | Test coverage |
|---|---|---|---|---|---|
| `PULSE_FORCE_LLM` | `pulse-wrapper.sh:1354` | LLM-supervisor skip condition — forces a daily-sweep LLM run regardless of backlog progress | ✅ `[pulse-wrapper] Skipping LLM supervisor (backlog progressing...)` logged on skip; force path sets `llm_trigger_mode="daily_sweep"` | ✅ LLM lock (mkdir-based) prevents concurrent LLM sessions | ❌ No dedicated test for force-LLM path |
| `FAST_FAIL_SKIP_THRESHOLD` | `pulse-fast-fail.sh:549` | Threshold for hard-stopping dispatch to a repeatedly-failing issue | ✅ `[pulse-wrapper] fast_fail_is_skipped: HARD STOP count=N>=threshold` logged | ✅ Threshold is a configurable number; hard stop remains at the configured value | ✅ `test-fast-fail-age-out.sh` |
| `AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE` | `pulse-merge-conflict.sh:147,239` | Controls idle-PR handover: `off` = never handover, `detect` = log only, `enforce` = apply label | ✅ All modes log their decisions; `off` returns early; `detect` logs `would-handover`; `enforce` logs label application | ✅ `no-takeover` label is always respected even in enforce mode | ✅ `test-pulse-merge-interactive-handover.sh` |

---

## Scanner Configuration Flags (tuning, not bypasses)

| Flag | Owner file(s) | Bypasses | Logged? | Floor? | Test coverage |
|---|---|---|---|---|---|
| `CONTENT_SCANNER_SKIP_PREFILTER` | `content-scanner-helper.sh:187` | Keyword pre-filter optimisation — when `true`, always proceeds to full scan (more thorough, not less) | ✅ Implicit: skip causes _more_ scanning, not less; no bypass log needed | ✅ By construction: disabling the pre-filter expands coverage | ❌ No dedicated test (optimisation flag, not safety flag) |
| `CONTENT_SCANNER_SKIP_NORMALIZE` | `content-scanner-helper.sh:235` | NFKC unicode normalization before injection scan | ✅ log added (t2377 audit) | ✅ Pattern matching still runs on unnormalised input; only bypasses evasion-resistance hardening | ❌ No dedicated test (rarely set; scanning still runs) |
| `NESTING_DEPTH_FORCE_AWK` | `scanners/nesting-depth.sh:63` | Forces AWK fallback backend for nesting-depth scanner (disables shfmt) | ✅ Implicit in function name: `_nd_shfmt_available()` returns false, causing AWK path; test-only flag | ✅ AWK path still computes nesting depth; only backend changes | ✅ `test-nesting-depth-scanner.sh:293` |
| `FORCE_VACUUM_SIZE_MB` | `opencode-db-maintenance-helper.sh:408` | Threshold above which SQLite VACUUM always runs | ✅ `print_info "Step 3/3: VACUUM skipped (low fragmentation: ... < FORCE_VACUUM_SIZE_MB MB)"` on skip | ✅ VACUUM is never harmful; threshold only controls when it's required | ✅ `test-opencode-db-maintenance.sh` |
| `AIDEVOPS_SCAN_STALE_AUTO_RELEASE` | `interactive-session-helper.sh:1204` | Whether stale dead-PID claims are auto-released on session start | ✅ Behavior described in startup scan output | ✅ Manual release path always available even when auto-release is disabled | ✅ `test-scan-stale-auto-release.sh` |
| `STAMPLESS_INTERACTIVE_AGE_THRESHOLD` | `pulse-wrapper.sh` (normalize path) | Threshold (hours) before stampless interactive claims are auto-recovered | ✅ Documented in AGENTS.md; recovery logs the threshold | ✅ Recovery is additive (label cleanup); no content is deleted | ✅ `test-stampless-non-task-filter.sh` |
| `BUNDLE_SKIP_GATES` | `linters-local.sh:1864` | Per-bundle linter gate skip list (from `.aidevops/bundles/*.json`) | ✅ `print_info "Skipping '${gate_name}' (bundle skip_gates)"` at each skipped gate | ✅ Only affects which linter gates run in a given bundle context | ❌ No dedicated test for BUNDLE_SKIP_GATES |

---

## Flags Safe by Construction (not bypass flags)

The following flags were found by the discovery command but are **not bypass flags** — they
are mode-detection signals, threshold tuning parameters, or CLI flags that select different
(but equivalent) code paths:

- `AIDEVOPS_AUTO_UPGRADE_BASH` — controls whether `bash-upgrade-helper.sh` installs/upgrades
  bash; `0` means "don't auto-install", not "bypass a safety check"
- `OVERRIDE_CONF` / `OVERRIDE_ENABLED` / `OVERRIDE_DEFAULT` — dispatch-override config keys
  (per-runner claim filtering); these are routing policy, not safety bypass
- `FORCE_AWK` / `NESTING_DEPTH_FORCE_AWK` — selects AWK backend instead of shfmt; both backends
  compute the same metric
- `FORCE_HOTFIX_BANNER` — forces hotfix banner display in update-check; CI/test helper
- `FORCE_PHASE2` — forces efficiency-analysis Phase 2 in `efficiency-analysis-runner.sh`; no
  safety gate is skipped
- `SKIP_COUNT` — skip-count argument in `verify-brief.sh`/`test-ocr-extraction-pipeline.sh`;
  internal function parameter, not a global bypass env var
- `SKIP_LABEL` — the string value of the `skip-review-gate` label in `review-bot-gate-helper.sh`;
  not an env var, it's a constant label name
- `SKIP_PATTERN` — `_LFG_SKIP_PATTERN` in `pulse-dispatch-large-file-gate.sh`; a regex constant
  for file extensions to exclude from large-file gate (lockfiles, JSON, YAML)
- `SKIP_FOR_REF` / `SKIP_RANGE` — test-internal variables in `test-pulse-auto-complete-keywords.sh`
- `SKIP_LIST` — list of MCP servers to skip in `mcp-register-claude.sh`; internal list variable
- `SD_SKIP_GITHUB` — stuck-detection-helper.sh GitHub-ops skip for offline testing ✅ logged
- `CB_SKIP_GITHUB` — circuit-breaker-helper.sh GitHub issue creation skip for testing ✅ logged

---

## Summary: Findings from t2377 Audit

### ❌ Logged → Fixed in this PR (t2377 audit, GH#20146)

The following bypass sites lacked an `info_log` call and were fixed:

1. `FORCE_ENRICH` in `issue-sync-helper.sh:988` — added `print_info` at the bypass entry point
2. `FORCE_PUSH` in `issue-sync-helper.sh:831` — added `print_info` when bypassing CI-only gate
3. `FORCE_CLOSE` in `issue-sync-helper.sh:526` — added `print_info` when bypassing evidence check
4. `AIDEVOPS_VM_SKIP_BUMP_VERIFY` in `version-manager-release.sh:86` — added `print_info` when skipping bump-commit verification
5. `SKIP_FRAMEWORK_ROUTING_CHECK` in `claim-task-id.sh:1329` — added `log_info` on early return
6. `AIDEVOPS_HEADLESS_SANDBOX_DISABLED` in `headless-runtime-helper.sh:473,573` — added `print_info` when falling back to bare timeout
7. `AIDEVOPS_SKIP_AUTO_CLAIM` in `worktree-helper.sh:587` — added `print_info` on skip
8. `CONTENT_SCANNER_SKIP_NORMALIZE` in `content-scanner-helper.sh:235` — added note that normalization was skipped

### ❌ Floor → Addressed

- `FORCE_PUSH`: no floor exists; documented in matrix that the single-task path (`push <task_id>`)
  is the safe alternative. A hard dedup floor would require a GitHub API round-trip per push, which
  conflicts with the offline-capable design. Accepted risk documented.
- All other flags: floors exist by construction (see matrix) or are safe-by-construction (scanner
  flags, mode flags).

### ❌ Test coverage → New tests added (GH#20146)

New regression tests in `.agents/scripts/tests/test-override-flags.sh`:

1. `FORCE_PUSH` bypass path — verifies `print_info` fires and bulk push proceeds
2. `FORCE_CLOSE` bypass path — verifies `print_info` fires and evidence check is skipped
3. `AIDEVOPS_VM_SKIP_BUMP_VERIFY` — verifies bypass log and that tag gate proceeds
4. `AIDEVOPS_HEADLESS_SANDBOX_DISABLED` — verifies log fires when sandbox is disabled
5. `SKIP_FRAMEWORK_ROUTING_CHECK` — verifies log fires and function returns 0

### No action needed

- `CONTENT_SCANNER_SKIP_PREFILTER` — disabling the pre-filter expands coverage (safer, not less safe)
- Headless mode flags (`AIDEVOPS_HEADLESS` etc.) — mode detection, not bypass flags
- `AIDEVOPS_BASH_REEXECED` — internal anti-loop guard; logs not needed (transparency is in the code)
- BUNDLE_SKIP_GATES — already logs each skipped gate by name
