#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Extract numeric GitHub rate headers while suppressing GH_DEBUG payloads."""

from __future__ import annotations

import re
import sys
from datetime import datetime
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from gh_quota_debug_response import REQUEST_END, response_metadata


REQUEST_START = re.compile(
    rb"^\* Request at (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)? [+-]\d{4})"
)
GO_DURATION_COMPONENT = re.compile(
    rb"([0-9]+(?:\.[0-9]+)?)(ns|(?:\xc2\xb5|\xce\xbc|u)s|ms|s|m|h)"
)
DURATION_MS_FACTORS = {
    b"ns": 0.000001,
    b"us": 0.001,
    b"\xc2\xb5s": 0.001,
    b"\xce\xbcs": 0.001,
    b"ms": 1.0,
    b"s": 1000.0,
}
DURATION_SECONDS_FACTORS = {
    **{unit: factor / 1000 for unit, factor in DURATION_MS_FACTORS.items()},
    b"m": 60.0,
    b"h": 3600.0,
}
CACHE_HOST = b"api.github.com"
CACHE_MIN_AGE_SECONDS = 2.0
CACHE_TTL_GRACE_SECONDS = 5.0
CACHE_RESET_GRACE_SECONDS = 5.0
CacheRequest = Tuple[datetime, float]


def _request_ranges(lines: List[bytes]) -> List[Tuple[int, int]]:
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


def _completion_ranges(lines: List[bytes]) -> List[Tuple[int, int]]:
    ranges: List[Tuple[int, int]] = []
    start = 0
    for index, line in enumerate(lines):
        if REQUEST_END.match(line.rstrip(b"\r\n")):
            ranges.append((start, index + 1))
            start = index + 1
    return ranges


def _duration(frame: List[bytes]) -> Optional[Tuple[float, bytes]]:
    for line in reversed(frame):
        match = REQUEST_END.match(line.rstrip(b"\r\n"))
        if not match:
            continue
        return float(match.group(1)), match.group(2)
    return None


def _duration_ms(frame: List[bytes]) -> Optional[int]:
    duration = _duration(frame)
    if duration is None:
        return None
    value, unit = duration
    factor = DURATION_MS_FACTORS.get(unit)
    if factor is None:
        return None
    return max(0, round(value * factor))


def _request_header(frame: List[bytes], name: bytes) -> Optional[bytes]:
    prefix = b"> " + name.lower() + b":"
    for line in frame:
        stripped = line.rstrip(b"\r\n")
        if stripped.lower().startswith(prefix):
            return stripped.split(b":", 1)[1].strip()
    return None


def _go_duration_seconds(value: bytes) -> Optional[float]:
    offset = 0
    total = 0.0
    for match in GO_DURATION_COMPONENT.finditer(value):
        if match.start() != offset:
            return None
        factor = DURATION_SECONDS_FACTORS.get(match.group(2))
        if factor is None:
            return None
        total += float(match.group(1)) * factor
        offset = match.end()
    return total if offset == len(value) and offset > 0 else None


def _request_time(frame: List[bytes]) -> Optional[datetime]:
    if not frame:
        return None
    match = REQUEST_START.match(frame[0].rstrip(b"\r\n"))
    if match is None:
        return None
    value = match.group(1).decode("ascii", errors="ignore")
    time_format = (
        "%Y-%m-%d %H:%M:%S.%f %z" if "." in value else "%Y-%m-%d %H:%M:%S %z"
    )
    try:
        return datetime.strptime(value, time_format)
    except ValueError:
        return None


def _cache_request(frame: List[bytes]) -> Optional[CacheRequest]:
    if _request_header(frame, b"host") != CACHE_HOST:
        return None
    ttl_value = _request_header(frame, b"x-gh-cache-ttl")
    ttl_seconds = _go_duration_seconds(ttl_value) if ttl_value is not None else None
    request_time = _request_time(frame)
    if ttl_seconds is None or ttl_seconds <= 0 or request_time is None:
        return None
    return request_time, ttl_seconds


def _consume_proven_cache_hit(
    response: Dict[str, str], cache_requests: List[CacheRequest]
) -> bool:
    # go-gh's HTTP logger wraps its local cache RoundTripper, so cache hits emit
    # normal request/response blocks. Exclude one only when four independent
    # properties agree: github.com host, positive cache TTL, a persisted response
    # Date that is still inside that TTL, and a retained rate-window reset that
    # expired before this request. The expired reset is response-owned proof of
    # stale metadata and stays reliable when local cache work takes milliseconds
    # under load. Request and completion streams are matched by evidence count
    # because concurrent gh queries may interleave their starts before either
    # response is logged.
    try:
        reset_epoch = int(response.get("reset", ""))
    except ValueError:
        return False
    try:
        response_time = parsedate_to_datetime(response.get("date", ""))
        if response_time.tzinfo is None or response_time.utcoffset() is None:
            return False
    except (TypeError, ValueError):
        return False
    for index, (request_time, ttl_seconds) in enumerate(cache_requests):
        age_seconds = (request_time - response_time).total_seconds()
        reset_expired = (
            reset_epoch + CACHE_RESET_GRACE_SECONDS < request_time.timestamp()
        )
        if (
            CACHE_MIN_AGE_SECONDS < age_seconds <= ttl_seconds + CACHE_TTL_GRACE_SECONDS
            and reset_expired
        ):
            del cache_requests[index]
            return True
    return False


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
    request_ranges = _request_ranges(lines)
    _write_sanitized_stderr(lines, request_ranges)
    if data and not request_ranges:
        # Non-empty stderr without a recognized request frame may be a changed
        # GH_DEBUG format containing private request or response data. Keep it
        # suppressed and mark capture invalid rather than claiming no request.
        print("v1\tinvalid")
        return 0
    cache_requests = []
    for start, end in request_ranges:
        request = _cache_request(lines[start:end])
        if request is not None:
            cache_requests.append(request)
    transport_frames = []
    completion_ranges = _completion_ranges(lines)
    for start, end in completion_ranges:
        frame = lines[start:end]
        status_count, response, response_cost = response_metadata(frame)
        duration = _duration_ms(frame)
        if status_count == 1 and duration is not None and _consume_proven_cache_hit(
            response, cache_requests
        ):
            continue
        transport_frames.append((status_count, response, response_cost, duration))
    for _ in range(max(0, len(request_ranges) - len(completion_ranges))):
        transport_frames.append((0, {}, None, None))
    print(f"v1\t{len(transport_frames)}")
    for frame_index, record in enumerate(transport_frames, start=1):
        status_count, response, response_cost, duration = record
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
