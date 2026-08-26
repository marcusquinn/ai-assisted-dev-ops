#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Runtime-neutral, argv-first shell-command safety-floor decisions."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from command_policy_account_mutation import (
    _account_mutation_guard,
    _is_protected_account_mutation,
    account_mutation_authorization,
)
from command_policy_config import (
    PolicyError,
    _default_policy_path,
    _load_policy,
    _parse_error,
)
from command_policy_evaluation import (
    _evaluate_static,
    evaluate_invocations,
)
from command_policy_dispatch import (
    CommandParseError,
    _validate_argv,
    analyze_network_argv as _analyze_network_argv,
)
from command_policy_runtime import (
    _argument_parser,
    _network_action,
    _report_policy_error,
    _worker_from_environment,
)
from command_policy_parser import (
    _expand_argv,
    _shell_invocations,
)
from command_policy_wrappers import (
    _expand_launcher as _expand_wrapper_launcher,
    _expand_shell_launcher as _expand_wrapper_shell_launcher,
)

FORBID_EXIT = 20
POLICY_ERROR_EXIT = 21


def analyze_network_argv(argv: list[str], cwd: str) -> dict[str, Any]:
    """Analyze one network command while preserving the original callable API."""
    return _analyze_network_argv(argv, cwd)


def _expand_launcher(
    argv: list[str], executable: str
) -> tuple[list[list[str]] | None, list[str]]:
    return _expand_wrapper_launcher(argv, executable, _shell_invocations)


def _expand_shell_launcher(argv: list[str]) -> list[list[str]]:
    return _expand_wrapper_shell_launcher(argv, _shell_invocations)


def _fixture_invocations(fixture: dict[str, Any]) -> tuple[list[list[str]], bool]:
    has_command = "command" in fixture
    has_argv = "argv" in fixture
    if has_command == has_argv:
        raise PolicyError("command policy fixture requires exactly one of command or argv")
    try:
        invocations = _shell_invocations(fixture["command"]) if has_command else _expand_argv(_validate_argv(fixture["argv"]))
    except CommandParseError as exc:
        if fixture.get("rule_id") == "command.parse-error":
            return [], True
        raise PolicyError(f"command policy fixture parse failed: {fixture.get('name', '?')}: {exc}") from exc
    return invocations, False


def _validate_fixtures(policy: dict[str, Any]) -> None:
    for fixture in policy["fixtures"]:
        if not isinstance(fixture, dict) or not all(key in fixture for key in ("name", "decision", "rule_id")):
            raise PolicyError("command policy fixture is incomplete")
        invocations, rejected = _fixture_invocations(fixture)
        if fixture["rule_id"] == "command.parse-error":
            if not rejected:
                raise PolicyError(
                    f"command policy fixture should fail parsing but did not: {fixture['name']}"
                )
            actual = _parse_error("fixture intentionally rejected")
        else:
            actual = _evaluate_static(invocations, "/work", policy)
        if (actual["decision"], actual["rule_id"]) != (fixture["decision"], fixture["rule_id"]):
            raise PolicyError(
                f"command policy fixture failed: {fixture['name']}: "
                f"expected {fixture['decision']}/{fixture['rule_id']}, "
                f"got {actual['decision']}/{actual['rule_id']}"
            )


def _parse_invocations(args: argparse.Namespace) -> list[list[str]]:
    if args.argv_json:
        return _expand_argv(_validate_argv(json.loads(args.argv_json)))
    if args.command:
        return _shell_invocations(args.command)
    return []


def _authorization_source(args: argparse.Namespace) -> dict[str, Any] | None:
    if args.command:
        return {"kind": "command", "value": args.command}
    if args.argv_json:
        return {"kind": "argv", "value": _validate_argv(json.loads(args.argv_json))}
    return None


def _policy_action(
    args: argparse.Namespace,
    invocations: list[list[str]],
    authorization_source: dict[str, Any] | None,
) -> int:
    policy_path = Path(args.policy) if args.policy else _default_policy_path()
    try:
        policy = _load_policy(policy_path)
        _validate_fixtures(policy)
    except PolicyError as exc:
        return _report_policy_error(args.action, exc)
    if args.action == "validate":
        print(f"Command policy valid: {policy_path}")
        return 0
    if args.action == "authorization-digest":
        return _authorization_action(
            args, invocations, policy, authorization_source
        )
    return _check_action(args, invocations, policy, authorization_source)


def _authorization_action(
    args: argparse.Namespace,
    invocations: list[list[str]],
    policy: dict[str, Any],
    authorization_source: dict[str, Any] | None,
) -> int:
    guard = _account_mutation_guard(policy)
    if len(invocations) != 1 or not _is_protected_account_mutation(
        invocations[0], guard["command_paths"]
    ):
        print(
            json.dumps(
                _parse_error(
                    "authorization digest requires one protected account mutation"
                ),
                sort_keys=True,
            )
        )
        return FORBID_EXIT
    print(
        account_mutation_authorization(
            invocations[0],
            args.cwd,
            authorization_source,
            args.account_mutation_workspace_root,
        )
    )
    return 0


def _check_action(
    args: argparse.Namespace,
    invocations: list[list[str]],
    policy: dict[str, Any],
    authorization_source: dict[str, Any] | None,
) -> int:
    if not invocations:
        print(json.dumps(_parse_error("command or argv input is required"), sort_keys=True))
        return FORBID_EXIT
    result = evaluate_invocations(
        invocations,
        args.cwd,
        policy,
        args.canonical_git_guard,
        args.worker or _worker_from_environment(),
        args.worker_id,
        args.network_helper,
        args.account_mutation_authorization,
        authorization_source,
        args.process_termination_guard,
        args.runtime_pid,
        args.runtime_process_identity,
        args.process_table_fixture,
        args.account_mutation_workspace_root,
        args.approval_helper,
    )
    print(json.dumps(result, sort_keys=True))
    return 0 if result["decision"] == "allow" else FORBID_EXIT


def main() -> int:
    args = _argument_parser().parse_args()

    try:
        invocations = _parse_invocations(args)
        authorization_source = _authorization_source(args)
    except (json.JSONDecodeError, CommandParseError) as exc:
        print(json.dumps(_parse_error(str(exc)), sort_keys=True))
        return FORBID_EXIT
    if args.action == "network-destinations":
        return _network_action(invocations, args.cwd)
    return _policy_action(args, invocations, authorization_source)


if __name__ == "__main__":
    raise SystemExit(main())
