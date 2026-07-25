#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Private knowledge-corpus catalog and default-deny path resolver CLI."""

from __future__ import annotations

import argparse
import os
import sqlite3
import sys
from pathlib import Path

from knowledge_corpus_catalog import (
    CAPABILITIES,
    DEFAULT_ALIAS,
    DEFAULT_CAPABILITY,
    list_authorized,
    provision,
    resolve,
)
from knowledge_corpus_context import CatalogError


def _default_base() -> Path:
    configured = (
        os.environ.get("KNOWLEDGE_CORPUS_BASE")
        or os.environ.get("PERSONAL_PLANE_BASE")
    )
    if configured:
        return Path(configured).expanduser()
    return Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Manage the private knowledge corpus catalog"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    provision_parser = subparsers.add_parser("provision")
    provision_parser.add_argument("--base", type=Path, default=_default_base())

    resolve_parser = subparsers.add_parser("resolve")
    resolve_parser.add_argument("--base", type=Path, default=_default_base())
    resolve_parser.add_argument("--alias", default=DEFAULT_ALIAS)
    resolve_parser.add_argument("--capability", default=DEFAULT_CAPABILITY)

    list_parser = subparsers.add_parser("list")
    list_parser.add_argument("--base", type=Path, default=_default_base())
    list_parser.add_argument("--capability", default=DEFAULT_CAPABILITY)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.command == "provision":
            provision(arguments.base)
            return 0
        if arguments.command == "resolve":
            print(resolve(arguments.base, arguments.alias, arguments.capability))
            return 0
        if arguments.command == "list":
            for alias, location in list_authorized(
                arguments.base, arguments.capability
            ):
                print(f"{alias}\t{location}")
            return 0
    except (CatalogError, sqlite3.Error, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
