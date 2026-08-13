#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Registry-backed provider adapters for approved outbound operations."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol

from _knowledge_social_outbound import ClaimedOperation
from _knowledge_social_x import XAdapterError, response_status
from _knowledge_social_x_reader import GuardedXurl, verified_identity
from knowledge_social_import import canonical_json, reject_credentials
from knowledge_social_store import SocialStoreError, validate_opaque

WRITE_TIMEOUT_SECONDS = 120
MAX_PROVIDER_OUTPUT_BYTES = 1024 * 1024


class ProviderAdapterError(RuntimeError):
    """Raised when an approved operation cannot be mapped to safe provider argv."""


class ProviderIdentityError(RuntimeError):
    """Raised when the selected provider account cannot be verified safely."""


class PreparedProvider(Protocol):
    """One validated provider selection for an immutable claimed operation."""

    def verify_identity(self) -> None:
        """Verify the selected provider identity before the write boundary."""

    def invoke(self) -> tuple[str | None, str | None]:
        """Invoke one approved write and return only a safe receipt classification."""


def _profile_args(claimed: ClaimedOperation) -> list[str]:
    options = (
        ("--app", claimed.app_profile),
        ("--username", claimed.username),
    )
    return [part for option, value in options if value for part in (option, value)]


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


@dataclass(frozen=True)
class XPreparedProvider:
    """Prepared official X CLI invocation for one claimed operation."""

    helper: Path
    claimed: ClaimedOperation

    def verify_identity(self) -> None:
        try:
            identity_reader = GuardedXurl(
                self.helper, self.claimed.app_profile, self.claimed.username
            )
            verified_identity(
                identity_reader.identity(), self.claimed.remote_account_id
            )
        except (
            OSError,
            SocialStoreError,
            subprocess.SubprocessError,
            XAdapterError,
        ) as error:
            raise ProviderIdentityError(
                "selected provider identity could not be verified"
            ) from error

    def invoke(self) -> tuple[str | None, str | None]:
        return invoke_provider(self.helper, self.claimed)


def _reddit_response_id(output: str) -> str:
    if len(output.encode("utf-8")) > MAX_PROVIDER_OUTPUT_BYTES:
        raise ProviderAdapterError("Reddit write response exceeds the safety limit")
    try:
        response = json.loads(output)
    except json.JSONDecodeError as error:
        raise ProviderAdapterError("Reddit write response is not valid JSON") from error
    if not isinstance(response, dict):
        raise ProviderAdapterError("Reddit write response root must be an object")
    reject_credentials(response)
    data = response.get("data")
    remote_id = data.get("id") if isinstance(data, dict) else None
    if not isinstance(remote_id, str):
        raise ProviderAdapterError("Reddit write response has no stable remote ID")
    return validate_opaque(remote_id, "provider_remote_id")


