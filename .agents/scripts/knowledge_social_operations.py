#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Owner-authorized outbound social operations and notification workflow CLI."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
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
from _knowledge_social_outbound import (
    ACTIONS,
    MAX_PAYLOAD_BYTES,
    ClaimedOperation,
    approve_operation,
    cancel_operation,
    claim_operation,
    create_operation,
    due_operation_ids,
    expire_claims,
    finalize_operation,
    list_operations,
    mark_provider_started,
    reconcile_unknown,
    revoke_approval,
)
from _knowledge_social_x import XAdapterError, response_status
from _knowledge_social_x_reader import GuardedXurl, verified_identity
from knowledge_corpus_catalog import DEFAULT_ALIAS, authorized_scope
from knowledge_corpus_context import CatalogError, validate_private_file
from knowledge_social_import import reject_credentials
from knowledge_social_store import (
    SocialStoreError,
    connect,
    migrate,
    require_schema,
    validate_opaque,
    validate_root,
)

DEFAULT_BASE = Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
WRITE_TIMEOUT_SECONDS = 120
MAX_PROVIDER_OUTPUT_BYTES = 1024 * 1024
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


def _read_private_body(path: Path) -> str:
    try:
        validate_private_file(path, "outbound body", repair=False)
        before = path.lstat()
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
    except (CatalogError, OSError) as error:
        raise OperationsError("outbound body is unavailable or unsafe") from error
    try:
        after = os.fstat(descriptor)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise OperationsError("outbound body replacement detected")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            payload = handle.read(MAX_PAYLOAD_BYTES + 1)
    except OSError as error:
        raise OperationsError("outbound body is unavailable or unsafe") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise OperationsError("outbound body exceeds the private payload limit")
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise OperationsError("outbound body must be UTF-8") from error


def _managed_context(args: argparse.Namespace) -> tuple[str, Path]:
    principal_id, corpora = authorized_scope(
        args.base or DEFAULT_BASE, "knowledge.manage", args.alias
    )
    return principal_id, validate_root(corpora[0][1])


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
    raise OperationsError("approved outbound operation has an invalid action shape")


def _provider_remote_id(claimed: ClaimedOperation, output: str) -> str:
    if len(output.encode("utf-8")) > MAX_PROVIDER_OUTPUT_BYTES:
        raise OperationsError("xurl write response exceeds the safety limit")
    try:
        response = json.loads(output)
    except json.JSONDecodeError as error:
        raise OperationsError("xurl write response is not valid JSON") from error
    if not isinstance(response, dict):
        raise OperationsError("xurl write response root must be an object")
    reject_credentials(response)
    status = response_status(response)
    if status < 200 or status >= 300:
        raise OperationsError("xurl write response reports a provider failure")
    if claimed.action in ("like", "bookmark"):
        if claimed.target_remote_id is None:
            raise OperationsError("engagement receipt has no target ID")
        return claimed.target_remote_id
    data = response.get("data", response)
    remote_id = data.get("id") if isinstance(data, dict) else None
    if not isinstance(remote_id, str):
        raise OperationsError("xurl write response has no stable post ID")
    return validate_opaque(remote_id, "provider_remote_id")


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
        "failed",
        failure_class=failure_class,
        finished_at=_clock(args),
    )


def _unknown_provider_outcome(
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
        "unknown",
        failure_class=failure_class,
        finished_at=_clock(args),
    )


