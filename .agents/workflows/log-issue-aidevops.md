---
description: Log an issue with aidevops to GitHub for the maintainers to address
agent: Build+
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
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Log an issue with the aidevops framework to GitHub.

**Arguments**: Optional title hint, e.g., `/log-issue-aidevops "Update check not working"`

All issues from non-collaborators are gated behind `needs-maintainer-review` — a maintainer must approve before the pipeline picks them up. This command produces higher-quality reports than the web form because it gathers diagnostics, checks duplicates, and validates before submission.

When the created issue leads to a follow-up PR, reference that issue in the PR
body with an accepted keyword: `For #NNN` or `Ref #NNN` for parent/non-closing
work, and `Resolves #NNN`, `Fixes #NNN`, or `Closes #NNN` for leaf fixes. The
repository `linked-issue-check` blocks PRs that mention an issue without one of
these keywords.

## Before Composing

**Enumerate every manual workaround you applied in the current session.** Each is a candidate fix for a systemic problem:

- File the highest-ROI workaround as the primary issue.
- File the rest as sibling issues with `See-also: #<this-issue>` cross-references.
- Add a `## Workarounds Applied` section to the primary issue body listing all workarounds.

**Workaround examples and their fix routes:**

| Workaround applied | Likely systemic fix |
|---|---|
| Applied `complexity-bump-ok` label to bypass a false-positive gate | Gate needs refinement for specific false-positive class |
| `sudo aidevops approve` to unblock auto-approved issue stuck in NMR | NMR classification logic has a gap |
| Manually ran `pre-edit-check.sh` because hook didn't fire | Hook installation or detection issue |
| `gh pr edit --base main` after an `origin:interactive` PR stacked on a feature branch | Stacked-PR retarget logic needs extending to grandchildren |

## Pre-composition Checks (MANDATORY)

Before composing any framework-bug report, run these 6 checks. They are shared with t2409 (`workflows/brief.md` "Pre-composition checks") — referenced here by pointer, not duplicated. Before auto-dispatch, use that workflow's single "Dispatch Readiness Contract (brief schema v2)" checklist and run `verify-brief-helper.sh check-readiness <brief>`.

1. **Memory recall**: `memory-helper.sh recall --query "<symptom-keywords>" --limit 5` — surface accumulated lessons before re-diagnosing a known issue. A lesson that says "same error, fixed in t2108" saves 30+ minutes.

2. **Discovery pass (t2046)**: Check if the bug was already fixed:

   ```bash
   git log --since="1 week ago" --oneline -- <suspect-files>
   gh pr list --state merged --search "<keywords>" --limit 5
   gh pr list --state open --search "<keywords>" --limit 5
   ```

   If a recent commit touches the exact file/function you're investigating, verify the bug still reproduces on HEAD before filing. Stale symptoms from a pre-deploy state (see `AGENTS.md` "Stale-symptom investigations") are not bugs — close the investigation.

