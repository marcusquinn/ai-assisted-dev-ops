#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded, creator-owned beehiiv publication post stream."""

from __future__ import annotations

import sys
from pathlib import Path

import _knowledge_social_beehiiv as beehiiv
from _knowledge_social_beehiiv import PageContext, normalize_page
from _knowledge_social_beehiiv_reader import (
    FixtureBeehiivReader,
    GuardedBeehiivReader,
    verified_identity,
)
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector

MAX_REQUEST_BUDGET = 59


def _enforce_rate_budget(arguments: list[str]) -> None:
    if "--budget" not in arguments:
        return
    index = arguments.index("--budget")
    if index + 1 >= len(arguments):
        return
    try:
        budget = int(arguments[index + 1])
    except ValueError:
        return
    if budget > MAX_REQUEST_BUDGET:
        raise beehiiv.BeehiivAdapterError(
            "beehiiv budget cannot exceed 59 requests per invocation"
        )


def _policy() -> OAuthCollectorPolicy:
    return OAuthCollectorPolicy(
        provider_module=beehiiv,
        verified_identity=verified_identity,
        normalize_page=normalize_page,
        page_context=PageContext,
        display_name="beehiiv",
        helper=Path(__file__).with_name("_knowledge_social_beehiiv_provider.py"),
        fixture_reader=FixtureBeehiivReader,
        live_reader=GuardedBeehiivReader,
        budget_unit="request",
        default_budget=19,
        max_page_size=100,
    )


def main() -> int:
    try:
        _enforce_rate_budget(sys.argv[1:])
    except beehiiv.BeehiivAdapterError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return run_oauth_collector(_policy(), __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
