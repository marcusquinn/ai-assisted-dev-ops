#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Classify and prune explicitly regenerable worktree cache directories."""

import json
from pathlib import Path
import sys
from typing import Any, Callable, Dict, List, Optional, Tuple

from worktree_recovery_cache_policy_common import (
    GIT_OUTPUT_LIMIT_RC,
    GIT_OUTPUT_MAX_BYTES,
    SAFE_CHAINS,
    SAFE_COMPONENTS,
    SAFE_NESTED_ROOTS,
    SAFE_REPOSITORY_ROOTS,
    SAFE_ROOT_PATTERN,
    RootExpectation,
    allocated_bytes,
    allocated_entry,
    bounded_stream_output,
    exact_safe_root,
    git_output,
    ignored_untracked_root,
    ordinary_directory,
    read_process_output,
    require,
    root_identity,
    safe_root,
    start_git_process,
    status_records,
    stop_process,
    stream_wait_seconds,
    wait_for_process,
)
from worktree_recovery_cache_policy_operations import (
    CACHE_MANIFEST_SCHEMA,
    bounded_git_state,
    cache_manifest,
    discovered_cache_roots,
    manifest_candidate,
    measure_staged_root,
    prune_cache_root,
    prune_caches,
    status_bytes_have_user_data,
    status_has_user_data,
    validate_original_root,
    validate_removed_root,
    validate_removing_root,
    validate_staged_root,
)


def existing_directory(raw_path: str) -> Path:
    """Convert an ordinary existing directory or reject the mode input."""
    path = Path(raw_path)
    require(all((path.is_dir(), not path.is_symlink())), "expected an ordinary directory")
    return path


def optional_deadline(raw_deadline: str) -> Optional[int]:
    """Convert a positive deadline, mapping zero and negative values to unbounded."""
    value = max(0, int(raw_deadline))
    return {0: None}.get(value, value)


def invoke_mode(
    arguments: List[str],
    converters: Tuple[Callable[[str], Any], ...],
    operation: Callable[..., Any],
    serializer: Optional[Callable[[Any], str]] = None,
) -> int:
    """Convert one mode's arguments, invoke it, and fail closed on invalid input."""
    try:
        require(len(arguments) == len(converters) + 1, "invalid argument count")
        values = [convert(raw) for convert, raw in zip(converters, arguments[1:])]
        result = operation(*values)
        require(result is not None, "mode operation failed")
    except ValueError:
        return 2
    if serializer is not None:
        print(serializer(result))
        return 0
    return int(result)


def handle_status(arguments: List[str]) -> int:
    """Handle legacy captured-status classification."""
    return invoke_mode(
        arguments, (Path, existing_directory, str), status_has_user_data
    )


def handle_prune(arguments: List[str]) -> int:
    """Handle legacy archive cache pruning."""
    return invoke_mode(
        arguments,
        (existing_directory, existing_directory, str),
        prune_caches,
    )


def handle_git_state(arguments: List[str]) -> int:
    """Handle bounded current Git-state classification."""
    return invoke_mode(
        arguments,
        (existing_directory, str, optional_deadline),
        bounded_git_state,
    )


def handle_manifest(arguments: List[str]) -> int:
    """Handle bounded cache-manifest generation."""
    return invoke_mode(
        arguments,
        (Path, str, int, int, int),
        cache_manifest,
        lambda manifest: json.dumps(manifest, sort_keys=True, separators=(",", ":")),
    )


def handle_validate_original(arguments: List[str]) -> int:
    """Handle immediate original-root revalidation."""
    return invoke_mode(
        arguments,
        (Path, str, str, int, str, int),
        lambda archive, relative, identity, size, git, deadline: validate_original_root(
            archive, relative, RootExpectation(identity, size), git, deadline
        ),
    )


def handle_validate_staged(arguments: List[str]) -> int:
    """Handle exact staged-root validation."""
    return invoke_mode(
        arguments, (Path, str, int, int), validate_staged_root
    )


def handle_measure_staged(arguments: List[str]) -> int:
    """Handle independently measured staged allocation."""
    return invoke_mode(
        arguments, (Path, str, int, int), measure_staged_root, str
    )


def handle_validate_removing(arguments: List[str]) -> int:
    """Handle partially removed root validation."""
    return invoke_mode(
        arguments, (Path, str, int, int), validate_removing_root
    )


def handle_validate_removed(arguments: List[str]) -> int:
    """Handle post-delete namespace validation."""
    return invoke_mode(arguments, (Path, int), validate_removed_root)


MODE_HANDLERS: Dict[str, Callable[[List[str]], int]] = {
    "status": handle_status,
    "prune": handle_prune,
    "git-state": handle_git_state,
    "manifest": handle_manifest,
    "validate-original": handle_validate_original,
    "validate-staged": handle_validate_staged,
    "measure-staged": handle_measure_staged,
    "validate-removing": handle_validate_removing,
    "validate-removed": handle_validate_removed,
}


def handle_unsupported_mode(_arguments: List[str]) -> int:
    """Fail closed for an absent or unsupported mode."""
    return 2


def main() -> int:
    """Dispatch one fail-closed cache-policy mode."""
    arguments = sys.argv[1:]
    mode = next(iter(arguments), "")
    handler = MODE_HANDLERS.get(mode, handle_unsupported_mode)
    return handler(arguments)


if __name__ == "__main__":
    raise SystemExit(main())
