#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one read-only X stream into an authorized social corpus."""

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

from _knowledge_social_lease import (
    RunLeaseRequest,
    SocialLeaseLostError,
    acquire_run_lease,
    fail_active_run,
    release_run_lease,
    renew_run_lease,
)
from _knowledge_social_x import (
    STREAMS,
    CursorState,
    XAdapterError,
    page_checkpoint,
    response_status,
    stream_endpoint,
)
from _knowledge_social_x_normalize import PageContext, normalize_page
from _knowledge_social_x_persist import (
    SuccessfulPage,
    TerminalDecision,
    persist_page,
    record_bounded_stop,
    record_terminal,
)
from _knowledge_social_x_reader import (
    FixtureXurl,
    GuardedXurl,
    XReader,
    verified_identity,
)
from _knowledge_social_x_state import CollectionContext, load_context
from knowledge_corpus_catalog import DEFAULT_ALIAS, authorized_scope
from knowledge_corpus_context import CatalogError
from knowledge_social_import import reject_credentials
from knowledge_social_store import (
    SocialStoreError,
    validate_opaque,
    validate_root,
)


def xurl_runner(args: argparse.Namespace) -> XReader:
    """Select the guarded live reader or a test-only fixture reader."""
    if args.fixture and os.environ.get("AIDEVOPS_TEST_MODE") != "1":
        raise XAdapterError("X fixtures are disabled outside the test harness")
    if args.fixture:
        return FixtureXurl(args.fixture)
    helper = Path(__file__).with_name("xurl-helper.sh")
    return GuardedXurl(helper, args.app, args.username)


def terminal_decision(payload: dict[str, Any]) -> TerminalDecision | None:
    """Map terminal response codes to sanitized local run states."""
    status = response_status(payload)
    if status == 200:
        decision = None
    elif status == 429:
        decision = TerminalDecision("rate_limited", "paused", "rate_limit")
    elif status in (401, 403):
        decision = TerminalDecision("failed", "failed", "authorization")
    elif status == 404:
        decision = TerminalDecision("failed", "failed", "unavailable")
    elif status >= 500:
        decision = TerminalDecision("failed", "failed", "provider")
    else:
        decision = TerminalDecision("failed", "failed", "request")
    return decision


def _page_context(context: CollectionContext) -> PageContext:
    return PageContext(
        context.connection_id,
        context.account,
        context.stream,
        context.media_policy,
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
    args: argparse.Namespace, runner: XReader, initial: CollectionContext
) -> dict[str, Any]:
    """Collect successful pages until completion, failure, or budget stop."""
    context = initial
    pages = 0
    resources = 0
    budget_units = 0
    while budget_units + context.spec.cost_units <= args.budget:
        if context.lease is None:
            raise XAdapterError("X collection requires a collector lease")
        renewed = renew_run_lease(
            context.root, context.lease, args.lease_seconds
        )
        context = replace(context, lease=renewed)
        endpoint = stream_endpoint(
            context.stream, context.account["id"], context.state
        )
        payload = runner.page(endpoint)
        reject_credentials(payload)
        decision = terminal_decision(payload)
        if decision:
            retry_after = record_terminal(context, payload, endpoint, decision)
            return _result(
                decision.output_status,
                pages,
                resources,
                budget_units + context.spec.cost_units,
                failure_class=decision.failure_class,
                retry_after=retry_after,
                run_id=context.lease.run_id,
            )
        checkpoint = page_checkpoint(payload, context.state.watermark)
        archive = normalize_page(payload, _page_context(context))
        complete = checkpoint.next_cursor is None
        page = SuccessfulPage(
            payload,
            endpoint,
            archive,
            checkpoint,
            complete,
            context.spec.cost_units,
        )
        resources += persist_page(context, page)
        pages += 1
        budget_units += context.spec.cost_units
        state = CursorState(
            checkpoint.next_cursor, checkpoint.watermark, complete
        )
        context = replace(context, state=state)
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
    if isinstance(error, XAdapterError):
        return "validation"
    if isinstance(error, sqlite3.Error):
        return "storage"
    if isinstance(error, subprocess.SubprocessError):
        return "provider"
    return "runtime"


def collect(
    args: argparse.Namespace, root: Path, collector_id: str
) -> dict[str, Any]:
    """Verify identity and collect one configured stream."""
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
        runner = xurl_runner(args)
        account = verified_identity(runner.identity(), account_id)
        context = replace(
            load_context(
                root,
                connection_id,
                account,
                args.stream,
                args.media_policy,
            ),
            lease=lease,
        )
        if context.state.backfill_complete and not context.spec.supports_since_id:
            record_bounded_stop(context, "unavailable", "delta_not_supported")
            return _result(
                "delta_unavailable",
                0,
                0,
                0,
                failure_class="delta_not_supported",
                run_id=lease.run_id,
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
    parser.add_argument("--budget", type=int, default=10)
    parser.add_argument(
        "--media-policy", choices=("none", "metadata"), default="none"
    )
    parser.add_argument("--app")
    parser.add_argument("--username")
    parser.add_argument("--collector-id")
    parser.add_argument("--lease-seconds", type=int, default=300)
    parser.add_argument("--fixture", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.budget < 1 or args.budget > 1000:
        parser.error("--budget must be between 1 and 1000 request units")
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
