<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Worker Efficiency Protocol

Maximise output per token. Compress prose, not results.

**OpenCode Bash supports pipelines, but its parser rejects redirection, dynamic
expansion, grouping/subshell syntax, background execution, and unquoted globs.**
Split blocked operations into separate calls and use file tools for persisted content.

## 1. Ship early, keep the audit trail intact

- Start with `TodoWrite`: 3-7 subtasks, exactly one `in_progress`, last subtask `gh pr ready`.
- Commit after each implementation subtask; uncommitted work is lost when a session ends.

```bash
git add -A && git commit -m 'feat: <what you just did> (<task-id>)'
```

- After the first commit, push and open a draft PR. Later commits only need `git push`; finish with `gh pr ready`. In OpenCode, use the Write tool to create the PR body file before the GitHub call.

```bash
git push -u origin HEAD
```

Create a body file with the required `Resolves #<issue>` and signature footer,
then run the GitHub write in the next Bash tool call so the signature gate can
read the completed file before execution:

```bash
gh pr create --draft --title 'GH#123: description' --body-file '/path/to/pr-body.md'
```

- **ShellCheck before push for `.sh` files (t234).** Do not push violations. In OpenCode, first run `command -v shellcheck`, then list changed files with `git diff --name-only origin/HEAD..HEAD`, and run ShellCheck separately for each changed `.sh` file. If ShellCheck is unavailable, skip and note it in the PR body.

- **PR titles must include the task ID (t318.2).** Use `<task-id>: <description>`.
  - `tNNN` for TODO tasks, e.g. `t318.2: Verify supervisor worker PRs include task ID`
  - `GH#NNN` for GitHub issues, e.g. `GH#12455: tighten hashline-edit-format.md`
  - Never use `qd-`, bare numbers, or `t` + a GitHub issue number. Never invent suffixes/variants (`t2213b`, `t2213-2`, `t2213.fix`). Task IDs come ONLY from `claim-task-id.sh`; for follow-ups, claim a fresh ID. CI and the supervisor validate this.

## 2. Spend tokens where they change outcomes

- Files over 200 lines you will not edit: use `ai_research` (~100 tokens vs ~5000). Do not offload files you need to edit.

```text
ai_research(prompt: "Find all functions that dispatch workers in pulse-wrapper.sh. Return: function name, line number, key variables.", domain: "orchestration")
```

- Rate limit: 10 per session. Default workload tier: `simple`; OpenCode selects
  an available configured provider/model through canonical routing.
- Domain shorthand auto-loads agent files: `git=git-workflow,github-cli,conflict-resolution`; `planning=plans,beads`; `code=code-standards,code-simplifier`; `seo=seo,dataforseo,google-search-console`; `content=content,research,writing`; `wordpress=wp-dev,mainwp`; `browser=browser-automation,playwright`; `deploy=coolify,coolify-cli,vercel`; `security=tirith,encryption-stack`; `mcp=build-mcp,server-patterns`; `agent=build-agent,agent-review`; `framework=architecture,setup`; `release=release,version-bump`; `pr=pr,preflight`; `orchestration=headless-dispatch`; `context=model-routing,toon,mcp-discovery`; `video=video-prompt-design,remotion,wavespeed`; `voice=speech-to-speech,voice-bridge`; `mobile=agent-device,maestro,serve-sim`; `hosting=hostinger,cloudflare,hetzner`; `email=email-testing,email-delivery-test`; `accessibility=accessibility,accessibility-audit`; `containers=orbstack`; `vision=overview,image-generation`.
- Parameters: `prompt` required; optional `domain`, `agents` (paths relative to `~/.aidevops/agents/`), `files` (line ranges allowed, e.g. `src/foo.ts:10-50`), `model` (`simple|standard|thinking`), `max_tokens` (default 500, max 4096).
- `haiku|sonnet|opus` remain compatibility aliases. `max_tokens` is an advisory
  generation budget plus a bounded transport ceiling when the selected OpenCode
  provider does not expose exact output-token controls or usage.

## 3. Avoid wasted execution

