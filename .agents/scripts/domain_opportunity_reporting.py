#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only, deterministic projections of domain-opportunity evidence."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from domain_opportunity_contract import SCHEMA_VERSION
from domain_opportunity_store import DomainOpportunityStore

REPORT_VERSION = "domain-opportunity-report-v1"
class ReportingError(ValueError):
    """Raised when a report request or local output is unsafe."""


def _parse_time(value: str) -> datetime:
    """Parse one UTC evidence timestamp."""
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, ValueError) as exc:
        raise ReportingError(f"invalid UTC timestamp: {value}") from exc
    if parsed.tzinfo is None:
        raise ReportingError(f"timestamp lacks timezone: {value}")
    return parsed.astimezone(timezone.utc)


@dataclass(frozen=True)
class ReportOptions:
    """Stable report filters collected without a wide function signature."""

    as_of: str | None = None
    active_only: bool = False
    eligible_only: bool = False
    limit: int | None = None


def _freshness(observed_at: str | None, as_of: datetime, days: int) -> str:
    if not observed_at:
        return "missing"
    age = (as_of - _parse_time(observed_at)).total_seconds()
    return "future" if age < 0 else ("fresh" if age <= days * 86400 else "stale")


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
        evidence = json.loads(component["evidence_json"]) if component["evidence_json"] else None
        components[component["name"]] = {
            "value_micros": component["value_micros"],
            "weight_micros": component["weight_micros"],
            "source": score["model"],
            "unit": "micros",
            "observed_at": score["observed_at"],
            "evidence": evidence,
        }
    return dict(score), components


def _latest_ads(store: DomainOpportunityStore, listing_id: int) -> dict[str, Any] | None:
    row = store.connection.execute(
        """SELECT source,value_text,unit,observed_at,source_run_id FROM keyword_metrics
           WHERE listing_id=? AND source='google-ads'
           ORDER BY observed_at DESC,metric_id DESC LIMIT 1""", (listing_id,)
    ).fetchone()
    if row is None:
        return None
    try:
        value = json.loads(row["value_text"])
    except (TypeError, json.JSONDecodeError):
        value = {"status": "invalid"}
    return {**dict(row), "value": value}


def _latest_trends(store: DomainOpportunityStore, listing_id: int) -> dict[str, Any] | None:
    row = store.connection.execute(
        """SELECT series_id,source,source_run_id,query,geography,timeframe,observed_at
           FROM trend_series WHERE listing_id=?
           ORDER BY observed_at DESC,series_id DESC LIMIT 1""", (listing_id,)
    ).fetchone()
    if row is None:
        return None
    points = store.connection.execute(
        "SELECT point_time,value FROM trend_points WHERE series_id=? ORDER BY point_time", (row["series_id"],)
    ).fetchall()
    values = [int(point["value"]) for point in points]
    direction = "unavailable"
    if len(values) >= 2:
        direction = "up" if values[-1] > values[0] else ("down" if values[-1] < values[0] else "flat")
    return {**dict(row), "values": values, "direction": direction}


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
    timestamps = [
        row[0] for query in (
            "SELECT MAX(observed_at) FROM listing_observations",
            "SELECT MAX(observed_at) FROM keyword_metrics",
            "SELECT MAX(observed_at) FROM trend_series",
            "SELECT MAX(observed_at) FROM candidate_scores",
        ) if (row := store.connection.execute(query).fetchone()) and row[0]
    ]
    value = max(timestamps) if timestamps else "1970-01-01T00:00:00Z"
    return value, _parse_time(value)


def _ads_projection(ads: dict[str, Any] | None, as_of: datetime) -> dict[str, Any]:
    value = ads["value"] if ads else {}
    return {
        "status": value.get("status", "unavailable"), "metrics": value.get("metrics"),
        "source": value.get("metric_source") if ads else None,
        "unit": "provider_metric_bundle" if ads else None,
        "observed_at": ads["observed_at"] if ads else None,
        "locale": {key: value.get(key) for key in ("language", "geographies", "network", "account_currency") if key in value},
        "retrieval_month": value.get("retrieval_month"),
        "freshness": _freshness(ads["observed_at"] if ads else None, as_of, 35),
    }


