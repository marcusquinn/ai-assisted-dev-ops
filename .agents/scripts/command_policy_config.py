#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Loading and structural validation for the command policy."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

KNOWN_MATCHERS = {
    "rm_recursive_force_root",
    "rm_recursive_force",
    "git_checkout_worktree_path",
    "git_restore_worktree",
    "git_reset_destructive",
    "git_clean_force",
    "git_push_force",
    "git_branch_force_delete",
    "git_stash_delete",
}


class PolicyError(ValueError):
    """Raised when required policy data cannot be trusted."""


def _default_policy_path() -> Path:
    override = os.environ.get("AIDEVOPS_COMMAND_POLICY_CONFIG", "")
    if override:
        return Path(override)
    return Path(__file__).resolve().parent.parent / "configs" / "command-policy.json"


def _decision(decision: str, rule_id: str, reason: str) -> dict[str, Any]:
    return {
        "schema_version": 2,
        "decision": decision,
        "rule_id": rule_id,
        "reason": reason,
    }


def _policy_error(reason: str) -> dict[str, Any]:
    return _decision("forbid", "policy.invalid", reason)


def _parse_error(reason: str) -> dict[str, Any]:
    return _decision("forbid", "command.parse-error", reason)


def _load_policy(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise PolicyError(
            f"required command policy is unavailable: {path}: {exc}"
        ) from exc
    try:
        policy = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise PolicyError(f"required command policy is malformed: {path}: {exc}") from exc
    _validate_policy_shape(policy)
    return policy


def _validate_policy_shape(policy: Any) -> None:
    if not isinstance(policy, dict) or policy.get("schema_version") != 2:
        raise PolicyError("command policy schema_version must be 2")
    if policy.get("decision_order") != ["allow", "forbid"]:
        raise PolicyError("command policy decision_order must be allow, forbid")
    default = policy.get("default_decision")
    if not isinstance(default, dict) or default.get("decision") != "allow":
        raise PolicyError("command policy requires an allow default_decision")
    _validate_policy_guards(policy.get("dynamic_guards"))
    _validate_policy_rules(policy.get("rules"))
    fixtures = policy.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        raise PolicyError("command policy requires self-test fixtures")


def _validate_policy_guards(guards: Any) -> None:
    if not _has_required_guard(
        guards, "canonical_git", "canonical-git-command-guard.py"
    ):
        raise PolicyError("command policy requires exactly one canonical Git guard")
    if not _has_required_guard(guards, "worker_network", "network-tier-helper.sh"):
        raise PolicyError("command policy requires exactly one worker network guard")
    if not _has_required_guard(
        guards, "process_termination", "process-termination-guard.py"
    ):
        raise PolicyError(
            "command policy requires exactly one process-termination guard"
        )
    if not _has_required_guard(guards, "approval_freshness", "approval-helper.sh"):
        raise PolicyError(
            "command policy requires exactly one approval-freshness guard"
        )
    _validate_account_mutation_guard(guards)


def _has_required_guard(guards: Any, kind: str, helper: str) -> bool:
    matches = [
        guard
        for guard in guards or []
        if isinstance(guard, dict) and guard.get("kind") == kind
    ]
    return (
        len(matches) == 1
        and matches[0].get("helper") == helper
        and matches[0].get("decision") == "forbid"
    )


def _validate_account_mutation_guard(guards: Any) -> None:
    matches = [
        guard
        for guard in guards or []
        if isinstance(guard, dict)
        and guard.get("kind") == "trusted_account_mutation"
    ]
    if len(matches) != 1:
        raise PolicyError(
            "command policy requires exactly one trusted account-mutation guard"
        )
    guard = matches[0]
    command_paths = guard.get("command_paths")
    required_paths = {
        ("repo", "create"),
        ("repo", "fork"),
        ("repo", "new"),
    }
    required_values = {
        "decision": "forbid",
        "authorization_env": "AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION",
        "workspace_root_env": "AIDEVOPS_ACCOUNT_MUTATION_WORKSPACE_ROOT",
    }
    valid_values = all(
        guard.get(key) == expected for key, expected in required_values.items()
    )
    valid_paths = (
        isinstance(command_paths, list)
        and bool(command_paths)
        and all(
            isinstance(path, list)
            and len(path) == 2
            and all(isinstance(part, str) and part for part in path)
            for path in command_paths
        )
    )
    has_required_paths = valid_paths and required_paths.issubset(
        map(tuple, command_paths)
    )
    if not valid_values or not has_required_paths:
        raise PolicyError("trusted account-mutation guard is malformed")


def _validate_policy_rules(rules: Any) -> None:
    if not isinstance(rules, list) or not rules:
        raise PolicyError("command policy rules must be a non-empty list")
    seen_ids: set[str] = set()
    seen_matchers: set[str] = set()
    for rule in rules:
        rule_id, matcher = _validate_policy_rule(rule, seen_ids, seen_matchers)
        seen_ids.add(rule_id)
        seen_matchers.add(matcher)
    if seen_matchers != KNOWN_MATCHERS:
        raise PolicyError("command policy must define every required matcher exactly once")


def _validate_policy_rule(
    rule: Any, seen_ids: set[str], seen_matchers: set[str]
) -> tuple[str, str]:
    if not isinstance(rule, dict):
        raise PolicyError("command policy rule must be an object")
    rule_id = rule.get("id")
    matcher = rule.get("matcher")
    if not _is_new_rule_id(rule_id, seen_ids):
        raise PolicyError("command policy rule IDs must be unique non-empty strings")
    if matcher not in KNOWN_MATCHERS or matcher in seen_matchers:
        raise PolicyError(f"command policy matcher is invalid or duplicated: {matcher}")
    if rule.get("decision") != "forbid" or not isinstance(rule.get("reason"), str):
        raise PolicyError(f"command policy rule must be forbid with a reason: {rule_id}")
    return rule_id, matcher


def _is_new_rule_id(rule_id: Any, seen_ids: set[str]) -> bool:
    return isinstance(rule_id, str) and bool(rule_id) and rule_id not in seen_ids
