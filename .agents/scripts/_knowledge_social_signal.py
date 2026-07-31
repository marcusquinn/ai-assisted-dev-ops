#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate and normalize bounded offline signal-cli receive notifications."""

from __future__ import annotations

import hashlib
import json
import os
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


def _event_lines(path: Path) -> list[str]:
    _private_regular_file(path, "Signal event input")
    if path.stat().st_size > MAX_INPUT_BYTES:
        raise SignalCollectorError("Signal event input exceeds the bounded input limit")
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise SignalCollectorError("Signal event input is not valid UTF-8") from error
    events = [line[5:].strip() if line.startswith("data:") else line.strip() for line in lines]
    events = [line for line in events if line and not line.startswith(":")]
    if len(events) > MAX_EVENTS:
        raise SignalCollectorError("Signal event input exceeds the event limit")
    return events


def _receive_payload(value: dict[str, Any], expected_account: str) -> dict[str, Any]:
    if value.get("jsonrpc") != "2.0" or value.get("method") != "receive":
        raise SignalCollectorError("Signal input may contain receive notifications only")
    if "id" in value or "result" in value or "error" in value:
        raise SignalCollectorError("Signal input contains a request or response")
    params = value.get("params")
    if not isinstance(params, dict):
        raise SignalCollectorError("Signal receive notification params must be an object")
    wrapped = params.get("result")
    payload = wrapped if isinstance(wrapped, dict) else params
    account = payload.get("account")
    if account != expected_account:
        raise SignalCollectorError("Signal notification account identity does not match config")
    envelope = payload.get("envelope")
    if not isinstance(envelope, dict):
        raise SignalCollectorError("Signal receive notification has no envelope")
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


def _source(envelope: dict[str, Any]) -> str:
    for key in ("sourceUuid", "sourceNumber", "source"):
        value = envelope.get(key)
        if isinstance(value, str) and value:
            return _identity(value, "participant")
    raise SignalCollectorError("Signal envelope has no source identity")


def _group(data: dict[str, Any]) -> str | None:
    group = data.get("groupInfo")
    if group is None:
        return None
    if not isinstance(group, dict):
        raise SignalCollectorError("Signal groupInfo must be an object")
    return _identity(group.get("groupId"), "group")


def _thread(account_id: str, participant_id: str, group_id: str | None) -> str:
    if group_id is not None:
        return f"thread_{_digest('group', group_id)}"
    return f"thread_{_digest('direct', *sorted((account_id, participant_id)))}"


def _message_id(thread_id: str, author_id: str, timestamp: int) -> str:
    return f"msg_{_digest(thread_id, author_id, timestamp)}"


def _base_archive(config: SignalConfig, observed_at: str) -> dict[str, Any]:
    account_id = _identity(config.account, "account")
    return {
        "provider": PROVIDER,
        "connection_id": config.connection_id,
        "remote_account_id": account_id,
        "exported_at": observed_at,
        "enabled_streams": ["offline_receive_notifications"],
        "policy": {
            "account_alias": config.account_alias,
            "account_gate": "every_notification_must_include_matching_account",
            "attachment_policy": "metadata_only_no_path_or_payload_reads",
            "collector_network_access": "none",
            "collector_provider_mutations": "none",
            "disappearing_message_policy": "content_free_tombstone",
            "event_schema": EVENT_SCHEMA,
            "evidence_reviewed_at": EVIDENCE_REVIEWED_AT,
            "official_export_route": "not_validated",
            "signal_cli_released_at": SIGNAL_CLI_RELEASED_AT,
            "signal_cli_version": config.signal_cli_version,
            "source": "offline_jsonrpc_receive_notifications",
            "view_once_policy": "exclude_payload_and_attachment_metadata",
        },
        "accounts": [
            {
                "remote_id": account_id,
                "handle": config.account_alias,
                "display_name": None,
                "observed_at": observed_at,
                "provider_json": {"source": "local_account_gate"},
            }
        ],
        "objects": [],
        "activities": [],
        "media": [],
        "coverage": [],
    }


def _coverage(observed_at: str, earliest: str | None, latest: str | None) -> list[dict[str, Any]]:
    rows = []
    for disposition in CAPABILITY_DISPOSITIONS:
        rows.append(
            {
                **disposition,
                "earliest_at": earliest,
                "latest_at": latest,
                "cursor_exhausted": False,
                "retention_limit": (
                    "provider_expiry_preserved_no_view_once_payload"
                    if disposition["stream"] in {"disappearing_messages", "view_once", "stories"}
                    else "local_protected_corpus_policy"
                ),
                "observed_at": observed_at,
                "unavailable_reason": disposition["reason"],
            }
        )
    return rows


