#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Manage the provider-neutral local domain-opportunity evidence store."""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path
from typing import Any

from domain_opportunity_contract import DomainOpportunityContractError, normalize_listing
from domain_opportunity_reporting import ReportOptions, ReportingError, build_report, pipeline_status, publish, render
from domain_opportunity_store import DomainOpportunityStore, DomainOpportunityStoreError


def cmd_init(args: argparse.Namespace) -> int:
    """Initialize or reopen a compatible local store."""
    with DomainOpportunityStore(args.db, initialize=True) as store:
        print(f"initialized schema v{store.status()['schema_version']}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    """Report schema compatibility and local record counts."""
    with DomainOpportunityStore(args.db) as store:
        status = store.status()
    if args.json:
        print(json.dumps(status, sort_keys=True, separators=(",", ":")))
    else:
        print(f"schema v{status['schema_version']}: {status['counts']['listings']} listings")
    return 0


def cmd_pipeline_status(args: argparse.Namespace) -> int:
    """Report inventory and optional enrichment readiness."""
    with DomainOpportunityStore(args.db) as store:
        status = pipeline_status(store)
    print(json.dumps(status, sort_keys=True) if args.json else "\n".join(
        f"{stage}: {value}" for stage, value in status["stages"].items()
    ))
    return 0


def _report(args: argparse.Namespace) -> dict[str, Any]:
    with DomainOpportunityStore(args.db) as store:
        return build_report(store, ReportOptions(
            as_of=args.as_of, active_only=args.active_only,
            eligible_only=args.eligible_only, limit=args.limit,
        ))


def cmd_candidates(args: argparse.Namespace) -> int:
    """Print the ranked joined candidate projection as JSON."""
    print(json.dumps(_report(args)["candidates"], sort_keys=True, separators=(",", ":")))
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    """Atomically publish one deterministic report projection."""
    report = _report(args)
    publish(args.output, render(report, args.format))
    print(json.dumps({"exported": report["candidate_count"], "format": args.format, "output": args.output}, sort_keys=True))
    return 0


def cmd_analysis_packet(args: argparse.Namespace) -> int:
    """Publish concise Markdown plus complete measured evidence."""
    report = _report(args)
    publish(args.output, render(report, "markdown"))
    print(json.dumps({"exported": report["candidate_count"], "format": "markdown", "output": args.output}, sort_keys=True))
    return 0


def _add_report_filters(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--db", required=True)
    parser.add_argument("--as-of")
    parser.add_argument("--active-only", action="store_true")
    parser.add_argument("--eligible-only", action="store_true")
    parser.add_argument("--limit", type=int)


def _load_jsonl(path: Path, provider: str) -> list[dict[str, Any]]:
    if path.is_symlink() or not path.is_file():
        raise DomainOpportunityContractError("input must be a regular JSONL file")
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                document = json.loads(line)
                document["provider"] = provider
                records.append(normalize_listing(document))
            except (AttributeError, TypeError, json.JSONDecodeError, DomainOpportunityContractError) as exc:
                raise DomainOpportunityContractError(f"input record {line_number} is invalid") from exc
    if not records:
        raise DomainOpportunityContractError("input contains no listing records")
    run_ids = {record["source_run_id"] for record in records}
    if len(run_ids) != 1:
        raise DomainOpportunityContractError("one import must contain exactly one source_run_id")
    return records


def cmd_import_jsonl(args: argparse.Namespace) -> int:
    """Import one validated provider batch atomically."""
    provider = args.provider.strip().lower()
    records = _load_jsonl(Path(args.input).expanduser(), provider)
    run_id = records[0]["source_run_id"]
    with DomainOpportunityStore(args.db) as store:
        try:
            with store.transaction():
                store.begin_source_run(run_id, provider, started_at=records[0]["observed_at"])
                inserted = sum(store.upsert_listing_observation(record) for record in records)
                store.complete_source_run(run_id, len(records))
        except Exception:
            with store.transaction():
                existing = store.connection.execute(
                    "SELECT 1 FROM source_runs WHERE source_run_id=?", (run_id,)
                ).fetchone()
                if existing is None:
                    store.begin_source_run(run_id, provider, started_at=records[0]["observed_at"])
                store.fail_source_run(run_id, "import_failed")
            raise
    print(json.dumps({"imported": inserted, "records": len(records)}, sort_keys=True))
    return 0


def cmd_export_csv(args: argparse.Namespace) -> int:
    """Export the stable current listing view to CSV."""
    with DomainOpportunityStore(args.db) as store:
        count = store.export_csv(args.output, active_only=args.active_only)
    print(json.dumps({"exported": count}, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    """Build the provider-neutral local evidence CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    init_parser = subparsers.add_parser("init", help="Initialize or reopen a compatible store")
    init_parser.add_argument("--db")
    init_parser.set_defaults(handler=cmd_init)
    status_parser = subparsers.add_parser("status", help="Show local store status")
    status_parser.add_argument("--db")
    status_parser.add_argument("--json", action="store_true")
    status_parser.set_defaults(handler=cmd_status)
    pipeline_parser = subparsers.add_parser("pipeline-status", help="Show pipeline evidence readiness")
    pipeline_parser.add_argument("--db", required=True)
    pipeline_parser.add_argument("--json", action="store_true")
    pipeline_parser.set_defaults(handler=cmd_pipeline_status)
    import_parser = subparsers.add_parser("import-jsonl", help="Import normalized JSONL evidence")
    import_parser.add_argument("--db")
    import_parser.add_argument("--input", required=True)
    import_parser.add_argument("--provider", required=True)
    import_parser.set_defaults(handler=cmd_import_jsonl)
    export_parser = subparsers.add_parser("export-csv", help="Export current listing evidence")
    export_parser.add_argument("--db")
    export_parser.add_argument("--output", required=True)
    export_parser.add_argument("--active-only", action="store_true")
    export_parser.set_defaults(handler=cmd_export_csv)
    candidates_parser = subparsers.add_parser("candidates", help="Print ranked joined candidates")
    _add_report_filters(candidates_parser)
    candidates_parser.set_defaults(handler=cmd_candidates)
    report_parser = subparsers.add_parser("report", help="Publish ranked CSV, JSON, or Markdown")
    _add_report_filters(report_parser)
    report_parser.add_argument("--format", choices=("csv", "json", "markdown"), required=True)
    report_parser.add_argument("--output", required=True)
    report_parser.set_defaults(handler=cmd_report)
    packet_parser = subparsers.add_parser("analysis-packet", help="Publish a Markdown decision packet")
    _add_report_filters(packet_parser)
    packet_parser.add_argument("--output", required=True)
    packet_parser.set_defaults(handler=cmd_analysis_packet)
    return parser


def main(argv: list[str] | None = None) -> int:
    """Dispatch one deterministic local evidence operation."""
    args = build_parser().parse_args(argv)
    try:
        return int(args.handler(args))
    except (DomainOpportunityContractError, DomainOpportunityStoreError, ReportingError) as exc:
        print(f"domain-opportunity: {exc}", file=sys.stderr)
        return 1
    except (OSError, sqlite3.Error):
        print("domain-opportunity: local storage operation failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
