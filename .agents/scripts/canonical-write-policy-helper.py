#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Runtime-neutral canonical-versus-linked worktree policy.

The helper is intentionally process-based so shell, Claude Code, and OpenCode
all consume the same structural classification. Branch names never decide
whether a checkout is canonical: an absolute Git directory equal to the
absolute common directory is canonical, while a different Git directory is a
linked worktree.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import asdict
from typing import Any

from canonical_branch_policy import resolve_branch
from canonical_write_policy_paths import (
    Classification,
    canonical_git_workspace_root as _canonical_git_workspace_root,
    classify_location,
    git_output as _git_output,
    git_symlink_origin as _git_symlink_origin,
    git_workspace_root_from_environment,
    is_within_workspace as _is_within_workspace,
    repository_within_workspace as _repository_within_workspace,
    target_probe as _target_probe,
)


POLICY_VERSION = "canonical-write-policy-v2"


def _write_action(
    decision: str,
    cross_repository_target: bool,
    symlink_workspace_escape: bool,
) -> str:
    if decision != "deny":
        return "none"
    if symlink_workspace_escape:
        return "use_direct_sanctioned_outside_path"
    if cross_repository_target:
        return "use_linked_worktree_under_git_workspace"
    return "create_or_use_linked_worktree"


def check_write(cwd: str, file_path: str) -> dict[str, Any]:
    """Return one fail-closed direct-file-write decision."""
    context = classify_location(cwd)
    if not file_path:
        target = Classification("unknown", False, reason="write target is empty")
        target_probe = cwd
        symlink_origin = None
    else:
        target_probe = _target_probe(cwd, file_path)
        target = classify_location(target_probe)
        symlink_origin = _git_symlink_origin(cwd, file_path)
    workspace_root = _canonical_git_workspace_root(
        git_workspace_root_from_environment()
    )
    cross_repository_target = target.classification == "linked" and (
        not context.inside_git or target.common_dir != context.common_dir
    )
    symlink_workspace_escape = (
        symlink_origin is not None
        and target.classification == "outside"
        and not _is_within_workspace(target_probe, workspace_root)
    )

    context_within_workspace = (
        _repository_within_workspace(context, workspace_root)
        if context.inside_git
        else _is_within_workspace(cwd, workspace_root)
    )

    if target.classification == "unknown":
        decision = "deny"
        reason = f"write target classification failed closed: {target.reason}"
    elif target.classification == "canonical":
        decision = "deny"
        reason = "canonical checkouts are read-only session mirrors"
    elif symlink_workspace_escape:
        decision = "deny"
        reason = (
            "symlinked write target escapes from a Git worktree outside the "
            "trusted Git workspace"
        )
    elif cross_repository_target and not (
        context_within_workspace
        and _repository_within_workspace(target, workspace_root)
    ):
        decision = "deny"
        reason = (
            "cross-repository linked worktree access is limited to the "
            "trusted Git workspace"
        )
    else:
        decision = "allow"
        reason = (
            "cross-repository write target resolves inside a linked worktree "
            "within the trusted Git workspace"
            if cross_repository_target
            else (
                "write target resolves inside an allowed linked worktree"
                if target.classification == "linked"
                else "write target is outside canonical worktrees"
            )
        )

    return {
        "policy": POLICY_VERSION,
        "git_workspace_root": workspace_root,
        "decision": decision,
        "reason": reason,
        "action": _write_action(
            decision, cross_repository_target, symlink_workspace_escape
        ),
        "context": asdict(context),
        "target": asdict(target),
    }


def _patch_paths(patch_text: str) -> list[str]:
    paths: list[str] = []
    header_pattern = re.compile(
        r"^\*\*\* (?:Add|Update|Delete) File: (?P<path>.+)$"
    )
    move_pattern = re.compile(r"^\*\*\* Move to: (?P<path>.+)$")
    for line in patch_text.splitlines():
        match = header_pattern.match(line) or move_pattern.match(line)
        if match:
            paths.append(match.group("path"))
    return paths


def check_patch(cwd: str, patch_text: str) -> dict[str, Any]:
    """Return one fail-closed decision for every target in an apply patch."""
    paths = _patch_paths(patch_text)
    if not paths:
        empty_decision = check_write(cwd, "")
        return {
            **empty_decision,
            "decision": "deny",
            "reason": "apply-patch targets could not be classified safely",
            "action": "repair_or_use_linked_worktree",
            "patch_paths": [],
        }
    for path in paths:
        decision = check_write(cwd, path)
        if decision["decision"] != "allow":
            return {**decision, "patch_paths": paths}
    return {**decision, "patch_paths": paths}


def resolve_canonical_branch(cwd: str) -> dict[str, str]:
    classification = classify_location(cwd)
    if classification.classification not in {"canonical", "linked"}:
        raise RuntimeError(
            "canonical branch requires a classified Git worktree: "
            f"{classification.reason}"
        )
    return resolve_branch(classification.repo_root, _git_output, POLICY_VERSION)


def _emit(payload: dict[str, Any], field: str) -> None:
    if field:
        value = payload.get(field, "")
        if isinstance(value, (dict, list)):
            print(json.dumps(value, sort_keys=True))
        else:
            print(value)
        return
    print(json.dumps(payload, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    classify_parser = subparsers.add_parser("classify")
    classify_parser.add_argument("--cwd", default=os.getcwd())
    classify_parser.add_argument("--field", default="")

    write_parser = subparsers.add_parser("check-write")
    write_parser.add_argument("--cwd", default=os.getcwd())
    write_parser.add_argument("--path", default="")
    write_parser.add_argument("--field", default="")

    patch_parser = subparsers.add_parser("check-patch")
    patch_parser.add_argument("--cwd", default=os.getcwd())
    patch_parser.add_argument("--field", default="")

    branch_parser = subparsers.add_parser("resolve-branch")
    branch_parser.add_argument("--cwd", default=os.getcwd())
    branch_parser.add_argument("--field", default="")

    args = parser.parse_args()
    if args.command == "classify":
        result = classify_location(args.cwd)
        payload = {"policy": POLICY_VERSION, **asdict(result)}
        _emit(payload, args.field)
        return 2 if result.classification == "unknown" else 0
    if args.command == "check-write":
        _emit(check_write(args.cwd, args.path), args.field)
        return 0
    if args.command == "check-patch":
        _emit(check_patch(args.cwd, sys.stdin.read()), args.field)
        return 0
    try:
        payload = resolve_canonical_branch(args.cwd)
    except RuntimeError as exc:
        print(f"BLOCKED: {exc}", file=sys.stderr)
        return 2
    _emit(payload, args.field)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
