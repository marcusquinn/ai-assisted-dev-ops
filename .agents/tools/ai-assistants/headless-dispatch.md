---
description: Headless dispatch patterns for parallel AI agent execution via OpenCode
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Headless Dispatch

<!-- AI-CONTEXT-START -->

## Quick Reference

- **One-shot**: `opencode run "prompt"` | **Warm server**: `opencode run --attach http://localhost:4096 "prompt"`
- **Server**: `opencode serve [--port 4096]` | **SDK**: `npm install @opencode-ai/sdk`
- **Runners**: `runner-helper.sh [create|run|status|list|stop|destroy]` → `~/.aidevops/.agent-workspace/runners/`
- **Model override**: `opencode run -m openrouter/anthropic/claude-sonnet-4-6 "Task"` | Auth: `opencode auth login`

**Use for**: parallel tasks, scheduled/cron AI work, CI/CD, chat-triggered dispatch (Matrix/Discord/Slack via OpenClaw), background tasks.
**Don't use for**: interactive dev (use TUI), frequent human-in-the-loop, single quick questions.
**Diagnostics**: When workers fail, stall, or loop: `reference/worker-diagnostics.md`.

**Draft agents**: Share domain instructions across workers via `~/.aidevops/agents/draft/`. See `tools/build-agent/build-agent.md`.
**Remote dispatch**: `tools/containers/remote-dispatch.md` (SSH/Tailscale with credential forwarding).

