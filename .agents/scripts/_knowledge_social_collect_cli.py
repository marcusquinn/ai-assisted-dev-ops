#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared CLI and guarded subprocess boundaries for live social collectors."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from knowledge_corpus_catalog import DEFAULT_ALIAS, authorized_scope
from knowledge_corpus_context import CatalogError
from knowledge_social_import import canonical_json
from knowledge_social_store import SocialStoreError, validate_opaque, validate_root

Collector = Callable[[argparse.Namespace, Path, str], dict[str, Any]]
EnvironmentFactory = Callable[[], dict[str, str]]
OutputDecoder = Callable[[str], dict[str, Any]]
ProviderFailure = Callable[[str], Exception]
READER_ENVIRONMENT_KEYS = frozenset(
    {
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
)


@dataclass(frozen=True)
class CollectorCliPolicy:
    """Provider-specific limits for the shared collector CLI."""

    description: str
    streams: tuple[str, ...]
    default_budget: int
    min_budget: int
    max_page_size: int
    budget_unit: str


@dataclass(frozen=True)
class GuardedReaderProcess:
    """Fixed child-process contract shared by live social readers."""

    helper: Path
    profile: str
    environment: EnvironmentFactory
    timeout_seconds: int
    decode_output: OutputDecoder
    provider_failure: ProviderFailure
    unavailable_error: type[Exception]
    provider_name: str

    def run(self, request: dict[str, Any]) -> dict[str, Any]:
        """Execute one serialized request with a filtered environment."""
        try:
            completed = subprocess.run(  # nosec B603 -- fixed helper and fixed argv
                [sys.executable, str(self.helper), "--profile", self.profile],
                check=False,
                capture_output=True,
                input=canonical_json(request),
                env=self.environment(),
                shell=False,
                text=True,
                timeout=self.timeout_seconds,
            )
        except subprocess.TimeoutExpired as error:
            raise self.unavailable_error(
                f"{self.provider_name} read provider timed out"
            ) from error
        except OSError as error:
            raise self.unavailable_error(
                f"{self.provider_name} read provider is unavailable"
            ) from error
        if completed.returncode != 0:
            raise self.provider_failure(completed.stderr)
        return self.decode_output(completed.stdout)


def guarded_reader_environment(
    token_name: str, test_keys: tuple[str, ...] = ()
) -> dict[str, str]:
    """Expose only one provider token and bounded runtime support variables."""
    environment = {
        key: value
        for key, value in os.environ.items()
        if key in READER_ENVIRONMENT_KEYS or key == token_name
    }
    if os.environ.get("AIDEVOPS_TEST_MODE") == "1":
        for key in ("AIDEVOPS_TEST_MODE", "PYTHONPATH", *test_keys):
            if key in os.environ:
                environment[key] = os.environ[key]
    return environment


def parse_collector_args(policy: CollectorCliPolicy) -> argparse.Namespace:
    """Parse the common bounded collector CLI using provider policy."""
    parser = argparse.ArgumentParser(description=policy.description)
    parser.add_argument("--base", type=Path)
    parser.add_argument("--alias", default=DEFAULT_ALIAS)
    parser.add_argument("--connection-id", required=True)
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--stream", required=True, choices=policy.streams)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--budget", type=int, default=policy.default_budget)
    parser.add_argument("--page-size", type=int, default=policy.max_page_size)
    parser.add_argument("--collector-id")
    parser.add_argument("--lease-seconds", type=int, default=300)
    parser.add_argument("--fixture", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.budget < policy.min_budget or args.budget > 1000:
        parser.error(
            f"--budget must be between {policy.min_budget} and 1000 "
            f"{policy.budget_unit} units"
        )
    if args.page_size < 1 or args.page_size > policy.max_page_size:
        parser.error(
            f"--page-size must be between 1 and {policy.max_page_size} items"
        )
    if args.lease_seconds < 1 or args.lease_seconds > 86400:
        parser.error("--lease-seconds must be between 1 and 86400")
    return args


def run_collector(args: argparse.Namespace, collector: Collector) -> int:
    """Resolve one authorized corpus and print a sanitized collector result."""
    try:
        base = (
            args.base
            if args.base
            else Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
        )
        principal_id, corpora = authorized_scope(base, "knowledge.write", args.alias)
        root = validate_root(corpora[0][1])
        collector_id = validate_opaque(
            args.collector_id or principal_id, "collector_id"
        )
        print(json.dumps(collector(args, root, collector_id), sort_keys=True))
        return 0
    except (
        CatalogError,
        OSError,
        SocialStoreError,
        sqlite3.Error,
        subprocess.SubprocessError,
        ValueError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
