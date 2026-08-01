#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate and normalize bounded offline signal-cli receive notifications."""

from __future__ import annotations

import hashlib
import json
import re
import stat
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from knowledge_social_import import reject_credentials
from knowledge_social_store import SocialStoreError, validate_opaque

PROVIDER = "signal"
SIGNAL_CLI_VERSION = "0.14.6"
SIGNAL_CLI_RELEASED_AT = "2026-07-13"
EVIDENCE_REVIEWED_AT = "2026-07-31"
EVENT_SCHEMA = "signal-cli-jsonrpc-v0.14.6"
MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_EVENTS = 1000
MAX_TEXT_CHARS = 1_000_000
MAX_ATTACHMENTS_PER_MESSAGE = 64
MAX_ATTACHMENT_BYTES = 512 * 1024 * 1024
ACCOUNT_VALUE = re.compile(r"^(?:\+[1-9][0-9]{7,14}|[0-9a-fA-F-]{32,36})$")


class SignalCollectorError(SocialStoreError):
    """Raised when Signal evidence cannot be handled without side effects."""


@dataclass(frozen=True)
class SignalConfig:
    """Private account gate and public-safe local aliases."""

    account: str
    account_alias: str
    connection_id: str
    signal_cli_version: str


CAPABILITY_DISPOSITIONS: tuple[dict[str, str], ...] = (
    {
        "stream": "direct_messages",
        "status": "partial",
        "reason": "offline_notifications_only_no_provider_history_query",
    },
    {
        "stream": "group_messages",
        "status": "partial",
        "reason": "offline_notifications_only_group_membership_history_unavailable",
    },
    {
        "stream": "quotes_replies",
        "status": "partial",
        "reason": "quote_target_metadata_only_quoted_payload_not_duplicated",
    },
    {
        "stream": "edits_deletions",
        "status": "partial",
        "reason": "observed_notifications_only_no_authoritative_delete_history",
    },
    {
        "stream": "reactions",
        "status": "partial",
        "reason": "observed_notifications_only_no_reaction_history_query",
    },
    {
        "stream": "attachments",
        "status": "partial",
        "reason": "metadata_only_collector_never_reads_signal_cli_attachment_paths",
    },
    {
        "stream": "contacts_groups",
        "status": "partial",
        "reason": "message_participants_and_group_ids_only_no_contact_or_group_mutation_route",
    },
    {
        "stream": "delivery_history",
        "status": "partial",
        "reason": "local_device_notifications_only_receipt_history_not_imported",
    },
    {
        "stream": "stories",
        "status": "excluded",
        "reason": "ephemeral_story_payloads_are_not_persisted",
    },
    {
        "stream": "disappearing_messages",
        "status": "excluded",
        "reason": "payloads_with_expiry_are_replaced_by_content_free_tombstones",
    },
    {
        "stream": "view_once",
        "status": "excluded",
        "reason": "view_once_payloads_and_attachment_metadata_are_not_persisted",
    },
    {
        "stream": "identity_safety_changes",
        "status": "unavailable",
        "reason": "signal_cli_receive_schema_has_no_validated_identity_change_event_contract",
    },
    {
        "stream": "pre_link_history",
        "status": "unavailable",
        "reason": "linked_device_receive_notifications_do_not_provide_pre_link_history",
    },
    {
        "stream": "official_export_backup",
        "status": "unavailable",
        "reason": "no_validated_official_third_party_message_export_contract",
    },
)


def utc_now() -> str:
    """Return one UTC observation timestamp."""
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _private_regular_file(path: Path, label: str) -> Path:
    if path.is_symlink() or not path.is_file():
        raise SignalCollectorError(f"{label} must be a regular non-symlink file")
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        raise SignalCollectorError(f"{label} permissions must not allow group or other access")
    return path


