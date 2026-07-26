#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one read-only Reddit account stream into a social corpus."""

from __future__ import annotations

import argparse
import os
import sqlite3
import subprocess
from dataclasses import replace
from pathlib import Path
from typing import Any

from _knowledge_social_collect import (
    CollectionContext,
    CollectionProgress,
    ContextRequest,
    CursorState,
    SuccessfulPage,
    TerminalDecision,
    terminal_decision_for_status,
)
from _knowledge_social_collect_cli import run_collector
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
from knowledge_corpus_catalog import DEFAULT_ALIAS
from knowledge_social_import import reject_credentials
from knowledge_social_store import validate_opaque


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
    return terminal_decision_for_status(response_status(payload))


def _page_context(context: CollectionContext) -> PageContext:
    return PageContext(
        context.connection_id,
        context.account,
        context.stream,
        context.config.enabled_streams,
        context.config.policy,
    )


def _result(
    status: str,
    progress: CollectionProgress,
    **extra: Any,
) -> dict[str, Any]:
    return {
        "status": status,
        "pages": progress.pages,
        "resources": progress.resources,
        "budget_units": progress.budget_units,
        **extra,
    }


def _terminal_result(
    context: CollectionContext,
    payload: dict[str, Any],
    request: PageRequest,
    decision: TerminalDecision,
    progress: CollectionProgress,
) -> dict[str, Any]:
    retry_after = record_terminal(
        context, payload, request.evidence_key(), decision
    )
    stopped = CollectionProgress(
        progress.pages,
        progress.resources,
        progress.budget_units + context.spec.cost_units,
    )
    return _result(
        decision.output_status,
        stopped,
        failure_class=decision.failure_class,
        retry_after=retry_after,
        run_id=context.lease.run_id if context.lease else None,
    )


def _persist_success(
    context: CollectionContext,
    payload: dict[str, Any],
    request: PageRequest,
) -> tuple[CollectionContext, int, bool]:
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
    resources = persist_page(context, page)
    state = CursorState(checkpoint.next_cursor, checkpoint.watermark, complete)
    return replace(context, state=state), resources, complete


def collect_pages(
    args: argparse.Namespace, runner: RedditReader, initial: CollectionContext
) -> dict[str, Any]:
    """Collect successful Reddit pages until completion, failure, or budget stop."""
    context = initial
    progress = CollectionProgress()
    while progress.budget_units + context.spec.cost_units <= args.budget:
        if context.lease is None:
            raise RedditAdapterError("Reddit collection requires a collector lease")
        context = replace(
            context,
            lease=renew_run_lease(
                context.root, context.lease, args.lease_seconds
            ),
        )
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
            return _terminal_result(context, payload, request, decision, progress)
        context, resources, complete = _persist_success(context, payload, request)
        progress = progress.advance(resources, context.spec.cost_units)
        if complete:
            return _result(
                "complete",
                progress,
                run_id=context.lease.run_id if context.lease else None,
            )
    record_bounded_stop(context, "paused", "budget")
    return _result(
        "budget_exhausted",
        progress,
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
                ContextRequest(
                    PROVIDER, connection_id, account, args.stream, "none"
                ),
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
    return run_collector(parse_args(), collect)


if __name__ == "__main__":
    raise SystemExit(main())