def _execute_claimed(
    database: sqlite3.Connection,
    claimed: ClaimedOperation,
    executor_id: str,
    args: argparse.Namespace,
) -> dict[str, Any]:
    helper = Path(__file__).with_name("xurl-helper.sh")
    try:
        identity_reader = GuardedXurl(
            helper, claimed.app_profile, claimed.username
        )
        verified_identity(identity_reader.identity(), claimed.remote_account_id)
    except (OSError, SocialStoreError, subprocess.SubprocessError, XAdapterError):
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
        return _unknown_provider_outcome(
            database, claimed, executor_id, "provider_unavailable", args
        )
    if completed.returncode != 0:
        return _unknown_provider_outcome(
            database, claimed, executor_id, "provider_unavailable", args
        )
    try:
        provider_remote_id = _provider_remote_id(claimed, completed.stdout)
    except (OperationsError, SocialStoreError, UnicodeError, XAdapterError):
        return _unknown_provider_outcome(
            database, claimed, executor_id, "validation", args
        )
    return finalize_operation(
        database,
        claimed,
        executor_id,
        "succeeded",
        provider_remote_id=provider_remote_id,
        finished_at=_clock(args),
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
        operation_id,
        principal_id,
        executor_id,
        _clock(args),
        args.claim_seconds,
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


def _dispatch(
    args: argparse.Namespace,
    principal_id: str,
    database: sqlite3.Connection,
) -> Any:
    now = _clock(args) if hasattr(args, "now_epoch") else None
    if args.command == "operation-create":
        payload = _read_private_body(args.body_file) if args.body_file else None
        return create_operation(
            database,
            connection_id=args.connection_id,
            remote_account_id=args.account_id,
            action=args.action,
            target_remote_id=args.target_id,
            payload=payload,
            app_profile=args.app,
            username=args.username,
            scheduled_at=args.scheduled_at if args.scheduled_at is not None else now,
            created_by=principal_id,
            operation_id=args.operation_id,
            created_at=now,
        )
    if args.command == "operation-approve":
        return approve_operation(
            database,
            args.operation_id,
            principal_id,
            args.expires_at,
            approved_at=now,
        )
    if args.command == "operation-revoke":
        return revoke_approval(
            database, args.operation_id, principal_id, revoked_at=now
        )
    if args.command == "operation-cancel":
        return cancel_operation(
            database, args.operation_id, principal_id, cancelled_at=now
        )
    if args.command == "operation-run":
        return _run_one(
            database,
            principal_id,
            args.operation_id,
            _executor_id(args),
            args,
        )
    if args.command == "operations-run-due":
        return _run_due(database, principal_id, args)
    if args.command == "operations-due":
        return due_operation_ids(database, principal_id, now, args.limit)
    if args.command == "operations-list":
        return list_operations(
            database, principal_id, args.operation_id, args.limit
        )
    if args.command == "operation-reconcile":
        if args.outcome == "succeeded" and args.provider_id is None:
            raise OperationsError("successful reconciliation requires --provider-id")
        if args.outcome == "not-sent" and args.provider_id is not None:
            raise OperationsError("not-sent reconciliation forbids --provider-id")
        return reconcile_unknown(
            database,
            args.operation_id,
            principal_id,
            args.outcome,
            args.provider_id,
            reconciled_at=now,
        )
    if args.command == "notifications-refresh":
        return project_notifications(database, principal_id, projected_at=now)
    if args.command == "notifications-list":
        return list_notifications(database, principal_id, args.status, args.limit)
    return set_notification_status(
        database,
        principal_id,
        args.notification_id,
        args.status,
        updated_at=now,
    )


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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    create = commands.add_parser("operation-create")
    _add_scope(create)
    _add_test_clock(create)
    create.add_argument("--connection-id", required=True)
    create.add_argument("--account-id", required=True)
    create.add_argument("--action", choices=ACTIONS, required=True)
    create.add_argument("--target-id")
    create.add_argument("--body-file", type=Path)
    create.add_argument("--app")
    create.add_argument("--username")
    create.add_argument("--scheduled-at", type=int)
    create.add_argument("--operation-id")

    for command in ("operation-approve", "operation-revoke", "operation-cancel"):
        operation = commands.add_parser(command)
        _add_scope(operation)
        _add_test_clock(operation)
        _add_operation_id(operation)
        if command == "operation-approve":
            operation.add_argument("--expires-at", type=int, required=True)

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
        OperationsError,
        SocialStoreError,
        XAdapterError,
        sqlite3.Error,
        subprocess.SubprocessError,
        ValueError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    finally:
        if database is not None:
            database.close()


if __name__ == "__main__":
    raise SystemExit(main())
