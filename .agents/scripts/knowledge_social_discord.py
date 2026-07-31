#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one identity-bound, read-only Discord stream into a social corpus."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_discord as discord
from _knowledge_social_discord_normalize import PageContext, normalize_page
from _knowledge_social_discord_reader import (
    FixtureDiscord,
    GuardedDiscordBot,
    verified_identity,
)
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector

COLLECTOR_POLICY = OAuthCollectorPolicy(
    display_name="Discord",
    provider_module=discord,
    helper=Path(__file__).with_name("_knowledge_social_discord_provider.py"),
    fixture_reader=FixtureDiscord,
    live_reader=GuardedDiscordBot,
    page_context=PageContext,
    normalize_page=normalize_page,
    verified_identity=verified_identity,
    budget_unit="request",
    default_budget=11,
    min_budget=3,
    max_page_size=100,
)


def main() -> int:
    return run_oauth_collector(COLLECTOR_POLICY, __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
