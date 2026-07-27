#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared execution loop for identity-bound OAuth social collectors."""

from __future__ import annotations

import argparse
import os
import sqlite3
import subprocess
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Callable, Protocol

from _knowledge_social_collect import (
    CollectionContext,
    CollectionProgress,
    ContextRequest,
    CursorState,
    PageCheckpoint,
    SuccessfulPage,
    TerminalDecision,
    collection_result,
    terminal_decision_for_status,
)
from _knowledge_social_collect_cli import (
    CollectorCliPolicy,
    parse_collector_args,
    run_collector,
)
from _knowledge_social_collect_persist import (
    persist_page,
    record_bounded_stop,
    record_terminal_result,
)
from _knowledge_social_collect_state import load_context
from _knowledge_social_lease import (
    RunLease,
    RunLeaseRequest,
    RunReceiptUpdate,
    SocialLeaseLostError,
    acquire_run_lease,
    fail_active_run,
    finish_active_run,
    release_run_lease,
    renew_run_lease,
)
from knowledge_social_import import reject_credentials
from knowledge_social_store import validate_opaque

IDENTITY_COST_UNITS = 1


class EvidenceRequest(Protocol):
    """Minimum provider request contract needed for immutable evidence."""

    def evidence_key(self) -> str: ...


class OAuthReader(Protocol):
    """Identity and page reads exposed by a guarded provider adapter."""

    def identity(self, expected_id: str) -> dict[str, Any]: ...

    def page(self, request: Any) -> dict[str, Any]: ...


class OAuthProviderModule(Protocol):
    """Provider policy surface consumed by the shared collector."""

    PROVIDER: str
    STREAMS: dict[str, Any]
    ADAPTER_ERROR: type[Exception]
    PROVIDER_UNAVAILABLE_ERROR: type[Exception]

    def page_request(
        self, stream: str, account: dict[str, Any], state: CursorState, limit: int
    ) -> EvidenceRequest: ...

    def page_checkpoint(
        self, payload: dict[str, Any], state: CursorState, request: Any
    ) -> tuple[PageCheckpoint, bool]: ...

    def response_status(self, payload: dict[str, Any]) -> int: ...


@dataclass(frozen=True)
class OAuthCollectorPolicy:
    """Provider-specific callbacks consumed by the shared OAuth loop."""

    display_name: str
    provider_module: OAuthProviderModule
    helper: Path
    fixture_reader: Callable[[Path], OAuthReader]
    live_reader: Callable[[Path, str], OAuthReader]
    page_context: Callable[..., Any]
    normalize_page: Callable[[dict[str, Any], Any], dict[str, Any]]
    verified_identity: Callable[[dict[str, Any], str], dict[str, Any]]
    budget_unit: str
    default_budget: int = 11
    min_budget: int = 3
    max_page_size: int = 50


