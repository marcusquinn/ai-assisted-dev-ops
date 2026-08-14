#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""CLI for privacy-safe normalized marketing performance ingestion."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from pathlib import Path
from typing import Any

from performance_adapters import (
    ADAPTERS,
    FIXTURE_ONLY_ADAPTERS,
    AdapterResult,
    PerformanceAdapterError,
    adapter_status,
    load_adapter,
    read_input,
)
from performance_contract import (
    PerformanceContractError,
    validate_batch_header,
    validate_event,
    wire_json,
)
from performance_reporting import PerformanceReporting
from performance_store import MarketingPerformanceStore, PerformanceStoreError
from performance_store_schema import resolve_paths


def _json(document: Any) -> None:
    print(wire_json(document))


def _repo(value: str | None) -> Path:
    return Path(value or ".").expanduser().resolve()


def _load_result(args: argparse.Namespace, adapter: str | None = None) -> AdapterResult:
    selected = adapter or args.adapter
    if selected in FIXTURE_ONLY_ADAPTERS and os.environ.get("AIDEVOPS_TEST_MODE") != "1":
        raise PerformanceAdapterError(
            f"{selected} is fixture-only; live provider ingest is not implemented"
        )
    return load_adapter(
        selected,
        Path(args.input).expanduser().absolute(),
        account_override=getattr(args, "account_ref", None),
        campaign_id=getattr(args, "campaign_id", None),
    )


def _validate_result(result: AdapterResult) -> dict[str, Any]:
    header = validate_batch_header(result.batch)
    errors = [
        {"index": error.get("index", "unknown"), "reason": str(error.get("reason", "adapter record rejected"))[:256]}
        for error in result.errors
    ]
    accepted = 0
    effective_coverage = "partial" if header["missing_scopes"] else header["coverage"]
    for index, event in enumerate(header["events"]):
        try:
            normalized = validate_event(
                event,
                effective_coverage,
                header["missing_scopes"],
            )
            if normalized["subject"]["identity_state"] == "ambiguous":
                errors.append({"index": index, "reason": "identity_ambiguous"})
            else:
                accepted += 1
        except PerformanceContractError as exc:
            errors.append({"index": index, "reason": str(exc)[:256]})
    return {
        "schema": "aidevops.marketing-performance-validation/v1",
        "valid": not errors,
        "source": header["source"],
        "account_ref": header["account_ref"],
        "accepted": accepted,
        "quarantined": len(errors),
        "coverage": "partial" if errors else effective_coverage,
        "errors": errors,
    }


def cmd_init(args: argparse.Namespace) -> int:
    paths = resolve_paths(_repo(args.repo))
    with MarketingPerformanceStore.open(paths.repo, provision=True) as store:
        config = store.config
        version = int(store.connection.execute("PRAGMA user_version").fetchone()[0])
    _json(
        {
            "schema": "aidevops.marketing-performance-init/v1",
            "status": "ready",
            "plane": str(paths.marketing),
            "config_schema": config["schema"],
            "store_schema_version": version,
        }
    )
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    report = _validate_result(_load_result(args))
    _json(report)
    return 0 if report["valid"] else 2


def _ingest(args: argparse.Namespace, adapter: str | None = None) -> tuple[dict[str, Any], Path | None]:
    result = _load_result(args, adapter)
    if args.dry_run:
        report = _validate_result(result)
        report["dry_run"] = True
        return report, None
    with MarketingPerformanceStore.open(_repo(args.repo), provision=True) as store:
        report = store.ingest(adapter or args.adapter, result)
        summary = None
        campaign_id = getattr(args, "campaign_id", None)
        if (adapter or args.adapter) == "campaign" and campaign_id:
            summary = PerformanceReporting(store).write_campaign_summary(
                campaign_id,
                str(report["account_ref"]),
            )
        return report, summary


def cmd_ingest(args: argparse.Namespace) -> int:
    report, _summary = _ingest(args)
    _json(report)
    return 0 if not args.dry_run or report.get("valid", False) else 2


def cmd_ingest_campaign(args: argparse.Namespace) -> int:
    args.input = args.results
    report, summary = _ingest(args, "campaign")
    if summary is not None:
        report["summary"] = str(summary)
    _json(report)
    return 0 if not args.dry_run or report.get("valid", False) else 2


