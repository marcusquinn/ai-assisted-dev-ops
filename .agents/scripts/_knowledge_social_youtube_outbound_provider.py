#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Official, resumable YouTube upload adapter for approved video intents."""

from __future__ import annotations

import hashlib
import json
import mimetypes
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from _knowledge_social_youtube_provider import PROFILE_NAME, _access_token
from _knowledge_social_outbound import ClaimedOperation
from _knowledge_social_outbound_provider import ProviderAdapterError, ProviderIdentityError
from knowledge_social_import import reject_credentials
from knowledge_social_store import SocialStoreError, validate_opaque

API_BASE = "https://www.googleapis.com/youtube/v3"
UPLOAD_BASE = "https://www.googleapis.com/upload/youtube/v3"
MAX_RESPONSE_BYTES = 1024 * 1024
HTTP_TIMEOUT_SECONDS = 120
MAX_UPLOAD_BYTES = 2 * 1024**3
UrlOpen = Callable[..., Any]


def _profile(claimed: ClaimedOperation) -> str:
    if claimed.app_profile is None or PROFILE_NAME.fullmatch(claimed.app_profile) is None:
        raise ProviderAdapterError("YouTube outbound operations require a named OAuth profile")
    return claimed.app_profile


def _decode_response(payload: bytes) -> dict[str, Any]:
    if len(payload) > MAX_RESPONSE_BYTES:
        raise ProviderAdapterError("YouTube write response exceeds the safety limit")
    try:
        decoded = json.loads(payload.decode("utf-8")) if payload else {}
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProviderAdapterError("YouTube write response is not valid JSON") from error
    if not isinstance(decoded, dict):
        raise ProviderAdapterError("YouTube write response root must be an object")
    reject_credentials(decoded)
    return decoded


def _api_request(token: str, endpoint: str, params: dict[str, str]) -> Request:
    return Request(
        f"{API_BASE}/{endpoint}?{urlencode(params)}",
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "aidevops-youtube-outbound/1",
        },
        method="GET",
    )


def _verified_media(claimed: ClaimedOperation) -> tuple[Path, int]:
    if claimed.media_path is None or claimed.media_sha256 is None:
        raise ProviderAdapterError("YouTube upload has no bound media")
    path = Path(claimed.media_path)
    stat = path.stat()
    if not path.is_file() or stat.st_size < 1 or stat.st_size > MAX_UPLOAD_BYTES:
        raise ProviderAdapterError("YouTube media is unavailable or outside the size limit")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != claimed.media_sha256:
        raise ProviderAdapterError("YouTube media changed after approval")
    return path, stat.st_size


def _media_type(path: Path) -> str:
    media_type, _encoding = mimetypes.guess_type(path.name)
    if media_type not in {"video/mp4", "video/quicktime", "video/webm"}:
        raise ProviderAdapterError("YouTube media type is unsupported")
    return media_type


@dataclass(frozen=True)
class YouTubePreparedProvider:
    """Prepared YouTube video upload with exact owned-channel verification."""

    claimed: ClaimedOperation
    opener: UrlOpen = urlopen

    def verify_identity(self) -> None:
        try:
            token = _access_token(_profile(self.claimed))
            with self.opener(
                _api_request(
                    token,
                    "channels",
                    {"part": "id", "mine": "true", "maxResults": "1"},
                ),
                timeout=HTTP_TIMEOUT_SECONDS,
            ) as response:
                if getattr(response, "status", 200) != 200:
                    raise ProviderIdentityError("YouTube upload capability or identity is unavailable")
                payload = _decode_response(response.read(MAX_RESPONSE_BYTES + 1))
            items = payload.get("items")
            channel_id = (
                items[0].get("id")
                if isinstance(items, list)
                and len(items) == 1
                and isinstance(items[0], dict)
                else None
            )
            if channel_id != self.claimed.remote_account_id:
                raise ProviderIdentityError("selected YouTube channel does not match the approved account")
            _verified_media(self.claimed)
        except ProviderIdentityError:
            raise
        except (HTTPError, URLError, OSError, SocialStoreError, ProviderAdapterError):
            raise ProviderIdentityError("YouTube upload capability or identity is unavailable") from None

    def _upload(
        self, checkpoint: Callable[[str], None] | None
    ) -> tuple[str | None, str | None]:
        if self.claimed.action != "post" or self.claimed.payload is None or self.claimed.subject is None:
            return None, "validation"
        media, size = _verified_media(self.claimed)
        media_type = _media_type(media)
        token = _access_token(_profile(self.claimed))
        metadata = json.dumps(
            {
                "snippet": {
                    "title": self.claimed.subject,
                    "description": self.claimed.payload,
                },
                "status": {"privacyStatus": "private"},
            },
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        initiate = Request(
            f"{UPLOAD_BASE}/videos?{urlencode({'uploadType': 'resumable', 'part': 'snippet,status'})}",
            data=metadata,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json; charset=UTF-8",
                "Content-Length": str(len(metadata)),
                "X-Upload-Content-Length": str(size),
                "X-Upload-Content-Type": media_type,
                "User-Agent": "aidevops-youtube-outbound/1",
            },
            method="POST",
        )
        with self.opener(initiate, timeout=HTTP_TIMEOUT_SECONDS) as response:
            location = response.headers.get("Location")
        if not isinstance(location, str) or not location.startswith("https://www.googleapis.com/"):
            return None, "validation"
        if checkpoint is not None:
            checkpoint(location)
        with media.open("rb") as handle:
            upload = Request(
                location,
                data=handle.read(),
                headers={
                    "Content-Type": media_type,
                    "Content-Length": str(size),
                    "User-Agent": "aidevops-youtube-outbound/1",
                },
                method="PUT",
            )
            with self.opener(upload, timeout=HTTP_TIMEOUT_SECONDS) as response:
                payload = _decode_response(response.read(MAX_RESPONSE_BYTES + 1))
        remote_id = payload.get("id")
        if not isinstance(remote_id, str):
            return None, "validation"
        return validate_opaque(remote_id, "provider_remote_id"), None

    def invoke(
        self, checkpoint: Callable[[str], None] | None = None
    ) -> tuple[str | None, str | None]:
        try:
            return self._upload(checkpoint)
        except (HTTPError, URLError, OSError):
            return None, "provider_unavailable"
        except (SocialStoreError, ProviderAdapterError, UnicodeError):
            return None, "validation"
