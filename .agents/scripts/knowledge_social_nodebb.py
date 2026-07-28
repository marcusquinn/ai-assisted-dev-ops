#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded, read-only NodeBB account stream into a social corpus."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_nodebb as nodebb
from _knowledge_social_nodebb_normalize import PageContext, normalize_page
from _knowledge_social_nodebb_reader import FixtureNodeBB, GuardedNodeBB, verified_identity
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector

COLLECTOR_OPTIONS = {
    "display_name": "NodeBB",
    "provider_module": nodebb,
    "helper": Path(__file__).with_name("_knowledge_social_nodebb_provider.py"),
    "fixture_reader": FixtureNodeBB,
    "live_reader": GuardedNodeBB,
    "page_context": PageContext,
    "normalize_page": normalize_page,
    "verified_identity": verified_identity,
    "budget_unit": "request",
    "max_page_size": 50,
}


def main() -> int:
    return run_oauth_collector(OAuthCollectorPolicy(**COLLECTOR_OPTIONS), __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
