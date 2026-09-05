#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Launch interactive clients with framework guidance and explicit permissions."""

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
ALIASES = {"oc": "opencode", "claude": "claude-code", "gemini": "gemini-cli",
           "cn": "continue", "cursor-agent": "cursor", "kiro-cli": "kiro"}
# Interactive adapters; GUI binaries must never be substituted for terminal agents.
RUNTIMES = {
    "codex": ("codex", ["--sandbox", "danger-full-access", "--ask-for-approval", "never"]),
    "claude-code": ("claude", ["--dangerously-skip-permissions"]),
    "opencode": ("opencode", ["--auto"]),
    "cursor": ("cursor-agent", ["--yolo"]),
    "droid": ("droid", []),
    "gemini-cli": ("gemini", ["--yolo"]),
    "continue": ("cn", ["--auto"]),
    "kilo": ("kilo", ["--auto"]),
    "kiro": ("kiro-cli", ["chat", "--trust-all-tools"]),
    "aider": ("aider", ["--yes-always"]),
    "amp": ("amp", ["--dangerously-allow-all"]),
    "kimi": ("kimi", ["--yolo"]),
    "qwen": ("qwen", ["--yolo"]),
    "windsurf": (None, []),
}
OPENCODE_MODES = {"conversation", "remote-interactive", "desktop", "server", "attach"}


def main_agents():
    """Use the setup-owned main-agent links, not workflow commands or subagents."""
    return {p.stem.removeprefix("aidevops-"): p.resolve()
            for p in sorted((ROOT / "commands").glob("aidevops-*.md")) if p.is_file()}


def usage():
    print("Usage: aidevops <runtime> [main-agent] [launcher options] [-- native arguments]")
    print("Default agent: build-plus. Launches interactively with full-access flags where supported.")
    print("Launcher options: --dry-run, --list-agents, --native (no injected defaults), --help")
    print("Runtimes: " + ", ".join(RUNTIMES))
    print("Examples: aidevops codex; aidevops claude automate; aidevops codex seo -- -m MODEL")
    print("Droid retains configured interactive autonomy; Windsurf has no terminal agent adapter.")


def parse_args(args, agents):
    """Only consume wrapper options before --; preserve native arguments verbatim."""
    agent = "build-plus"
    if args and not args[0].startswith("-"):
        agent = args.pop(0).lower().removeprefix("aidevops-")
        agent = {"build+": "build-plus", "ai-devops": "framework"}.get(agent, agent)
    if agent not in agents:
        raise ValueError(f"Unknown main agent: {agent}. Use --list-agents; pass native subcommands with --native.")
    dry_run = False
    native = []
    for index, arg in enumerate(args):
        if arg == "--":
            native.extend(args[index + 1:])
            break
        if arg == "--dry-run":
            dry_run = True
        else:
            native.extend(args[index:])
            break
    return agent, dry_run, native


def guidance(agent, source):
    return (f"For this session, use aidevops main agent {agent}. Read {ROOT / 'AGENTS.md'} "
            f"and {source} and follow their workflow using this runtime's native tools. "
            "This explicit main-agent selection replaces the default Build+ workflow. "
            "Treat OpenCode-specific tool and permission metadata as runtime-specific. "
            "Selecting an agent is not a task: wait for the user's request before doing work.")


def cached_file(name, content):
    """Keep immutable, content-addressed session guidance for clients requiring files."""
    digest = hashlib.sha256(content.encode()).hexdigest()
    directory = Path.home() / ".aidevops/cache/runtime-launchers" / digest
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = directory / name
    if not target.exists():
        fd, temporary = tempfile.mkstemp(dir=directory)
        with os.fdopen(fd, "w") as output:
            output.write(content)
        os.replace(temporary, target)
    return str(target)


def kimi_args(prompt, dry_run):
    # Kimi YAML agents inherit native tools, and preserve project/skill context.
    content = prompt + "\n${KIMI_AGENTS_MD}\n${KIMI_SKILLS}\n"
    path = "<generated-session-guidance.md>" if dry_run else cached_file("guidance.md", content)
    config = "version: 1\nagent:\n  extend: default\n  system_prompt_path: " + json.dumps(path) + "\n"
    config_path = "<generated-kimi-agent.yaml>" if dry_run else cached_file("agent.yaml", config)
    return ["--agent-file", config_path]


