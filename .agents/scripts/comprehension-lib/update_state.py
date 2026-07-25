#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Update simplification-state.json from a complete canonical-tier sweep."""
import json
import sys
from pathlib import Path

ALLOWED_TIERS = {"simple", "standard", "thinking"}


def validate_results(results):
    """Return canonical file/tier updates after validating the full sweep."""
    summary = results.get("summary", {})
    if (
        summary.get("total", 0) < 1
        or summary.get("mismatched", 0) != 0
        or summary.get("errors", 0) != 0
    ):
        raise ValueError("sweep is empty, incomplete, or contains tier mismatches")

    updates = []
    for result in results.get("results", []):
        file_path = result.get("file", "")
        tier = result.get("actual_tier", "")
        if not file_path:
            raise ValueError("sweep result is missing a file path")
        if tier not in ALLOWED_TIERS:
            raise ValueError(f"non-canonical measured tier for {file_path}: {tier}")
        if result.get("matched") is not True:
            raise ValueError(f"unreviewed expected-tier mismatch for {file_path}")
        if result.get("unresolved_scenarios", 0) != 0:
            raise ValueError(f"unresolved comprehension scenario for {file_path}")
        updates.append((file_path, tier))
    return updates


def main():
    """Validate arguments and apply tier updates to known state entries."""
    if len(sys.argv) != 3:
        raise SystemExit("usage: update_state.py RESULTS_JSON STATE_JSON")

    results_path = Path(sys.argv[1])
    state_path = Path(sys.argv[2])
    results = json.loads(results_path.read_text())
    state = json.loads(state_path.read_text())
    state_files = state.get("files")
    if not isinstance(state_files, dict):
        raise ValueError("simplification state has no files object")

    updates = validate_results(results)
    updated = 0
    for file_path, tier in updates:
        if file_path in state_files:
            state_files[file_path]["tier_minimum"] = tier
            updated += 1

    state_path.write_text(json.dumps(state, indent=2) + "\n")
    print(f"Updated {updated} entries in simplification-state.json")


if __name__ == "__main__":
    main()
