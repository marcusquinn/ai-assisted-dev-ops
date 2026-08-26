#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fresh approval verification for privileged aidevops approval commands."""

from __future__ import annotations

import os
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from command_policy_config import _decision

REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
TARGET_PATTERN = re.compile(r"^[1-9][0-9]*$")
KNOWN_VERIFY_STATES = {
    "API_ERROR",
    "LEGACY_APPROVAL",
    "MALFORMED_APPROVAL",
    "NO_APPROVAL",
    "NO_KEY",
    "STALE_APPROVAL",
    "UNTRUSTED_APPROVAL",
    "VERIFIED",
}


class ApprovalCommandError(ValueError):
    """Raised when a recognized approval command is not safely parseable."""


@dataclass(frozen=True)
class ApprovalRequest:
    targets: tuple[tuple[str, str], ...]
    repository: str
    batch: bool


def _approval_request(argv: list[str]) -> ApprovalRequest | None:
    if len(argv) < 3 or os.path.basename(argv[0]) != "aidevops":
        return None
    if argv[1] != "approve" or argv[2] not in {"issue", "pr", "batch"}:
        return None
    if len(argv) < 5 or not REPOSITORY_PATTERN.fullmatch(argv[-1]):
        raise ApprovalCommandError(
            "approval command requires targets followed by an explicit owner/repository"
        )
    repository = argv[-1]
    target_args = argv[3:-1]
    batch = argv[2] == "batch"
    targets = (
        _parse_batch_targets(target_args)
        if batch
        else _parse_same_kind_targets(argv[2], target_args)
    )
    return ApprovalRequest(tuple(dict.fromkeys(targets)), repository, batch)


def _parse_same_kind_targets(
    target_type: str, target_args: list[str]
) -> list[tuple[str, str]]:
    if not target_args or any(not TARGET_PATTERN.fullmatch(arg) for arg in target_args):
        raise ApprovalCommandError("approval issue/pr targets must be positive integers")
    return [(target_type, number) for number in target_args]


def _parse_batch_targets(target_args: list[str]) -> list[tuple[str, str]]:
    targets: list[tuple[str, str]] = []
    for item in target_args:
        target_type, separator, number = item.partition(":")
        if (
            separator != ":"
            or target_type not in {"issue", "pr"}
            or not TARGET_PATTERN.fullmatch(number)
        ):
            raise ApprovalCommandError(
                "approval batch targets must use issue:<number> or pr:<number>"
            )
        targets.append((target_type, number))
    if not targets:
        raise ApprovalCommandError("approval batch requires at least one target")
    return targets


def _evaluate_approval_freshness(
    invocations: list[list[str]], helper: Path
) -> dict[str, Any] | None:
    requests: list[ApprovalRequest] = []
    try:
        for argv in invocations:
            request = _approval_request(argv)
            if request is not None:
                requests.append(request)
    except ApprovalCommandError as exc:
        return _decision("forbid", "approval.preflight-malformed", str(exc))
    if not requests:
        return None
    if not helper.is_file():
        return _decision(
            "forbid",
            "approval.verifier-unavailable",
            f"Fresh approval verifier is unavailable: {helper}",
        )
    decisions = [_evaluate_request(request, helper) for request in requests]
    return next(
        (decision for decision in decisions if decision["decision"] == "forbid"),
        decisions[0],
    )


def _evaluate_request(request: ApprovalRequest, helper: Path) -> dict[str, Any]:
    states = _verify_targets(request, helper)
    verified = [target for target in request.targets if states[target] == "VERIFIED"]
    unapproved = [
        target for target in request.targets if states[target] == "NO_APPROVAL"
    ]
    indeterminate = [
        target
        for target in request.targets
        if states[target] not in {"VERIFIED", "NO_APPROVAL"}
    ]
    if indeterminate:
        details = ", ".join(
            f"{_format_target(target)}={states[target]}" for target in indeterminate
        )
        reason = (
            "Fresh approval state is indeterminate; do not claim approval is missing "
            f"or retry sudo. verified=[{_format_targets(verified)}], "
            f"unapproved=[{_format_targets(unapproved)}], indeterminate=[{details}]"
        )
        return _decision("forbid", "approval.verification-indeterminate", reason)
    if len(verified) == len(request.targets):
        return _decision(
            "forbid",
            "approval.already-verified",
            "Fresh authoritative verification confirms every target is already "
            f"approved ({_format_targets(verified)}); skip sudo and continue the "
            "requested workflow",
        )
    if verified:
        reduced = _approval_command(request, unapproved)
        return _decision(
            "forbid",
            "approval.partially-verified",
            f"Fresh verification removed already-approved targets "
            f"({_format_targets(verified)}); retry only genuinely unapproved targets "
            f"with: {reduced}",
        )
    return _decision(
        "allow",
        "approval.fresh-unapproved",
        f"Fresh verification confirms approval is absent for "
        f"{_format_targets(unapproved)}",
    )


def _verify_targets(
    request: ApprovalRequest, helper: Path
) -> dict[tuple[str, str], str]:
    worker_count = min(len(request.targets), 8)
    with ThreadPoolExecutor(max_workers=worker_count) as executor:
        results = executor.map(
            lambda target: _verify_target(helper, request.repository, target),
            request.targets,
        )
    return dict(zip(request.targets, results))


def _verify_target(
    helper: Path, repository: str, target: tuple[str, str]
) -> str:
    target_type, number = target
    try:
        result = subprocess.run(  # nosec B603 -- helper is policy-selected and target argv is strictly validated.
            [str(helper), "verify", target_type, number, repository],
            capture_output=True,
            text=True,
            timeout=8,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return "API_ERROR"
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    state = lines[-1] if lines and lines[-1] in KNOWN_VERIFY_STATES else "API_ERROR"
    if state == "VERIFIED" and result.returncode != 0:
        return "API_ERROR"
    if state == "NO_APPROVAL" and result.returncode != 1:
        return "API_ERROR"
    return state


def _approval_command(
    request: ApprovalRequest, targets: list[tuple[str, str]]
) -> str:
    if not request.batch and len({target[0] for target in targets}) == 1:
        target_type = targets[0][0]
        numbers = " ".join(target[1] for target in targets)
        return f"sudo aidevops approve {target_type} {numbers} {request.repository}"
    encoded = " ".join(_format_target(target) for target in targets)
    return f"sudo aidevops approve batch {encoded} {request.repository}"


def _format_target(target: tuple[str, str]) -> str:
    return f"{target[0]}:{target[1]}"


def _format_targets(targets: list[tuple[str, str]]) -> str:
    return ", ".join(_format_target(target) for target in targets) or "none"
