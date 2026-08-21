#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Versioned SQLite persistence for local domain-opportunity evidence."""

from __future__ import annotations

import csv
import os
import sqlite3
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator, Mapping

from domain_opportunity_contract import (
    CSV_COLUMNS,
    SCHEMA_VERSION,
    CandidateScore,
    DomainOpportunityContractError,
    KeywordMetric,
    TrendSeries,
    canonical_json,
    content_hash,
    money_micros,
    normalize_listing,
    utc_now,
    utc_timestamp,
)

DEFAULT_ROOT = Path.home() / ".aidevops" / ".agent-workspace" / "work" / "domain-opportunities"
DEFAULT_DATABASE = DEFAULT_ROOT / "opportunities.sqlite"


class DomainOpportunityStoreError(RuntimeError):
    """Raised when the local evidence store cannot satisfy its contract."""


def _safe_path(path: str | os.PathLike[str] | None, default: Path) -> Path:
    candidate = Path(path).expanduser() if path is not None else default
    if not candidate.name or candidate.name in {".", ".."}:
        raise DomainOpportunityStoreError("local storage path must name a file")
    absolute = candidate.absolute()
    if absolute.exists() and absolute.is_symlink():
        raise DomainOpportunityStoreError("local storage path must not be a symbolic link")
    probe = absolute
    while probe != probe.parent and not probe.exists():
        probe = probe.parent
    if probe.is_symlink():
        raise DomainOpportunityStoreError("local storage parent must not be a symbolic link")
    return probe.resolve(strict=True).joinpath(absolute.relative_to(probe))


