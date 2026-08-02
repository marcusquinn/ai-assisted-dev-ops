#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Crash, rollback, and recovery tests for social raw evidence."""

from __future__ import annotations

import gzip
import hashlib
import json
import os
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIRECTORY = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPT_DIRECTORY))

from _knowledge_social_collect import (  # noqa: E402
    CollectionContext,
    ConnectionConfig,
    CursorState,
    PageCheckpoint,
    SuccessfulPage,
    TerminalDecision,
)
from _knowledge_social_collect_persist import (  # noqa: E402
    persist_page,
    record_terminal,
)
from _knowledge_social_lease import (  # noqa: E402
    RunLeaseRequest,
    acquire_run_lease,
)
from _knowledge_social_medium import persist_medium_archive  # noqa: E402
from _knowledge_social_medium_types import ParsedMediumArchive  # noqa: E402
from _knowledge_social_reconcile import (  # noqa: E402
    ReconciliationSnapshot,
    reconcile_snapshot,
)
from _knowledge_social_x import STREAMS  # noqa: E402
import _knowledge_social_store_raw_write as raw_write  # noqa: E402
from knowledge_social_import import (  # noqa: E402
    canonical_json,
    import_archive_payload,
)
from knowledge_social_store import (  # noqa: E402
    SocialStoreError,
    connect,
    migrate,
    recover_raw_evidence,
    write_raw_batch,
)

FAULT_ENV = "AIDEVOPS_SOCIAL_RAW_TEST_FAULT"
FAULT_EXIT = 86
FAULT_RAISE = 75
WRITER_SCENARIOS = ("page", "terminal", "reconciliation", "archive", "medium")


def _prepare_root(root: Path) -> None:
    root.mkdir(parents=True, mode=0o700)
    os.chmod(root, 0o700)


def _archive(provider: str, connection_id: str, account_id: str) -> dict[str, object]:
    return {
        "provider": provider,
        "connection_id": connection_id,
        "remote_account_id": account_id,
        "exported_at": "2026-08-01T00:00:00Z",
        "enabled_streams": ["authored"],
        "policy": {},
        "accounts": [],
        "objects": [],
        "activities": [],
        "media": [],
        "coverage": [],
    }


def _lease(root: Path, connection_id: str, stream: str, run_kind: str = "sync"):
    return acquire_run_lease(
        root,
        RunLeaseRequest(connection_id, stream, "fault_runner", run_kind, 60),
    )


def _context(root: Path, connection_id: str) -> CollectionContext:
    lease = _lease(root, connection_id, "authored")
    return CollectionContext(
        root,
        connection_id,
        {"id": "acct_fault"},
        "authored",
        "none",
        ConnectionConfig(("authored",), {"media_hydration": "none"}),
        CursorState(None, None, False),
        STREAMS["authored"],
        lease,
        "xapi",
    )


def _run_page(root: Path) -> None:
    context = _context(root, "conn_page")
    observed_at = "2026-08-01T00:00:00Z"
    archive = {
        "remote_account_id": "acct_fault",
        "enabled_streams": ["authored"],
        "policy": {"media_hydration": "none"},
        "accounts": [],
        "objects": [],
        "activities": [],
        "media": [],
        "coverage": [],
        "exported_at": observed_at,
    }
    os.environ[FAULT_ENV] = os.environ["RAW_FAULT_MODE"]
    persist_page(
        context,
        SuccessfulPage(
            {"status": 200, "observed_at": observed_at, "data": []},
            "/fault/page",
            archive,
            PageCheckpoint(None, None),
            True,
            1,
        ),
    )


def _run_terminal(root: Path) -> None:
    context = _context(root, "conn_terminal")
    os.environ[FAULT_ENV] = os.environ["RAW_FAULT_MODE"]
    record_terminal(
        context,
        {"status": 429, "observed_at": "2026-08-01T00:00:00Z"},
        "/fault/terminal",
        TerminalDecision("rate_limited", "paused", "rate_limit"),
    )


