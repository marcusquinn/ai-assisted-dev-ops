#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Crash-safe private store for normalized marketing performance events."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import stat
import time
from pathlib import Path
from typing import Any

from performance_adapters import AdapterResult
from performance_contract import (
    ALIAS_RE,
    PUBLIC_DIMENSION_KEYS,
    PerformanceContractError,
    canonical_json,
    event_for_fingerprint,
    timestamp_epoch,
    utc_now,
    validate_batch_header,
    validate_event,
)
from performance_store_schema import (
    PlanePaths,
    connect_database,
    load_config,
    provision_plane,
    resolve_paths,
)


class PerformanceStoreError(PerformanceContractError):
    """Raised when durable ingest state cannot advance safely."""


class MarketingPerformanceStore:
    """Own source/account leases, immutable events, and rebuildable projections."""

    def __init__(
        self,
        paths: PlanePaths,
        config: dict[str, Any],
        connection: sqlite3.Connection,
    ) -> None:
        self.paths = paths
        self.config = config
        self.connection = connection
        row = connection.execute(
            "SELECT value FROM metadata WHERE key='subject_hmac_salt'"
        ).fetchone()
        if row is None:
            raise PerformanceStoreError("performance store is missing pseudonymization metadata")
        self._salt = bytes.fromhex(str(row["value"]))

    @classmethod
    def open(cls, repo: Path, *, provision: bool = False) -> "MarketingPerformanceStore":
        """Open an initialized plane, optionally provisioning it first."""
        paths = resolve_paths(repo)
        create_database = provision and not paths.index.exists()
        config = provision_plane(paths) if provision else load_config(paths)
        return cls(
            paths,
            config,
            connect_database(paths, create=create_database),
        )

    def close(self) -> None:
        """Close the private SQLite projection."""
        self.connection.close()

    def __enter__(self) -> "MarketingPerformanceStore":
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()

    def pseudonym(self, prefix: str, *parts: str) -> str:
        """Return a deterministic store-local HMAC reference."""
        payload = "\0".join(parts).encode("utf-8")
        digest = hmac.new(self._salt, payload, hashlib.sha256).hexdigest()
        return f"{prefix}:{digest}"

    def _source_event_ref(self, source: str, account_ref: str, source_event_id: str) -> str:
        return self.pseudonym("mkt-event-v1", source, account_ref, source_event_id)

    def _subject_ref(self, source: str, account_ref: str, source_subject_ref: str) -> str:
        return self.pseudonym("mkt-subj-v1", source, account_ref, source_subject_ref)

    def _cursor_ref(self, source: str, account_ref: str, cursor: str | None) -> str | None:
        if cursor is None:
            return None
        return self.pseudonym("mkt-cursor-v1", source, account_ref, cursor)

    def _storage_dimensions(
        self,
        source: str,
        account_ref: str,
        dimensions: dict[str, str | int | float | bool],
    ) -> dict[str, str | int | float | bool]:
        """Pseudonymize dimensions outside the bounded public vocabulary."""
        output: dict[str, str | int | float | bool] = {}
        for key, value in dimensions.items():
            public_value = not isinstance(value, str) or bool(
                ALIAS_RE.fullmatch(value)
            )
            if key in PUBLIC_DIMENSION_KEYS and public_value:
                output[key] = value
            else:
                output[key] = self.pseudonym(
                    "mkt-dim-v1",
                    source,
                    account_ref,
                    key,
                    canonical_json(value),
                )
        return output

    @staticmethod
    def _record_ref(event_ref: str, revision: int) -> str:
        digest = hashlib.sha256(f"{event_ref}\0{revision}".encode("utf-8")).hexdigest()
        return f"mkt-record-v1:{digest}"

    @staticmethod
    def _evidence_ref(source: str, account_ref: str, raw_bytes: bytes) -> tuple[str, str]:
        content_digest = hashlib.sha256(raw_bytes).hexdigest()
        scoped_digest = hashlib.sha256(
            f"{source}\0{account_ref}\0{content_digest}".encode("utf-8")
        ).hexdigest()
        return f"mkt-evidence-v1:sha256:{scoped_digest}", content_digest

    def _acquire_lease(self, source: str, account_ref: str) -> str:
        token = secrets.token_hex(24)
        now_epoch = int(time.time())
        lease_seconds = int(self.config["lease_seconds"])
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            existing = self.connection.execute(
                "SELECT expires_at FROM leases WHERE source=? AND account_ref=?",
                (source, account_ref),
            ).fetchone()
            if existing is not None and int(existing["expires_at"]) > now_epoch:
                raise PerformanceStoreError("exact source/account ingest is already leased")
            self.connection.execute(
                "INSERT INTO leases(source,account_ref,token,acquired_at,expires_at) "
                "VALUES(?,?,?,?,?) ON CONFLICT(source,account_ref) DO UPDATE SET "
                "token=excluded.token,acquired_at=excluded.acquired_at,expires_at=excluded.expires_at",
                (source, account_ref, token, now_epoch, now_epoch + lease_seconds),
            )
            self.connection.commit()
        except Exception:
            self.connection.rollback()
            raise
        return token

    def _release_lease(self, source: str, account_ref: str, token: str) -> None:
        self.connection.execute(
            "DELETE FROM leases WHERE source=? AND account_ref=? AND token=?",
            (source, account_ref, token),
        )
        self.connection.commit()

    @staticmethod
    def _ensure_private_directory(path: Path) -> None:
        """Create one private directory without accepting a symlink."""
        if path.is_symlink():
            raise PerformanceStoreError("raw evidence directory is unsafe")
        path.mkdir(parents=False, exist_ok=True, mode=0o700)
        if path.is_symlink() or not path.is_dir():
            raise PerformanceStoreError("raw evidence directory is unsafe")
        os.chmod(path, 0o700)

    @staticmethod
    def _regular_file_digest(path: Path) -> str:
        """Hash one regular file through a no-follow descriptor."""
        descriptor = -1
        try:
            descriptor = os.open(
                path,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            )
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise PerformanceStoreError(
                    "raw evidence destination is not a regular file"
                )
            digest = hashlib.sha256()
            with os.fdopen(descriptor, "rb") as handle:
                descriptor = -1
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
            return digest.hexdigest()
        except OSError as exc:
            raise PerformanceStoreError(
                "raw evidence destination is not a readable regular file"
            ) from exc
        finally:
            if descriptor >= 0:
                os.close(descriptor)

    def _write_raw(
        self,
        source: str,
        account_ref: str,
        digest: str,
        suffix: str,
        raw_bytes: bytes,
    ) -> tuple[Path, bool]:
        source_directory = self.paths.raw / source
        directory = source_directory / account_ref
        for private_directory in (
            self.paths.raw,
            source_directory,
            directory,
        ):
            self._ensure_private_directory(private_directory)
        destination = directory / f"{digest}{suffix}"
        if destination.is_symlink() or (
            destination.exists() and not destination.is_file()
        ):
            raise PerformanceStoreError("raw evidence destination is not a regular file")
        if destination.exists():
            if self._regular_file_digest(destination) != digest:
                raise PerformanceStoreError("raw evidence digest collision")
            return destination, False
        temporary = directory / f".{digest}.{os.getpid()}.{secrets.token_hex(4)}.tmp"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(raw_bytes)
                handle.flush()
                os.fsync(handle.fileno())
            try:
                os.link(temporary, destination)
                created = True
            except FileExistsError:
                created = False
            temporary.unlink()
            if self._regular_file_digest(destination) != digest:
                raise PerformanceStoreError("raw evidence failed digest verification")
            return destination, created
        finally:
            if temporary.exists():
                temporary.unlink()

    @staticmethod
    def _safe_error(error: dict[str, Any]) -> dict[str, Any]:
        reason = str(error.get("reason", "adapter record rejected"))
        reason = "".join(character for character in reason if character.isprintable())[:256]
        index = error.get("index")
        if not isinstance(index, (int, str)):
            index = "unknown"
        return {"index": index, "reason": reason or "adapter record rejected"}

    def _quarantine(
        self,
        source: str,
        account_ref: str,
        source_event_id: str,
        reason: str,
        evidence_ref: str,
        recorded_at: str,
        details: dict[str, Any],
    ) -> str:
        source_event_ref = self._source_event_ref(source, account_ref, source_event_id)
        digest = hashlib.sha256(
            f"{source}\0{account_ref}\0{source_event_ref}\0{reason}\0{evidence_ref}".encode(
                "utf-8"
            )
        ).hexdigest()
        quarantine_ref = f"mkt-quarantine-v1:{digest}"
        self.connection.execute(
            "INSERT OR IGNORE INTO quarantine("
            "quarantine_ref,source,account_ref,source_event_ref,reason,evidence_ref,recorded_at,details_json"
            ") VALUES(?,?,?,?,?,?,?,?)",
            (
                quarantine_ref,
                source,
                account_ref,
                source_event_ref,
                reason,
                evidence_ref,
                recorded_at,
                canonical_json(details),
            ),
        )
        return quarantine_ref

    def _insert_governance(
        self,
        event: dict[str, Any],
        record_ref: str,
        subject_id: str | None,
        source: str,
        account_ref: str,
        observed_at: str,
        evidence_ref: str,
    ) -> None:
        if subject_id is None:
            return
        for index, consent in enumerate(event["governance"]["consent"]):
            ledger_ref = self.pseudonym("mkt-consent-v1", record_ref, str(index), canonical_json(consent))
            self.connection.execute(
                "INSERT OR IGNORE INTO consent_ledger("
                "ledger_ref,subject_id,purpose,state,lawful_basis,source,account_ref,effective_at,observed_at,evidence_ref"
                ") VALUES(?,?,?,?,?,?,?,?,?,?)",
                (
                    ledger_ref,
                    subject_id,
                    consent["purpose"],
                    consent["state"],
                    consent["lawful_basis"],
                    source,
                    account_ref,
                    consent["effective_at"],
                    observed_at,
                    evidence_ref,
                ),
            )
        suppression = event["governance"]["suppression"]
        if suppression is None:
            return
        ledger_ref = self.pseudonym("mkt-suppression-v1", record_ref, canonical_json(suppression))
        self.connection.execute(
            "INSERT OR IGNORE INTO suppression_ledger("
            "ledger_ref,subject_id,state,reason,source,account_ref,effective_at,observed_at,evidence_ref"
            ") VALUES(?,?,?,?,?,?,?,?,?)",
            (
                ledger_ref,
                subject_id,
                suppression["state"],
                suppression["reason"],
                source,
                account_ref,
                suppression["effective_at"],
                observed_at,
                evidence_ref,
            ),
        )

    def _insert_event(
        self,
        event: dict[str, Any],
        header: dict[str, Any],
        evidence_ref: str,
        recorded_at: str,
    ) -> str:
        event = {
            **event,
            "scope": {
                **event["scope"],
                "dimensions": self._storage_dimensions(
                    header["source"],
                    header["account_ref"],
                    event["scope"]["dimensions"]
                ),
            },
        }
        source = header["source"]
        account_ref = header["account_ref"]
        event_ref = self._source_event_ref(source, account_ref, event["source_event_id"])
        record_ref = self._record_ref(event_ref, int(event["revision"]))
        fingerprint = hashlib.sha256(
            canonical_json(event_for_fingerprint(event)).encode("utf-8")
        ).hexdigest()
        existing = self.connection.execute(
            "SELECT payload_fingerprint FROM events WHERE record_ref=?",
            (record_ref,),
        ).fetchone()
        if existing is not None:
            if str(existing["payload_fingerprint"]) == fingerprint:
                return "duplicate"
            self._quarantine(
                source,
                account_ref,
                event["source_event_id"],
                "same_revision_payload_conflict",
                evidence_ref,
                recorded_at,
                {"reason": "same_revision_payload_conflict"},
            )
            return "conflict"
        subject = event["subject"]
        if subject["identity_state"] == "ambiguous":
            self._quarantine(
                source,
                account_ref,
                event["source_event_id"],
                "identity_ambiguous",
                evidence_ref,
                recorded_at,
                {"reason": "identity_ambiguous", "candidate_count": len(subject["candidate_refs"])},
            )
            return "quarantined"
        subject_id = None
        if subject["source_ref"] is not None:
            subject_id = self._subject_ref(source, account_ref, subject["source_ref"])
        correction_ref = None
        if event["correction_of"] is not None:
            correction_ref = self._source_event_ref(source, account_ref, event["correction_of"])
        scope = event["scope"]
        measurement = event["measurement"]
        quality = event["quality"]
        if correction_ref is not None:
            target = self.connection.execute(
                "SELECT * FROM events WHERE event_ref=? ORDER BY revision DESC LIMIT 1",
                (correction_ref,),
            ).fetchone()
            correction_fields = (
                "subject_id",
                "campaign_id",
                "channel",
                "creative_id",
                "touchpoint_id",
                "outcome_id",
                "dimensions_json",
                "metric_id",
                "unit",
                "aggregation",
                "currency",
                "period_start",
                "period_end",
            )
            correction_values = {
                "subject_id": subject_id,
                **scope,
                **measurement,
                "dimensions_json": canonical_json(scope["dimensions"]),
            }
            reason = None
            if target is None:
                reason = "correction_target_pending"
            elif any(target[field] != correction_values[field] for field in correction_fields):
                reason = "correction_target_mismatch"
            else:
                existing_correction = self.connection.execute(
                    "SELECT event_ref FROM events WHERE correction_ref=? LIMIT 1",
                    (correction_ref,),
                ).fetchone()
                if (
                    existing_correction is not None
                    and str(existing_correction["event_ref"]) != event_ref
                ):
                    reason = "correction_target_already_corrected"
            if reason is not None:
                self._quarantine(
                    source,
                    account_ref,
                    event["source_event_id"],
                    reason,
                    evidence_ref,
                    recorded_at,
                    {"reason": reason},
                )
                return "quarantined"
        self.connection.execute(
            "INSERT INTO events("
            "record_ref,event_ref,source,account_ref,revision,correction_ref,event_type,occurred_at,observed_at,recorded_at,"
            "source_observed_at,source_recorded_at,"
            "subject_id,subject_kind,identity_state,campaign_id,channel,creative_id,touchpoint_id,outcome_id,"
            "dimensions_json,metric_id,value_text,unit,aggregation,currency,period_start,period_end,confidence,completeness,source_type,collected_by,evidence_ref,payload_fingerprint"
            ") VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                record_ref,
                event_ref,
                source,
                account_ref,
                event["revision"],
                correction_ref,
                event["event_type"],
                event["occurred_at"],
                header["observed_at"],
                recorded_at,
                event["source_observed_at"],
                event["source_recorded_at"],
                subject_id,
                subject["kind"],
                subject["identity_state"],
                scope["campaign_id"],
                scope["channel"],
                scope["creative_id"],
                scope["touchpoint_id"],
                scope["outcome_id"],
                canonical_json(scope["dimensions"]),
                measurement["metric_id"],
                measurement["value"],
                measurement["unit"],
                measurement["aggregation"],
                measurement["currency"],
                measurement["period_start"],
                measurement["period_end"],
                quality["confidence"],
                quality["completeness"],
                quality["source_type"],
                quality["collected_by"],
                evidence_ref,
                fingerprint,
            ),
        )
        self._insert_governance(
            event,
            record_ref,
            subject_id,
            source,
            account_ref,
            header["observed_at"],
            evidence_ref,
        )
        return "inserted"

    def _events_match_evidence(
        self,
        events: list[dict[str, Any]],
        header: dict[str, Any],
        evidence_ref: str,
    ) -> bool:
        """Return whether every event already references this exact evidence."""
        for event in events:
            event_ref = self._source_event_ref(
                header["source"],
                header["account_ref"],
                event["source_event_id"],
            )
            record_ref = self._record_ref(event_ref, int(event["revision"]))
            existing = self.connection.execute(
                "SELECT evidence_ref FROM events WHERE record_ref=?",
                (record_ref,),
            ).fetchone()
            if existing is None or str(existing["evidence_ref"]) != evidence_ref:
                return False
        return bool(events)

    def _events_are_current(
        self,
        events: list[dict[str, Any]],
        header: dict[str, Any],
    ) -> bool:
        """Return whether every replayed event is its current highest revision."""
        for event in events:
            event_ref = self._source_event_ref(
                header["source"],
                header["account_ref"],
                event["source_event_id"],
            )
            latest = self.connection.execute(
                "SELECT MAX(revision) FROM events WHERE source=? AND account_ref=? AND event_ref=?",
                (header["source"], header["account_ref"], event_ref),
            ).fetchone()
            if latest is None or int(latest[0]) != int(event["revision"]):
                return False
        return bool(events)

    def _validate_events(
        self,
        header: dict[str, Any],
        adapter_errors: list[dict[str, Any]],
    ) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        events: list[dict[str, Any]] = []
        errors = [dict(error) for error in adapter_errors]
        effective_coverage = "partial" if header["missing_scopes"] else header["coverage"]
        for index, raw_event in enumerate(header["events"]):
            try:
                events.append(
                    validate_event(raw_event, effective_coverage, header["missing_scopes"])
                )
            except PerformanceContractError as exc:
                source_event_id = f"record-{index}"
                if isinstance(raw_event, dict) and isinstance(raw_event.get("source_event_id"), str):
                    source_event_id = raw_event["source_event_id"]
                errors.append(
                    {
                        "index": index,
                        "reason": str(exc),
                        "source_event_id": source_event_id,
                    }
                )
        return events, errors

    def _update_source_state(
        self,
        adapter: str,
        header: dict[str, Any],
        evidence_ref: str,
        recorded_at: str,
        partial: bool,
    ) -> bool:
        """Advance only monotonic source observations and successful checkpoints."""
        source = header["source"]
        account_ref = header["account_ref"]
        existing = self.connection.execute(
            "SELECT * FROM sources WHERE source=? AND account_ref=?",
            (source, account_ref),
        ).fetchone()
        observed_at = header["observed_at"]
        observed_epoch = timestamp_epoch(observed_at)
        latest_observation = (
            existing is None
            or existing["last_observed_at"] is None
            or observed_epoch >= timestamp_epoch(str(existing["last_observed_at"]))
        )
        prior_success = None if existing is None else existing["last_success_at"]
        successful_checkpoint = (
            not partial
            and (
                prior_success is None
                or observed_epoch >= timestamp_epoch(str(prior_success))
            )
        )
        prior_cursor = None if existing is None else existing["cursor_ref"]
        next_cursor = prior_cursor
        if successful_checkpoint and header["cursor"] is not None:
            next_cursor = self._cursor_ref(source, account_ref, header["cursor"])
        cursor_advanced = bool(
            successful_checkpoint
            and header["cursor"] is not None
            and next_cursor != prior_cursor
        )
        if existing is None or latest_observation:
            state_adapter = adapter
            state_status = "partial" if partial else "ready"
            state_coverage = "partial" if partial else header["coverage"]
            missing_scopes = canonical_json(sorted(set(header["missing_scopes"])))
            last_evidence_ref = evidence_ref
        else:
            state_adapter = str(existing["adapter"])
            state_status = str(existing["status"])
            state_coverage = str(existing["coverage"])
            missing_scopes = str(existing["missing_scopes_json"])
            last_evidence_ref = existing["last_evidence_ref"]
        last_observed_at = observed_at
        if existing is not None and existing["last_observed_at"] is not None:
            if observed_epoch < timestamp_epoch(str(existing["last_observed_at"])):
                last_observed_at = str(existing["last_observed_at"])
        last_success_at = prior_success
        if successful_checkpoint:
            last_success_at = observed_at
        stale_map = self.config["source_stale_after_seconds"]
        stale_after = int(
            stale_map.get(source, self.config["default_stale_after_seconds"])
        )
        self.connection.execute(
            "INSERT INTO sources("
            "source,account_ref,adapter,status,coverage,missing_scopes_json,cursor_ref,last_observed_at,last_success_at,last_evidence_ref,stale_after_seconds,updated_at"
            ") VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(source,account_ref) DO UPDATE SET "
            "adapter=excluded.adapter,status=excluded.status,coverage=excluded.coverage,"
            "missing_scopes_json=excluded.missing_scopes_json,cursor_ref=excluded.cursor_ref,"
            "last_observed_at=excluded.last_observed_at,last_success_at=excluded.last_success_at,"
            "last_evidence_ref=excluded.last_evidence_ref,stale_after_seconds=excluded.stale_after_seconds,updated_at=excluded.updated_at",
            (
                source,
                account_ref,
                state_adapter,
                state_status,
                state_coverage,
                missing_scopes,
                next_cursor,
                last_observed_at,
                last_success_at,
                last_evidence_ref,
                stale_after,
                recorded_at,
            ),
        )
        return cursor_advanced

    def _checkpoint_conflicts(self, header: dict[str, Any]) -> bool:
        """Detect a conflicting opaque cursor at the same successful watermark."""
        if header["cursor"] is None:
            return False
        existing = self.connection.execute(
            "SELECT cursor_ref,last_success_at FROM sources WHERE source=? AND account_ref=?",
            (header["source"], header["account_ref"]),
        ).fetchone()
        if (
            existing is None
            or existing["cursor_ref"] is None
            or existing["last_success_at"] is None
            or timestamp_epoch(header["observed_at"])
            != timestamp_epoch(str(existing["last_success_at"]))
        ):
            return False
        incoming = self._cursor_ref(
            header["source"], header["account_ref"], header["cursor"]
        )
        return incoming != str(existing["cursor_ref"])

    def ingest(
        self,
        adapter: str,
        result: AdapterResult,
        *,
        dry_run: bool = False,
    ) -> dict[str, Any]:
        """Validate, lease, append, and advance one exact source/account cursor."""
        header = validate_batch_header(result.batch)
        total_records = len(header["events"]) + len(result.errors)
        if total_records > int(self.config["max_batch_events"]):
            raise PerformanceStoreError("batch exceeds configured event limit")
        events, validation_errors = self._validate_events(header, result.errors)
        safe_errors = [self._safe_error(error) for error in validation_errors]
        if dry_run:
            return {
                "schema": "aidevops.marketing-performance-ingest/v1",
                "dry_run": True,
                "source": header["source"],
                "account_ref": header["account_ref"],
                "accepted": len(events),
                "quarantined": len(validation_errors),
                "coverage": (
                    "partial"
                    if validation_errors or header["missing_scopes"]
                    else header["coverage"]
                ),
                "errors": safe_errors,
            }
        source = header["source"]
        account_ref = header["account_ref"]
        lease_token = self._acquire_lease(source, account_ref)
        evidence_ref, content_digest = self._evidence_ref(source, account_ref, result.raw_bytes)
        raw_path: Path | None = None
        try:
            raw_path, _ = self._write_raw(
                source,
                account_ref,
                content_digest,
                result.suffix,
                result.raw_bytes,
            )
            recorded_at = utc_now()
            now_epoch = int(time.time())
            self.connection.execute("BEGIN IMMEDIATE")
            lease = self.connection.execute(
                "SELECT token,expires_at FROM leases WHERE source=? AND account_ref=?",
                (source, account_ref),
            ).fetchone()
            if lease is None or str(lease["token"]) != lease_token or int(lease["expires_at"]) <= now_epoch:
                raise PerformanceStoreError("source/account lease expired before commit")
            relative_path = raw_path.relative_to(self.paths.repo).as_posix()
            self.connection.execute(
                "INSERT OR IGNORE INTO evidence("
                "evidence_ref,source,account_ref,sha256,relative_path,observed_at,recorded_at"
                ") VALUES(?,?,?,?,?,?,?)",
                (
                    evidence_ref,
                    source,
                    account_ref,
                    content_digest,
                    relative_path,
                    header["observed_at"],
                    recorded_at,
                ),
            )
            counts = {"inserted": 0, "duplicate": 0, "conflict": 0, "quarantined": 0}
            for event in events:
                outcome = self._insert_event(event, header, evidence_ref, recorded_at)
                counts[outcome] += 1
            for error in validation_errors:
                source_event_id = str(error.get("source_event_id", f"record-{error.get('index', 'unknown')}"))
                safe_error = self._safe_error(error)
                self._quarantine(
                    source,
                    account_ref,
                    source_event_id,
                    "adapter_or_contract_rejected",
                    evidence_ref,
                    recorded_at,
                    safe_error,
                )
                counts["quarantined"] += 1
            complete_campaign_revision = (
                adapter == "campaign"
                and bool(events)
                and counts["inserted"] == len(events)
                and counts["duplicate"] == 0
                and counts["conflict"] == 0
                and counts["quarantined"] == 0
                and header["coverage"] == "complete"
                and not header["missing_scopes"]
            )
            if (
                self._checkpoint_conflicts(header)
                and not complete_campaign_revision
                and counts["conflict"] == 0
                and counts["quarantined"] == 0
            ):
                self._quarantine(
                    source,
                    account_ref,
                    "batch-cursor",
                    "same_watermark_cursor_conflict",
                    evidence_ref,
                    recorded_at,
                    {"reason": "same_watermark_cursor_conflict"},
                )
                counts["quarantined"] += 1
            exact_replay = (
                counts["duplicate"] == len(events)
                and counts["inserted"] == 0
                and counts["conflict"] == 0
                and counts["quarantined"] == 0
                and self._events_match_evidence(events, header, evidence_ref)
                and self._events_are_current(events, header)
            )
            partial = (
                header["coverage"] != "complete"
                or bool(header["missing_scopes"])
                or any(
                    counts[name] > 0 for name in ("conflict", "quarantined")
                )
            )
            cursor_advanced = self._update_source_state(
                adapter,
                header,
                evidence_ref,
                recorded_at,
                partial,
            )
            self.connection.execute(
                "DELETE FROM leases WHERE source=? AND account_ref=? AND token=?",
                (source, account_ref, lease_token),
            )
            self.connection.commit()
            return {
                "schema": "aidevops.marketing-performance-ingest/v1",
                "dry_run": False,
                "source": source,
                "account_ref": account_ref,
                "evidence_ref": evidence_ref,
                "accepted": counts["inserted"],
                "duplicates": counts["duplicate"],
                "quarantined": counts["quarantined"] + counts["conflict"],
                "coverage": "partial" if partial else header["coverage"],
                "cursor_advanced": cursor_advanced,
                "exact_replay": exact_replay,
                "errors": safe_errors,
            }
        except Exception:
            self.connection.rollback()
            try:
                self._release_lease(source, account_ref, lease_token)
            except sqlite3.Error:
                pass
            # Published raw evidence is content-addressed and immutable. Retain an
            # unreferenced artifact after rollback so an expired worker cannot
            # delete a file another fenced worker is about to reference.
            raise

    def recover_expired_leases(self) -> int:
        """Remove only expired mutable lease projections."""
        cursor = self.connection.execute(
            "DELETE FROM leases WHERE expires_at <= ?",
            (int(time.time()),),
        )
        self.connection.commit()
        return int(cursor.rowcount)
