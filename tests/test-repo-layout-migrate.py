#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Disposable end-to-end tests for guarded repository layout migration."""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
HELPER = REPOSITORY_ROOT / ".agents/scripts/repo-layout-migrate-helper.sh"


class RepoLayoutMigrationTest(unittest.TestCase):
    """Exercise plan, apply/resume, consumer updates, refusal, and rollback."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / "home"
        self.workspace = self.home / "Git"
        self.state = self.home / "state"
        self.workspace.mkdir(parents=True)
        self.source = self.workspace / "Project"
        self.destination = self.workspace / "acme" / "Project"
        self.worktree = self.workspace / "_worktrees" / "Project-feature"
        self.repos_json = self.home / ".config/aidevops/repos.json"
        self.tabby = self.home / "tabby.yaml"
        self.database = self.home / "opencode.db"
        self.isolated_root = self.home / "isolated"
        self.recovery_root = self.home / "recovery"
        self.plan = self.home / "plan.json"
        self.environment = {**os.environ, "HOME": str(self.home)}
        self._create_repository()
        self._create_consumers()

    def _run(
        self,
        *arguments: str,
        check: bool = True,
        cwd: Path | None = None,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [str(HELPER), *arguments],
            cwd=cwd or self.root,
            env=environment or self.environment,
            text=True,
            capture_output=True,
            check=False,
            timeout=30,
        )
        if check and result.returncode != 0:
            self.fail(
                f"migration command failed ({result.returncode}): {result.stderr.strip()}"
            )
        return result

    def _git(self, *arguments: str, cwd: Path | None = None) -> str:
        result = subprocess.run(
            ["git", *arguments],
            cwd=cwd or self.source,
            text=True,
            capture_output=True,
            check=True,
            timeout=20,
        )
        return result.stdout.strip()

    def _create_repository(self) -> None:
        self.source.mkdir()
        self._git("init", "-q", "-b", "main")
        self._git("config", "user.name", "Fixture User")
        self._git("config", "user.email", "fixture@example.invalid")
        (self.source / "tracked.txt").write_text("tracked\n", encoding="utf-8")
        (self.source / ".gitmodules").write_text(
            '[submodule "vendor/library"]\n'
            "\tpath = vendor/library\n"
            "\turl = ../library.git\n",
            encoding="utf-8",
        )
        self._git("add", "tracked.txt", ".gitmodules")
        self._git("commit", "-q", "-m", "initial")
        self._git("remote", "add", "origin", "git@github.com:Acme/Project.git")
        self.worktree.parent.mkdir()
        self._git("worktree", "add", "-q", "-b", "feature/test", str(self.worktree))
        (self.source / "stash.txt").write_text("stash\n", encoding="utf-8")
        self._git("add", "stash.txt")
        self._git("stash", "push", "-q", "-m", "fixture")
        (self.source / "dirty.txt").write_text("dirty\n", encoding="utf-8")

    def _create_database(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(path) as connection:
            connection.execute("CREATE TABLE project (id TEXT PRIMARY KEY, worktree TEXT)")
            connection.execute(
                "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, parent_id TEXT)"
            )
            connection.execute(
                "INSERT INTO project VALUES (?, ?)", ("project-1", str(self.source))
            )
            connection.execute(
                "INSERT INTO session VALUES (?, ?, NULL)",
                ("ses_fixture1", str(self.source)),
            )

    def _create_consumers(self) -> None:
        self.repos_json.parent.mkdir(parents=True)
        self.repos_json.write_text(
            json.dumps(
                {
                    "initialized_repos": [
                        {
                            "path": str(self.source),
                            "slug": "Acme/Project",
                            "custom": "preserved",
                        }
                    ],
                    "git_parent_dirs": [str(self.workspace)],
                    "personal_owners": {"github.com": ["alice"]},
                }
            ),
            encoding="utf-8",
        )
        self.tabby.write_text(
            "profiles:\n"
            "  - name: Custom Project\n"
            "    color: '#ABCDEF'\n"
            "    options:\n"
            f"      cwd: '{self.source}'\n"
            "      command: /bin/zsh\n"
            "groups: []\n",
            encoding="utf-8",
        )
        self._create_database(self.database)
        isolated_db = self.isolated_root / "worker-1/opencode/opencode.db"
        self._create_database(isolated_db)
        marker = self.recovery_root / "ses_fixture1/recovery.json"
        marker.parent.mkdir(parents=True)
        self.recovery_root.chmod(0o700)
        marker.parent.chmod(0o700)
        marker.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "session_id": "ses_fixture1",
                    "directory": str(self.source),
                    "data_dir": str(isolated_db.parent.parent),
                }
            ),
            encoding="utf-8",
        )
        marker.chmod(0o600)

    def _plan(self, *, include_registered: bool = True) -> dict:
        arguments = [
            "plan",
            "--workspace",
            str(self.workspace),
            "--output",
            str(self.plan),
            "--repos-json",
            str(self.repos_json),
            "--tabby-config",
            str(self.tabby),
            "--opencode-db",
            str(self.database),
            "--isolated-root",
            str(self.isolated_root),
            "--recovery-root",
            str(self.recovery_root),
            "--state-dir",
            str(self.state),
        ]
        if include_registered:
            arguments.append("--include-registered-paths")
        result = self._run(*arguments)
        return json.loads(result.stdout)

    def _receipt_status(self, receipt_id: str) -> dict:
        result = self._run(
            "status", "--receipt", receipt_id, "--state-dir", str(self.state)
        )
        return json.loads(result.stdout)

    def test_plan_is_non_mutating_and_reports_complete_inventory(self) -> None:
        before = self._fixture_digest()
        summary = self._plan()
        payload = json.loads(self.plan.read_text(encoding="utf-8"))

        self.assertEqual(before, self._fixture_digest(exclude_plan=True))
        self.assertEqual(summary["moves"], 1)
        repository = payload["repositories"][0]
        self.assertEqual(repository["fingerprint"]["status_entries"], 1)
        self.assertEqual(repository["fingerprint"]["stash_count"], 1)
        self.assertIsNotNone(repository["fingerprint"]["gitmodules_sha256"])
        self.assertEqual(len(repository["fingerprint"]["worktrees"]), 2)
        self.assertEqual(len(repository["linked_pointers"]), 1)
        self.assertEqual(len(payload["consumers"]["databases"]), 2)
        self.assertEqual(len(payload["consumers"]["markers"]), 1)
        self.assertFalse(self.destination.exists())

    def test_apply_resume_or_rollback_preserves_exact_state(self) -> None:
        before_repository = self._repository_snapshot(self.source)
        marker = self.recovery_root / "ses_fixture1/recovery.json"
        before_consumers = {
            self.repos_json: self.repos_json.read_bytes(),
            self.tabby: self.tabby.read_bytes(),
            marker: marker.read_bytes(),
        }
        summary = self._plan()
        interrupted_environment = {
            **self.environment,
            "AIDEVOPS_MIGRATE_FAIL_AFTER": "repository:0",
        }
        interrupted = self._run(
            "apply",
            "--plan",
            str(self.plan),
            "--confirm",
            summary["plan_sha256"],
            check=False,
            environment=interrupted_environment,
        )
        self.assertEqual(interrupted.returncode, 2)
        self.assertTrue(self.destination.is_dir())
        self.assertFalse(self.source.exists())

        applied = json.loads(
            self._run(
                "apply",
                "--plan",
                str(self.plan),
                "--confirm",
                summary["plan_sha256"],
            ).stdout
        )
        self.assertEqual(applied["state"], "applied")
        receipt_id = applied["receipt_id"]
        self.assertEqual(self._receipt_status(receipt_id)["state"], "applied")
        registration = json.loads(self.repos_json.read_text(encoding="utf-8"))
        self.assertEqual(registration["initialized_repos"][0]["path"], str(self.destination))
        self.assertEqual(registration["initialized_repos"][0]["custom"], "preserved")
        tabby_text = self.tabby.read_text(encoding="utf-8")
        self.assertIn(str(self.destination), tabby_text)
        self.assertIn("color: '#ABCDEF'", tabby_text)
        self.assertEqual(self._database_paths(self.database), {str(self.destination)})
        linked_marker = (self.worktree / ".git").read_text(encoding="utf-8")
        self.assertIn(str(self.destination / ".git"), linked_marker)
        self.assertEqual(
            self._git("rev-parse", "HEAD", cwd=self.destination),
            self._git("rev-parse", "HEAD", cwd=self.worktree),
        )

        status = self._receipt_status(receipt_id)
        rolled_back = json.loads(
            self._run(
                "rollback",
                "--receipt",
                receipt_id,
                "--state-dir",
                str(self.state),
                "--confirm",
                status["receipt_sha256"],
            ).stdout
        )
        self.assertEqual(rolled_back["state"], "rolled-back")
        self.assertTrue(self.source.is_dir())
        self.assertFalse(self.destination.exists())
        self.assertEqual(before_repository, self._repository_snapshot(self.source))
        for path, expected in before_consumers.items():
            self.assertEqual(path.read_bytes(), expected)
        self.assertEqual(self._database_paths(self.database), {str(self.source)})

    def test_refusal_for_unapproved_registration_and_plan_drift(self) -> None:
        summary = self._plan(include_registered=False)
        payload = json.loads(self.plan.read_text(encoding="utf-8"))
        self.assertEqual(summary["moves"], 0)
        self.assertEqual(
            payload["exclusions"][0]["reason"], "explicit-registration-not-approved"
        )

        summary = self._plan()
        (self.source / "dirty.txt").write_text("changed after plan\n", encoding="utf-8")
        refused = self._run(
            "apply",
            "--plan",
            str(self.plan),
            "--confirm",
            summary["plan_sha256"],
            check=False,
        )
        self.assertEqual(refused.returncode, 2)
        self.assertIn("drift detected", refused.stderr)
        self.assertTrue(self.source.is_dir())
        self.assertFalse(self.destination.exists())

    def test_refusal_for_destination_collision_and_active_path(self) -> None:
        self.destination.mkdir(parents=True)
        refused = self._run(
            "plan",
            "--workspace",
            str(self.workspace),
            "--output",
            str(self.plan),
            "--repos-json",
            str(self.repos_json),
            "--include-registered-paths",
            check=False,
        )
        self.assertEqual(refused.returncode, 2)
        self.assertIn("Destination collision", refused.stderr)
        self.destination.rmdir()
        self.destination.parent.rmdir()

        summary = self._plan()
        active = self._run(
            "apply",
            "--plan",
            str(self.plan),
            "--confirm",
            summary["plan_sha256"],
            check=False,
            cwd=self.source,
        )
        self.assertEqual(active.returncode, 2)
        self.assertIn("Active-path ambiguity", active.stderr)
        self.assertTrue(self.source.is_dir())

    def test_refusal_for_unexpected_linked_pointer(self) -> None:
        summary = self._plan()
        (self.worktree / ".git").write_text("gitdir: /unexpected/location\n", encoding="utf-8")
        refused = self._run(
            "apply",
            "--plan",
            str(self.plan),
            "--confirm",
            summary["plan_sha256"],
            check=False,
        )
        self.assertEqual(refused.returncode, 2)
        self.assertTrue(self.source.is_dir())
        self.assertFalse(self.destination.exists())

    def test_refusal_for_malformed_config_and_database_schema_drift(self) -> None:
        original_tabby = self.tabby.read_text(encoding="utf-8")
        self.tabby.write_text("profiles: not-a-list\n", encoding="utf-8")
        malformed = self._run(
            "plan",
            "--workspace",
            str(self.workspace),
            "--output",
            str(self.plan),
            "--repos-json",
            str(self.repos_json),
            "--tabby-config",
            str(self.tabby),
            "--include-registered-paths",
            check=False,
        )
        self.assertEqual(malformed.returncode, 2)
        self.assertFalse(self.plan.exists())

        self.tabby.write_text(original_tabby, encoding="utf-8")
        summary = self._plan()
        with sqlite3.connect(self.database) as connection:
            connection.execute("ALTER TABLE project ADD COLUMN later TEXT")
        drifted = self._run(
            "apply",
            "--plan",
            str(self.plan),
            "--confirm",
            summary["plan_sha256"],
            check=False,
        )
        self.assertEqual(drifted.returncode, 2)
        self.assertIn("Database schema or row drift", drifted.stderr)
        self.assertTrue(self.source.is_dir())

    def test_confirmation_and_post_apply_drift_block_rollback(self) -> None:
        summary = self._plan()
        wrong = self._run(
            "apply",
            "--plan",
            str(self.plan),
            "--confirm",
            "0" * 64,
            check=False,
        )
        self.assertEqual(wrong.returncode, 2)
        self.assertTrue(self.source.is_dir())

        applied = json.loads(
            self._run(
                "apply",
                "--plan",
                str(self.plan),
                "--confirm",
                summary["plan_sha256"],
            ).stdout
        )
        (self.destination / "dirty.txt").write_text("newer work\n", encoding="utf-8")
        status = self._receipt_status(applied["receipt_id"])
        refused = self._run(
            "rollback",
            "--receipt",
            applied["receipt_id"],
            "--state-dir",
            str(self.state),
            "--confirm",
            status["receipt_sha256"],
            check=False,
        )
        self.assertEqual(refused.returncode, 2)
        self.assertIn("drift blocks rollback", refused.stderr)
        self.assertTrue(self.destination.is_dir())

    def test_resume_or_rollback_from_every_consumer_boundary(self) -> None:
        boundaries = (
            "consumer:repos_json",
            "consumer:tabby",
            "consumer:database:0",
            "consumer:database:1",
            "consumer:marker:0",
        )
        for boundary in boundaries:
            with self.subTest(boundary=boundary):
                summary = self._plan()
                payload = json.loads(self.plan.read_text(encoding="utf-8"))
                receipt_id = f"layout-{payload['plan_id']}"
                interrupted = self._run(
                    "apply",
                    "--plan",
                    str(self.plan),
                    "--confirm",
                    summary["plan_sha256"],
                    check=False,
                    environment={
                        **self.environment,
                        "AIDEVOPS_MIGRATE_FAIL_AFTER": boundary,
                    },
                )
                self.assertEqual(interrupted.returncode, 2)
                partial = self._receipt_status(receipt_id)
                self.assertEqual(partial["state"], "partial")
                self.assertEqual(
                    {item["action"] for item in partial["next_actions"]},
                    {"resume", "rollback"},
                )
                applied = json.loads(
                    self._run(
                        "apply",
                        "--plan",
                        str(self.plan),
                        "--confirm",
                        summary["plan_sha256"],
                    ).stdout
                )
                current = self._receipt_status(applied["receipt_id"])
                rolled_back = json.loads(
                    self._run(
                        "rollback",
                        "--receipt",
                        applied["receipt_id"],
                        "--state-dir",
                        str(self.state),
                        "--confirm",
                        current["receipt_sha256"],
                    ).stdout
                )
                self.assertEqual(rolled_back["state"], "rolled-back")
                self.assertTrue(self.source.is_dir())
                self.assertFalse(self.destination.exists())

    def test_resume_after_mutation_before_completion_event(self) -> None:
        for boundary in ("repository:0", "consumer:repos_json"):
            with self.subTest(boundary=boundary):
                summary = self._plan()
                interrupted = self._run(
                    "apply",
                    "--plan",
                    str(self.plan),
                    "--confirm",
                    summary["plan_sha256"],
                    check=False,
                    environment={
                        **self.environment,
                        "AIDEVOPS_MIGRATE_FAIL_AFTER_MUTATION": boundary,
                    },
                )
                self.assertEqual(interrupted.returncode, 2)
                applied = json.loads(
                    self._run(
                        "apply",
                        "--plan",
                        str(self.plan),
                        "--confirm",
                        summary["plan_sha256"],
                    ).stdout
                )
                status = self._receipt_status(applied["receipt_id"])
                self._run(
                    "rollback",
                    "--receipt",
                    applied["receipt_id"],
                    "--state-dir",
                    str(self.state),
                    "--confirm",
                    status["receipt_sha256"],
                )
                self.assertTrue(self.source.is_dir())
                self.assertFalse(self.destination.exists())
                self.assertIn(
                    str(self.source / ".git"),
                    (self.worktree / ".git").read_text(encoding="utf-8"),
                )

    def test_resume_rollback_after_mutation_before_completion_event(self) -> None:
        summary = self._plan()
        applied = json.loads(
            self._run(
                "apply",
                "--plan",
                str(self.plan),
                "--confirm",
                summary["plan_sha256"],
            ).stdout
        )
        status = self._receipt_status(applied["receipt_id"])
        interrupted = self._run(
            "rollback",
            "--receipt",
            applied["receipt_id"],
            "--state-dir",
            str(self.state),
            "--confirm",
            status["receipt_sha256"],
            check=False,
            environment={
                **self.environment,
                "AIDEVOPS_MIGRATE_FAIL_AFTER_MUTATION": "rollback:repository:0",
            },
        )
        self.assertEqual(interrupted.returncode, 2)
        partial = self._receipt_status(applied["receipt_id"])
        resumed = json.loads(
            self._run(
                "rollback",
                "--receipt",
                applied["receipt_id"],
                "--state-dir",
                str(self.state),
                "--confirm",
                partial["receipt_sha256"],
            ).stdout
        )
        self.assertEqual(resumed["state"], "rolled-back")
        self.assertTrue(self.source.is_dir())
        self.assertFalse(self.destination.exists())

    def test_receipt_paths_and_event_targets_are_authenticated(self) -> None:
        summary = self._plan()
        applied = json.loads(
            self._run(
                "apply",
                "--plan",
                str(self.plan),
                "--confirm",
                summary["plan_sha256"],
            ).stdout
        )
        receipt_directory = Path(applied["receipt_directory"])
        refused_path = self._run(
            "status",
            "--receipt",
            str(receipt_directory),
            "--state-dir",
            str(self.state),
            check=False,
        )
        self.assertEqual(refused_path.returncode, 2)
        self.assertIn("Invalid receipt ID", refused_path.stderr)

        journal = receipt_directory / "receipt.jsonl"
        events = [json.loads(line) for line in journal.read_text(encoding="utf-8").splitlines()]
        consumer_event = next(
            event
            for event in events
            if event.get("key") == "consumer:repos_json"
            and event.get("event") == "started"
        )
        consumer_event["details"]["path"] = str(self.home / "unrelated.json")
        journal.write_text(
            "".join(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n" for event in events),
            encoding="utf-8",
        )
        journal.chmod(0o600)
        refused_target = self._run(
            "status",
            "--receipt",
            applied["receipt_id"],
            "--state-dir",
            str(self.state),
            check=False,
        )
        self.assertEqual(refused_target.returncode, 2)
        self.assertIn("target mismatch", refused_target.stderr)

    def test_torn_receipt_tail_recovers_and_rollback_rejects_active_path(self) -> None:
        summary = self._plan()
        plan_payload = json.loads(self.plan.read_text(encoding="utf-8"))
        receipt_id = f"layout-{plan_payload['plan_id']}"
        receipt_directory = self.state / receipt_id
        receipt_directory.mkdir(parents=True, mode=0o700)
        self.state.chmod(0o700)
        stored_plan = receipt_directory / "plan.json"
        stored_plan.write_bytes(self.plan.read_bytes())
        stored_plan.chmod(0o600)
        journal = receipt_directory / "receipt.jsonl"
        journal.write_bytes(b'{"event":"cre')
        journal.chmod(0o600)

        applied = json.loads(
            self._run(
                "apply",
                "--plan",
                str(self.plan),
                "--confirm",
                summary["plan_sha256"],
            ).stdout
        )
        status = self._receipt_status(applied["receipt_id"])
        active = self._run(
            "rollback",
            "--receipt",
            applied["receipt_id"],
            "--state-dir",
            str(self.state),
            "--confirm",
            status["receipt_sha256"],
            check=False,
            cwd=self.destination,
        )
        self.assertEqual(active.returncode, 2)
        self.assertIn("Active-path ambiguity", active.stderr)

        with journal.open("ab") as handle:
            handle.write(b'{"event":"com')
        torn_status = self._receipt_status(applied["receipt_id"])
        self.assertEqual(torn_status["state"], "applied")
        rolled_back = json.loads(
            self._run(
                "rollback",
                "--receipt",
                applied["receipt_id"],
                "--state-dir",
                str(self.state),
                "--confirm",
                torn_status["receipt_sha256"],
            ).stdout
        )
        self.assertEqual(rolled_back["state"], "rolled-back")
        self.assertTrue(self.source.is_dir())
        self.assertFalse(self.destination.exists())

    def test_apply_and_rollback_staged_path_shapes(self) -> None:
        cases = (
            ("nested", Path("acme"), Path("acme/Project")),
            ("case-only", Path("Acme/CaseProject"), Path("acme/CaseProject")),
        )
        for label, source_relative, destination_relative in cases:
            with self.subTest(label=label):
                workspace = self.home / f"Git-{label}"
                source = workspace / source_relative
                destination = workspace / destination_relative
                source.mkdir(parents=True)
                self._git("init", "-q", "-b", "main", cwd=source)
                self._git("config", "user.name", "Fixture User", cwd=source)
                self._git(
                    "config", "user.email", "fixture@example.invalid", cwd=source
                )
                (source / "tracked.txt").write_text("tracked\n", encoding="utf-8")
                self._git("add", "tracked.txt", cwd=source)
                self._git("commit", "-q", "-m", "initial", cwd=source)
                repository_name = destination.name
                self._git(
                    "remote",
                    "add",
                    "origin",
                    f"git@github.com:Acme/{repository_name}.git",
                    cwd=source,
                )
                config = self.home / f"repos-{label}.json"
                config.write_text(
                    json.dumps(
                        {
                            "initialized_repos": [],
                            "personal_owners": {"github.com": ["alice"]},
                        }
                    ),
                    encoding="utf-8",
                )
                plan = self.home / f"plan-{label}.json"
                state = self.home / f"state-{label}"
                summary = json.loads(
                    self._run(
                        "plan",
                        "--workspace",
                        str(workspace),
                        "--output",
                        str(plan),
                        "--repos-json",
                        str(config),
                        "--state-dir",
                        str(state),
                    ).stdout
                )
                apply_result = self._run(
                    "apply",
                    "--plan",
                    str(plan),
                    "--confirm",
                    summary["plan_sha256"],
                    check=False,
                )
                self.assertEqual(apply_result.returncode, 0, apply_result.stderr)
                applied = json.loads(apply_result.stdout)
                self.assertTrue(destination.is_dir())
                status = json.loads(
                    self._run(
                        "status",
                        "--receipt",
                        applied["receipt_id"],
                        "--state-dir",
                        str(state),
                    ).stdout
                )
                self._run(
                    "rollback",
                    "--receipt",
                    applied["receipt_id"],
                    "--state-dir",
                    str(state),
                    "--confirm",
                    status["receipt_sha256"],
                )
                self.assertTrue(source.is_dir())
                if str(source).lower() != str(destination).lower():
                    self.assertFalse(destination.exists())

    def _database_paths(self, path: Path) -> set[str]:
        with sqlite3.connect(path) as connection:
            project = connection.execute("SELECT worktree FROM project").fetchone()[0]
            session = connection.execute("SELECT directory FROM session").fetchone()[0]
        return {project, session}

    def _repository_snapshot(self, path: Path) -> dict[str, str]:
        return {
            "head": self._git("rev-parse", "HEAD", cwd=path),
            "branch": self._git("branch", "--show-current", cwd=path),
            "branches": self._git(
                "for-each-ref",
                "--sort=refname",
                "--format=%(refname) %(objectname)",
                "refs/heads",
                cwd=path,
            ),
            "status": self._git("status", "--porcelain=v1", cwd=path),
            "stashes": self._git("stash", "list", cwd=path),
            "linked_pointer": (self.worktree / ".git").read_text(encoding="utf-8"),
        }

    def _fixture_digest(
        self, *, exclude_plan: bool = False, exclude_state: bool = False
    ) -> str:
        digest = hashlib.sha256()
        for path in sorted(self.home.rglob("*")):
            if exclude_plan and path == self.plan:
                continue
            if exclude_state and (path == self.state or self.state in path.parents):
                continue
            relative = path.relative_to(self.home)
            digest.update(str(relative).encode())
            if path.is_file() and not path.is_symlink():
                digest.update(path.read_bytes())
        return digest.hexdigest()


if __name__ == "__main__":
    unittest.main()