def _run_reconciliation(root: Path) -> None:
    database = connect(root)
    try:
        migrate(database)
        database.execute("BEGIN IMMEDIATE")
        database.execute(
            "INSERT INTO connections(connection_id,provider,remote_account_id,"
            "enabled_streams,policy_json) VALUES(?,?,?,?,?)",
            ("conn_reconcile", "xapi", "acct_fault", '["authored"]', "{}"),
        )
        database.execute("COMMIT")
    finally:
        database.close()
    lease = _lease(root, "conn_reconcile", "authored", "reconcile")
    snapshot_payload = canonical_json(
        {"objects": [], "activities": [], "complete": True}
    ).encode("utf-8")
    snapshot = ReconciliationSnapshot(
        "xapi",
        "2026-08-01T00:00:00Z",
        True,
        frozenset(),
        frozenset(),
        snapshot_payload,
        hashlib.sha256(snapshot_payload).hexdigest(),
        1_785_542_400.0,
    )
    os.environ[FAULT_ENV] = os.environ["RAW_FAULT_MODE"]
    reconcile_snapshot(root, lease, snapshot, now_epoch=1000)


def _run_archive(root: Path) -> None:
    archive = _archive("xapi", "conn_archive", "acct_fault")
    payload = canonical_json(archive).encode("utf-8")
    os.environ[FAULT_ENV] = os.environ["RAW_FAULT_MODE"]
    import_archive_payload(root, archive, payload)


def _run_medium(root: Path) -> None:
    payload = b"medium-fault-evidence"
    archive = _archive("medium", "conn_medium", "acct_fault")
    archive["enabled_streams"] = ["archive"]
    parsed = ParsedMediumArchive(
        archive,
        hashlib.sha256(payload).hexdigest(),
        1,
        0,
        0,
    )
    lease = _lease(root, "conn_medium", "archive")
    os.environ[FAULT_ENV] = os.environ["RAW_FAULT_MODE"]
    persist_medium_archive(root, parsed, payload, lease)


def _run_writer(scenario: str, root: Path) -> None:
    runners = {
        "page": _run_page,
        "terminal": _run_terminal,
        "reconciliation": _run_reconciliation,
        "archive": _run_archive,
        "medium": _run_medium,
    }
    runners[scenario](root)


def _child_main(arguments: list[str]) -> int:
    scenario, root_value, fault_mode = arguments
    root = Path(root_value)
    _prepare_root(root)
    os.environ["AIDEVOPS_TEST_MODE"] = "1"
    os.environ["AIDEVOPS_SOCIAL_NOW_EPOCH"] = "1000"
    os.environ["RAW_FAULT_MODE"] = fault_mode
    try:
        _run_writer(scenario, root)
    except SocialStoreError as error:
        if fault_mode == "raise-after-durable" and "injected failure" in str(error):
            return FAULT_RAISE
        raise
    return 0


class RawEvidenceWriterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="social-raw-recovery-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)

    def _child(self, scenario: str, fault_mode: str) -> tuple[Path, subprocess.CompletedProcess[str]]:
        root = self.base / f"{scenario}-{fault_mode}"
        environment = os.environ.copy()
        environment.pop(FAULT_ENV, None)
        result = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), "--child", scenario, str(root), fault_mode],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        return root, result

    @staticmethod
    def _raw_files(root: Path) -> list[Path]:
        raw_root = root / "sources" / "social" / "raw"
        return sorted(raw_root.glob("*/*/*.json.gz")) if raw_root.exists() else []

    @staticmethod
    def _markers(root: Path) -> list[Path]:
        staging = root / "sources" / "social" / "raw" / ".staging"
        return sorted(staging.glob("*.json")) if staging.exists() else []

    @staticmethod
    def _fetch_count(root: Path) -> int:
        with sqlite3.connect(root / "index" / "social.db") as database:
            return int(database.execute("SELECT count(*) FROM fetch_batches").fetchone()[0])

    def test_every_writer_rolls_back_an_ordinary_post_durability_failure(self) -> None:
        for scenario in WRITER_SCENARIOS:
            with self.subTest(scenario=scenario):
                root, result = self._child(scenario, "raise-after-durable")
                self.assertEqual(result.returncode, FAULT_RAISE, result.stderr)
                self.assertEqual(self._fetch_count(root), 0)
                self.assertEqual(self._raw_files(root), [])
                self.assertEqual(self._markers(root), [])

    def test_killed_writers_leave_leased_orphans_then_recovery_reclaims_them(self) -> None:
        for scenario in WRITER_SCENARIOS:
            with self.subTest(scenario=scenario):
                root, result = self._child(scenario, "exit-after-durable")
                self.assertEqual(result.returncode, FAULT_EXIT, result.stderr)
                self.assertEqual(self._fetch_count(root), 0)
                raw_files = self._raw_files(root)
                markers = self._markers(root)
                self.assertEqual(len(raw_files), 1)
                self.assertEqual(len(markers), 1)
                for directory in (
                    root / "sources",
                    root / "sources" / "social",
                    root / "sources" / "social" / "raw",
                    raw_files[0].parent.parent,
                    raw_files[0].parent,
                    markers[0].parent,
                ):
                    self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
                self.assertEqual(stat.S_IMODE(raw_files[0].stat().st_mode), 0o600)
                self.assertEqual(stat.S_IMODE(markers[0].stat().st_mode), 0o600)
                database = connect(root)
                try:
                    migrate(database)
                    now = time.time()
                    protected = recover_raw_evidence(
                        database,
                        now_epoch=now,
                        grace_seconds=3600,
                    )
                    self.assertGreaterEqual(protected.protected_files, 1)
                    self.assertEqual(len(self._raw_files(root)), 1)
                    recovered = recover_raw_evidence(
                        database,
                        now_epoch=now + 3601,
                        grace_seconds=3600,
                    )
                finally:
                    database.close()
                self.assertEqual(recovered.orphan_files_removed, 1)
                self.assertEqual(recovered.markers_removed, 1)
                self.assertEqual(self._raw_files(root), [])
                self.assertEqual(self._markers(root), [])

    def test_referenced_replayed_evidence_survives_recovery(self) -> None:
        root = self.base / "referenced"
        _prepare_root(root)
        archive = _archive("xapi", "conn_replay", "acct_fault")
        payload = canonical_json(archive).encode("utf-8")
        first = import_archive_payload(root, archive, payload)
        second = import_archive_payload(root, archive, payload)
        self.assertEqual(first["batch_id"], second["batch_id"])
        database = connect(root)
        try:
            migrate(database)
            recovered = recover_raw_evidence(
                database,
                now_epoch=time.time() + 7200,
                grace_seconds=3600,
            )
        finally:
            database.close()
        self.assertEqual(recovered.orphan_files_removed, 0)
        self.assertEqual(len(self._raw_files(root)), 1)
        self.assertEqual(self._fetch_count(root), 1)

    def test_recovery_cleans_committed_markers_and_partial_staging(self) -> None:
        root = self.base / "committed-marker"
        _prepare_root(root)
        archive = _archive("xapi", "conn_committed", "acct_fault")
        payload = canonical_json(archive).encode("utf-8")
        imported = import_archive_payload(root, archive, payload)
        digest = str(imported["batch_id"])
        blob_ref = str(imported["blob_ref"])
        staging = root / "sources" / "social" / "raw" / ".staging"
        token = "2" * 32
        marker = staging / f"{token}.json"
        marker.write_text(
            json.dumps(
                {
                    "version": 1,
                    "token": token,
                    "digest": digest,
                    "blob_ref": blob_ref,
                }
            ),
            encoding="utf-8",
        )
        staged_file = staging / f"{token}.stage"
        staged_file.write_bytes(b"partial-gzip-write")
        os.chmod(marker, 0o600)
        os.chmod(staged_file, 0o600)
        database = connect(root)
        try:
            migrate(database)
            recovered = recover_raw_evidence(
                database,
                now_epoch=time.time() + 1,
                grace_seconds=0,
            )
        finally:
            database.close()
        self.assertEqual(recovered.orphan_files_removed, 0)
        self.assertEqual(recovered.staging_files_removed, 1)
        self.assertEqual(recovered.markers_removed, 1)
        self.assertEqual(len(self._raw_files(root)), 1)
        self.assertFalse(marker.exists())
        self.assertFalse(staged_file.exists())

    def test_post_commit_marker_cleanup_failure_remains_successful(self) -> None:
        root = self.base / "post-commit-cleanup"
        _prepare_root(root)
        archive = _archive("xapi", "conn_cleanup", "acct_fault")
        payload = canonical_json(archive).encode("utf-8")
        original_unlink = raw_write._unlink_private_file

        def fail_marker_unlink(path: Path) -> bool:
            if path.suffix == ".json" and path.parent.name == ".staging":
                raise SocialStoreError("injected post-commit marker cleanup failure")
            return original_unlink(path)

        with mock.patch.object(
            raw_write,
            "_unlink_private_file",
            side_effect=fail_marker_unlink,
        ):
            imported = import_archive_payload(root, archive, payload)

        self.assertEqual(self._fetch_count(root), 1)
        self.assertEqual(len(self._raw_files(root)), 1)
        self.assertEqual(len(self._markers(root)), 1)
        self.assertTrue(str(imported["blob_ref"]).endswith(".json.gz"))

        database = connect(root)
        try:
            migrate(database)
            recovered = recover_raw_evidence(
                database,
                now_epoch=time.time() + 1,
                grace_seconds=0,
            )
        finally:
            database.close()
        self.assertEqual(recovered.orphan_files_removed, 0)
        self.assertEqual(recovered.markers_removed, 1)
        self.assertEqual(self._fetch_count(root), 1)
        self.assertEqual(len(self._raw_files(root)), 1)
        self.assertEqual(self._markers(root), [])

    def test_corrupt_orphans_are_removed_but_corrupt_references_fail_closed(self) -> None:
        orphan_root = self.base / "corrupt-orphan"
        _prepare_root(orphan_root)
        database = connect(orphan_root)
        try:
            migrate(database)
            _, blob_ref = write_raw_batch(
                orphan_root, "xapi", "conn_corrupt", b"orphan"
            )
            orphan_path = orphan_root / blob_ref
            orphan_path.write_bytes(b"not-gzip")
            os.chmod(orphan_path, 0o600)
            recovered = recover_raw_evidence(
                database,
                now_epoch=time.time() + 1,
                grace_seconds=0,
            )
        finally:
            database.close()
        self.assertEqual(recovered.corrupt_files_removed, 1)
        self.assertFalse(orphan_path.exists())

        referenced_root = self.base / "corrupt-reference"
        _prepare_root(referenced_root)
        archive = _archive("xapi", "conn_reference", "acct_fault")
        payload = canonical_json(archive).encode("utf-8")
        imported = import_archive_payload(referenced_root, archive, payload)
        referenced_path = referenced_root / str(imported["blob_ref"])
        referenced_path.write_bytes(gzip.compress(b"wrong", mtime=0))
        os.chmod(referenced_path, 0o600)
        database = connect(referenced_root)
        try:
            migrate(database)
            with self.assertRaisesRegex(SocialStoreError, "hash mismatch"):
                recover_raw_evidence(database, verify_referenced=True)
        finally:
            database.close()
        self.assertTrue(referenced_path.exists())
        self.assertEqual(self._fetch_count(referenced_root), 1)

    def test_symlinked_and_path_escape_staging_fail_closed(self) -> None:
        symlink_root = self.base / "symlink"
        _prepare_root(symlink_root)
        database = connect(symlink_root)
        try:
            migrate(database)
            _, blob_ref = write_raw_batch(
                symlink_root, "xapi", "conn_symlink", b"symlink"
            )
            raw_path = symlink_root / blob_ref
            staging = symlink_root / "sources" / "social" / "raw" / ".staging"
            symlink = staging / f"{'0' * 32}.stage"
            symlink.symlink_to(raw_path)
            with self.assertRaisesRegex(SocialStoreError, "symlink"):
                recover_raw_evidence(
                    database,
                    now_epoch=time.time() + 7200,
                    grace_seconds=3600,
                )
        finally:
            database.close()
        self.assertTrue(symlink.is_symlink())
        self.assertTrue(raw_path.exists())

        escape_root = self.base / "path-escape"
        _prepare_root(escape_root)
        database = connect(escape_root)
        try:
            migrate(database)
            digest, blob_ref = write_raw_batch(
                escape_root, "xapi", "conn_escape", b"escape"
            )
            raw_path = escape_root / blob_ref
            staging = escape_root / "sources" / "social" / "raw" / ".staging"
            token = "1" * 32
            marker = staging / f"{token}.json"
            marker.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "token": token,
                        "digest": digest,
                        "blob_ref": "../../outside.json.gz",
                    }
                ),
                encoding="utf-8",
            )
            os.chmod(marker, 0o600)
            with self.assertRaises(SocialStoreError):
                recover_raw_evidence(
                    database,
                    now_epoch=time.time() + 7200,
                    grace_seconds=3600,
                )
        finally:
            database.close()
        self.assertTrue(marker.exists())
        self.assertTrue(raw_path.exists())

    def test_production_writers_use_only_the_shared_lifecycle(self) -> None:
        writers = (
            "_knowledge_social_collect_persist.py",
            "_knowledge_social_reconcile.py",
            "knowledge_social_import.py",
            "_knowledge_social_medium.py",
            "_knowledge_social_slack_persist.py",
            "_knowledge_social_whatsapp.py",
            "_knowledge_social_share_data.py",
        )
        for filename in writers:
            with self.subTest(filename=filename):
                source = (SCRIPT_DIRECTORY / filename).read_text(encoding="utf-8")
                self.assertIn("raw_evidence_transaction", source)
                self.assertNotIn("write_raw_batch(", source)


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "--child":
        raise SystemExit(_child_main(sys.argv[2:]))
    unittest.main(verbosity=2)
