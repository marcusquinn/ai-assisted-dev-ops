#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Reject high-confidence Slack secrets before evidence persistence."""

from __future__ import annotations

import re
from typing import Any

from _knowledge_social_slack_identity import SlackAdapterError
from knowledge_source_contract import (
    SourceContractError,
    reject_credentials as reject_credential_keys,
)

SLACK_TOKEN = re.compile(
    r"(?<![A-Za-z0-9])(?:xox[a-z]|xapp)-"
    r"(?=[A-Za-z0-9-]{24,200}(?![A-Za-z0-9-]))"
    r"(?=[A-Za-z0-9-]*[A-Za-z])(?=[A-Za-z0-9-]*[0-9])"
    r"[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+(?![A-Za-z0-9])",
    re.IGNORECASE,
)
SLACK_WEBHOOK = re.compile(
    r"https://hooks\.slack\.com/(?:services|triggers|workflows)/"
    r"[A-Za-z0-9/_-]{20,}",
    re.IGNORECASE,
)
MIN_TOKEN_SYMBOLS = 8


def _contains_slack_token(value: str) -> bool:
    for match in SLACK_TOKEN.finditer(value):
        token_body = match.group().split("-", 1)[1]
        symbols = {character.lower() for character in token_body if character.isalnum()}
        if len(symbols) >= MIN_TOKEN_SYMBOLS:
            return True
    return False


def _contains_credential(value: Any, exact_secret: str | None) -> bool:
    if isinstance(value, str):
        exact_match = (
            exact_secret is not None
            and len(exact_secret) >= 16
            and exact_secret in value
        )
        return exact_match or _contains_slack_token(value) or bool(
            SLACK_WEBHOOK.search(value)
        )
    if isinstance(value, dict):
        return any(
            _contains_credential(child, exact_secret) for child in value.values()
        )
    if isinstance(value, list):
        return any(_contains_credential(child, exact_secret) for child in value)
    return False


def reject_slack_credentials(
    value: Any, *, exact_secret: str | None = None
) -> None:
    """Reject credential keys and high-confidence Slack secret scalar values."""
    try:
        reject_credential_keys(value)
    except SourceContractError as error:
        raise SlackAdapterError(
            "Slack evidence contains forbidden credential material"
        ) from error
    if _contains_credential(value, exact_secret):
        raise SlackAdapterError(
            "Slack evidence contains forbidden credential material"
        )
