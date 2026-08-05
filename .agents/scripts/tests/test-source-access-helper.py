#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HELPER_PATH = Path(__file__).resolve().parents[1] / "source-access-helper.py"
SPEC = importlib.util.spec_from_file_location("source_access_helper", HELPER_PATH)
assert SPEC and SPEC.loader
HELPER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = HELPER
SPEC.loader.exec_module(HELPER)


class SourceAccessHelperTests(unittest.TestCase):
    def setUp(self) -> None:
        temp_parent = Path(
            os.environ.get(
                "AIDEVOPS_TEMP_DIR",
                Path.home() / ".aidevops" / ".agent-workspace" / "tmp",
            )
        )
        temp_parent.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(
            prefix="aidevops-source-access-test-",
            dir=temp_parent,
        )
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "-C", str(self.repo), "init", "--quiet"], check=True)
        self.source = self.repo / "secret-helper.sh"
        self.other_source = self.repo / "secret-other.sh"
        self.source.write_text("#!/usr/bin/env bash\nprintf synthetic\\n\n", encoding="utf-8")
        self.other_source.write_text("#!/usr/bin/env bash\nprintf other\\n\n", encoding="utf-8")
        subprocess.run(
            ["git", "-C", str(self.repo), "add", self.source.name, self.other_source.name],
            check=True,
        )
        self.uid = os.getuid()
        self.home = self.root / "home"
        self.home.mkdir()
        self.config = HELPER.Config(
            config_dir=self.root / "system-config",
            state_dir=self.root / "system-state",
            request_root=self.root / "requests",
            signing_key=self.root / "approval-private" / "approval.key",
            trust_uid=self.uid,
        )
        self.config.private_key.parent.mkdir(mode=0o700)
        subprocess.run(
            [
                HELPER.SSH_KEYGEN,
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                "aidevops-approval-signing",
                "-f",
                str(self.config.private_key),
            ],
            check=True,
        )
        HELPER.setup_key_material(self.config)
        self.session = "ses_fixture_123456"
        self.now = 1_800_000_000

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _request(self, path: Path | None = None) -> str:
        return HELPER.create_request(
            self.config,
            session_id=self.session,
            uid=self.uid,
            home=self.home,
            path=str(path or self.source),
            reason=HELPER.OVERRIDABLE_REASON,
            now=self.now,
        )

    def _approve(self, request_id: str | None = None) -> dict[str, object]:
        return HELPER.approve_request(
            self.config,
            request_id=request_id or self._request(),
            home=self.home,
            expected_uid=self.uid,
            ttl_seconds=HELPER.MAX_TTL_SECONDS,
            now=self.now,
            confirm=lambda _request: True,
        )

    def _verify(self, **overrides: object) -> bool:
        arguments = {
            "session_id": self.session,
            "uid": self.uid,
            "path": str(self.source),
            "reason": HELPER.OVERRIDABLE_REASON,
            "now": self.now + 1,
        }
        arguments.update(overrides)
        return HELPER.verify_approval(self.config, **arguments)

    def test_exact_signed_scope_verifies(self) -> None:
        payload = self._approve()
        self.assertTrue(self._verify())
        self.assertEqual(payload["expires_at"], self.now + HELPER.MAX_TTL_SECONDS)
        snapshot_path = Path(str(payload["snapshot_path"]))
        self.assertEqual(snapshot_path.read_bytes(), self.source.read_bytes())
        self.assertEqual(snapshot_path.stat().st_mode & 0o777, 0o444)

    def test_request_is_reused_for_the_same_scope(self) -> None:
        first = self._request()
        second = self._request()
        self.assertEqual(first, second)

    def test_cross_session_user_path_and_reason_fail_closed(self) -> None:
        self._approve()
        self.assertFalse(self._verify(session_id="ses_other_123456"))
        self.assertFalse(self._verify(uid=self.uid + 1))
        self.assertFalse(self._verify(path=str(self.other_source)))
        self.assertFalse(self._verify(reason="private key path"))

    def test_expired_and_future_receipts_fail_closed(self) -> None:
        self._approve()
        self.assertFalse(self._verify(now=self.now + HELPER.MAX_TTL_SECONDS))
        self.assertFalse(self._verify(now=self.now - 1))

    def test_source_content_change_invalidates_approval(self) -> None:
        self._approve()
        self.source.write_text("changed\n", encoding="utf-8")
        self.assertFalse(self._verify())

    def test_tampered_receipt_fails_signature_verification(self) -> None:
        payload = self._approve()
        receipt_path = (
            self.config.state_dir
            / "approvals"
            / str(self.uid)
            / f"{payload['approval_id']}.json"
        )
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["payload"]["expires_at"] += 60
        receipt_path.write_bytes(HELPER.canonical_json(receipt) + b"\n")
        self.assertFalse(self._verify())

    def test_revocation_is_immediate(self) -> None:
        payload = self._approve()
        self.assertTrue(self._verify())
        HELPER.revoke_approval(
            self.config,
            approval_id=str(payload["approval_id"]),
            uid=self.uid,
        )
        self.assertFalse(self._verify())
        self.assertFalse(Path(str(payload["snapshot_path"])).exists())

    def test_untracked_symlink_and_credential_like_paths_are_denied(self) -> None:
        untracked = self.repo / "secret-untracked.sh"
        untracked.write_text("synthetic\n", encoding="utf-8")
        with self.assertRaisesRegex(HELPER.SourceAccessError, "Git-tracked"):
            self._request(untracked)

        link = self.repo / "secret-link.sh"
        link.symlink_to(self.source)
        subprocess.run(["git", "-C", str(self.repo), "add", link.name], check=True)
        with self.assertRaisesRegex(HELPER.SourceAccessError, "symlinked"):
            self._request(link)

        credential_like = self.repo / ".env-secret.sh"
        credential_like.write_text("synthetic\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.repo), "add", credential_like.name], check=True)
        with self.assertRaisesRegex(HELPER.SourceAccessError, "credential-like"):
            self._request(credential_like)

        private_key = self.repo / "secret-private.pem"
        private_key.write_text("synthetic\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.repo), "add", private_key.name], check=True)
        with self.assertRaisesRegex(HELPER.SourceAccessError, "private key"):
            self._request(private_key)

        credential_store = self.repo / "credentials.json"
        credential_store.write_text("{}\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.repo), "add", credential_store.name], check=True)
        with self.assertRaisesRegex(HELPER.SourceAccessError, "credential-like"):
            self._request(credential_store)

        hard_link = self.repo / "secret-hard-link.sh"
        os.link(self.source, hard_link)
        subprocess.run(["git", "-C", str(self.repo), "add", hard_link.name], check=True)
        hard_link_request = self._request(hard_link)
        with self.assertRaisesRegex(HELPER.SourceAccessError, "hard-linked"):
            self._approve(hard_link_request)

    def test_ttl_parser_enforces_twelve_hour_maximum(self) -> None:
        self.assertEqual(HELPER.parse_ttl("12h"), HELPER.MAX_TTL_SECONDS)
        self.assertEqual(HELPER.parse_ttl("30m"), 1800)
        with self.assertRaisesRegex(HELPER.SourceAccessError, "12 hours"):
            HELPER.parse_ttl("13h")

    def test_approval_rejects_unsafe_or_malformed_request_files(self) -> None:
        request_id = self._request()
        request_path = self.config.request_root / f"{request_id}.json"
        request = json.loads(request_path.read_text(encoding="utf-8"))
        request["created_at"] = "not-an-epoch"
        request_path.write_bytes(HELPER.canonical_json(request) + b"\n")
        with self.assertRaisesRegex(HELPER.SourceAccessError, "timestamp is invalid"):
            self._approve(request_id)

        request_path.chmod(0o666)
        with self.assertRaisesRegex(HELPER.SourceAccessError, "permissions are unsafe"):
            self._approve(request_id)

    def test_malformed_receipt_fails_closed(self) -> None:
        payload = self._approve()
        receipt_path = (
            self.config.state_dir
            / "approvals"
            / str(self.uid)
            / f"{payload['approval_id']}.json"
        )
        receipt_path.write_text("{", encoding="utf-8")
        self.assertFalse(self._verify())

    def test_root_and_interactive_terminal_are_required(self) -> None:
        with mock.patch.object(HELPER.os, "geteuid", return_value=1000):
            with self.assertRaisesRegex(HELPER.SourceAccessError, "root-owned"):
                HELPER._require_root_tty(self.config)
        fake_stdin = mock.Mock()
        fake_stdin.isatty.return_value = False
        with mock.patch.object(HELPER.os, "geteuid", return_value=0), mock.patch.object(
            HELPER.sys, "stdin", fake_stdin
        ):
            with self.assertRaisesRegex(HELPER.SourceAccessError, "interactive terminal"):
                HELPER._require_root_tty(self.config)

        fake_stdin.isatty.return_value = True
        with mock.patch.object(HELPER.os, "geteuid", return_value=0), mock.patch.object(
            HELPER.sys, "stdin", fake_stdin
        ):
            with self.assertRaisesRegex(HELPER.SourceAccessError, "root-owned source-access broker"):
                HELPER._require_root_tty(self.config)


if __name__ == "__main__":
    unittest.main()
