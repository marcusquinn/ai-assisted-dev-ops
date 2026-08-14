#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fixture tests for capability-gated LinkedIn and YouTube outbound adapters."""

from __future__ import annotations

import hashlib
import io
import os
import secrets
import tempfile
import unittest
from datetime import datetime, timezone
from email.message import Message
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError

from _knowledge_social_linkedin_outbound_provider import LinkedInPreparedProvider
from _knowledge_social_outbound import ClaimedOperation
from _knowledge_social_outbound_provider import (
    MAX_PROVIDER_RETRY_SECONDS,
    ProviderRateLimitError,
    provider_retry_seconds,
    redirect_free_provider_open,
)
from _knowledge_social_youtube_outbound_provider import YouTubePreparedProvider

FIXTURE_ACCESS_TOKEN = secrets.token_hex(24)


class Response:
    def __init__(self, status: int, body: bytes, headers: dict[str, str] | None = None):
        self.status = status
        self._body = body
        self.headers = Message()
        for key, value in (headers or {}).items():
            self.headers[key] = value

    def read(self, _limit: int = -1) -> bytes:
        return self._body

    def __enter__(self) -> Response:
        return self

    def __exit__(self, *_args: object) -> None:
        return None


def claimed(provider: str, **values: str | None) -> ClaimedOperation:
    return ClaimedOperation(
        operation_id="op_fixture",
        provider=provider,
        action="post",
        remote_account_id=values.get("account") or "channel_fixture",
        target_remote_id=None,
        destination_remote_id=None,
        payload="private description",
        subject=values.get("subject"),
        app_profile="fixture",
        username=None,
        claim_token=1,
        attempt_id="att_fixture",
        media_path=values.get("media_path"),
        media_sha256=values.get("media_sha256"),
    )


