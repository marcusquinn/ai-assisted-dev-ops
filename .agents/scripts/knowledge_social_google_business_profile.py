#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one identity-bound Google Business Profile location read stream."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_google_business_profile as gbp
from _knowledge_social_google_business_profile_normalize import (
    PageContext,
    normalize_page,
)
from _knowledge_social_google_business_profile_reader import (
    FixtureGoogleBusinessProfile,
    GuardedGoogleBusinessProfileOAuth,
    verified_identity,
)
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector


COLLECTOR_POLICY = OAuthCollectorPolicy(
    display_name="Google Business Profile",
    provider_module=gbp,
    helper=Path(__file__).with_name(
        "_knowledge_social_google_business_profile_provider.py"
    ),
    fixture_reader=FixtureGoogleBusinessProfile,
    live_reader=GuardedGoogleBusinessProfileOAuth,
    page_context=PageContext,
    normalize_page=normalize_page,
    verified_identity=verified_identity,
    budget_unit="bounded collection",
    default_budget=11,
    min_budget=3,
    max_page_size=100,
)


def main() -> int:
    return run_oauth_collector(COLLECTOR_POLICY, __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
