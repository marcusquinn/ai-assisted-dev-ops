#!/usr/bin/env python3
"""Detect deterministic tool-output waste without reproducing transcript content."""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any

from session_output_metrics import AnalysisConfig, analyse
from session_output_opencode import extract_opencode_db
from session_output_transcript import extract_jsonl, resolve_jsonl


def print_text(report: dict[str, Any]) -> None:
    stats = report["stats"]
    thresholds = report["thresholds"]
    visibility = report["visibility"]
    print("## Output Efficiency")
    print(
        "Completed tool results: "
        f"{stats['completed_tool_results']} "
        f"({stats['tool_output_bytes']} bytes; ~{stats['approx_tool_output_tokens']} tokens)"
    )
    print(
        "Repeated unchanged snapshots: "
        f"{stats['repeated_snapshot_groups']} groups, "
        f"{stats['redundant_tool_results']} redundant results, "
        f"{stats['redundant_output_bytes']} redundant bytes"
    )
    print(f"Duplicate tool-output groups: {stats['duplicate_output_groups']}")
    print(
        "Repeated line/block groups: "
        f"{stats['repeated_line_groups']}/{stats['repeated_block_groups']}"
    )
    print(
        "Oversized tool results: "
        f"{stats['oversized_tool_results']} "
        f"(threshold {thresholds['oversized_output_bytes']} bytes)"
    )
    print(f"Successful oversized results: {stats['successful_oversized_results']}")
    print(
        "Receipt-backed background evidence: "
        f"{visibility['declared_background_evidence_bytes']} declared bytes across "
        f"{visibility['receipt_results']} receipts (background content not scanned)"
    )
    print(
        "Raw fallback / exact-output bypass results: "
        f"{stats['raw_fallback_results']} / {stats['exact_output_bypass_results']}"
    )
    if stats["parse_errors"]:
        print(f"Unparsed transcript records: {stats['parse_errors']}")
    print("Category coverage:")
    if not report["category_summary"]:
        print("- None above deterministic thresholds")
    for category in report["category_summary"]:
        print(
            f"- {category['kind']}: groups={category['finding_count']}, "
            f"occurrences={category['occurrences']}, "
            f"aggregate_bytes={category['aggregate_bytes']}, "
            f"leading_tool={category['leading_tool']}"
        )
    print("Candidates:")
    if not report["findings"]:
        print("- None above deterministic thresholds")
    for finding in report["findings"]:
        print_finding(finding)
    print("Evidence is aggregate and approximate-token only; raw transcript content is omitted.")


def print_finding(finding: dict[str, Any]) -> None:
    prefix = (
        f"- {finding['kind']} {finding['fingerprint']}: "
        f"tool={finding['tool']}, occurrences={finding['occurrences']}"
    )
    if "redundant_bytes" in finding:
        print(f"{prefix}, redundant_bytes={finding['redundant_bytes']}")
    else:
        visible_bytes = finding.get("total_bytes", finding.get("largest_bytes", 0))
        print(f"{prefix}, total_bytes={visible_bytes}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Detect repeated unchanged and oversized tool outputs in a session transcript."
    )
    parser.add_argument("--runtime", choices=("opencode", "claude-code", "normalized"), default="normalized")
    parser.add_argument("--source", required=True, help="SQLite database, JSONL file, or JSONL directory")
    parser.add_argument("--source-format", choices=("auto", "database", "transcript"), default="auto")
    parser.add_argument("--session", default="")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--min-repeat-bytes", type=int, default=80)
    parser.add_argument("--oversized-bytes", type=int, default=8192)
    parser.add_argument("--max-findings", type=int, default=5)
    args = parser.parse_args()
    thresholds = (args.min_repeat_bytes, args.oversized_bytes, args.max_findings)
    if any(value < 1 for value in thresholds):
        parser.error("thresholds and --max-findings must be positive integers")
    if args.session and not re.fullmatch(r"[A-Za-z0-9_.-]+", args.session):
        parser.error("--session may only contain letters, numbers, dots, hyphens, and underscores")
    return args


def use_database_source(args: argparse.Namespace, source: Path) -> bool:
    if args.source_format == "database":
        return True
    if args.source_format != "auto" or args.runtime != "opencode":
        return False
    if not source.is_file():
        return False
    return source.suffix == ".db"


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    source = Path(args.source).expanduser()
    if use_database_source(args, source):
        results, parse_errors = extract_opencode_db(source, args.session)
        source_kind = "database"
    else:
        transcript = resolve_jsonl(source, args.session)
        results, parse_errors = extract_jsonl(transcript)
        source_kind = "transcript"
    config = AnalysisConfig(
        runtime=args.runtime,
        session_id=args.session,
        source_kind=source_kind,
        parse_errors=parse_errors,
        min_repeat_bytes=args.min_repeat_bytes,
        oversized_bytes=args.oversized_bytes,
        max_findings=args.max_findings,
    )
    return analyse(results, config)


def main() -> int:
    args = parse_args()
    try:
        report = build_report(args)
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2
    except (OSError, sqlite3.Error):
        print("Error: transcript evidence could not be read", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    else:
        print_text(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
