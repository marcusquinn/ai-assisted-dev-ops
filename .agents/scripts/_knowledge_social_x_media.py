#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize metadata-only X media references without downloading binaries."""

from __future__ import annotations

from typing import Any

from _knowledge_social_x import XAdapterError


def _attachment_keys(item: dict[str, Any]) -> list[str]:
    attachments = item.get("attachments")
    if attachments is None:
        return []
    if not isinstance(attachments, dict):
        raise XAdapterError("X post attachments must be an object")
    keys = attachments.get("media_keys", [])
    if not isinstance(keys, list) or any(not isinstance(key, str) for key in keys):
        raise XAdapterError("X post media_keys must be an array of text")
    return keys


def _media_links(data: list[dict[str, Any]]) -> dict[str, str]:
    links: dict[str, str] = {}
    for item in data:
        remote_id = item.get("id")
        if not isinstance(remote_id, str):
            continue
        for media_key in _attachment_keys(item):
            links.setdefault(media_key, remote_id)
    return links


def page_media(
    includes: dict[str, Any], data: list[dict[str, Any]], media_policy: str
) -> list[dict[str, Any]]:
    """Return media references only when metadata hydration is enabled."""
    if media_policy != "metadata":
        return []
    items = includes.get("media", [])
    if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
        raise XAdapterError("X included media must be an array")
    links = _media_links(data)
    media = []
    for item in items:
        media_key = item.get("media_key")
        if not isinstance(media_key, str) or not media_key:
            raise XAdapterError("X media requires a media_key")
        media.append(
            {
                "remote_id": media_key,
                "object_remote_id": links.get(media_key),
                "mime_type": item.get("type"),
                "hydration_state": "metadata_only",
            }
        )
    return media