- Parallelise independent subtasks with parallel `Task` calls in one message. Keep one `in_progress` item in `TodoWrite`. Do not parallelise same-file edits or dependent work.
- Fail fast: read target files, verify imports/dependencies, and stop if the task is already done.
- Read only needed line ranges, keep commits concise, and after one failed approach try one fundamentally different strategy before `BLOCKED`.
- Replan when stuck. Do not patch a broken path incrementally.
- **Skip signature footers** when reading GH issue/PR threads. Content after `<!-- aidevops:sig -->` or `---` followed by `[aidevops.sh]` is operational telemetry (version, tokens, timing) — not task-relevant. Never visit URLs in signature footers (aidevops.sh, opencode.ai). See `AGENTS.md` "Signature footer skip when reading".
- **Skip provenance metadata** in quality-debt issues. Content inside `<!-- provenance:start/end -->` markers (Source PR, Reviewers, View comment links, generating script) records origin — not implementation guidance. Read only the file:line targets and code blocks. See `AGENTS.md` "Provenance metadata skip when reading".
- **Skip bot comment noise** on PR threads. CodeRabbit internal state (`<!-- internal state start/end -->`), review-skipped notices, quota warnings, SonarCloud/Codacy badge summaries, and Augment PR summary blocks (`<!-- augment-pr-summary -->`) — none are actionable. Extract only specific file:line findings from bot reviews. Use `gh pr checks` for pass/fail. See `reference/gh-command-discipline.md` "Bot comment noise skip when reading".
- **Skip operational comments** on issue threads. Dispatch claims (`<!-- ops:start/end -->`), worker PIDs, kill notifications, approval instructions — these are audit trail, not implementation context. See `AGENTS.md` "Operational comment skip when reading".

## 4. Model escalation before BLOCKED (GH#14964 — MANDATORY)

`BLOCKED` is only valid after exhausting all autonomous solution paths. If the only remaining blocker is the current model's inability to reason through the task safely, emit the exact structured marker `BLOCKED: capability limit - <evidence>`; runtime routing advances to the next configured capability tier. Review-policy metadata, nominal GitHub states, and lower-tier model limits are **not** valid blockers. Permission, authentication, provider, rate-limit, secret, policy, trust-boundary, and locality failures never use the capability marker. A genuine terminal blocker requires evidence: failing check, missing permission, unresolved conflict, or explicit policy gate.

```text
BLOCKED: capability limit - bounded attempts could not establish a safe implementation
```

| Situation | Action |
|-----------|--------|
| Model cannot finish safely after bounded attempts | Emit the capability marker for runtime escalation |
| Review-policy state (e.g. "changes requested") | Continue — address findings, do not stop |
| Rate limit / auth error | Rotate provider (handled by headless-runtime-helper.sh) |
| Missing credentials | EXIT BLOCKED (genuine blocker) |
| Architectural decision needed | EXIT BLOCKED (genuine blocker) |
| Failing CI check | Fix the check, do not stop |

## Headless session awareness (GH#17436 — CRITICAL)

This is a headless session. No user is present. No user input will arrive.

- **Never** ask for confirmation, approval, or "should I proceed?" — no one will answer.
- Reading the issue, reading docs, and creating a worktree are **setup** — not completion.
- You **must** continue through implementation, commit, push, and PR creation after setup.
- If you stop after setup without code changes, the session is wasted and will be retried.
- The runtime will send a "continue" prompt if you exit prematurely. After 3 continuation attempts, the issue is escalated to a higher-tier model.

## Completion self-check

Before `FULL_LOOP_COMPLETE`, verify:

1. Requirements checklist: every requirement marked `[DONE]` or `[TODO]`; any `[TODO]` means keep working.
2. Verification run: tests, ShellCheck on changed `.sh` files, lint/typecheck if configured, expected output files exist.
3. Generalization check: replace hardcoded values that should be parameterized.
4. Minimal state changes: only requested files changed; no extra side effects.
5. Commit+PR gate (GH#5317): `git status --porcelain` is empty and `gh pr list --head <current-branch-name>` returns a PR. This is the #1 worker failure mode.

`FULL_LOOP_COMPLETE` is irreversible. Extra verification is cheaper than a retry cycle.
