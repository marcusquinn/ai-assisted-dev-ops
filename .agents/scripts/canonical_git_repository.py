#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Native Git resolution and canonical-repository probes."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path


def real_git(explicit: str = "") -> str:
    """Resolve the real Git executable without selecting the sibling shim."""
    if explicit:
        return explicit
    guard_dir = Path(__file__).resolve().parent
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory or ".") / "git"
        try:
            if (
                candidate.is_file()
                and os.access(candidate, os.X_OK)
                and candidate.resolve().parent != guard_dir
            ):
                return str(candidate.resolve())
        except OSError:
            continue
    return shutil.which("git") or "/usr/bin/git"


def git_output(real_git_path: str, cwd: str, *args: str) -> str:
    try:
        result = subprocess.run(
            [real_git_path, *args],
            cwd=cwd,
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("native Git repository probe timed out") from error
    except OSError as error:
        raise RuntimeError("native Git repository probe failed to start") from error
    return result.stdout.strip() if result.returncode == 0 else ""


def _repos_file() -> Path:
    configured = os.environ.get("AIDEVOPS_REPOS_FILE") or os.environ.get(
        "AIDEVOPS_REPOS_JSON"
    )
    return Path(configured or "~/.config/aidevops/repos.json").expanduser()


def _registered_roots() -> list[Path]:
    try:
        payload = json.loads(_repos_file().read_text(encoding="utf-8"))
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError):
        return []
    if not isinstance(payload, dict):
        return []
    entries = payload.get("initialized_repos", [])
    if not isinstance(entries, list):
        return []
    roots: list[Path] = []
    for entry in entries:
        if not isinstance(entry, dict) or not entry.get("path"):
            continue
        try:
            roots.append(Path(str(entry["path"])).expanduser().resolve())
        except (OSError, RuntimeError, ValueError):
            continue
    return roots


def _is_managed_root(repo_root: str) -> bool:
    root = Path(repo_root).resolve()
    return (root / ".aidevops.json").is_file() or root in _registered_roots()


def _is_registered_common_dir(common_dir: str) -> bool:
    common = Path(common_dir).resolve()
    for root in _registered_roots():
        dot_git = root / ".git"
        if dot_git.is_dir() and dot_git.resolve() == common:
            return True
        if not dot_git.is_file():
            continue
        try:
            marker = dot_git.read_text(encoding="utf-8").strip()
            if not marker.startswith("gitdir:"):
                continue
            target = Path(marker.split(":", 1)[1].strip()).expanduser()
            if not target.is_absolute():
                target = root / target
            if target.resolve() == common:
                return True
        except (OSError, RuntimeError, ValueError):
            continue
    return False


def _has_worktree_override(git_prefix: list[str]) -> bool:
    return bool(
        os.environ.get("GIT_WORK_TREE")
        or "--work-tree" in git_prefix
        or any(value.startswith("--work-tree=") for value in git_prefix)
    )


def _linked_worktree_root(git_dir: str) -> Path | None:
    metadata_dir = Path(git_dir).resolve()
    try:
        marker = (metadata_dir / "gitdir").read_text(encoding="utf-8").strip()
        marker_path = Path(marker).expanduser()
        if not marker_path.is_absolute():
            marker_path = metadata_dir / marker_path
        marker_path = marker_path.resolve()
    except (OSError, RuntimeError, ValueError):
        return None
    return marker_path.parent if marker_path.name == ".git" else None


def is_canonical(real_git_path: str, cwd: str, git_prefix: list[str]) -> bool:
    git_dir = git_output(
        real_git_path,
        cwd,
        *git_prefix,
        "rev-parse",
        "--path-format=absolute",
        "--git-dir",
    )
    common_dir = git_output(
        real_git_path,
        cwd,
        *git_prefix,
        "rev-parse",
        "--path-format=absolute",
        "--git-common-dir",
    )
    repo_root = git_output(
        real_git_path,
        cwd,
        *git_prefix,
        "rev-parse",
        "--path-format=absolute",
        "--show-toplevel",
    )
    canonical_common_dir = os.path.realpath(common_dir) if common_dir else ""
    canonical_git_dir = os.path.realpath(git_dir) if git_dir else ""
    configured_worktree = git_output(
        real_git_path,
        cwd,
        *git_prefix,
        "config",
        "--path",
        "--get",
        "core.worktree",
    )
    if _has_worktree_override(git_prefix):
        pass
    elif configured_worktree:
        worktree_path = Path(configured_worktree).expanduser()
        if not worktree_path.is_absolute():
            worktree_path = Path(canonical_common_dir) / worktree_path
        repo_root = str(worktree_path.resolve())
    elif (
        canonical_git_dir == canonical_common_dir
        and os.path.basename(canonical_common_dir) == ".git"
    ):
        repo_root = os.path.dirname(canonical_common_dir)
    if not git_dir or not common_dir or not repo_root:
        return False
    if canonical_git_dir == canonical_common_dir:
        return _is_managed_root(repo_root) or _is_registered_common_dir(
            canonical_common_dir
        )
    linked_root = _linked_worktree_root(canonical_git_dir)
    if linked_root and linked_root == Path(repo_root).resolve():
        return False
    return _is_managed_root(repo_root)
