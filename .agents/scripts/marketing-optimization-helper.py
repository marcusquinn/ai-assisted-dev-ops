#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Build privacy-safe marketing attribution, experiments, reports, and recommendations."""

from __future__ import annotations

import argparse
import sqlite3
import sys
from typing import Any

from marketing_optimization_cli import (
    cmd_attribution,
    cmd_experiment_analyze,
    cmd_experiment_assignment_register,
    cmd_experiment_decide,
    cmd_experiment_register,
    cmd_init,
    cmd_recommend,
    cmd_report,
    cmd_status,
)
from performance_contract import SOURCE_KINDS, PerformanceContractError
from performance_store import PerformanceStoreError


def _repo_option(parser: argparse.ArgumentParser) -> None:
    """Add the local repository root option."""
    parser.add_argument("--repo", default=".")


def _dry_run_option(parser: argparse.ArgumentParser) -> None:
    """Add the immutable-output suppression option."""
    parser.add_argument("--dry-run", action="store_true")


def _snapshot_options(parser: argparse.ArgumentParser) -> None:
    """Add normalized snapshot or live projection options."""
    parser.add_argument("--input", help="Hermetic normalized snapshot JSON")
    parser.add_argument("--as-of", help="Required UTC boundary for live performance reads")
    parser.add_argument("--source", choices=tuple(sorted(SOURCE_KINDS)))
    _repo_option(parser)


def _attribution_parser(subparsers: Any) -> None:
    """Configure direct and last-touch attribution options."""
    parser = subparsers.add_parser("attribute", help="Build direct or last-touch aggregate attribution")
    _snapshot_options(parser)
    parser.add_argument("--outcome-metric-id", required=True)
    parser.add_argument("--model", choices=("direct", "last_touch"))
    parser.add_argument("--model-version", type=int)
    parser.add_argument("--lookback-seconds", type=int)
    parser.add_argument("--refund-maturity-seconds", type=int)
    parser.add_argument("--minimum-cell-size", type=int)
    parser.add_argument("--include-view-through", action="store_true")
    parser.add_argument("--account-ref")
    parser.add_argument("--campaign-id")
    parser.add_argument("--currency")
    parser.add_argument("--supersedes")
    _dry_run_option(parser)
    parser.set_defaults(handler=cmd_attribution)


def _experiment_parsers(subparsers: Any) -> None:
    """Configure experiment registry, analysis, and decision commands."""
    register = subparsers.add_parser("experiment-register", help="Register one preregistered experiment version")
    register.add_argument("--definition", required=True)
    _repo_option(register)
    _dry_run_option(register)
    register.set_defaults(handler=cmd_experiment_register)

    assignment = subparsers.add_parser(
        "experiment-assignment-register",
        help="Register immutable verified assignment evidence",
    )
    assignment.add_argument("--definition", required=True)
    assignment.add_argument("--assignment-snapshot", required=True)
    _repo_option(assignment)
    _dry_run_option(assignment)
    assignment.set_defaults(handler=cmd_experiment_assignment_register)

    analyze = subparsers.add_parser("experiment-analyze", help="Analyse one preregistered experiment look")
    analyze.add_argument("--definition", required=True)
    analyze.add_argument("--assignment-snapshot")
    analyze.add_argument("--look-number", type=int, required=True)
    analyze.add_argument("--look-type", choices=("interim", "final", "safety"), required=True)
    _snapshot_options(analyze)
    _dry_run_option(analyze)
    analyze.set_defaults(handler=cmd_experiment_analyze)

    decide = subparsers.add_parser("experiment-decide", help="Record an explicit owner decision")
    decide.add_argument("--experiment", required=True)
    decide.add_argument("--decision", required=True)
    _repo_option(decide)
    _dry_run_option(decide)
    decide.set_defaults(handler=cmd_experiment_decide)


def _report_parser(subparsers: Any) -> None:
    """Configure aggregate report generation."""
    parser = subparsers.add_parser("report", help="Build a freshness-aware aggregate report draft")
    _snapshot_options(parser)
    parser.add_argument("--account-ref")
    parser.add_argument("--campaign-id")
    parser.add_argument("--attribution", action="append", default=[])
    parser.add_argument("--experiment", action="append", default=[])
    parser.add_argument("--minimum-cell-size", type=int)
    _dry_run_option(parser)
    parser.set_defaults(handler=cmd_report)


def _recommend_parser(subparsers: Any) -> None:
    """Configure recommendation generation."""
    parser = subparsers.add_parser("recommend", help="Build evidence-ranked approval-bound recommendations")
    parser.add_argument("--report", required=True)
    parser.add_argument("--prior", action="append", default=[])
    _repo_option(parser)
    _dry_run_option(parser)
    parser.set_defaults(handler=cmd_recommend)


def build_parser() -> argparse.ArgumentParser:
    """Build the complete provider-neutral optimization CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    init_parser = subparsers.add_parser("init", help="Provision optimization policy and output paths")
    _repo_option(init_parser)
    init_parser.set_defaults(handler=cmd_init)
    status_parser = subparsers.add_parser("status", help="Show optimization artifact status")
    _repo_option(status_parser)
    status_parser.set_defaults(handler=cmd_status)
    _attribution_parser(subparsers)
    _experiment_parsers(subparsers)
    _report_parser(subparsers)
    _recommend_parser(subparsers)
    return parser


def main(argv: list[str] | None = None) -> int:
    """Dispatch one deterministic optimization operation."""
    args = build_parser().parse_args(argv)
    try:
        return int(args.handler(args))
    except (PerformanceContractError, PerformanceStoreError) as exc:
        print(f"marketing-optimization: {exc}", file=sys.stderr)
        return 1
    except (KeyError, TypeError, ValueError):
        print("marketing-optimization: input shape is invalid", file=sys.stderr)
        return 1
    except (OSError, sqlite3.Error):
        print("marketing-optimization: local storage operation failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
