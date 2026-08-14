#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Health, redaction, cooldown, and reconciliation contract tests."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from _knowledge_collector_health import health_record
from _knowledge_collector_model import Connection
from _knowledge_social_outbound import (
    OperationIntent,
    approve_operation,
    create_operation,
)
from _knowledge_social_outbound_provider import (
    DEFAULT_PROVIDER_RETRY_SECONDS,
    ProviderRateLimitError,
)
from _knowledge_social_outbound_reconciliation import ReconciliationRequest
from _knowledge_social_outbound_runtime import (
    AttemptOutcome,
    ClaimRequest,
    claim_operation,
    defer_claim_for_cooldown,
    due_operation_ids,
    finalize_operation,
    mark_provider_started,
)
from knowledge_corpus_catalog import provision
from knowledge_social_operations import _execute_claimed
from knowledge_social_store import SocialStoreError, connect, migrate
from social_provider_health import (
    build_health_report,
    reconcile_provider_receipts,
    render_human,
    require_health_schema,
    write_snapshot,
)

NOW = 2_000_000_000
PRINCIPAL = "principal_fixture"


class RateLimitedProvider:
    """Fixture provider returning one structured post-boundary rate limit."""

    @staticmethod
    def verify_identity() -> None:
        return None

    @staticmethod
    def invoke() -> tuple[str | None, str | None]:
        raise ProviderRateLimitError(None)


