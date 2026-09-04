#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Recovery cache classification, manifest, validation, and pruning operations."""

from pathlib import Path
import shutil
import time
from typing import Optional, Set, Tuple

from worktree_recovery_cache_policy_common import (
    RootExpectation,
    allocated_bytes,
    exact_safe_root,
    git_output,
    ignored_untracked_root,
    ordinary_directory,
    require,
    root_identity,
    safe_root,
    status_records,
)

CACHE_MANIFEST_SCHEMA = "aidevops.worktree-recovery-cache-manifest/v1"


def status_bytes_have_user_data(
    raw_status: bytes,
    archive_root: Path,
    git_bin: str,
    deadline_epoch: Optional[int] = None,
) -> int:
    """Return 0 for protected data, 1 for recognised caches only, 2 on uncertainty."""
    checked: Set[Tuple[str, ...]] = set()
    for state, relative_path in status_records(raw_status):
        root_parts = safe_root(relative_path) if state == b"!!" else None
        if root_parts is None or ordinary_directory(archive_root, root_parts) is None:
            return 0
        if root_parts in checked:
            continue
        tracked_rc, tracked = git_output(
            git_bin,
            archive_root,
            ["ls-files", "-z", "--", "/".join(root_parts)],
            deadline_epoch,
        )
        if tracked_rc != 0:
            return 2
        if tracked:
            return 0
        checked.add(root_parts)
    return 1


def status_has_user_data(status_path: Path, archive_root: Path, git_bin: str) -> int:
    """Classify a previously captured status file."""
    try:
        raw_status = status_path.read_bytes()
    except OSError:
        return 2
    return status_bytes_have_user_data(raw_status, archive_root, git_bin)


def bounded_git_state(
    archive_root: Path, git_bin: str, deadline_epoch: Optional[int]
) -> int:
    """Classify current Git state without an unbounded status capture."""
    status_rc, raw_status = git_output(
        git_bin,
        archive_root,
        ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"],
        deadline_epoch,
    )
    if status_rc != 0:
        return 2
    return status_bytes_have_user_data(raw_status, archive_root, git_bin, deadline_epoch)


def discovered_cache_roots(raw_status: bytes) -> Set[Tuple[str, ...]]:
    """Collect recognised ignored cache roots from bounded status output."""
    ignored_paths = (
        relative_path
        for state_value, relative_path in status_records(raw_status)
        if state_value == b"!!"
    )
    return {root for path in ignored_paths if (root := safe_root(path)) is not None}


def manifest_candidate(
    archive_root: Path,
    root_parts: Tuple[str, ...],
    git_bin: str,
    deadline_epoch: int,
) -> Optional[dict]:
    """Build one candidate only after identity and Git safety proofs pass."""
    relative_root = "/".join(root_parts)
    candidate = ordinary_directory(archive_root, root_parts)
    try:
        require(candidate is not None, "cache root is not an ordinary directory")
        require(
            ignored_untracked_root(
                archive_root, relative_root, git_bin, deadline_epoch
            ),
            "cache root is not ignored and untracked",
        )
        identity = root_identity(candidate)
        measured_bytes = allocated_bytes(candidate, deadline_epoch)
        require(
            all(
                (
                    identity is not None,
                    measured_bytes is not None,
                    measured_bytes is not None and measured_bytes > 0,
                )
            ),
            "cache root allocation or identity is invalid",
        )
    except ValueError:
        return None
    return {
        "relative_path": relative_root,
        "expected_allocated_bytes": measured_bytes,
        "path_identity": identity,
    }


