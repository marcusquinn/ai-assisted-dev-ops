#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Hermetic contract tests for approval-bound Meta and TikTok writes."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from _knowledge_social_meta_outbound_provider import MetaPreparedProvider
from _knowledge_social_outbound import ClaimedOperation, OUTBOUND_PROVIDER_ACTIONS
from _knowledge_social_outbound_provider import prepare_provider
from _knowledge_social_tiktok_outbound_provider import TikTokPreparedProvider


def claimed(
    provider: str, *, account: str = "acct_approved", media_ref: str | None = None
) -> ClaimedOperation:
    """Build a private, already-approved publish claim for one fixture."""
    return ClaimedOperation(
        operation_id="op_idempotent",
        provider=provider,
        action="post",
        remote_account_id=account,
        target_remote_id=None,
        destination_remote_id=media_ref,
        payload="private campaign body",
        subject=None,
        app_profile=None,
        username=None,
        claim_token=1,
        attempt_id="att_fixture",
    )


class MetaTikTokOutboundTests(unittest.TestCase):
    """Prove identity, idempotency, unknown, and redaction boundaries."""

    def test_registry_allows_only_documented_actions(self) -> None:
        self.assertEqual(OUTBOUND_PROVIDER_ACTIONS["meta_facebook"], ("post", "reply"))
        self.assertEqual(OUTBOUND_PROVIDER_ACTIONS["meta_instagram"], ("post",))
        self.assertEqual(OUTBOUND_PROVIDER_ACTIONS["meta_threads"], ("post", "reply"))
        self.assertEqual(OUTBOUND_PROVIDER_ACTIONS["tiktok"], ("post",))

    def test_unconfigured_registry_adapter_cannot_reach_write_boundary(self) -> None:
        adapter = prepare_provider(claimed("tiktok", media_ref="media_approved"))
        with self.assertRaisesRegex(Exception, "transport is unavailable"):
            adapter.verify_identity()
        self.assertEqual(adapter.invoke(), (None, "provider_unavailable"))

    def test_meta_publishes_after_exact_identity_and_returns_only_remote_id(self) -> None:
        calls: list[dict[str, str]] = []

        def transport(request: dict[str, str]) -> dict[str, str]:
            calls.append(request)
            if request["operation"] == "identity":
                return {"id": "acct_approved"}
            return {"state": "succeeded", "id": "post_opaque"}

        adapter = MetaPreparedProvider(claimed("meta_threads"), transport)
        adapter.verify_identity()
        receipt = adapter.invoke()
        self.assertEqual(receipt, ("post_opaque", None))
        self.assertEqual(calls[1]["idempotency_key"], "op_idempotent")
        self.assertNotIn("private campaign body", str(receipt))
        self.assertEqual(len(calls), 2)

    def test_identity_mismatch_makes_zero_publish_requests(self) -> None:
        calls: list[dict[str, str]] = []

        def transport(request: dict[str, str]) -> dict[str, str]:
            calls.append(request)
            return {"id": "acct_other"}

        adapter = MetaPreparedProvider(claimed("meta_facebook"), transport)
        with self.assertRaisesRegex(Exception, "does not match"):
            adapter.verify_identity()
        self.assertEqual([call["operation"] for call in calls], ["identity"])

    def test_tiktok_accepted_publish_is_unknown_with_stable_publish_id(self) -> None:
        def transport(request: dict[str, str]) -> dict[str, str]:
            if request["operation"] == "identity":
                return {"id": "acct_approved"}
            return {"state": "accepted", "publish_id": "job_stable"}

        adapter = TikTokPreparedProvider(
            claimed("tiktok", media_ref="media_approved"), transport
        )
        adapter.verify_identity()
        self.assertEqual(adapter.invoke(), ("job_stable", "runtime"))

    def test_tiktok_requires_an_approved_media_reference(self) -> None:
        adapter = TikTokPreparedProvider(
            claimed("tiktok"), lambda _: {"id": "acct_approved"}
        )
        adapter.verify_identity()
        self.assertEqual(adapter.invoke(), (None, "validation"))


if __name__ == "__main__":
    unittest.main()
