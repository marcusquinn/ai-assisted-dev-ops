#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Import one bounded, identity-verified Medium account export."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from _knowledge_social_lease import (
    RunLease,
    RunLeaseRequest,
    acquire_run_lease,
    fail_active_run,
    release_run_lease,
)
from _knowledge_social_medium import parse_medium_archive, persist_medium_archive
from knowledge_corpus_catalog import DEFAULT_ALIAS, resolve
from knowledge_corpus_context import CatalogError
from knowledge_social_store import SocialStoreError, validate_root

DEFAULT_MAX_BYTES = 512 * 1024 * 1024
DEFAULT_MAX_ITEMS = 50_000


def _positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer") from error
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path)
    parser.add_argument("--alias", default=DEFAULT_ALIAS)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--connection-id", required=True)
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--username")
    parser.add_argument(
        "--exported-at",
        required=True,
        help="export observation time with an explicit timezone",
    )
    parser.add_argument("--max-bytes", type=_positive_int, default=DEFAULT_MAX_BYTES)
    parser.add_argument("--max-items", type=_positive_int, default=DEFAULT_MAX_ITEMS)
    parser.add_argument("--collector-id", default="medium_archive")
    parser.add_argument("--lease-seconds", type=_positive_int, default=300)
    args = parser.parse_args()
    if args.max_bytes > 1024 * 1024 * 1024:
        parser.error("--max-bytes cannot exceed 1073741824")
    if args.max_items > 1_000_000:
        parser.error("--max-items cannot exceed 1000000")
    if args.lease_seconds > 86_400:
        parser.error("--lease-seconds cannot exceed 86400")
    return args


def _release_safely(root: Path, lease: RunLease | None) -> None:
    if lease is None:
        return
    try:
        release_run_lease(root, lease)
    except SocialStoreError:
        return


def main() -> int:
    args = parse_args()
    lease: RunLease | None = None
    root: Path | None = None
    try:
        base = (
            args.base
            if args.base is not None
            else Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
        )
        root = validate_root(resolve(base, args.alias, "knowledge.write"))
        parsed, payload = parse_medium_archive(
            args.archive,
            args.connection_id,
            args.account_id,
            args.username,
            args.exported_at,
            args.max_bytes,
            args.max_items,
        )
        lease = acquire_run_lease(
            root,
            RunLeaseRequest(
                args.connection_id,
                "archive",
                args.collector_id,
                "sync",
                args.lease_seconds,
                parsed.raw_sha256,
            ),
        )
        result = persist_medium_archive(root, parsed, payload, lease)
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


if __name__ == "__main__":
    raise SystemExit(main())
