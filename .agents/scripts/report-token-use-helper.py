#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Generate local token-use reports per AI session."""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from pathlib import Path
from typing import Any

from report_token_use_render import as_dict, session_kind_summary, write_html, write_json, write_markdown


DEFAULT_OPENCODE_DB = Path.home() / ".local/share/opencode/opencode.db"
DEFAULT_OBS_DB = Path.home() / ".aidevops/.agent-workspace/observability/llm-requests.db"
DEFAULT_REPORT_ROOT = Path.home() / ".aidevops/_reports/token-use"
DEFAULT_OPENCODE_CONFIG = Path.home() / ".config/opencode/opencode.json"
UTC = timezone.utc


@dataclass
class SessionRow:
    session_id: str
    parent_id: str | None
    title: str
    model: str
    tokens_input: int
    tokens_output: int
    tokens_reasoning: int
    tokens_cache_read: int
    tokens_cache_write: int
    cost: float
    time_created: int
    time_updated: int
    time_compacting: int | None
    directory: str
    path: str
    agent: str


@dataclass
class SessionReport:
    session_id: str
    session_name: str
    runtime: str
    session_kind: str
    models_used: list[str]
    tokens_input: int
    tokens_output: int
    tokens_reasoning: int
    tokens_cache_read: int
    tokens_cache_write: int
    raw_tokens_total: int
    net_tokens_total: int
    child_session_count: int
    compaction_count: int
    mcps_active: list[str]
    mcps_observed: list[str]
    started_at: str
    finished_at: str
    cost_usd: float
    request_count: int
    tool_call_count: int
    source_session_ids: list[str] = field(default_factory=list)
    cost_provenance: str = "unavailable"
    lineage_provenance: str = "unavailable"
    compaction_provenance: str = "unavailable"


@dataclass
class DailyUsage:
    date: str
    session_count: int
    raw_tokens_total: int
    net_tokens_total: int
    cost_usd: float
    interactive_session_count: int = 0
    interactive_raw_tokens_total: int = 0
    interactive_net_tokens_total: int = 0
    interactive_cost_usd: float = 0.0
    headless_worker_session_count: int = 0
    headless_worker_raw_tokens_total: int = 0
    headless_worker_net_tokens_total: int = 0
    headless_worker_cost_usd: float = 0.0


@dataclass(frozen=True)
class OpencodeReportContext:
    conn: sqlite3.Connection
    obs_db: Path
    configured_mcps: list[str]
    observed_parents: dict[str, str]


def _make_session_report(**values: Any) -> SessionReport:
    return SessionReport(**values)


def _die(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)


def _connect(path: Path) -> sqlite3.Connection | None:
    if not path.exists():
        return None
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def _table_exists(conn: sqlite3.Connection, table: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", (table,)
    ).fetchone()
    return row is not None


def _table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    if not _table_exists(conn, table):
        return set()
    return {str(row["name"]) for row in conn.execute(f"PRAGMA table_info({table})")}


def _parse_since(value: str | None) -> datetime | None:
    if not value:
        return None
    match = re.fullmatch(r"(\d+)([hdw])", value.strip().lower())
    if not match:
        _die("--since must use a duration such as 24h, 7d, or 2w")
    amount = int(match.group(1))
    unit = match.group(2)
    if unit == "h":
        return datetime.now(UTC) - timedelta(hours=amount)
    if unit == "d":
        return datetime.now(UTC) - timedelta(days=amount)
    return datetime.now(UTC) - timedelta(weeks=amount)


def _ms_to_iso(value: int | None) -> str:
    if not value:
        return ""
    return datetime.fromtimestamp(value / 1000, tz=UTC).astimezone().isoformat(timespec="seconds")


def _iso_now_id() -> str:
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")


def _safe_title(value: str) -> str:
    cleaned = re.sub(r"\s+", " ", value or "").strip()
    return cleaned[:120] if cleaned else "(untitled)"


def _parse_model(raw: str | None) -> str:
    if not raw:
        return ""
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return raw
    if isinstance(data, dict):
        model = data.get("id") or data.get("model") or ""
        provider = data.get("providerID") or data.get("provider") or ""
        variant = data.get("variant") or ""
        parts = [part for part in (provider, model, variant) if part]
        return "/".join(parts)
    return str(data)