@dataclass
class OAuthCollector:
    """Run one provider policy under shared lease and persistence rules."""

    policy: OAuthCollectorPolicy
    args: argparse.Namespace

    def _runner(self) -> OAuthReader:
        if self.args.fixture and os.environ.get("AIDEVOPS_TEST_MODE") != "1":
            raise self.policy.provider_module.ADAPTER_ERROR(
                f"{self.policy.display_name} fixtures are disabled outside the test harness"
            )
        if self.args.fixture:
            return self.policy.fixture_reader(self.args.fixture)
        return self.policy.live_reader(self.policy.helper, self.args.profile)

    def _decision(self, payload: dict[str, Any]) -> TerminalDecision | None:
        status = self.policy.provider_module.response_status(payload)
        return terminal_decision_for_status(status)

    def _page_context(self, context: CollectionContext) -> Any:
        return self.policy.page_context(
            context.connection_id,
            context.account,
            context.stream,
            context.config.enabled_streams,
            context.config.policy,
        )

    def _persist_success(
        self,
        context: CollectionContext,
        payload: dict[str, Any],
        request: EvidenceRequest,
    ) -> tuple[CollectionContext, int, bool]:
        checkpoint, complete = self.policy.provider_module.page_checkpoint(
            payload, context.state, request
        )
        archive = self.policy.normalize_page(payload, self._page_context(context))
        page = SuccessfulPage(
            payload,
            request.evidence_key(),
            archive,
            checkpoint,
            complete,
            context.spec.cost_units,
            retention_limit=context.spec.retention_limit,
            unavailable_reason=context.spec.unavailable_reason,
            coverage_status=context.spec.coverage_status,
        )
        resources = persist_page(context, page)
        state = CursorState(checkpoint.next_cursor, checkpoint.watermark, complete)
        return replace(context, state=state), resources, complete

    def _collect_pages(
        self, runner: OAuthReader, initial: CollectionContext
    ) -> dict[str, Any]:
        context = initial
        progress = CollectionProgress(budget_units=IDENTITY_COST_UNITS)
        while progress.budget_units + context.spec.cost_units <= self.args.budget:
            if context.lease is None:
                raise self.policy.provider_module.ADAPTER_ERROR(
                    f"{self.policy.display_name} collection requires a collector lease"
                )
            context = replace(
                context,
                lease=renew_run_lease(
                    context.root, context.lease, self.args.lease_seconds
                ),
            )
            request = self.policy.provider_module.page_request(
                context.stream,
                context.account,
                context.state,
                self.args.page_size,
            )
            payload = runner.page(request)
            reject_credentials(payload)
            decision = self._decision(payload)
            if decision:
                return record_terminal_result(
                    context, payload, request.evidence_key(), decision, progress
                )
            context, resources, complete = self._persist_success(
                context, payload, request
            )
            progress = progress.advance(resources, context.spec.cost_units)
            if complete:
                return collection_result(
                    "complete", progress, run_id=context.lease.run_id
                )
        record_bounded_stop(context, "paused", "budget")
        return collection_result(
            "budget_exhausted",
            progress,
            run_id=context.lease.run_id if context.lease else None,
        )

    def _failure_class(self, error: Exception) -> str:
        if isinstance(error, self.policy.provider_module.PROVIDER_UNAVAILABLE_ERROR):
            return "provider"
        if isinstance(error, self.policy.provider_module.ADAPTER_ERROR):
            return "validation"
        if isinstance(error, sqlite3.Error):
            return "storage"
        if isinstance(error, subprocess.SubprocessError):
            return "provider"
        return "runtime"

    def _identity_terminal_result(
        self, root: Path, lease: RunLease, payload: dict[str, Any]
    ) -> dict[str, Any] | None:
        reject_credentials(payload)
        decision = self._decision(payload)
        if decision is None:
            return None
        retry_value = payload.get("retry_after")
        if retry_value is not None:
            if isinstance(retry_value, bool) or not isinstance(
                retry_value, (int, str)
            ):
                raise self.policy.provider_module.ADAPTER_ERROR(
                    f"{self.policy.display_name} retry_after must be text or an integer"
                )
        retry_after = str(retry_value) if retry_value is not None else None
        finish_active_run(
            root,
            lease,
            RunReceiptUpdate(
                decision.run_status,
                failure_class=decision.failure_class,
                retry_after=retry_after,
            ),
        )
        return collection_result(
            decision.output_status,
            CollectionProgress(budget_units=IDENTITY_COST_UNITS),
            failure_class=decision.failure_class,
            retry_after=retry_after,
            run_id=lease.run_id,
        )

    def collect(
        self,
        args: argparse.Namespace,
        root: Path,
        collector_id: str,
    ) -> dict[str, Any]:
        del args
        connection_id = validate_opaque(self.args.connection_id, "connection_id")
        account_id = validate_opaque(self.args.account_id, "account_id")
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
                return terminal
            account = self.policy.verified_identity(identity, account_id)
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


def run_oauth_collector(policy: OAuthCollectorPolicy, description: str) -> int:
    """Parse one provider CLI and execute its shared OAuth collector."""
    cli_policy = CollectorCliPolicy(
        description=description,
        streams=tuple(policy.provider_module.STREAMS),
        default_budget=policy.default_budget,
        min_budget=policy.min_budget,
        max_page_size=policy.max_page_size,
        budget_unit=policy.budget_unit,
    )
    args = parse_collector_args(cli_policy)
    collector = OAuthCollector(policy, args)
    return run_collector(args, collector.collect)