def _bounded_json(path: Path, label: str) -> dict[str, Any]:
    _private_regular_file(path, label)
    if path.stat().st_size > MAX_INPUT_BYTES:
        raise SignalCollectorError(f"{label} exceeds the bounded input limit")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SignalCollectorError(f"{label} is not valid UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise SignalCollectorError(f"{label} root must be an object")
    return value


def load_config(path: Path) -> SignalConfig:
    """Load a mode-0600 account gate without exposing its provider identifier."""
    value = _bounded_json(path, "Signal collector config")
    if set(value) != {
        "schema_version",
        "account",
        "account_alias",
        "connection_id",
        "signal_cli_version",
    }:
        raise SignalCollectorError("Signal collector config keys do not match schema version 1")
    if value["schema_version"] != 1:
        raise SignalCollectorError("Signal collector config schema_version must be 1")
    account = value["account"]
    if not isinstance(account, str) or not ACCOUNT_VALUE.fullmatch(account):
        raise SignalCollectorError("Signal account must be an E.164 number or UUID")
    alias = value["account_alias"]
    connection_id = value["connection_id"]
    if not isinstance(alias, str) or not isinstance(connection_id, str):
        raise SignalCollectorError("Signal account_alias and connection_id must be text")
    validate_opaque(alias, "Signal account alias")
    validate_opaque(connection_id, "Signal connection ID")
    version = value["signal_cli_version"]
    if version != SIGNAL_CLI_VERSION:
        raise SignalCollectorError(
            f"Signal event schema is pinned to signal-cli {SIGNAL_CLI_VERSION}"
        )
    return SignalConfig(account, alias, connection_id, version)


def _read_event_lines(path: Path) -> list[str]:
    _private_regular_file(path, "Signal event input")
    if path.stat().st_size > MAX_INPUT_BYTES:
        raise SignalCollectorError("Signal event input exceeds the bounded input limit")
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise SignalCollectorError("Signal event input is not valid UTF-8") from error


def _clean_event_line(line: str) -> str | None:
    payload = line[5:] if line.startswith("data:") else line
    event = payload.strip()
    if not event or event.startswith(":"):
        return None
    return event


def _event_lines(path: Path) -> list[str]:
    cleaned = (_clean_event_line(line) for line in _read_event_lines(path))
    events = [line for line in cleaned if line is not None]
    if len(events) > MAX_EVENTS:
        raise SignalCollectorError("Signal event input exceeds the event limit")
    return events


def _validate_notification(value: dict[str, Any]) -> None:
    if value.get("jsonrpc") != "2.0":
        raise SignalCollectorError("Signal input may contain receive notifications only")
    if value.get("method") != "receive":
        raise SignalCollectorError("Signal input may contain receive notifications only")
    if {"id", "result", "error"}.intersection(value):
        raise SignalCollectorError("Signal input contains a request or response")


def _notification_payload(value: dict[str, Any]) -> dict[str, Any]:
    params = value.get("params")
    if not isinstance(params, dict):
        raise SignalCollectorError("Signal receive notification params must be an object")
    wrapped = params.get("result")
    if isinstance(wrapped, dict):
        return wrapped
    return params


def _notification_envelope(
    payload: dict[str, Any], expected_account: str
) -> dict[str, Any]:
    if payload.get("account") != expected_account:
        raise SignalCollectorError("Signal notification account identity does not match config")
    envelope = payload.get("envelope")
    if not isinstance(envelope, dict):
        raise SignalCollectorError("Signal receive notification has no envelope")
    return envelope


def _receive_payload(value: dict[str, Any], expected_account: str) -> dict[str, Any]:
    _validate_notification(value)
    payload = _notification_payload(value)
    envelope = _notification_envelope(payload, expected_account)
    reject_credentials(envelope)
    return envelope


def load_events(path: Path, config: SignalConfig) -> list[dict[str, Any]]:
    """Read bounded JSONL or SSE data lines and complete the final identity fence."""
    envelopes: list[dict[str, Any]] = []
    for line_number, line in enumerate(_event_lines(path), 1):
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise SignalCollectorError(
                f"Signal event line {line_number} is not valid JSON"
            ) from error
        if not isinstance(value, dict):
            raise SignalCollectorError(f"Signal event line {line_number} must be an object")
        envelopes.append(_receive_payload(value, config.account))
    return envelopes


def _digest(*parts: object) -> str:
    payload = json.dumps(parts, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:40]


def _identity(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 256:
        raise SignalCollectorError(f"Signal {field} is missing or invalid")
    return f"id_{_digest(field, value)}"


def _timestamp(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise SignalCollectorError(f"Signal {field} must be a positive integer")
    return value


def _iso_millis(value: int) -> str:
    try:
        return datetime.fromtimestamp(value / 1000, timezone.utc).isoformat().replace(
            "+00:00", "Z"
        )
    except (OSError, OverflowError, ValueError) as error:
        raise SignalCollectorError("Signal timestamp is outside the supported range") from error


def _text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > MAX_TEXT_CHARS:
        raise SignalCollectorError(f"Signal {field} is invalid or too large")
    return value


def route_status() -> dict[str, Any]:
    """Return the dated no-live-route and offline-event disposition."""
    return {
        "provider": PROVIDER,
        "route": "offline_pre_captured_jsonrpc_receive_notifications_only",
        "live_collector": "unavailable_due_to_unavoidable_default_delivery_receipts",
        "official_export_backup": "no_validated_third_party_message_export_contract",
        "signal_cli": {
            "supported_version": SIGNAL_CLI_VERSION,
            "released_at": SIGNAL_CLI_RELEASED_AT,
            "schema": EVENT_SCHEMA,
            "installed_dependency_required": False,
        },
        "reviewed_at": EVIDENCE_REVIEWED_AT,
        "dispositions": list(CAPABILITY_DISPOSITIONS),
        "forbidden_actions": [
            "send",
            "sendReceipt",
            "sendTyping",
            "sendReaction",
            "trust",
            "updateContact",
            "updateGroup",
            "remoteDelete",
            "subscribeReceive",
        ],
    }
