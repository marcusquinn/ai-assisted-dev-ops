#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded Readwise Reader account stream into a social corpus."""

from __future__ import annotations

import sys
from pathlib import Path

import _knowledge_social_readwise_reader as reader
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector
from _knowledge_social_readwise_reader_normalize import PageContext, normalize_page
from _knowledge_social_readwise_reader_reader import (
    FixtureReadwiseReader,
    GuardedReadwiseReader,
    verified_identity,
)


def _enforce_rate_budget(arguments: list[str]) -> None:
    if "--budget" not in arguments:
        return
    index = arguments.index("--budget")
    if index + 1 >= len(arguments):
        return
    try:
        budget = int(arguments[index + 1])
    except ValueError:
        return
    if budget > 19:
        raise reader.ReadwiseReaderAdapterError(
            "Readwise Reader budget cannot exceed 19 requests per invocation"
        )


def _policy() -> OAuthCollectorPolicy:
    return OAuthCollectorPolicy(
        provider_module=reader, verified_identity=verified_identity,
        normalize_page=normalize_page, page_context=PageContext,
        display_name="Readwise Reader",
        helper=Path(__file__).with_name("_knowledge_social_readwise_reader_provider.py"),
        fixture_reader=FixtureReadwiseReader, live_reader=GuardedReadwiseReader,
        budget_unit="request", default_budget=19, max_page_size=100,
    )


def main() -> int:
    try:
        _enforce_rate_budget(sys.argv[1:])
    except reader.ReadwiseReaderAdapterError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return run_oauth_collector(_policy(), __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