def _read_sessions(conn: sqlite3.Connection) -> list[SessionRow]:
    rows = conn.execute(
        """
        SELECT id, parent_id, title, model, tokens_input, tokens_output,
               tokens_reasoning, tokens_cache_read, tokens_cache_write, cost,
               time_created, time_updated, time_compacting, directory, path, agent
        FROM session
        """
    ).fetchall()
    sessions: list[SessionRow] = []
    for row in rows:
        sessions.append(
            SessionRow(
                session_id=row["id"],
                parent_id=row["parent_id"],
                title=row["title"] or "",
                model=row["model"] or "",
                tokens_input=int(row["tokens_input"] or 0),
                tokens_output=int(row["tokens_output"] or 0),
                tokens_reasoning=int(row["tokens_reasoning"] or 0),
                tokens_cache_read=int(row["tokens_cache_read"] or 0),
                tokens_cache_write=int(row["tokens_cache_write"] or 0),
                cost=float(row["cost"] or 0),
                time_created=int(row["time_created"] or 0),
                time_updated=int(row["time_updated"] or 0),
                time_compacting=row["time_compacting"],
                directory=row["directory"] or "",
                path=row["path"] or "",
                agent=row["agent"] or "",
            )
        )
    return sessions


def _root_for(
    session_id: str,
    by_id: dict[str, SessionRow],
    observed_parents: dict[str, str] | None = None,
) -> str:
    seen: set[str] = set()
    current = session_id
    while current not in seen:
        seen.add(current)
        parent = by_id.get(current).parent_id if current in by_id else None
        parent = parent or (observed_parents or {}).get(current)
        if not parent:
            break
        current = parent
    return current


def _children_by_root(
    sessions: list[SessionRow], observed_parents: dict[str, str] | None = None
) -> dict[str, list[SessionRow]]:
    by_id = {row.session_id: row for row in sessions}
    grouped: dict[str, list[SessionRow]] = {}
    for row in sessions:
        root = _root_for(row.session_id, by_id, observed_parents)
        grouped.setdefault(root, []).append(row)
    return grouped


def _configured_mcps() -> list[str]:
    config_path = Path(os.environ.get("AIDEVOPS_REPORT_TOKEN_USE_OPENCODE_CONFIG", DEFAULT_OPENCODE_CONFIG))
    if not config_path.exists():
        return []
    text = config_path.read_text(encoding="utf-8", errors="replace")
    text = _strip_jsonc_comments(text)
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return []
    mcp = data.get("mcp") if isinstance(data, dict) else None
    if isinstance(mcp, dict):
        return sorted(str(key) for key in mcp.keys())
    return []


def _strip_jsonc_comments(text: str) -> str:
    output: list[str] = []
    in_string = False
    escaped = False
    index = 0
    while index < len(text):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""
        if in_string:
            escaped, in_string = _append_jsonc_string_char(output, char, escaped)
            index += 1
            continue
        if char == '"':
            in_string = True
            output.append(char)
            index += 1
            continue
        if char == "/" and next_char == "/":
            index = _skip_jsonc_line_comment(text, index)
            continue
        if char == "/" and next_char == "*":
            index = _skip_jsonc_block_comment(text, index)
            continue
        output.append(char)
        index += 1
    return "".join(output)


def _append_jsonc_string_char(output: list[str], char: str, escaped: bool) -> tuple[bool, bool]:
    output.append(char)
    if escaped:
        return False, True
    if char == "\\":
        return True, True
    if char == '"':
        return False, False
    return False, True


def _skip_jsonc_line_comment(text: str, index: int) -> int:
    while index < len(text) and text[index] not in "\r\n":
        index += 1
    return index


def _skip_jsonc_block_comment(text: str, index: int) -> int:
    index += 2
    while index + 1 < len(text) and not (text[index] == "*" and text[index + 1] == "/"):
        index += 1
    return min(index + 2, len(text))


def _model_switches(conn: sqlite3.Connection, session_ids: list[str]) -> set[str]:
    if not _table_exists(conn, "session_message") or not session_ids:
        return set()
    placeholders = ",".join("?" for _ in session_ids)
    rows = conn.execute(
        f"SELECT data FROM session_message WHERE type='model-switched' AND session_id IN ({placeholders})",
        session_ids,
    ).fetchall()
    models: set[str] = set()
    for row in rows:
        try:
            data = json.loads(row["data"] or "{}")
        except json.JSONDecodeError:
            continue
        model = data.get("model") if isinstance(data, dict) else None
        if isinstance(model, dict):
            mid = model.get("id") or ""
            provider = model.get("providerID") or ""
            variant = model.get("variant") or ""
            rendered = "/".join(part for part in (provider, mid, variant) if part)
            if rendered:
                models.add(rendered)
    return models


