#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded, read-only GitHub account stream into a social corpus."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_github as github
from _knowledge_social_github_normalize import PageContext, normalize_page
from _knowledge_social_github_reader import FixtureGitHub, GuardedGitHub, verified_identity
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector


def _policy() -> OAuthCollectorPolicy:
    """Bind GitHub-specific boundaries to the shared OAuth collector."""
    return OAuthCollectorPolicy(
        provider_module=github,
        verified_identity=verified_identity,
        normalize_page=normalize_page,
        page_context=PageContext,
        display_name="GitHub",
        helper=Path(__file__).with_name("_knowledge_social_github_provider.py"),
        fixture_reader=FixtureGitHub,
        live_reader=GuardedGitHub,
        budget_unit="request",
        min_budget=5,
        max_page_size=100,
        identity_cost_units=2,
    )


def main() -> int:
    return run_oauth_collector(_policy(), __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
