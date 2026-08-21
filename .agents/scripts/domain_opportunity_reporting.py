#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only, deterministic projections of domain-opportunity evidence."""

from __future__ import annotations

import csv
import io
import json
import os
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from domain_opportunity_contract import SCHEMA_VERSION
from domain_opportunity_store import DomainOpportunityStore

REPORT_VERSION = "domain-opportunity-report-v1"
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


class ReportingError(ValueError):
    """Raised when a report request or local output is unsafe."""


@dataclass(frozen=True)
class ReportOptions:
    """Stable report filters without a wide public function signature."""

    as_of: str | None = None
    active_only: bool = False
    eligible_only: bool = False
    limit: int | None = None


def _parse_time(value: str) -> datetime:
    """Parse one UTC evidence timestamp."""
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, ValueError) as exc:
        raise ReportingError(f"invalid UTC timestamp: {value}") from exc
    if parsed.tzinfo is None:
        raise ReportingError(f"timestamp lacks timezone: {value}")
    return parsed.astimezone(timezone.utc)


def _json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _freshness(observed_at: str | None, as_of: datetime, days: int) -> str:
    if not observed_at:
        return "missing"
    age = (as_of - _parse_time(observed_at)).total_seconds()
    return ("stale", "fresh", "future")[int(age <= days * 86400) + int(age < 0)]


def _latest_score(store: DomainOpportunityStore, listing_id: int) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    score = store.connection.execute(
        """SELECT score_id,model,score_micros,observed_at FROM candidate_scores
           WHERE listing_id=? ORDER BY observed_at DESC,score_id DESC LIMIT 1""", (listing_id,)
    ).fetchone()
    if score is None:
        return None, {}
    components: dict[str, Any] = {}
    for component in store.connection.execute(
        """SELECT name,value_micros,weight_micros,evidence_json FROM score_components
           WHERE score_id=? ORDER BY name""", (score["score_id"],)
    ).fetchall():
        evidence = json.loads(component["evidence_json"] or "null")
        components[component["name"]] = {
            "value_micros": component["value_micros"],
            "weight_micros": component["weight_micros"],
            "source": score["model"],
            "unit": "micros",
            "observed_at": score["observed_at"],
            "evidence": evidence,
        }
    return dict(score), components


def _latest_ads(store: DomainOpportunityStore, listing_id: int) -> dict[str, Any]:
    row = store.connection.execute(
        """SELECT source,value_text,unit,observed_at,source_run_id FROM keyword_metrics
           WHERE listing_id=? AND source='google-ads'
           ORDER BY observed_at DESC,metric_id DESC LIMIT 1""", (listing_id,)
    ).fetchone()
    data = dict(row or {})
    try:
        value = json.loads(data.get("value_text", '{"status":"unavailable"}'))
    except (TypeError, json.JSONDecodeError):
        value = {"status": "invalid"}
    return {**data, "value": value}


def _latest_trends(store: DomainOpportunityStore, listing_id: int) -> dict[str, Any]:
    row = store.connection.execute(
        """SELECT series_id,source,source_run_id,query,geography,timeframe,observed_at
           FROM trend_series WHERE listing_id=?
           ORDER BY observed_at DESC,series_id DESC LIMIT 1""", (listing_id,)
    ).fetchone()
    data = dict(row or {})
    points = store.connection.execute(
        "SELECT point_time,value FROM trend_points WHERE series_id=? ORDER BY point_time", (data.get("series_id"),)
    ).fetchall()
    values = [int(point["value"]) for point in points]
    direction = "unavailable"
    if len(values) >= 2:
        direction = "up" if values[-1] > values[0] else ("down" if values[-1] < values[0] else "flat")
    return {**data, "values": values, "direction": direction}


def _flags(components: dict[str, Any]) -> tuple[list[str], list[str], bool | None]:
    structural = components.get("structural_readability", {}).get("evidence") or {}
    risk = components.get("risk_quality", {}).get("evidence") or {}
    hard_flags = structural.get("hard_filter_flags", [])
    risk_flags = risk.get("flags", [])
    return sorted(set(hard_flags)), sorted(set(risk_flags)), structural.get("eligible")


def _snapshot_as_of(store: DomainOpportunityStore, requested: str | None) -> tuple[str, datetime]:
    if requested:
        parsed = _parse_time(requested)
        return parsed.isoformat().replace("+00:00", "Z"), parsed
    row = store.connection.execute(
        """SELECT MAX(observed_at) FROM (
               SELECT observed_at FROM listing_observations UNION ALL
               SELECT observed_at FROM keyword_metrics UNION ALL
               SELECT observed_at FROM trend_series UNION ALL
               SELECT observed_at FROM candidate_scores
           )"""
    ).fetchone()
    value = row[0] or "1970-01-01T00:00:00Z"
    return value, _parse_time(value)


def _missing_flags(
    score: dict[str, Any] | None, ads_status: str, trends_status: str, currency: str,
) -> list[str]:
    """Describe unavailable evidence without coercing unknown values to zero."""
    flags = {
        "score": score is None,
        "trends_optional": trends_status == "unavailable_optional",
        "price_currency": not currency,
    }
    if ads_status == "unavailable":
        flags["google_ads"] = True
    elif ads_status != "found":
        flags[f"google_ads_{ads_status}"] = True
    return sorted(name for name, present in flags.items() if present)


