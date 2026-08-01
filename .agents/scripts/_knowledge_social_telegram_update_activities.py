#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Activity projections for Telegram Bot API update fan-out."""

from __future__ import annotations

from typing import Any

from _knowledge_social_telegram_contract import (
    canonical_user_id,
    normalized_time,
    require_list,
    stable_id,
)
from knowledge_social_store import SocialStoreError


def _compound_id(*parts: Any) -> str:
    return ":".join(str(part) for part in parts)


def _actor_id(payload: dict[str, Any]) -> str:
    actor = payload.get("user") or payload.get("from")
    actor_chat = payload.get("actor_chat")
    if isinstance(actor, dict) and actor.get("id") is not None:
        return canonical_user_id(actor["id"])
    if isinstance(actor_chat, dict) and actor_chat.get("id") is not None:
        return _compound_id("actor_chat", stable_id(actor_chat["id"], "actor chat ID"))
    return "telegram_system"


def _member_state(member: Any) -> dict[str, Any] | None:
    if not isinstance(member, dict):
        return None
    affected = member.get("user")
    user_id = None
    if isinstance(affected, dict) and affected.get("id") is not None:
        user_id = canonical_user_id(affected["id"])
    return {"status": member.get("status"), "user_id": user_id}


def _activity_metadata(
    update_type: str, payload: dict[str, Any], update_id: int, fanout_sequence: int
) -> dict[str, Any]:
    common: dict[str, Any] = {
        "source": "telegram_bot_api_update",
        "update_id": update_id,
        "fanout_sequence": fanout_sequence,
    }
    actor_chat = payload.get("actor_chat")
    if isinstance(actor_chat, dict) and actor_chat.get("id") is not None:
        common["actor_chat_id"] = stable_id(actor_chat["id"], "actor chat ID")
    if update_type in ("message_reaction", "message_reaction_count"):
        common["old_reaction"] = payload.get("old_reaction", [])
        common["new_reaction"] = payload.get("new_reaction", payload.get("reactions", []))
    if update_type in ("chat_member", "my_chat_member"):
        for field in ("old_chat_member", "new_chat_member"):
            state = _member_state(payload.get(field))
            if state is not None:
                common[field] = state
    return common


def _deleted_records(
    payload: dict[str, Any], update_type: str, update_id: int, common: dict[str, Any]
) -> list[dict[str, Any]] | None:
    message_ids = payload.get("message_ids")
    if update_type != "deleted_business_messages" or message_ids is None:
        return None
    chat = payload.get("chat")
    chat_id = stable_id(chat.get("id"), "chat ID") if isinstance(chat, dict) else None
    business_id = stable_id(payload.get("business_connection_id"), "business connection ID")
    actor_id = _actor_id(payload)
    records = []
    for value in require_list(message_ids, "deleted business message IDs"):
        message_id = stable_id(value, "deleted message ID")
        records.append(
            {
                "activity_type": update_type,
                "remote_id": _compound_id("update", update_id, update_type, message_id),
                "actor_remote_id": actor_id,
                "object_remote_id": _compound_id(
                    "business", business_id, "chat", chat_id, "message", message_id
                ),
                "occurred_at": None,
                "observed_at": common["observed_at"],
                "state": "deleted",
                "provider_json": common["provider_json"],
            }
        )
    return records


def activity_records(
    update_type: str,
    payload: dict[str, Any],
    update_id: int,
    fanout_sequence: int,
    observed_at: str,
) -> tuple[list[dict[str, Any]], str]:
    chat = payload.get("chat")
    chat_id = stable_id(chat.get("id"), "chat ID") if isinstance(chat, dict) else None
    if chat_id is None:
        raise SocialStoreError("Telegram update cannot be bound to an allowlisted chat")
    provider_json = _activity_metadata(update_type, payload, update_id, fanout_sequence)
    common = {
        "observed_at": observed_at,
        "provider_json": provider_json,
    }
    deleted = _deleted_records(payload, update_type, update_id, common)
    if deleted is not None:
        return deleted, chat_id
    message_id = payload.get("message_id")
    object_id = None
    if message_id is not None:
        object_id = _compound_id("chat", chat_id, "message", stable_id(message_id, "message ID"))
    record = {
        "activity_type": update_type,
        "remote_id": _compound_id("update", update_id, update_type),
        "actor_remote_id": _actor_id(payload),
        "object_remote_id": object_id,
        "occurred_at": normalized_time(None, payload.get("date"), "activity date")
        if payload.get("date") is not None
        else None,
        "observed_at": observed_at,
        "state": "observed",
        "provider_json": provider_json,
    }
    return [record], chat_id
