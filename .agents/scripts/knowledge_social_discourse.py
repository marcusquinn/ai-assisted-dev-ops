#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded, read-only Discourse account stream into a social corpus."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_discourse as discourse
from _knowledge_social_discourse_normalize import PageContext, normalize_page
from _knowledge_social_discourse_reader import (
    FixtureDiscourse,
    GuardedDiscourse,
    verified_identity,
)
from _knowledge_social_oauth_collector import (
    OAuthCollectorPolicy,
    run_oauth_collector,
)

COLLECTOR_POLICY = OAuthCollectorPolicy(
    display_name="Discourse",
    provider_module=discourse,
    helper=Path(__file__).with_name("_knowledge_social_discourse_provider.py"),
    fixture_reader=FixtureDiscourse,
    live_reader=GuardedDiscourse,
    page_context=PageContext,
    normalize_page=normalize_page,
    verified_identity=verified_identity,
    budget_unit="request",
    max_page_size=20,
)


def main() -> int:
    return run_oauth_collector(COLLECTOR_POLICY, __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
