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


def _policy() -> OAuthCollectorPolicy:
    """Bind Lemmy version and identity boundaries to the shared collector."""
    return OAuthCollectorPolicy(
        provider_module=lemmy,
        verified_identity=verified_identity,
        normalize_page=normalize_page,
        page_context=PageContext,
        display_name="Lemmy",
        helper=Path(__file__).with_name("_knowledge_social_lemmy_provider.py"),
        fixture_reader=FixtureLemmy,
        live_reader=GuardedLemmy,
        budget_unit="request",
        max_page_size=50,
    )


def main() -> int:
    return run_oauth_collector(_policy(), __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
