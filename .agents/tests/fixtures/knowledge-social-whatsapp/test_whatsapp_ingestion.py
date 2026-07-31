#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fixture-backed tests for safe WhatsApp ingestion."""

from __future__ import annotations

import ast
import base64
import hashlib
import hmac
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
import zipfile
from contextlib import ExitStack, contextmanager, redirect_stdout
from dataclasses import replace
from pathlib import Path
from typing import Iterator
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[3] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from _knowledge_social_lease import (  # noqa: E402
    RunLeaseRequest,
    acquire_run_lease,
    release_run_lease,
)
from _knowledge_social_whatsapp import persist_batch  # noqa: E402
from _knowledge_social_whatsapp_export import ExportRequest, parse_export  # noqa: E402
from _knowledge_social_whatsapp_webhook import (  # noqa: E402
    WebhookRequest,
    parse_business_webhook as parse_webhook_request,
)
from knowledge_social_store import SocialStoreError  # noqa: E402
from knowledge_social_whatsapp import main as whatsapp_main  # noqa: E402

OBSERVED_AT = "2026-07-28T08:30:00Z"
APP_SECRET = b"fixture-secret-not-a-real-credential"


def parse_business_webhook(
    payload: bytes,
    signature: str,
    app_secret: bytes,
    connection_id: str,
    expected_waba_id: str,
    expected_phone_number_id: str,
    observed_at: str,
):
    return parse_webhook_request(WebhookRequest(
        payload, signature, app_secret, connection_id,
        expected_waba_id, expected_phone_number_id, observed_at,
    ))


def write_zip(path: Path, transcript: str, media: dict[str, bytes] | None = None) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("WhatsApp Chat.txt", transcript)
        for name, payload in (media or {}).items():
            archive.writestr(name, payload)


def export_request(path: Path, connection: str = "conn_export") -> ExportRequest:
    return ExportRequest(
        path,
        connection,
        "conversation_fixture",
        "android-us-12h",
        "+01:00",
        OBSERVED_AT,
        16 * 1024 * 1024,
        100,
        30,
    )


def assert_isolated_imports(test: unittest.TestCase, target: Path) -> None:
    tree = ast.parse(target.read_text(encoding="utf-8"))
    imports = {
        alias.name
        for node in ast.walk(tree)
        if isinstance(node, ast.Import)
        for alias in node.names
    }
    imports.update(node.module or "" for node in ast.walk(tree) if isinstance(node, ast.ImportFrom))
    test.assertNotIn("subprocess", imports)
    test.assertNotIn("socket", imports)
    test.assertFalse(any(name.startswith(("urllib", "requests", "httpx")) for name in imports))
    test.assertNotIn("knowledge_social_browser", imports)
    test.assertNotIn("_knowledge_social_outbound", imports)


def blocked_api(*_args, **_kwargs):
    raise AssertionError("network or subprocess execution attempted")


@contextmanager
def blocked_runtime_apis() -> Iterator[None]:
    targets = (
        "socket.socket", "subprocess.Popen", "subprocess.call", "subprocess.run",
        "subprocess.check_call", "subprocess.check_output", "os.system", "os.popen",
        "os.spawnv", "os.spawnve",
    )
    with ExitStack() as stack:
        for target in targets:
            stack.enter_context(mock.patch(target, side_effect=blocked_api))
        yield


def runtime_paths(temporary: str) -> tuple[Path, Path, bytes, str, Path]:
    transcript = Path(temporary) / "chat.txt"
    transcript.write_text("7/28/26, 8:01 AM - Alpha: Runtime isolated\n", encoding="utf-8")
    payload_path = Path(temporary) / "webhook.json"
    payload = webhook_payload()
    payload_path.write_bytes(payload)
    signature = "sha256=" + hmac.new(APP_SECRET, payload, hashlib.sha256).hexdigest()
    corpus = Path(temporary) / "corpus"
    corpus.mkdir(mode=0o700)
    return transcript, payload_path, payload, signature, corpus


def persist_runtime_export(corpus: Path, transcript: Path):
    parsed, raw = parse_export(export_request(transcript))
    lease = acquire_run_lease(
        corpus,
        RunLeaseRequest(
            "conn_export", "export", "runtime_persist", "sync", 300, parsed.manifest_sha256
        ),
    )
    persisted = persist_batch(corpus, parsed, raw, lease)
    release_run_lease(corpus, lease)
    return parsed, persisted


