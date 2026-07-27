#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one LinkedIn Member Snapshot domain into a social corpus."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_linkedin as linkedin
from _knowledge_social_linkedin_normalize import PageContext, normalize_page
from _knowledge_social_linkedin_reader import (
    FixtureLinkedIn,
    GuardedLinkedInOAuth,
    verified_identity,
)
from _knowledge_social_oauth_collector import (
    OAuthCollectorPolicy,
    run_oauth_collector,
)

COLLECTOR_POLICY = OAuthCollectorPolicy(
    display_name="LinkedIn",
    provider_module=linkedin,
    helper=Path(__file__).with_name("_knowledge_social_linkedin_provider.py"),
    fixture_reader=FixtureLinkedIn,
    live_reader=GuardedLinkedInOAuth,
    page_context=PageContext,
    normalize_page=normalize_page,
    verified_identity=verified_identity,
    budget_unit="request",
)


def main() -> int:
    return run_oauth_collector(COLLECTOR_POLICY, __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
