#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect a bounded authorized Notion root tree into a social corpus."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_notion as notion
from _knowledge_social_notion_normalize import PageContext, normalize_page
from _knowledge_social_notion_reader import (
    FixtureNotion,
    GuardedNotion,
    verified_identity,
)
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector

COLLECTOR_OPTIONS = {
    "budget_unit": "request",
    "default_budget": 21,
    "display_name": "Notion",
    "fixture_reader": FixtureNotion,
    "helper": Path(__file__).with_name("_knowledge_social_notion_provider.py"),
    "live_reader": GuardedNotion,
    "max_page_size": 100,
    "normalize_page": normalize_page,
    "page_context": PageContext,
    "provider_module": notion,
    "verified_identity": verified_identity,
}


def main() -> int:
    return run_oauth_collector(OAuthCollectorPolicy(**COLLECTOR_OPTIONS), __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
