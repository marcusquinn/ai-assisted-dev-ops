---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Codex CLI integration

`setup.sh --non-interactive` and `aidevops update` reconcile the Codex integration
when the CLI is installed or its configuration directory exists. Restart Codex
for changed global guidance and configuration to load.

## Start working

Launch in your repository or linked worktree:

```bash
codex -C /path/to/repo --sandbox danger-full-access --ask-for-approval never
```

This is the explicit full-access launch: no shell sandbox or approval prompts.
Setup preserves your permission and model settings. Plain `codex` uses those
existing defaults. `--dangerously-bypass-approvals-and-sandbox` is the equivalent
combined flag. Neither form automatically trusts new lifecycle hooks.

Global `AGENTS.md` loads the framework and Build+ workflow automatically. Select
an explicit workflow with `$aidevops-build-plus`, `$aidevops-full-loop`, or another
`$aidevops-…` skill. Use `/skills` to discover installed skills. Supply the task
in the same message. Read the named canonical workflow before executing it.

## Installed surfaces

| Capability | Codex integration |
|---|---|
| Framework instructions and default Build+ | Small managed block in `$CODEX_HOME/AGENTS.md` (default `~/.codex`) |
| Main agents and workflow commands | Pointer skills in `~/.agents/skills/aidevops-*/SKILL.md`, generated from shared command sources |
| Legacy slash commands | `~/.codex/prompts/aidevops-*.md`, invoked as `/prompts:aidevops-…`; retained for compatibility |
| Startup, resume and compaction | `SessionStart` hook restores framework pointers and continuation guidance |
| Shell and patch safety | `PreToolUse` adapter calls the same command and canonical-write policies as Claude Code |
| MCP | `config.toml` migrations preserve custom servers; new shared defaults are disabled until explicitly enabled |
| Memory and task lifecycle | Shared CLI helpers, including `memory-helper.sh` and `full-loop-helper.sh`; Vault access still requires an unlocked Vault |
| Session mining | Existing Codex runtime miner; session location follows `CODEX_HOME` |

Native skills require explicit invocation so commands such as release cannot
activate merely from a matching description. `AIDEVOPS_FEATURE_COMMANDS_CODEX=no`
skips both legacy command and native skill installation; it does not remove
previously installed skills. Personal unmarked skills are preserved on collision.

## Hooks and overrides

Open `/hooks` once to review and trust the newly installed hooks. Codex binds trust
to hook definitions; changed definitions may need another review. Setup preserves
existing hooks, disabled entries, and `features.hooks` settings. If hooks are
untrusted or disabled, follow the framework's pre-edit and safety checks explicitly.

A nonempty `$CODEX_HOME/AGENTS.override.md` takes precedence over `AGENTS.md`.
Setup reports this and leaves the override untouched. Include the framework
reference there if you want aidevops active under that override. Legacy
`instructions.md` is preserved, but is not assumed to load automatically.

## Runtime differences

OpenCode's agent picker, per-agent model/tool profiles, native TypeScript tools,
MCP connect/disconnect tool, and database session controls are not installed into
Codex. Skills supply workflow guidance; they do not create equivalent isolated
agent permissions. Use the shared shell helpers and Codex's native tools. Keep
full-loop ownership in the primary session unless the user requests delegation.

Hooks cover documented local tool paths, not hosted tools or arbitrary external
processes. The adapter does not claim complete containment. Codex's native
compaction is retained; the startup hook restores pointers rather than replacing
its compaction algorithm. Headless dispatch remains supported through the
framework's existing Claude Code/OpenCode runners, not a newly invented Codex runner.

## Verification and sources

Inspect `/skills`, `/hooks`, and `/mcp` in a new Codex session. Ask it to list the
instruction files it loaded and confirm both global and repository guidance.
For a focused reconciliation run `python3 ~/.aidevops/agents/scripts/codex-setup.py all`.

Contracts checked against the installed CLI and official documentation:
[AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md.md),
[skills](https://learn.chatgpt.com/docs/build-skills.md),
[hooks and tool payloads](https://learn.chatgpt.com/docs/hooks.md), and
[deprecated custom prompts](https://learn.chatgpt.com/docs/custom-prompts.md).