def cmd_backfill(args: argparse.Namespace) -> int:
    report, _summary = _ingest(args, "phase1")
    _json(report)
    return 0 if not args.dry_run or report.get("valid", False) else 2


def cmd_list(args: argparse.Namespace) -> int:
    with MarketingPerformanceStore.open(_repo(args.repo)) as store:
        reporting = PerformanceReporting(store)
        if args.subjects:
            records = reporting.subject_records()
        else:
            events = reporting.event_records(
                history=args.history,
                source=args.source,
                account_ref=args.account_ref,
                campaign_id=args.campaign_id,
            )
            records = [reporting.phase1_result(event) for event in events] if args.results else events
    _json({"schema": "aidevops.marketing-performance-list/v1", "records": records})
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    paths = resolve_paths(_repo(args.repo))
    if paths.config.is_symlink() or paths.index.is_symlink() or paths.database.is_symlink():
        raise PerformanceContractError("performance plane status paths are unsafe")
    if paths.config.exists() and paths.index.exists() and not paths.database.exists():
        raise PerformanceContractError("marketing performance database is missing")
    if not paths.config.exists() or not paths.database.exists():
        report: dict[str, Any] = {
            "schema": "aidevops.marketing-performance-status/v1",
            "status": "uninitialized",
            "sources": [],
            "summary": {
                "source_accounts": 0,
                "event_history": 0,
                "effective_events": 0,
                "subjects": 0,
                "quarantine_total": 0,
                "unresolved_quarantine": 0,
            },
        }
    else:
        now_epoch = args.now
        if now_epoch is not None and os.environ.get("AIDEVOPS_TEST_MODE") != "1":
            raise PerformanceContractError("--now is available only to the test harness")
        with MarketingPerformanceStore.open(paths.repo) as store:
            report = PerformanceReporting(store).status(now_epoch)
    report["adapters"] = adapter_status()
    if args.json:
        _json(report)
    else:
        print(f"Marketing performance: {report['status']}")
        for source in report["sources"]:
            print(
                f"  {source['source']}/{source['account_ref']}: {source['status']} "
                f"coverage={source['coverage']} quarantine={source['unresolved_quarantine']}"
            )
        print(
            f"  Events: {report['summary']['effective_events']} effective / "
            f"{report['summary']['event_history']} history"
        )
    return 0


def cmd_reconcile(args: argparse.Namespace) -> int:
    raw = read_input(Path(args.input).expanduser().absolute())
    try:
        document = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise PerformanceContractError("reconciliation input must be valid UTF-8 JSON") from exc
    with MarketingPerformanceStore.open(_repo(args.repo)) as store:
        report = PerformanceReporting(store).reconcile(document)
    _json(report)
    return 0


def cmd_export(args: argparse.Namespace) -> int:
    lexical_repo = Path(args.repo or ".").expanduser().absolute()
    repo = _repo(args.repo)
    output = Path(args.output).expanduser().absolute()
    try:
        common = Path(os.path.commonpath((lexical_repo, output)))
    except ValueError:
        raise PerformanceContractError("export destination has no safe local root") from None
    relative_output = output.relative_to(common)
    current = common.resolve()
    for component in relative_output.parts[:-1]:
        current /= component
        if current.is_symlink():
            raise PerformanceContractError(
                "export destination contains a symlinked directory"
            )
    output = common.resolve() / relative_output
    with MarketingPerformanceStore.open(repo) as store:
        report = PerformanceReporting(store).export(
            args.purpose,
            output,
            result_format=args.format == "results",
        )
    _json(report)
    return 0


def cmd_repair(args: argparse.Namespace) -> int:
    with MarketingPerformanceStore.open(_repo(args.repo)) as store:
        expired = store.recover_expired_leases()
    _json(
        {
            "schema": "aidevops.marketing-performance-repair/v1",
            "expired_leases_removed": expired,
            "history_rewritten": False,
        }
    )
    return 0