class OutboundProviderTests(unittest.TestCase):
    def test_retry_after_duration_is_validated_and_bounded(self) -> None:
        self.assertEqual(2, provider_retry_seconds("1.5"))
        self.assertEqual(
            MAX_PROVIDER_RETRY_SECONDS,
            provider_retry_seconds(str(MAX_PROVIDER_RETRY_SECONDS * 2)),
        )
        self.assertIsNone(provider_retry_seconds("-1"))
        self.assertIsNone(provider_retry_seconds("not-a-duration"))
        current_time = datetime(2026, 8, 14, 11, tzinfo=timezone.utc).timestamp()
        self.assertEqual(
            3600,
            provider_retry_seconds(
                "Fri, 14 Aug 2026 12:00:00 GMT", current_time=current_time
            ),
        )

    def test_provider_defaults_reject_authorization_bearing_redirects(self) -> None:
        self.assertIs(
            redirect_free_provider_open,
            LinkedInPreparedProvider(claimed("linkedin")).opener,
        )
        self.assertIs(
            redirect_free_provider_open,
            YouTubePreparedProvider(claimed("youtube")).opener,
        )

    @patch.dict(os.environ, {"LINKEDIN_FIXTURE_ACCESS_TOKEN": FIXTURE_ACCESS_TOKEN})
    def test_linkedin_identity_mismatch_prevents_post(self) -> None:
        calls: list[str] = []

        def opener(request: object, **_kwargs: object) -> Response:
            calls.append(getattr(request, "method"))
            return Response(200, b'{"elements":[{"member":"member_other"}]}')

        provider = LinkedInPreparedProvider(claimed("linkedin", account="member_fixture"), opener)
        with self.assertRaisesRegex(Exception, "does not match"):
            provider.verify_identity()
        self.assertEqual(calls, ["GET"])

    @patch.dict(os.environ, {"LINKEDIN_FIXTURE_ACCESS_TOKEN": FIXTURE_ACCESS_TOKEN})
    def test_linkedin_post_preserves_bounded_rate_limit_evidence(self) -> None:
        responses = iter(
            [
                Response(200, b'{"elements":[{"member":"member_fixture"}]}'),
                Response(429, b"", {"Retry-After": "300"}),
            ]
        )
        provider = LinkedInPreparedProvider(
            claimed("linkedin", account="member_fixture"),
            lambda _request, **_kwargs: next(responses),
        )
        provider.verify_identity()
        with self.assertRaises(ProviderRateLimitError) as raised:
            provider.invoke()
        self.assertEqual(300, raised.exception.retry_after_seconds)

    @patch.dict(os.environ, {"YOUTUBE_FIXTURE_ACCESS_TOKEN": FIXTURE_ACCESS_TOKEN})
    def test_youtube_upload_requires_exact_channel_and_bound_media(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".mp4") as media:
            media.write(b"fixture video")
            media.flush()
            digest = hashlib.sha256(b"fixture video").hexdigest()
            provider = YouTubePreparedProvider(
                claimed(
                    "youtube",
                    media_path=media.name,
                    media_sha256=digest,
                    subject="Fixture video",
                ),
                lambda _request, **_kwargs: Response(200, b'{"items":[{"id":"channel_other"}]}'),
            )
            with self.assertRaisesRegex(Exception, "does not match"):
                provider.verify_identity()

    @patch.dict(os.environ, {"YOUTUBE_FIXTURE_ACCESS_TOKEN": FIXTURE_ACCESS_TOKEN})
    def test_youtube_successful_private_upload_returns_stable_id(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".mp4") as media:
            media.write(b"fixture video")
            media.flush()
            digest = hashlib.sha256(b"fixture video").hexdigest()
            responses = iter(
                [
                    Response(200, b'{"items":[{"id":"channel_fixture"}]}'),
                    Response(200, b"", {"Location": "https://www.googleapis.com/upload/session_fixture"}),
                    Response(200, b'{"id":"video_fixture"}'),
                ]
            )
            provider = YouTubePreparedProvider(
                claimed("youtube", media_path=media.name, media_sha256=digest, subject="Fixture video"),
                lambda _request, **_kwargs: next(responses),
            )
            provider.verify_identity()
            checkpoints: list[str] = []
            self.assertEqual(
                provider.invoke(checkpoints.append), ("video_fixture", None)
            )
            self.assertEqual(
                checkpoints,
                ["https://www.googleapis.com/upload/session_fixture"],
            )

    @patch.dict(os.environ, {"YOUTUBE_FIXTURE_ACCESS_TOKEN": FIXTURE_ACCESS_TOKEN})
    def test_youtube_rejects_unsupported_media_before_mutation(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".txt") as media:
            media.write(b"fixture video")
            media.flush()
            digest = hashlib.sha256(b"fixture video").hexdigest()
            provider = YouTubePreparedProvider(
                claimed("youtube", media_path=media.name, media_sha256=digest, subject="Fixture"),
                lambda _request, **_kwargs: Response(200, b'{"items":[{"id":"channel_fixture"}]}'),
            )
            provider.verify_identity()
            self.assertEqual(provider.invoke(), (None, "validation"))

    @patch.dict(os.environ, {"YOUTUBE_FIXTURE_ACCESS_TOKEN": FIXTURE_ACCESS_TOKEN})
    def test_youtube_upload_preserves_bounded_rate_limit_evidence(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".mp4") as media:
            media.write(b"fixture video")
            media.flush()
            digest = hashlib.sha256(b"fixture video").hexdigest()
            responses = iter(
                [
                    Response(200, b'{"items":[{"id":"channel_fixture"}]}'),
                    Response(429, b"", {"Retry-After": "600"}),
                ]
            )
            provider = YouTubePreparedProvider(
                claimed(
                    "youtube",
                    media_path=media.name,
                    media_sha256=digest,
                    subject="Fixture video",
                ),
                lambda _request, **_kwargs: next(responses),
            )
            provider.verify_identity()
            with self.assertRaises(ProviderRateLimitError) as raised:
                provider.invoke()
            self.assertEqual(600, raised.exception.retry_after_seconds)

    @patch.dict(os.environ, {"YOUTUBE_FIXTURE_ACCESS_TOKEN": FIXTURE_ACCESS_TOKEN})
    def test_youtube_quota_403_uses_the_rate_limit_path(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".mp4") as media:
            media.write(b"fixture video")
            media.flush()
            digest = hashlib.sha256(b"fixture video").hexdigest()
            headers = Message()
            quota_error = HTTPError(
                "https://www.googleapis.com/upload/youtube/v3/videos",
                403,
                "quota",
                headers,
                io.BytesIO(b'{"error":{"errors":[{"reason":"quotaExceeded"}]}}'),
            )
            responses: list[Response | HTTPError] = [
                Response(200, b'{"items":[{"id":"channel_fixture"}]}'),
                quota_error,
            ]

            def opener(_request: object, **_kwargs: object) -> Response:
                response = responses.pop(0)
                if isinstance(response, HTTPError):
                    raise response
                return response

            provider = YouTubePreparedProvider(
                claimed(
                    "youtube",
                    media_path=media.name,
                    media_sha256=digest,
                    subject="Fixture video",
                ),
                opener,
            )
            provider.verify_identity()
            with self.assertRaises(ProviderRateLimitError) as raised:
                provider.invoke()
            self.assertIsNone(raised.exception.retry_after_seconds)


if __name__ == "__main__":
    unittest.main()