def cache_manifest(
    archive_root: Path,
    git_bin: str,
    max_roots: int,
    max_bytes: int,
    deadline_epoch: int,
) -> Optional[dict]:
    """Build a bounded typed manifest of currently safe cache roots."""
    valid_request = all(
        (
            archive_root.is_absolute(),
            archive_root.is_dir(),
            not archive_root.is_symlink(),
            max_roots >= 1,
            max_bytes >= 1,
            time.time() < deadline_epoch,
        )
    )
    if not valid_request:
        return None
    status_rc, raw_status = git_output(
        git_bin,
        archive_root,
        ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"],
        deadline_epoch,
    )
    if status_rc != 0:
        return None
    roots = discovered_cache_roots(raw_status)
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
        candidate = manifest_candidate(
            archive_root, root_parts, git_bin, deadline_epoch
        )
        if candidate is None:
            continue
        measured_bytes = candidate["expected_allocated_bytes"]
        fits = all(
            (
                len(selected) < max_roots,
                selected_bytes + measured_bytes <= max_bytes,
            )
        )
        selected.extend([candidate] * int(fits))
        selected_bytes += measured_bytes * int(fits)
        deferred += int(not fits)
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
    expected: RootExpectation,
    git_bin: str,
    deadline_epoch: int,
) -> int:
    """Revalidate one manifest root immediately before it is staged."""
    root_parts = exact_safe_root(relative_path)
    try:
        require(root_parts is not None, "manifest path is not an exact safe root")
        require(time.time() < deadline_epoch, "validation deadline expired")
        candidate = ordinary_directory(archive_root, root_parts)
        require(candidate is not None, "cache root is not an ordinary directory")
        require(
            ignored_untracked_root(
                archive_root, relative_path, git_bin, deadline_epoch
            ),
            "cache root is not ignored and untracked",
        )
    except ValueError:
        return 2
    measured_bytes = allocated_bytes(candidate, deadline_epoch)
    matches_manifest = all(
        (
            root_identity(candidate) == expected.identity,
            measured_bytes == expected.allocated_bytes,
        )
    )
    return 2 * int(not matches_manifest)


def validate_staged_root(
    staged_path: Path,
    expected_identity: str,
    expected_bytes: int,
    deadline_epoch: int,
) -> int:
    """Validate one already-staged cache root for interruption recovery."""
    measurement = measure_staged_root(
        staged_path, expected_identity, expected_bytes, deadline_epoch
    )
    return 2 * int(measurement is None)


def measure_staged_root(
    staged_path: Path,
    expected_identity: str,
    expected_bytes: int,
    deadline_epoch: int,
) -> Optional[int]:
    """Return the exact current allocation for one validated staged root."""
    try:
        require(staged_path.is_absolute(), "staged path is not absolute")
        require(time.time() < deadline_epoch, "measurement deadline expired")
        measured_bytes = allocated_bytes(staged_path, deadline_epoch)
        require(root_identity(staged_path) == expected_identity, "identity changed")
        require(measured_bytes == expected_bytes, "allocation changed")
    except ValueError:
        return None
    return measured_bytes


def validate_removing_root(
    staged_path: Path,
    expected_identity: str,
    expected_bytes: int,
    deadline_epoch: int,
) -> int:
    """Validate an isolated cache root that may be partly removed on retry."""
    root_is_absent = not staged_path.exists() and not staged_path.is_symlink()
    measured_bytes = allocated_bytes(staged_path, deadline_epoch)
    measured_or_unsafe = {None: expected_bytes + 1}.get(measured_bytes, measured_bytes)
    is_valid = all(
        (
            staged_path.is_absolute(),
            time.time() < deadline_epoch,
            root_is_absent
            or all(
                (
                    root_identity(staged_path) == expected_identity,
                    measured_or_unsafe <= expected_bytes,
                )
            ),
        )
    )
    return 2 * int(not is_valid)


def validate_removed_root(staged_path: Path, deadline_epoch: int) -> int:
    """Prove the staged namespace has zero remaining allocated bytes."""
    root_is_absent = not staged_path.exists() and not staged_path.is_symlink()
    is_valid = all(
        (staged_path.is_absolute(), time.time() < deadline_epoch, root_is_absent)
    )
    return 2 * int(not is_valid)


def prune_cache_root(
    source_root: Path,
    archive_root: Path,
    root_parts: Tuple[str, ...],
    git_bin: str,
) -> int:
    """Prune one cache root, returning 1 when it must be preserved."""
    relative_root = "/".join(root_parts)
    tracked_rc, tracked = git_output(
        git_bin, source_root, ["ls-files", "-z", "--", relative_root]
    )
    if tracked_rc != 0:
        return 2
    if tracked:
        return 1
    candidate = ordinary_directory(archive_root, root_parts)
    if candidate is None:
        return 1
    try:
        shutil.rmtree(candidate)
    except OSError:
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
        prune_rc = prune_cache_root(source_root, archive_root, root_parts, git_bin)
        if prune_rc == 2:
            return 2
        pruned.update([root_parts] * int(prune_rc == 0))
    return 0
