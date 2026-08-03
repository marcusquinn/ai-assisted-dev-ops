#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared-loop adaptation for a mutable public Hacker News username selector."""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path
from typing import Any

from _knowledge_social_collect import (
    CollectionProgress,
    ContextRequest,
    collection_result,
)
from _knowledge_social_collect_cli import (
    CollectorCliPolicy,
    parse_collector_args,
    run_collector,
)
from _knowledge_social_collect_persist import record_terminal
from _knowledge_social_collect_state import load_context
from _knowledge_social_hacker_news_identity import selector_id, username
from _knowledge_social_lease import (
    RunLeaseRequest,
    SocialLeaseLostError,
    acquire_run_lease,
    fail_active_run,
    release_run_lease,
)
from _knowledge_social_oauth_collector import OAuthCollector, OAuthCollectorPolicy
from knowledge_social_import import canonical_json, reject_credentials
from knowledge_social_store import validate_opaque


class HackerNewsCollector(OAuthCollector):
    """Run shared persistence without treating the username as an opaque ID."""

    def collect(
        self,
        args: Any,
        root: Path,
        collector_id: str,
    ) -> dict[str, Any]:
        del args
        connection_id = validate_opaque(self.args.connection_id, "connection_id")
        selected = username(self.args.account_id)
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
            identity = runner.identity(selected)
            reject_credentials(identity)
            decision = self._decision(identity)
            if decision is not None:
                account = {
                    "id": selector_id(selected),
                    "username": selected,
                    "availability": "unavailable",
                    "submitted": [],
                    "identity_boundary": "public_mutable_username_selector",
                }
                context = replace(
                    load_context(
                        root,
                        ContextRequest(
                            self.policy.provider_module.PROVIDER,
                            connection_id,
                            account,
                            self.args.stream,
                            "none",
                        ),
                        self.policy.provider_module.STREAMS,
                    ),
                    lease=lease,
                )
                context = replace(
                    context,
                    spec=replace(
                        context.spec,
                        cost_units=self.policy.identity_cost_units,
                    ),
                )
                retry_after = record_terminal(
                    context,
                    identity,
                    canonical_json({"action": "identity", "account_id": selected}),
                    decision,
                )
                return collection_result(
                    decision.output_status,
                    CollectionProgress(
                        budget_units=self.policy.identity_cost_units
                    ),
                    failure_class=decision.failure_class,
                    retry_after=retry_after,
                    run_id=lease.run_id,
                )
            account = self.policy.verified_identity(identity, selected)
            context = replace(
                load_context(
                    root,
                    ContextRequest(
                        self.policy.provider_module.PROVIDER,
                        connection_id,
                        account,
                        self.args.stream,
                        "none",
                    ),
                    self.policy.provider_module.STREAMS,
                ),
                lease=lease,
            )
            return self._collect_pages(runner, context)
        except Exception as error:
            try:
                fail_active_run(root, lease, self._failure_class(error))
            except SocialLeaseLostError:
                pass
            raise
        finally:
            release_run_lease(root, lease)


def run_hacker_news_collector(
    policy: OAuthCollectorPolicy, description: str
) -> int:
    cli_policy = CollectorCliPolicy(
        description=description,
        streams=tuple(policy.provider_module.STREAMS),
        default_budget=policy.default_budget,
        min_budget=policy.min_budget,
        max_page_size=policy.max_page_size,
        budget_unit=policy.budget_unit,
    )
    args = parse_collector_args(cli_policy)
    return run_collector(args, HackerNewsCollector(policy, args).collect)
