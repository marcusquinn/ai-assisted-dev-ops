#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded public Hacker News submitted-item slice into a social corpus."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_hacker_news as hacker_news
from _knowledge_social_hacker_news_collector import run_hacker_news_collector
from _knowledge_social_hacker_news_normalize import PageContext, normalize_page
from _knowledge_social_hacker_news_reader import (
    FixtureHackerNews,
    GuardedHackerNews,
    verified_identity,
)
from _knowledge_social_oauth_collector import OAuthCollectorPolicy


def _policy() -> OAuthCollectorPolicy:
    return OAuthCollectorPolicy(
        provider_module=hacker_news,
        verified_identity=verified_identity,
        normalize_page=normalize_page,
        page_context=PageContext,
        display_name="Hacker News",
        helper=Path(__file__).with_name("_knowledge_social_hacker_news_provider.py"),
        fixture_reader=FixtureHackerNews,
        live_reader=GuardedHackerNews,
        budget_unit="request",
        default_budget=11,
        min_budget=3,
        max_page_size=100,
    )


def main() -> int:
    return run_hacker_news_collector(_policy(), __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
