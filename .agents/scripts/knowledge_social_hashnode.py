#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded, read-only Hashnode account stream into a social corpus."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_hashnode as hashnode
from _knowledge_social_hashnode_normalize import PageContext, normalize_page
from _knowledge_social_hashnode_reader import (
    FixtureHashnode,
    GuardedHashnode,
    verified_identity,
)
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector


HASHNODE_POLICY = OAuthCollectorPolicy(
    provider_module=hashnode,
    verified_identity=verified_identity,
    normalize_page=normalize_page,
    page_context=PageContext,
    display_name="Hashnode",
    helper=Path(__file__).with_name("_knowledge_social_hashnode_provider.py"),
    fixture_reader=FixtureHashnode,
    live_reader=GuardedHashnode,
    budget_unit="query",
    min_budget=3,
    max_page_size=50,
    identity_cost_units=1,
)


def main() -> int:
    return run_oauth_collector(HASHNODE_POLICY, __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
