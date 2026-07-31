#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded, read-only Gumroad seller stream into a social corpus."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_gumroad as gumroad
from _knowledge_social_gumroad_normalize import PageContext, normalize_page
from _knowledge_social_gumroad_reader import FixtureGumroad, GuardedGumroad, verified_identity
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector

COLLECTOR_OPTIONS = {
    "display_name": "Gumroad",
    "provider_module": gumroad,
    "helper": Path(__file__).with_name("_knowledge_social_gumroad_provider.py"),
    "fixture_reader": FixtureGumroad,
    "live_reader": GuardedGumroad,
    "page_context": PageContext,
    "normalize_page": normalize_page,
    "verified_identity": verified_identity,
    "budget_unit": "request",
    "default_budget": 11,
    "min_budget": 3,
    "max_page_size": 100,
}


def main() -> int:
    return run_oauth_collector(OAuthCollectorPolicy(**COLLECTOR_OPTIONS), __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
