#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Build private-free Slack JSON export fixtures for collector tests."""

from __future__ import annotations

import json
import stat
import sys
import zipfile
from pathlib import Path
from typing import Any

WORKSPACE = "T123ABC456"
SELECTED_USER = "U123ABC456"
OTHER_USER = "U999ABC456"
CHANNEL = "C123ABC456"
OTHER_CHANNEL = "C999ABC456"
TOKEN_PREFIX = "xo" + "xb" + "-"
SYNTHETIC_TOKEN = TOKEN_PREFIX + "123456789012-" + "A1b2C3d4E5f6G7h8" * 2


def _json(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True).encode("utf-8")


def _write(archive: zipfile.ZipFile, name: str, value: Any) -> None:
    info = zipfile.ZipInfo(name, (2026, 7, 31, 19, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = (stat.S_IFREG | 0o600) << 16
    archive.writestr(info, _json(value))


def _base_members(mode: str) -> dict[str, Any]:
    selected = SELECTED_USER if mode != "wrong-account" else "U888ABC456"
    workspace = WORKSPACE if mode != "wrong-workspace" else "T888ABC456"
    selected_workspace = (
        "T777ABC456" if mode == "conflicting-workspace" else workspace
    )
    messages = [
        {
            "type": "message",
            "user": selected,
            "text": "bounded Slack fixture knowledge",
            "ts": "1710000000.000001",
            "reactions": [{"name": "eyes", "count": 1, "users": [selected]}],
            "files": [
                {
                    "id": "F123ABC456",
                    "user": selected,
                    "name": "fixture.txt",
                    "title": "Fixture attachment",
                    "mimetype": "text/plain",
                    "size": 42,
                    "timestamp": 1710000000,
                    "url_private": "https://files.example.invalid/credential-bearing-link",
                }
            ],
        },
        {
            "type": "message",
            "subtype": "message_changed",
            "user": selected,
            "editor_id": selected,
            "text": "edited fixture knowledge",
            "previous": {"text": "old fixture knowledge"},
            "original_ts": "1710000001.000001",
            "ts": "1710000010.000001",
        },
        {
            "type": "message",
            "subtype": "message_deleted",
            "user": selected,
            "editor_id": selected,
            "text": "",
            "previous": {"text": "deleted fixture knowledge"},
            "original_ts": "1710000002.000001",
            "ts": "1710000011.000001",
        },
    ]
    if mode == "changed":
        messages[0]["text"] = "updated archive fixture knowledge"
    elif mode == "stale":
        messages[0]["text"] = "stale archive fixture knowledge"
    elif mode == "credential":
        # Synthetic non-secret value exercises credential-key rejection.
        messages[0]["access_token"] = "fixture-redacted-value"  # nosec B105
    elif mode == "credential-scalar":
        messages[0]["text"] = SYNTHETIC_TOKEN
    return {
        "team_info.json": {"id": workspace, "name": "Fixture Workspace"},
        "users.json": [
            {
                "id": selected,
                "team_id": selected_workspace,
                "name": "fixture-user",
                "deleted": False,
                "is_bot": False,
                "is_restricted": False,
                "profile": {
                    "display_name": "Fixture User",
                    "real_name": "Fixture User",
                    "email": "not-collected@example.invalid",
                },
            },
            {
                "id": OTHER_USER,
                "team_id": workspace,
                "name": "other-user",
                "profile": {"display_name": "Other User"},
            },
        ],
        "channels.json": [
            {
                "id": CHANNEL,
                "name": ".." if mode == "unsafe-folder" else "engineering",
                "created": 1710000000,
                "members": [selected],
                "topic": {"value": "Bounded topic"},
                "purpose": {"value": "Fixture purpose"},
            },
            {
                "id": OTHER_CHANNEL,
                "name": "unselected",
                "members": [OTHER_USER],
            },
        ],
        "engineering/2026-07-31.json": messages,
        "unselected/2026-07-31.json": [
            {
                "type": "message",
                "user": OTHER_USER,
                "text": "must-not-persist-from-unselected-conversation",
                "ts": "1710000999.000001",
            }
        ],
    }


def build(path: Path, mode: str) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        members = _base_members(mode)
        if mode in {"duplicate-folder", "casefold-folder"}:
            members["channels.json"].append(
                {
                    "id": "C777ABC456",
                    "name": (
                        "Engineering" if mode == "casefold-folder" else "engineering"
                    ),
                    "members": [SELECTED_USER],
                }
            )
        for name, value in members.items():
            _write(archive, name, value)
        if mode == "traversal":
            _write(archive, "../escape.json", {})
        elif mode == "duplicate":
            _write(archive, "USERS.json", [])
        elif mode == "member-symlink":
            info = zipfile.ZipInfo("unsafe-link", (2026, 7, 31, 19, 0, 0))
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, b"users.json")


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: slack-archive-fixture.py PATH MODE")
    build(Path(sys.argv[1]), sys.argv[2])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
