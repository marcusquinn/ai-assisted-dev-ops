#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Crash-safe private store for normalized marketing performance events."""

from __future__ import annotations

import hashlib
import hmac
import json
import sqlite3
from pathlib import Path
from typing import Any

from performance_adapters import AdapterResult
from performance_contract import (
    ALIAS_RE,
    PUBLIC_DIMENSION_KEYS,
    PerformanceContractError,
    canonical_json,
    timestamp_epoch,
    validate_event,
)
from performance_store_schema import (
    PlanePaths,
    connect_database,
    load_config,
    provision_plane,
    resolve_paths,
)
from _performance_store_ingest import ingest as _ingest
from _performance_store_leases import (
    acquire_lease as _acquire_lease,
    recover_expired_leases as _recover_expired_leases,
    release_lease as _release_lease,
)
from _performance_store_evidence import (
    ensure_private_directory as _ensure_private_directory,
    regular_file_digest as _regular_file_digest,
    write_raw as _write_raw,
)
from _performance_store_persistence import (
    insert_event as _persist_event,
    insert_governance as _persist_governance,
    quarantine as _persist_quarantine,
)
from _performance_store_state import update_source_state as _update_source_state
from _performance_store_types import (
    EvidenceWriteContext,
    EventInsertContext,
    GovernanceContext,
    QuarantineContext,
    SourceStateContext,
)


class PerformanceStoreError(PerformanceContractError):
    """Raised when durable ingest state cannot advance safely."""


class MarketingPerformanceStore:
    """Own source/account leases, immutable events, and rebuildable projections."""

    error_type = PerformanceStoreError

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
        return _acquire_lease(self, source, account_ref)

    def _release_lease(self, source: str, account_ref: str, token: str) -> None:
        _release_lease(self, source, account_ref, token)

    @staticmethod
    def _ensure_private_directory(path: Path) -> None:
        """Create one private directory without accepting a symlink."""
        _ensure_private_directory(MarketingPerformanceStore, path)

    @staticmethod
    def _regular_file_digest(path: Path) -> str:
        """Hash one regular file through a no-follow descriptor."""
        return _regular_file_digest(MarketingPerformanceStore, path)

    def _write_raw(
        self,
        source: str,
        account_ref: str,
        digest: str,
        suffix: str,
        raw_bytes: bytes,
    ) -> tuple[Path, bool]:
        return _write_raw(
            self, EvidenceWriteContext(source, account_ref, digest, suffix, raw_bytes)
        )

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
        context: QuarantineContext,
    ) -> str:
        return _persist_quarantine(self, context)

    def _insert_governance(
        self,
        context: GovernanceContext,
    ) -> None:
        _persist_governance(self, context)

    def _insert_event(
        self,
        event: dict[str, Any],
        header: dict[str, Any],
        evidence_ref: str,
        recorded_at: str,
    ) -> str:
        return _persist_event(
            self, EventInsertContext(event, header, evidence_ref, recorded_at)
        )

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
        return _update_source_state(
            self,
            SourceStateContext(adapter, header, evidence_ref, recorded_at, partial),
        )

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
        return _ingest(self, adapter, result, dry_run)

    def recover_expired_leases(self) -> int:
        """Remove only expired mutable lease projections."""
        return _recover_expired_leases(self)
