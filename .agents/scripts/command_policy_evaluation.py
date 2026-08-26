#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Static and dynamic command-policy evaluation."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from command_policy_account_mutation import (
    _AccountMutationContext,
    _account_mutation_guard as _account_mutation_guard,
    _evaluate_account_mutation,
    account_mutation_authorization as _account_mutation_authorization,
)
from command_policy_approval import _evaluate_approval_freshness
from command_policy_config import _decision
from command_policy_matchers import _matches
from command_policy_process_termination import (
    _evaluate_process_termination,
    _process_termination_guard_path,
)

DECISION_RANK = {"allow": 0, "forbid": 1}


def account_mutation_authorization(
    argv: list[str],
    cwd: str,
    source: dict[str, Any] | None = None,
    workspace_root: str | None = None,
) -> str:
    """Preserve the original command-policy evaluation import surface."""
    return _account_mutation_authorization(argv, cwd, source, workspace_root)


@dataclass(frozen=True)
class _EvaluationOptions:
    guard_path: str = ""
    worker: bool = False
    worker_id: str = "unknown"
    network_helper: str = ""
    account_mutation_authorization: str = ""
    account_mutation_source: dict[str, Any] | None = None
    process_termination_guard: str = ""
    runtime_pid: int = 0
    runtime_process_identity: str = ""
    process_table_fixture: str = ""
    account_mutation_workspace_root: str | None = None
    approval_helper: str = ""


def _evaluate_static(
    invocations: list[list[str]], cwd: str, policy: dict[str, Any]
) -> dict[str, Any]:
    best = dict(policy["default_decision"])
    best["schema_version"] = 2
    for argv in invocations:
        for rule in policy["rules"]:
            if (
                _matches(rule["matcher"], argv, cwd)
                and DECISION_RANK[rule["decision"]] > DECISION_RANK[best["decision"]]
            ):
                best = _decision(rule["decision"], rule["id"], rule["reason"])
    return best


def _canonical_guard_path(
    policy: dict[str, Any], explicit: str, script_dir: Path | None = None
) -> Path:
    if explicit:
        return Path(explicit)
    helper = next(
        guard["helper"]
        for guard in policy["dynamic_guards"]
        if guard["kind"] == "canonical_git"
    )
    return (script_dir or Path(__file__).resolve().parent) / helper


def _evaluate_canonical_git(
    invocations: list[list[str]], cwd: str, guard: Path
) -> dict[str, Any]:
    git_invocations = list(filter(_is_git_invocation, invocations))
    if not git_invocations:
        return _decision("allow", "git.no-invocation", "No Git invocation detected")
    if not guard.is_file():
        return _decision(
            "forbid",
            "git.guard-unavailable",
            f"Canonical Git policy helper is unavailable: {guard}",
        )
    for argv in git_invocations:
        result, error = _run_canonical_guard(argv, cwd, guard)
        if error:
            return error
        denied = _canonical_guard_denial(result)
        if denied:
            return denied
    return _decision(
        "allow", "git.canonical-allow", "Canonical Git guard allowed every Git argv"
    )


def _is_git_invocation(argv: list[str]) -> bool:
    return bool(argv) and os.path.basename(argv[0]) == "git"


def _canonical_guard_denial(
    result: subprocess.CompletedProcess[str],
) -> dict[str, Any] | None:
    if result.returncode == 0:
        return None
    reason = result.stderr.strip() or (
        f"Canonical Git guard failed with exit {result.returncode}"
    )
    return _decision("forbid", "git.canonical-worktree", reason)


