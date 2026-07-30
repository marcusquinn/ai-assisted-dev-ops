#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared guarded child-process adapter for OAuth social readers."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Protocol

from _knowledge_social_collect_cli import (
    GuardedReaderProcess,
    guarded_reader_environment,
)

PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")


class PagePayload(Protocol):
    """Minimum request contract consumed by a guarded OAuth reader."""

    def payload(self) -> dict[str, Any]: ...


@dataclass(frozen=True)
class GuardedOAuthPolicy:
    """Provider-specific child-process boundaries for one OAuth reader."""

    display_name: str
    environment_prefix: str
    test_log_key: str
    timeout_seconds: int
    decode_output: Callable[[str], dict[str, Any]]
    provider_failure: Callable[[str], Exception]
    unavailable_error: type[Exception]
    credential_suffixes: tuple[str, ...] = ("ACCESS_TOKEN",)
    profile_kind: str = "OAuth"


class GuardedOAuthReader:
    """Execute only identity and allowlisted page reads in a bounded child."""

    def __init__(self, helper: Path, profile: str, policy: GuardedOAuthPolicy) -> None:
        if PROFILE_NAME.fullmatch(profile) is None:
            kind = f" {policy.profile_kind}" if policy.profile_kind else ""
            raise policy.unavailable_error(
                f"{policy.display_name}{kind} profile name is invalid"
            )
        if helper.is_symlink() or not helper.is_file():
            raise policy.unavailable_error(
                f"{policy.display_name} read provider is unavailable"
            )
        self.profile = profile
        self.policy = policy
        self.process = GuardedReaderProcess(
            helper=helper,
            profile=profile,
            environment=self._environment,
            timeout_seconds=policy.timeout_seconds,
            decode_output=policy.decode_output,
            provider_failure=policy.provider_failure,
            unavailable_error=policy.unavailable_error,
            provider_name=policy.display_name,
        )

    def _environment(self) -> dict[str, str]:
        profile_prefix = (
            f"{self.policy.environment_prefix}_{self.profile.upper()}"
        )
        credential_names = tuple(
            f"{profile_prefix}_{suffix}"
            for suffix in self.policy.credential_suffixes
        )
        return guarded_reader_environment(
            credential_names, (self.policy.test_log_key,)
        )

    def identity(self, expected_id: str) -> dict[str, Any]:
        return self.process.run({"action": "identity", "account_id": expected_id})

    def page(self, request: PagePayload) -> dict[str, Any]:
        return self.process.run(request.payload())
