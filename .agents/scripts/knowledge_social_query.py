#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Query authorized social corpora or write a private personal annotation."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from _knowledge_social_annotation import (
    load_private_annotations,
    read_private_body,
    write_private_annotation,
)
from _knowledge_social_query import (
    build_fts_query,
    candidate_limit,
    fuse_results,
    search_corpus,
    social_store_exists,
)
from knowledge_corpus_catalog import DEFAULT_ALIAS, authorized_scope
from knowledge_corpus_context import CatalogError, validate_private_file
from knowledge_social_store import SocialStoreError, validate_root

DEFAULT_BASE = Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
MAX_RESULTS = 100


def _base_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--base", type=Path, default=DEFAULT_BASE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    query = subparsers.add_parser("query", help="search authorized social corpora")
    _base_argument(query)
    query.add_argument("--alias", help="narrow the authorized scope to one alias")
    query_input = query.add_mutually_exclusive_group(required=True)
    query_input.add_argument("--query")
    query_input.add_argument("--query-file", type=Path)
    query.add_argument("--limit", type=int, default=10)

    annotate = subparsers.add_parser(
        "annotate", help="write a private annotation in personal:default"
    )
    _base_argument(annotate)
    annotate.add_argument("--provider", required=True)
    annotate.add_argument("--object-type", required=True)
    annotate.add_argument("--remote-id", required=True)
    annotate.add_argument("--annotation-id")
    annotate.add_argument("--body-file", type=Path, required=True)
    return parser.parse_args()


def _read_query(args: argparse.Namespace) -> str:
    if args.query is not None:
        return str(args.query)
    validate_private_file(args.query_file, "query file", repair=False)
    return str(args.query_file.read_text(encoding="utf-8"))


def _authorized_roots(
    base: Path, capability: str, alias: str | None
) -> tuple[str, list[tuple[str, Path]]]:
    principal_id, corpora = authorized_scope(base, capability, alias)
    authorized = [
        (corpus_alias, validate_root(root)) for corpus_alias, root in corpora
    ]
    if not authorized:
        raise CatalogError("access denied: no authorized corpora")
    return principal_id, authorized


def query_social(args: argparse.Namespace) -> dict[str, Any]:
    if args.limit < 1 or args.limit > MAX_RESULTS:
        raise SocialStoreError("limit must be between 1 and 100")
    principal_id, corpora = _authorized_roots(
        args.base, "knowledge.read", args.alias
    )
    fts_query = build_fts_query(_read_query(args))
    per_corpus = [
        (
            alias,
            search_corpus(alias, root, fts_query, candidate_limit(args.limit)),
        )
        for alias, root in corpora
        if social_store_exists(root)
    ]
    results = fuse_results(per_corpus, args.limit)
    roots = dict(corpora)
    if DEFAULT_ALIAS in roots:
        keys = {
            (result["provider"], result["object_type"], result["remote_id"])
            for result in results
        }
        overlays = load_private_annotations(roots[DEFAULT_ALIAS], principal_id, keys)
        for result in results:
            key = (result["provider"], result["object_type"], result["remote_id"])
            result["private_annotations"] = overlays.get(key, [])
    else:
        for result in results:
            result["private_annotations"] = []
    return {
        "version": 1,
        "scope": {"aliases": [alias for alias, _ in corpora]},
        "results": results,
    }


def annotate_social(args: argparse.Namespace) -> dict[str, Any]:
    principal_id, corpora = _authorized_roots(
        args.base, "knowledge.write", DEFAULT_ALIAS
    )
    body = read_private_body(args.body_file)
    return write_private_annotation(
        corpora[0][1],
        principal_id,
        (args.provider, args.object_type, args.remote_id),
        body,
        args.annotation_id,
    )


def main() -> int:
    args = parse_args()
    try:
        result = query_social(args) if args.command == "query" else annotate_social(args)
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0
    except (CatalogError, OSError, SocialStoreError, UnicodeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
