---
description: Interactive aidevops runtime shortcuts and main-agent selection
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Interactive runtime launchers

`aidevops <runtime> [main-agent]` starts an interactive session in the current
working directory. The default main agent is `build-plus`. Setup and update deploy
the shared launcher with the CLI and framework bundle; no shell aliases or global
permission settings are needed.

```bash
aidevops codex
aidevops codex automate
aidevops claude seo
aidevops opencode research
aidevops codex --list-agents
aidevops claude automate --dry-run
aidevops codex automate -- -m MODEL
aidevops codex --native resume --last
```

Main-agent names come from the framework's `commands/aidevops-*.md` links, including
`build-plus`, `automate`, `business`, `content`, `framework`, `health`, `legal`,
`marketing-sales`, `product`, `research`, and `seo`. Names are case-insensitive;
`Build+` and the `aidevops-` prefix also work. Workflow commands such as `full-loop`
are tasks to invoke inside a session, not main-agent selectors.

Put launcher options (`--dry-run`) before native options; use `--` to end launcher
option handling. Native arguments retain their original boundaries and quoting.
Use `--native` immediately after the runtime to run its native subcommands or to
launch without injected permissions or agent guidance. For example,
`aidevops codex --native login` and `aidevops claude --native --help`.

## Runtime behavior

The launchers request the following permissions for this invocation. Runtime and
organization policies, explicit deny rules, framework safeguards and hook trust
still apply. Codex hook trust remains separate from sandbox/approval flags.

| Command | Executable / permissions | Main-agent guidance |
| --- | --- | --- |
| `codex` | `codex --sandbox danger-full-access --ask-for-approval never` | Session `developer_instructions` |
| `claude`, `claude-code` | `claude --dangerously-skip-permissions` | Appended system instructions |
| `opencode`, `oc` | Existing isolated launcher, `--auto` | Native `--agent` |
| `cursor`, `cursor-agent` | `cursor-agent --yolo` | Initial interactive context |
| `droid` | `droid`, configured interactive autonomy | Initial interactive context |
| `gemini`, `gemini-cli` | `gemini --yolo` | `--prompt-interactive` |
| `continue`, `cn` | `cn --auto` | Session `--rule` |
| `kilo` | `kilo --auto` | TUI `--prompt` |
| `kiro`, `kiro-cli` | `kiro-cli chat --trust-all-tools` | Initial interactive context |
| `aider` | `aider --yes-always` | Framework, selected agent and session guidance as read-only context |
| `amp` | `amp --dangerously-allow-all` | Initial stdin, preserving any piped user input |
| `kimi` | `kimi --yolo` | YAML agent extending native `default` tools |
| `qwen` | `qwen --yolo` | `--prompt-interactive` |
| `windsurf` | Editor only | Use the editor's installed aidevops workflows |

Codex and Claude session instructions select the workflow without submitting a
task. Initial-context adapters may perform a bootstrap turn to read the framework;
the context explicitly tells them to wait for the user's task. Enter the task in
the terminal after launch. Aider loads the selected Markdown and explicit session guidance as read-only context;
its available tools remain those of Aider. Amp uses its documented piped-input TUI
mode, so terminal output must remain attached for interactive use.

Kimi's YAML adapter targets the `kimi-cli` interface documented below. Its generated
agent and prompt live in content-addressed `~/.aidevops/cache/runtime-launchers/`
files. It inherits native tools and includes project/skill context; its system
prompt uses the selected aidevops workflow. Dry runs do not write these files.

Droid's interactive interface does not expose the Exec-only permission bypass
flag. Select the desired autonomy in `/settings`; the launcher reports this
limitation. It never switches to one-shot `droid exec` to obtain broader access.
Windsurf's editor integration has no supported terminal agent adapter and returns
an explanatory error. Cursor, Continue and Kiro use their terminal executables,
not the similarly named editor binaries. Missing CLIs produce an actionable error;
launching never installs software or modifies personal runtime settings.

OpenCode keeps its existing `--dir`, `--shared-db`, `--session-id` and Tabby options.
Its `conversation`, `remote-interactive`, `desktop`, `server` and `attach` modes
are forwarded unchanged to the existing launcher, without injecting main-agent or
permission flags. `opencode-desktop` and `opencode-sandbox` remain available.

## Adapter references

Verified against installed CLI help where available and upstream references:
[Codex options](https://learn.chatgpt.com/docs/developer-commands.md?surface=cli),
[Continue CLI](https://docs.continue.dev/cli/quickstart),
[Droid interactive autonomy](https://docs.factory.ai/autonomy-and-safety/auto-run),
[Kilo CLI options](https://kilo.ai/docs/code-with-ai/platforms/cli-reference),
[Kiro CLI options](https://kiro.dev/docs/cli/reference/cli-commands/),
[Kimi YAML agents](https://moonshotai.github.io/kimi-cli/en/customization/agents.html),
[Aider options](https://aider.chat/docs/config/options.html).
