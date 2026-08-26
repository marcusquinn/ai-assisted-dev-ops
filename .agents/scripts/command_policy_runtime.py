#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Runtime environment and CLI argument handling."""

from __future__ import annotations

import argparse
import json
import os
import sys

from command_policy_account_mutation import (
    account_mutation_workspace_root_from_environment,
)
from command_policy_config import PolicyError, _policy_error
from command_policy_dispatch import analyze_network_argv

WORKER_ENV_KEYS = (
    "FULL_LOOP_HEADLESS",
    "AIDEVOPS_HEADLESS",
    "OPENCODE_HEADLESS",
    "CLAUDE_HEADLESS",
    "Claude_HEADLESS",
    "HEADLESS",
    "GITHUB_ACTIONS",
)


def _worker_from_environment() -> bool:
    return bool(os.environ.get("AIDEVOPS_WORKER_ID", "")) or any(
        os.environ.get(key, "").lower() in {"1", "true", "yes"}
        for key in WORKER_ENV_KEYS
    )


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "action",
        choices=(
            "authorization-digest",
            "check-command",
            "validate",
            "network-destinations",
        ),
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--command", default="")
    source.add_argument("--argv-json", default="")
    parser.add_argument("--cwd", default=os.getcwd())
    parser.add_argument("--policy", default="")
    parser.add_argument("--canonical-git-guard", default="")
    parser.add_argument("--network-helper", default="")
    parser.add_argument("--process-termination-guard", default="")
    parser.add_argument("--runtime-pid", type=int, default=0)
    parser.add_argument("--runtime-process-identity", default="")
    parser.add_argument("--process-table-fixture", default="")
    parser.add_argument("--approval-helper", default="")
    parser.add_argument("--worker", action="store_true")
    parser.add_argument(
        "--worker-id", default=os.environ.get("AIDEVOPS_WORKER_ID", "unknown")
    )
    # #aidevops:trust-boundary — this value comes from the policy process'
    # inherited environment, never from an assignment inside the checked command.
    parser.add_argument(
        "--account-mutation-authorization",
        default=os.environ.get("AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION", ""),
    )
    parser.add_argument(
        "--account-mutation-workspace-root",
        default=account_mutation_workspace_root_from_environment(),
    )
    return parser


def _network_action(invocations: list[list[str]], cwd: str) -> int:
    if len(invocations) == 1:
        output = analyze_network_argv(invocations[0], cwd)
        exit_code = 0
    else:
        output = {
            "recognized": False,
            "requires_destination": True,
            "destinations": [],
            "unclassified": ["network analysis requires exactly one argv"],
        }
        exit_code = 20
    print(json.dumps(output, sort_keys=True))
    return exit_code


def _report_policy_error(action: str, error: PolicyError) -> int:
    if action == "check-command":
        print(json.dumps(_policy_error(str(error)), sort_keys=True))
    else:
        print(f"BLOCKED: {error}", file=sys.stderr)
    return 21
