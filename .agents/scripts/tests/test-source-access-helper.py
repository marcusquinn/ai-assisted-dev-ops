#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from __future__ import annotations

import importlib.util
import json
import os
import py_compile
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS_DIR = Path(__file__).resolve().parents[1]
HELPER_PATH = SCRIPTS_DIR / "source-access-helper.py"
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
        subprocess.run(  # nosec B603 -- fixed Git binary and local fixture path
            ["/usr/bin/git", "-C", str(self.repo), "init", "--quiet"], check=True
        )
        self.source = self.repo / "secret-helper.sh"
        self.other_source = self.repo / "secret-other.sh"
        self.third_source = self.repo / "secret-third.sh"
        self.source.write_text("#!/usr/bin/env bash\nprintf synthetic\\n\n", encoding="utf-8")
        self.other_source.write_text("#!/usr/bin/env bash\nprintf other\\n\n", encoding="utf-8")
        self.third_source.write_text("#!/usr/bin/env bash\nprintf third\\n\n", encoding="utf-8")
        subprocess.run(  # nosec B603 -- fixed Git binary and local fixture paths
            [
                "/usr/bin/git",
                "-C",
                str(self.repo),
                "add",
                self.source.name,
                self.other_source.name,
                self.third_source.name,
            ],
            check=True,
        )
        self.uid = os.getuid()
        self.home = self.root / "home"
        self.home.mkdir()
        self.config = HELPER.Config(
            config_dir=self.root / "system-config",
            state_dir=self.root / "system-state",
            request_root=self.root / "requests",
            trust_uid=self.uid,
        )
        self.config.private_key.parent.mkdir(parents=True, mode=0o700)
        subprocess.run(
            [
                HELPER.SSH_KEYGEN,
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                "aidevops-source-access-signing",
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
            HELPER.RequestSpec(
                session_id=self.session,
                uid=self.uid,
                home=self.home,
                path=str(path or self.source),
                reason=HELPER.OVERRIDABLE_REASON,
                now=self.now,
            ),
        )

    def _approve(self, request_id: str | None = None) -> dict[str, object]:
        return HELPER.approve_request(
            self.config,
            HELPER.ApprovalSpec(
                request_id=request_id or self._request(),
                home=self.home,
                expected_uid=self.uid,
                ttl_seconds=HELPER.MAX_TTL_SECONDS,
                now=self.now,
                confirm=lambda _request: True,
            ),
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
        return HELPER.verify_approval(self.config, HELPER.VerificationSpec(**arguments))

    def test_exact_signed_scope_verifies(self) -> None:
        payload = self._approve()
        self.assertTrue(self._verify())
        self.assertEqual(payload["expires_at"], self.now + HELPER.MAX_TTL_SECONDS)
        snapshot_path = Path(str(payload["snapshot_path"]))
        self.assertEqual(snapshot_path.read_bytes(), self.source.read_bytes())
        self.assertEqual(snapshot_path.stat().st_mode & 0o777, 0o444)

    def _confirmation_request(self, manifest: bool) -> str:
        if not manifest:
            return self._request()
        return HELPER.create_manifest_request(
            self.config,
            HELPER.ManifestRequestSpec(
                self.session, self.uid, self.home,
                (str(self.source), str(self.other_source)),
                HELPER.OVERRIDABLE_REASON, self.now,
            ),
        )

    def test_grant_lifetime_starts_at_human_confirmation(self) -> None:
        for manifest in (False, True):
            with self.subTest(manifest=manifest):
                request_id = self._confirmation_request(manifest)
                confirmed_at = self.now + 7 * 24 * 60 * 60
                with mock.patch.object(HELPER.time, "time", return_value=self.now) as clock:
                    def confirm(_request: dict[str, object]) -> bool:
                        clock.return_value = confirmed_at
                        return True

                    payload = HELPER.approve_request(
                        self.config,
                        HELPER.ApprovalSpec(
                            request_id, self.home, self.uid, HELPER.MAX_TTL_SECONDS,
                            confirm=confirm,
                        ),
                    )
                self.assertEqual(payload["issued_at"], confirmed_at)
                self.assertEqual(payload["expires_at"], confirmed_at + HELPER.MAX_TTL_SECONDS)
                self.assertTrue(self._verify(now=confirmed_at + 1))
                self.assertFalse(self._verify(now=confirmed_at + HELPER.MAX_TTL_SECONDS))

    def test_confirmation_cancellation_and_clock_rollback_do_not_sign(self) -> None:
        for manifest in (False, True):
            for accepted in (False, True):
                with self.subTest(manifest=manifest, accepted=accepted):
                    request_id = self._confirmation_request(manifest)
                    with mock.patch.object(HELPER.time, "time", return_value=self.now) as clock:
                        def confirm(_request: dict[str, object]) -> bool:
                            clock.return_value = self.now - 1
                            return accepted

                        message = "clock moved backwards" if accepted else "approval cancelled"
                        with mock.patch.object(HELPER, "_sign_payload") as sign:
                            with self.assertRaisesRegex(HELPER.SourceAccessError, message):
                                HELPER.approve_request(
                                    self.config,
                                    HELPER.ApprovalSpec(
                                        request_id, self.home, self.uid, HELPER.MAX_TTL_SECONDS,
                                        confirm=confirm,
                                    ),
                                )
                            sign.assert_not_called()
                    self.assertFalse(self._verify())
                    self.assertFalse((self.config.state_dir / "snapshots").exists())

    def test_one_manifest_approves_three_exact_paths_with_one_confirmation(self) -> None:
        request_id = HELPER.create_manifest_request(
            self.config,
            HELPER.ManifestRequestSpec(
                session_id=self.session,
                uid=self.uid,
                home=self.home,
                paths=(str(self.third_source), str(self.source), str(self.other_source)),
                reason=HELPER.OVERRIDABLE_REASON,
                now=self.now,
            ),
        )
        confirmations = 0

        def confirm(request: dict[str, object]) -> bool:
            nonlocal confirmations
            confirmations += 1
            self.assertEqual(len(request["entries"]), 3)  # type: ignore[arg-type]
            return True

        payload = HELPER.approve_request(
            self.config,
            HELPER.ApprovalSpec(
                request_id=request_id,
                home=self.home,
                expected_uid=self.uid,
                ttl_seconds=HELPER.MAX_TTL_SECONDS,
                now=self.now,
                confirm=confirm,
            ),
        )
        self.assertEqual(confirmations, 1)
        self.assertEqual(len(payload["entries"]), 3)
        approvals = HELPER.list_approvals(self.config, uid=self.uid, now=self.now + 1)
        self.assertEqual(len(approvals), 1)
        self.assertIn("(3 exact paths)", approvals[0]["path"])
        for source in (self.source, self.other_source, self.third_source):
            self.assertTrue(self._verify(path=str(source)))

        extra_source = self.repo / "secret-extra.sh"
        extra_source.write_text("extra\n", encoding="utf-8")
        subprocess.run(  # nosec B603 -- fixed Git binary and local fixture path
            ["/usr/bin/git", "-C", str(self.repo), "add", extra_source.name], check=True
        )
        self.assertFalse(self._verify(path=str(extra_source)))

        self.other_source.write_text("altered\n", encoding="utf-8")
        self.assertFalse(self._verify(path=str(self.source)))
        self.assertFalse(self._verify(path=str(self.other_source)))
        self.other_source.write_text("#!/usr/bin/env bash\nprintf other\\n\n", encoding="utf-8")
        self.assertTrue(self._verify(path=str(self.source)))
        self.assertFalse(
            self._verify(path=str(self.source), now=self.now + HELPER.MAX_TTL_SECONDS)
        )

        HELPER.revoke_approval(
            self.config,
            approval_id=str(payload["approval_id"]),
            uid=self.uid,
        )
        for entry in payload["entries"]:  # type: ignore[union-attr]
            self.assertFalse(Path(str(entry["snapshot_path"])).exists())
        self.assertFalse(self._verify(path=str(self.source)))

    def test_manifest_rejects_cross_repository_and_tampered_binding(self) -> None:
        untracked_source = self.repo / "secret-untracked-manifest.sh"
        untracked_source.write_text("untracked\n", encoding="utf-8")
        with self.assertRaisesRegex(HELPER.SourceAccessError, "Git-tracked"):
            HELPER.create_manifest_request(
                self.config,
                HELPER.ManifestRequestSpec(
                    self.session,
                    self.uid,
                    self.home,
                    (str(self.source), str(untracked_source)),
                    HELPER.OVERRIDABLE_REASON,
                    self.now,
                ),
            )

        other_repo = self.root / "other-repo"
        other_repo.mkdir()
        subprocess.run(  # nosec B603 -- fixed Git binary and local fixture path
            ["/usr/bin/git", "-C", str(other_repo), "init", "--quiet"], check=True
        )
        foreign_source = other_repo / "secret-foreign.sh"
        foreign_source.write_text("foreign\n", encoding="utf-8")
        subprocess.run(  # nosec B603 -- fixed Git binary and local fixture path
            ["/usr/bin/git", "-C", str(other_repo), "add", foreign_source.name], check=True
        )
        with self.assertRaisesRegex(HELPER.SourceAccessError, "one Git worktree"):
            HELPER.create_manifest_request(
                self.config,
                HELPER.ManifestRequestSpec(
                    self.session,
                    self.uid,
                    self.home,
                    (str(self.source), str(foreign_source)),
                    HELPER.OVERRIDABLE_REASON,
                    self.now,
                ),
            )

        request_id = HELPER.create_manifest_request(
            self.config,
            HELPER.ManifestRequestSpec(
                self.session,
                self.uid,
                self.home,
                (str(self.source), str(self.other_source)),
                HELPER.OVERRIDABLE_REASON,
                self.now,
            ),
        )
        request_path = self.config.request_root / f"{request_id}.json"
        request = json.loads(request_path.read_text(encoding="utf-8"))
        request["entries"][0]["relative_path"] = "substituted.sh"
        request_path.write_bytes(HELPER.canonical_json(request) + b"\n")
        with self.assertRaisesRegex(HELPER.SourceAccessError, "entries are invalid"):
            self._approve(request_id)

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
        receipt_path.write_text("[]", encoding="utf-8")
        self.assertFalse(self._verify())

    def test_setup_generates_dedicated_root_only_key_when_approval_key_is_absent(self) -> None:
        dedicated_config = HELPER.Config(
            config_dir=self.root / "dedicated-config",
            state_dir=self.root / "dedicated-state",
            trust_uid=self.uid,
        )

        HELPER.setup_key_material(dedicated_config)

        self.assertTrue(dedicated_config.private_key.is_file())
        self.assertTrue(dedicated_config.public_key.is_file())
        self.assertTrue(dedicated_config.trust_marker.is_file())
        self.assertEqual(stat.S_IMODE(dedicated_config.private_key.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(dedicated_config.public_key.stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE(dedicated_config.trust_marker.stat().st_mode), 0o644)
        derived_public_fields = subprocess.run(
            [HELPER.SSH_KEYGEN, "-y", "-f", str(dedicated_config.private_key)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.split()
        self.assertGreaterEqual(len(derived_public_fields), 2)
        derived_public = " ".join(derived_public_fields[:2])
        self.assertEqual(dedicated_config.public_key.read_text(encoding="utf-8").strip(), derived_public)
        self.assertEqual(
            dedicated_config.trust_marker.read_text(encoding="utf-8"),
            f"schema={HELPER.SCHEMA_TRUST}\n"
            f"key_source={HELPER.TRUST_KEY_SOURCE_DEDICATED}\n"
            f"public_key={derived_public}\n",
        )
        HELPER.validate_key_material(dedicated_config)

        dedicated_config.private_key.parent.chmod(0o755)
        with self.assertRaisesRegex(HELPER.SourceAccessError, "directory ownership"):
            HELPER.validate_key_material(dedicated_config)
        dedicated_config.private_key.parent.chmod(0o700)

        replacement_key = self.root / "replacement-signing-key"
        subprocess.run(
            [
                HELPER.SSH_KEYGEN,
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                "replacement-source-access-signing",
                "-f",
                str(replacement_key),
            ],
            check=True,
        )
        dedicated_config.private_key.write_bytes(replacement_key.read_bytes())
        dedicated_config.private_key.chmod(0o600)
        with self.assertRaisesRegex(HELPER.SourceAccessError, "key binding"):
            HELPER.validate_key_material(dedicated_config)

    def test_setup_canonicalizes_derived_public_key_comment(self) -> None:
        canonical_public = self.config.public_key.read_bytes().strip()
        commented_public = canonical_public + b" aidevops-source-access-signing\n"
        derived_result = subprocess.CompletedProcess(
            args=[HELPER.SSH_KEYGEN, "-y", "-f", str(self.config.private_key)],
            returncode=0,
            stdout=commented_public,
            stderr=b"",
        )

        with mock.patch.object(HELPER._SOURCE_CORE, "_run", return_value=derived_result):
            HELPER.setup_key_material(self.config)

        self.assertEqual(self.config.public_key.read_bytes(), canonical_public + b"\n")
        self.assertEqual(
            self.config.trust_marker.read_bytes(),
            HELPER._SOURCE_CORE._trust_marker_content(canonical_public),
        )
        HELPER.validate_key_material(self.config)

    def test_setup_records_existing_dedicated_key_binding(self) -> None:
        derived_public = self.config.public_key.read_text(encoding="utf-8").strip()
        self.assertEqual(
            self.config.trust_marker.read_text(encoding="utf-8"),
            f"schema={HELPER.SCHEMA_TRUST}\n"
            f"key_source={HELPER.TRUST_KEY_SOURCE_DEDICATED}\n"
            f"public_key={derived_public}\n",
        )
        HELPER.validate_key_material(self.config)

    def test_setup_rejects_dangling_dedicated_key_symlink(self) -> None:
        symlink_config = HELPER.Config(
            config_dir=self.root / "symlink-config",
            state_dir=self.root / "symlink-state",
            trust_uid=self.uid,
        )
        symlink_config.private_key.parent.mkdir(parents=True, mode=0o700)
        outside_target = self.root / "outside-signing-key"
        symlink_config.private_key.symlink_to(outside_target)

        with self.assertRaisesRegex(HELPER.SourceAccessError, "ownership or permissions are unsafe"):
            HELPER.setup_key_material(symlink_config)

        self.assertFalse(outside_target.exists())

    def test_privileged_bootstrap_rejects_unsafe_core_and_ignores_bytecode(self) -> None:
        broker = self.root / "broker"
        broker.mkdir(mode=0o755)
        broker.chmod(0o755)
        helper_path = broker / "source-access-helper.py"
        helper_path.write_text("# bootstrap fixture\n", encoding="utf-8")
        helper_path.chmod(0o644)
        core_path = broker / "source_access_core.py"
        marker_path = self.root / "core-executed"
        core_source = (
            "from pathlib import Path\n"
            f"Path({str(marker_path)!r}).write_text('executed', encoding='utf-8')\n"
            "VALUE = 7\n"
        )
        core_path.write_text(core_source, encoding="utf-8")
        original_module = sys.modules.get(HELPER._SOURCE_CORE_MODULE_NAME)

        def load_fixture() -> object:
            with mock.patch.object(HELPER, "__file__", str(helper_path)), mock.patch.object(
                HELPER, "_ROOT_BROKER_PATH", helper_path
            ), mock.patch.object(HELPER, "_SOURCE_CORE_PATH", core_path), mock.patch.object(
                HELPER, "_BOOTSTRAP_TRUST_ROOT", self.root
            ), mock.patch.object(HELPER, "_BOOTSTRAP_TRUST_UID", self.uid), mock.patch.object(
                HELPER.os, "geteuid", return_value=0
            ):
                return HELPER._load_source_access_core()

        try:
            core_path.chmod(0o666)
            with self.assertRaisesRegex(RuntimeError, "untrusted broker files"):
                load_fixture()
            self.assertFalse(marker_path.exists())

            core_path.chmod(0o644)
            loaded = load_fixture()
            self.assertTrue(marker_path.exists())
            self.assertEqual(loaded.VALUE, 7)

            marker_path.unlink()
            core_path.write_text("VALUE = 13\n", encoding="utf-8")
            malicious_source = broker / "malicious-core.py"
            malicious_source.write_text(
                "from pathlib import Path\n"
                f"Path({str(marker_path)!r}).write_text('bytecode', encoding='utf-8')\n"
                "VALUE = 99\n",
                encoding="utf-8",
            )
            bytecode_path = Path(importlib.util.cache_from_source(str(core_path)))
            bytecode_path.parent.mkdir()
            py_compile.compile(
                str(malicious_source),
                cfile=str(bytecode_path),
                doraise=True,
                invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH,
            )
            loaded = load_fixture()
            self.assertFalse(marker_path.exists())
            self.assertEqual(loaded.VALUE, 13)

            broker.chmod(0o777)
            with self.assertRaisesRegex(RuntimeError, "untrusted broker files"):
                load_fixture()
            self.assertFalse(marker_path.exists())

            broker.chmod(0o755)
            core_target = broker / "core-target.py"
            core_path.replace(core_target)
            core_path.symlink_to(core_target.name)
            with self.assertRaisesRegex(RuntimeError, "untrusted broker files"):
                load_fixture()
            self.assertFalse(marker_path.exists())
        finally:
            if original_module is None:
                sys.modules.pop(HELPER._SOURCE_CORE_MODULE_NAME, None)
            else:
                sys.modules[HELPER._SOURCE_CORE_MODULE_NAME] = original_module

    def test_privileged_bootstrap_accepts_trusted_symlinked_ancestor(self) -> None:
        canonical_root = self.root / "private" / "etc"
        broker = canonical_root / "aidevops" / "source-access"
        broker.mkdir(parents=True)
        for trusted_directory in (canonical_root.parent, canonical_root, broker.parent, broker):
            trusted_directory.chmod(0o755)
        alias_root = self.root / "etc"
        alias_root.symlink_to(Path("private") / "etc", target_is_directory=True)
        helper_path = alias_root / "aidevops" / "source-access" / "source-access-helper.py"
        helper_path.write_text("# bootstrap fixture\n", encoding="utf-8")
        helper_path.chmod(0o644)
        core_path = broker / "source_access_core.py"
        marker_path = self.root / "aliased-core-executed"
        core_path.write_text(
            "from pathlib import Path\n"
            f"Path({str(marker_path)!r}).write_text('executed', encoding='utf-8')\n"
            "VALUE = 11\n",
            encoding="utf-8",
        )
        core_path.chmod(0o644)
        original_module = sys.modules.get(HELPER._SOURCE_CORE_MODULE_NAME)

        try:
            with mock.patch.object(HELPER, "__file__", str(helper_path)), mock.patch.object(
                HELPER, "_ROOT_BROKER_PATH", helper_path
            ), mock.patch.object(HELPER, "_SOURCE_CORE_PATH", core_path), mock.patch.object(
                HELPER, "_BOOTSTRAP_TRUST_ROOT", self.root
            ), mock.patch.object(HELPER, "_BOOTSTRAP_TRUST_UID", self.uid), mock.patch.object(
                HELPER.os, "geteuid", return_value=0
            ):
                loaded = HELPER._load_source_access_core()
            self.assertTrue(marker_path.exists())
            self.assertEqual(loaded.VALUE, 11)
        finally:
            if original_module is None:
                sys.modules.pop(HELPER._SOURCE_CORE_MODULE_NAME, None)
            else:
                sys.modules[HELPER._SOURCE_CORE_MODULE_NAME] = original_module

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
