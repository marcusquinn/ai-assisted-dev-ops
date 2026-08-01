#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate primitive fields in sanitized Slack provider records."""

from __future__ import annotations

from typing import Any

from _knowledge_social_slack import SlackAdapterError


def required(record: dict[str, Any], key: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or not value or "\x00" in value:
        raise SlackAdapterError(f"Slack record requires {key}")
    return value


def optional(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is not None and (not isinstance(value, str) or "\x00" in value):
        raise SlackAdapterError(f"Slack record {key} must be text")
    return value
