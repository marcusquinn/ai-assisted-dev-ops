#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Extract numeric GitHub rate headers while suppressing GH_DEBUG payloads."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import List, Optional, Tuple

from gh_quota_debug_response import REQUEST_END, response_metadata


REQUEST_START = re.compile(rb"^\* Request at ")


def _frame_ranges(lines: List[bytes]) -> List[Tuple[int, int]]:
    starts = [index for index, line in enumerate(lines) if REQUEST_START.match(line)]
    ranges: List[Tuple[int, int]] = []
    for position, start in enumerate(starts):
        bound = starts[position + 1] if position + 1 < len(starts) else len(lines)
        ends = [
            index
            for index in range(start, bound)
            if REQUEST_END.match(lines[index].rstrip(b"\r\n"))
        ]
        # An unterminated debug frame is private too. Suppress it through the
        # next request frame (or EOF) instead of risking response-body leakage.
        end = ends[-1] + 1 if ends else bound
        ranges.append((start, end))
    return ranges


def _duration_ms(frame: List[bytes]) -> Optional[int]:
    for line in reversed(frame):
        match = REQUEST_END.match(line.rstrip(b"\r\n"))
        if not match:
            continue
        value = float(match.group(1))
        if match.group(2) == b"s":
            value *= 1000
        return max(0, round(value))
    return None


def _write_sanitized_stderr(
    lines: List[bytes], ranges: List[Tuple[int, int]]
) -> None:
    if not ranges:
        # Exact-capture mode deliberately enables GH_DEBUG. If its framing ever
        # changes, raw stderr may contain request headers or response bodies.
        # Suppress the whole stream rather than leak it as a normal diagnostic.
        return
    suppressed = {
        index for start, end in ranges for index in range(start, end)
    }
    for index, line in enumerate(lines):
        if index not in suppressed:
            sys.stderr.buffer.write(line)


def main() -> int:
    if len(sys.argv) != 2:
        return 2
    try:
        data = Path(sys.argv[1]).read_bytes()
    except OSError:
        return 1
    lines = data.splitlines(keepends=True)
    ranges = _frame_ranges(lines)
    _write_sanitized_stderr(lines, ranges)
    if data and not ranges:
        # Non-empty stderr without a recognized request frame may be a changed
        # GH_DEBUG format containing private request or response data. Keep it
        # suppressed and mark capture invalid rather than claiming no request.
        print("v1\tinvalid")
        return 0
    print(f"v1\t{len(ranges)}")
    for frame_index, (start, end) in enumerate(ranges, start=1):
        frame = lines[start:end]
        status_count, response, response_cost = response_metadata(frame)
        duration = _duration_ms(frame)
        values = [
            "frame",
            str(frame_index),
            str(status_count),
            response.get("status", ""),
            response.get("resource", ""),
            response.get("used", ""),
            response.get("remaining", ""),
            response.get("reset", ""),
            "" if duration is None else str(duration),
            "" if response_cost is None else str(response_cost),
        ]
        print("\t".join(values))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
