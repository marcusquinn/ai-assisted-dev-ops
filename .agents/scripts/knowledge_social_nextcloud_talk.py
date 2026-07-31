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

COLLECTOR_POLICY = OAuthCollectorPolicy(
    "Nextcloud Talk",
    nextcloud_talk,
    Path(__file__).with_name("_knowledge_social_nextcloud_talk_provider.py"),
    FixtureNextcloudTalk,
    GuardedNextcloudTalk,
    PageContext,
    normalize_page,
    verified_identity,
    "bounded read",
    10,
    4,
    200,
)


def main() -> int:
    return run_oauth_collector(COLLECTOR_POLICY, __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
