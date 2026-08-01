#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize validated offline signal-cli notifications into social archives."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from _knowledge_social_signal import (
    CAPABILITY_DISPOSITIONS,
    EVIDENCE_REVIEWED_AT,
    EVENT_SCHEMA,
    PROVIDER,
    SIGNAL_CLI_RELEASED_AT,
    SignalCollectorError,
    SignalConfig,
    _digest,
    _identity,
    _iso_millis,
    _text,
    _timestamp,
)
from _knowledge_social_signal_media import attachment_rows
from knowledge_social_import import reject_credentials


@dataclass(frozen=True)
class MessageContext:
    """Identity and policy context shared by one normalized message event."""

    archive: dict[str, Any]
    account_id: str
    author_id: str
    participant_id: str
    observed_at: str
    direction: str


@dataclass(frozen=True)
class MessageState:
    """Validated identifiers and expiry state for one message event."""

    timestamp: int
    thread_id: str
    message_id: str
    group_id: str | None
    expires: int
    view_once: bool
    ephemeral: bool


def _source(envelope: dict[str, Any]) -> str:
    source = next(
        (
            envelope.get(key)
            for key in ("sourceUuid", "sourceNumber", "source")
            if isinstance(envelope.get(key), str) and envelope.get(key)
        ),
        None,
    )
    return _identity(source, "participant")


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


def _retention_limit(stream: str) -> str:
    ephemeral_streams = {"disappearing_messages", "view_once", "stories"}
    if stream in ephemeral_streams:
        return "provider_expiry_preserved_no_view_once_payload"
    return "local_protected_corpus_policy"


def _coverage(
    observed_at: str, earliest: str | None, latest: str | None
) -> list[dict[str, Any]]:
    return [
        {
            **disposition,
            "earliest_at": earliest,
            "latest_at": latest,
            "cursor_exhausted": False,
            "retention_limit": _retention_limit(disposition["stream"]),
            "observed_at": observed_at,
            "unavailable_reason": disposition["reason"],
        }
        for disposition in CAPABILITY_DISPOSITIONS
    ]


def _message_state(context: MessageContext, data: dict[str, Any]) -> MessageState:
    timestamp = _timestamp(data.get("timestamp"), "message timestamp")
    group_id = _group(data)
    thread_id = _thread(context.account_id, context.participant_id, group_id)
    expires = data.get("expiresInSeconds", 0)
    if isinstance(expires, bool) or not isinstance(expires, int):
        raise SignalCollectorError(
            "Signal expiresInSeconds must be a non-negative integer"
        )
    if expires < 0:
        raise SignalCollectorError(
            "Signal expiresInSeconds must be a non-negative integer"
        )
    view_once = data.get("viewOnce") is True
    return MessageState(
        timestamp=timestamp,
        thread_id=thread_id,
        message_id=_message_id(thread_id, context.author_id, timestamp),
        group_id=group_id,
        expires=expires,
        view_once=view_once,
        ephemeral=view_once or expires > 0,
    )


def _reaction_author(reaction: dict[str, Any]) -> Any:
    return (
        reaction.get("targetAuthorUuid")
        or reaction.get("targetAuthorNumber")
        or reaction.get("targetAuthor")
    )


def _append_reaction(
    context: MessageContext, state: MessageState, reaction: Any
) -> None:
    if not isinstance(reaction, dict):
        raise SignalCollectorError("Signal reaction must be an object")
    target_id = _message_id(
        state.thread_id,
        _identity(_reaction_author(reaction), "reaction author"),
        _timestamp(reaction.get("targetSentTimestamp"), "reaction target timestamp"),
    )
    context.archive["activities"].append(
        {
            "activity_type": "message_reaction",
            "remote_id": (
                f"reaction_{_digest(state.message_id, target_id, reaction.get('emoji'))}"
            ),
            "actor_remote_id": context.author_id,
            "object_remote_id": target_id,
            "occurred_at": _iso_millis(state.timestamp),
            "observed_at": context.observed_at,
            "state": "removed" if reaction.get("isRemove") is True else "active",
            "provider_json": {
                "emoji": _text(reaction.get("emoji"), "reaction emoji"),
                "source": "signal_cli_notification",
                "thread_remote_id": state.thread_id,
            },
        }
    )


