#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Adapt documented Codex lifecycle events to aidevops's shared policies."""

import json
import os
from pathlib import Path
import sys

import git_safety_guard as guard


def session_context():
    """Restore bounded framework pointers at session boundaries."""
    agents = Path(__file__).resolve().parent.parent
    context = (f"Read {agents / 'AGENTS.md'} and {agents / 'build-plus.md'}. "
               f"Codex runtime guidance: {agents / 'tools/ai-assistants/codex-cli.md'}. "
               "Resume the current task after compaction; preserve its worktree and lifecycle stage.")
    return {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}}


def check_tool(event):
    """Translate Codex's command field to the shared shell or patch policy."""
    tool = event.get("tool_name")
    if tool not in ("Bash", "apply_patch"):
        return None
    command = event.get("tool_input", {}).get("command")
    if not isinstance(command, str) or not command:
        return guard._direct_write_deny("Codex hook command payload is missing or invalid")
    if tool == "apply_patch":
        return guard._check_canonical_write("", command)
    return guard._check_command_policy(command)


def handle(event):
    """Return Codex hook output; policy decisions remain in shared helpers."""
    name = event.get("hook_event_name")
    if name == "SessionStart":
        return session_context()
    if name == "PreToolUse":
        return check_tool(event)
    return None


def main():
    try:
        event = json.load(sys.stdin)
        if event.get("cwd"):
            os.chdir(event["cwd"])
        result = handle(event)
    except (OSError, ValueError, TypeError, AttributeError):
        result = guard._direct_write_deny("Codex lifecycle payload could not be validated")
    if result:
        print(json.dumps(result))


if __name__ == "__main__":
    main()
