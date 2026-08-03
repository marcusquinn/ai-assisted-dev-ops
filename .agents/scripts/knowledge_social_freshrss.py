#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded FreshRSS account stream into a social corpus."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_freshrss as freshrss
from _knowledge_social_freshrss_normalize import PageContext, normalize_page
from _knowledge_social_freshrss_reader import (
    FixtureFreshRSS,
    GuardedFreshRSS,
    verified_identity,
)
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector

MAX_RUN_BUDGET = 20


def _policy() -> OAuthCollectorPolicy:
    return OAuthCollectorPolicy(
        provider_module=freshrss,
        verified_identity=verified_identity,
        normalize_page=normalize_page,
        page_context=PageContext,
        display_name="FreshRSS",
        helper=Path(__file__).with_name("_knowledge_social_freshrss_provider.py"),
        fixture_reader=FixtureFreshRSS,
        live_reader=GuardedFreshRSS,
        budget_unit="request",
        max_page_size=1000,
        default_budget=14,
        min_budget=5,
        identity_cost_units=2,
        max_budget=MAX_RUN_BUDGET,
    )


def main() -> int:
    return run_oauth_collector(_policy(), __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
