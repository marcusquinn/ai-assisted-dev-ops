#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded, read-only Ghost publication stream into a social corpus."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_ghost as ghost
from _knowledge_social_ghost_normalize import PageContext, normalize_page
from _knowledge_social_ghost_reader import FixtureGhost, GuardedGhost, verified_identity
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector

def _collector_policy() -> OAuthCollectorPolicy:
    """Bind the generic collector only to Ghost's public publication boundary."""
    return OAuthCollectorPolicy(
        display_name="Ghost",
        provider_module=ghost,
        helper=Path(__file__).with_name("_knowledge_social_ghost_provider.py"),
        fixture_reader=FixtureGhost,
        live_reader=GuardedGhost,
        page_context=PageContext,
        normalize_page=normalize_page,
        verified_identity=verified_identity,
        budget_unit="request",
        max_page_size=100,
    )


def main() -> int:
    return run_oauth_collector(_collector_policy(), __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