def run_export_cli(transcript: Path) -> None:
    arguments = [
        "knowledge_social_whatsapp.py", "export", "--archive", str(transcript),
        "--connection-id", "conn_cli_export", "--conversation-id", "conversation_cli_export",
        "--format", "android-us-12h", "--timezone", "+01:00", "--observed-at", OBSERVED_AT,
        "--dry-run",
    ]
    with mock.patch.object(sys, "argv", arguments), redirect_stdout(io.StringIO()):
        if whatsapp_main() != 0:
            raise AssertionError("export CLI failed")


def run_webhook_cli(payload_path: Path, signature: str) -> None:
    arguments = [
        "knowledge_social_whatsapp.py", "webhook", "--payload", str(payload_path),
        "--connection-id", "conn_cli_webhook", "--waba-id", "waba_fixture",
        "--phone-number-id", "phone_fixture", "--observed-at", OBSERVED_AT, "--dry-run",
    ]
    environment = {
        "WHATSAPP_APP_SECRET": APP_SECRET.decode(),
        "WHATSAPP_WEBHOOK_SIGNATURE": signature,
    }
    with (
        mock.patch.object(sys, "argv", arguments),
        mock.patch.dict(os.environ, environment),
        redirect_stdout(io.StringIO()),
    ):
        if whatsapp_main() != 0:
            raise AssertionError("webhook CLI failed")


def webhook_payload(waba: str = "waba_fixture", phone: str = "phone_fixture") -> bytes:
    value = {
        "messaging_product": "whatsapp",
        "metadata": {"display_phone_number": "000000", "phone_number_id": phone},
        "messages": [
            {"from": "contact_alpha", "id": "wamid.fixture.text", "timestamp": "1785225660", "text": {"body": "Hello"}, "type": "text"},
            {"from": "contact_beta", "id": "wamid.fixture.reply", "timestamp": "1785225720", "context": {"id": "wamid.fixture.text"}, "text": {"body": "Reply"}, "type": "text"},
            {"from": "contact_alpha", "id": "wamid.fixture.react", "timestamp": "1785225780", "reaction": {"message_id": "wamid.fixture.text", "emoji": "+1"}, "type": "reaction"},
            {"from": "contact_beta", "id": "wamid.fixture.media", "timestamp": "1785225840", "image": {"id": "media_fixture", "mime_type": "image/jpeg", "sha256": base64.b64encode(b"a" * 32).decode(), "caption": "Fixture image"}, "type": "image"},
        ],
        "statuses": [
            {"id": "wamid.fixture.text", "recipient_id": "contact_alpha", "status": "delivered", "timestamp": "1785225900"}
        ],
    }
    root = {"object": "whatsapp_business_account", "entry": [{"id": waba, "changes": [{"field": "messages", "value": value}]}]}
    return json.dumps(root, separators=(",", ":"), sort_keys=True).encode()


def signed_webhook(payload: bytes, connection: str = "conn_webhook"):
    signature = "sha256=" + hmac.new(APP_SECRET, payload, hashlib.sha256).hexdigest()
    return parse_business_webhook(
        payload,
        signature,
        APP_SECRET,
        connection,
        "waba_fixture",
        "phone_fixture",
        OBSERVED_AT,
    )


