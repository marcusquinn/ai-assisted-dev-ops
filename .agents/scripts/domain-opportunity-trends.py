#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Prepare and import manual Google Trends interest-over-time exports; no browser automation."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from domain_opportunity_trends import TrendsError, import_export, inspect_export, load_manifest, queue_manifests


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    queue = commands.add_parser("queue")
    queue.add_argument("--db", required=True)
    queue.add_argument("--output", required=True)
    for name in ("inspect", "import"):
        command = commands.add_parser(name)
        command.add_argument("--manifest", required=True)
        command.add_argument("--input", required=True)
        if name == "import":
            command.add_argument("--db", required=True)
    arguments = parser.parse_args()
    try:
        if arguments.command == "queue":
            result = {
                "manifests": [str(path) for path in queue_manifests(arguments.db, arguments.output)],
                "browser_checklist": [
                    "Open the official Trends site in a visible browser tab.",
                    "Configure each comparison and filter exactly as recorded in its manifest.",
                    "Download Interest over time, record its share URL and export time, then inspect the CSV.",
                ],
            }
            print(json.dumps(result, sort_keys=True))
            return 0
        manifest = load_manifest(arguments.manifest)
        if arguments.command == "inspect":
            raw_hash, series = inspect_export(manifest, arguments.input)
            result = {"batch_id": manifest["batch_id"], "raw_hash": raw_hash, "series": len(series), "parser_profile": "google-trends-interest-over-time-v1"}
        else:
            result = import_export(manifest, arguments.input, arguments.db)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, TrendsError, ValueError) as exc:
        print(f"domain-opportunity-trends: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
