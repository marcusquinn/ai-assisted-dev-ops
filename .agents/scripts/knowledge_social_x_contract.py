#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared constants for the read-only X social adapter."""

PROVIDER = "xapi"
STREAM_PATHS = {
    "authored": "/2/users/{account_id}/tweets",
    "mentions": "/2/users/{account_id}/mentions",
    "likes": "/2/users/{account_id}/liked_tweets",
    "bookmarks": "/2/users/{account_id}/bookmarks",
    "followers": "/2/users/{account_id}/followers",
    "following": "/2/users/{account_id}/following",
}
TWEET_STREAMS = {"authored", "mentions", "likes", "bookmarks"}
