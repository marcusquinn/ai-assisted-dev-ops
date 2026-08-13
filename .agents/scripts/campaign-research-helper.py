#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Build a bounded, reference-oriented campaign research dossier from supplied evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any

from campaign_research_common import DossierError, required_text
from campaign_research_dossier import build_dossier, render_summary
from campaign_research_sources import load_intake


def atomic_write(path: Path, content: str) -> None:
    """Atomically replace one dossier artifact on its destination volume."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def run(arguments: argparse.Namespace) -> int:
    """Execute one campaign research run and preserve a previous dossier on failed refresh."""
    campaign_id = required_text(arguments.campaign_id, "campaign_id", 160)
    campaign_dir = Path(arguments.repo).resolve() / "_campaigns" / "active" / campaign_id
    if not campaign_dir.is_dir():
        raise DossierError(f"active campaign not found: {campaign_id}")
    now = dt.datetime.now(dt.timezone.utc)
    dossier = build_dossier(campaign_id, load_intake(campaign_dir), [Path(value) for value in arguments.source], now)
    research_dir = campaign_dir / "research"
    dossier_path = research_dir / "dossier.json"
    existing: dict[str, Any] | None = None
    try:
        existing = json.loads(dossier_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass
    if existing and existing.get("semantic_snapshot_sha256") == dossier["semantic_snapshot_sha256"]:
        print(f"Campaign research unchanged: {dossier_path}")
        return 0
    if dossier["coverage"]["status"] == "unavailable" and existing:
        raise DossierError("all supplied sources are unavailable; previous valid dossier was preserved")
    atomic_write(dossier_path, json.dumps(dossier, indent=2, sort_keys=True) + "\n")
    atomic_write(research_dir / "dossier.md", render_summary(dossier))
    print(f"Campaign research dossier written: {dossier_path}")
    return 0


def main() -> int:
    """Parse the narrow orchestration interface."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("campaign_id")
    parser.add_argument("--repo", default=".", help="repository containing _campaigns")
    parser.add_argument("--source", action="append", default=[], help="supplied source package JSON; repeatable")
    try:
        return run(parser.parse_args())
    except DossierError as error:
        print(f"campaign research: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
