#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded, read-only Nextcloud Talk stream into a social corpus."""

from __future__ import annotations

from pathlib import Path

import _knowledge_social_nextcloud_talk as nextcloud_talk
from _knowledge_social_nextcloud_talk_normalize import PageContext, normalize_page
from _knowledge_social_nextcloud_talk_reader import (
    FixtureNextcloudTalk,
    GuardedNextcloudTalk,
    verified_identity,
)
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector

COLLECTOR_OPTIONS = {
    "display_name": "Nextcloud Talk",
    "provider_module": nextcloud_talk,
    "helper": Path(__file__).with_name("_knowledge_social_nextcloud_talk_provider.py"),
    "fixture_reader": FixtureNextcloudTalk,
    "live_reader": GuardedNextcloudTalk,
    "page_context": PageContext,
    "normalize_page": normalize_page,
    "verified_identity": verified_identity,
    "budget_unit": "bounded read",
    "default_budget": 10,
    "min_budget": 4,
    "max_page_size": 200,
}


def main() -> int:
    return run_oauth_collector(OAuthCollectorPolicy(**COLLECTOR_OPTIONS), __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
