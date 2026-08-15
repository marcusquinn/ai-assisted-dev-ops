#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded Reddit subprocess adapter for approved outbound operations."""

from __future__ import annotations

import json
import os
import subprocess  # nosec B404 -- required isolated provider boundary
import sys
from dataclasses import dataclass
from pathlib import Path

from _knowledge_social_outbound import ClaimedOperation
from _knowledge_social_provider_common import (
    MAX_PROVIDER_OUTPUT_BYTES,
    WRITE_TIMEOUT_SECONDS,
    ProviderAdapterError,
    ProviderIdentityError,
    PreparedProvider,
)
from knowledge_social_import import canonical_json, reject_credentials
from knowledge_social_store import SocialStoreError, validate_opaque

INHERITED_ENVIRONMENT = frozenset(
    (
        "HOME", "HTTPS_PROXY", "HTTP_PROXY", "LANG", "LC_ALL", "NO_PROXY",
        "PATH", "REQUESTS_CA_BUNDLE", "SSL_CERT_FILE", "TMPDIR", "https_proxy",
        "http_proxy", "no_proxy",
    )
)
TEST_ENVIRONMENT = frozenset(
    ("AIDEVOPS_TEST_MODE", "PYTHONPATH", "REDDIT_LOG", "REDDIT_MODE")
)


def _credential_names(app_profile: str) -> set[str]:
    prefix = f"REDDIT_{app_profile.upper()}_"
    return {
        f"{prefix}{field}"
        for field in ("CLIENT_ID", "CLIENT_SECRET", "PASSWORD", "USER_AGENT", "USERNAME")
    }


def _selected_environment(names: set[str] | frozenset[str]) -> dict[str, str]:
    return {key: os.environ[key] for key in names if key in os.environ}


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
class RedditPreparedProvider(PreparedProvider):
    """Prepared bounded PRAW subprocess invocation for one claimed operation."""

    helper: Path
    claimed: ClaimedOperation

    def _environment(self) -> dict[str, str]:
        if self.claimed.app_profile is None:
            raise ProviderAdapterError("Reddit operation has no auth profile")
        names = set(INHERITED_ENVIRONMENT)
        names.update(_credential_names(self.claimed.app_profile))
        environment = _selected_environment(names)
        if os.environ.get("AIDEVOPS_TEST_MODE") == "1":
            environment.update(_selected_environment(TEST_ENVIRONMENT))
        return environment

    def _run(
        self, request: dict[str, str], *, confirm_write: bool
    ) -> subprocess.CompletedProcess[str]:
        if self.claimed.app_profile is None:
            raise ProviderAdapterError("Reddit operation has no auth profile")
        command = [sys.executable, str(self.helper), "--profile", self.claimed.app_profile]
        if confirm_write:
            command.append("--confirm-write")
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit, python.django.security.injection.command.subprocess-injection.subprocess-injection
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
                raise ProviderIdentityError("selected provider identity could not be verified")
            remote_id = _reddit_response_id(completed.stdout)
            if remote_id != self.claimed.remote_account_id:
                raise ProviderIdentityError(
                    "selected provider identity does not match the approved account"
                )
        except ProviderIdentityError:
            raise
        except (OSError, ProviderAdapterError, SocialStoreError, subprocess.SubprocessError, UnicodeError) as error:
            raise ProviderIdentityError(
                "selected provider identity could not be verified"
            ) from error

    def _post_request(self) -> dict[str, str]:
        if not all(
            (self.claimed.destination_remote_id, self.claimed.subject, self.claimed.payload)
        ):
            raise ProviderAdapterError("Reddit post has an invalid action shape")
        return {
            "action": "post",
            "destination": str(self.claimed.destination_remote_id),
            "subject": str(self.claimed.subject),
            "payload": str(self.claimed.payload),
        }

    def _engagement_request(self) -> dict[str, str]:
        if self.claimed.target_remote_id is None:
            raise ProviderAdapterError("Reddit engagement has no target ID")
        request = {"action": self.claimed.action, "target": self.claimed.target_remote_id}
        if self.claimed.action == "reply":
            if self.claimed.payload is None:
                raise ProviderAdapterError("Reddit reply has no body")
            request["payload"] = self.claimed.payload
        elif self.claimed.action not in ("like", "bookmark"):
            raise ProviderAdapterError("Reddit outbound action is unsupported")
        return request

    def _write_request(self) -> dict[str, str]:
        if self.claimed.action == "post":
            return self._post_request()
        return self._engagement_request()

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


def prepare_reddit(claimed: ClaimedOperation) -> PreparedProvider:
    """Prepare the fixed local Reddit helper for one claimed operation."""
    return RedditPreparedProvider(
        Path(__file__).with_name("_knowledge_social_reddit_provider.py"), claimed
    )