class WhatsAppExportTests(unittest.TestCase):
    def test_export_parses_multiline_media_aliases_and_duplicate_occurrences(self) -> None:
        transcript = "\n".join(
            (
                "7/28/26, 8:01 AM - Alpha: First line",
                "continued line",
                "7/28/26, 8:02 AM - Beta: fixture.jpg (file attached)",
                "7/28/26, 8:03 AM - Alpha: repeated",
                "7/28/26, 8:03 AM - Alpha: repeated",
            )
        )
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "export.zip"
            write_zip(archive, transcript, {"fixture.jpg": b"synthetic-image"})
            parsed, raw = parse_export(export_request(archive))
        self.assertEqual(hashlib.sha256(raw).hexdigest(), parsed.raw_sha256)
        self.assertEqual(4, len(parsed.archive["objects"]))
        self.assertEqual(2, len(parsed.archive["accounts"]))
        self.assertEqual(1, len(parsed.archive["media"]))
        self.assertTrue(
            any("continued line" in record["text"] for record in parsed.archive["objects"])
        )
        ids = {record["remote_id"] for record in parsed.archive["objects"]}
        self.assertEqual(4, len(ids))
        media = parsed.archive["media"][0]
        self.assertEqual("embedded_in_raw_archive", media["hydration_state"])
        self.assertEqual(hashlib.sha256(b"synthetic-image").hexdigest(), media["content_sha256"])
        coverage = {record["stream"]: record for record in parsed.archive["coverage"]}
        self.assertEqual("partial", coverage["timestamps"]["status"])

    def test_explicit_dmy_format_and_offset_are_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            transcript = Path(temporary) / "chat.txt"
            transcript.write_text("28/07/2026, 08:01 - Alpha: Local time\n", encoding="utf-8")
            request = ExportRequest(
                transcript,
                "conn_dmy",
                "conversation_dmy",
                "android-dmy-24h",
                "-04:00",
                OBSERVED_AT,
                4096,
                10,
                30,
            )
            parsed, _raw = parse_export(request)
        self.assertEqual("2026-07-28T08:01:00-04:00", parsed.archive["objects"][0]["created_at"])

    def test_missing_media_is_explicit_partial_coverage(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "export.zip"
            write_zip(archive, "7/28/26, 8:01 AM - Alpha: absent.jpg (file attached)")
            parsed, _raw = parse_export(export_request(archive))
        coverage = {record["stream"]: record for record in parsed.archive["coverage"]}
        self.assertEqual("partial", coverage["attachments"]["status"])
        self.assertEqual("unavailable", coverage["reactions"]["status"])
        self.assertEqual("unavailable", coverage["history_before_export_window"]["status"])

    def test_malformed_format_and_archive_paths_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            transcript = root / "chat.txt"
            transcript.write_text("28/07/2026, 08:01 - Alpha: Wrong selected locale\n", encoding="utf-8")
            with self.assertRaises(SocialStoreError):
                parse_export(export_request(transcript))
            archive = root / "unsafe.zip"
            with zipfile.ZipFile(archive, "w") as target:
                target.writestr("../WhatsApp Chat.txt", "7/28/26, 8:01 AM - Alpha: Unsafe")
            with self.assertRaises(SocialStoreError):
                parse_export(export_request(archive))

    def test_mixed_timestamp_profiles_fail_instead_of_becoming_message_text(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            transcript = Path(temporary) / "chat.txt"
            transcript.write_text(
                "7/28/26, 8:01 AM - Alpha: First\n"
                "28/07/2026, 08:02 - Beta: Mixed locale\n",
                encoding="utf-8",
            )
            with self.assertRaises(SocialStoreError):
                parse_export(export_request(transcript))

    def test_aliases_are_conversation_scoped_and_attribution_is_observed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            transcript = Path(temporary) / "chat.txt"
            transcript.write_text(
                "7/28/26, 8:01 AM - Alpha: Setting changed: fixture value\n",
                encoding="utf-8",
            )
            first, _raw = parse_export(export_request(transcript))
            second_request = replace(
                export_request(transcript, "conn_other"),
                conversation_id="conversation_other",
            )
            second, _raw = parse_export(second_request)
        self.assertNotEqual(
            first.archive["accounts"][0]["remote_id"],
            second.archive["accounts"][0]["remote_id"],
        )
        self.assertEqual("observed", first.archive["objects"][0]["evidence_class"])
        self.assertEqual(
            "syntactic_alias_unverified",
            first.archive["objects"][0]["provider_json"]["attribution_status"],
        )

    def test_high_compression_ratio_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "compressed.zip"
            write_zip(
                archive,
                "7/28/26, 8:01 AM - Alpha: compressed.bin (file attached)",
                {"compressed.bin": b"x" * (2 * 1024 * 1024)},
            )
            with self.assertRaises(SocialStoreError):
                parse_export(export_request(archive))

    def test_zip_member_and_elapsed_time_budgets_fail_before_parsing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "budget.zip"
            write_zip(
                archive,
                "7/28/26, 8:01 AM - Alpha: fixture.txt (file attached)",
                {"fixture.txt": b"fixture"},
            )
            with self.assertRaises(SocialStoreError):
                parse_export(replace(export_request(archive), max_items=1))
            with (
                mock.patch(
                    "_knowledge_social_whatsapp_export.time.monotonic",
                    side_effect=[0.0, 2.0],
                ),
                self.assertRaises(SocialStoreError),
            ):
                parse_export(replace(export_request(archive), max_seconds=1))

    def test_cli_dry_run_reports_plan_without_provisioning_a_corpus(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            transcript = Path(temporary) / "chat.txt"
            transcript.write_text(
                "7/28/26, 8:01 AM - Alpha: Planned only\n", encoding="utf-8"
            )
            arguments = [
                str(SCRIPTS / "knowledge_social_whatsapp.py"), "export",
                "--archive", str(transcript), "--connection-id", "conn_plan",
                "--conversation-id", "conversation_plan", "--format",
                "android-us-12h", "--timezone", "+01:00", "--observed-at",
                OBSERVED_AT, "--dry-run",
            ]
            output = io.StringIO()
            with mock.patch.object(sys, "argv", arguments), redirect_stdout(output):
                self.assertEqual(0, whatsapp_main())
        result = json.loads(output.getvalue())
        self.assertEqual(("planned", True, 1), (result["status"], result["dry_run"], result["objects"]))


class WhatsAppWebhookTests(unittest.TestCase):
    def test_verified_webhook_normalizes_messages_replies_reactions_media_and_status(self) -> None:
        payload = webhook_payload()
        parsed = signed_webhook(payload)
        archive = parsed.archive
        self.assertEqual(4, len(archive["objects"]))
        self.assertEqual(2, len(archive["activities"]))
        self.assertEqual(1, len(archive["media"]))
        self.assertIsNone(archive["media"][0]["content_sha256"])
        media_object = next(
            record for record in archive["objects"] if record["remote_id"] == "wamid.fixture.media"
        )
        self.assertIn("provider_media_sha256_b64", media_object["provider_json"])
        reply = next(record for record in archive["objects"] if record["remote_id"] == "wamid.fixture.reply")
        self.assertEqual("wamid.fixture.text", reply["provider_json"]["reply_to_message_id"])
        reaction = next(record for record in archive["activities"] if record["activity_type"] == "reaction")
        self.assertEqual("wamid.fixture.text", reaction["object_remote_id"])
        coverage = {record["stream"]: record["status"] for record in archive["coverage"]}
        self.assertEqual("unavailable", coverage["history_before_connection"])
        self.assertEqual("unavailable", coverage["personal_and_existing_group_history"])
        signature = "sha256=" + hmac.new(APP_SECRET, payload, hashlib.sha256).hexdigest()
        retry = parse_business_webhook(
            payload,
            signature,
            APP_SECRET,
            "conn_webhook",
            "waba_fixture",
            "phone_fixture",
            "2026-07-28T08:31:00Z",
        )
        self.assertEqual(parsed.manifest_sha256, retry.manifest_sha256)

    def test_signature_and_bound_identities_fail_closed(self) -> None:
        payload = webhook_payload()
        with self.assertRaises(SocialStoreError):
            parse_business_webhook(payload, "sha256=" + "0" * 64, APP_SECRET, "conn_bad", "waba_fixture", "phone_fixture", OBSERVED_AT)
        mismatched = webhook_payload(waba="other_waba")
        signature = "sha256=" + hmac.new(APP_SECRET, mismatched, hashlib.sha256).hexdigest()
        with self.assertRaises(SocialStoreError):
            parse_business_webhook(mismatched, signature, APP_SECRET, "conn_bad", "waba_fixture", "phone_fixture", OBSERVED_AT)

    def test_malformed_context_and_typed_bodies_fail_closed(self) -> None:
        for mutation in ("context", "media", "reaction"):
            decoded = json.loads(webhook_payload())
            messages = decoded["entry"][0]["changes"][0]["value"]["messages"]
            if mutation == "context":
                messages[1]["context"] = ""
            elif mutation == "media":
                messages[3].pop("image")
            else:
                messages[2]["reaction"]["emoji"] = 1
            payload = json.dumps(decoded, separators=(",", ":"), sort_keys=True).encode()
            signature = "sha256=" + hmac.new(APP_SECRET, payload, hashlib.sha256).hexdigest()
            with self.assertRaises(SocialStoreError):
                parse_business_webhook(
                    payload,
                    signature,
                    APP_SECRET,
                    "conn_malformed",
                    "waba_fixture",
                    "phone_fixture",
                    OBSERVED_AT,
                )

    def test_identity_failures_do_not_echo_private_values(self) -> None:
        private_marker = "private-waba-marker"
        payload = webhook_payload(waba=private_marker)
        signature = "sha256=" + hmac.new(APP_SECRET, payload, hashlib.sha256).hexdigest()
        with self.assertRaises(SocialStoreError) as raised:
            parse_business_webhook(
                payload,
                signature,
                APP_SECRET,
                "conn_private",
                "waba_fixture",
                "phone_fixture",
                OBSERVED_AT,
            )
        self.assertNotIn(private_marker, str(raised.exception))
        mismatched = webhook_payload(phone="other_phone")
        signature = "sha256=" + hmac.new(APP_SECRET, mismatched, hashlib.sha256).hexdigest()
        with self.assertRaises(SocialStoreError):
            parse_business_webhook(mismatched, signature, APP_SECRET, "conn_bad", "waba_fixture", "phone_fixture", OBSERVED_AT)


class WhatsAppPersistenceTests(unittest.TestCase):
    def setUp(self) -> None:
        os.environ["AIDEVOPS_TEST_MODE"] = "1"

    def test_export_persistence_is_atomic_and_replay_safe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "corpus"
            root.mkdir(mode=0o700)
            archive = base / "export.zip"
            write_zip(archive, "7/28/26, 8:01 AM - Alpha: Durable\n")
            parsed, payload = parse_export(export_request(archive))
            first = acquire_run_lease(root, RunLeaseRequest("conn_export", "export", "fixture_first", "sync", 300, parsed.manifest_sha256))
            first_result = persist_batch(root, parsed, payload, first)
            release_run_lease(root, first)
            second = acquire_run_lease(root, RunLeaseRequest("conn_export", "export", "fixture_second", "sync", 300, parsed.manifest_sha256))
            second_result = persist_batch(root, parsed, payload, second)
            release_run_lease(root, second)
            changed, _payload = parse_export(
                replace(export_request(archive), timezone_name="+02:00")
            )
            revision = acquire_run_lease(
                root,
                RunLeaseRequest(
                    "conn_export",
                    "export",
                    "fixture_revision",
                    "sync",
                    300,
                    changed.manifest_sha256,
                ),
            )
            revision_result = persist_batch(root, changed, payload, revision)
            release_run_lease(root, revision)
            with sqlite3.connect(root / "index" / "social.db") as database:
                object_count = database.execute("SELECT count(*) FROM objects WHERE provider='whatsapp'").fetchone()[0]
                batch_count = database.execute("SELECT count(*) FROM fetch_batches WHERE provider='whatsapp'").fetchone()[0]
            raw_count = len(list((root / "sources" / "social" / "raw" / "whatsapp" / "conn_export").glob("*.json.gz")))
        self.assertFalse(first_result["replayed"])
        self.assertTrue(second_result["replayed"])
        self.assertFalse(revision_result["replayed"])
        self.assertEqual((2, 2, 1), (object_count, batch_count, raw_count))

    def test_export_and_webhook_use_separate_streams(self) -> None:
        parsed = signed_webhook(webhook_payload())
        self.assertEqual("business_webhook", parsed.stream)
        self.assertFalse(any(record["stream"] == "history_before_connection" and record["cursor_exhausted"] for record in parsed.archive["coverage"]))


class WhatsAppIsolationTests(unittest.TestCase):
    def test_collector_has_no_network_outbound_or_subprocess_reachability(self) -> None:
        targets = list(SCRIPTS.glob("*knowledge_social_whatsapp*.py"))
        self.assertGreaterEqual(len(targets), 5)
        for target in targets:
            assert_isolated_imports(self, target)

    def test_runtime_collector_cannot_reach_network_or_process_apis(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            transcript, payload_path, _payload, signature, corpus = runtime_paths(temporary)
            with blocked_runtime_apis():
                webhook = signed_webhook(webhook_payload(), "conn_runtime")
                parsed, persisted = persist_runtime_export(corpus, transcript)
                run_export_cli(transcript)
                run_webhook_cli(payload_path, signature)
        self.assertEqual((1, 4), (len(parsed.archive["objects"]), len(webhook.archive["objects"])))
        self.assertEqual("complete", persisted["status"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