class DomainOpportunityStore:
    """Own all mutations of one compatible domain-opportunity database."""

    def __init__(self, path: str | os.PathLike[str] | None = None, *, initialize: bool = False) -> None:
        self.path = _safe_path(path, DEFAULT_DATABASE)
        existed = self.path.exists()
        existing_size = self.path.stat().st_size if existed else 0
        if not existed and not initialize:
            raise DomainOpportunityStoreError("domain opportunity store does not exist; run init first")
        if initialize:
            self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            self.connection = sqlite3.connect(self.path, timeout=5.0)
            self.connection.row_factory = sqlite3.Row
            version = int(self.connection.execute("PRAGMA user_version").fetchone()[0])
            if version > SCHEMA_VERSION:
                raise DomainOpportunityStoreError("domain opportunity store schema is newer than this runtime")
            if version == 0:
                if not initialize or (existed and existing_size > 0):
                    raise DomainOpportunityStoreError("domain opportunity store is uninitialized or incompatible")
                self._configure()
                self._create_schema_v1()
            elif version != SCHEMA_VERSION:
                raise DomainOpportunityStoreError("unsupported domain opportunity store migration path")
            else:
                self._configure()
            os.chmod(self.path, 0o600)
        except Exception:
            if hasattr(self, "connection"):
                self.connection.close()
            raise

    def _configure(self) -> None:
        self.connection.execute("PRAGMA foreign_keys=ON")
        self.connection.execute("PRAGMA busy_timeout=5000")
        self.connection.execute("PRAGMA journal_mode=WAL")

    def _create_schema_v1(self) -> None:
        self.connection.executescript(
            """
            BEGIN IMMEDIATE;
            CREATE TABLE source_runs (
                source_run_id TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                started_at TEXT NOT NULL,
                completed_at TEXT,
                status TEXT NOT NULL CHECK(status IN ('running','completed','failed')),
                records_seen INTEGER NOT NULL DEFAULT 0 CHECK(records_seen >= 0),
                error_code TEXT
            );
            CREATE TABLE listings (
                listing_id INTEGER PRIMARY KEY AUTOINCREMENT,
                provider TEXT NOT NULL,
                provider_listing_id TEXT NOT NULL,
                fqdn TEXT NOT NULL,
                sld TEXT NOT NULL,
                tld TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                current_observation_id INTEGER,
                UNIQUE(provider, provider_listing_id)
            );
            CREATE INDEX listings_fqdn_idx ON listings(fqdn);
            CREATE TABLE listing_observations (
                observation_id INTEGER PRIMARY KEY AUTOINCREMENT,
                listing_id INTEGER NOT NULL REFERENCES listings(listing_id),
                source_run_id TEXT NOT NULL REFERENCES source_runs(source_run_id),
                status TEXT NOT NULL,
                auction_type TEXT NOT NULL,
                current_price_micros INTEGER NOT NULL CHECK(current_price_micros >= 0),
                current_price_currency TEXT NOT NULL,
                bid_count INTEGER NOT NULL CHECK(bid_count >= 0),
                start_time TEXT NOT NULL,
                end_time TEXT NOT NULL,
                source_url TEXT NOT NULL,
                observed_at TEXT NOT NULL,
                payload_hash TEXT NOT NULL,
                raw_json TEXT,
                UNIQUE(listing_id, payload_hash)
            );
            CREATE INDEX observations_listing_time_idx ON listing_observations(listing_id,observed_at);
            CREATE TABLE keyword_metrics (
                metric_id INTEGER PRIMARY KEY AUTOINCREMENT,
                listing_id INTEGER NOT NULL REFERENCES listings(listing_id),
                source_run_id TEXT NOT NULL REFERENCES source_runs(source_run_id),
                source TEXT NOT NULL,
                metric_name TEXT NOT NULL,
                value_text TEXT NOT NULL,
                unit TEXT NOT NULL,
                observed_at TEXT NOT NULL,
                payload_hash TEXT NOT NULL,
                UNIQUE(listing_id, source, metric_name, payload_hash)
            );
            CREATE TABLE trend_series (
                series_id INTEGER PRIMARY KEY AUTOINCREMENT,
                listing_id INTEGER NOT NULL REFERENCES listings(listing_id),
                source_run_id TEXT NOT NULL REFERENCES source_runs(source_run_id),
                source TEXT NOT NULL,
                query TEXT NOT NULL,
                geography TEXT NOT NULL,
                timeframe TEXT NOT NULL,
                observed_at TEXT NOT NULL,
                payload_hash TEXT NOT NULL,
                UNIQUE(listing_id, source, payload_hash)
            );
            CREATE TABLE trend_points (
                point_id INTEGER PRIMARY KEY AUTOINCREMENT,
                series_id INTEGER NOT NULL REFERENCES trend_series(series_id) ON DELETE CASCADE,
                point_time TEXT NOT NULL,
                value INTEGER NOT NULL CHECK(value >= 0),
                UNIQUE(series_id, point_time)
            );
            CREATE TABLE candidate_scores (
                score_id INTEGER PRIMARY KEY AUTOINCREMENT,
                listing_id INTEGER NOT NULL REFERENCES listings(listing_id),
                source_run_id TEXT NOT NULL REFERENCES source_runs(source_run_id),
                model TEXT NOT NULL,
                score_micros INTEGER NOT NULL,
                observed_at TEXT NOT NULL,
                payload_hash TEXT NOT NULL,
                UNIQUE(listing_id, model, payload_hash)
            );
            CREATE TABLE score_components (
                component_id INTEGER PRIMARY KEY AUTOINCREMENT,
                score_id INTEGER NOT NULL REFERENCES candidate_scores(score_id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                value_micros INTEGER NOT NULL,
                weight_micros INTEGER NOT NULL,
                evidence_json TEXT,
                UNIQUE(score_id, name)
            );
            PRAGMA user_version=1;
            COMMIT;
            """
        )

    def close(self) -> None:
        """Close this store connection."""
        self.connection.close()

    def __enter__(self) -> "DomainOpportunityStore":
        return self

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        self.close()

    @contextmanager
    def transaction(self) -> Iterator[None]:
        """Wrap a source batch in one explicit immediate transaction."""
        if self.connection.in_transaction:
            raise DomainOpportunityStoreError("nested store transactions are not supported")
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            yield
        except Exception:
            self.connection.rollback()
            raise
        else:
            self.connection.commit()

    def begin_source_run(self, source_run_id: str, provider: str, *, started_at: str | None = None) -> None:
        """Create or restart an idempotent source-run record."""
        timestamp = utc_timestamp(started_at, "started_at") if started_at else utc_now()
        existing = self.connection.execute(
            "SELECT provider FROM source_runs WHERE source_run_id=?", (source_run_id,)
        ).fetchone()
        if existing is not None and existing["provider"] != provider:
            raise DomainOpportunityStoreError("source run already belongs to another provider")
        self.connection.execute(
            """INSERT INTO source_runs(source_run_id,provider,started_at,status)
               VALUES(?,?,?,'running')
               ON CONFLICT(source_run_id) DO UPDATE SET
                 started_at=excluded.started_at, completed_at=NULL,
                 status='running', records_seen=0, error_code=NULL""",
            (source_run_id, provider, timestamp),
        )

    def complete_source_run(self, source_run_id: str, records_seen: int) -> None:
        """Mark a source run complete in the caller's transaction."""
        cursor = self.connection.execute(
            "UPDATE source_runs SET status='completed',completed_at=?,records_seen=?,error_code=NULL WHERE source_run_id=?",
            (utc_now(), records_seen, source_run_id),
        )
        if cursor.rowcount != 1:
            raise DomainOpportunityStoreError("source run does not exist")

    def fail_source_run(self, source_run_id: str, error_code: str) -> None:
        """Mark a source run failed without recording sensitive error details."""
        cursor = self.connection.execute(
            "UPDATE source_runs SET status='failed',completed_at=?,error_code=? WHERE source_run_id=?",
            (utc_now(), error_code[:64], source_run_id),
        )
        if cursor.rowcount != 1:
            raise DomainOpportunityStoreError("source run does not exist")

    def _listing_id(self, provider: str, provider_listing_id: str) -> int:
        row = self.connection.execute(
            "SELECT listing_id FROM listings WHERE provider=? AND provider_listing_id=?",
            (provider, provider_listing_id),
        ).fetchone()
        if row is None:
            raise DomainOpportunityStoreError("listing identity does not exist")
        return int(row["listing_id"])

    def upsert_listing_observation(self, record: Mapping[str, Any]) -> bool:
        """Store a normalized observation; return whether it was new."""
        item = normalize_listing(record)
        run = self.connection.execute(
            "SELECT provider FROM source_runs WHERE source_run_id=?",
            (item["source_run_id"],),
        ).fetchone()
        if run is None or run["provider"] != item["provider"]:
            raise DomainOpportunityStoreError("listing source run is missing or belongs to another provider")
        timestamp = item["observed_at"]
        self.connection.execute(
            """INSERT INTO listings(provider,provider_listing_id,fqdn,sld,tld,created_at,updated_at)
               VALUES(?,?,?,?,?,?,?)
               ON CONFLICT(provider,provider_listing_id) DO NOTHING""",
            (item["provider"], item["provider_listing_id"], item["fqdn"], item["sld"], item["tld"], timestamp, timestamp),
        )
        listing_id = self._listing_id(item["provider"], item["provider_listing_id"])
        cursor = self.connection.execute(
            """INSERT OR IGNORE INTO listing_observations(
                 listing_id,source_run_id,status,auction_type,current_price_micros,
                 current_price_currency,bid_count,start_time,end_time,source_url,
                 observed_at,payload_hash,raw_json)
               VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                listing_id,
                item["source_run_id"],
                item["status"],
                item["auction_type"],
                item["current_price_micros"],
                item["current_price_currency"],
                item["bid_count"],
                item["start_time"],
                item["end_time"],
                item["source_url"],
                item["observed_at"],
                item["payload_hash"],
                item["raw_json"],
            ),
        )
        if cursor.rowcount == 0:
            return False
        observation_id = int(cursor.lastrowid)
        current = self.connection.execute(
            """SELECT o.observed_at FROM listings l
               LEFT JOIN listing_observations o ON o.observation_id=l.current_observation_id
               WHERE l.listing_id=?""",
            (listing_id,),
        ).fetchone()
        if current is None or current["observed_at"] is None or timestamp >= current["observed_at"]:
            self.connection.execute(
                """UPDATE listings SET fqdn=?,sld=?,tld=?,updated_at=?,current_observation_id=?
                   WHERE listing_id=?""",
                (item["fqdn"], item["sld"], item["tld"], timestamp, observation_id, listing_id),
            )
        return True

    def insert_keyword_metric(self, metric: KeywordMetric) -> bool:
        """Insert one typed keyword metric with source and freshness provenance."""
        listing_id = self._listing_id(metric.provider, metric.provider_listing_id)
        cursor = self.connection.execute(
            """INSERT OR IGNORE INTO keyword_metrics(
                 listing_id,source_run_id,source,metric_name,value_text,unit,observed_at,payload_hash)
               VALUES(?,?,?,?,?,?,?,?)""",
            (
                listing_id,
                metric.source_run_id,
                metric.source,
                metric.metric_name,
                str(metric.value),
                metric.unit,
                utc_timestamp(metric.observed_at, "observed_at"),
                metric.payload_hash,
            ),
        )
        return cursor.rowcount == 1

    def insert_trend_series(self, series: TrendSeries) -> int:
        """Insert a deduplicated trend series and its typed points."""
        listing_id = self._listing_id(series.provider, series.provider_listing_id)
        normalized_points = [
            (utc_timestamp(point_time, "point_time"), value) for point_time, value in series.points
        ]
        if any(isinstance(value, bool) or not isinstance(value, int) or value < 0 for _, value in normalized_points):
            raise DomainOpportunityContractError("trend values must be non-negative integers")
        digest = series.payload_hash or content_hash(normalized_points)
        self.connection.execute(
            """INSERT OR IGNORE INTO trend_series(
                 listing_id,source_run_id,source,query,geography,timeframe,observed_at,payload_hash)
               VALUES(?,?,?,?,?,?,?,?)""",
            (
                listing_id,
                series.source_run_id,
                series.source,
                series.query,
                series.geography,
                series.timeframe,
                utc_timestamp(series.observed_at, "observed_at"),
                digest,
            ),
        )
        row = self.connection.execute(
            "SELECT series_id FROM trend_series WHERE listing_id=? AND source=? AND payload_hash=?",
            (listing_id, series.source, digest),
        ).fetchone()
        series_id = int(row["series_id"])
        self.connection.executemany(
            "INSERT OR IGNORE INTO trend_points(series_id,point_time,value) VALUES(?,?,?)",
            [(series_id, point_time, value) for point_time, value in normalized_points],
        )
        return series_id

    def insert_candidate_score(self, candidate: CandidateScore) -> int:
        """Insert one reproducible score and its named integer-micro components."""
        listing_id = self._listing_id(candidate.provider, candidate.provider_listing_id)
        score = money_micros(candidate.score_micros, "score_micros")
        digest = candidate.payload_hash or content_hash(
            {"score_micros": score, "components": candidate.components}
        )
        self.connection.execute(
            """INSERT OR IGNORE INTO candidate_scores(
                 listing_id,source_run_id,model,score_micros,observed_at,payload_hash)
               VALUES(?,?,?,?,?,?)""",
            (
                listing_id,
                candidate.source_run_id,
                candidate.model,
                score,
                utc_timestamp(candidate.observed_at, "observed_at"),
                digest,
            ),
        )
        row = self.connection.execute(
            "SELECT score_id FROM candidate_scores WHERE listing_id=? AND model=? AND payload_hash=?",
            (listing_id, candidate.model, digest),
        ).fetchone()
        score_id = int(row["score_id"])
        for name, component in sorted(candidate.components.items()):
            value = money_micros(component.get("value_micros"), "component value_micros")
            weight = money_micros(component.get("weight_micros"), "component weight_micros")
            evidence = component.get("evidence")
            self.connection.execute(
                """INSERT OR IGNORE INTO score_components(
                     score_id,name,value_micros,weight_micros,evidence_json) VALUES(?,?,?,?,?)""",
                (score_id, name, value, weight, None if evidence is None else canonical_json(evidence)),
            )
        return score_id

    def current_listings(self, *, active_only: bool = False) -> list[dict[str, Any]]:
        """Return the current normalized listing view in stable identity order."""
        rows = self.connection.execute(
            """SELECT l.provider,l.provider_listing_id,l.fqdn,l.sld,l.tld,
                       o.status,o.auction_type,o.current_price_micros,
                       o.current_price_currency,o.bid_count,o.start_time,o.end_time,
                       o.source_url,o.observed_at,o.source_run_id,o.payload_hash
                FROM listings l JOIN listing_observations o
                  ON o.observation_id=l.current_observation_id
                WHERE (?=0 OR o.status='active')
                ORDER BY l.provider,l.provider_listing_id""",
            (int(active_only),),
        ).fetchall()
        return [{column: row[column] for column in CSV_COLUMNS} for row in rows]

    def status(self) -> dict[str, Any]:
        """Return deterministic compatibility and row-count status."""
        queries = (
            ("source_runs", "SELECT COUNT(*) FROM source_runs"),
            ("listings", "SELECT COUNT(*) FROM listings"),
            ("listing_observations", "SELECT COUNT(*) FROM listing_observations"),
            ("keyword_metrics", "SELECT COUNT(*) FROM keyword_metrics"),
            ("trend_series", "SELECT COUNT(*) FROM trend_series"),
            ("trend_points", "SELECT COUNT(*) FROM trend_points"),
            ("candidate_scores", "SELECT COUNT(*) FROM candidate_scores"),
            ("score_components", "SELECT COUNT(*) FROM score_components"),
        )
        counts = {
            table: int(self.connection.execute(query).fetchone()[0]) for table, query in queries
        }
        return {"schema_version": SCHEMA_VERSION, "database": str(self.path), "counts": counts}

    def export_csv(self, output: str | os.PathLike[str], *, active_only: bool = False) -> int:
        """Atomically export the current normalized listing view."""
        destination = _safe_path(output, DEFAULT_ROOT / "opportunities.csv")
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=CSV_COLUMNS, lineterminator="\n")
                writer.writeheader()
                rows = self.current_listings(active_only=active_only)
                writer.writerows(rows)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary_name, 0o600)
            os.replace(temporary_name, destination)
            return len(rows)
        except Exception:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass
            raise