def _trends_projection(trends: dict[str, Any] | None, as_of: datetime) -> dict[str, Any]:
    values = trends["values"] if trends else []
    return {
        "status": "measured_batch_relative" if trends else "unavailable_optional",
        "batch_id": trends["source_run_id"] if trends else None,
        "query": trends["query"] if trends else None, "geography": trends["geography"] if trends else None,
        "timeframe": trends["timeframe"] if trends else None, "direction": trends["direction"] if trends else None,
        "minimum": min(values) if values else None, "maximum": max(values) if values else None,
        "source": trends["source"] if trends else None,
        "unit": "batch_relative_index_0_100" if trends else None,
        "observed_at": trends["observed_at"] if trends else None,
        "freshness": _freshness(trends["observed_at"] if trends else None, as_of, 14),
    }


def _missing_flags(score: dict[str, Any] | None, ads: dict[str, Any], trends: dict[str, Any], currency: str) -> list[str]:
    flags = []
    if score is None:
        flags.append("score")
    if ads["status"] == "unavailable":
        flags.append("google_ads")
    elif ads["status"] != "found":
        flags.append(f"google_ads_{ads['status']}")
    if trends["status"] == "unavailable_optional":
        flags.append("trends_optional")
    if not currency:
        flags.append("price_currency")
    return sorted(flags)


def _candidate(store: DomainOpportunityStore, listing: Any, as_of: datetime) -> dict[str, Any]:
    listing_id = int(listing["listing_id"])
    score, components = _latest_score(store, listing_id)
    ads = _ads_projection(_latest_ads(store, listing_id), as_of)
    trends = _trends_projection(_latest_trends(store, listing_id), as_of)
    hard_flags, risk_flags, eligible = _flags(components)
    currency = listing["current_price_currency"]
    return {
        "domain": listing["fqdn"], "provider": listing["provider"],
        "provider_listing_id": listing["provider_listing_id"], "status": listing["status"],
        "auction_type": listing["auction_type"], "current_price_micros": listing["current_price_micros"],
        "current_price_currency": currency, "bid_count": listing["bid_count"],
        "deadline": listing["end_time"], "listing_observed_at": listing["observed_at"],
        "listing_source": listing["provider"], "listing_unit": "currency_micros",
        "listing_freshness": _freshness(listing["observed_at"], as_of, 7),
        "policy_version": score["model"] if score else None,
        "score_micros": score["score_micros"] if score else None,
        "score_source": score["model"] if score else None, "score_unit": "micros" if score else None,
        "score_observed_at": score["observed_at"] if score else None,
        "score_freshness": _freshness(score["observed_at"] if score else None, as_of, 35),
        "eligible": eligible, "score_components": components, "google_ads": ads, "trends": trends,
        "missing_flags": _missing_flags(score, ads, trends, currency),
        "risk_flags": sorted(set(hard_flags + risk_flags)),
    }


def build_report(store: DomainOpportunityStore, options: ReportOptions | None = None) -> dict[str, Any]:
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
        candidates = [_candidate(store, listing, as_of_time) for listing in listings]
        if options.eligible_only:
            candidates = [candidate for candidate in candidates if candidate["eligible"] is True]
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


def pipeline_status(store: DomainOpportunityStore) -> dict[str, Any]:
    """Expose explicit non-fatal readiness for each optional evidence stage."""
    status = store.status()
    counts = status["counts"]
    status["stages"] = {
        "inventory": "ready" if counts["listings"] else "missing",
        "scoring": "ready" if counts["candidate_scores"] else "missing_non_fatal",
        "google_ads": "ready" if counts["keyword_metrics"] else "missing_non_fatal",
        "trends": "ready" if counts["trend_series"] else "missing_optional",
    }
    return status
