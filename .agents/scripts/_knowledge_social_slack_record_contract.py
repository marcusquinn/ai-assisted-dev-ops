#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Primitive identity and timestamp contracts for Slack records."""

from __future__ import annotations

import re
from datetime import UTC, datetime
from decimal import Decimal, InvalidOperation
from typing import Any

from _knowledge_social_slack import (
    account_id,
    namespaced_id,
    slack_timestamp,
    team_id,
)
from _knowledge_social_slack_contract import (
    SlackReadProviderError,
    non_negative_integer,
)

ACTOR_ID = re.compile(r"^[BUW][A-Z0-9]{2,31}$")
FILE_ID = re.compile(r"^F[A-Z0-9]{2,31}$")


def stable_id(value: Any, field: str, pattern: re.Pattern[str]) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise SlackReadProviderError(f"Slack {field} is invalid")
    return value


def timestamp_iso(value: Any, field: str) -> str | None:
    if value is None:
        return None
    timestamp = slack_timestamp(value, field)
    try:
        epoch = Decimal(timestamp)
        seconds = int(epoch)
        micros = int((epoch - seconds) * 1_000_000)
        return (
            datetime.fromtimestamp(seconds, UTC)
            .replace(microsecond=micros)
            .isoformat()
            .replace("+00:00", "Z")
        )
    except (InvalidOperation, OverflowError, OSError, ValueError) as error:
        raise SlackReadProviderError(f"Slack {field} is invalid") from error


def epoch_iso(value: Any, field: str) -> str | None:
    if value in (None, 0):
        return None
    number = non_negative_integer(value, field)
    if number is None:
        return None
    try:
        return datetime.fromtimestamp(number, UTC).isoformat().replace("+00:00", "Z")
    except (OverflowError, OSError, ValueError) as error:
        raise SlackReadProviderError(f"Slack {field} is invalid") from error


def actor_id(value: Any, workspace: str) -> str:
    if isinstance(value, str) and ACTOR_ID.fullmatch(value) is not None:
        if value.startswith("B"):
            return namespaced_id(workspace, "bot", value)
        return account_id(workspace, value)
    return namespaced_id(workspace, "workspace_actor", team_id(workspace))