def _attachment_rows(
    attachments: Any, message_id: str, ephemeral: bool
) -> list[dict[str, Any]]:
    if attachments is None:
        return []
    if not isinstance(attachments, list) or len(attachments) > MAX_ATTACHMENTS_PER_MESSAGE:
        raise SignalCollectorError("Signal attachments must be a bounded array")
    if ephemeral:
        return []
    rows = []
    for index, attachment in enumerate(attachments):
        if not isinstance(attachment, dict):
            raise SignalCollectorError("Signal attachment must be an object")
        size = attachment.get("size")
        if size is not None and (
            isinstance(size, bool)
            or not isinstance(size, int)
            or size < 0
            or size > MAX_ATTACHMENT_BYTES
        ):
            raise SignalCollectorError("Signal attachment size is invalid or too large")
        attachment_id = attachment.get("id")
        remote_id = f"media_{_digest(message_id, attachment_id, index)}"
        content_type = _text(attachment.get("contentType"), "attachment content type")
        rows.append(
            {
                "remote_id": remote_id,
                "object_remote_id": message_id,
                "content_sha256": None,
                "mime_type": content_type,
                "byte_size": size,
                "blob_ref": None,
                "hydration_state": "metadata_only",
            }
        )
    return rows


def _message_rows(
    archive: dict[str, Any],
    data: dict[str, Any],
    *,
    author_id: str,
    participant_id: str,
    account_id: str,
    observed_at: str,
    direction: str,
    edit_target: int | None = None,
) -> tuple[str, int]:
    timestamp = _timestamp(data.get("timestamp"), "message timestamp")
    group_id = _group(data)
    thread_id = _thread(account_id, participant_id, group_id)
    message_id = _message_id(thread_id, author_id, timestamp)
    expires = data.get("expiresInSeconds", 0)
    if isinstance(expires, bool) or not isinstance(expires, int) or expires < 0:
        raise SignalCollectorError("Signal expiresInSeconds must be a non-negative integer")
    view_once = data.get("viewOnce") is True
    ephemeral = view_once or expires > 0

    reaction = data.get("reaction")
    if reaction is not None:
        if not isinstance(reaction, dict):
            raise SignalCollectorError("Signal reaction must be an object")
        target_author = reaction.get("targetAuthorUuid") or reaction.get("targetAuthorNumber") or reaction.get("targetAuthor")
        target_id = _message_id(
            thread_id,
            _identity(target_author, "reaction author"),
            _timestamp(reaction.get("targetSentTimestamp"), "reaction target timestamp"),
        )
        archive["activities"].append(
            {
                "activity_type": "message_reaction",
                "remote_id": f"reaction_{_digest(message_id, target_id, reaction.get('emoji'))}",
                "actor_remote_id": author_id,
                "object_remote_id": target_id,
                "occurred_at": _iso_millis(timestamp),
                "observed_at": observed_at,
                "state": "removed" if reaction.get("isRemove") is True else "active",
                "provider_json": {
                    "emoji": _text(reaction.get("emoji"), "reaction emoji"),
                    "source": "signal_cli_notification",
                    "thread_remote_id": thread_id,
                },
            }
        )
        return "reaction", timestamp

    remote_delete = data.get("remoteDelete")
    if remote_delete is not None:
        if not isinstance(remote_delete, dict):
            raise SignalCollectorError("Signal remoteDelete must be an object")
        target_id = _message_id(
            thread_id,
            author_id,
            _timestamp(remote_delete.get("timestamp"), "delete target timestamp"),
        )
        archive["activities"].append(
            {
                "activity_type": "message_deleted",
                "remote_id": f"delete_{_digest(message_id, target_id)}",
                "actor_remote_id": author_id,
                "object_remote_id": target_id,
                "occurred_at": _iso_millis(timestamp),
                "observed_at": observed_at,
                "state": "deleted",
                "provider_json": {
                    "source": "signal_cli_notification",
                    "thread_remote_id": thread_id,
                },
            }
        )
        return "delete", timestamp

    provider_json: dict[str, Any] = {
        "direction": direction,
        "ephemeral": ephemeral,
        "expires_in_seconds": expires,
        "group_remote_id": group_id,
        "source": "signal_cli_notification",
        "thread_remote_id": thread_id,
        "view_once": view_once,
    }
    quote = data.get("quote")
    if quote is not None:
        if not isinstance(quote, dict):
            raise SignalCollectorError("Signal quote must be an object")
        quote_author = quote.get("authorUuid") or quote.get("authorNumber") or quote.get("author")
        provider_json["quote_target_remote_id"] = _message_id(
            thread_id,
            _identity(quote_author, "quote author"),
            _timestamp(quote.get("id"), "quote timestamp"),
        )
    if edit_target is not None:
        provider_json["edit_target_remote_id"] = _message_id(thread_id, author_id, edit_target)

    archive["objects"].append(
        {
            "object_type": "message_tombstone" if ephemeral else ("message_edit" if edit_target else "message"),
            "remote_id": message_id,
            "account_remote_id": account_id if direction == "outbound" else None,
            "text": None if ephemeral else _text(data.get("message"), "message text"),
            "created_at": _iso_millis(timestamp),
            "observed_at": observed_at,
            "evidence_class": "authored" if direction == "outbound" else "observed",
            "provider_json": provider_json,
        }
    )
    archive["activities"].append(
        {
            "activity_type": "message_edited" if edit_target else "message_sent",
            "remote_id": f"activity_{_digest(message_id, 'edit' if edit_target else 'sent')}",
            "actor_remote_id": author_id,
            "object_remote_id": message_id,
            "occurred_at": _iso_millis(timestamp),
            "observed_at": observed_at,
            "state": "tombstone" if ephemeral else "active",
            "provider_json": {"source": "signal_cli_notification", "thread_remote_id": thread_id},
        }
    )
    archive["media"].extend(
        _attachment_rows(data.get("attachments"), message_id, ephemeral)
    )
    return "message", timestamp