def cmd_rebuild(args: argparse.Namespace) -> int:
    with MarketingPerformanceStore.open(_repo(args.repo)) as store:
        report = PerformanceReporting(store).rebuild_summaries()
    _json(report)
    return 0


def _input_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--adapter", choices=sorted(ADAPTERS), required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--account-ref")
    parser.add_argument("--repo", default=".")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Privacy-safe normalized marketing performance plane"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init", help="Provision the marketing performance plane")
    init_parser.add_argument("--repo", default=".")
    init_parser.set_defaults(handler=cmd_init)

    validate_parser = subparsers.add_parser("validate", help="Validate without mutation")
    _input_options(validate_parser)
    validate_parser.set_defaults(handler=cmd_validate)

    ingest_parser = subparsers.add_parser("ingest", help="Ingest one normalized batch")
    _input_options(ingest_parser)
    ingest_parser.add_argument("--dry-run", action="store_true")
    ingest_parser.set_defaults(handler=cmd_ingest)

    campaign_parser = subparsers.add_parser(
        "ingest-campaign", help="Ingest a manual campaign results Markdown file"
    )
    campaign_parser.add_argument("--campaign-id", required=True)
    campaign_parser.add_argument("--results", required=True)
    campaign_parser.add_argument("--account-ref")
    campaign_parser.add_argument("--repo", default=".")
    campaign_parser.add_argument("--dry-run", action="store_true")
    campaign_parser.set_defaults(handler=cmd_ingest_campaign)

    backfill_parser = subparsers.add_parser(
        "backfill", help="Import existing Phase 1 marketing result JSONL"
    )
    backfill_parser.add_argument("--input", required=True)
    backfill_parser.add_argument("--account-ref")
    backfill_parser.add_argument("--repo", default=".")
    backfill_parser.add_argument("--dry-run", action="store_true")
    backfill_parser.set_defaults(handler=cmd_backfill)

    list_parser = subparsers.add_parser("list", help="List pseudonymous events or subjects")
    list_parser.add_argument("--repo", default=".")
    list_parser.add_argument("--source")
    list_parser.add_argument("--account-ref")
    list_parser.add_argument("--campaign-id")
    list_parser.add_argument("--history", action="store_true")
    list_parser.add_argument("--subjects", action="store_true")
    list_parser.add_argument("--results", action="store_true")
    list_parser.set_defaults(handler=cmd_list)

    status_parser = subparsers.add_parser("status", help="Show coverage and freshness")
    status_parser.add_argument("--repo", default=".")
    status_parser.add_argument("--json", action="store_true")
    status_parser.add_argument("--now", type=int, help=argparse.SUPPRESS)
    status_parser.set_defaults(handler=cmd_status)

    reconcile_parser = subparsers.add_parser(
        "reconcile", help="Append explicit owner reconciliation decisions"
    )
    reconcile_parser.add_argument("--input", required=True)
    reconcile_parser.add_argument("--repo", default=".")
    reconcile_parser.set_defaults(handler=cmd_reconcile)

    export_parser = subparsers.add_parser("export", help="Write a bounded pseudonymous export")
    export_parser.add_argument("--purpose", choices=("measurement", "audience"), required=True)
    export_parser.add_argument("--format", choices=("events", "results"), default="events")
    export_parser.add_argument("--output", required=True)
    export_parser.add_argument("--repo", default=".")
    export_parser.set_defaults(handler=cmd_export)

    repair_parser = subparsers.add_parser("repair", help="Recover expired mutable leases")
    repair_parser.add_argument("--repo", default=".")
    repair_parser.set_defaults(handler=cmd_repair)

    rebuild_parser = subparsers.add_parser(
        "rebuild", help="Rebuild aggregate campaign summaries from immutable history"
    )
    rebuild_parser.add_argument("--repo", default=".")
    rebuild_parser.set_defaults(handler=cmd_rebuild)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.handler(args))
    except (PerformanceContractError, PerformanceAdapterError, PerformanceStoreError) as exc:
        print(f"performance: {exc}", file=sys.stderr)
        return 1
    except (KeyError, TypeError, ValueError):
        print("performance: input shape is invalid", file=sys.stderr)
        return 1
    except (OSError, sqlite3.Error):
        print("performance: local storage operation failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
