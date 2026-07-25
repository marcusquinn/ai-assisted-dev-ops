#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Plan and reconcile deterministic social corpus synchronization."""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path
from typing import Any

from _knowledge_social_lease import (
    RunLeaseRequest,
    SocialLeaseLostError,
    acquire_run_lease,
    fail_active_run,
    release_run_lease,
)
from _knowledge_social_reconcile import (
    load_reconciliation_snapshot,
    reconcile_snapshot,
)
from _knowledge_social_schedule import due_plan, run_receipts
from knowledge_corpus_catalog import DEFAULT_ALIAS, authorized_scope, resolve
from knowledge_corpus_context import CatalogError
from knowledge_social_store import SocialStoreError, validate_opaque, validate_root


def _base(args: argparse.Namespace) -> Path:
    if args.base is not None:
        return args.base
    return Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"


def _write_context(args: argparse.Namespace) -> tuple[str, Path]:
    principal_id, corpora = authorized_scope(
        _base(args), "knowledge.write", args.alias
    )
    return principal_id, validate_root(corpora[0][1])


def _read_root(args: argparse.Namespace) -> Path:
    return validate_root(resolve(_base(args), args.alias, "knowledge.read"))


def _collector(args: argparse.Namespace, principal_id: str) -> str:
    return validate_opaque(args.collector_id or principal_id, "collector_id")


def _run_reconcile(args: argparse.Namespace) -> dict[str, Any]:
    principal_id, root = _write_context(args)
    snapshot = load_reconciliation_snapshot(args.snapshot)
    lease = acquire_run_lease(
        root,
        RunLeaseRequest(
            args.connection_id,
            args.stream,
            _collector(args, principal_id),
            "reconcile",
            args.lease_seconds,
            snapshot.request_hash,
        ),
        now_epoch=args.now_epoch,
    )
    try:
        return reconcile_snapshot(root, lease, snapshot, now_epoch=args.now_epoch)
    except Exception:
        try:
            fail_active_run(
                root, lease, "reconciliation", now_epoch=args.now_epoch
            )
        except SocialLeaseLostError:
            pass
        raise
    finally:
        release_run_lease(root, lease)


def _run_due(args: argparse.Namespace, run_kind: str) -> list[dict[str, Any]]:
    return due_plan(
        _read_root(args),
        run_kind,
        now_epoch=args.now_epoch,
        interval_seconds=args.interval_seconds,
    )


def _run_receipts(args: argparse.Namespace) -> list[dict[str, Any]]:
    return run_receipts(_read_root(args), args.connection_id, limit=args.limit)


def _add_scope(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--base", type=Path)
    parser.add_argument("--alias", default=DEFAULT_ALIAS)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("sync-due", "reconcile-due"):
        due = subparsers.add_parser(command)
        _add_scope(due)
        due.add_argument("--now-epoch", type=int, help=argparse.SUPPRESS)
        due.add_argument("--interval-seconds", type=int)
    reconcile = subparsers.add_parser("reconcile")
    _add_scope(reconcile)
    reconcile.add_argument("--connection-id", required=True)
    reconcile.add_argument("--stream", required=True)
    reconcile.add_argument("--snapshot", required=True, type=Path)
    reconcile.add_argument("--collector-id")
    reconcile.add_argument("--lease-seconds", type=int, default=300)
    reconcile.add_argument("--now-epoch", type=int, help=argparse.SUPPRESS)
    receipts = subparsers.add_parser("receipts")
    _add_scope(receipts)
    receipts.add_argument("--connection-id")
    receipts.add_argument("--limit", type=int, default=100)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "sync-due":
            result: Any = _run_due(args, "sync")
        elif args.command == "reconcile-due":
            result = _run_due(args, "reconcile")
        elif args.command == "reconcile":
            result = _run_reconcile(args)
        else:
            result = _run_receipts(args)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (CatalogError, OSError, SocialStoreError, sqlite3.Error, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
