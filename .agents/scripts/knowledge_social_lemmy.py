#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded, read-only, version-gated Lemmy account stream."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_lemmy as lemmy
from _knowledge_social_lemmy_normalize import PageContext, normalize_page
from _knowledge_social_lemmy_reader import FixtureLemmy, GuardedLemmy, verified_identity
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector


LEMMY_POLICY = OAuthCollectorPolicy(
    display_name="Lemmy",
    provider_module=lemmy,
    helper=Path(__file__).with_name("_knowledge_social_lemmy_provider.py"),
    fixture_reader=FixtureLemmy,
    live_reader=GuardedLemmy,
    page_context=PageContext,
    normalize_page=normalize_page,
    verified_identity=verified_identity,
    budget_unit="request",
    max_page_size=50,
)


def main() -> int:
    description = __doc__ or ""
    return run_oauth_collector(LEMMY_POLICY, description)


if __name__ == "__main__":
    raise SystemExit(main())
