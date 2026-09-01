#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Classify and prune explicitly regenerable worktree cache directories."""

import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
from typing import List, Optional, Set, Tuple

SAFE_COMPONENTS = {"node_modules", ".pnpm-store", ".turbo", ".parcel-cache", ".vite"}
SAFE_CHAINS = {(".yarn", "cache"), (".next", "cache"), (".nuxt", "cache")}


def safe_root(raw_path: str) -> Optional[Tuple[str, ...]]:
    """Return the narrow recognised cache root containing a status path."""
    parts = PurePosixPath(raw_path.rstrip("/")).parts
    if not parts or parts[0] in {"/", ".", ".."} or ".." in parts:
        return None
    for index, part in enumerate(parts):
        if part in SAFE_COMPONENTS:
            return parts[: index + 1]
        for chain in SAFE_CHAINS:
            if tuple(parts[index : index + len(chain)]) == chain:
                return parts[: index + len(chain)]
    return None


def ordinary_directory(root: Path, relative_parts: Tuple[str, ...]) -> Optional[Path]:
    """Resolve a directory without traversing any symlink component."""
    candidate = root
    for part in relative_parts:
        candidate = candidate / part
        if candidate.is_symlink():
            return None
    return candidate if candidate.is_dir() else None


def status_records(raw: bytes):
    """Yield porcelain state and path records without losing unusual filenames."""
    for record in raw.split(b"\0"):
        if not record:
            continue
        if len(record) < 4:
            yield b"??", ""
            continue
        yield record[:2], os.fsdecode(record[3:])


def status_has_user_data(status_path: Path, archive_root: Path) -> int:
    """Return 0 for protected data, 1 for recognised caches only, 2 on uncertainty."""
    try:
        raw_status = status_path.read_bytes()
    except OSError:
        return 2
    for state, relative_path in status_records(raw_status):
        root_parts = safe_root(relative_path) if state == b"!!" else None
        if root_parts is None or ordinary_directory(archive_root, root_parts) is None:
            return 0
    return 1


def git_output(
    git_bin: str, source_root: Path, arguments: List[str]
) -> Tuple[int, bytes]:
    """Run one read-only Git query with bounded captured output."""
    result = subprocess.run(
        [git_bin, "-C", str(source_root), *arguments],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode, result.stdout


def prune_caches(source_root: Path, archive_root: Path, git_bin: str) -> int:
    """Remove only ignored, untracked, recognised cache roots from an archive copy."""
    status_rc, raw_status = git_output(
        git_bin,
        source_root,
        ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"],
    )
    if status_rc != 0:
        return 2
    pruned: Set[Tuple[str, ...]] = set()
    for state, relative_path in status_records(raw_status):
        root_parts = safe_root(relative_path) if state == b"!!" else None
        if root_parts is None or root_parts in pruned:
            continue
        relative_root = "/".join(root_parts)
        tracked_rc, tracked = git_output(
            git_bin, source_root, ["ls-files", "-z", "--", relative_root]
        )
        if tracked_rc != 0:
            return 2
        if tracked:
            continue
        candidate = ordinary_directory(archive_root, root_parts)
        if candidate is None:
            continue
        try:
            shutil.rmtree(candidate)
        except OSError:
            return 2
        pruned.add(root_parts)
    return 0


def main() -> int:
    """Dispatch status or prune mode with fail-closed path validation."""
    if len(sys.argv) != 5:
        return 2
    mode, source_raw, archive_raw, git_bin = sys.argv[1:]
    archive_root = Path(archive_raw)
    if not archive_root.is_dir() or archive_root.is_symlink():
        return 2
    if mode == "status":
        return status_has_user_data(Path(source_raw), archive_root)
    source_root = Path(source_raw)
    if mode != "prune" or not source_root.is_dir() or source_root.is_symlink():
        return 2
    return prune_caches(source_root, archive_root, git_bin)


if __name__ == "__main__":
    raise SystemExit(main())
