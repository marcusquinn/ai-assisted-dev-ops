#!/usr/bin/env python3
"""Serialize and atomically write aidevops Buzz team snapshots."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import json
import os
from pathlib import Path
import tempfile


MAX_SNAPSHOT_BYTES = 5 * 1024 * 1024


class SnapshotIOError(ValueError):
    """Raised when a snapshot output cannot be produced safely."""


def serialized_snapshot(snapshot):
    """Return stable pretty-printed UTF-8 JSON bytes."""
    payload = (json.dumps(snapshot, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    if len(payload) > MAX_SNAPSHOT_BYTES:
        raise SnapshotIOError("generated Buzz team snapshot exceeds the 5 MiB decoded limit")
    return payload


def validate_output_path(output_path, agents_dir, ensure_output_is_not_source):
    """Validate an explicit caller-owned output without following a target symlink."""
    expanded = Path(os.path.expanduser(output_path))
    if expanded.is_symlink():
        raise SnapshotIOError("output must not replace a symbolic link")
    parent = expanded.parent.resolve()
    if not parent.is_dir():
        raise SnapshotIOError("output parent directory is unavailable")
    resolved = parent / expanded.name
    ensure_output_is_not_source(resolved, agents_dir)
    return resolved


def downloads_output_path(agents_dir, ensure_output_is_not_source):
    """Resolve the user-facing native-import destination under Downloads."""
    configured = os.environ.get("AIDEVOPS_DOWNLOADS_DIR")
    downloads = Path(os.path.expanduser(configured)) if configured else Path.home() / "Downloads"
    if not downloads.is_absolute():
        raise SnapshotIOError("AIDEVOPS_DOWNLOADS_DIR must be absolute")
    downloads.mkdir(mode=0o700, parents=False, exist_ok=True)
    return validate_output_path(
        downloads / "aidevops.team.json", agents_dir, ensure_output_is_not_source
    )


def atomic_write(output_path, payload):
    """Atomically replace one explicit output with an owner-only regular file."""
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output_path.name}.", dir=output_path.parent)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        descriptor = -1
        os.replace(temporary_path, output_path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary_path.unlink(missing_ok=True)
