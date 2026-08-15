#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic privacy-safe marketing attribution and experiment analysis."""

from __future__ import annotations

import argparse
import json
from typing import Any

from marketing_optimization_attribution import AttributionOptions
from marketing_optimization_attribution import attribute as _attribute
from marketing_optimization_common import OptimizationError
from marketing_optimization_common import load_document as _load
from marketing_optimization_common import write_document as _write
from marketing_optimization_experiment import analyze_experiment
from marketing_optimization_reporting import RecommendationOptions, build_report
from marketing_optimization_reporting import recommend as _recommend
from marketing_optimization_reporting import status


def attribute(document: dict[str, Any], *args: Any, **kwargs: Any) -> dict[str, Any]:
    """Preserve the helper API while grouping versioned run options."""
    names = ("model", "window_days", "model_version", "window_version", "run_id", "generated_at")
    values = dict(zip(names, args, strict=False))
    values.update(kwargs)
    return _attribute(document, AttributionOptions(**values))


def recommend(document: dict[str, Any], *args: Any, **kwargs: Any) -> dict[str, Any]:
    """Preserve the helper API while grouping recommendation governance."""
    names = ("owner", "approval", "rollback", "retest_at", "created_at")
    values = dict(zip(names, args, strict=False))
    values.update(kwargs)
    return _recommend(document, RecommendationOptions(**values))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    attribute_parser = subparsers.add_parser("attribute", help="Build a versioned attribution projection")
    attribute_parser.add_argument("--input", required=True)
    attribute_parser.add_argument("--output")
    attribute_parser.add_argument("--model", choices=("direct", "last_touch"), default="last_touch")
    attribute_parser.add_argument("--window-days", type=int, default=30)
    attribute_parser.add_argument("--model-version", type=int, default=1)
    attribute_parser.add_argument("--window-version", type=int, default=1)
    attribute_parser.add_argument("--run-id", required=True)
    attribute_parser.add_argument("--generated-at", required=True)

    experiment_parser = subparsers.add_parser("experiment", help="Analyze a preregistered aggregate experiment")
    experiment_parser.add_argument("--input", required=True)
    experiment_parser.add_argument("--output")
    experiment_parser.add_argument("--run-id", required=True)
    experiment_parser.add_argument("--observed-at", required=True)

    report_parser = subparsers.add_parser("report", help="Build a freshness-aware aggregate report")
    report_parser.add_argument("--input", required=True)
    report_parser.add_argument("--output")
    report_parser.add_argument("--minimum-cohort", type=int, default=10)
    report_parser.add_argument("--stale-after-hours", type=int, default=48)
    report_parser.add_argument("--generated-at", required=True)

    recommend_parser = subparsers.add_parser("recommend", help="Create an approval-bound recommendation")
    recommend_parser.add_argument("--input", required=True)
    recommend_parser.add_argument("--output")
    recommend_parser.add_argument("--owner", choices=("content", "marketing", "product", "sales", "seo", "campaign-owner", "report-owner"), required=True)
    recommend_parser.add_argument("--approval", required=True)
    recommend_parser.add_argument("--rollback", required=True)
    recommend_parser.add_argument("--retest-at", required=True)
    recommend_parser.add_argument("--created-at", required=True)

    status_parser = subparsers.add_parser("status", help="Check projection or report freshness")
    status_parser.add_argument("--input", required=True)
    status_parser.add_argument("--output")
    status_parser.add_argument("--now", required=True)
    status_parser.add_argument("--stale-after-hours", type=int, default=48)
    return parser


def _run(args: argparse.Namespace, document: dict[str, Any]) -> dict[str, Any]:
    if args.command == "attribute":
        return attribute(document, args.model, args.window_days, args.model_version, args.window_version, args.run_id, args.generated_at)
    if args.command == "experiment":
        return analyze_experiment(document, args.run_id, args.observed_at)
    if args.command == "report":
        return build_report(document, args.minimum_cohort, args.stale_after_hours, args.generated_at)
    if args.command == "recommend":
        return recommend(document, args.owner, args.approval, args.rollback, args.retest_at, args.created_at)
    return status(document, args.now, args.stale_after_hours)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        _write(_run(args, _load(args.input)), args.output)
    except (OSError, json.JSONDecodeError, OptimizationError, KeyError, TypeError, ValueError) as exc:
        print(json.dumps({"schema": "aidevops.marketing-optimization-error/v1", "error": str(exc)}))
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
