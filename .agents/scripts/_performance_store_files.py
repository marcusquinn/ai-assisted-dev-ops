#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Atomic local file creation for performance store provisioning."""

from __future__ import annotations

import os
from pathlib import Path

from performance_contract import PerformanceContractError


def write_new(path: Path, content: bytes, mode: int) -> None:
    """Create one file atomically without replacing user-owned state."""
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise PerformanceContractError(f"performance plane file is unsafe: {path.name}")
    if path.exists():
        return
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise PerformanceContractError(f"performance plane file is unsafe: {path.name}")
        if path.exists():
            temporary.unlink()
            return
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()