def _mcp_name_from_tool(tool: str, configured_mcps: list[str]) -> str:
    if tool.startswith("mcp_"):
        remainder = tool[4:]
        return remainder.split("_", 1)[0] if remainder else tool
    for name in configured_mcps:
        normalized = name.replace("-", "_")
        if tool.startswith(f"{normalized}_") or tool.startswith(f"{name}_"):
            return name
    return ""


def _observed_parents(obs_db: Path) -> dict[str, str]:
    conn = _connect(obs_db)
    if conn is None:
        return {}
    try:
        columns = _table_columns(conn, "llm_requests")
        if not {"session_id", "parent_session_id"}.issubset(columns):
            return {}
        rows = conn.execute(
            "SELECT session_id, parent_session_id FROM llm_requests "
            "WHERE session_id IS NOT NULL AND parent_session_id IS NOT NULL "
            "AND session_id != '' AND parent_session_id != ''"
        ).fetchall()
        return {
            str(row["session_id"]): str(row["parent_session_id"])
            for row in rows
            if row["session_id"] != row["parent_session_id"]
        }
    finally:
        conn.close()


def _observability_session_ids_by_root(
    observed_parents: dict[str, str], by_id: dict[str, SessionRow], roots: set[str]
) -> dict[str, set[str]]:
    grouped: dict[str, set[str]] = defaultdict(set)
    for session_id in observed_parents:
        root = _root_for(session_id, by_id, observed_parents)
        if root in roots:
            grouped[root].add(session_id)
    return grouped


def _observability_request_rows(
    conn: sqlite3.Connection, columns: set[str], session_ids: list[str]
) -> list[sqlite3.Row]:
    if not session_ids or not {"session_id", "model_id"}.issubset(columns):
        return []
    selected = ["session_id", "model_id"]
    for column in ("cost", "parent_session_id", "agent"):
        if column in columns:
            selected.append(column)
    placeholders = ",".join("?" for _ in session_ids)
    query = "SELECT " + ", ".join(selected) + " FROM llm_requests WHERE session_id IN (" + placeholders + ")"
    return conn.execute(query, session_ids).fetchall()


def _add_observability_request(result: dict[str, Any], row: sqlite3.Row, columns: set[str]) -> float:
    if row["model_id"]:
        result["models"].add(str(row["model_id"]))
    result["requests"] += 1
    if "parent_session_id" in columns and row["parent_session_id"]:
        result["has_lineage"] = True
    if "agent" in columns:
        result["has_compaction_evidence"] = True
        if "compact" in str(row["agent"] or "").lower():
            result["compaction_session_ids"].add(str(row["session_id"]))
    return float(row["cost"] or 0) if "cost" in columns else 0.0


def _observability_for(obs_db: Path, session_ids: list[str], configured_mcps: list[str]) -> dict[str, Any]:
    result: dict[str, Any] = {
        "models": set(),
        "requests": 0,
        "tool_calls": 0,
        "observed_mcps": set(),
        "cost_usd": None,
        "compaction_session_ids": set(),
        "has_lineage": False,
        "has_compaction_evidence": False,
    }
    conn = _connect(obs_db)
    if conn is None:
        return result
    try:
        placeholders = ",".join("?" for _ in session_ids)
        columns = _table_columns(conn, "llm_requests")
        request_rows = _observability_request_rows(conn, columns, session_ids)
        costs = [_add_observability_request(result, row, columns) for row in request_rows]
        if "cost" in columns and request_rows:
            result["cost_usd"] = round(sum(costs), 6)
        if placeholders and _table_exists(conn, "tool_calls"):
            for row in conn.execute(
                f"SELECT tool_name, COUNT(*) AS n FROM tool_calls WHERE session_id IN ({placeholders}) GROUP BY tool_name",
                session_ids,
            ):
                tool = str(row["tool_name"] or "")
                result["tool_calls"] += int(row["n"] or 0)
                mcp_name = _mcp_name_from_tool(tool, configured_mcps)
                if mcp_name:
                    result["observed_mcps"].add(mcp_name)
    finally:
        conn.close()
    return result


