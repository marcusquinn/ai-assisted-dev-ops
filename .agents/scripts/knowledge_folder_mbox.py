#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded mbox framing for recursive folder ingestion."""

from __future__ import annotations

import re
from typing import Iterator

from knowledge_folder_model import EvidenceProcessingError


MBOX_SEPARATOR = re.compile(
    rb"^From \S+ (?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) "
    rb"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) "
    rb"[ 0-3]\d \d{2}:\d{2}(?::\d{2})?(?: [^\r\n ]+)? \d{4}\r?$"
)


def mbox_messages(data: bytes) -> Iterator[bytes]:
    position = 0
    while position < len(data):
        envelope_end = data.find(b"\n", position)
        if envelope_end < 0:
            raise EvidenceProcessingError("mailbox envelope is truncated")
        envelope = data[position:envelope_end]
        if MBOX_SEPARATOR.fullmatch(envelope) is None:
            raise EvidenceProcessingError("mailbox envelope is malformed")
        message_start = envelope_end + 1
        header_end, body_start = _message_header_boundary(data, message_start)
        content_length = _content_length(data[message_start:header_end])
        message_end, next_position = _message_boundary(data, message_start, body_start, content_length)
        yield data[message_start:message_end]
        if next_position is None:
            return
        position = next_position


def _message_boundary(
    data: bytes, message_start: int, body_start: int, content_length: int | None
) -> tuple[int, int | None]:
    if content_length is None:
        next_position = _next_mbox_separator(data, message_start)
        return (next_position if next_position is not None else len(data), next_position)
    message_end = body_start + content_length
    if message_end > len(data):
        raise EvidenceProcessingError("mailbox content length exceeds available bytes")
    return message_end, _separator_after_content(data, message_end)


def _message_header_boundary(data: bytes, start: int) -> tuple[int, int]:
    candidates = ((data.find(b"\r\n\r\n", start), 4), (data.find(b"\n\n", start), 2))
    present = [(offset, width) for offset, width in candidates if offset >= 0]
    if not present:
        return start, start
    offset, width = min(present)
    return offset, offset + width


def _content_length(headers: bytes) -> int | None:
    matches = re.findall(rb"(?im)^Content-Length:[ \t]*(\d+)[ \t]*\r?$", headers)
    if not matches:
        return None
    if len(matches) != 1:
        raise EvidenceProcessingError("mailbox content length is ambiguous")
    return int(matches[0])


def _separator_after_content(data: bytes, position: int) -> int | None:
    if position >= len(data) or data[position:] in {b"\n", b"\r\n"}:
        return None
    for candidate in (position, position + 1, position + 2):
        if candidate >= len(data):
            continue
        if candidate > position and data[position:candidate] not in {b"\n", b"\r\n"}:
            continue
        line_end = data.find(b"\n", candidate)
        if line_end >= 0 and MBOX_SEPARATOR.fullmatch(data[candidate:line_end]) is not None:
            return candidate
    raise EvidenceProcessingError("mailbox content length does not end at an envelope")


def _next_mbox_separator(data: bytes, start: int) -> int | None:
    position = start
    while position < len(data):
        line_end = data.find(b"\n", position)
        if line_end < 0:
            return None
        if MBOX_SEPARATOR.fullmatch(data[position:line_end]) is not None:
            return position
        position = line_end + 1
    return None
