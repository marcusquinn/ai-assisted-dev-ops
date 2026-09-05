#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Install native Codex guidance, workflow skills and compatible lifecycle hooks."""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import tempfile

START = "<!-- aidevops:codex:start -->"
END = "<!-- aidevops:codex:end -->"


def write_changed(path, text):
    """Atomically update an owned file, preserving mode and detecting races."""
    original = path.read_bytes() if path.exists() else None
    if original == text.encode():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".aidevops-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(text)
            os.fchmod(output.fileno(), path.stat().st_mode & 0o777 if path.exists() else 0o600)
        if (path.read_bytes() if path.exists() else None) != original:
            raise ValueError("destination changed concurrently; retry setup")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def guidance(home, agents):
    """Maintain a small marked block without replacing personal instructions."""
    path = home / "AGENTS.md"
    text = path.read_text() if path.exists() else ""
    block = (f"{START}\nRead {agents / 'AGENTS.md'} for aidevops framework rules.\n"
             f"Use {agents / 'build-plus.md'} as the default coding workflow.\n"
             f"Read {agents / 'tools/ai-assistants/codex-cli.md'} for Codex controls, "
             f"skills, hooks and runtime differences.\n{END}")
    if START in text or END in text:
        if text.count(START) != 1 or text.count(END) != 1 or text.index(END) < text.index(START):
            raise ValueError("invalid aidevops guidance markers")
        text = text[:text.index(START)] + block + text[text.index(END) + len(END):]
    else:
        text = block + "\n\n" + text
    write_changed(path, text)
    override = home / "AGENTS.override.md"
    if override.exists() and override.read_text().strip():
        print("Codex: AGENTS.override.md takes precedence; include the aidevops AGENTS.md reference there if wanted")


def command_sources(agents):
    """Collect canonical command paths, collapsing prefixed aliases."""
    sources = {}
    for directory in (agents / "commands", agents / "scripts/commands"):
        for source in sorted(directory.glob("*.md")):
            if source.is_file() and source.stem != "SKILL":
                name = source.stem
                if not name.startswith("aidevops-"):
                    name = "aidevops-" + name
                sources[name] = source
    sources.setdefault("aidevops-build-plus", agents / "build-plus.md")
    return sources


def skill_text(name, source, agents):
    """Render a native skill without copying runtime-specific prompt bodies."""
    description = f"Run the aidevops {name.removeprefix('aidevops-')} workflow when explicitly requested."
    return (f"---\nname: {name}\ndescription: {json.dumps(description)}\n---\n\n{START}\n"
            f"Read {source} and follow that workflow for the user's request.\n"
            f"Read {agents / 'AGENTS.md'} first if it is not already loaded.\n"
            "Treat $ARGUMENTS in the source as the user's accompanying request, not a shell variable.\n"
            "Use the current runtime's tools; OpenCode agent names and tool permissions are routing guidance.\n"
            f"{END}\n")


def skills(home, agents):
    """Generate bounded pointer skills from the same command sources as OpenCode."""
    for name, source in command_sources(agents).items():
        if not source.is_file() or not re.fullmatch(r"[a-z0-9-]+", name):
            continue
        directory = home / name
        target = directory / "SKILL.md"
        if target.exists() and START not in target.read_text():
            print(f"Codex: preserved personal skill {name}")
            continue
        write_changed(target, skill_text(name, source, agents))
        # Workflow commands, especially release/deploy, require explicit selection.
        metadata = directory / "agents/openai.yaml"
        if not metadata.exists():
            write_changed(metadata, "policy:\n  allow_implicit_invocation: false\n")
    print(f"Codex: reconciled workflow skills in {home}")


def hooks(home, agents):
    """Append owned hooks while preserving custom entries and trust choices."""
    path = home / "hooks.json"
    data = json.loads(path.read_text()) if path.exists() else {}
    events = data.setdefault("hooks", {})
    command = "python3 " + shlex.quote(str(agents / "hooks/codex_lifecycle.py"))
    for event, matcher in (("SessionStart", "startup|resume|clear|compact"),
                           ("PreToolUse", "^(Bash|apply_patch)$")):
        groups = events.setdefault(event, [])
        handler = {"type": "command", "command": command, "timeout": 15,
                   "statusMessage": "aidevops " + event}
        # Stable command identity avoids duplicate registration and preserves disabled hooks.
        if not any(h.get("command") == command for group in groups for h in group.get("hooks", [])):
            groups.append({"matcher": matcher, "hooks": [handler]})
    write_changed(path, json.dumps(data, indent=2) + "\n")
    print("Codex: lifecycle hooks installed; review/trust new hooks with /hooks")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("guidance", "skills", "hooks", "all"))
    parser.add_argument("--agents", type=Path, default=Path.home() / ".aidevops/agents")
    parser.add_argument("--codex-home", type=Path,
                        default=Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex"))
    parser.add_argument("--skills-home", type=Path, default=Path.home() / ".agents/skills")
    args = parser.parse_args()
    if args.mode in ("guidance", "all"):
        guidance(args.codex_home, args.agents)
    if args.mode in ("skills", "all") and os.environ.get("AIDEVOPS_FEATURE_COMMANDS_CODEX", "yes") == "yes":
        skills(args.skills_home, args.agents)
    if args.mode in ("hooks", "all"):
        hooks(args.codex_home, args.agents)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, AttributeError) as error:
        raise SystemExit(f"Codex setup failed ({type(error).__name__}); inspect destination format and retry") from None
