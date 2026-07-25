#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fixed-argv X provider adapter for approved outbound operations."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from _knowledge_social_outbound import ClaimedOperation
from _knowledge_social_x import XAdapterError, response_status
from knowledge_social_import import reject_credentials
from knowledge_social_store import SocialStoreError, validate_opaque

WRITE_TIMEOUT_SECONDS = 120
MAX_PROVIDER_OUTPUT_BYTES = 1024 * 1024


class ProviderAdapterError(RuntimeError):
    """Raised when an approved operation cannot be mapped to safe provider argv."""


def _profile_args(claimed: ClaimedOperation) -> list[str]:
    arguments: list[str] = []
    if claimed.app_profile:
        arguments.extend(("--app", claimed.app_profile))
    if claimed.username:
        arguments.extend(("--username", claimed.username))
    return arguments


def _write_args(claimed: ClaimedOperation) -> list[str]:
    if claimed.action == "post" and claimed.payload is not None:
        return ["post", claimed.payload]
    if (
        claimed.action == "reply"
        and claimed.target_remote_id is not None
        and claimed.payload is not None
    ):
        return ["reply", claimed.target_remote_id, claimed.payload]
    if claimed.action in ("like", "bookmark") and claimed.target_remote_id:
        return [claimed.action, claimed.target_remote_id]
    raise ProviderAdapterError("approved outbound operation has an invalid action shape")


def _decoded_response(output: str) -> dict[str, object]:
    if len(output.encode("utf-8")) > MAX_PROVIDER_OUTPUT_BYTES:
        raise ProviderAdapterError("xurl write response exceeds the safety limit")
    try:
        response = json.loads(output)
    except json.JSONDecodeError as error:
        raise ProviderAdapterError("xurl write response is not valid JSON") from error
    if not isinstance(response, dict):
        raise ProviderAdapterError("xurl write response root must be an object")
    reject_credentials(response)
    status = response_status(response)
    if status < 200 or status >= 300:
        raise ProviderAdapterError("xurl write response reports a provider failure")
    return response


def _receipt_remote_id(
    claimed: ClaimedOperation, response: dict[str, object]
) -> str:
    if claimed.action in ("like", "bookmark"):
        if claimed.target_remote_id is None:
            raise ProviderAdapterError("engagement receipt has no target ID")
        return claimed.target_remote_id
    data = response.get("data", response)
    remote_id = data.get("id") if isinstance(data, dict) else None
    if not isinstance(remote_id, str):
        raise ProviderAdapterError("xurl write response has no stable post ID")
    return validate_opaque(remote_id, "provider_remote_id")


def _provider_remote_id(claimed: ClaimedOperation, output: str) -> str:
    return _receipt_remote_id(claimed, _decoded_response(output))


def invoke_provider(
    helper: Path, claimed: ClaimedOperation
) -> tuple[str | None, str | None]:
    """Invoke one fixed helper action and classify only privacy-safe outcomes."""
    write_args = _write_args(claimed)
    command = [
        str(helper),
        write_args[0],
        *_profile_args(claimed),
        "--confirm-write",
        "--",
        *write_args[1:],
    ]
    try:
        completed = subprocess.run(  # nosec B603 -- fixed helper and allowlisted action argv
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=WRITE_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        return None, "provider_unavailable"
    if completed.returncode != 0:
        return None, "provider_unavailable"
    try:
        return _provider_remote_id(claimed, completed.stdout), None
    except (ProviderAdapterError, SocialStoreError, UnicodeError, XAdapterError):
        return None, "validation"