> **Issue-backed workers:** use `dispatch-single-issue-helper.sh dispatch NUMBER OWNER/REPO`. It keeps ownership ceremony and runner identity transport coupled. Use `headless-runtime-helper.sh run` directly only for non-issue jobs; never use bare `opencode run` for managed dispatch (GH#5096).

<!-- AI-CONTEXT-END -->

## Security

1. **Network**: `--hostname 127.0.0.1` (default) | Set `OPENCODE_SERVER_PASSWORD` for network exposure
2. **Permissions**: `OPENCODE_PERMISSION` env var for headless autonomy (`'{"*":"allow"}'` for CI/CD)
3. **Credentials**: Never pass secrets in prompts — use environment variables. Delete sessions after use.
4. **Scoped tokens** (t1412.2): Workers get minimal-permission GitHub tokens (`contents:write`, `pull_requests:write`, `issues:write`) scoped to target repo. Flow: `worker-token-helper.sh create --repo owner/repo --ttl 3600` → `GH_TOKEN` env → worker executes → `worker-token-helper.sh revoke`. GitHub App installation tokens (repo-scoped, 1h TTL) or delegated tokens (configurable TTL). Disable: `WORKER_SCOPED_TOKENS=false`. Setup: `https://github.com/settings/apps/new` → Contents/PRs/Issues R&W → configure `~/.config/aidevops/github-app.json` (600 perms).
5. **Worker sandbox** (t1412.1): Fake HOME — only `.gitconfig`, `GH_TOKEN`, `.aidevops/` symlink (read-only), MCP config, writable XDG dirs. No `~/.ssh/`, gopass, `credentials.sh`, cloud/publish tokens, browser profiles. `WORKER_SANDBOX_ENABLED=true` (default). CLI: `worker-sandbox-helper.sh create <task_id>` → auto-clean on exit.
6. **Network tiering** (t1412.3): recognized direct clients use 5-tier domain classification. Tier 5 is denied and Tier 4 is flagged. This is command-level policy, not containment for arbitrary interpreter scripts/custom binaries; use an enforcing proxy/container/firewall backend for that threat model. Config: `configs/network-tiers.conf`. See `network-tier-helper.sh`.

## Dispatch Methods

```bash
opencode run "Review src/auth.ts for security issues"       # one-shot
opencode run -m anthropic/claude-sonnet-4-6 "Task"          # model override
opencode run --agent plan "Analyze the database schema"     # agent override
opencode run -f ./schema.sql "Generate types"               # file context
opencode run -c "Continue" | -s ses_abc123 "Add handling"   # resume session
```

**Warm server**: `opencode serve --port 4096` once, then `opencode run --attach http://localhost:4096 "Task"` (avoids MCP cold boot).

**SDK**: `import { createOpencode } from "@opencode-ai/sdk"` → `createOpencode({ port: 4096 })`. Connect: `createOpencodeClient({ baseUrl: "http://localhost:4096" })`.

**HTTP API**: `tools/ai-assistants/opencode-server.md`. Key: `POST /session` → `POST /session/$ID/message`. Async: `POST .../prompt_async` (204). SSE: `GET /event`. Fork: `POST /session/$ID/fork`. No-reply: `noReply:true`.

## Parallel Execution (t1419)

**Stagger manual launches by 30-60s** to avoid thundering herd (RAM exhaustion, API rate limiting, MCP cold boot storms). Pulse supervisor handles staggering automatically (`RAM_PER_WORKER_MB`, `RAM_RESERVE_MB`, `MAX_WORKERS_CAP`).

```bash
HELPER="$(aidevops config get paths.agents_dir | sed "s|^~|$HOME|")/scripts/dispatch-single-issue-helper.sh"
for issue in 42 43 44; do
	$HELPER dispatch "$issue" owner/repo
  sleep 30
done
```

**Monitoring**: `worker-watchdog.sh --status` (active) | `--install` (launchd hung/idle detection with transcript-tail inspection). **SDK**: `Promise.all` for concurrent sessions, SSE via `client.event.subscribe()`.

## Runners and Custom Agents

**Runners**: Named, persistent agent instances at `~/.aidevops/.agent-workspace/runners/<name>/` with `AGENTS.md`, `config.json`, optional `memory.db`. CLI: `runner-helper.sh create|run|status|list|destroy`. Memory: `memory-helper.sh store/recall --namespace "runner-name"`. Inter-runner: `mail-helper.sh send --to/--from`. Templates: `tools/ai-assistants/runners/` ([README](runners-README.md)).

**Custom agents**: Define via `.opencode/agents/<name>.md` or `opencode.json` with frontmatter controlling `tools`, `permission`, `model`, `temperature`. Example: restrict to read-only git commands with `permission: { bash: { "git diff*": allow, "*": deny } }`. Usage: `opencode run --agent <name> "prompt"`.

## Model Providers

`opencode auth login` for setup. Override: `opencode run -m openrouter/anthropic/claude-sonnet-4-6 "Task"`.

**OAuth-aware routing (t1163)**: `SUPERVISOR_PREFER_OAUTH=true` (default) routes Anthropic requests through Claude CLI if OAuth available (zero marginal cost). Non-Anthropic → `opencode`. Override: `SUPERVISOR_CLI=opencode`. Detection: `~/.claude/` credentials, cached 5 min. Budget: `budget-tracker-helper.sh configure claude-oauth --billing-type subscription`.

## Worker Uncertainty Framework

**Proceed autonomously** (document in commit): inferable from context/conventions, only affects own task scope, multiple valid approaches (pick simplest), style ambiguity (follow conventions), equivalent patterns (match precedent), minor adjacent issues (note in PR body).

**Exit BLOCKED**: contradicts codebase, breaks public API, task done/obsolete, missing deps/credentials, architectural decisions affecting other tasks, create-vs-modify with data loss risk, multiple interpretations with very different outcomes. Example: `BLOCKED: 'update the auth endpoint' but 3 exist (JWT, OAuth, API key). Need clarification.`

**Supervisor**: Proceed → normal PR review. BLOCKED → clarifies/retries or creates prerequisite. Unclear error → diagnostic worker (`-diag-N`).

## Subtask Lineage and Decomposition (t1408)

**Lineage context (t1408)**: When dispatching subtasks (dot-notation IDs like `t1408.3`), include a lineage block to prevent scope drift. Include when task ID has a dot AND siblings may run in parallel. Workers: focus only on `<-- THIS TASK`, stub sibling deps, exit BLOCKED on hard dependencies.

```text
TASK LINEAGE:
  0. [parent] Build a CRM (t1408)
    1. Contact management (t1408.1)
    2. Deal pipeline (t1408.2)  <-- THIS TASK
    3. Email integration (t1408.3)
LINEAGE RULES: Focus ONLY on "<-- THIS TASK". Stub sibling deps. Exit BLOCKED if hard dependency.
```

**Assembly**: `PARENT_ID="${TASK_ID%.*}"`, grep TODO.md for siblings. `task-decompose-helper.sh format-lineage` does not yet support task-id lookup (t1408.1). Dispatch: append `${LINEAGE_BLOCK}` to `--prompt` via `headless-runtime-helper.sh run`.

**Decomposition (t1408.2)**: Tasks classified as **atomic** (dispatch directly) or **composite** (split into 2-5 subtasks with dependency edges). Interactive: show tree, ask Y/n/edit. Pulse: auto-proceed (depth limit: 3). Integration: `/full-loop` (Step 0.45), `/pulse` (Step 3), `/new-task` (Step 5.5), `/mission`. CLI: `task-decompose-helper.sh classify|decompose|format-lineage|has-subtasks`. Config: `DECOMPOSE_MAX_DEPTH=3`, `DECOMPOSE_MODEL=haiku`, `DECOMPOSE_ENABLED=true`. Principle: "When in doubt, atomic."

**Batch strategies (t1408.4)**: `batch-strategy-helper.sh next-batch --strategy depth-first|breadth-first --tasks "$JSON" --concurrency "$SLOTS"`. Depth-first (default): finish one branch before next. Breadth-first: one subtask per branch per batch. Hybrid: parallel analysis → sequential implementation.

## Worker Efficiency Protocol

Injected via supervisor dispatch (~300-500 token overhead, 20-100x ROI):

1. **TodoWrite** — 3-7 subtasks at start. Last: "Push and create PR". Survives compaction.
2. **Commit early** — per subtask. After first: `git push -u origin HEAD && gh pr create --draft`.
3. **ShellCheck gate (t234)** — Before push, if `.sh` changed: `shellcheck -x -S warning`.
4. **Parallel sub-work (MANDATORY)** — Task tool for independent ops. Sequential for: same-file writes, dependent steps, git ops.
5. **Research offloading** — Task sub-agents for 500+ line files. **Checkpoint**: `session-checkpoint-helper.sh save` per subtask.
6. **Fail fast** — Verify assumptions before coding. Exit BLOCKED after one retry. **Token min**: read ranges, concise commits.

**Parallel vs sequential**: Independent read-only ops (reviews, audits, multi-module tests) → parallel. Dependent chains (fix→test, refactor→docs, plan→implement→verify) → sequential.

## CI/CD Integration

```yaml
- run: opencode run --format json "Review PR changes for security and quality" > review.md
  env: { ANTHROPIC_API_KEY: "${{ secrets.ANTHROPIC_API_KEY }}", OPENCODE_PERMISSION: '{"*":"allow"}' }
```

## Related

`tools/ai-assistants/opencode-server.md` (server API) | `tools/ai-assistants/overview.md` (assistant comparison) | `tools/ai-assistants/runners-README.md` (templates) | `scripts/runner-helper.sh` | `scripts/cron-dispatch.sh`, `scripts/cron-helper.sh` (cron) | `scripts/matrix-dispatch-helper.sh`, `services/communications/matrix-bot.md` (Matrix) | `scripts/commands/pulse.md` (supervisor) | `scripts/mail-helper.sh` (mailbox) | `scripts/worker-token-helper.sh` (t1412.2) | `scripts/network-tier-helper.sh`, `scripts/sandbox-exec-helper.sh` (network+sandbox) | `configs/network-tiers.conf` | `tools/security/prompt-injection-defender.md` | `reference/memory.md` (memory system)