def _session_in_scope(group: list[SessionRow], session_id: str | None, since_ms: int | None) -> bool:
    if session_id and session_id not in [row.session_id for row in group]:
        return False
    if since_ms and max(row.time_updated for row in group) < since_ms:
        return False
    return True


def _tokens_for_group(group: list[SessionRow]) -> dict[str, int]:
    tokens = {
        "input": sum(row.tokens_input for row in group),
        "output": sum(row.tokens_output for row in group),
        "reasoning": sum(row.tokens_reasoning for row in group),
        "cache_read": sum(row.tokens_cache_read for row in group),
        "cache_write": sum(row.tokens_cache_write for row in group),
    }
    tokens["raw_total"] = sum(tokens.values())
    tokens["net_total"] = tokens["input"] + tokens["output"] + tokens["reasoning"] + tokens["cache_write"]
    return tokens


def _normalized_session_location(row: SessionRow) -> str:
    location = f"/{row.directory}/{row.path}".replace("\\", "/").lower()
    return re.sub(r"/+", "/", location)


def _session_kind_for_group(group: list[SessionRow]) -> str:
    for row in group:
        location = _normalized_session_location(row)
        if (
            "/private/tmp/opencode" in location
            or "/tmp/opencode" in location
            or "/temp/opencode" in location
        ):
            return "headless_worker"
    return "interactive"


def _models_for_group(
    conn: sqlite3.Connection,
    group: list[SessionRow],
    session_ids: list[str],
    obs: dict[str, Any],
) -> list[str]:
    models = {model for model in (_parse_model(row.model) for row in group) if model}
    models.update(_model_switches(conn, session_ids))
    models.update(obs["models"])
    return sorted(models) or ["unknown"]


def _opencode_report_from_group(
    context: OpencodeReportContext,
    root_id: str,
    root: SessionRow,
    group: list[SessionRow],
) -> SessionReport:
    group_session_ids = {row.session_id for row in group}
    source_session_ids = group_session_ids | _observability_session_ids_by_root(
        context.observed_parents, {row.session_id: row for row in group}, {root_id}
    ).get(root_id, set())
    session_ids = sorted(source_session_ids)
    obs = _observability_for(context.obs_db, session_ids, context.configured_mcps)
    tokens = _tokens_for_group(group)
    compacted_session_ids = {
        row.session_id for row in group if row.parent_id or row.time_compacting
    } | obs["compaction_session_ids"]
    session_cost = round(sum(row.cost for row in group), 6)
    cost_from_observability = obs["cost_usd"] is not None
    has_opencode_lineage = any(row.parent_id for row in group)
    lineage_provenance = "opencode_session.parent_id"
    if context.observed_parents:
        lineage_provenance = (
            "combined: session.parent_id + llm_requests.parent_session_id"
            if has_opencode_lineage
            else "observability: llm_requests.parent_session_id"
        )
    compaction_provenance = "opencode_session.parent_id,time_compacting"
    if obs["has_compaction_evidence"]:
        compaction_provenance = "combined: opencode_session + llm_requests.agent"
    return _make_session_report(
        session_id=root_id,
        session_name=_safe_title(root.title),
        runtime="opencode",
        session_kind=_session_kind_for_group(group),
        models_used=_models_for_group(context.conn, group, session_ids, obs),
        tokens_input=tokens["input"],
        tokens_output=tokens["output"],
        tokens_reasoning=tokens["reasoning"],
        tokens_cache_read=tokens["cache_read"],
        tokens_cache_write=tokens["cache_write"],
        raw_tokens_total=tokens["raw_total"],
        net_tokens_total=tokens["net_total"],
        child_session_count=max(len(source_session_ids) - 1, 0),
        compaction_count=len(compacted_session_ids),
        mcps_active=context.configured_mcps,
        mcps_observed=sorted(obs["observed_mcps"]),
        started_at=_ms_to_iso(min(row.time_created for row in group)),
        finished_at=_ms_to_iso(max(row.time_updated for row in group)),
        cost_usd=obs["cost_usd"] if cost_from_observability else session_cost,
        request_count=int(obs["requests"]),
        tool_call_count=int(obs["tool_calls"]),
        source_session_ids=session_ids,
        cost_provenance=(
            "observability: llm_requests.cost" if cost_from_observability else "opencode_session.cost"
        ),
        lineage_provenance=lineage_provenance,
        compaction_provenance=compaction_provenance,
    )


