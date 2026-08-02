#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Git identity and path probes for the canonical write policy."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from canonical_git_policy import _git_output as _shared_git_output
from canonical_git_policy import real_git


GIT_WORKSPACE_ROOT_ENV = "AIDEVOPS_GIT_WORKSPACE_ROOT"


@dataclass
class Classification:
    """One repository-location classification."""

    classification: str
    inside_git: bool
    repo_root: str = ""
    git_dir: str = ""
    common_dir: str = ""
    branch: str = ""
    reason: str = ""


def _real_git() -> str:
    explicit = os.environ.get("AIDEVOPS_REAL_GIT_BIN", "") or os.environ.get(
        "AIDEVOPS_REAL_GIT", ""
    )
    if not explicit and os.path.isfile("/usr/bin/git"):
        explicit = "/usr/bin/git"
    return real_git(explicit)


def git_output(cwd: Path, *args: str) -> str:
    try:
        return _shared_git_output(_real_git(), str(cwd), *args)
    except RuntimeError as exc:
        raise RuntimeError(f"Git repository probe failed: {exc}") from exc


def _existing_probe_path(raw_path: str) -> Path:
    path = Path(raw_path).expanduser().resolve(strict=False)
    if path.is_file() or path.is_symlink():
        path = path.parent
    while not path.exists() and path != path.parent:
        path = path.parent
    return path


def _repository_probes(probe_path: Path) -> dict[str, str]:
    return {
        "repo_root": git_output(probe_path, "rev-parse", "--show-toplevel"),
        "git_dir": git_output(probe_path, "rev-parse", "--git-dir"),
        "common_dir": git_output(probe_path, "rev-parse", "--git-common-dir"),
        "branch": git_output(probe_path, "branch", "--show-current"),
    }


def _absolute_probe_value(probe_path: Path, raw_value: str) -> str:
    path = Path(raw_value)
    if not path.is_absolute():
        path = probe_path / path
    return os.path.realpath(path)


def classify_location(raw_path: str) -> Classification:
    """Classify a path as canonical, linked, outside Git, or unknown."""
    probe_path = _existing_probe_path(raw_path)
    try:
        inside = git_output(probe_path, "rev-parse", "--is-inside-work-tree")
    except RuntimeError as exc:
        return Classification("unknown", False, reason=str(exc))
    if inside != "true":
        return Classification(
            "outside", False, reason="path is outside a Git worktree"
        )

    try:
        values = _repository_probes(probe_path)
    except RuntimeError as exc:
        return Classification("unknown", True, reason=str(exc))

    required = ("repo_root", "git_dir", "common_dir")
    if any(not values[name] for name in required):
        return Classification(
            "unknown",
            True,
            reason="required Git worktree identity could not be resolved",
        )

    repo_root = _absolute_probe_value(probe_path, values["repo_root"])
    git_dir = _absolute_probe_value(probe_path, values["git_dir"])
    common_dir = _absolute_probe_value(probe_path, values["common_dir"])
    classification = "canonical" if git_dir == common_dir else "linked"
    return Classification(
        classification,
        True,
        repo_root=repo_root,
        git_dir=git_dir,
        common_dir=common_dir,
        branch=values["branch"],
        reason=(
            "Git directory equals common directory"
            if classification == "canonical"
            else "Git directory is isolated beneath the common directory"
        ),
    )


def target_probe(cwd: str, file_path: str) -> str:
    if not file_path:
        return cwd
    target = Path(file_path).expanduser()
    if not target.is_absolute():
        target = Path(cwd) / target
    return str(target.resolve(strict=False))


def git_symlink_origin(cwd: str, file_path: str) -> Classification | None:
    """Return the Git location containing a traversed symlink, if any."""
    target = Path(file_path).expanduser()
    if not target.is_absolute():
        base = Path(cwd).expanduser()
        if not base.is_absolute():
            base = Path.cwd() / base
        target = base / target
    current = Path(target.anchor)
    for part in target.parts[1:]:
        if part in ("", "."):
            continue
        if part == "..":
            current = current.parent
            continue
        candidate = current / part
        if candidate.is_symlink():
            origin = classify_location(str(current))
            if origin.inside_git:
                return origin
            current = Path(os.path.realpath(candidate))
            continue
        current = candidate
    return None


def git_workspace_root_from_environment() -> str:
    """Return the trusted Git workspace root, defaulting to ~/Git."""
    if GIT_WORKSPACE_ROOT_ENV in os.environ:
        return os.environ[GIT_WORKSPACE_ROOT_ENV]
    return str(Path.home() / "Git")


def canonical_git_workspace_root(workspace_root: str) -> str:
    if not workspace_root:
        return ""
    root = os.path.realpath(os.path.expanduser(workspace_root))
    home = os.path.realpath(str(Path.home()))
    if root in {os.path.abspath(os.sep), home} or not os.path.isdir(root):
        return ""
    return root


def is_within_workspace(path: str, workspace_root: str) -> bool:
    if not path or not workspace_root:
        return False
    try:
        return (
            os.path.commonpath([os.path.realpath(path), workspace_root])
            == workspace_root
        )
    except ValueError:
        return False


def repository_within_workspace(
    location: Classification, workspace_root: str
) -> bool:
    """Require the worktree and its shared Git metadata beneath one root."""
    return location.inside_git and all(
        is_within_workspace(path, workspace_root)
        for path in (location.repo_root, location.git_dir, location.common_dir)
    )
