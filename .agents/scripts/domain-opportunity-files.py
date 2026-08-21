#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Inspect and import authorized local auction inventory files without network access."""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys

from domain_opportunity_contract import DomainOpportunityContractError
from domain_opportunity_files import DomainOpportunityFileError, ImportOptions, import_inventory, inspect
from domain_opportunity_store import DomainOpportunityStoreError


def build_parser() -> argparse.ArgumentParser:
    """Build the local-only inventory import command line."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    inspect_parser = commands.add_parser("inspect", help="Report headers and safety diagnostics without writes")
    inspect_parser.add_argument("--provider", required=True)
    inspect_parser.add_argument("--input", required=True)
    inspect_parser.set_defaults(handler=lambda args: inspect(args.input, args.provider))
    import_parser = commands.add_parser("import", help="Import one authorized local inventory file")
    import_parser.add_argument("--provider", required=True)
    import_parser.add_argument("--input", required=True)
    import_parser.add_argument("--db", required=True)
    import_parser.add_argument("--rejects")
    import_parser.add_argument("--observed-at")
    import_parser.set_defaults(
        handler=lambda args: import_inventory(
            args.input, args.provider, args.db, ImportOptions(rejects_path=args.rejects, observed_at=args.observed_at)
        )
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    """Run one deterministic local inspection or import."""
    args = build_parser().parse_args(argv)
    try:
        print(json.dumps(args.handler(args), sort_keys=True, separators=(",", ":")))
        return 0
    except (DomainOpportunityFileError, DomainOpportunityContractError, DomainOpportunityStoreError, OSError, sqlite3.Error) as exc:
        print(f"domain-opportunity-files: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
