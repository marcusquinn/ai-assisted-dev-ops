#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Report social provider readiness and reconcile content-free receipts."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any

from _knowledge_social_outbound import OUTBOUND_PROVIDER_ACTIONS
from _knowledge_social_outbound_reconciliation import ReconciliationRequest
from knowledge_corpus_catalog import DEFAULT_ALIAS, authorized_scope
from knowledge_corpus_context import CatalogError, validate_private_file
from knowledge_social_store import (
    SocialStoreError,
    connect,
    connect_read_only,
    migrate,
    require_schema,
    validate_root,
)
from social_provider_health import (
    DEFAULT_STALE_SECONDS,
    build_health_report,
    reconcile_provider_receipts,
    render_human,
    require_health_schema,
    write_snapshot,
)

DEFAULT_BASE = Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
MAX_DECISION_BYTES = 1024 * 1024


class ProviderHealthError(RuntimeError):
    """Raised for privacy-safe provider health command failures."""


def _clock(args: argparse.Namespace) -> int:
    override = args.now_epoch
    if override is not None:
        if os.environ.get("AIDEVOPS_TEST_MODE") != "1":
            raise ProviderHealthError("test clocks are disabled outside the test harness")
        if override < 0:
            raise ProviderHealthError("test clock must be a non-negative epoch")
        return override
    return int(time.time())


def _context(args: argparse.Namespace, capability: str) -> tuple[str, Path]:
    principal_id, corpora = authorized_scope(
        args.base or DEFAULT_BASE, capability, args.alias
    )
    return principal_id, validate_root(corpora[0][1])


def _decision_document(path: Path) -> list[dict[str, Any]]:
    validate_private_file(path, "social reconciliation decision file", repair=False)
    if path.stat().st_size > MAX_DECISION_BYTES:
        raise ProviderHealthError("social reconciliation decisions exceed the size limit")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ProviderHealthError(
            "social reconciliation decisions are not valid private JSON"
        ) from error
    if not isinstance(value, list):
        raise ProviderHealthError("social reconciliation decisions must be an array")
    if any(not isinstance(item, dict) for item in value):
        raise ProviderHealthError("social reconciliation decision must be an object")
    return value


def _decisions(
    path: Path | None, principal_id: str, reconciled_at: int
) -> tuple[ReconciliationRequest, ...]:
    if path is None:
        return ()
    decisions: list[ReconciliationRequest] = []
    for item in _decision_document(path):
        if set(item) - {"operation_id", "outcome", "provider_id"}:
            raise ProviderHealthError("social reconciliation decision has unknown fields")
        operation_id = item.get("operation_id")
        outcome = item.get("outcome")
        provider_id = item.get("provider_id")
        if not isinstance(operation_id, str) or outcome not in ("succeeded", "not-sent"):
            raise ProviderHealthError("social reconciliation decision is invalid")
        if provider_id is not None and not isinstance(provider_id, str):
            raise ProviderHealthError("social reconciliation provider ID must be text")
        decisions.append(
            ReconciliationRequest(
                operation_id,
                principal_id,
                outcome,
                provider_id,
                reconciled_at,
            )
        )
    return tuple(decisions)


def _health(args: argparse.Namespace, now: int) -> tuple[dict[str, Any], bool]:
    capability = "knowledge.manage" if args.command == "collect" else "knowledge.read"
    principal_id, root = _context(args, capability)
    writable = args.command == "collect"
    database = connect(root) if writable else connect_read_only(root)
    try:
        if writable:
            migrate(database)
            require_schema(database)
        else:
            require_health_schema(database)
        report = build_health_report(
            database,
            principal_id,
            now,
            stale_seconds=args.stale_seconds,
            provider=args.provider,
        )
    finally:
        database.close()
    if args.command == "collect":
        write_snapshot(root / "state" / "social-provider-health.json", report)
    return report, args.command == "report"


def _reconcile(args: argparse.Namespace, now: int) -> dict[str, Any]:
    principal_id, root = _context(args, "knowledge.manage")
    database = connect(root)
    try:
        migrate(database)
        require_schema(database)
        decisions = _decisions(args.decisions_file, principal_id, now)
        if len(decisions) > args.limit:
            raise ProviderHealthError(
                "social reconciliation decisions exceed the invocation limit"
            )
        return reconcile_provider_receipts(
            database,
            principal_id,
            now,
            decisions=decisions,
            limit=args.limit,
            per_provider_limit=args.per_provider_limit,
        )
    finally:
        database.close()


def _add_scope(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--base", type=Path)
    parser.add_argument("--alias", default=DEFAULT_ALIAS)
    parser.add_argument("--now-epoch", type=int, help=argparse.SUPPRESS)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("status", "collect", "report"):
        health = commands.add_parser(command)
        _add_scope(health)
        health.add_argument("--provider")
        health.add_argument("--stale-seconds", type=int, default=DEFAULT_STALE_SECONDS)
    reconcile = commands.add_parser("reconcile")
    _add_scope(reconcile)
    reconcile.add_argument("--decisions-file", type=Path)
    reconcile.add_argument("--limit", type=int, default=10)
    reconcile.add_argument("--per-provider-limit", type=int, default=3)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        now = _clock(args)
        if args.command == "reconcile":
            print(json.dumps(_reconcile(args, now), sort_keys=True))
        else:
            report, human = _health(args, now)
            print(render_human(report) if human else json.dumps(report, sort_keys=True))
        return 0
    except (
        CatalogError,
        OSError,
        ProviderHealthError,
        SocialStoreError,
        sqlite3.Error,
        ValueError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