def _append_delete(
    context: MessageContext, state: MessageState, remote_delete: Any
) -> None:
    if not isinstance(remote_delete, dict):
        raise SignalCollectorError("Signal remoteDelete must be an object")
    target_id = _message_id(
        state.thread_id,
        context.author_id,
        _timestamp(remote_delete.get("timestamp"), "delete target timestamp"),
    )
    context.archive["activities"].append(
        {
            "activity_type": "message_deleted",
            "remote_id": f"delete_{_digest(state.message_id, target_id)}",
            "actor_remote_id": context.author_id,
            "object_remote_id": target_id,
            "occurred_at": _iso_millis(state.timestamp),
            "observed_at": context.observed_at,
            "state": "deleted",
            "provider_json": {
                "source": "signal_cli_notification",
                "thread_remote_id": state.thread_id,
            },
        }
    )


def _quote_target(data: dict[str, Any], thread_id: str) -> str | None:
    quote = data.get("quote")
    if quote is None:
        return None
    if not isinstance(quote, dict):
        raise SignalCollectorError("Signal quote must be an object")
    author = quote.get("authorUuid") or quote.get("authorNumber") or quote.get("author")
    return _message_id(
        thread_id,
        _identity(author, "quote author"),
        _timestamp(quote.get("id"), "quote timestamp"),
    )


def _provider_json(
    context: MessageContext,
    data: dict[str, Any],
    state: MessageState,
    edit_target: int | None,
) -> dict[str, Any]:
    provider_json: dict[str, Any] = {
        "direction": context.direction,
        "ephemeral": state.ephemeral,
        "expires_in_seconds": state.expires,
        "group_remote_id": state.group_id,
        "source": "signal_cli_notification",
        "thread_remote_id": state.thread_id,
        "view_once": state.view_once,
    }
    quote_target = _quote_target(data, state.thread_id)
    if quote_target is not None:
        provider_json["quote_target_remote_id"] = quote_target
    if edit_target is not None:
        provider_json["edit_target_remote_id"] = _message_id(
            state.thread_id, context.author_id, edit_target
        )
    return provider_json


def _object_type(state: MessageState, edit_target: int | None) -> str:
    if state.ephemeral:
        return "message_tombstone"
    if edit_target is not None:
        return "message_edit"
    return "message"


def _append_content(
    context: MessageContext,
    data: dict[str, Any],
    state: MessageState,
    edit_target: int | None,
) -> None:
    context.archive["objects"].append(
        {
            "object_type": _object_type(state, edit_target),
            "remote_id": state.message_id,
            "account_remote_id": (
                context.account_id if context.direction == "outbound" else None
            ),
            "text": (
                None
                if state.ephemeral
                else _text(data.get("message"), "message text")
            ),
            "created_at": _iso_millis(state.timestamp),
            "observed_at": context.observed_at,
            "evidence_class": (
                "authored" if context.direction == "outbound" else "observed"
            ),
            "provider_json": _provider_json(context, data, state, edit_target),
        }
    )
    action = "edit" if edit_target is not None else "sent"
    context.archive["activities"].append(
        {
            "activity_type": (
                "message_edited" if edit_target is not None else "message_sent"
            ),
            "remote_id": f"activity_{_digest(state.message_id, action)}",
            "actor_remote_id": context.author_id,
            "object_remote_id": state.message_id,
            "occurred_at": _iso_millis(state.timestamp),
            "observed_at": context.observed_at,
            "state": "tombstone" if state.ephemeral else "active",
            "provider_json": {
                "source": "signal_cli_notification",
                "thread_remote_id": state.thread_id,
            },
        }
    )
    context.archive["media"].extend(
        attachment_rows(data.get("attachments"), state.message_id, state.ephemeral)
    )


def _message_rows(
    context: MessageContext, data: dict[str, Any], edit_target: int | None = None
) -> tuple[str, int]:
    state = _message_state(context, data)
    kind = "message"
    if data.get("reaction") is not None:
        _append_reaction(context, state, data["reaction"])
        kind = "reaction"
    elif data.get("remoteDelete") is not None:
        _append_delete(context, state, data["remoteDelete"])
        kind = "delete"
    else:
        _append_content(context, data, state, edit_target)
    return kind, state.timestamp