3. **File:line verification**: For every file reference in the brief, run `git ls-files <path>` or `sed -n "<line>p" <path>` to confirm the reference exists and the content matches the claim. Phantom line refs force the worker to spend the first hour re-locating the code (GH#17832-17835).

4. **Tier disqualifier check**: Framework bugs are usually `tier:standard`. Cross-check the draft brief against `reference/task-taxonomy.md` "Tier Assignment Validation" disqualifiers before assigning `tier:simple`. Default to `tier:standard` when uncertain.

5. **Self-assignment awareness**: If filing via `gh_create_issue` with the `auto-dispatch` label, plan to `gh issue edit N --remove-assignee <user>` immediately after — the wrapper currently self-assigns (t2406/#19991). Alternatively, omit `auto-dispatch` until ready to hand off.

6. **Security/setup advisory suppression proof**: Before filing a false-positive issue for any setup or security advisory, require proof that the fully configured positive path cannot work. For `SYNC_PAT`, do not equate `bypass_pull_request_allowances` with the `SYNC_PAT` principal: the former is the classic `github-actions[bot]`/app bypass list, while the latter authenticates as the maintainer/admin PAT owner. A missing or empty bypass list alone is insufficient; require evidence that a correctly scoped admin/maintainer PAT cannot bypass the repo's actual protection settings.

## Workflow

### Step 1: Gather Diagnostics

```bash
~/.aidevops/agents/scripts/log-issue-helper.sh diagnostics
```

Collects: aidevops version (local + latest), AI assistant, OS/shell, repo context, `gh` CLI version.

### Step 2: Understand the Issue

Ask the user:
1. What happened?
2. What did you expect?
3. Steps to reproduce (if known)?

Use any provided argument as the title starting point. Review session context for commands, errors, and intent.

### Step 2.5: Evidence Attribution and Reproducer (framework bugs only)

For bugs with an observable failure mode, the observing session has a live reproducer context that vanishes at session end. Capture it now:

```bash
~/.aidevops/agents/scripts/log-issue-helper.sh prompt-reproducer
```

This outputs the section template. Collect and include in the issue body:

1. **Symptom**: exact command that exhibited the bug + full terminal output
2. **Expected**: what should have happened
3. **Causal code**: `git blame <file> -L <line>,<line>` output or commit SHA suspected to have introduced the regression
4. **Call-site sweep**: `rg "<function-or-pattern>" .agents/scripts/` to enumerate all affected locations
5. **Causal status**: explicitly choose `unconfirmed investigation` or `confirmed`
6. **Owning-path proof** (required for `confirmed`): the production entry point, end-to-end call chain, and an integrated test or trace that exercises that same path

For hang, timeout, rate-limit, API-budget, or transport claims, distinguish the
observed symptom from its cause. A long-running parent process proves only the
symptom. A confirmed-cause report also needs the exact blocked child command and
direct backend-state evidence captured during the failure. Without both, file an
investigation and describe candidate causes as unconfirmed. If the report says
"all calls" or equivalent, generate and include the complete executable call-site
inventory; otherwise narrow the claim to the enumerated locations.

Store the collected data under a `## Reproducer` section in the issue body (included in the compose template in Step 4).

A brief filed without a Reproducer section forces the worker to spend 30-60 min reconstructing the failure mode from scratch — the exact time cost described in GH#20008.

### Step 2.6: Workaround Enumeration

Before composing, enumerate every manual workaround you applied during the current session that relates to this bug. For each workaround:

- What was the workaround command or action?
- Does the workaround reveal a gap that should be a separate fix?
- Can it be automated so no future session needs it?

**For each workaround that has a clear systemic fix:**

- File it as a separate issue with `See-also: #<this-issue>` in its body, OR
- Add it to the `## Siblings` section of the current brief

### Step 3: Check for Duplicates

**3a — Keyword search (catches semantic duplicates):**

```bash
gh issue list -R marcusquinn/aidevops --state all --search "KEYWORDS" --limit 10
```

If duplicates found, present them and ask: add comment to existing / create new / review first.

> **Note on indexing lag:** GitHub's search index has a 2–10 second lag after an issue is created. This step catches semantic matches in existing issues but cannot detect an identical issue filed seconds ago in the same session. The deterministic fingerprint check at Step 5.5 closes that gap — do not skip it.

### Step 3.5: Customization Routing

Before filing, check whether this is a customization need rather than a framework issue:

| User says | Likely route |
|-----------|-------------|
| "My script edits get overwritten" | Customization — use `~/.aidevops/agents/custom/scripts/` |
| "I want X to behave differently" | Customization — create a wrapper in `custom/` |
| "I added an agent but it disappeared" | Customization — use `custom/` or `draft/` (root agents are overwritten) |
| "This script is broken for everyone" | Bug — file an issue |
| "The framework should support X" | Enhancement — file an issue (maintainers assess fit) |

If the need is customization, explain the `custom/` directory and link to `reference/customization.md`. Do not file an issue.

### Step 3.6: Performance and Causal Attribution Validation

For every hang, timeout, rate-limit, API-budget, or transport-cause claim—even
when it is not a performance report—require the blocked command/process-tree
evidence and backend state described in Step 2.5. If either is unavailable, do
not assert the cause: file an investigation brief with the suspected cause marked
unconfirmed.

The remaining checks are mandatory for performance/optimization claims:

If the issue involves performance, optimization, O(n^2) claims, or "hot path" assertions:

1. **Verify line references**: Read the cited file at the cited line number. If the code at that line does not match the claim, REJECT the issue. Do not file issues with hallucinated line numbers.
2. **Require measurements**: "May cause O(n^2)" is not evidence. Require actual timing data (`time`, `hyperfine`, profiling output). No measurements = no issue.
3. **Verify data scale**: Check how many items the loop actually processes and how often it runs. A loop over 5 items on a 60-second timer is not a performance problem regardless of algorithmic complexity.
4. **Check for template-driven findings**: If the user or AI is filing multiple performance issues with identical structure ("nested loops", "O(n^2)", "hot path") across different files, this is likely a batch code scan without verification. Validate each independently.
5. **Cache / API-budget causality proof**: If the claim involves cache poisoning, GitHub rate limits, GraphQL budget exhaustion, REST fallback, or API-call pressure, require evidence that links the observed symptom to backend calls. Include the exact command shape, return code, stdout byte count, cache hit/miss/store/stale/bypass telemetry, and backend call counts before/after a repeated identical call.
6. **Exact-output empty-result guard**: For exact-output caches, successful empty stdout can be the correct cached value (for example, `gh pr list --jq '.[].number // empty'` on an empty result set). A 0-byte cache file alone is not cache poisoning. Only file a bug when the report proves that empty stdout is semantically invalid for the command or that cache metadata/sentinel handling cannot distinguish corruption from a valid empty result.
7. **Symptom vs root cause**: If the evidence only shows many cache files, 0-byte files, or a rate-limit event without hit/miss/backend-call correlation, do not file a fix issue. File an investigation brief instead, asking for call-shape telemetry and a before/after API-budget measurement.

If any check fails, explain why and do not file the issue. Direct the user to the "Performance Optimization" issue template which requires mandatory evidence fields.

### Step 3.7: Architectural Alignment (enhancements only)

Skip for bugs with clear reproduction steps — bugs are observed failures and belong in the tracker.

For enhancements, feature requests, and architectural changes, evaluate against:

- **Observed failure first**: Is this addressing an actual failure, or preemptive? Preemptive rules are prompt bloat.
- **Intelligence over determinism**: Does this add a deterministic gate where model judgment would work better?
- **Prompt cost**: Every instruction has a per-turn cost. Is the value worth it?
- **External pattern adoption**: A "gap" vs another framework may be a deliberate omission in an intelligence-first design.

If the proposal doesn't survive these questions, discuss before filing — it may be better as a memory entry.

### Step 4: Compose the Issue

For framework bugs, use this expanded template that includes Evidence Attribution and Reproducer sections:

````markdown
## Description

{problem}

## Expected Behavior

{what should have happened}

## Reproducer

**Symptom command**:

```
{exact command that exhibited the bug}
```

**Actual output**:

```
{full terminal output}
```

**Expected output**:

{what should have happened}

**Causal status**: {unconfirmed investigation | confirmed}

**Owning-path proof**:

- **Production entry point**: {file:line and command/event that enters the owning path}
- **Call chain**: {end-to-end calls from entry point to observed failure}
- **Integrated verification**: {test or trace exercising that production path}

**Causal code** (if identified):

```bash
{git blame output or commit SHA}
```

## Steps to Reproduce

1. {step}

## Workarounds Applied

{list each workaround used during the observing session}

## Environment

{diagnostics output}

## Additional Context

{errors, session context}
````

For non-bug reports (enhancements, questions), use the shorter template without Reproducer and Workarounds sections:

```markdown
## Description

{problem or request}

## Expected Behavior

{what should happen}

## Steps to Reproduce

1. {step, if applicable}

## Environment

{diagnostics output}

## Additional Context

{errors, session context}
```

### Step 5: Confirm Before Submitting

Show the user: title, body preview, label. Offer: create / edit title / edit description / cancel.

### Step 5.5: Fingerprint Pre-Check (deterministic dedup)

Before creating the issue, run a fingerprint check against this session and prior sessions.
This check is not subject to GitHub's search index lag — it reads a local state file.

```bash
~/.aidevops/agents/scripts/log-issue-helper.sh check-fingerprint "EXACT_TITLE" "EXACT_BODY"
```

Replace `EXACT_TITLE` and `EXACT_BODY` with the title and body from Step 4/5.

**If output is `OK`**: proceed to Step 6.

**If output starts with `DUPLICATE:NNN:SECONDS`** (e.g., `DUPLICATE:20312:8`):
- **Do NOT create a new issue.** The body hash matches issue #NNN filed NNN seconds ago.
- Inform the user: "Issue #NNN was already filed NNN seconds ago with an identical body."
- Offer the user:
  1. View the existing issue: `gh issue view NNN -R marcusquinn/aidevops`
  2. Add a comment to the existing issue (if new information has emerged)
  3. Proceed with a new issue only if the user explicitly confirms a different scope is intended

This step is **MANDATORY** — it is the primary guard against the indexing-lag race window
documented in GH#20322. Do not skip it even if Step 3 returned no results.

### Step 6: Create the Issue

First, use the runtime Write tool—not Bash, a heredoc, or shell redirection—to
create `aidevops-issue-body.md` at a fully resolved absolute path beneath
`${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}`. Write only the
approved `BODY_CONTENT`; the managed GitHub wrapper signs a private copy before
posting.

Then use a separate Bash tool call to post the already-created file. Do not
combine body-file creation and the `gh issue create` write in one call.

For framework bugs, validate that final body file immediately before posting.
Do not validate an earlier draft or inline copy:

```bash
~/.aidevops/agents/scripts/log-issue-helper.sh validate-brief \
  "/absolute/path/to/aidevops-issue-body.md"
```

If validation fails, correct the evidence or explicitly reframe the report as an
unconfirmed investigation. Do not run `gh issue create` until validation passes.

The aidevops `gh` PATH shim repeats this final-body validation at exec time for
non-tracking framework-bug reports targeting `marcusquinn/aidevops`. This is a
deterministic backstop for raw and wrapped `gh issue create` calls, not a
replacement for the workflow check above. A blocked write leaves the caller's
body file unchanged; apply the validator's remediation and retry. Internal
`tNNN:` / `GH#NNN:` tracking tasks and non-bug issue shapes are exempt.

```bash
gh issue create -R marcusquinn/aidevops \
  --title "TITLE" \
  --body-file "/absolute/path/to/aidevops-issue-body.md" \
  --label "LABEL"
```

### Step 6.5: Record Fingerprint

After a successful `gh issue create`, extract the issue number from the URL and record the fingerprint
so future sessions can detect this as a duplicate:

```bash
# Extract issue number from the URL (e.g., https://github.com/marcusquinn/aidevops/issues/20312 → 20312)
ISSUE_NUMBER=<number from created issue URL>
~/.aidevops/agents/scripts/log-issue-helper.sh record-fingerprint "EXACT_TITLE" "EXACT_BODY" "$ISSUE_NUMBER"
```

This writes to `~/.aidevops/state/log-issue-fingerprints.jsonl`. On transient failures where
`gh issue create` may have succeeded server-side, re-running the command will be caught by the
Step 5.5 fingerprint check within the dedup window (default: 120 seconds, configurable via
`LOG_ISSUE_DEDUP_WINDOW_SECONDS`).

### Step 7: Confirm Success

Output the issue URL. Note: user can add comments, subscribe to notifications, or reference with `Fixes #NNN`.

## Label Selection

| Issue Type | Label |
|------------|-------|
| Something broken | `bug` |
| New feature request | `enhancement` |
| Question/help needed | `question` |
| Documentation issue | `documentation` |
| Performance problem | `performance` |

## Privacy

Diagnostics do NOT include credentials or tokens. File paths are included (may reveal username). No file contents uploaded. User reviews everything before submission.

## Error Handling

- `gh` not authenticated: prompt `gh auth login`, then retry.
- Network failure: prompt user to check connection and retry.
