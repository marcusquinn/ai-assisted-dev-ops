#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded, creator-owned beehiiv publication post stream."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

import _knowledge_social_beehiiv as beehiiv
from _knowledge_social_beehiiv import PageContext, normalize_page
from _knowledge_social_beehiiv_reader import (
    FixtureBeehiivReader,
    GuardedBeehiivReader,
    verified_identity,
)
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector
from _knowledge_social_oauth_reader import PROFILE_NAME

MAX_REQUEST_BUDGET = 59


def _ownership_preflight(args: argparse.Namespace) -> None:
    """Reject an absent or mismatched local ownership claim before leasing."""
    if args.fixture is not None:
        return
    if PROFILE_NAME.fullmatch(args.profile) is None:
        raise beehiiv.BeehiivAdapterError("beehiiv profile name is invalid")
    prefix = f"BEEHIIV_{args.profile.upper()}"
    configured_value = os.environ.get(f"{prefix}_PUBLICATION_ID", "")
    ownership_value = os.environ.get(
        f"{prefix}_CREATOR_OWNED_PUBLICATION_ID", ""
    )
    if not configured_value:
        raise beehiiv.BeehiivAdapterError("beehiiv profile publication ID is missing")
    if not ownership_value:
        raise beehiiv.BeehiivAdapterError(
            "beehiiv profile creator-owned publication ID is missing"
        )
    configured = beehiiv.publication_id(configured_value)
    ownership = beehiiv.publication_id(ownership_value)
    if configured != beehiiv.publication_id(args.account_id):
        raise beehiiv.BeehiivAdapterError(
            "selected beehiiv publication does not match the configured publication"
        )
    if ownership != configured:
        raise beehiiv.BeehiivAdapterError(
            "beehiiv profile creator ownership attestation does not match publication"
        )


def _policy() -> OAuthCollectorPolicy:
    return OAuthCollectorPolicy(
        provider_module=beehiiv,
        verified_identity=verified_identity,
        normalize_page=normalize_page,
        page_context=PageContext,
        display_name="beehiiv",
        helper=Path(__file__).with_name("_knowledge_social_beehiiv_provider.py"),
        fixture_reader=FixtureBeehiivReader,
        live_reader=GuardedBeehiivReader,
        budget_unit="request",
        default_budget=19,
        max_page_size=100,
        max_budget=MAX_REQUEST_BUDGET,
        preflight=_ownership_preflight,
    )


def main() -> int:
    return run_oauth_collector(_policy(), __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