class SocialProviderHealthTests(unittest.TestCase):
    """Exercise only local fixture state; no provider request is reachable."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.database = connect(self.root)
        migrate(self.database)

    def tearDown(self) -> None:
        self.database.close()
        self.temporary.cleanup()

    def assert_schema(self, report: dict[str, object]) -> None:
        report_path = self.root / "health-report.json"
        report_path.write_text(json.dumps(report), encoding="utf-8")
        schema_path = SCRIPTS.parent / "schemas" / "social-provider-health.schema.json"
        script = (
            "const fs=require('fs');"
            "const Ajv=require('ajv/dist/2020').default;"
            "const schema=JSON.parse(fs.readFileSync(process.argv[1]));"
            "const data=JSON.parse(fs.readFileSync(process.argv[2]));"
            "const validate=new Ajv({strict:false}).compile(schema);"
            "if(!validate(data)){console.error(JSON.stringify(validate.errors));process.exit(1)}"
        )
        completed = subprocess.run(  # nosec B603 -- fixed Node schema validator
            ["node", "-e", script, str(schema_path), str(report_path)],
            cwd=SCRIPTS.parents[1],
            capture_output=True,
            check=False,
            text=True,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)

    @staticmethod
    def downgrade_to_schema_seven(database: sqlite3.Connection) -> None:
        database.execute("DROP TRIGGER outbound_reconciliations_no_update")
        database.execute("DROP TRIGGER outbound_reconciliations_no_delete")
        database.execute("DROP TRIGGER outbound_unknown_attempts_no_update")
        database.execute("DROP TRIGGER outbound_unknown_attempts_no_delete")
        database.execute("DROP TABLE outbound_reconciliations")
        database.execute("PRAGMA user_version=7")

    def connection(
        self,
        connection_id: str,
        provider: str,
        remote_account_id: str,
        *,
        configured: bool = True,
        streams: tuple[str, ...] = ("authored",),
    ) -> None:
        self.database.execute(
            "INSERT INTO connections(connection_id,provider,remote_account_id,"
            "auth_profile_ref,enabled_streams,policy_json) VALUES(?,?,?,?,?,?)",
            (
                connection_id,
                provider,
                remote_account_id,
                "profile_fixture" if configured else None,
                json.dumps(streams),
                json.dumps({"health_stale_seconds": 3600}),
            ),
        )

    def operation(
        self,
        connection_id: str,
        account_id: str,
        operation_id: str,
        *,
        payload: str = "private fixture body",
        approved: bool = True,
        created_at: int = NOW - 30,
    ) -> None:
        provider = self.database.execute(
            "SELECT provider FROM connections WHERE connection_id=?", (connection_id,)
        ).fetchone()[0]
        create_operation(
            self.database,
            OperationIntent(
                connection_id=connection_id,
                remote_account_id=account_id,
                action="post",
                target_remote_id=None,
                destination_remote_id=(
                    "fixture_subreddit" if provider == "reddit" else None
                ),
                payload=payload,
                subject="Fixture title" if provider == "reddit" else None,
                app_profile="profile_fixture",
                username=None,
                scheduled_at=created_at,
                created_by=PRINCIPAL,
                operation_id=operation_id,
                created_at=created_at,
            ),
        )
        if approved:
            approve_operation(
                self.database,
                operation_id,
                PRINCIPAL,
                NOW + 3600,
                approved_at=created_at + 1,
            )

    def finish(
        self,
        operation_id: str,
        executor_id: str,
        status: str,
        *,
        started_at: int = NOW - 20,
    ) -> None:
        claimed = claim_operation(
            self.database,
            ClaimRequest(operation_id, PRINCIPAL, executor_id, started_at, 300),
        )
        mark_provider_started(
            self.database, claimed, executor_id, started_at=started_at + 1
        )
        outcome = AttemptOutcome(
            status,
            provider_remote_id="receipt_fixture",
            failure_class="runtime" if status == "unknown" else None,
            finished_at=started_at + 2,
        )
        finalize_operation(self.database, claimed, executor_id, outcome)

    def test_readiness_is_multidimensional_and_partial(self) -> None:
        self.connection("x_primary", "xapi", "private_x_account")
        self.operation("x_primary", "private_x_account", "op_succeeded")
        self.finish("op_succeeded", "executor_success", "succeeded")
        self.operation("x_primary", "private_x_account", "op_ready")
        self.connection("x_secondary", "xapi", "private_x_secondary")
        self.database.execute(
            "INSERT INTO sync_runs(run_id,connection_id,status,failure_class,"
            "retry_after,stream,run_kind,started_at,completed_at) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            (
                "run_x_secondary_rate_limit",
                "x_secondary",
                "paused",
                "rate_limit",
                str(NOW + 300),
                "authored",
                "sync",
                NOW - 10,
                NOW - 5,
            ),
        )

        self.connection("reddit_primary", "reddit", "private_reddit_account")
        self.database.execute(
            "INSERT INTO sync_runs(run_id,connection_id,status,failure_class,"
            "retry_after,stream,run_kind,started_at,completed_at) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            (
                "run_rate_limit",
                "reddit_primary",
                "paused",
                "rate_limit",
                str(NOW + 600),
                "authored",
                "sync",
                NOW - 10,
                NOW - 5,
            ),
        )

        report = build_health_report(self.database, PRINCIPAL, NOW)
        self.assert_schema(report)
        providers = {item["provider_id"]: item for item in report["providers"]}
        x_accounts = {
            item["account_alias"]: item for item in providers["xapi"]["accounts"]
        }
        x_account = x_accounts["x_primary"]
        reddit_account = providers["reddit"]["accounts"][0]

        self.assertEqual("partial", report["status"])
        self.assertTrue(report["partial"])
        self.assertEqual("x_primary", x_account["account_alias"])
        self.assertTrue(x_account["dimensions"]["usable"])
        self.assertEqual("partial", x_account["status"])
        x_post = next(
            item
            for item in x_account["actions"]
            if item["mode"] == "write" and item["action"] == "post"
        )
        self.assertEqual("usable", x_post["status"])
        self.assertEqual("rate_limited", x_accounts["x_secondary"]["status"])
        self.assertEqual("partial", providers["xapi"]["status"])
        self.assertEqual("rate_limited", reddit_account["status"])
        self.assertEqual(NOW + 600, reddit_account["quota"]["reset_at"])
        self.assertEqual("unconfigured", providers["tiktok"]["status"])
        self.assertIn("xapi", render_human(report))

    def test_read_success_cannot_make_an_unwired_write_transport_usable(self) -> None:
        self.connection("threads_primary", "meta_threads", "private_threads_account")
        self.operation("threads_primary", "private_threads_account", "op_approved")
        self.database.execute(
            "INSERT INTO sync_runs(run_id,connection_id,status,stream,run_kind,"
            "started_at,completed_at) VALUES(?,?,?,?,?,?,?)",
            (
                "run_complete",
                "threads_primary",
                "complete",
                "authored",
                "sync",
                NOW - 20,
                NOW - 10,
            ),
        )

        report = build_health_report(self.database, PRINCIPAL, NOW)
        provider = next(
            item for item in report["providers"] if item["provider_id"] == "meta_threads"
        )
        account = provider["accounts"][0]
        post = next(item for item in account["actions"] if item["action"] == "post")
        self.assertEqual("partial", account["status"])
        self.assertEqual("unreachable", post["status"])
        self.assertFalse(post["dimensions"]["usable"])

    def test_output_redacts_private_values_and_isolates_accounts(self) -> None:
        secret = "campaign-secret-that-must-never-leak"
        self.connection("threads_one", "meta_threads", "private_account_one")
        self.connection("threads_two", "meta_threads", "private_account_two")
        self.operation(
            "threads_one",
            "private_account_one",
            "op_unknown",
            payload=secret,
        )
        self.finish("op_unknown", "executor_unknown", "unknown")
        self.operation(
            "threads_two",
            "private_account_two",
            "op_other",
            payload="second-private-body",
            approved=False,
        )

        report = build_health_report(self.database, PRINCIPAL, NOW)
        encoded = json.dumps(report, sort_keys=True)
        self.assertNotIn(secret, encoded)
        self.assertNotIn("second-private-body", encoded)
        self.assertNotIn("private_account_one", encoded)
        self.assertNotIn("private_account_two", encoded)
        self.assertNotIn("profile_fixture", encoded)

        provider = next(
            item for item in report["providers"] if item["provider_id"] == "meta_threads"
        )
        accounts = {item["account_alias"]: item for item in provider["accounts"]}
        self.assertEqual(1, accounts["threads_one"]["queue"]["unknown"])
        self.assertEqual(0, accounts["threads_two"]["queue"]["unknown"])
        self.assertIsNone(accounts["threads_one"]["dimensions"]["authenticated"])
        self.assertIsNot(accounts["threads_one"]["dimensions"]["reachable"], True)

        snapshot = self.root / "state" / "provider-health.json"
        write_snapshot(snapshot, report)
        self.assertEqual(0o600, snapshot.stat().st_mode & 0o777)
        self.assertEqual(report, json.loads(snapshot.read_text(encoding="utf-8")))

    def test_reconciliation_is_bounded_cooldown_aware_and_never_requeues(self) -> None:
        self.connection("x_primary", "xapi", "private_x_account")
        self.operation("x_primary", "private_x_account", "op_unknown")
        self.finish("op_unknown", "executor_unknown", "unknown")
        self.operation(
            "x_primary",
            "private_x_account",
            "op_undecided",
            created_at=NOW - 100,
        )
        self.finish(
            "op_undecided",
            "executor_undecided",
            "unknown",
            started_at=NOW - 90,
        )

        self.connection("reddit_primary", "reddit", "private_reddit_account")
        self.operation("reddit_primary", "private_reddit_account", "op_expired")
        claim_operation(
            self.database,
            ClaimRequest("op_expired", PRINCIPAL, "executor_lost", NOW - 10, 1),
        )
        self.connection("reddit_secondary", "reddit", "private_reddit_secondary")
        self.operation(
            "reddit_secondary", "private_reddit_secondary", "op_secondary_unknown"
        )
        self.finish("op_secondary_unknown", "executor_secondary", "unknown")
        self.database.execute(
            "INSERT INTO sync_runs(run_id,connection_id,status,failure_class,"
            "retry_after,stream,run_kind,started_at,completed_at) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            (
                "run_old_rate_limit",
                "reddit_primary",
                "paused",
                "rate_limit",
                str(NOW + 600),
                "authored",
                "sync",
                NOW - 100,
                NOW - 90,
            ),
        )
        self.database.execute(
            "INSERT INTO sync_runs(run_id,connection_id,status,stream,run_kind,"
            "started_at,completed_at) VALUES(?,?,?,?,?,?,?)",
            (
                "run_later_success",
                "reddit_primary",
                "complete",
                "authored",
                "sync",
                NOW - 20,
                NOW - 10,
            ),
        )
        health = build_health_report(self.database, PRINCIPAL, NOW)
        reddit = next(
            item for item in health["providers"] if item["provider_id"] == "reddit"
        )
        accounts = {item["account_alias"]: item for item in reddit["accounts"]}
        self.assertEqual(NOW + 600, accounts["reddit_primary"]["quota"]["reset_at"])
        self.assertIsNone(accounts["reddit_secondary"]["quota"]["reset_at"])
        attempts_before = self.database.execute(
            "SELECT COUNT(*) FROM outbound_attempts"
        ).fetchone()[0]
        unknown_evidence_before = self.database.execute(
            "SELECT operation_id,status,failure_class,provider_remote_id,finished_at,diagnostics "
            "FROM outbound_attempts WHERE operation_id IN (?,?) ORDER BY operation_id",
            ("op_unknown", "op_secondary_unknown"),
        ).fetchall()

        result = reconcile_provider_receipts(
            self.database,
            PRINCIPAL,
            NOW,
            decisions=(
                ReconciliationRequest(
                    "op_unknown", PRINCIPAL, "succeeded", "remote_confirmed", NOW
                ),
                ReconciliationRequest(
                    "op_expired", PRINCIPAL, "not-sent", None, NOW
                ),
                ReconciliationRequest(
                    "op_secondary_unknown", PRINCIPAL, "not-sent", None, NOW
                ),
            ),
            limit=3,
            per_provider_limit=1,
        )

        states = dict(
            self.database.execute(
                "SELECT operation_id,state FROM outbound_operations"
            ).fetchall()
        )
        attempts_after = self.database.execute(
            "SELECT COUNT(*) FROM outbound_attempts"
        ).fetchone()[0]
        unknown_evidence_after = self.database.execute(
            "SELECT operation_id,status,failure_class,provider_remote_id,finished_at,diagnostics "
            "FROM outbound_attempts WHERE operation_id IN (?,?) ORDER BY operation_id",
            ("op_unknown", "op_secondary_unknown"),
        ).fetchall()
        self.assertEqual("succeeded", states["op_unknown"])
        self.assertEqual("unknown", states["op_undecided"])
        self.assertEqual("unknown", states["op_expired"])
        self.assertEqual("failed", states["op_secondary_unknown"])
        self.assertEqual(attempts_before, attempts_after)
        self.assertEqual(
            [tuple(row) for row in unknown_evidence_before],
            [tuple(row) for row in unknown_evidence_after],
        )
        self.assertEqual(["op_expired"], result["expired_claims"])
        self.assertEqual(2, result["resolved_count"])
        self.assertEqual("op_expired", result["skipped"][0]["operation_id"])
        self.assertEqual("cooldown", result["skipped"][0]["reason"])
        self.assertNotIn("approved", states.values())
        reconciled_health = build_health_report(self.database, PRINCIPAL, NOW)
        reconciled_providers = {
            item["provider_id"]: item for item in reconciled_health["providers"]
        }
        x_account = reconciled_providers["xapi"]["accounts"][0]
        reddit_accounts = {
            item["account_alias"]: item
            for item in reconciled_providers["reddit"]["accounts"]
        }
        self.assertEqual(NOW, x_account["last_success_at"])
        self.assertTrue(x_account["dimensions"]["authenticated"])
        self.assertTrue(x_account["dimensions"]["reachable"])
        self.assertEqual(
            "reconciled_not_sent",
            reddit_accounts["reddit_secondary"]["last_failure_class"],
        )
        self.assertEqual(0, reddit_accounts["reddit_secondary"]["queue"]["unknown"])
        self.assertEqual(1, reddit_accounts["reddit_secondary"]["queue"]["failed"])
        audit_rows = self.database.execute(
            "SELECT original_status,original_failure_class "
            "FROM outbound_reconciliations ORDER BY operation_id"
        ).fetchall()
        self.assertEqual(
            [("unknown", "runtime"), ("unknown", "runtime")],
            [tuple(row) for row in audit_rows],
        )
        with self.assertRaises(sqlite3.IntegrityError):
            self.database.execute(
                "UPDATE outbound_reconciliations SET outcome='not-sent'"
            )
        with self.assertRaises(sqlite3.IntegrityError):
            self.database.execute(
                "UPDATE outbound_attempts SET failure_class='provider_unavailable' "
                "WHERE operation_id='op_unknown'"
            )

    def test_read_only_provider_health_and_write_cooldown_fence(self) -> None:
        self.connection(
            "mastodon_primary",
            "mastodon",
            "private_mastodon_account",
            streams=("authored_statuses",),
        )
        self.database.execute(
            "INSERT INTO sync_runs(run_id,connection_id,status,stream,run_kind,"
            "started_at,completed_at) VALUES(?,?,?,?,?,?,?)",
            (
                "run_mastodon_complete",
                "mastodon_primary",
                "complete",
                "authored_statuses",
                "sync",
                NOW - 20,
                NOW - 10,
            ),
        )
        mastodon_report = build_health_report(
            self.database, PRINCIPAL, NOW, provider="mastodon"
        )
        self.assert_schema(mastodon_report)
        mastodon = mastodon_report["providers"][0]
        read_action = mastodon["accounts"][0]["actions"][0]
        self.assertEqual("usable", mastodon["status"])
        self.assertEqual([], mastodon["supported_actions"]["write"])
        self.assertEqual("read", read_action["mode"])
        self.assertTrue(read_action["dimensions"]["authorized"])
        self.assertEqual("collect_enabled_stream", read_action["next_action"])

        self.connection("x_cooldown", "xapi", "private_x_cooldown")
        self.operation("x_cooldown", "private_x_cooldown", "op_cooldown")
        self.connection("x_boundary", "xapi", "private_x_boundary")
        self.operation("x_boundary", "private_x_boundary", "op_boundary")
        boundary_claim = claim_operation(
            self.database,
            ClaimRequest("op_boundary", PRINCIPAL, "executor_boundary", NOW, 60),
        )
        self.database.execute(
            "INSERT INTO sync_runs(run_id,connection_id,status,failure_class,"
            "retry_after,stream,run_kind,started_at,completed_at) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            (
                "run_write_cooldown",
                "x_cooldown",
                "paused",
                "rate_limit",
                str(NOW + 600),
                "authored",
                "sync",
                NOW - 10,
                NOW - 5,
            ),
        )
        self.database.execute(
            "INSERT INTO sync_runs(run_id,connection_id,status,failure_class,"
            "retry_after,stream,run_kind,started_at,completed_at) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            (
                "run_boundary_cooldown",
                "x_boundary",
                "paused",
                "rate_limit",
                str(NOW + 600),
                "authored",
                "sync",
                NOW - 10,
                NOW - 5,
            ),
        )
        self.assertEqual([], due_operation_ids(self.database, PRINCIPAL, NOW, 10))
        with self.assertRaisesRegex(SocialStoreError, "provider cooldown"):
            claim_operation(
                self.database,
                ClaimRequest("op_cooldown", PRINCIPAL, "executor_blocked", NOW, 60),
            )
        with self.assertRaisesRegex(SocialStoreError, "provider boundary"):
            mark_provider_started(
                self.database,
                boundary_claim,
                "executor_boundary",
                started_at=NOW,
            )
        deferred = defer_claim_for_cooldown(
            self.database, boundary_claim, "executor_boundary", NOW
        )
        self.assertEqual("approved", deferred["state"] if deferred else None)
        self.assertEqual(
            ("approved", "failed", "rate_limit", None),
            tuple(
                self.database.execute(
                    "SELECT o.state,a.status,a.failure_class,a.provider_started_at "
                    "FROM outbound_operations o JOIN outbound_attempts a "
                    "ON a.attempt_id=o.last_attempt_id WHERE o.operation_id='op_boundary'"
                ).fetchone()
            ),
        )
        self.assertEqual(
            ("approved", 0),
            tuple(
                self.database.execute(
                    "SELECT state,(SELECT count(*) FROM outbound_attempts "
                    "WHERE operation_id='op_cooldown') FROM outbound_operations "
                    "WHERE operation_id='op_cooldown'"
                ).fetchone()
            ),
        )

    def test_provider_rate_limit_receipt_persists_exact_account_cooldown(self) -> None:
        self.connection("linkedin_primary", "linkedin", "private_linkedin_account")
        self.operation(
            "linkedin_primary", "private_linkedin_account", "op_rate_limited"
        )
        self.operation("linkedin_primary", "private_linkedin_account", "op_same_account")
        self.connection("linkedin_other", "linkedin", "private_linkedin_other")
        self.operation("linkedin_other", "private_linkedin_other", "op_other_account")
        claimed = claim_operation(
            self.database,
            ClaimRequest("op_rate_limited", PRINCIPAL, "executor_rate", NOW - 10, 60),
        )
        with patch.dict(os.environ, {"AIDEVOPS_TEST_MODE": "1"}), patch(
            "knowledge_social_operations.prepare_provider",
            return_value=RateLimitedProvider(),
        ):
            receipt = _execute_claimed(
                self.database,
                claimed,
                "executor_rate",
                argparse.Namespace(now_epoch=NOW),
            )

        reset_at = NOW + DEFAULT_PROVIDER_RETRY_SECONDS
        self.assertEqual(reset_at, receipt["retry_after"])
        self.assertEqual(
            (
                "linkedin_primary",
                "paused",
                "rate_limit",
                str(reset_at),
                "post",
                "outbound",
            ),
            tuple(
                self.database.execute(
                    "SELECT connection_id,status,failure_class,retry_after,stream,run_kind "
                    "FROM sync_runs WHERE run_kind='outbound'"
                ).fetchone()
            ),
        )
        self.assertEqual(
            ["op_other_account"],
            due_operation_ids(self.database, PRINCIPAL, NOW, 10),
        )
        with self.assertRaisesRegex(SocialStoreError, "provider cooldown"):
            claim_operation(
                self.database,
                ClaimRequest(
                    "op_same_account", PRINCIPAL, "executor_blocked", NOW, 60
                ),
            )
        report = build_health_report(
            self.database, PRINCIPAL, NOW, provider="linkedin"
        )
        accounts = {
            item["account_alias"]: item for item in report["providers"][0]["accounts"]
        }
        self.assertEqual(reset_at, accounts["linkedin_primary"]["quota"]["reset_at"])
        self.assertIsNone(accounts["linkedin_other"]["quota"]["reset_at"])

    def test_expired_claim_cannot_finalize_as_succeeded(self) -> None:
        self.connection("x_expired", "xapi", "private_x_expired")
        self.operation("x_expired", "private_x_expired", "op_expired_success")
        claimed = claim_operation(
            self.database,
            ClaimRequest(
                "op_expired_success", PRINCIPAL, "executor_expired", NOW - 10, 5
            ),
        )
        mark_provider_started(
            self.database, claimed, "executor_expired", started_at=NOW - 9
        )

        receipt = finalize_operation(
            self.database,
            claimed,
            "executor_expired",
            AttemptOutcome(
                "succeeded",
                provider_remote_id="late_provider_receipt",
                finished_at=NOW,
            ),
        )

        self.assertEqual("unknown", receipt["state"])
        self.assertEqual("executor_lost", receipt["failure_class"])
        self.assertEqual("late_provider_receipt", receipt["provider_remote_id"])
        stored = self.database.execute(
            "SELECT o.state,a.status,a.failure_class,a.provider_remote_id "
            "FROM outbound_operations o JOIN outbound_attempts a "
            "ON a.attempt_id=o.last_attempt_id "
            "WHERE o.operation_id='op_expired_success'"
        ).fetchone()
        self.assertEqual(
            ("unknown", "unknown", "executor_lost", "late_provider_receipt"),
            tuple(stored),
        )

    def test_expired_claims_consume_the_global_reconciliation_budget(self) -> None:
        self.connection("x_budget", "xapi", "private_x_budget")
        self.operation("x_budget", "private_x_budget", "op_budget_expired")
        claim_operation(
            self.database,
            ClaimRequest(
                "op_budget_expired", PRINCIPAL, "executor_lost", NOW - 10, 1
            ),
        )
        self.operation("x_budget", "private_x_budget", "op_budget_unknown")
        self.finish("op_budget_unknown", "executor_unknown", "unknown")

        result = reconcile_provider_receipts(
            self.database,
            PRINCIPAL,
            NOW,
            decisions=(
                ReconciliationRequest(
                    "op_budget_unknown", PRINCIPAL, "not-sent", None, NOW
                ),
            ),
            limit=1,
            per_provider_limit=1,
        )

        self.assertEqual(["op_budget_expired"], result["expired_claims"])
        self.assertEqual(0, result["resolved_count"])
        self.assertEqual("global_budget", result["skipped"][0]["reason"])
        state = self.database.execute(
            "SELECT state FROM outbound_operations WHERE operation_id='op_budget_unknown'"
        ).fetchone()[0]
        self.assertEqual("unknown", state)
        pending = reconcile_provider_receipts(
            self.database,
            PRINCIPAL,
            NOW,
            decisions=(),
            limit=2,
            per_provider_limit=1,
        )
        self.assertEqual(1, pending["unresolved_count"])

    def test_schema_seven_remains_read_compatible_and_upgrades_explicitly(self) -> None:
        self.downgrade_to_schema_seven(self.database)

        require_health_schema(self.database)
        report = build_health_report(self.database, PRINCIPAL, NOW)
        self.assert_schema(report)
        self.assertEqual("unconfigured", report["status"])

        migrate(self.database)
        self.assertEqual(
            8, self.database.execute("PRAGMA user_version").fetchone()[0]
        )

    def test_cli_reads_schema_seven_and_collect_upgrades_with_manage_grant(self) -> None:
        base = self.root / "cli-knowledge"
        corpus = base / "_knowledge"
        corpus.mkdir(parents=True)
        provision(base)
        database = connect(corpus)
        migrate(database)
        self.downgrade_to_schema_seven(database)
        database.close()

        command = SCRIPTS / "social-provider-health.py"
        status = subprocess.run(  # nosec B603 -- fixed local health CLI
            [sys.executable, str(command), "status", "--base", str(base)],
            cwd=SCRIPTS.parents[1],
            capture_output=True,
            check=False,
            text=True,
        )
        self.assertEqual(0, status.returncode, status.stderr)
        self.assert_schema(json.loads(status.stdout))
        database_path = corpus / "index" / "social.db"
        inspection = sqlite3.connect(
            f"{database_path.as_uri()}?mode=ro&immutable=1", uri=True
        )
        self.assertEqual(7, inspection.execute("PRAGMA user_version").fetchone()[0])
        inspection.close()

        collect = subprocess.run(  # nosec B603 -- fixed local health CLI
            [sys.executable, str(command), "collect", "--base", str(base)],
            cwd=SCRIPTS.parents[1],
            capture_output=True,
            check=False,
            text=True,
        )
        self.assertEqual(0, collect.returncode, collect.stderr)
        inspection = sqlite3.connect(
            f"{database_path.as_uri()}?mode=ro&immutable=1", uri=True
        )
        self.assertEqual(8, inspection.execute("PRAGMA user_version").fetchone()[0])
        inspection.close()
        self.assertTrue((corpus / "state" / "social-provider-health.json").is_file())

    def test_stale_evidence_blocks_usable_and_collector_record_is_public(self) -> None:
        self.connection("x_primary", "xapi", "private_x_account")
        self.operation(
            "x_primary",
            "private_x_account",
            "op_old_success",
            created_at=NOW - 10_000,
        )
        self.finish(
            "op_old_success",
            "executor_old",
            "succeeded",
            started_at=NOW - 9_000,
        )
        self.operation("x_primary", "private_x_account", "op_ready")

        report = build_health_report(self.database, PRINCIPAL, NOW)
        x_provider = next(
            item for item in report["providers"] if item["provider_id"] == "xapi"
        )
        account = x_provider["accounts"][0]
        self.assertEqual("partial", account["status"])
        self.assertFalse(account["dimensions"]["usable"])
        post = next(
            item
            for item in account["actions"]
            if item["mode"] == "write" and item["action"] == "post"
        )
        self.assertEqual("stale", post["status"])

        connection = Connection(
            "social_fixture",
            "social",
            "poll",
            (),
            self.root,
            None,
            60,
            60,
            60,
            300,
            30,
            2,
            None,
            True,
        )
        projected = health_record(
            connection,
            {"last_success": NOW - 10, "status": "complete"},
            NOW,
        )
        self.assertEqual("healthy", projected["health"])
        self.assertEqual("social_fixture", projected["connection_id"])


if __name__ == "__main__":
    unittest.main()