def _opencode_reports(args: argparse.Namespace) -> list[SessionReport]:
    db_path = Path(os.environ.get("AIDEVOPS_REPORT_TOKEN_USE_OPENCODE_DB", DEFAULT_OPENCODE_DB))
    obs_db = Path(os.environ.get("AIDEVOPS_REPORT_TOKEN_USE_OBS_DB", DEFAULT_OBS_DB))
    conn = _connect(db_path)
    if conn is None:
        return []
    try:
        sessions = _read_sessions(conn)
        by_id = {row.session_id: row for row in sessions}
        observed_parents = _observed_parents(obs_db)
        grouped = _children_by_root(sessions, observed_parents)
        since_dt = _parse_since(args.since)
        since_ms = int(since_dt.timestamp() * 1000) if since_dt else None
        context = OpencodeReportContext(
            conn=conn,
            obs_db=obs_db,
            configured_mcps=_configured_mcps(),
            observed_parents=observed_parents,
        )
        reports: list[SessionReport] = []
        for root_id, group in grouped.items():
            if not _session_in_scope(group, args.session, since_ms):
                continue
            root = by_id.get(root_id, group[0])
            reports.append(_opencode_report_from_group(context, root_id, root, group))
        reports.sort(key=lambda row: row.finished_at, reverse=True)
        return reports[: args.limit]
    finally:
        conn.close()


def _claude_reports(args: argparse.Namespace) -> list[SessionReport]:
    metrics_path = Path.home() / ".aidevops/.agent-workspace/observability/metrics.jsonl"
    if not metrics_path.exists():
        return []
    since_dt = _parse_since(args.since)
    grouped: dict[str, dict[str, Any]] = {}
    with metrics_path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            session_id = row.get("session_id") or "unknown"
            if _skip_claude_row(args, session_id, row.get("recorded_at") or "", since_dt):
                continue
            _add_claude_row(grouped, session_id, row)
    reports = [_claude_report_from_group(session_id, data) for session_id, data in grouped.items()]
    reports.sort(key=lambda row: row.finished_at, reverse=True)
    return reports[: args.limit]


def _skip_claude_row(args: argparse.Namespace, session_id: str, recorded_at: str, since_dt: datetime | None) -> bool:
    if args.session and args.session != session_id:
        return True
    if not since_dt or not recorded_at:
        return False
    try:
        ts = datetime.fromisoformat(recorded_at.replace("Z", "+00:00"))
    except ValueError:
        return False
    return ts < since_dt


def _new_claude_group(recorded_at: str) -> dict[str, Any]:
    return {
        "models": set(),
        "input": 0,
        "output": 0,
        "cache_read": 0,
        "cache_write": 0,
        "cost": 0.0,
        "first": recorded_at,
        "last": recorded_at,
        "requests": 0,
    }


def _add_claude_row(grouped: dict[str, dict[str, Any]], session_id: str, row: dict[str, Any]) -> None:
    recorded_at = row.get("recorded_at") or ""
    data = grouped.setdefault(session_id, _new_claude_group(recorded_at))
    if row.get("model"):
        data["models"].add(str(row["model"]))
    data["input"] += int(row.get("input_tokens") or 0)
    data["output"] += int(row.get("output_tokens") or 0)
    data["cache_read"] += int(row.get("cache_read_tokens") or 0)
    data["cache_write"] += int(row.get("cache_write_tokens") or 0)
    data["cost"] += float(row.get("cost_total") or 0)
    data["requests"] += 1
    data["first"] = min(filter(None, [data["first"], recorded_at]), default="")
    data["last"] = max(filter(None, [data["last"], recorded_at]), default="")


def _claude_report_from_group(session_id: str, data: dict[str, Any]) -> SessionReport:
    raw_tokens_total = data["input"] + data["output"] + data["cache_read"] + data["cache_write"]
    net_tokens_total = data["input"] + data["output"] + data["cache_write"]
    return _make_session_report(
        session_id=session_id,
        session_name=session_id,
        runtime="claude",
        session_kind="interactive",
        models_used=sorted(data["models"]) or ["unknown"],
        tokens_input=data["input"],
        tokens_output=data["output"],
        tokens_reasoning=0,
        tokens_cache_read=data["cache_read"],
        tokens_cache_write=data["cache_write"],
        raw_tokens_total=raw_tokens_total,
        net_tokens_total=net_tokens_total,
        child_session_count=0,
        compaction_count=0,
        mcps_active=[],
        mcps_observed=[],
        started_at=data["first"],
        finished_at=data["last"],
        cost_usd=round(data["cost"], 6),
        request_count=data["requests"],
        tool_call_count=0,
        source_session_ids=[session_id],
        cost_provenance="claude_metrics.cost_total",
        lineage_provenance="unavailable",
        compaction_provenance="unavailable",
    )


