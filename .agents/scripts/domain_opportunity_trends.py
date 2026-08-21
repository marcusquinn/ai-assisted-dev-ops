#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Hermetic parser and persistence adapter for manual Google Trends CSV exports."""
from __future__ import annotations

import csv
import hashlib
import json
import os
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from domain_opportunity_contract import TrendSeries, canonical_json
from domain_opportunity_store import DomainOpportunityStore

PARSER_PROFILE = "google-trends-interest-over-time-v1"
MANIFEST_VERSION = 1
MAX_COMPARISON_TERMS = 5


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
    required = {
        "schema_version", "batch_id", "terms", "geography", "timeframe", "timezone",
        "granularity", "search_property", "category", "language", "share_url", "exported_at",
        "expected_filename",
    }
    if not isinstance(manifest, dict) or required - set(manifest):
        raise TrendsError("manifest omits required comparison metadata")
    terms = manifest["terms"]
    if manifest["schema_version"] != MANIFEST_VERSION or not isinstance(terms, list) or not 1 <= len(terms) <= MAX_COMPARISON_TERMS:
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


def _timeframe_bounds(timeframe: str) -> tuple[str, str] | None:
    """Return ISO date bounds when a manifest uses the documented explicit range."""
    parts = timeframe.split()
    if len(parts) != 2:
        return None
    try:
        start = datetime.strptime(parts[0], "%Y-%m-%d").date().isoformat()
        end = datetime.strptime(parts[1], "%Y-%m-%d").date().isoformat()
    except ValueError:
        return None
    if end < start:
        raise TrendsError("manifest timeframe ends before it starts")
    return start, end


def _read_export(path: str | Path) -> tuple[bytes, list[list[str]], int]:
    """Read an export and locate its documented Interest-over-time header."""
    raw = Path(path).read_bytes()
    rows = list(csv.reader(raw.decode("utf-8-sig").splitlines()))
    header_index = next(
        (index for index, row in enumerate(rows) if row and row[0].strip().lower() in {"day", "week", "month", "date"}),
        None,
    )
    if header_index is None:
        raise TrendsError("CSV has no Interest-over-time header")
    return raw, rows, header_index


def _validate_period(point_time: str, seen_times: set[str], bounds: tuple[str, str] | None) -> None:
    """Reject repeated or manifest-incompatible periods before persistence."""
    if point_time in seen_times:
        raise TrendsError("CSV repeats a trend period")
    if bounds and not bounds[0] <= point_time[:10] <= bounds[1]:
        raise TrendsError("CSV periods fall outside the manifest timeframe")
    seen_times.add(point_time)


def _value_and_partial(raw_value: str, point_time: str) -> tuple[int, str | None]:
    """Preserve a relative <1 marker separately from a numeric zero."""
    text = raw_value.strip()
    if text == "<1":
        return 0, point_time
    if text.isdigit() and 0 <= int(text) <= 100:
        return int(text), None
    raise TrendsError("CSV interest values must be 0-100 or <1")


def _append_row(row: list[str], point_time: str, values: list[list[tuple[str, int]]], partials: list[list[str]]) -> None:
    """Append one valid comparison period to its respective term series."""
    for index, raw_value in enumerate(row[1:]):
        value, partial = _value_and_partial(raw_value, point_time)
        values[index].append((point_time, value))
        if partial is not None:
            partials[index].append(partial)


def _parse_values(rows: list[list[str]], header_index: int, manifest: dict[str, Any]) -> tuple[ParsedTrend, ...]:
    """Normalize one manifest-matched comparison without treating <1 as zero."""
    header = rows[header_index]
    labels = [column.split(":", 1)[0].strip() for column in header[1:]]
    expected = [term["term"] for term in manifest["terms"]]
    if labels != expected:
        raise TrendsError("CSV terms or order do not match manifest")
    values: list[list[tuple[str, int]]] = [[] for _ in expected]
    partials: list[list[str]] = [[] for _ in expected]
    seen_times: set[str] = set()
    bounds = _timeframe_bounds(manifest["timeframe"])
    for row in rows[header_index + 1 :]:
        if not row or not row[0].strip():
            continue
        if len(row) != len(header):
            raise TrendsError("CSV row has an unexpected column count")
        point_time = _point_time(row[0])
        _validate_period(point_time, seen_times, bounds)
        _append_row(row, point_time, values, partials)
    if not all(values):
        raise TrendsError("CSV has no trend points")
    return tuple(
        ParsedTrend(manifest["terms"][index], tuple(points), tuple(partials[index]))
        for index, points in enumerate(values)
    )


def inspect_export(manifest: dict[str, Any], path: str | Path) -> tuple[str, tuple[ParsedTrend, ...]]:
    """Validate a downloaded CSV without mutating any database."""
    raw, rows, header_index = _read_export(path)
    return hashlib.sha256(raw).hexdigest(), _parse_values(rows, header_index, manifest)


