#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Signed-fixture tests for webhook deduplication and invalidation ordering."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import hashlib
import hmac
import http.client
import importlib.util
import json
import multiprocessing
import os
from pathlib import Path
import socket
import stat
import subprocess
import tempfile
import threading
import time
import unittest
from typing import Any


TEST_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = TEST_DIR.parent
SERVER_PATH = SCRIPTS_DIR / "pulse-merge-webhook-server.py"
RECEIVER_PATH = SCRIPTS_DIR / "pulse-merge-webhook-receiver.sh"

SERVER_SPEC = importlib.util.spec_from_file_location("pulse_merge_webhook_server", SERVER_PATH)
if SERVER_SPEC is None or SERVER_SPEC.loader is None:
    raise RuntimeError("unable to load webhook server module")
SERVER = importlib.util.module_from_spec(SERVER_SPEC)
SERVER_SPEC.loader.exec_module(SERVER)


def _record_delivery_in_process(arguments: tuple[str, int]) -> str:
    ledger_path, worker = arguments
    SERVER.LEDGER_FILE = Path(ledger_path)
    SERVER.LEDGER_TTL_SECONDS = 3600
    SERVER.LEDGER_MAX_ENTRIES = 32
    return SERVER._record_delivery(
        f"process-delivery-{worker}",
        "issues",
        hashlib.sha256(str(worker).encode("utf-8")).hexdigest(),
        "accepted",
    )


def _record_shared_delivery_in_process(ledger_path: str) -> str:
    SERVER.LEDGER_FILE = Path(ledger_path)
    SERVER.LEDGER_TTL_SECONDS = 3600
    SERVER.LEDGER_MAX_ENTRIES = 32
    return SERVER._record_delivery(
        "process-shared-delivery",
        "issues",
        hashlib.sha256(b"shared-delivery").hexdigest(),
        "accepted",
    )


class WebhookInvalidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.ledger = self.root / "state" / "deliveries.json"
        self.secret = b"signed-fixture-secret"
        self.records: list[str] = []
        self.logs: list[str] = []
        self.received_markers: list[int] = []
        self.dispatch_evidence: list[str] = []
        self.original_emit = SERVER._emit_records
        self.original_log = SERVER._log
        SERVER.SECRET = self.secret
        SERVER.LEDGER_FILE = self.ledger
        SERVER.LEDGER_TTL_SECONDS = 3600
        SERVER.LEDGER_MAX_ENTRIES = 16
        SERVER.MAX_BODY = 1_048_576
        SERVER.HANDLED = {
            "check_run",
            "check_suite",
            "issue_comment",
            "issues",
            "pull_request",
            "pull_request_review",
            "pull_request_review_comment",
            "pull_request_review_thread",
            "status",
            "workflow_run",
        }

        def capture_records(
            invalidations: list[str], actions: list[tuple[str, int]], received_ms: int
        ) -> None:
            self.received_markers.append(received_ms)
            self.records.extend(invalidations)
            self.records.extend(f"PROCESS_PR {slug} {number}" for slug, number in actions)

        SERVER._emit_records = capture_records
        SERVER._log = self.logs.append
        self._start_server()

    def tearDown(self) -> None:
        self._stop_server()
        SERVER._emit_records = self.original_emit
        SERVER._log = self.original_log
        self.temporary_directory.cleanup()

    def _start_server(self) -> None:
        self.server = SERVER.WebhookServer(("127.0.0.1", 0), SERVER.WebhookHandler)
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()

    def _stop_server(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(timeout=5)

    def _request(
        self,
        event: str,
        delivery_id: str,
        payload: dict[str, Any] | bytes,
        *,
        valid_signature: bool = True,
    ) -> tuple[int, bytes]:
        body = (
            payload
            if isinstance(payload, bytes)
            else json.dumps(payload, separators=(",", ":")).encode("utf-8")
        )
        signature = hmac.new(self.secret, body, hashlib.sha256).hexdigest()
        if not valid_signature:
            signature = "0" * 64
        connection = http.client.HTTPConnection(
            self.server.server_address[0], self.server.server_address[1], timeout=5
        )
        connection.request(
            "POST",
            "/webhook",
            body=body,
            headers={
                "Content-Length": str(len(body)),
                "Content-Type": "application/json",
                "X-GitHub-Delivery": delivery_id,
                "X-GitHub-Event": event,
                "X-Hub-Signature-256": f"sha256={signature}",
            },
        )
        response = connection.getresponse()
        response_body = response.read()
        connection.close()
        return response.status, response_body

    @staticmethod
    def _repository_payload() -> dict[str, Any]:
        return {"repository": {"full_name": "owner/repo"}}

    def _issue_payload(self, number: int, **issue_fields: Any) -> dict[str, Any]:
        payload = self._repository_payload()
        payload["action"] = "edited"
        payload["issue"] = {"number": number, **issue_fields}
        return payload

    def test_health_endpoint_remains_local_and_payload_free(self) -> None:
        connection = http.client.HTTPConnection(
            self.server.server_address[0], self.server.server_address[1], timeout=5
        )
        connection.request("GET", "/health")
        response = connection.getresponse()
        self.assertEqual(200, response.status)
        self.assertEqual(b"ok\n", response.read())
        connection.close()
        self.assertFalse(self.ledger.exists())

    def test_ipv6_loopback_server_uses_the_ipv6_address_family(self) -> None:
        if not socket.has_ipv6:
            self.skipTest("IPv6 unavailable")
        try:
            server = SERVER.IPv6WebhookServer(("::1", 0), SERVER.WebhookHandler)
        except OSError as error:
            self.skipTest(f"IPv6 loopback unavailable: {error}")
        self.assertEqual(socket.AF_INET6, server.address_family)
        server.server_close()

    def test_signature_and_json_validation_precede_logs_and_ledger(self) -> None:
        payload = self._repository_payload()
        status, _ = self._request("issues", "delivery-invalid-signature", payload, valid_signature=False)
        self.assertEqual(401, status)
        self.assertFalse(self.ledger.exists())
        self.assertEqual([], self.records)
        self.assertEqual([], self.logs)

    def test_body_delivery_slug_and_id_validation_fail_before_ledger(self) -> None:
        payload = self._issue_payload(1)
        original_max_body = SERVER.MAX_BODY
        SERVER.MAX_BODY = 8
        try:
            status, _ = self._request("issues", "delivery-oversized", payload)
        finally:
            SERVER.MAX_BODY = original_max_body
        self.assertEqual(413, status)

        status, _ = self._request("issues", "", payload)
        self.assertEqual(400, status)
        invalid_slug = self._issue_payload(2)
        invalid_slug["repository"] = {"full_name": "../invalid"}
        status, _ = self._request("issues", "delivery-invalid-slug", invalid_slug)
        self.assertEqual(400, status)
        invalid_id = self._issue_payload(0)
        status, _ = self._request("issues", "delivery-invalid-id", invalid_id)
        self.assertEqual(400, status)
        status, _ = self._request("push", "delivery-unhandled", self._repository_payload())
        self.assertEqual(204, status)
        status, _ = self._request("push", "delivery-unhandled-json", b"{invalid")
        self.assertEqual(204, status)
        invalid_action = self._issue_payload(3)
        invalid_action["action"] = "unknown_action"
        status, _ = self._request("issues", "delivery-invalid-action", invalid_action)
        self.assertEqual(400, status)
        invalid_sha = self._repository_payload()
        invalid_sha.update({"sha": "short", "state": "success"})
        status, _ = self._request("status", "delivery-invalid-sha", invalid_sha)
        self.assertEqual(400, status)
        self.assertFalse(self.ledger.exists())
        self.assertEqual([], self.records)
        self.assertEqual([], self.logs)

        status, _ = self._request("issues", "delivery-invalid-json", b"{invalid")
        self.assertEqual(400, status)
        self.assertFalse(self.ledger.exists())
        self.assertEqual([], self.records)

    def test_issue_invalidation_is_private_narrow_and_body_free(self) -> None:
        payload = self._issue_payload(3, title="RAW-BODY-SENTINEL")
        status, _ = self._request("issues", "delivery-issue-1", payload)
        self.assertEqual(200, status)
        self.assertEqual(
            ["INVALIDATE v1 collection issues owner/repo"],
            self.records,
        )
        self.assertEqual(1, len(self.received_markers))
        self.assertGreater(self.received_markers[0], 0)
        self.assertEqual(0o600, stat.S_IMODE(self.ledger.stat().st_mode))
        ledger_text = self.ledger.read_text(encoding="utf-8")
        self.assertNotIn("RAW-BODY-SENTINEL", ledger_text)
        self.assertNotIn("RAW-BODY-SENTINEL", "\n".join(self.logs))
        ledger = json.loads(ledger_text)
        self.assertEqual("aidevops-webhook-deliveries/v1", ledger["schema"])
        self.assertEqual("accepted", ledger["deliveries"][0]["outcome"])
        self.assertEqual([], list(self.ledger.parent.glob(".webhook-ledger.*")))

    def test_duplicate_and_conflicting_delivery_ids_do_not_retrigger(self) -> None:
        payload = self._issue_payload(4)
        first_status, _ = self._request("issues", "delivery-dedup-1", payload)
        ledger_before = self.ledger.read_bytes()
        mtime_before = self.ledger.stat().st_mtime_ns
        duplicate_status, duplicate_body = self._request(
            "issues", "delivery-dedup-1", payload
        )
        changed_payload = self._issue_payload(5)
        conflict_status, _ = self._request(
            "issues", "delivery-dedup-1", changed_payload
        )
        self.assertEqual(200, first_status)
        self.assertEqual(200, duplicate_status)
        self.assertEqual(b"duplicate\n", duplicate_body)
        self.assertEqual(409, conflict_status)
        self.assertEqual(ledger_before, self.ledger.read_bytes())
        self.assertEqual(mtime_before, self.ledger.stat().st_mtime_ns)
        self.assertEqual(
            ["INVALIDATE v1 collection issues owner/repo"],
            self.records,
        )
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        self.assertEqual(1, len(ledger["deliveries"]))

    def test_duplicate_remains_suppressed_after_server_restart(self) -> None:
        payload = self._issue_payload(6)
        status, _ = self._request("issues", "delivery-restart-1", payload)
        self.assertEqual(200, status)
        self._stop_server()
        self._start_server()
        status, response_body = self._request("issues", "delivery-restart-1", payload)
        self.assertEqual(200, status)
        self.assertEqual(b"duplicate\n", response_body)
        self.assertEqual(1, len(self.records))

    def test_simultaneous_duplicate_deliveries_have_one_atomic_owner(self) -> None:
        payload = self._issue_payload(7)

        def deliver(_worker: int) -> int:
            status, _ = self._request("issues", "delivery-concurrent-1", payload)
            return status

        with ThreadPoolExecutor(max_workers=8) as executor:
            statuses = list(executor.map(deliver, range(8)))
        self.assertEqual([200] * 8, statuses)
        self.assertEqual(
            ["INVALIDATE v1 collection issues owner/repo"],
            self.records,
        )
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        self.assertEqual(1, len(ledger["deliveries"]))

    def test_pr_and_check_records_precede_process_actions(self) -> None:
        pull_payload = self._repository_payload()
        pull_payload.update(
            {
                "action": "labeled",
                "label": {"name": "ai-approved"},
                "pull_request": {"number": 7},
            }
        )
        status, _ = self._request("pull_request", "delivery-pr-1", pull_payload)
        self.assertEqual(200, status)

        check_payload = self._repository_payload()
        check_payload.update(
            {
                "action": "completed",
                "check_suite": {
                    "conclusion": "success",
                    "head_sha": "a" * 40,
                    "pull_requests": [{"number": 8}, {"number": 8}, {"number": 9}],
                },
            }
        )
        status, _ = self._request("check_suite", "delivery-check-1", check_payload)
        self.assertEqual(200, status)
        self.assertEqual(
            [
                "INVALIDATE v1 collection prs owner/repo",
                "PROCESS_PR owner/repo 7",
                f"INVALIDATE v1 checks owner/repo {'a' * 40}",
                "PROCESS_PR owner/repo 8",
                "PROCESS_PR owner/repo 9",
            ],
            self.records,
        )

    def test_review_and_check_run_map_to_pr_and_exact_sha(self) -> None:
        review_payload = self._repository_payload()
        review_payload.update(
            {
                "action": "submitted",
                "pull_request": {"number": 11},
                "review": {"state": "approved"},
            }
        )
        status, _ = self._request(
            "pull_request_review", "delivery-review-1", review_payload
        )
        self.assertEqual(200, status)

        check_run_payload = self._repository_payload()
        check_run_payload.update(
            {
                "action": "completed",
                "check_run": {
                    "conclusion": "success",
                    "head_sha": "d" * 40,
                    "pull_requests": [{"number": 11}],
                },
            }
        )
        status, _ = self._request("check_run", "delivery-check-run-1", check_run_payload)
        self.assertEqual(200, status)
        self.assertEqual(
            [
                "INVALIDATE v1 collection prs owner/repo",
                "PROCESS_PR owner/repo 11",
                f"INVALIDATE v1 checks owner/repo {'d' * 40}",
                "PROCESS_PR owner/repo 11",
            ],
            self.records,
        )

    def test_issue_comments_select_only_the_affected_collection(self) -> None:
        issue_comment = self._repository_payload()
        issue_comment.update({"action": "created", "issue": {"number": 12}})
        status, _ = self._request("issue_comment", "delivery-comment-1", issue_comment)
        self.assertEqual(200, status)

        pr_comment = self._repository_payload()
        pr_comment.update(
            {"action": "edited", "issue": {"number": 13, "pull_request": {}}}
        )
        status, _ = self._request("issue_comment", "delivery-comment-2", pr_comment)
        self.assertEqual(200, status)
        self.assertEqual(
            [
                "INVALIDATE v1 collection issues owner/repo",
                "INVALIDATE v1 collection prs owner/repo",
            ],
            self.records,
        )

    def test_review_thread_mutation_invalidates_only_the_pr_collection(self) -> None:
        payload = self._repository_payload()
        payload.update({"action": "resolved", "pull_request": {"number": 15}})
        status, _ = self._request(
            "pull_request_review_thread", "delivery-thread-1", payload
        )
        self.assertEqual(200, status)
        self.assertEqual(
            ["INVALIDATE v1 collection prs owner/repo"],
            self.records,
        )

    def test_review_comment_and_workflow_run_map_to_narrow_invalidations(self) -> None:
        review_comment = self._repository_payload()
        review_comment.update({"action": "edited", "pull_request": {"number": 18}})
        status, _ = self._request(
            "pull_request_review_comment", "delivery-review-comment-1", review_comment
        )
        self.assertEqual(200, status)

        workflow_run = self._repository_payload()
        workflow_run.update(
            {"action": "completed", "workflow_run": {"head_sha": "e" * 40}}
        )
        status, _ = self._request(
            "workflow_run", "delivery-workflow-run-1", workflow_run
        )
        self.assertEqual(200, status)
        self.assertEqual(
            [
                "INVALIDATE v1 collection prs owner/repo",
                f"INVALIDATE v1 checks owner/repo {'e' * 40}",
            ],
            self.records,
        )

    def test_out_of_order_unique_events_remain_safe_invalidations(self) -> None:
        newer = self._issue_payload(14, updated_at="2026-07-18T12:00:00Z")
        newer["action"] = "closed"
        older = self._issue_payload(14, updated_at="2026-07-18T11:00:00Z")
        older["action"] = "reopened"
        first_status, _ = self._request("issues", "delivery-newer", newer)
        second_status, _ = self._request("issues", "delivery-older", older)
        self.assertEqual((200, 200), (first_status, second_status))
        self.assertEqual(
            [
                "INVALIDATE v1 collection issues owner/repo",
                "INVALIDATE v1 collection issues owner/repo",
            ],
            self.records,
        )

    def test_status_invalidation_is_exact_sha_and_has_no_process_action(self) -> None:
        payload = self._repository_payload()
        payload["sha"] = "b" * 40
        payload["state"] = "success"
        status, _ = self._request("status", "delivery-status-1", payload)
        self.assertEqual(200, status)
        self.assertEqual(
            [f"INVALIDATE v1 checks owner/repo {'b' * 40}"],
            self.records,
        )

    def test_delivery_ledger_is_bounded(self) -> None:
        SERVER.LEDGER_MAX_ENTRIES = 2
        for number in range(1, 4):
            payload = self._issue_payload(number)
            status, _ = self._request("issues", f"delivery-bound-{number}", payload)
            self.assertEqual(200, status)
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        self.assertEqual(2, len(ledger["deliveries"]))
        self.assertEqual(
            ["delivery-bound-3", "delivery-bound-2"],
            [entry["id"] for entry in ledger["deliveries"]],
        )

    def test_expired_and_implausibly_future_entries_are_pruned(self) -> None:
        SERVER.LEDGER_TTL_SECONDS = 60
        now = int(time.time())
        self.ledger.parent.mkdir(parents=True)
        self.ledger.write_text(
            json.dumps(
                {
                    "schema": "aidevops-webhook-deliveries/v1",
                    "deliveries": [
                        {
                            "event": "issues",
                            "id": "delivery-expired",
                            "outcome": "accepted",
                            "payload_sha256": "a" * 64,
                            "received_at": now - 3600,
                        },
                        {
                            "event": "issues",
                            "id": "delivery-future",
                            "outcome": "accepted",
                            "payload_sha256": "b" * 64,
                            "received_at": now + 3600,
                        },
                    ],
                }
            ),
            encoding="utf-8",
        )
        status, _ = self._request("issues", "delivery-expired", self._issue_payload(16))
        self.assertEqual(200, status)
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        self.assertEqual(["delivery-expired"], [entry["id"] for entry in ledger["deliveries"]])

    def test_delivery_ledger_updates_are_atomic_across_processes(self) -> None:
        self._stop_server()
        try:
            context = multiprocessing.get_context("spawn")
            with context.Pool(processes=4) as pool:
                outcomes = pool.map(
                    _record_delivery_in_process,
                    [(str(self.ledger), worker) for worker in range(12)],
                )
        finally:
            self._start_server()
        self.assertEqual(["accepted"] * 12, outcomes)
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        self.assertEqual(12, len(ledger["deliveries"]))

    def test_delivery_ledger_claims_one_owner_across_processes(self) -> None:
        self._stop_server()
        try:
            context = multiprocessing.get_context("spawn")
            with context.Pool(processes=4) as pool:
                outcomes = pool.map(
                    _record_shared_delivery_in_process,
                    [str(self.ledger)] * 8,
                )
        finally:
            self._start_server()
        self.assertEqual(1, outcomes.count("accepted"))
        self.assertEqual(7, outcomes.count("duplicate"))
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        self.assertEqual(
            ["process-shared-delivery"],
            [entry["id"] for entry in ledger["deliveries"]],
        )

    def test_malformed_ledger_fails_closed_without_actions(self) -> None:
        self.ledger.parent.mkdir(parents=True)
        self.ledger.write_text("{malformed\n", encoding="utf-8")
        payload = self._issue_payload(10)
        status, _ = self._request("issues", "delivery-ledger-failure", payload)
        self.assertEqual(500, status)
        self.assertEqual([], self.records)

    def _dispatch_receiver_records(
        self, records: list[str], *, fail_collection: bool = False, use_queue: bool = False
    ) -> list[str]:
        actions = self.root / "actions.txt"
        actions.write_text("\n".join(records) + "\n", encoding="utf-8")
        call_log = self.root / "dispatch.log"
        evidence_log = self.root / "dispatch-evidence.log"
        script = r'''
source "$RECEIVER_PATH"
if [[ "$USE_QUEUE" == 1 ]]; then
    source "$QUEUE_LIB"
fi
gh_record_efficiency_evidence() {
    local name="$1"
    local value="$2"
    printf '%s|%s\n' "$name" "$value" >>"$EVIDENCE_LOG"
    return 0
}
_webhook_invalidate_collection() {
    local kind="$1"
    local slug="$2"
    printf 'collection|%s|%s\n' "$kind" "$slug" >>"$CALL_LOG"
    [[ "$FAIL_COLLECTION" == "1" ]] && return 1
    return 0
}
_webhook_invalidate_checks() {
    local slug="$1"
    local sha="$2"
    printf 'checks|%s|%s\n' "$slug" "$sha" >>"$CALL_LOG"
    return 0
}
process_pr() {
    local slug="$1"
    local number="$2"
    printf 'process|%s|%s\n' "$slug" "$number" >>"$CALL_LOG"
    return 0
}
while IFS= read -r action_line; do
    _dispatch_webhook_action_line "$action_line"
done <"$ACTIONS_FILE"
wait
'''
        environment = os.environ.copy()
        environment.update(
            {
                "ACTIONS_FILE": str(actions),
                "CALL_LOG": str(call_log),
                "EVIDENCE_LOG": str(evidence_log),
                "FAIL_COLLECTION": "1" if fail_collection else "0",
                "USE_QUEUE": "1" if use_queue else "0",
                "QUEUE_LIB": str(SCRIPTS_DIR / "pulse-merge-dirty-queue.sh"),
                "AIDEVOPS_PULSE_MERGE_DIRTY_QUEUE_DIR": str(self.root / "queue"),
                "HOME": str(self.root / "home"),
                "RECEIVER_PATH": str(RECEIVER_PATH),
                "WEBHOOK_CONF": str(SCRIPTS_DIR.parent / "configs" / "webhook-receiver.conf"),
                "WEBHOOK_LOG_FILE": str(self.root / "receiver.log"),
            }
        )
        result = subprocess.run(
            ["bash", "-c", script],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )  # nosec B603 B607
        self.assertEqual(0, result.returncode, result.stderr or result.stdout)
        self.dispatch_evidence = (
            evidence_log.read_text(encoding="utf-8").splitlines()
            if evidence_log.exists()
            else []
        )
        if not call_log.exists():
            return []
        return call_log.read_text(encoding="utf-8").splitlines()

    def test_receiver_dispatches_invalidation_before_process_pr(self) -> None:
        received_ms = int(time.time() * 1000) - 2_000
        calls = self._dispatch_receiver_records(
            [
                f"DELIVERY v1 received-ms {received_ms}",
                "INVALIDATE v1 collection prs owner/repo",
                f"INVALIDATE v1 checks owner/repo {'c' * 40}",
                "PROCESS_PR owner/repo 12",
            ]
        )
        self.assertEqual(
            [
                "collection|prs|owner/repo",
                f"checks|owner/repo|{'c' * 40}",
                "process|owner/repo|12",
            ],
            calls,
        )
        self.assertEqual(2, self.dispatch_evidence.count("webhook.invalidations|1"))
        lag_samples = [
            int(value.split("|", 1)[1])
            for value in self.dispatch_evidence
            if value.startswith("webhook.lag_ms|")
        ]
        self.assertEqual(2, len(lag_samples))
        self.assertTrue(all(value >= 0 for value in lag_samples))

    def test_receiver_skips_process_when_invalidation_fails(self) -> None:
        calls = self._dispatch_receiver_records(
            [
                f"DELIVERY v1 received-ms {int(time.time() * 1000) - 2_000}",
                "INVALIDATE v1 collection prs owner/repo",
                "PROCESS_PR owner/repo 12",
                "# accepted event=pull_request delivery=fixture invalidations=1 actions=1",
                "PROCESS_PR owner/repo 13",
            ],
            fail_collection=True,
        )
        self.assertEqual(
            ["collection|prs|owner/repo", "process|owner/repo|13"],
            calls,
        )
        self.assertIn("webhook.missed_recoveries|1", self.dispatch_evidence)
        self.assertNotIn("webhook.invalidations|1", self.dispatch_evidence)

    def test_successful_later_invalidation_cannot_clear_delivery_failure(self) -> None:
        calls = self._dispatch_receiver_records(
            [
                f"DELIVERY v1 received-ms {int(time.time() * 1000)}",
                "INVALIDATE v1 collection prs owner/repo",
                f"INVALIDATE v1 checks owner/repo {'c' * 40}",
                "PROCESS_PR owner/repo 12",
            ],
            fail_collection=True,
        )
        self.assertEqual(["collection|prs|owner/repo", f"checks|owner/repo|{'c' * 40}"], calls)

    def test_receiver_coalesces_repeated_pr_wakes(self) -> None:
        calls = self._dispatch_receiver_records(
            ["PROCESS_PR owner/repo 12"] * 3, use_queue=True
        )
        self.assertEqual(["process|owner/repo|12"], calls)

    def test_receiver_rejects_unknown_protocol_before_process_pr(self) -> None:
        calls = self._dispatch_receiver_records(
            [
                "INVALIDATE v2 collection prs owner/repo",
                "PROCESS_PR owner/repo 12",
                "# accepted event=pull_request delivery=fixture invalidations=1 actions=1",
                "PROCESS_PR owner/repo 13",
            ]
        )
        self.assertEqual(["process|owner/repo|13"], calls)

    def test_receiver_removes_original_secret_from_child_environment(self) -> None:
        script = r'''
source "$RECEIVER_PATH"
resolved_secret=$(_resolve_secret)
[[ -n "$resolved_secret" ]]
_clear_webhook_secret_env
[[ -z "${GITHUB_WEBHOOK_SECRET+x}" ]]
'''
        environment = os.environ.copy()
        environment.update(
            {
                "GITHUB_WEBHOOK_SECRET": self.secret.decode("utf-8"),
                "HOME": str(self.root / "home"),
                "RECEIVER_PATH": str(RECEIVER_PATH),
                "WEBHOOK_CONF": str(SCRIPTS_DIR.parent / "configs" / "webhook-receiver.conf"),
                "WEBHOOK_LOG_FILE": str(self.root / "secret-scope.log"),
            }
        )
        result = subprocess.run(
            ["bash", "-c", script],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )  # nosec B603 B607
        self.assertEqual(0, result.returncode, result.stderr or result.stdout)


if __name__ == "__main__":
    unittest.main()
