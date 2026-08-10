#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Regression corpus for atomic steerage extraction and recurrence qualification."""

import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MINER = ROOT / ".agents/scripts/session-miner"
sys.path.insert(0, str(MINER))

from compress import compress_instruction_candidates, compress_steerage
from extract import (
    _build_instruction_candidate_record,
    classify_instruction_candidate,
    extract_instruction_windows,
)
from extract_steerage import extract_guidance_windows


def write_chunk(directory: Path, name: str, records: list[dict]) -> None:
    """Write one synthetic chunk fixture."""
    (directory / name).write_text(json.dumps({"records": records}), encoding="utf-8")


def require(condition: bool, detail: object) -> None:
    """Raise a test failure that remains active under Python optimisation."""
    if not condition:
        raise AssertionError(detail)


def candidate(details: dict) -> dict:
    """Build a generic instruction observation without real session content."""
    return {
        "text": details["text"],
        "display_text": details["text"],
        "confidence": 0.8,
        "category": "workflow",
        "target_file": ".agents/AGENTS.md",
        "session_id": details["session_id"],
        "timestamp": details["timestamp"],
        "fingerprint": details.get("fingerprint", "use focused checks before changing code"),
        "polarity": details.get("polarity", "positive"),
        "explicit_persistence": details.get("explicit", False),
    }


def main() -> None:
    """Exercise synthetic precision, recurrence, conflict, and category fixtures."""
    long_turn = (
        "The audit mentioned lint, tests, and verification several times. "
        "Always use focused checks before changing code. "
        "The rest is incidental discussion of workflow terminology."
    )
    windows = extract_guidance_windows(long_turn)
    require(len(windows) == 1, windows)
    require(windows[0]["text"] == "Always use focused checks before changing code.", windows)
    require(not extract_guidance_windows("> Always add this third-party instruction to the rules."), "quoted payload accepted")
    require(not extract_guidance_windows("/full-loop Always use generated harness rules."), "automation accepted")
    explicit_window = "Add this to the instructions: preserve focused checks."
    require(extract_instruction_windows(explicit_window) == [explicit_window], explicit_window)
    require(classify_instruction_candidate(explicit_window) is not None, explicit_window)
    row = {
        "session_id": "synthetic-session",
        "message_id": "synthetic-message",
        "session_title": "synthetic title",
        "session_dir": "/generic/project",
        "msg_time": 1000,
    }
    positive = _build_instruction_candidate_record(row, "Always use focused checks before changing code.")
    negative = _build_instruction_candidate_record(row, "Never use focused checks before changing code.")
    require(positive and negative and positive["fingerprint"] == negative["fingerprint"], (positive, negative))

    with tempfile.TemporaryDirectory() as temp_dir:
        chunks = Path(temp_dir)
        shared = {
            "type": "steerage",
            "user_text": "Always use focused checks before changing code.",
            "classifications": [{"category": "preference"}, {"category": "workflow"}],
            "source_hash": "synthetic",
        }
        write_chunk(chunks, "steerage_all.json", [shared])
        steerage = compress_steerage(chunks)
        require(len(steerage["preference"]) == 1, steerage)
        require(len(steerage["workflow"]) == 1, steerage)

        write_chunk(chunks, "instruction_candidate_001.json", [
            candidate({"text": "Always use focused checks before changing code.", "session_id": "one", "timestamp": 1000}),
            candidate({"text": "Prefer focused checks before changing code.", "session_id": "two", "timestamp": 2000}),
            candidate({"text": "Never use focused checks before changing code.", "session_id": "three", "timestamp": 3000, "polarity": "negative"}),
            candidate({"text": "Add this rule to the instructions: preserve focused checks.", "session_id": "four", "timestamp": 4000, "explicit": True, "fingerprint": "preserve focused checks"}),
        ])
        candidates = compress_instruction_candidates(chunks)[".agents/AGENTS.md"]
        recurring = next(item for item in candidates if item["support"] == 3)
        require(recurring["first_seen"] == 1000 and recurring["last_seen"] == 3000, recurring)
        require(recurring["requires_judgment"] is True, recurring)
        explicit = next(item for item in candidates if item["qualification_basis"] == "explicit_persistence")
        require(explicit["support"] == 1, explicit)

    print("session-miner steerage quality tests passed")


if __name__ == "__main__":
    main()