def _normalize_envelope(
    archive: dict[str, Any], envelope: dict[str, Any], observed_at: str
) -> tuple[str, int]:
    account_id = archive["remote_account_id"]
    source_id = _source(envelope)
    sync = envelope.get("syncMessage")
    if sync is not None:
        if not isinstance(sync, dict):
            raise SignalCollectorError("Signal syncMessage must be an object")
        sent = sync.get("sentMessage")
        if not isinstance(sent, dict):
            return "sync_metadata", _timestamp(envelope.get("timestamp"), "envelope timestamp")
        destination = sent.get("destinationUuid") or sent.get("destinationNumber") or sent.get("destination")
        participant_id = _identity(destination, "destination")
        edit = sent.get("editMessage")
        if edit is not None:
            if not isinstance(edit, dict) or not isinstance(edit.get("dataMessage"), dict):
                raise SignalCollectorError("Signal sync editMessage is invalid")
            return _message_rows(
                archive,
                edit["dataMessage"],
                author_id=account_id,
                participant_id=participant_id,
                account_id=account_id,
                observed_at=observed_at,
                direction="outbound",
                edit_target=_timestamp(edit.get("targetSentTimestamp"), "edit target timestamp"),
            )
        return _message_rows(
            archive,
            sent,
            author_id=account_id,
            participant_id=participant_id,
            account_id=account_id,
            observed_at=observed_at,
            direction="outbound",
        )

    edit = envelope.get("editMessage")
    if edit is not None:
        if not isinstance(edit, dict) or not isinstance(edit.get("dataMessage"), dict):
            raise SignalCollectorError("Signal editMessage is invalid")
        return _message_rows(
            archive,
            edit["dataMessage"],
            author_id=source_id,
            participant_id=source_id,
            account_id=account_id,
            observed_at=observed_at,
            direction="inbound",
            edit_target=_timestamp(edit.get("targetSentTimestamp"), "edit target timestamp"),
        )

    data = envelope.get("dataMessage")
    if isinstance(data, dict):
        return _message_rows(
            archive,
            data,
            author_id=source_id,
            participant_id=source_id,
            account_id=account_id,
            observed_at=observed_at,
            direction="inbound",
        )
    return "unsupported", _timestamp(envelope.get("timestamp"), "envelope timestamp")


def normalize_events(
    config: SignalConfig, envelopes: list[dict[str, Any]], observed_at: str
) -> tuple[dict[str, Any], dict[str, int]]:
    """Build one canonical archive after validating every event and collision."""
    archive = _base_archive(config, observed_at)
    counts: dict[str, int] = {}
    timestamps: list[int] = []
    for envelope in envelopes:
        kind, timestamp = _normalize_envelope(archive, envelope, observed_at)
        counts[kind] = counts.get(kind, 0) + 1
        timestamps.append(timestamp)

    for key in ("objects", "activities", "media"):
        seen: dict[str, str] = {}
        for row in archive[key]:
            remote_id = row["remote_id"]
            payload = json.dumps(row, sort_keys=True, ensure_ascii=False)
            if remote_id in seen and seen[remote_id] != payload:
                raise SignalCollectorError(f"Signal {key} stable identity collision")
            seen[remote_id] = payload
        archive[key] = list({row["remote_id"]: row for row in archive[key]}.values())

    earliest = _iso_millis(min(timestamps)) if timestamps else None
    latest = _iso_millis(max(timestamps)) if timestamps else None
    archive["coverage"] = _coverage(observed_at, earliest, latest)
    reject_credentials(archive)
    return archive, counts


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
