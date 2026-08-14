#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Owner-authorized outbound social operations and notification workflow CLI."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
import uuid
from pathlib import Path
from typing import Any

from _knowledge_social_notifications import (
    NOTIFICATION_STATUSES,
    list_notifications,
    project_notifications,
    set_notification_status,
)
from _knowledge_social_operation_files import (
    OperationFileError,
    private_media_digest,
    read_private_body,
    read_private_subject,
)
from _knowledge_social_outbound import (
    ACTIONS,
    MAX_SUBJECT_BYTES,
    ClaimedOperation,
    OperationIntent,
    approve_operation,
    cancel_operation,
    create_operation,
    revoke_approval,
)
from _knowledge_social_outbound_provider import (
    ProviderAdapterError,
    ProviderIdentityError,
    prepare_provider,
)
from _knowledge_social_outbound_reconciliation import (
    ReconciliationRequest,
    list_operations,
    reconcile_unknown,
)
from _knowledge_social_outbound_runtime import (
    AttemptOutcome,
    ClaimRequest,
    claim_operation,
    due_operation_ids,
    expire_claims,
    finalize_operation,
    mark_provider_started,
    record_provider_checkpoint,
)
from knowledge_corpus_catalog import DEFAULT_ALIAS, authorized_scope
from knowledge_corpus_context import CatalogError
from knowledge_social_store import (
    SocialStoreError,
    connect,
    migrate,
    require_schema,
    validate_opaque,
    validate_root,
)

DEFAULT_BASE = Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
CONCURRENT_CLAIM_ERRORS = {
    "operation is not due and approved",
    "operation claim lost a concurrent race",
}


class OperationsError(RuntimeError):
    """Raised for privacy-safe outbound CLI failures."""


def _clock(args: argparse.Namespace) -> int:
    override = getattr(args, "now_epoch", None)
    if override is not None:
        if os.environ.get("AIDEVOPS_TEST_MODE") != "1":
            raise OperationsError("test clocks are disabled outside the test harness")
        if override < 0:
            raise OperationsError("test clock must be a non-negative epoch")
        return override
    return int(time.time())


def _managed_context(args: argparse.Namespace) -> tuple[str, Path]:
    principal_id, corpora = authorized_scope(
        args.base or DEFAULT_BASE, "knowledge.manage", args.alias
    )
    return principal_id, validate_root(corpora[0][1])


def _pre_provider_failure(
    database: sqlite3.Connection,
    claimed: ClaimedOperation,
    executor_id: str,
    failure_class: str,
    args: argparse.Namespace,
) -> dict[str, Any]:
    return finalize_operation(
        database,
        claimed,
        executor_id,
        AttemptOutcome(
            "failed", failure_class=failure_class, finished_at=_clock(args)
        ),
    )


def _unknown_provider_outcome(
    database: sqlite3.Connection,
    claimed: ClaimedOperation,
    executor_id: str,
    provider_outcome: tuple[str | None, str],
    args: argparse.Namespace,
) -> dict[str, Any]:
    provider_remote_id, failure_class = provider_outcome
    return finalize_operation(
        database,
        claimed,
        executor_id,
        AttemptOutcome(
            "unknown",
            provider_remote_id=provider_remote_id,
            failure_class=failure_class,
            finished_at=_clock(args),
        ),
    )


