#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Inspect or import bounded offline signal-cli receive notifications."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from _knowledge_social_signal import (
    SignalCollectorError,
    load_config,
    load_events,
    route_status,
    utc_now,
)
from _knowledge_social_signal_normalize import normalize_events
from knowledge_corpus_catalog import CatalogError, DEFAULT_ALIAS, resolve
from knowledge_social_import import canonical_json, import_archive_payload
from knowledge_social_store import SocialStoreError, validate_root


def _add_event_arguments(
    parser: argparse.ArgumentParser, include_destination: bool = False
) -> None:
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--events", type=Path, required=True)
    parser.add_argument("--observed-at", help=argparse.SUPPRESS)
    if include_destination:
        parser.add_argument("--base", type=Path)
        parser.add_argument("--alias", default=DEFAULT_ALIAS)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    _add_event_arguments(commands.add_parser("inspect"))
    _add_event_arguments(
        commands.add_parser("import-events"), include_destination=True
    )
    return parser.parse_args()


def _summary(archive: dict[str, Any], counts: dict[str, int]) -> dict[str, Any]:
    return {
        "account_alias": archive["policy"]["account_alias"],
        "activities": len(archive["activities"]),
        "counts": counts,
        "media": len(archive["media"]),
        "objects": len(archive["objects"]),
        "provider": archive["provider"],
        "route": archive["policy"]["source"],
    }


def main() -> int:
    args = parse_args()
    try:
        if args.command == "status":
            result: Any = route_status()
        else:
            config = load_config(args.config)
            events = load_events(args.events, config)
            archive, counts = normalize_events(config, events, args.observed_at or utc_now())
            result = _summary(archive, counts)
            if args.command == "import-events":
                base = args.base or Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
                root = validate_root(resolve(base, args.alias, "knowledge.write"))
                imported = import_archive_payload(
                    root, archive, canonical_json(archive).encode("utf-8")
                )
                result["import"] = imported
        print(json.dumps(result, sort_keys=True))
        return 0
    except (CatalogError, OSError, SignalCollectorError, SocialStoreError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
