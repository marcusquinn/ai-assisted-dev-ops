#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Classify and prune explicitly regenerable worktree cache directories."""

import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import sys
import time
from typing import List, Optional, Set, Tuple

CACHE_MANIFEST_SCHEMA = "aidevops.worktree-recovery-cache-manifest/v1"

SAFE_COMPONENTS = {
    "node_modules",
    ".pnpm-store",
    ".turbo",
    ".parcel-cache",
    ".vite",
    "__pycache__",
    ".pytest_cache",
}
SAFE_CHAINS = {(".yarn", "cache"), (".next", "cache"), (".nuxt", "cache")}
SAFE_REPOSITORY_ROOTS = {".codegraph"}


def safe_root(raw_path: str) -> Optional[Tuple[str, ...]]:
    """Return the narrow recognised cache root containing a status path."""
    parts = PurePosixPath(raw_path.rstrip("/")).parts
    if not parts or parts[0] in {"/", ".", ".."} or ".." in parts:
        return None
    if parts[0] in SAFE_REPOSITORY_ROOTS:
        return parts[:1]
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


def status_has_user_data(status_path: Path, archive_root: Path, git_bin: str) -> int:
    """Return 0 for protected data, 1 for recognised caches only, 2 on uncertainty."""
    try:
        raw_status = status_path.read_bytes()
    except OSError:
        return 2
    checked: Set[Tuple[str, ...]] = set()
    for state, relative_path in status_records(raw_status):
        root_parts = safe_root(relative_path) if state == b"!!" else None
        if root_parts is None or ordinary_directory(archive_root, root_parts) is None:
            return 0
        if root_parts in checked:
            continue
        tracked_rc, tracked = git_output(
            git_bin, archive_root, ["ls-files", "-z", "--", "/".join(root_parts)]
        )
        if tracked_rc != 0:
            return 2
        if tracked:
            return 0
        checked.add(root_parts)
    return 1


