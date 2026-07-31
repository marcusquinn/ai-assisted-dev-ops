#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Resolve a maintainer-owned canonical branch without trusting worktree dirt."""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any, Callable


BRANCH_CONFIG_KEYS = (
    "canonical_branch",
    "integration_branch",
    "dispatch_base_branch",
    "pr_base_branch",
    "pr_target_branch",
    "base_branch",
    "default_branch",
)
GitOutput = Callable[..., str]


def _normalise_branch(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    branch = value.strip()
    for prefix in ("refs/heads/", "refs/remotes/origin/", "origin/"):
        if branch.startswith(prefix):
            return branch[len(prefix) :]
    return branch


def _branch_from_mapping(mapping: Any) -> str:
    if not isinstance(mapping, dict):
        return ""
    for key in BRANCH_CONFIG_KEYS:
        branch = _normalise_branch(mapping.get(key))
        if branch:
            return branch
    return ""


def _load_json_text(payload: str, source: str) -> Any:
    try:
        return json.loads(payload)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"configured branch metadata is unreadable: {source}: {exc}"
        ) from exc


def _load_json(path: Path) -> Any:
    try:
        return _load_json_text(path.read_text(encoding="utf-8"), str(path))
    except OSError as exc:
        raise RuntimeError(
            f"configured branch metadata is unreadable: {path}: {exc}"
        ) from exc


def _origin_slug(repo_root: str, git_output: GitOutput) -> str:
    remote_name = os.environ.get("AIDEVOPS_CANONICAL_REMOTE", "origin")
    remote = git_output(Path(repo_root), "remote", "get-url", remote_name)
    match = re.search(r"github\.com[/:]([^/\s]+/[^/\s]+?)(?:\.git)?$", remote)
    return match.group(1) if match else ""


def _project_branch(repo_root: str, git_output: GitOutput) -> tuple[str, str]:
    payload = git_output(Path(repo_root), "show", "HEAD:.aidevops.json")
    if not payload:
        return "", ""
    branch = _branch_from_mapping(_load_json_text(payload, "HEAD:.aidevops.json"))
    return (branch, "project-config-at-head") if branch else ("", "")


def _registered_config_path() -> Path:
    configured_path = os.environ.get("AIDEVOPS_REPOS_CONFIG", "")
    if configured_path:
        return Path(configured_path).expanduser()
    return Path.home() / ".config" / "aidevops" / "repos.json"


def _entry_matches_repo(entry: dict[str, Any], slug: str, repo_root: str) -> bool:
    entry_slug = entry.get("slug", "")
    entry_path = entry.get("path", "") or entry.get("repo_path", "")
    path_matches = bool(entry_path) and os.path.realpath(
        os.path.expanduser(str(entry_path))
    ) == os.path.realpath(repo_root)
    return bool((slug and entry_slug == slug) or path_matches)


def _registered_branch(repo_root: str, git_output: GitOutput) -> tuple[str, str]:
    config_path = _registered_config_path()
    if not config_path.is_file():
        return "", ""
    payload = _load_json(config_path)
    entries = payload.get("initialized_repos", []) if isinstance(payload, dict) else []
    slug = _origin_slug(repo_root, git_output)
    for entry in entries:
        if not isinstance(entry, dict) or not _entry_matches_repo(
            entry, slug, repo_root
        ):
            continue
        branch = _branch_from_mapping(entry)
        if branch:
            return branch, "registered-repo-config"
    return "", ""


def _origin_default_branch(
    repo_root: str, git_output: GitOutput
) -> tuple[str, str]:
    remote_name = os.environ.get("AIDEVOPS_CANONICAL_REMOTE", "origin")
    branch = _normalise_branch(
        git_output(
            Path(repo_root),
            "symbolic-ref",
            "--quiet",
            "--short",
            f"refs/remotes/{remote_name}/HEAD",
        )
    )
    remote_prefix = f"{remote_name}/"
    if branch.startswith(remote_prefix):
        branch = branch[len(remote_prefix) :]
    return (branch, f"{remote_name}-head") if branch else ("", "")


def _valid_branch(repo_root: str, branch: str, git_output: GitOutput) -> bool:
    return bool(git_output(Path(repo_root), "check-ref-format", "--branch", branch))


def resolve_branch(
    repo_root: str, git_output: GitOutput, policy_version: str
) -> dict[str, str]:
    """Resolve the canonical branch from trusted sources in precedence order."""
    resolvers = (_registered_branch, _project_branch, _origin_default_branch)
    for resolver in resolvers:
        branch, source = resolver(repo_root, git_output)
        if not branch:
            continue
        if not _valid_branch(repo_root, branch, git_output):
            raise RuntimeError(f"configured canonical branch is invalid: {branch}")
        return {
            "policy": policy_version,
            "branch": branch,
            "source": source,
            "repo_root": repo_root,
        }
    raise RuntimeError(
        "canonical remote default or configured canonical branch cannot be resolved"
    )
