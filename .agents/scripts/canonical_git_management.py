#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Resolve aidevops-managed repository roots and Git metadata."""

from __future__ import annotations

import json
import os
from pathlib import Path


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


def _gitdir_target(root: Path) -> Path | None:
    dot_git = root / ".git"
    if not dot_git.is_file():
        return None
    try:
        marker = dot_git.read_text(encoding="utf-8").strip()
        if not marker.startswith("gitdir:"):
            return None
        target = Path(marker.split(":", 1)[1].strip()).expanduser()
        if not target.is_absolute():
            target = root / target
        return target.resolve()
    except (OSError, RuntimeError, ValueError):
        return None


def is_managed_root(repo_root: str) -> bool:
    root = Path(repo_root).resolve()
    git_dir = _gitdir_target(root)
    if git_dir and linked_worktree_root(str(git_dir)) == root:
        return False
    return (root / ".aidevops.json").is_file() or root in _registered_roots()


def is_registered_common_dir(common_dir: str) -> bool:
    common = Path(common_dir).resolve()
    for root in _registered_roots():
        dot_git = root / ".git"
        if dot_git.is_dir() and dot_git.resolve() == common:
            return True
        if _gitdir_target(root) == common:
            return True
    return False


def linked_worktree_root(git_dir: str) -> Path | None:
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