@dataclass(frozen=True)
class RedditPreparedProvider:
    """Prepared bounded PRAW subprocess invocation for one claimed operation."""

    helper: Path
    claimed: ClaimedOperation

    def _environment(self) -> dict[str, str]:
        if self.claimed.app_profile is None:
            raise ProviderAdapterError("Reddit operation has no auth profile")
        profile_prefix = f"REDDIT_{self.claimed.app_profile.upper()}_"
        credential_names = {
            f"{profile_prefix}{field}"
            for field in (
                "CLIENT_ID",
                "CLIENT_SECRET",
                "PASSWORD",
                "USER_AGENT",
                "USERNAME",
            )
        }
        inherited = {
            "HOME",
            "HTTPS_PROXY",
            "HTTP_PROXY",
            "LANG",
            "LC_ALL",
            "NO_PROXY",
            "PATH",
            "REQUESTS_CA_BUNDLE",
            "SSL_CERT_FILE",
            "TMPDIR",
            "https_proxy",
            "http_proxy",
            "no_proxy",
        }
        environment = {
            key: value
            for key, value in os.environ.items()
            if key in inherited or key in credential_names
        }
        if os.environ.get("AIDEVOPS_TEST_MODE") == "1":
            for key in (
                "AIDEVOPS_TEST_MODE",
                "PYTHONPATH",
                "REDDIT_LOG",
                "REDDIT_MODE",
            ):
                if key in os.environ:
                    environment[key] = os.environ[key]
        return environment

    def _run(
        self, request: dict[str, str], *, confirm_write: bool
    ) -> subprocess.CompletedProcess[str]:
        if self.claimed.app_profile is None:
            raise ProviderAdapterError("Reddit operation has no auth profile")
        command = [
            sys.executable,
            str(self.helper),
            "--profile",
            self.claimed.app_profile,
        ]
        if confirm_write:
            command.append("--confirm-write")
        return subprocess.run(  # nosec B603 -- fixed local helper and fixed argv
            command,
            check=False,
            capture_output=True,
            input=canonical_json(request),
            env=self._environment(),
            text=True,
            timeout=WRITE_TIMEOUT_SECONDS,
        )

    def verify_identity(self) -> None:
        try:
            completed = self._run({"action": "identity"}, confirm_write=False)
            if completed.returncode != 0:
                raise ProviderIdentityError(
                    "selected provider identity could not be verified"
                )
            remote_id = _reddit_response_id(completed.stdout)
            if remote_id != self.claimed.remote_account_id:
                raise ProviderIdentityError(
                    "selected provider identity does not match the approved account"
                )
        except ProviderIdentityError:
            raise
        except (
            OSError,
            ProviderAdapterError,
            SocialStoreError,
            subprocess.SubprocessError,
            UnicodeError,
        ) as error:
            raise ProviderIdentityError(
                "selected provider identity could not be verified"
            ) from error

    def _write_request(self) -> dict[str, str]:
        request = {"action": self.claimed.action}
        if self.claimed.action == "post":
            if (
                self.claimed.destination_remote_id is None
                or self.claimed.subject is None
                or self.claimed.payload is None
            ):
                raise ProviderAdapterError("Reddit post has an invalid action shape")
            request.update(
                {
                    "destination": self.claimed.destination_remote_id,
                    "subject": self.claimed.subject,
                    "payload": self.claimed.payload,
                }
            )
            return request
        if self.claimed.target_remote_id is None:
            raise ProviderAdapterError("Reddit engagement has no target ID")
        request["target"] = self.claimed.target_remote_id
        if self.claimed.action == "reply":
            if self.claimed.payload is None:
                raise ProviderAdapterError("Reddit reply has no body")
            request["payload"] = self.claimed.payload
        elif self.claimed.action not in ("like", "bookmark"):
            raise ProviderAdapterError("Reddit outbound action is unsupported")
        return request

    def invoke(self) -> tuple[str | None, str | None]:
        try:
            completed = self._run(self._write_request(), confirm_write=True)
        except (OSError, ProviderAdapterError, subprocess.SubprocessError, UnicodeError):
            return None, "provider_unavailable"
        if completed.returncode != 0:
            return None, "provider_unavailable"
        try:
            return _reddit_response_id(completed.stdout), None
        except (ProviderAdapterError, SocialStoreError, UnicodeError):
            return None, "validation"


def _prepare_x(claimed: ClaimedOperation) -> PreparedProvider:
    return XPreparedProvider(Path(__file__).with_name("xurl-helper.sh"), claimed)


def _prepare_reddit(claimed: ClaimedOperation) -> PreparedProvider:
    return RedditPreparedProvider(
        Path(__file__).with_name("_knowledge_social_reddit_provider.py"), claimed
    )


def _prepare_meta(claimed: ClaimedOperation) -> PreparedProvider:
    from _knowledge_social_meta_outbound_provider import MetaPreparedProvider

    return MetaPreparedProvider(claimed)


def _prepare_tiktok(claimed: ClaimedOperation) -> PreparedProvider:
    from _knowledge_social_tiktok_outbound_provider import TikTokPreparedProvider

    return TikTokPreparedProvider(claimed)


PROVIDER_FACTORIES: dict[str, Callable[[ClaimedOperation], PreparedProvider]] = {
    "meta_facebook": _prepare_meta,
    "meta_instagram": _prepare_meta,
    "meta_threads": _prepare_meta,
    "reddit": _prepare_reddit,
    "tiktok": _prepare_tiktok,
    "xapi": _prepare_x,
}


def prepare_provider(claimed: ClaimedOperation) -> PreparedProvider:
    """Resolve one allowlisted provider without accepting executable input."""
    factory = PROVIDER_FACTORIES.get(claimed.provider)
    if factory is None:
        raise ProviderAdapterError("approved outbound provider is unsupported")
    return factory(claimed)
