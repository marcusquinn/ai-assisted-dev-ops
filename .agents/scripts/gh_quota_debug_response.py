#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Parse privacy-filtered GH_DEBUG response metadata."""

from __future__ import annotations

import json
import re
from typing import Dict, List, Optional, Tuple


REQUEST_END = re.compile(
    rb"^\* Request took ([0-9]+(?:\.[0-9]+)?)(ns|(?:\xc2\xb5|\xce\xbc|u)s|ms|s)\s*$"
)
RESPONSE_STATUS = re.compile(
    rb"^< HTTP/\S+\s+([0-9]{3})(?:\s+.*)?$", re.IGNORECASE
)
DATE_HEADER = re.compile(rb"^< Date:\s*(.+?)\s*$", re.IGNORECASE)
RATE_HEADER = re.compile(
    rb"^< X-Ratelimit-(Resource|Used|Remaining|Reset):\s*([^\s]+)\s*$",
    re.IGNORECASE,
)
RATE_FIELDS = frozenset({"resource", "used", "remaining", "reset"})
Response = Tuple[Dict[str, str], List[bytes]]


def _decode_ascii(value: bytes) -> Optional[str]:
    try:
        return value.decode("ascii")
    except UnicodeDecodeError:
        return None


def _response_start(line: bytes) -> Optional[Response]:
    match = RESPONSE_STATUS.match(line)
    if match is None:
        return None
    return {"status": match.group(1).decode("ascii")}, []


def _capture_response_header(headers: Dict[str, str], line: bytes) -> None:
    date_match = DATE_HEADER.match(line)
    if date_match is not None:
        date_value = _decode_ascii(date_match.group(1))
        if date_value is not None:
            headers["date"] = date_value
        return
    match = RATE_HEADER.match(line)
    if match is None:
        return
    name = _decode_ascii(match.group(1))
    value = _decode_ascii(match.group(2))
    if name is None or value is None:
        return
    headers[name.lower()] = value


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


def response_metadata(
    frame: List[bytes],
) -> Tuple[int, Dict[str, str], Optional[int]]:
    """Return complete rate responses and the final GraphQL response cost."""
    responses: List[Response] = []
    in_headers = False
    for line in frame:
        stripped = line.rstrip(b"\r\n")
        started = _response_start(stripped)
        if started is not None:
            responses.append(started)
            in_headers = True
            continue
        if not responses:
            continue
        headers, body = responses[-1]
        if in_headers:
            in_headers = stripped != b""
            _capture_response_header(headers, stripped)
        elif not REQUEST_END.match(stripped):
            body.append(stripped)
    rate_responses = [
        response for response in responses if RATE_FIELDS <= response[0].keys()
    ]
    if not rate_responses:
        return 0, {}, None
    headers, body = rate_responses[-1]
    return len(rate_responses), headers, _graphql_rate_cost(body)
