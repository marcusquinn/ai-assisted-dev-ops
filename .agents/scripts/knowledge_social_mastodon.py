#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded, read-only Mastodon account stream into a social corpus."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_mastodon as mastodon
from _knowledge_social_mastodon_normalize import PageContext, normalize_page
from _knowledge_social_mastodon_reader import FixtureMastodon, GuardedMastodon, verified_identity
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector

COLLECTOR_OPTIONS = {
    "display_name": "Mastodon",
    "provider_module": mastodon,
    "helper": Path(__file__).with_name("_knowledge_social_mastodon_provider.py"),
    "fixture_reader": FixtureMastodon,
    "live_reader": GuardedMastodon,
    "page_context": PageContext,
    "normalize_page": normalize_page,
    "verified_identity": verified_identity,
    "budget_unit": "request",
    "max_page_size": 100,
}


def main() -> int:
    return run_oauth_collector(OAuthCollectorPolicy(**COLLECTOR_OPTIONS), __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