def _manifest_term(listing: dict[str, Any], position: int) -> dict[str, Any]:
    """Map a known listing to the ordered manual-search comparison identity."""
    return {
        "term": listing["sld"], "identity_type": "search_term", "provider": listing["provider"],
        "provider_listing_id": listing["provider_listing_id"], "position": position,
    }


def queue_manifests(database: str | Path, output: str | Path) -> list[Path]:
    """Write bounded, operator-completed manifests without opening or controlling a browser."""
    destination = Path(output).expanduser()
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    with DomainOpportunityStore(database) as store:
        candidates = [
            item for item in store.current_listings(active_only=True)
            if store.connection.execute(
                "SELECT 1 FROM trend_series WHERE listing_id=(SELECT listing_id FROM listings WHERE provider=? AND provider_listing_id=?) AND source LIKE 'google-trends:%' LIMIT 1",
                (item["provider"], item["provider_listing_id"]),
            ).fetchone() is None
        ]
    created: list[Path] = []
    for batch_number, start in enumerate(range(0, len(candidates), MAX_COMPARISON_TERMS), start=1):
        terms = candidates[start : start + MAX_COMPARISON_TERMS]
        manifest = {
            "schema_version": MANIFEST_VERSION, "batch_id": f"trends-{batch_number:04d}",
            "terms": [_manifest_term(item, index) for index, item in enumerate(terms)],
            "geography": "Worldwide", "timeframe": "today 5-y", "timezone": "UTC",
            "granularity": "month", "search_property": "web", "category": "0", "language": "en",
            "share_url": "", "exported_at": "", "expected_filename": "multiTimeline.csv",
        }
        path = destination / f"{manifest['batch_id']}.json"
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=destination)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(manifest, handle, sort_keys=True, separators=(",", ":"))
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary_name, 0o600)
            os.replace(temporary_name, path)
        except Exception:
            os.unlink(temporary_name)
            raise
        created.append(path)
    return created


def _bootstrap_listings(store: DomainOpportunityStore, manifest: dict[str, Any], parsed: tuple[ParsedTrend, ...]) -> None:
    """Create fixture-compatible listing identities only for a brand-new store."""
    listings_run = f"google-trends-listings:{manifest['batch_id']}"
    providers = {item.term["provider"] for item in parsed}
    if len(providers) != 1 or any("listing" not in item.term for item in parsed):
        raise TrendsError("a new database requires manifest listing observations")
    store.begin_source_run(listings_run, providers.pop(), started_at=manifest["exported_at"])
    for item in parsed:
        listing = dict(item.term["listing"])
        listing["source_run_id"] = listings_run
        store.upsert_listing_observation(listing)
    store.complete_source_run(listings_run, len(parsed))


def _series_provenance(manifest: dict[str, Any], item: ParsedTrend) -> str:
    """Serialize comparison context so batch-relative values remain interpretable."""
    keys = (
        "batch_id", "geography", "timeframe", "timezone", "granularity", "search_property",
        "category", "language", "share_url", "exported_at", "expected_filename",
    )
    provenance = {key: manifest[key] for key in keys}
    provenance.update({
        "parser_profile": PARSER_PROFILE, "term_order": item.term["position"],
        "identity_type": item.term["identity_type"], "partial_points": item.partial_points,
    })
    return "google-trends:" + canonical_json(provenance)


def _store_parsed_series(store: DomainOpportunityStore, manifest: dict[str, Any], raw_hash: str, parsed: tuple[ParsedTrend, ...]) -> int:
    """Write the manifest-bound series under an idempotent raw-export source run."""
    run_id = f"google-trends:{manifest['batch_id']}:{raw_hash[:12]}"
    store.begin_source_run(run_id, "google-trends", started_at=manifest["exported_at"])
    for item in parsed:
        series = TrendSeries(
            item.term["provider"], item.term["provider_listing_id"], run_id,
            _series_provenance(manifest, item), item.term["term"], manifest["geography"],
            manifest["timeframe"], manifest["exported_at"], item.points, raw_hash,
        )
        store.insert_trend_series(series)
    store.complete_source_run(run_id, len(parsed))
    return len(parsed)


def import_export(manifest: dict[str, Any], path: str | Path, database: str | Path) -> dict[str, Any]:
    """Persist one validated batch with its complete provenance envelope."""
    raw_hash, parsed = inspect_export(manifest, path)
    db_path = Path(database).expanduser()
    initializing = not db_path.exists()
    with DomainOpportunityStore(db_path, initialize=initializing) as store:
        with store.transaction():
            if initializing:
                _bootstrap_listings(store, manifest, parsed)
            imported = _store_parsed_series(store, manifest, raw_hash, parsed)
    return {"batch_id": manifest["batch_id"], "raw_hash": raw_hash, "imported": len(parsed), "parser_profile": PARSER_PROFILE}
