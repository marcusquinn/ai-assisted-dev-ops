#!/usr/bin/env python3
"""Single-process verifier for aidevops schema-1 audit JSONL segments."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any


def _error(message: str) -> None:
    print(f"[AUDIT ERROR] {message}", file=sys.stderr)


def _canonical_without_hash(entry: dict[str, Any]) -> bytes:
    content = dict(entry)
    content.pop("hash", None)
    return json.dumps(
        content,
        ensure_ascii=False,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def _verify_entry(
    entry: dict[str, Any], line_number: int, expected_prev_hash: str
) -> tuple[str, int]:
    stored_hash = entry.get("hash")
    stored_prev_hash = entry.get("prev_hash")
    if not isinstance(stored_hash, str) or not stored_hash:
        _error(f"Entry {line_number}: Missing hash field")
        return expected_prev_hash, 1

    errors = 0
    if stored_prev_hash != expected_prev_hash:
        _error(f"Entry {line_number}: Chain broken — prev_hash mismatch")
        _error(f"  Expected: {expected_prev_hash}")
        _error(f"  Found:    {stored_prev_hash or ''}")
        errors += 1

    try:
        computed_hash = hashlib.sha256(_canonical_without_hash(entry)).hexdigest()
    except (TypeError, ValueError):
        _error(f"Entry {line_number}: Invalid JSON value")
        return stored_hash, errors + 1

    if computed_hash != stored_hash:
        _error(f"Entry {line_number}: Hash mismatch — entry has been tampered with")
        _error(f"  Stored:   {stored_hash}")
        _error(f"  Computed: {computed_hash}")
        errors += 1

    return stored_hash, errors


def verify(path: Path, genesis_hash: str, quiet: bool) -> int:
    expected_prev_hash = genesis_hash
    errors = 0
    total_lines = 0

    try:
        stream = path.open("r", encoding="utf-8", errors="strict")
    except (OSError, UnicodeError) as exc:
        _error(f"Cannot read audit segment: {exc}")
        return 2

    with stream:
        for line_number, raw_line in enumerate(stream, start=1):
            total_lines = line_number
            line = raw_line.rstrip("\r\n")
            if not line:
                continue
            try:
                entry = json.loads(line)
            except (json.JSONDecodeError, UnicodeError):
                _error(f"Entry {line_number}: Invalid JSON")
                errors += 1
                continue
            if not isinstance(entry, dict):
                _error(f"Entry {line_number}: Invalid JSON object")
                errors += 1
                continue

            expected_prev_hash, entry_errors = _verify_entry(
                entry, line_number, expected_prev_hash
            )
            errors += entry_errors

    if errors:
        _error(f"Verification FAILED: {errors} error(s) in {total_lines} entries")
        return 1
    if not quiet:
        print(
            f"[AUDIT] Verification PASSED: {total_lines} entries, chain intact",
            file=sys.stderr,
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("path", type=Path)
    parser.add_argument("genesis_hash")
    parser.add_argument("quiet", choices=("true", "false"))
    args = parser.parse_args()
    return verify(args.path, args.genesis_hash, args.quiet == "true")


if __name__ == "__main__":
    raise SystemExit(main())
