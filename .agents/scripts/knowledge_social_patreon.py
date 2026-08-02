#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded, read-only Patreon creator stream into a social corpus."""

from __future__ import annotations

import sys
from pathlib import Path

import _knowledge_social_patreon as patreon
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector
from _knowledge_social_patreon_normalize import PageContext, normalize_page
from _knowledge_social_patreon_reader import (
    FixturePatreon,
    GuardedPatreon,
    verified_identity,
)

MAX_INVOCATION_BUDGET = 99


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
    if budget > MAX_INVOCATION_BUDGET:
        raise patreon.PatreonAdapterError(
            "Patreon budget cannot exceed 99 requests per invocation"
        )


def _policy() -> OAuthCollectorPolicy:
    return OAuthCollectorPolicy(
        display_name="Patreon",
        provider_module=patreon,
        helper=Path(__file__).with_name("_knowledge_social_patreon_provider.py"),
        fixture_reader=FixturePatreon,
        live_reader=GuardedPatreon,
        page_context=PageContext,
        normalize_page=normalize_page,
        verified_identity=verified_identity,
        budget_unit="request",
        default_budget=20,
        min_budget=5,
        max_page_size=100,
        identity_cost_units=2,
    )


def main() -> int:
    try:
        _enforce_rate_budget(sys.argv[1:])
    except patreon.PatreonAdapterError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return run_oauth_collector(_policy(), __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
