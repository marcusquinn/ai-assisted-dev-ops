#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared authenticated CLI boundary for live social collectors."""

from __future__ import annotations

import argparse
import json
import sqlite3
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable

from knowledge_corpus_catalog import authorized_scope
from knowledge_corpus_context import CatalogError
from knowledge_social_store import SocialStoreError, validate_opaque, validate_root

Collector = Callable[[argparse.Namespace, Path, str], dict[str, Any]]


def run_collector(args: argparse.Namespace, collector: Collector) -> int:
    """Resolve one authorized corpus and print a sanitized collector result."""
    try:
        base = (
            args.base
            if args.base
            else Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
        )
        principal_id, corpora = authorized_scope(base, "knowledge.write", args.alias)
        root = validate_root(corpora[0][1])
        collector_id = validate_opaque(
            args.collector_id or principal_id, "collector_id"
        )
        print(json.dumps(collector(args, root, collector_id), sort_keys=True))
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
