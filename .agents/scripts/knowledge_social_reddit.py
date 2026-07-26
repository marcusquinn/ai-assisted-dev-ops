#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one read-only Reddit account stream into a social corpus."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
from dataclasses import replace
from pathlib import Path
from typing import Any

from _knowledge_social_collect import CursorState, SuccessfulPage, TerminalDecision
from _knowledge_social_collect_persist import (
    persist_page,
    record_bounded_stop,
    record_terminal,
)
from _knowledge_social_collect_state import load_context
from _knowledge_social_lease import (
    RunLeaseRequest,
    SocialLeaseLostError,
    acquire_run_lease,
    fail_active_run,
    release_run_lease,
    renew_run_lease,
)
from _knowledge_social_reddit import (
    PROVIDER,
    STREAMS,
    PageRequest,
    RedditAdapterError,
    RedditProviderUnavailableError,
    page_checkpoint,
    page_request,
    response_status,
)
from _knowledge_social_reddit_normalize import PageContext, normalize_page
from _knowledge_social_reddit_reader import (
    FixtureReddit,
    GuardedPraw,
    RedditReader,
    verified_identity,
)
from knowledge_corpus_catalog import DEFAULT_ALIAS, authorized_scope
from knowledge_corpus_context import CatalogError
from knowledge_social_import import reject_credentials
from knowledge_social_store import SocialStoreError, validate_opaque, validate_root


def reddit_runner(args: argparse.Namespace) -> RedditReader:
    """Select the guarded live reader or a test-only fixture reader."""
    if args.fixture and os.environ.get("AIDEVOPS_TEST_MODE") != "1":
        raise RedditAdapterError("Reddit fixtures are disabled outside the test harness")
    if args.fixture:
        return FixtureReddit(args.fixture)
    helper = Path(__file__).with_name("_knowledge_social_reddit_read_provider.py")
    return GuardedPraw(helper, args.profile)


def terminal_decision(payload: dict[str, Any]) -> TerminalDecision | None:
    """Map terminal provider status codes to sanitized local run states."""
    status = response_status(payload)
    if status == 200:
        return None
    if status == 429:
        return TerminalDecision("rate_limited", "paused", "rate_limit")
    if status in (401, 403):
        return TerminalDecision("failed", "failed", "authorization")
    if status == 404:
        return TerminalDecision("failed", "failed", "unavailable")
    if status >= 500:
        return TerminalDecision("failed", "failed", "provider")
    return TerminalDecision("failed", "failed", "request")


def _page_context(context: Any) -> PageContext:
    return PageContext(
        context.connection_id,
        context.account,
        context.stream,
        context.config.enabled_streams,
        context.config.policy,
    )


def _result(
    status: str,
    pages: int,
    resources: int,
    budget_units: int,
    **extra: Any,
) -> dict[str, Any]:
    return {
        "status": status,
        "pages": pages,
        "resources": resources,
        "budget_units": budget_units,
        **extra,
    }


def collect_pages(
    args: argparse.Namespace, runner: RedditReader, initial: Any
) -> dict[str, Any]:
    """Collect successful Reddit pages until completion, failure, or budget stop."""
    context = initial
    pages = 0
    resources = 0
    budget_units = 0
    while budget_units + context.spec.cost_units <= args.budget:
        if context.lease is None:
            raise RedditAdapterError("Reddit collection requires a collector lease")
        renewed = renew_run_lease(
            context.root, context.lease, args.lease_seconds
        )
        context = replace(context, lease=renewed)
        request: PageRequest = page_request(
            context.stream,
            context.account["id"],
            context.state,
            args.page_size,
        )
        payload = runner.page(request)
        reject_credentials(payload)
        decision = terminal_decision(payload)
        if decision:
            retry_after = record_terminal(
                context, payload, request.evidence_key(), decision
            )
            return _result(
                decision.output_status,
                pages,
                resources,
                budget_units + context.spec.cost_units,
                failure_class=decision.failure_class,
                retry_after=retry_after,
                run_id=context.lease.run_id,
            )
        checkpoint, complete = page_checkpoint(payload, context.state, request)
        archive = normalize_page(payload, _page_context(context))
        page = SuccessfulPage(
            payload,
            request.evidence_key(),
            archive,
            checkpoint,
            complete,
            context.spec.cost_units,
            retention_limit=context.spec.retention_limit,
        )
        resources += persist_page(context, page)
        pages += 1
        budget_units += context.spec.cost_units
        context = replace(
            context,
            state=CursorState(
                checkpoint.next_cursor, checkpoint.watermark, complete
            ),
        )
        if complete:
            return _result(
                "complete",
                pages,
                resources,
                budget_units,
                run_id=context.lease.run_id,
            )
    record_bounded_stop(context, "paused", "budget")
    return _result(
        "budget_exhausted",
        pages,
        resources,
        budget_units,
        run_id=context.lease.run_id if context.lease else None,
    )


def _failure_class(error: Exception) -> str:
    if isinstance(error, RedditProviderUnavailableError):
        return "provider"
    if isinstance(error, RedditAdapterError):
        return "validation"
    if isinstance(error, sqlite3.Error):
        return "storage"
    if isinstance(error, subprocess.SubprocessError):
        return "provider"
    return "runtime"


def collect(
    args: argparse.Namespace, root: Path, collector_id: str
) -> dict[str, Any]:
    """Verify the selected account and collect one configured Reddit stream."""
    connection_id = validate_opaque(args.connection_id, "connection_id")
    account_id = validate_opaque(args.account_id, "account_id")
    lease = acquire_run_lease(
        root,
        RunLeaseRequest(
            connection_id,
            args.stream,
            collector_id,
            "sync",
            args.lease_seconds,
        ),
    )
    try:
        runner = reddit_runner(args)
        account = verified_identity(runner.identity(), account_id)
        context = replace(
            load_context(
                root,
                PROVIDER,
                connection_id,
                account,
                args.stream,
                "none",
                STREAMS,
            ),
            lease=lease,
        )
        return collect_pages(args, runner, context)
    except Exception as error:
        try:
            fail_active_run(root, lease, _failure_class(error))
        except SocialLeaseLostError:
            pass
        raise
    finally:
        release_run_lease(root, lease)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path)
    parser.add_argument("--alias", default=DEFAULT_ALIAS)
    parser.add_argument("--connection-id", required=True)
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--stream", required=True, choices=tuple(STREAMS))
    parser.add_argument("--profile", required=True)
    parser.add_argument("--budget", type=int, default=10)
    parser.add_argument("--page-size", type=int, default=100)
    parser.add_argument("--collector-id")
    parser.add_argument("--lease-seconds", type=int, default=300)
    parser.add_argument("--fixture", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.budget < 1 or args.budget > 1000:
        parser.error("--budget must be between 1 and 1000 request units")
    if args.page_size < 1 or args.page_size > 100:
        parser.error("--page-size must be between 1 and 100 items")
    if args.lease_seconds < 1 or args.lease_seconds > 86400:
        parser.error("--lease-seconds must be between 1 and 86400")
    return args


def main() -> int:
    args = parse_args()
    try:
        base = (
            args.base
            if args.base
            else Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
        )
        principal_id, corpora = authorized_scope(
            base, "knowledge.write", args.alias
        )
        root = validate_root(corpora[0][1])
        collector_id = validate_opaque(
            args.collector_id or principal_id, "collector_id"
        )
        print(json.dumps(collect(args, root, collector_id), sort_keys=True))
        return 0
    except (
        CatalogError,
        OSError,
        SocialStoreError,
        sqlite3.Error,
        subprocess.SubprocessError,
        ValueError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
