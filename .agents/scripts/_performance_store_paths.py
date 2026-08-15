#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Repository-local path layout for the marketing performance store."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from performance_contract import PerformanceContractError


@dataclass(frozen=True)
class PlanePaths:
    """Resolved performance plane paths for one repository."""

    repo: Path
    plane: Path
    marketing: Path
    config_dir: Path
    config: Path
    raw: Path
    index: Path
    exports: Path
    quarantine: Path
    summaries: Path
    database: Path


def resolve_paths(repo: Path) -> PlanePaths:
    """Resolve but do not provision one repository-local plane."""
    resolved = repo.expanduser().resolve()
    if not resolved.is_dir():
        raise PerformanceContractError("repository path must be an existing directory")
    plane = resolved / "_performance"
    marketing = plane / "marketing"
    return PlanePaths(
        repo=resolved, plane=plane, marketing=marketing,
        config_dir=marketing / "_config", config=marketing / "_config" / "plane.json",
        raw=marketing / "raw", index=marketing / "index", exports=marketing / "exports",
        quarantine=marketing / "quarantine", summaries=marketing / "summaries",
        database=marketing / "index" / "performance.sqlite",
    )