def _execute_claimed(
    database: sqlite3.Connection,
    claimed: ClaimedOperation,
    executor_id: str,
    args: argparse.Namespace,
) -> dict[str, Any]:
    try:
        provider = prepare_provider(claimed)
    except ProviderAdapterError:
        return _pre_provider_failure(
            database, claimed, executor_id, "validation", args
        )
    try:
        provider.verify_identity()
    except ProviderIdentityError:
        return _pre_provider_failure(
            database, claimed, executor_id, "identity", args
        )

    try:
        mark_provider_started(
            database, claimed, executor_id, started_at=_clock(args)
        )
    except SocialStoreError:
        return _pre_provider_failure(
            database, claimed, executor_id, "authorization", args
        )

    if claimed.provider == "youtube":
        checkpoint = lambda checkpoint_id: record_provider_checkpoint(
            database, claimed, executor_id, checkpoint_id
        )
        provider_remote_id, failure_class = provider.invoke(checkpoint)
    else:
        provider_remote_id, failure_class = provider.invoke()
    if failure_class is not None:
        return _unknown_provider_outcome(
            database,
            claimed,
            executor_id,
            (provider_remote_id, failure_class),
            args,
        )
    if provider_remote_id is None:
        raise OperationsError("successful provider outcome has no remote ID")
    return finalize_operation(
        database,
        claimed,
        executor_id,
        AttemptOutcome(
            "succeeded",
            provider_remote_id=provider_remote_id,
            finished_at=_clock(args),
        ),
    )


def _executor_id(args: argparse.Namespace) -> str:
    return validate_opaque(
        args.executor_id or f"exe_{uuid.uuid4().hex}", "executor_id"
    )


def _run_one(
    database: sqlite3.Connection,
    principal_id: str,
    operation_id: str,
    executor_id: str,
    args: argparse.Namespace,
) -> dict[str, Any]:
    claimed = claim_operation(
        database,
        ClaimRequest(
            operation_id,
            principal_id,
            executor_id,
            _clock(args),
            args.claim_seconds,
        ),
    )
    return _execute_claimed(database, claimed, executor_id, args)


def _run_due(
    database: sqlite3.Connection,
    principal_id: str,
    args: argparse.Namespace,
) -> dict[str, Any]:
    current_time = _clock(args)
    expired = expire_claims(database, principal_id, current_time, args.limit)
    due = due_operation_ids(database, principal_id, current_time, args.limit)
    executor_id = _executor_id(args)
    results: list[dict[str, Any]] = []
    for operation_id in due:
        try:
            results.append(
                _run_one(
                    database, principal_id, operation_id, executor_id, args
                )
            )
        except SocialStoreError as error:
            if str(error) not in CONCURRENT_CLAIM_ERRORS:
                raise
    return {"expired_claims": len(expired), "results": results}


def _required_now(current_time: int | None) -> int:
    if current_time is None:
        raise OperationsError("operation command requires a current time")
    return current_time


def _handle_operation_create(
    args: argparse.Namespace,
    principal_id: str,
    database: sqlite3.Connection,
    current_time: int | None,
) -> dict[str, Any]:
    created_at = _required_now(current_time)
    payload = read_private_body(args.body_file) if args.body_file else None
    subject = read_private_subject(args.subject_file) if args.subject_file else None
    media_path, media_sha256 = (
        private_media_digest(args.media_file) if args.media_file else (None, None)
    )
    if subject is not None and len(subject.encode("utf-8")) > MAX_SUBJECT_BYTES:
        raise OperationsError("outbound subject exceeds the private subject limit")
    return create_operation(
        database,
        OperationIntent(
            connection_id=args.connection_id,
            remote_account_id=args.account_id,
            action=args.action,
            target_remote_id=args.target_id,
            payload=payload,
            app_profile=args.app,
            username=args.username,
            scheduled_at=(
                args.scheduled_at
                if args.scheduled_at is not None
                else created_at
            ),
            created_by=principal_id,
            destination_remote_id=args.destination_id,
            subject=subject,
            media_path=media_path,
            media_sha256=media_sha256,
            operation_id=args.operation_id,
            created_at=created_at,
        ),
    )


def _handle_operation_approve(
    args: argparse.Namespace,
    principal_id: str,
    database: sqlite3.Connection,
    current_time: int | None,
) -> dict[str, Any]:
    return approve_operation(
        database,
        args.operation_id,
        principal_id,
        args.expires_at,
        approved_at=current_time,
    )


