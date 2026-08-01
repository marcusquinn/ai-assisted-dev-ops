#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect bounded read-only Slack API or approved-export evidence."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import replace
from pathlib import Path
from typing import Any

import _knowledge_social_slack as slack
from _knowledge_social_collect import CollectionContext, CursorState, SuccessfulPage
from _knowledge_social_collect_cli import run_collector
from _knowledge_social_lease import (
    RunLease,
    RunLeaseRequest,
    acquire_run_lease,
    fail_active_run,
    release_run_lease,
)
from _knowledge_social_oauth_collector import OAuthCollector, OAuthCollectorPolicy
from _knowledge_social_slack_archive import SlackArchiveRequest, build_slack_archive
from _knowledge_social_slack_normalize import PageContext, normalize_page
from _knowledge_social_slack_persist import persist_slack_archive, persist_slack_page
from _knowledge_social_slack_provider import load_profile
from _knowledge_social_slack_reader import FixtureSlack, GuardedSlack, verified_identity
from knowledge_corpus_catalog import DEFAULT_ALIAS, resolve
from knowledge_corpus_context import CatalogError
from knowledge_social_store import SocialStoreError, validate_root

DEFAULT_MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
DEFAULT_MAX_ARCHIVE_ITEMS = 25_000
MAX_API_BUDGET = 17
MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
MAX_ARCHIVE_ITEMS = 100_000

API_POLICY = OAuthCollectorPolicy(
    display_name="Slack",
    provider_module=slack,
    helper=Path(__file__).with_name("_knowledge_social_slack_provider.py"),
    fixture_reader=FixtureSlack,
    live_reader=GuardedSlack,
    page_context=PageContext,
    normalize_page=normalize_page,
    verified_identity=verified_identity,
    budget_unit="request",
    default_budget=11,
    min_budget=3,
    max_page_size=15,
)


class SlackCollector(OAuthCollector):
    """Use timestamp-ordered persistence for overlapping API/export evidence."""

    def _persist_success(
        self,
        context: CollectionContext,
        payload: dict[str, Any],
        request: Any,
    ) -> tuple[CollectionContext, int, bool]:
        checkpoint, complete = slack.page_checkpoint(
            payload, context.state, request
        )
        archive = normalize_page(payload, self._page_context(context))
        page = SuccessfulPage(
            payload,
            request.evidence_key(),
            archive,
            checkpoint,
            complete,
            context.spec.cost_units,
            retention_limit=context.spec.retention_limit,
            unavailable_reason=context.spec.unavailable_reason,
            coverage_status=context.spec.coverage_status,
        )
        resources = persist_slack_page(context, page)
        state = CursorState(checkpoint.next_cursor, checkpoint.watermark, complete)
        return replace(context, state=state), resources, complete


def _positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer") from error
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def _add_api_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--base", type=Path)
    parser.add_argument("--alias", default=DEFAULT_ALIAS)
    parser.add_argument("--connection-id", required=True)
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--stream", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--budget", type=_positive_int, default=API_POLICY.default_budget)
    parser.add_argument("--page-size", type=_positive_int, default=API_POLICY.max_page_size)
    parser.add_argument("--collector-id")
    parser.add_argument("--lease-seconds", type=_positive_int, default=300)
    parser.add_argument("--fixture", type=Path, help=argparse.SUPPRESS)


def _add_archive_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--base", type=Path)
    parser.add_argument("--alias", default=DEFAULT_ALIAS)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--connection-id", required=True)
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--exported-at", required=True)
    parser.add_argument(
        "--max-bytes", type=_positive_int, default=DEFAULT_MAX_ARCHIVE_BYTES
    )
    parser.add_argument(
        "--max-items", type=_positive_int, default=DEFAULT_MAX_ARCHIVE_ITEMS
    )
    parser.add_argument("--collector-id", default="slack_archive")
    parser.add_argument("--lease-seconds", type=_positive_int, default=300)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    api_parser = subparsers.add_parser(
        "api", help="collect one identity-bound Slack Web API stream"
    )
    _add_api_arguments(api_parser)
    archive_parser = subparsers.add_parser(
        "archive", help="import one approved Slack JSON export"
    )
    _add_archive_arguments(archive_parser)
    args = parser.parse_args()
    if args.command == "api":
        try:
            slack.parse_stream(args.stream)
        except slack.SlackAdapterError as error:
            parser.error(str(error))
        if not 3 <= args.budget <= MAX_API_BUDGET:
            parser.error(
                f"--budget must be between 3 and {MAX_API_BUDGET} request units"
            )
        if not 1 <= args.page_size <= 15:
            parser.error("--page-size must be between 1 and 15 items")
        if args.lease_seconds > 86_400:
            parser.error("--lease-seconds cannot exceed 86400")
    elif args.command == "archive":
        if args.max_bytes > MAX_ARCHIVE_BYTES:
            parser.error(f"--max-bytes cannot exceed {MAX_ARCHIVE_BYTES}")
        if args.max_items > MAX_ARCHIVE_ITEMS:
            parser.error(f"--max-items cannot exceed {MAX_ARCHIVE_ITEMS}")
        if args.lease_seconds > 86_400:
            parser.error("--lease-seconds cannot exceed 86400")
    return args


def _run_api(args: argparse.Namespace) -> int:
    collector = SlackCollector(API_POLICY, args)
    return run_collector(args, collector.collect)


def _release_safely(root: Path, lease: RunLease | None) -> None:
    if lease is None:
        return
    try:
        release_run_lease(root, lease)
    except SocialStoreError:
        return


def _run_archive(args: argparse.Namespace) -> int:
    root: Path | None = None
    lease: RunLease | None = None
    try:
        base = (
            args.base
            if args.base is not None
            else Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
        )
        root = validate_root(resolve(base, args.alias, "knowledge.write"))
        profile = load_profile(
            args.profile, require_token=False, include_token=False
        )
        parsed = build_slack_archive(
            SlackArchiveRequest(
                args.archive,
                args.connection_id,
                args.account_id,
                args.exported_at,
                profile,
                args.max_bytes,
                args.max_items,
            )
        )
        lease = acquire_run_lease(
            root,
            RunLeaseRequest(
                args.connection_id,
                "archive",
                args.collector_id,
                "sync",
                args.lease_seconds,
                parsed.source_sha256,
            ),
        )
        result = persist_slack_archive(root, parsed, lease)
        _release_safely(root, lease)
        lease = None
        print(json.dumps(result, sort_keys=True))
        return 0
    except (CatalogError, OSError, SocialStoreError, ValueError) as error:
        if root is not None and lease is not None:
            try:
                fail_active_run(root, lease, "archive_validation")
            except SocialStoreError:
                pass
            _release_safely(root, lease)
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


def main() -> int:
    args = parse_args()
    if args.command == "api":
        return _run_api(args)
    if args.command == "archive":
        return _run_archive(args)
    raise AssertionError("unsupported Slack command")


if __name__ == "__main__":
    raise SystemExit(main())
