#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""X compatibility exports for provider-neutral collector persistence."""

from _knowledge_social_collect import SuccessfulPage, TerminalDecision
from _knowledge_social_collect_persist import (
    persist_page,
    record_bounded_stop,
    record_terminal,
)

__all__ = (
    "SuccessfulPage",
    "TerminalDecision",
    "persist_page",
    "record_bounded_stop",
    "record_terminal",
)