def _edit_payload(edit: Any, label: str) -> tuple[dict[str, Any], int]:
    if not isinstance(edit, dict):
        raise SignalCollectorError(f"Signal {label} editMessage is invalid")
    data = edit.get("dataMessage")
    if not isinstance(data, dict):
        raise SignalCollectorError(f"Signal {label} editMessage is invalid")
    target = _timestamp(edit.get("targetSentTimestamp"), "edit target timestamp")
    return data, target


def _message_context(
    archive: dict[str, Any],
    observed_at: str,
    author_id: str,
    participant_id: str,
    direction: str,
) -> MessageContext:
    return MessageContext(
        archive=archive,
        account_id=archive["remote_account_id"],
        author_id=author_id,
        participant_id=participant_id,
        observed_at=observed_at,
        direction=direction,
    )


def _destination(sent: dict[str, Any]) -> str:
    value = (
        sent.get("destinationUuid")
        or sent.get("destinationNumber")
        or sent.get("destination")
    )
    return _identity(value, "destination")


def _normalize_sync(
    archive: dict[str, Any],
    envelope: dict[str, Any],
    sync: Any,
    observed_at: str,
) -> tuple[str, int]:
    if not isinstance(sync, dict):
        raise SignalCollectorError("Signal syncMessage must be an object")
    sent = sync.get("sentMessage")
    if not isinstance(sent, dict):
        timestamp = _timestamp(envelope.get("timestamp"), "envelope timestamp")
        return "sync_metadata", timestamp
    account_id = archive["remote_account_id"]
    context = _message_context(
        archive, observed_at, account_id, _destination(sent), "outbound"
    )
    edit = sent.get("editMessage")
    if edit is None:
        return _message_rows(context, sent)
    data, target = _edit_payload(edit, "sync")
    return _message_rows(context, data, target)


def _normalize_inbound(
    archive: dict[str, Any],
    envelope: dict[str, Any],
    source_id: str,
    observed_at: str,
) -> tuple[str, int]:
    context = _message_context(
        archive, observed_at, source_id, source_id, "inbound"
    )
    edit = envelope.get("editMessage")
    data = envelope.get("dataMessage")
    if edit is not None:
        edit_data, target = _edit_payload(edit, "inbound")
        result = _message_rows(context, edit_data, target)
    elif isinstance(data, dict):
        result = _message_rows(context, data)
    else:
        result = (
            "unsupported",
            _timestamp(envelope.get("timestamp"), "envelope timestamp"),
        )
    return result


def _normalize_envelope(
    archive: dict[str, Any], envelope: dict[str, Any], observed_at: str
) -> tuple[str, int]:
    source_id = _source(envelope)
    sync = envelope.get("syncMessage")
    if sync is not None:
        result = _normalize_sync(archive, envelope, sync, observed_at)
    else:
        result = _normalize_inbound(archive, envelope, source_id, observed_at)
    return result


def _dedupe_rows(rows: list[dict[str, Any]], label: str) -> list[dict[str, Any]]:
    seen: dict[str, str] = {}
    unique: dict[str, dict[str, Any]] = {}
    for row in rows:
        remote_id = row["remote_id"]
        payload = json.dumps(row, sort_keys=True, ensure_ascii=False)
        if remote_id in seen and seen[remote_id] != payload:
            raise SignalCollectorError(f"Signal {label} stable identity collision")
        seen[remote_id] = payload
        unique[remote_id] = row
    return list(unique.values())


def _event_bounds(timestamps: list[int]) -> tuple[str | None, str | None]:
    if not timestamps:
        return None, None
    return _iso_millis(min(timestamps)), _iso_millis(max(timestamps))


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
        archive[key] = _dedupe_rows(archive[key], key)
    earliest, latest = _event_bounds(timestamps)
    archive["coverage"] = _coverage(observed_at, earliest, latest)
    reject_credentials(archive)
    return archive, counts
