#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only Namecheap Market auction sync for local domain evidence."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from domain_opportunity_namecheap import MAX_PAGES, NamecheapMarketError, SyncOptions, sync
from domain_opportunity_store import DomainOpportunityStoreError


def build_parser() -> argparse.ArgumentParser:
    """Build the narrow read-only provider CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    sync_parser = commands.add_parser("sync", help="Import active .com sales without bidding")
    sync_parser.add_argument("--db", required=True, help="Local SQLite evidence store")
    sync_parser.add_argument("--fixture", help="Redacted offline API response fixture")
    sync_parser.add_argument("--max-pages", type=int, default=MAX_PAGES)
    return parser


def main(argv: list[str] | None = None) -> int:
    """Run one safe fixture or opt-in live sync."""
    arguments = build_parser().parse_args(argv)
    try:
        fixture = Path(arguments.fixture).expanduser() if arguments.fixture else None
        result = sync(arguments.db, SyncOptions(fixture=fixture, max_pages=arguments.max_pages))
    except (NamecheapMarketError, DomainOpportunityStoreError):
        print("namecheap-market: sync failed", file=sys.stderr)
        return 1
    print(json.dumps(result.as_dict(), sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