def _collect_reports(args: argparse.Namespace) -> list[SessionReport]:
    if args.runtime == "opencode":
        return _opencode_reports(args)
    if args.runtime == "claude":
        return _claude_reports(args)
    reports = _opencode_reports(args)
    return reports if reports else _claude_reports(args)


def _daily_usage(reports: list[SessionReport]) -> list[DailyUsage]:
    grouped: defaultdict[str, dict[str, Any]] = defaultdict(_new_daily_usage_bucket)
    for report in reports:
        date = (report.finished_at or report.started_at or "unknown")[:10]
        _add_daily_usage_report(grouped[date], report)
    return [
        _daily_usage_from_bucket(date, data)
        for date, data in sorted(grouped.items(), reverse=True)
    ]


def _new_daily_usage_bucket() -> dict[str, Any]:
    return {
        "sessions": 0,
        "raw": 0,
        "net": 0,
        "cost": 0.0,
        "interactive_sessions": 0,
        "interactive_raw": 0,
        "interactive_net": 0,
        "interactive_cost": 0.0,
        "headless_worker_sessions": 0,
        "headless_worker_raw": 0,
        "headless_worker_net": 0,
        "headless_worker_cost": 0.0,
    }


def _add_daily_usage_report(data: dict[str, Any], report: SessionReport) -> None:
    data["sessions"] += 1
    data["raw"] += report.raw_tokens_total
    data["net"] += report.net_tokens_total
    data["cost"] += report.cost_usd
    prefix = "headless_worker" if report.session_kind == "headless_worker" else "interactive"
    data[f"{prefix}_sessions"] += 1
    data[f"{prefix}_raw"] += report.raw_tokens_total
    data[f"{prefix}_net"] += report.net_tokens_total
    data[f"{prefix}_cost"] += report.cost_usd


def _daily_usage_from_bucket(date: str, data: dict[str, Any]) -> DailyUsage:
    return DailyUsage(
        date=date,
        session_count=data["sessions"],
        raw_tokens_total=data["raw"],
        net_tokens_total=data["net"],
        cost_usd=round(data["cost"], 6),
        interactive_session_count=data["interactive_sessions"],
        interactive_raw_tokens_total=data["interactive_raw"],
        interactive_net_tokens_total=data["interactive_net"],
        interactive_cost_usd=round(data["interactive_cost"], 6),
        headless_worker_session_count=data["headless_worker_sessions"],
        headless_worker_raw_tokens_total=data["headless_worker_raw"],
        headless_worker_net_tokens_total=data["headless_worker_net"],
        headless_worker_cost_usd=round(data["headless_worker_cost"], 6),
    )


def _collect_daily_usage(args: argparse.Namespace) -> list[DailyUsage]:
    if args.daily_days < 1:
        return []
    daily_args = SimpleNamespace(
        limit=100000,
        session=args.session,
        since=f"{args.daily_days}d",
        runtime=args.runtime,
    )
    return _daily_usage(_collect_reports(daily_args))


def _open_path(path: Path) -> None:
    if sys.platform == "darwin":
        subprocess.run(["open", str(path)], check=False)
    elif os.name == "nt":
        os.startfile(path)  # type: ignore[attr-defined]
    else:
        subprocess.run(["xdg-open", str(path)], check=False)


def _add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--limit", type=int, default=25, help="maximum sessions to include")
    parser.add_argument("--session", help="include one session/root session")
    parser.add_argument("--since", help="restrict to sessions updated within duration, e.g. 24h, 7d, 2w")
    parser.add_argument("--runtime", choices=["auto", "opencode", "claude"], default="auto")
    parser.add_argument("--daily-days", type=int, default=90, help="days to include in the daily usage summary; 0 disables")


