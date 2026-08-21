#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Stable renderers and atomic publication for domain-opportunity reports."""

from __future__ import annotations

import csv
import io
import json
import os
import tempfile
from pathlib import Path
from typing import Any

from domain_opportunity_reporting import ReportingError

CSV_COLUMNS = (
    "rank", "domain", "provider", "provider_listing_id", "status", "auction_type",
    "current_price_micros", "current_price_currency", "bid_count", "deadline",
    "listing_observed_at", "listing_source", "listing_unit", "listing_freshness",
    "policy_version", "score_micros", "score_source", "score_unit", "score_observed_at", "score_freshness", "eligible",
    "score_components_json", "google_ads_status", "google_ads_metrics_json",
    "google_ads_source", "google_ads_unit", "google_ads_observed_at",
    "google_ads_locale_json", "google_ads_retrieval_month", "google_ads_freshness",
    "trends_status", "trends_batch_id", "trends_query", "trends_geography",
    "trends_timeframe", "trends_direction", "trends_min", "trends_max",
    "trends_source", "trends_unit", "trends_observed_at", "trends_freshness",
    "missing_flags", "risk_flags",
)


def _json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _csv_row(item: dict[str, Any]) -> dict[str, Any]:
    ads, trends = item["google_ads"], item["trends"]
    row = {key: item.get(key) for key in CSV_COLUMNS}
    row.update({
        "score_components_json": _json(item["score_components"]),
        "google_ads_status": ads["status"], "google_ads_metrics_json": _json(ads["metrics"]),
        "google_ads_source": ads["source"], "google_ads_unit": ads["unit"],
        "google_ads_observed_at": ads["observed_at"], "google_ads_locale_json": _json(ads["locale"]),
        "google_ads_retrieval_month": ads["retrieval_month"], "google_ads_freshness": ads["freshness"],
        "trends_status": trends["status"], "trends_batch_id": trends["batch_id"],
        "trends_query": trends["query"], "trends_geography": trends["geography"],
        "trends_timeframe": trends["timeframe"], "trends_direction": trends["direction"],
        "trends_min": trends["minimum"], "trends_max": trends["maximum"],
        "trends_source": trends["source"], "trends_unit": trends["unit"],
        "trends_observed_at": trends["observed_at"], "trends_freshness": trends["freshness"],
        "missing_flags": ";".join(item["missing_flags"]), "risk_flags": ";".join(item["risk_flags"]),
    })
    return row


def _markdown(report: dict[str, Any]) -> str:
    lines = [
        "# Domain opportunity report", "", f"As of: `{report['as_of']}`  ",
        "Policy evidence: persisted version per candidate  ",
        "Trends values are batch-relative, not absolute demand.", "",
        "| Rank | Domain | Score | Policy | Price | Deadline | Missing | Risk |",
        "|---:|---|---:|---|---:|---|---|---|",
    ]
    for item in report["candidates"]:
        score = "unknown" if item["score_micros"] is None else str(item["score_micros"])
        price = f"{item['current_price_micros']} {item['current_price_currency']} micros"
        lines.append(
            f"| {item['rank']} | {item['domain']} | {score} | {item['policy_version'] or 'unknown'} | "
            f"{price} | {item['deadline']} | {', '.join(item['missing_flags']) or 'none'} | "
            f"{', '.join(item['risk_flags']) or 'none'} |"
        )
    lines.extend(["", "## Evidence packet", "", "```json", _json(report["candidates"]), "```", ""])
    return "\n".join(lines)


def render(report: dict[str, Any], output_format: str) -> str:
    """Render stable CSV, JSON, or concise Markdown."""
    if output_format == "json":
        return _json(report) + "\n"
    if output_format == "markdown":
        return _markdown(report)
    if output_format != "csv":
        raise ReportingError("format must be csv, json, or markdown")
    target = io.StringIO(newline="")
    writer = csv.DictWriter(target, fieldnames=CSV_COLUMNS, lineterminator="\n")
    writer.writeheader()
    writer.writerows(_csv_row(item) for item in report["candidates"])
    return target.getvalue()


def publish(output: str, content: str) -> None:
    """Publish atomically without replacing through a symlink."""
    destination = Path(output).expanduser().absolute()
    if destination.is_symlink():
        raise ReportingError("output must not be a symbolic link")
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
