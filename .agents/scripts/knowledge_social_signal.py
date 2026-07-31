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
    normalize_events,
    route_status,
    utc_now,
)
from knowledge_corpus_catalog import CatalogError, DEFAULT_ALIAS, resolve
from knowledge_social_import import canonical_json, import_archive_payload
from knowledge_social_store import SocialStoreError, validate_root


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "inspect", "import-events"))
    parser.add_argument("--config", type=Path)
    parser.add_argument("--events", type=Path)
    parser.add_argument("--base", type=Path)
    parser.add_argument("--alias", default=DEFAULT_ALIAS)
    parser.add_argument("--observed-at", help=argparse.SUPPRESS)
    args = parser.parse_args()
    needs_input = args.command in {"inspect", "import-events"}
    if needs_input and (args.config is None or args.events is None):
        parser.error(f"{args.command} requires --config and --events")
    if not needs_input and (args.config is not None or args.events is not None):
        parser.error("--config and --events are valid only for inspect or import-events")
    if args.command != "import-events" and (args.base is not None or args.alias != DEFAULT_ALIAS):
        parser.error("--base and --alias are valid only for import-events")
    return args


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
