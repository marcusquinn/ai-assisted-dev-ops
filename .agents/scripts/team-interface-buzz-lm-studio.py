#!/usr/bin/env python3
"""Detect a ready LM Studio runtime and launch Buzz Agent against it."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import argparse
import json
import os
import shutil
import subprocess
import sys

from _team_interface_buzz_lm_studio_cli import (
    LMStudioError,
    loaded_llm_identifiers,
    resolve_lms_cli,
    run_json_command,
    validate_executable,
    validated_model_identifier,
)


def running_server_port(status_value):
    """Return the validated port for a running server, or None when stopped."""
    if not isinstance(status_value, dict) or not isinstance(status_value.get("running"), bool):
        raise LMStudioError("LM Studio server status has an unexpected shape")
    port = None
    if status_value["running"]:
        port = status_value.get("port")
        if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
            raise LMStudioError("LM Studio server did not report a valid local port")
    return port


def select_loaded_model(identifiers):
    """Select one reviewed loaded LLM and return it with any skip reason."""
    selected = None
    reason = None
    configured_model = os.environ.get("AIDEVOPS_LM_STUDIO_MODEL")
    if not identifiers:
        reason = "LM Studio has no loaded LLM"
    elif configured_model:
        configured_model = validated_model_identifier(configured_model)
        if configured_model is None:
            raise LMStudioError("AIDEVOPS_LM_STUDIO_MODEL is invalid")
        if configured_model in identifiers:
            selected = configured_model
        else:
            reason = "configured LM Studio model is not loaded"
    elif len(identifiers) == 1:
        selected = identifiers[0]
    else:
        reason = "multiple LM Studio LLMs are loaded; set AIDEVOPS_LM_STUDIO_MODEL explicitly"
    return selected, reason


def detect_lm_studio():
    """Return a bounded readiness result from the official local CLI surfaces."""
    cli = resolve_lms_cli()
    result = {
        "ready": False,
        "reason": "LM Studio CLI is unavailable; open LM Studio once to install lms",
    }
    if cli is None:
        return result
    status_value = run_json_command(
        cli, ["server", "status", "--json", "--quiet"], "LM Studio server status"
    )
    port = running_server_port(status_value)
    if port is None:
        result["reason"] = "LM Studio server is not running"
    else:
        loaded_value = run_json_command(cli, ["ps", "--json"], "LM Studio loaded-model query")
        selected, reason = select_loaded_model(loaded_llm_identifiers(loaded_value))
        if selected:
            result = {"model": selected, "port": port, "ready": True, "reason": "ready"}
        else:
            result["reason"] = reason
    return result


def resolve_buzz_agent():
    """Resolve the bundled Buzz Agent command inherited through Buzz Desktop PATH."""
    configured = os.environ.get("AIDEVOPS_BUZZ_AGENT_BIN")
    if configured:
        return validate_executable(configured, "AIDEVOPS_BUZZ_AGENT_BIN")
    candidate = shutil.which("buzz-agent")
    if not candidate:
        raise LMStudioError("buzz-agent is unavailable in the Buzz runtime PATH")
    return validate_executable(candidate, "buzz-agent")


def exec_buzz_agent(arguments):
    """Fail closed unless LM Studio is ready, then replace this process with Buzz Agent."""
    status_value = detect_lm_studio()
    if not status_value["ready"]:
        raise LMStudioError(status_value["reason"])
    environment = os.environ.copy()
    environment.update(
        {
            "BUZZ_AGENT_PROVIDER": "openai",
            "OPENAI_COMPAT_API": "chat",
            "OPENAI_COMPAT_API_KEY": "lm-studio",
            "OPENAI_COMPAT_BASE_URL": f"http://127.0.0.1:{status_value['port']}/v1",
            "OPENAI_COMPAT_MODEL": status_value["model"],
        }
    )
    executable = resolve_buzz_agent()
    os.execve(executable, [str(executable), *arguments], environment)


def parse_args(argv=None):
    """Parse the status and runtime entry points."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    status_command = commands.add_parser("status", help="report bounded LM Studio readiness")
    status_command.add_argument("--require", action="store_true", help="exit non-zero unless ready")
    exec_command = commands.add_parser("exec", help="launch Buzz Agent against ready LM Studio")
    exec_command.add_argument("agent_args", nargs=argparse.REMAINDER)
    return parser.parse_args(argv)


def main(argv=None):
    """Report readiness or launch the local Buzz Agent runtime."""
    args = parse_args(argv)
    if args.command == "exec":
        agent_args = args.agent_args[1:] if args.agent_args[:1] == ["--"] else args.agent_args
        exec_buzz_agent(agent_args)
        return 0
    status_value = detect_lm_studio()
    print(json.dumps(status_value, sort_keys=True, separators=(",", ":")))
    if args.require and not status_value["ready"]:
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (LMStudioError, OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"team-interface-buzz-lm-studio: {error}", file=sys.stderr)
        raise SystemExit(1) from error