def _handle_operation_revoke(
    args: argparse.Namespace,
    principal_id: str,
    database: sqlite3.Connection,
    current_time: int | None,
) -> dict[str, Any]:
    return revoke_approval(
        database, args.operation_id, principal_id, revoked_at=current_time
    )


def _handle_operation_cancel(
    args: argparse.Namespace,
    principal_id: str,
    database: sqlite3.Connection,
    current_time: int | None,
) -> dict[str, Any]:
    return cancel_operation(
        database, args.operation_id, principal_id, cancelled_at=current_time
    )


def _handle_operation_run(
    args: argparse.Namespace,
    principal_id: str,
    database: sqlite3.Connection,
    _current_time: int | None,
) -> dict[str, Any]:
    return _run_one(
        database, principal_id, args.operation_id, _executor_id(args), args
    )


def _handle_operations_run_due(
    args: argparse.Namespace,
    principal_id: str,
    database: sqlite3.Connection,
    _current_time: int | None,
) -> dict[str, Any]:
    return _run_due(database, principal_id, args)


def _handle_operations_due(
    args: argparse.Namespace,
    principal_id: str,
    database: sqlite3.Connection,
    current_time: int | None,
) -> list[str]:
    return due_operation_ids(
        database, principal_id, _required_now(current_time), args.limit
    )


def _handle_operations_list(
    args: argparse.Namespace,
    principal_id: str,
    database: sqlite3.Connection,
    _current_time: int | None,
) -> list[dict[str, Any]]:
    return list_operations(database, principal_id, args.operation_id, args.limit)


def _handle_operation_reconcile(
    args: argparse.Namespace,
    principal_id: str,
    database: sqlite3.Connection,
    current_time: int | None,
) -> dict[str, Any]:
    if args.outcome == "succeeded" and args.provider_id is None:
        raise OperationsError("successful reconciliation requires --provider-id")
    if args.outcome == "not-sent" and args.provider_id is not None:
        raise OperationsError("not-sent reconciliation forbids --provider-id")
    return reconcile_unknown(
        database,
        ReconciliationRequest(
            args.operation_id,
            principal_id,
            args.outcome,
            args.provider_id,
            current_time,
        ),
    )


def _handle_notifications_refresh(
    _args: argparse.Namespace,
    principal_id: str,
    database: sqlite3.Connection,
    current_time: int | None,
) -> dict[str, int]:
    return project_notifications(database, principal_id, projected_at=current_time)


def _handle_notifications_list(
    args: argparse.Namespace,
    principal_id: str,
    database: sqlite3.Connection,
    _current_time: int | None,
) -> list[dict[str, Any]]:
    return list_notifications(database, principal_id, args.status, args.limit)


def _handle_notification_set(
    args: argparse.Namespace,
    principal_id: str,
    database: sqlite3.Connection,
    current_time: int | None,
) -> dict[str, Any]:
    return set_notification_status(
        database,
        principal_id,
        args.notification_id,
        args.status,
        updated_at=current_time,
    )


COMMAND_HANDLERS = {
    "operation-create": _handle_operation_create,
    "operation-approve": _handle_operation_approve,
    "operation-revoke": _handle_operation_revoke,
    "operation-cancel": _handle_operation_cancel,
    "operation-run": _handle_operation_run,
    "operations-run-due": _handle_operations_run_due,
    "operations-due": _handle_operations_due,
    "operations-list": _handle_operations_list,
    "operation-reconcile": _handle_operation_reconcile,
    "notifications-refresh": _handle_notifications_refresh,
    "notifications-list": _handle_notifications_list,
    "notification-set": _handle_notification_set,
}


def _dispatch(
    args: argparse.Namespace,
    principal_id: str,
    database: sqlite3.Connection,
) -> Any:
    current_time = _clock(args) if hasattr(args, "now_epoch") else None
    handler = COMMAND_HANDLERS.get(args.command)
    if handler is None:
        raise OperationsError("unsupported operation command")
    return handler(args, principal_id, database, current_time)


