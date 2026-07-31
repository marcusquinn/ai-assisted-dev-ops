#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded, read-only Bluesky/AT Protocol account stream."""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path
from typing import Any

import _knowledge_social_bluesky as bluesky
from _knowledge_social_collect import ContextRequest
from _knowledge_social_collect_cli import CollectorCliPolicy, parse_collector_args, run_collector
from _knowledge_social_collect_state import load_context
from _knowledge_social_lease import (
    RunLeaseRequest,
    SocialLeaseLostError,
    acquire_run_lease,
    fail_active_run,
    release_run_lease,
)
from _knowledge_social_bluesky_normalize import PageContext, normalize_page
from _knowledge_social_bluesky_reader import FixtureBluesky, GuardedBluesky, verified_identity
from _knowledge_social_oauth_collector import OAuthCollector, OAuthCollectorPolicy
from knowledge_social_store import validate_opaque

COLLECTOR_POLICY = OAuthCollectorPolicy(
    display_name="Bluesky",
    provider_module=bluesky,
    helper=Path(__file__).with_name("_knowledge_social_bluesky_provider.py"),
    fixture_reader=FixtureBluesky,
    live_reader=GuardedBluesky,
    page_context=PageContext,
    normalize_page=normalize_page,
    verified_identity=verified_identity,
    budget_unit="request",
    default_budget=19,
    min_budget=7,
    max_page_size=100,
)


class BlueskyCollector(OAuthCollector):
    """Use a stable DID selector instead of the generic opaque account ID."""

    @staticmethod
    def _identity_cost(result: dict[str, Any]) -> dict[str, Any]:
        units = result.get("budget_units")
        if isinstance(units, int) and not isinstance(units, bool):
            result["budget_units"] = units + 2
        return result

    def _budgeted_pages(self, runner: Any, context: Any) -> dict[str, Any]:
        declared_budget = self.args.budget
        self.args.budget = declared_budget - 2
        try:
            return self._identity_cost(self._collect_pages(runner, context))
        finally:
            self.args.budget = declared_budget

    def collect(self, args: Any, root: Path, collector_id: str) -> dict[str, Any]:
        del args
        connection_id = validate_opaque(self.args.connection_id, "connection_id")
        account_id = bluesky.did(self.args.account_id, "configured account DID")
        lease = acquire_run_lease(
            root,
            RunLeaseRequest(
                connection_id,
                self.args.stream,
                collector_id,
                "sync",
                self.args.lease_seconds,
            ),
        )
        try:
            runner = self._runner()
            identity = runner.identity(account_id)
            terminal = self._identity_terminal_result(root, lease, identity)
            if terminal is not None:
                return self._identity_cost(terminal)
            account = self.policy.verified_identity(identity, account_id)
            context = replace(
                load_context(
                    root,
                    ContextRequest(
                        bluesky.PROVIDER,
                        connection_id,
                        account,
                        self.args.stream,
                        "none",
                    ),
                    bluesky.STREAMS,
                ),
                lease=lease,
            )
            return self._budgeted_pages(runner, context)
        except Exception as error:
            try:
                fail_active_run(root, lease, self._failure_class(error))
            except SocialLeaseLostError:
                pass
            raise
        finally:
            release_run_lease(root, lease)


def main() -> int:
    cli_policy = CollectorCliPolicy(
        description=__doc__ or "",
        streams=tuple(bluesky.STREAMS),
        default_budget=COLLECTOR_POLICY.default_budget,
        min_budget=COLLECTOR_POLICY.min_budget,
        max_page_size=COLLECTOR_POLICY.max_page_size,
        budget_unit=COLLECTOR_POLICY.budget_unit,
    )
    args = parse_collector_args(cli_policy)
    return run_collector(args, BlueskyCollector(COLLECTOR_POLICY, args).collect)


if __name__ == "__main__":
    raise SystemExit(main())