def build_report(
    store: DomainOpportunityStore, options: ReportOptions | None = None,
) -> dict[str, Any]:
    """Build one joined report inside a consistent SQLite read transaction."""
    options = options or ReportOptions()
    if options.limit is not None and options.limit < 1:
        raise ReportingError("limit must be positive")
    store.connection.execute("BEGIN")
    try:
        as_of_text, as_of_time = _snapshot_as_of(store, options.as_of)
        listings = store.connection.execute(
            """SELECT l.listing_id,l.provider,l.provider_listing_id,l.fqdn,o.status,o.auction_type,
                      o.current_price_micros,o.current_price_currency,o.bid_count,o.end_time,
                      o.observed_at,o.source_run_id
               FROM listings l JOIN listing_observations o ON o.observation_id=l.current_observation_id
               WHERE (?=0 OR o.status='active') ORDER BY l.provider,l.provider_listing_id""",
            (int(options.active_only),),
        ).fetchall()
        candidates: list[dict[str, Any]] = []
        for listing in listings:
            score, components = _latest_score(store, int(listing["listing_id"]))
            ads = _latest_ads(store, int(listing["listing_id"]))
            trends = _latest_trends(store, int(listing["listing_id"]))
            hard_flags, risk_flags, eligible = _flags(components)
            if options.eligible_only and eligible is not True:
                continue
            score_value = score or {}
            ads_value = ads["value"]
            ads_status = ads_value.get("status", "unavailable")
            trends_status = "measured_batch_relative" if trends.get("series_id") else "unavailable_optional"
            trends_values = trends["values"]
            candidate = {
                "domain": listing["fqdn"], "provider": listing["provider"],
                "provider_listing_id": listing["provider_listing_id"], "status": listing["status"],
                "auction_type": listing["auction_type"], "current_price_micros": listing["current_price_micros"],
                "current_price_currency": listing["current_price_currency"], "bid_count": listing["bid_count"],
                "deadline": listing["end_time"], "listing_observed_at": listing["observed_at"],
                "listing_source": listing["provider"], "listing_unit": "currency_micros",
                "listing_freshness": _freshness(listing["observed_at"], as_of_time, 7),
                "policy_version": score_value.get("model"),
                "score_micros": score_value.get("score_micros"),
                "score_source": score_value.get("model"),
                "score_unit": {True: "micros"}.get(score is not None),
                "score_observed_at": score_value.get("observed_at"),
                "score_freshness": _freshness(score_value.get("observed_at"), as_of_time, 35),
                "eligible": eligible, "score_components": components,
                "google_ads": {
                    "status": ads_status, "metrics": ads_value.get("metrics"),
                    "source": ads_value.get("metric_source"),
                    "unit": {"found": "provider_metric_bundle"}.get(ads_status),
                    "observed_at": ads.get("observed_at"),
                    "locale": {key: ads_value.get(key) for key in ("language", "geographies", "network", "account_currency") if key in ads_value},
                    "retrieval_month": ads_value.get("retrieval_month"),
                    "freshness": _freshness(ads.get("observed_at"), as_of_time, 35),
                },
                "trends": {
                    "status": trends_status,
                    "batch_id": trends.get("source_run_id"),
                    "query": trends.get("query"), "geography": trends.get("geography"),
                    "timeframe": trends.get("timeframe"), "direction": trends.get("direction"),
                    "minimum": min(trends_values, default=None),
                    "maximum": max(trends_values, default=None),
                    "source": trends.get("source"),
                    "unit": {"measured_batch_relative": "batch_relative_index_0_100"}.get(trends_status),
                    "observed_at": trends.get("observed_at"),
                    "freshness": _freshness(trends.get("observed_at"), as_of_time, 14),
                },
                "missing_flags": _missing_flags(
                    score, ads_status, trends_status, listing["current_price_currency"],
                ),
                "risk_flags": sorted(set(hard_flags + risk_flags)),
            }
            candidates.append(candidate)
        candidates.sort(key=lambda item: (
            item["score_micros"] is None, -(item["score_micros"] or 0),
            item["domain"], item["provider"], item["provider_listing_id"],
        ))
        if options.limit is not None:
            candidates = candidates[:options.limit]
        for rank, candidate in enumerate(candidates, 1):
            candidate["rank"] = rank
        return {
            "report_version": REPORT_VERSION, "schema_version": SCHEMA_VERSION,
            "as_of": as_of_text, "candidate_count": len(candidates), "candidates": candidates,
        }
    finally:
        store.connection.rollback()


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


def _render_csv(report: dict[str, Any]) -> str:
    target = io.StringIO(newline="")
    writer = csv.DictWriter(target, fieldnames=CSV_COLUMNS, lineterminator="\n")
    writer.writeheader()
    writer.writerows(_csv_row(item) for item in report["candidates"])
    return target.getvalue()


def _render_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# Domain opportunity report", "", f"As of: `{report['as_of']}`  ",
        "Policy evidence: persisted version per candidate  ", "Trends values are batch-relative, not absolute demand.", "",
        "| Rank | Domain | Score | Policy | Price | Deadline | Missing | Risk |", "|---:|---|---:|---|---:|---|---|---|",
    ]
    for item in report["candidates"]:
        score = {None: "unknown"}.get(item["score_micros"], str(item["score_micros"]))
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
    renderers = {
        "csv": _render_csv,
        "json": lambda value: _json(value) + "\n",
        "markdown": _render_markdown,
    }
    try:
        renderer = renderers[output_format]
    except KeyError as exc:
        raise ReportingError("format must be csv, json, or markdown") from exc
    return renderer(report)


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


def pipeline_status(store: DomainOpportunityStore) -> dict[str, Any]:
    """Expose explicit non-fatal readiness for each optional evidence stage."""
    status = store.status()
    counts = status["counts"]
    status["stages"] = {
        name: "ready" if counts[count_name] else missing
        for name, count_name, missing in (
            ("inventory", "listings", "missing"),
            ("scoring", "candidate_scores", "missing_non_fatal"),
            ("google_ads", "keyword_metrics", "missing_non_fatal"),
            ("trends", "trend_series", "missing_optional"),
        )
    }
    return status