def _run_canonical_guard(
    argv: list[str], cwd: str, guard: Path
) -> tuple[subprocess.CompletedProcess[str] | None, dict[str, Any] | None]:
    try:
        result = subprocess.run(  # nosec B603 -- executable is the current Python; guard path is policy-selected and verified as a file.
                [
                    sys.executable,
                    str(guard),
                    "--cwd",
                    cwd,
                    "--argv-json",
                    json.dumps(argv[1:]),
                ],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return None, _decision(
                "forbid",
                "git.guard-error",
                f"Canonical Git policy check failed closed: {exc}",
        )
    return result, None


def _network_guard_path(
    policy: dict[str, Any], explicit: str, script_dir: Path | None = None
) -> Path:
    if explicit:
        return Path(explicit)
    override = os.environ.get("AIDEVOPS_NETWORK_TIER_HELPER", "")
    if override:
        return Path(override)
    helper = next(
        guard["helper"]
        for guard in policy["dynamic_guards"]
        if guard["kind"] == "worker_network"
    )
    return (script_dir or Path(__file__).resolve().parent) / helper


def _approval_guard_path(
    policy: dict[str, Any], explicit: str, script_dir: Path | None = None
) -> Path:
    if explicit:
        return Path(explicit)
    helper = next(
        guard["helper"]
        for guard in policy["dynamic_guards"]
        if guard["kind"] == "approval_freshness"
    )
    return (script_dir or Path(__file__).resolve().parent) / helper


def _evaluate_worker_network(
    invocations: list[list[str]], cwd: str, helper: Path, worker_id: str
) -> dict[str, Any]:
    if not helper.is_file():
        return _decision(
            "forbid",
            "network.helper-unavailable",
            f"Required worker network policy helper is unavailable: {helper}",
        )
    for argv in invocations:
        try:
            result = subprocess.run(  # nosec B603 -- /bin/bash is fixed and helper is policy-selected and verified as a file.
                [
                    "/bin/bash",
                    str(helper),
                    "check-argv",
                    json.dumps(argv),
                    "--cwd",
                    cwd,
                    "--worker-id",
                    worker_id,
                ],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return _decision(
                "forbid",
                "network.helper-error",
                f"Worker network policy failed closed: {exc}",
            )
        if result.returncode != 0:
            reason = result.stderr.strip() or (
                "Worker network policy denied or could not classify the command destination"
            )
            return _decision("forbid", "network.worker-policy", reason)
    return _decision(
        "allow", "network.worker-allow", "Worker network policy allowed every argv"
    )


def evaluate_invocations(
    invocations: list[list[str]],
    cwd: str,
    policy: dict[str, Any],
    *legacy_options: Any,
    **named_options: Any,
) -> dict[str, Any]:
    options = _evaluation_options(legacy_options, named_options)
    script_dir = Path(__file__).resolve().parent
    approval_decision = _evaluate_approval_freshness(
        invocations,
        _approval_guard_path(policy, options.approval_helper, script_dir),
    )
    decisions = ([approval_decision] if approval_decision else []) + [
        _evaluate_static(invocations, cwd, policy),
        _evaluate_canonical_git(
            invocations,
            cwd,
            _canonical_guard_path(policy, options.guard_path, script_dir),
        ),
        _evaluate_account_mutation(
            invocations,
            cwd,
            policy,
            _AccountMutationContext(
                authorization=options.account_mutation_authorization,
                source=options.account_mutation_source,
                workspace_root=options.account_mutation_workspace_root,
            ),
        ),
        _evaluate_process_termination(
            invocations,
            _process_termination_guard_path(
                policy, options.process_termination_guard, script_dir
            ),
            options.runtime_pid,
            options.runtime_process_identity,
            options.process_table_fixture,
        ),
    ]
    if options.worker:
        decisions.append(
            _evaluate_worker_network(
                invocations,
                cwd,
                _network_guard_path(policy, options.network_helper, script_dir),
                options.worker_id,
            )
        )
    return max(decisions, key=lambda item: DECISION_RANK[item["decision"]])


def _evaluation_options(
    legacy_options: tuple[Any, ...], named_options: dict[str, Any]
) -> _EvaluationOptions:
    names = (
        "guard_path",
        "worker",
        "worker_id",
        "network_helper",
        "account_mutation_authorization",
        "account_mutation_source",
        "process_termination_guard",
        "runtime_pid",
        "runtime_process_identity",
        "process_table_fixture",
        "account_mutation_workspace_root",
        "approval_helper",
    )
    if len(legacy_options) > len(names):
        maximum_arguments = len(names) + 3
        raise TypeError(
            f"evaluate_invocations() takes from 3 to {maximum_arguments} positional arguments "
            f"but {len(legacy_options) + 3} were given"
        )
    values: dict[str, Any] = dict(zip(names, legacy_options))
    for name, value in named_options.items():
        if name not in names:
            raise TypeError(
                f"evaluate_invocations() got an unexpected keyword argument '{name}'"
            )
        if name in values:
            raise TypeError(
                f"evaluate_invocations() got multiple values for argument '{name}'"
            )
        values[name] = value
    return _EvaluationOptions(**values)
