# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Auditable README inventory orchestration and display totals."""

import json
import sys
from pathlib import Path

from readme_inventory_sources import DEFINITIONS, KEYS, LABELS, classify_source
from repo_metrics_git import run_command


def tracked_sources(root):
    """Select index paths; count their current worktree contents, not untracked files."""
    result = run_command(["git", "ls-files", "--stage", "-z", "--", ".agents"], root)
    if result is None or result.returncode != 0:
        raise ValueError("Cannot enumerate tracked .agents sources")
    entries = {}
    for entry in filter(None, result.stdout.split("\0")):
        metadata, name = entry.split("\t", 1)
        mode, _oid, stage = metadata.split()
        if stage != "0":
            raise ValueError("Resolve index conflicts before counting sources")
        entries[name] = mode
    if not entries:
        raise ValueError("No tracked .agents sources found")
    return entries


def inventory(root):
    root = Path(root).resolve()
    entries = tracked_sources(root)
    files = {key: [] for key in KEYS}
    for name, mode in sorted(entries.items()):
        category = classify_source(root, name, mode, entries)
        if category:
            files[category].append(name)
    return {
        "counts": {key: len(files[key]) for key in KEYS},
        "files": files,
        "definitions": DEFINITIONS,
    }


def display_counts(counts):
    """Keep the established conservative display increments, never round upward."""
    steps = {"subagents": 50, "scripts": 10, "slash_commands": 10}
    return {
        key: f"{value // steps[key] * steps[key]:,}+"
        if key in steps and value >= steps[key]
        else f"{value:,}"
        for key, value in counts.items()
    }


def show_counts(data, output):
    if output == "inventory":
        print(json.dumps(data, indent=2))
    elif output == "json":
        print(json.dumps(data["counts"]))
    elif output == "approx":
        for key, value in display_counts(data["counts"]).items():
            print(f"{key}={value}")
    else:
        for key, label in zip(KEYS, LABELS):
            print(f"{label}: {data['counts'][key]}")


if __name__ == "__main__":
    from readme_inventory_cli import main

    sys.exit(main())