def _add_scope(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--base", type=Path)
    parser.add_argument("--alias", default=DEFAULT_ALIAS)


def _add_test_clock(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--now-epoch", type=int, help=argparse.SUPPRESS)


def _add_operation_id(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--operation-id", required=True)


def _add_executor(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--executor-id")
    parser.add_argument("--claim-seconds", type=int, default=300)


def _add_create_command(commands: Any) -> None:
    create = commands.add_parser("operation-create")
    _add_scope(create)
    _add_test_clock(create)
    create.add_argument("--connection-id", required=True)
    create.add_argument("--account-id", required=True)
    create.add_argument("--action", choices=ACTIONS, required=True)
    create.add_argument("--target-id")
    create.add_argument("--destination-id")
    create.add_argument("--body-file", type=Path)
    create.add_argument("--subject-file", type=Path)
    create.add_argument("--media-file", type=Path)
    create.add_argument("--app", "--profile", dest="app")
    create.add_argument("--username")
    create.add_argument("--scheduled-at", type=int)
    create.add_argument("--operation-id")


def _add_state_commands(commands: Any) -> None:
    for command in ("operation-approve", "operation-revoke", "operation-cancel"):
        operation = commands.add_parser(command)
        _add_scope(operation)
        _add_test_clock(operation)
        _add_operation_id(operation)
        if command == "operation-approve":
            operation.add_argument("--expires-at", type=int, required=True)


def _add_run_commands(commands: Any) -> None:
    run = commands.add_parser("operation-run")
    _add_scope(run)
    _add_test_clock(run)
    _add_operation_id(run)
    _add_executor(run)

    run_due = commands.add_parser("operations-run-due")
    _add_scope(run_due)
    _add_test_clock(run_due)
    _add_executor(run_due)
    run_due.add_argument("--limit", type=int, default=10)


def _add_inspection_commands(commands: Any) -> None:
    due = commands.add_parser("operations-due")
    _add_scope(due)
    _add_test_clock(due)
    due.add_argument("--limit", type=int, default=100)

    operation_list = commands.add_parser("operations-list")
    _add_scope(operation_list)
    operation_list.add_argument("--operation-id")
    operation_list.add_argument("--limit", type=int, default=100)

    reconcile = commands.add_parser("operation-reconcile")
    _add_scope(reconcile)
    _add_test_clock(reconcile)
    _add_operation_id(reconcile)
    reconcile.add_argument("--outcome", choices=("succeeded", "not-sent"), required=True)
    reconcile.add_argument("--provider-id")


def _add_notification_commands(commands: Any) -> None:
    refresh = commands.add_parser("notifications-refresh")
    _add_scope(refresh)
    _add_test_clock(refresh)

    notification_list = commands.add_parser("notifications-list")
    _add_scope(notification_list)
    notification_list.add_argument("--status", choices=NOTIFICATION_STATUSES)
    notification_list.add_argument("--limit", type=int, default=100)

    notification_set = commands.add_parser("notification-set")
    _add_scope(notification_set)
    _add_test_clock(notification_set)
    notification_set.add_argument("--notification-id", required=True)
    notification_set.add_argument("--status", choices=NOTIFICATION_STATUSES, required=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    _add_create_command(commands)
    _add_state_commands(commands)
    _add_run_commands(commands)
    _add_inspection_commands(commands)
    _add_notification_commands(commands)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    database: sqlite3.Connection | None = None
    try:
        principal_id, root = _managed_context(args)
        database = connect(root)
        migrate(database)
        require_schema(database)
        result = _dispatch(args, principal_id, database)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (
        CatalogError,
        OSError,
        OperationFileError,
        OperationsError,
        ProviderAdapterError,
        ProviderIdentityError,
        SocialStoreError,
        sqlite3.Error,
        ValueError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    finally:
        if database is not None:
            database.close()


if __name__ == "__main__":
    raise SystemExit(main())
