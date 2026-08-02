#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Configuration, state, and planning model for knowledge collectors."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from _knowledge_collector_receipt import CollectorScheduleError

SCHEMA = "aidevops.knowledge-collector/v1"
MODES = frozenset(("event", "poll", "watch", "archive", "manual", "hybrid"))
OPAQUE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
SCRIPT_DIR = Path(__file__).resolve().parent
CONNECTORS = {
    "folder": (SCRIPT_DIR / "knowledge-helper.sh", "folder", "import"),
    "inbox-watch": (SCRIPT_DIR / "inbox-watch-routine.sh",),
    "mailbox": (SCRIPT_DIR / "email-poll-helper.sh", "tick"),
    "social": (SCRIPT_DIR / "knowledge-social-helper.sh", "provider-run"),
}


@dataclass(frozen=True)
class Connection:
    """One validated private source schedule."""

    connection_id: str
    connector_id: str
    mode: str
    arguments: tuple[str, ...]
    working_directory: Path
    projection_root: Path | None
    freshness_seconds: int
    minimum_interval_seconds: int
    reconcile_seconds: int
    stale_seconds: int
    timeout_seconds: int
    alert_after_failures: int
    event_token: str | None
    enabled: bool


def _private_json(path: Path, label: str, *, optional: bool = False) -> dict[str, Any]:
    if optional and not path.exists():
        return {}
    if path.is_symlink() or not path.is_file():
        raise CollectorScheduleError(f"{label} must be a regular non-symlink file")
    if path.stat().st_mode & 0o077:
        raise CollectorScheduleError(f"{label} must use owner-only permissions")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CollectorScheduleError(f"{label} is not valid private JSON") from error
    if not isinstance(value, dict):
        raise CollectorScheduleError(f"{label} root must be an object")
    return value


def _integer(value: Any, label: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise CollectorScheduleError(f"{label} must be between {minimum} and {maximum}")
    return value


def _opaque_field(value: Any, label: str) -> str:
    if not isinstance(value, str) or not OPAQUE.fullmatch(value):
        raise CollectorScheduleError(f"{label} must be opaque")
    return value


def _arguments(value: Any) -> tuple[str, ...]:
    if not isinstance(value, list) or len(value) > 64:
        raise CollectorScheduleError("collector arguments are invalid")
    if any(not isinstance(item, str) or len(item) > 1024 or "\x00" in item for item in value):
        raise CollectorScheduleError("collector arguments are invalid")
    return tuple(value)


def _directory(value: Any, label: str) -> Path:
    if not isinstance(value, str):
        raise CollectorScheduleError(f"{label} must be text")
    directory = Path(value).expanduser().resolve()
    if not directory.is_dir():
        raise CollectorScheduleError(f"{label} is unavailable")
    return directory


def _projection_root(value: dict[str, Any], connector_id: str, mode: str) -> Path | None:
    projection_value = value.get("projection_root")
    if connector_id == "social":
        if projection_value is not None:
            raise CollectorScheduleError("social collectors update their own query index")
        return None
    if mode not in ("archive", "manual") and projection_value is None:
        raise CollectorScheduleError("active document collectors require projection_root")
    return None if projection_value is None else _directory(projection_value, "projection_root")


def _event_token(value: dict[str, Any]) -> str | None:
    event_token = value.get("event_token")
    if event_token is not None:
        event_token = _opaque_field(event_token, "event_token")
    if value.get("event_pending", False) is True and event_token is None:
        raise CollectorScheduleError("event_pending requires an event_token")
    return event_token


def _connection(value: Any) -> Connection:
    if not isinstance(value, dict):
        raise CollectorScheduleError("collector connection must be an object")
    connection_id = _opaque_field(value.get("connection_id"), "connection_id")
    connector_id = value.get("connector_id")
    mode = value.get("mode")
    if connector_id not in CONNECTORS:
        raise CollectorScheduleError("connector_id is not allowlisted")
    if mode not in MODES:
        raise CollectorScheduleError("collector mode is invalid")
    arguments = _arguments(value.get("arguments", []))
    if value.get("enabled", False) is True and "--dry-run" in arguments:
        raise CollectorScheduleError("enabled collectors cannot use --dry-run")
    return Connection(
        connection_id, connector_id, mode, arguments,
        _directory(value.get("working_directory", "."), "working_directory"),
        _projection_root(value, connector_id, mode),
        _integer(value.get("freshness_seconds", 3600), "freshness_seconds", 60, 31_536_000),
        _integer(value.get("minimum_interval_seconds", 60), "minimum_interval_seconds", 60, 31_536_000),
        _integer(value.get("reconcile_seconds", 86_400), "reconcile_seconds", 60, 31_536_000),
        _integer(value.get("stale_seconds", 7200), "stale_seconds", 60, 31_536_000),
        _integer(value.get("budget", {}).get("seconds", 300), "budget.seconds", 1, 3600)
        if isinstance(value.get("budget", {}), dict) else _integer(None, "budget", 1, 3600),
        _integer(value.get("alert_after_failures", 3), "alert_after_failures", 1, 100),
        _event_token(value), value.get("enabled", False) is True,
    )


def load_config(path: Path) -> list[Connection]:
    value = _private_json(path, "collector config")
    if value.get("schema") != SCHEMA:
        raise CollectorScheduleError("collector config schema is unsupported")
    raw = value.get("connections")
    if not isinstance(raw, list):
        raise CollectorScheduleError("collector config connections must be an array")
    connections = [_connection(item) for item in raw]
    keys = [item.connection_id for item in connections]
    if len(keys) != len(set(keys)):
        raise CollectorScheduleError("collector connection_id values must be unique")
    return sorted(connections, key=lambda item: item.connection_id)


def load_state(path: Path) -> dict[str, Any]:
    value = _private_json(path, "collector state", optional=True)
    if not value:
        return {"schema": SCHEMA, "connections": {}}
    if value.get("schema") != SCHEMA or not isinstance(value.get("connections"), dict):
        raise CollectorScheduleError("collector state schema is unsupported")
    return value


def _record(state: dict[str, Any], connection_id: str) -> dict[str, Any]:
    value = state["connections"].setdefault(connection_id, {})
    if not isinstance(value, dict):
        raise CollectorScheduleError("collector state record is invalid")
    return value


def due_at(connection: Connection, record: dict[str, Any], now: int) -> int | None:
    if not connection.enabled or connection.mode in ("archive", "manual"):
        return None
    rate_reset = record.get("rate_reset_at")
    if isinstance(rate_reset, int) and rate_reset > now:
        return rate_reset
    last_attempt = record.get("last_attempt", 0)
    last_success = record.get("last_success", 0)
    interval_floor = last_attempt + connection.minimum_interval_seconds
    if connection.mode in ("event", "hybrid"):
        pending_event = connection.event_token is not None and connection.event_token != record.get("event_token")
        event_due = now if pending_event else last_success + connection.reconcile_seconds
        return max(interval_floor, event_due)
    return max(interval_floor, last_success + connection.freshness_seconds)