def agent_args(runtime, agent, source, prompt, dry_run):
    adapters = {
        "codex": ["-c", "developer_instructions=" + json.dumps(prompt)],
        "claude-code": ["--append-system-prompt", prompt],
        "opencode": ["--agent", "Build+" if agent == "build-plus" else
                     "AI-DevOps" if agent == "framework" else "SEO" if agent == "seo" else agent.title()],
        "cursor": [prompt], "droid": [prompt], "kiro": [prompt],
        "gemini-cli": ["--prompt-interactive", prompt],
        "qwen": ["--prompt-interactive", prompt],
        "continue": ["--rule", prompt],
        "kilo": ["--prompt", prompt],
        "aider": ["--read", str(ROOT / "AGENTS.md"), "--read", str(source)],
        "amp": [],
    }
    if runtime == "kimi":
        return kimi_args(prompt, dry_run)
    if runtime == "aider":
        path = "<generated-session-guidance.md>" if dry_run else cached_file("guidance.md", prompt)
        return adapters[runtime] + ["--read", path]
    return adapters[runtime]


def execute(command, prompt_input=None):
    """Replace the launcher, preserving exit status, terminal output and signals."""
    if prompt_input is not None:
        # Amp documents piped initial input with interactive terminal output.
        # Retain piped user input after the bootstrap instead of discarding it.
        with tempfile.TemporaryFile() as stream:
            stream.write((prompt_input + "\n").encode())
            if not sys.stdin.isatty():
                shutil.copyfileobj(sys.stdin.buffer, stream)
            stream.seek(0)
            os.dup2(stream.fileno(), 0)
            os.execvp(command[0], command)  # nosec B606 -- fixed adapter executable, user-authorized argv, no shell.
    os.execvp(command[0], command)  # nosec B606 -- fixed adapter executable, user-authorized argv, no shell.


def native_launch(runtime, args):
    binary = RUNTIMES[runtime][0]
    if binary is None:
        raise ValueError("Windsurf is an editor integration; launch its editor and use the installed aidevops workflows.")
    execute([binary, *args])


def launch(runtime, args):
    if args and args[0] == "--native":
        native_launch(runtime, args[1:])
    if runtime == "opencode" and args and args[0] in OPENCODE_MODES:
        execute(["bash", str(ROOT / "scripts/opencode-launcher-helper.sh"), *args])
    agents = main_agents()
    if args and args[0] == "--list-agents":
        print("\n".join(agents))
        return
    agent, dry_run, native = parse_args(args, agents)
    binary, flags = RUNTIMES[runtime]
    if binary is None:
        raise ValueError("Windsurf has no supported terminal agent. Use the editor's aidevops workflows.")
    if not dry_run and not shutil.which(binary):
        raise ValueError(f"{binary} is not installed or not on PATH. Install this runtime, then run aidevops update.")
    prompt = guidance(agent, agents[agent])
    selected = agent_args(runtime, agent, agents[agent], prompt, dry_run)
    command = [binary, *flags, *selected, *native]
    if runtime == "opencode":
        command = ["bash", str(ROOT / "scripts/opencode-launcher-helper.sh"), *flags, *selected, *native]
    if runtime == "droid":
        print("aidevops: Droid interactive mode uses your configured autonomy (/settings).", file=sys.stderr)
    if dry_run:
        print(shlex.join(command))
        if runtime == "amp":
            print("Initial stdin: " + prompt)
        return
    execute(command, prompt if runtime == "amp" else None)


def main(args):
    if not args or args[0] in {"-h", "--help", "help"}:
        usage()
        return
    runtime = ALIASES.get(args[0], args[0])
    if runtime not in RUNTIMES:
        raise ValueError(f"Unknown runtime: {runtime}")
    if len(args) > 1 and args[1] in {"-h", "--help", "help"}:
        usage()
        return
    launch(runtime, args[1:])


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError) as error:
        print(f"aidevops: {error}", file=sys.stderr)
        sys.exit(1)
