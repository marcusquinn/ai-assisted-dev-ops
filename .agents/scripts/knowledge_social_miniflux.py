#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded Miniflux account stream into a social corpus."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_miniflux as miniflux
from _knowledge_social_miniflux_normalize import PageContext, normalize_page
from _knowledge_social_miniflux_reader import FixtureMiniflux, GuardedMiniflux, verified_identity
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector


def _policy() -> OAuthCollectorPolicy:
    return OAuthCollectorPolicy(
        provider_module=miniflux,
        verified_identity=verified_identity,
        normalize_page=normalize_page,
        page_context=PageContext,
        display_name="Miniflux",
        helper=Path(__file__).with_name("_knowledge_social_miniflux_provider.py"),
        fixture_reader=FixtureMiniflux,
        live_reader=GuardedMiniflux,
        budget_unit="request",
        max_page_size=100,
    )


def main() -> int:
    return run_oauth_collector(_policy(), __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