def git_output(
    git_bin: str,
    source_root: Path,
    arguments: List[str],
    deadline_epoch: Optional[int] = None,
) -> Tuple[int, bytes]:
    """Run one read-only Git query with bounded captured output."""
    timeout = None
    if deadline_epoch is not None:
        timeout = deadline_epoch - time.time()
        if timeout <= 0:
            return 124, b""
    try:
        result = subprocess.run(
            [git_bin, "-C", str(source_root), *arguments],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        return 2, b""
    return result.returncode, result.stdout


def allocated_bytes(root: Path, deadline_epoch: int) -> Optional[int]:
    """Measure allocated bytes without following symlink entries or hard links."""
    total = 0
    stack = [root]
    while stack:
        if time.time() >= deadline_epoch:
            return None
        current = stack.pop()
        try:
            metadata = current.lstat()
        except OSError:
            return None
        if current == root and (not stat.S_ISDIR(metadata.st_mode) or current.is_symlink()):
            return None
        if stat.S_ISREG(metadata.st_mode) and metadata.st_nlink != 1:
            return None
        total += metadata.st_blocks * 512
        if not stat.S_ISDIR(metadata.st_mode):
            continue
        try:
            with os.scandir(current) as children:
                stack.extend(Path(child.path) for child in children)
        except OSError:
            return None
    return total


def exact_safe_root(relative_path: str) -> Optional[Tuple[str, ...]]:
    """Return a safe root only when the supplied path is exactly that root."""
    parts = PurePosixPath(relative_path).parts
    return parts if safe_root(relative_path) == parts else None


def root_identity(path: Path) -> Optional[str]:
    """Return a non-following device/inode identity for an ordinary directory."""
    try:
        metadata = path.lstat()
    except OSError:
        return None
    if not stat.S_ISDIR(metadata.st_mode) or path.is_symlink():
        return None
    return f"{metadata.st_dev}:{metadata.st_ino}"


def ignored_untracked_root(
    archive_root: Path,
    relative_root: str,
    git_bin: str,
    deadline_epoch: int,
) -> bool:
    """Prove that an exact approved root is ignored and contains no tracked path."""
    ignored_rc, _ = git_output(
        git_bin, archive_root, ["check-ignore", "-q", "--", relative_root], deadline_epoch
    )
    if ignored_rc != 0:
        return False
    tracked_rc, tracked = git_output(
        git_bin, archive_root, ["ls-files", "-z", "--", relative_root], deadline_epoch
    )
    return tracked_rc == 0 and not tracked


def cache_manifest(
    archive_root: Path,
    git_bin: str,
    max_roots: int,
    max_bytes: int,
    deadline_epoch: int,
) -> Optional[dict]:
    """Build a bounded typed manifest of currently safe cache roots."""
    if (
        not archive_root.is_absolute()
        or not archive_root.is_dir()
        or archive_root.is_symlink()
        or max_roots < 1
        or max_bytes < 1
        or time.time() >= deadline_epoch
    ):
        return None
    status_rc, raw_status = git_output(
        git_bin,
        archive_root,
        ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"],
        deadline_epoch,
    )
    if status_rc != 0:
        return None
    roots: Set[Tuple[str, ...]] = set()
    for state_value, relative_path in status_records(raw_status):
        root_parts = safe_root(relative_path) if state_value == b"!!" else None
        if root_parts is not None:
            roots.add(root_parts)
    selected = []
    selected_bytes = 0
    inspected = 0
    deferred = 0
    deadline_exhausted = False
    for root_parts in sorted(roots):
        if time.time() >= deadline_epoch:
            deadline_exhausted = True
            deferred += len(roots) - inspected
            break
        inspected += 1
        relative_root = "/".join(root_parts)
        candidate = ordinary_directory(archive_root, root_parts)
        if candidate is None or not ignored_untracked_root(
            archive_root, relative_root, git_bin, deadline_epoch
        ):
            continue
        identity = root_identity(candidate)
        measured_bytes = allocated_bytes(candidate, deadline_epoch)
        if identity is None or measured_bytes is None or measured_bytes <= 0:
            continue
        if len(selected) >= max_roots or selected_bytes + measured_bytes > max_bytes:
            deferred += 1
            continue
        selected.append(
            {
                "relative_path": relative_root,
                "expected_allocated_bytes": measured_bytes,
                "path_identity": identity,
            }
        )
        selected_bytes += measured_bytes
    return {
        "schema": CACHE_MANIFEST_SCHEMA,
        "complete": not deadline_exhausted,
        "deadline_exhausted": deadline_exhausted,
        "inspected_root_count": inspected,
        "deferred_root_count": deferred,
        "candidate_count": len(selected),
        "candidate_bytes": selected_bytes,
        "entries": selected,
    }


def validate_original_root(
    archive_root: Path,
    relative_path: str,
    expected_identity: str,
    expected_bytes: int,
    git_bin: str,
    deadline_epoch: int,
) -> int:
    """Revalidate one manifest root immediately before it is staged."""
    root_parts = exact_safe_root(relative_path)
    if root_parts is None or time.time() >= deadline_epoch:
        return 2
    candidate = ordinary_directory(archive_root, root_parts)
    if candidate is None or not ignored_untracked_root(
        archive_root, relative_path, git_bin, deadline_epoch
    ):
        return 2
    measured_bytes = allocated_bytes(candidate, deadline_epoch)
    if root_identity(candidate) != expected_identity or measured_bytes != expected_bytes:
        return 2
    return 0


def validate_staged_root(
    staged_path: Path,
    expected_identity: str,
    expected_bytes: int,
    deadline_epoch: int,
) -> int:
    """Validate one already-staged cache root for interruption recovery."""
    if not staged_path.is_absolute() or time.time() >= deadline_epoch:
        return 2
    measured_bytes = allocated_bytes(staged_path, deadline_epoch)
    if root_identity(staged_path) != expected_identity or measured_bytes != expected_bytes:
        return 2
    return 0


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
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode in {"status", "prune"} and len(sys.argv) == 5:
        _, source_raw, archive_raw, git_bin = sys.argv[1:]
        archive_root = Path(archive_raw)
        if not archive_root.is_dir() or archive_root.is_symlink():
            return 2
        if mode == "status":
            return status_has_user_data(Path(source_raw), archive_root, git_bin)
        source_root = Path(source_raw)
        if not source_root.is_dir() or source_root.is_symlink():
            return 2
        return prune_caches(source_root, archive_root, git_bin)
    if mode == "manifest" and len(sys.argv) == 7:
        _, archive_raw, git_bin, max_roots_raw, max_bytes_raw, deadline_raw = sys.argv[
            1:
        ]
        try:
            manifest = cache_manifest(
                Path(archive_raw),
                git_bin,
                int(max_roots_raw),
                int(max_bytes_raw),
                int(deadline_raw),
            )
        except ValueError:
            return 2
        if manifest is None:
            return 2
        print(json.dumps(manifest, sort_keys=True, separators=(",", ":")))
        return 0
    if mode == "validate-original" and len(sys.argv) == 8:
        _, archive_raw, relative_path, identity, bytes_raw, git_bin, deadline_raw = sys.argv[1:]
        try:
            return validate_original_root(
                Path(archive_raw),
                relative_path,
                identity,
                int(bytes_raw),
                git_bin,
                int(deadline_raw),
            )
        except ValueError:
            return 2
    if mode == "validate-staged" and len(sys.argv) == 6:
        _, staged_raw, identity, bytes_raw, deadline_raw = sys.argv[1:]
        try:
            return validate_staged_root(Path(staged_raw), identity, int(bytes_raw), int(deadline_raw))
        except ValueError:
            return 2
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