def _compact_session(report: SessionReport) -> dict[str, Any]:
    return {
        "session_id": report.session_id,
        "runtime": report.runtime,
        "session_kind": report.session_kind,
        "models_used": report.models_used,
        "raw_tokens_total": report.raw_tokens_total,
        "net_tokens_total": report.net_tokens_total,
        "cost_usd": report.cost_usd,
        "request_count": report.request_count,
        "tool_call_count": report.tool_call_count,
        "child_session_count": report.child_session_count,
        "compaction_count": report.compaction_count,
        "mcps_observed": report.mcps_observed,
        "started_at": report.started_at,
        "finished_at": report.finished_at,
    }


def _evidence_coverage(reports: list[SessionReport]) -> dict[str, dict[str, int]]:
    provenance_fields = {
        "cost": "cost_provenance",
        "lineage": "lineage_provenance",
        "compaction": "compaction_provenance",
    }
    return {
        name: {
            "available_session_count": sum(getattr(report, field) != "unavailable" for report in reports),
            "unavailable_session_count": sum(getattr(report, field) == "unavailable" for report in reports),
        }
        for name, field in provenance_fields.items()
    }


def _compact_data_payload(reports: list[SessionReport], daily_usage: list[DailyUsage]) -> dict[str, Any]:
    return {
        "summary": {
            "session_count": len(reports),
            "raw_tokens_total": sum(report.raw_tokens_total for report in reports),
            "net_tokens_total": sum(report.net_tokens_total for report in reports),
            "cost_usd": round(sum(report.cost_usd for report in reports), 6),
            "evidence_coverage": _evidence_coverage(reports),
        },
        "configured_mcps": sorted({mcp for report in reports for mcp in report.mcps_active}),
        "usage_by_session_kind": session_kind_summary(reports),
        "sessions": [_compact_session(report) for report in reports],
        "daily_usage": [as_dict(row) for row in daily_usage],
    }


def cmd_data(args: argparse.Namespace) -> int:
    if args.daily_days is None:
        args.daily_days = 0 if args.compact else 90
    reports = _collect_reports(args)
    daily_usage = _collect_daily_usage(args)
    if args.compact:
        payload = _compact_data_payload(reports, daily_usage)
    else:
        payload = {
            "daily_usage": [as_dict(row) for row in daily_usage],
            "usage_by_session_kind": session_kind_summary(reports),
            "sessions": [as_dict(row) for row in reports],
        }
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    reports = _collect_reports(args)
    daily_usage = _collect_daily_usage(args)
    generated_at = datetime.now(UTC).astimezone().isoformat(timespec="seconds")
    output_root = Path(os.environ.get("AIDEVOPS_REPORT_TOKEN_USE_ROOT", DEFAULT_REPORT_ROOT))
    output_dir = output_root / _iso_now_id()
    output_dir.mkdir(parents=True, exist_ok=True)
    md_path = write_markdown(reports, daily_usage, output_dir, generated_at)
    json_path = write_json(reports, daily_usage, output_dir, generated_at)
    html_path = write_html(reports, daily_usage, output_dir, generated_at)
    if args.open:
        _open_path(html_path)
    if args.json:
        print(
            json.dumps(
                {
                    "report_md": str(md_path),
                    "report_json": str(json_path),
                    "report_html": str(html_path),
                    "report_url": html_path.resolve().as_uri(),
                },
                indent=2,
            )
        )
    else:
        print(f"Report written: {html_path.resolve().as_uri()}")
        print(f"Markdown: {md_path}")
        print(f"JSON: {json_path}")
        print(f"Sessions: {len(reports)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    report_parser = subparsers.add_parser("report", help="write Markdown, JSON, and HTML report files")
    _add_common_args(report_parser)
    report_parser.add_argument("--json", action="store_true", help="print artifact paths as JSON")
    report_parser.add_argument("--open", action="store_true", help="open the generated HTML report")
    report_parser.set_defaults(func=cmd_report)
    data_parser = subparsers.add_parser("data", help="print compact session report data as JSON")
    _add_common_args(data_parser)
    data_parser.add_argument("--json", action="store_true", help="accepted for command symmetry")
    data_mode = data_parser.add_mutually_exclusive_group()
    data_mode.add_argument("--compact", dest="compact", action="store_true", help="print the compact model-consumption schema (default)")
    data_mode.add_argument("--full", dest="compact", action="store_false", help="print the complete legacy-compatible session schema")
    data_parser.set_defaults(func=cmd_data, compact=True, daily_days=None)
    args = parser.parse_args(argv)
    if args.limit < 1:
        _die("--limit must be positive")
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
