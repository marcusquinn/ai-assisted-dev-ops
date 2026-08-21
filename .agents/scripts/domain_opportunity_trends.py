#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Hermetic parser and persistence adapter for manual Google Trends CSV exports."""
from __future__ import annotations

import csv
import hashlib
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from domain_opportunity_contract import TrendSeries, canonical_json
from domain_opportunity_store import DomainOpportunityStore

PARSER_PROFILE = "google-trends-interest-over-time-v1"


class TrendsError(ValueError):
    """Raised for a malformed, mismatched, or unsafe Trends import."""


@dataclass(frozen=True)
class ParsedTrend:
    term: dict[str, Any]
    points: tuple[tuple[str, int], ...]
    partial_points: tuple[str, ...]


def load_manifest(path: str | Path) -> dict[str, Any]:
    """Load and validate the manifest required to interpret an export."""
    try:
        manifest = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise TrendsError("manifest must be readable JSON") from exc
    required = {"schema_version", "batch_id", "terms", "geography", "timeframe", "timezone", "granularity", "search_property", "category", "language", "share_url", "exported_at", "expected_filename"}
    if not isinstance(manifest, dict) or required - set(manifest):
        raise TrendsError("manifest omits required comparison metadata")
    terms = manifest["terms"]
    if manifest["schema_version"] != 1 or not isinstance(terms, list) or not 1 <= len(terms) <= 5:
        raise TrendsError("manifest must contain one to five ordered terms")
    for position, term in enumerate(terms):
        if not isinstance(term, dict) or term.get("position") != position:
            raise TrendsError("manifest terms must retain consecutive positions")
        if not all(isinstance(term.get(key), str) and term[key] for key in ("term", "identity_type", "provider", "provider_listing_id")):
            raise TrendsError("manifest term lacks listing identity")
    return manifest


def _point_time(value: str) -> str:
    for pattern in ("%Y-%m-%d", "%Y-%m", "%Y"):
        try:
            return datetime.strptime(value.strip(), pattern).replace(tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")
        except ValueError:
            pass
    raise TrendsError("CSV date is not an accepted Trends period")


def inspect_export(manifest: dict[str, Any], path: str | Path) -> tuple[str, tuple[ParsedTrend, ...]]:
    """Validate a downloaded CSV without mutating any database."""
    raw = Path(path).read_bytes()
    rows = list(csv.reader(raw.decode("utf-8-sig").splitlines()))
    header_index = next((i for i, row in enumerate(rows) if row and row[0].strip().lower() in {"day", "week", "month", "date"}), None)
    if header_index is None:
        raise TrendsError("CSV has no Interest-over-time header")
    header = rows[header_index]
    labels = [column.split(":", 1)[0].strip() for column in header[1:]]
    expected = [term["term"] for term in manifest["terms"]]
    if labels != expected:
        raise TrendsError("CSV terms or order do not match manifest")
    values: list[list[tuple[str, int]]] = [[] for _ in expected]
    partials: list[list[str]] = [[] for _ in expected]
    for row in rows[header_index + 1 :]:
        if not row or not row[0].strip():
            continue
        if len(row) != len(header):
            raise TrendsError("CSV row has an unexpected column count")
        point_time = _point_time(row[0])
        for index, raw_value in enumerate(row[1:]):
            text = raw_value.strip()
            if text == "<1":
                value = 0
                partials[index].append(point_time)
            elif text.isdigit() and 0 <= int(text) <= 100:
                value = int(text)
            else:
                raise TrendsError("CSV interest values must be 0-100 or <1")
            values[index].append((point_time, value))
    if not all(values):
        raise TrendsError("CSV has no trend points")
    return hashlib.sha256(raw).hexdigest(), tuple(ParsedTrend(manifest["terms"][i], tuple(points), tuple(partials[i])) for i, points in enumerate(values))


def import_export(manifest: dict[str, Any], path: str | Path, database: str | Path) -> dict[str, Any]:
    """Persist one validated batch with its complete provenance envelope."""
    raw_hash, parsed = inspect_export(manifest, path)
    db_path = Path(database).expanduser()
    with DomainOpportunityStore(db_path, initialize=not db_path.exists()) as store:
        with store.transaction():
            run_id = f"google-trends:{manifest['batch_id']}:{raw_hash[:12]}"
            store.begin_source_run(run_id, "google-trends", started_at=manifest["exported_at"])
            imported = 0
            for item in parsed:
                provenance = {key: manifest[key] for key in ("batch_id", "geography", "timeframe", "timezone", "granularity", "search_property", "category", "language", "share_url", "exported_at", "expected_filename")}
                provenance.update({"parser_profile": PARSER_PROFILE, "term_order": item.term["position"], "identity_type": item.term["identity_type"], "partial_points": item.partial_points})
                series = TrendSeries(item.term["provider"], item.term["provider_listing_id"], run_id, "google-trends:" + canonical_json(provenance), item.term["term"], manifest["geography"], manifest["timeframe"], manifest["exported_at"], item.points, raw_hash)
                store.insert_trend_series(series)
                imported += 1
            store.complete_source_run(run_id, imported)
    return {"batch_id": manifest["batch_id"], "raw_hash": raw_hash, "imported": len(parsed), "parser_profile": PARSER_PROFILE}
