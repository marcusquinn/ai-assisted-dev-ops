#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Extract numeric GitHub rate headers while suppressing GH_DEBUG payloads."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple


REQUEST_START = re.compile(rb"^\* Request at ")
REQUEST_END = re.compile(
    rb"^\* Request took ([0-9]+(?:\.[0-9]+)?)(ms|s)\s*$"
)
RESPONSE_STATUS = re.compile(rb"^< HTTP/\S+\s+([0-9]{3})(?:\s+.*)?$", re.IGNORECASE)
RATE_HEADER = re.compile(
    rb"^< X-Ratelimit-(Resource|Used|Remaining|Reset):\s*([^\s]+)\s*$",
    re.IGNORECASE,
)
RATE_FIELDS = frozenset({"resource", "used", "remaining", "reset"})


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


def _graphql_rate_cost(body: List[bytes]) -> Optional[int]:
    try:
        payload = json.loads(b"\n".join(body))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    data = payload.get("data")
    rate_limit = data.get("rateLimit") if isinstance(data, dict) else None
    cost = rate_limit.get("cost") if isinstance(rate_limit, dict) else None
    if isinstance(cost, bool) or not isinstance(cost, int) or cost < 0:
        return None
    return cost


def _response_metadata(
    frame: List[bytes],
) -> Tuple[int, Dict[str, str], Optional[int]]:
    responses: List[Tuple[Dict[str, str], List[bytes]]] = []
    current: Optional[Dict[str, str]] = None
    current_body: Optional[List[bytes]] = None
    in_headers = False
    for line in frame:
        stripped = line.rstrip(b"\r\n")
        status_match = RESPONSE_STATUS.match(stripped)
        if status_match:
            current = {"status": status_match.group(1).decode("ascii")}
            current_body = []
            responses.append((current, current_body))
            in_headers = True
            continue
        if in_headers and stripped == b"":
            in_headers = False
            continue
        if current is not None and current_body is not None and not in_headers:
            if not REQUEST_END.match(stripped):
                current_body.append(stripped)
            continue
        if current is None:
            continue
        header_match = RATE_HEADER.match(stripped)
        if not header_match:
            continue
        name = header_match.group(1).decode("ascii").lower()
        value = header_match.group(2).decode("ascii", errors="ignore")
        current[name] = value
    rate_responses = [
        response for response in responses if RATE_FIELDS <= response[0].keys()
    ]
    if not rate_responses:
        return 0, {}, None
    headers, body = rate_responses[-1]
    return len(rate_responses), headers, _graphql_rate_cost(body)


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
        status_count, response, response_cost = _response_metadata(frame)
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
