#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Render token-use report artifacts."""

from __future__ import annotations

import html
import json
from pathlib import Path
from typing import Any


def as_dict(report: Any) -> dict[str, Any]:
    if hasattr(report, "date"):
        return {
            "date": report.date,
            "session_count": report.session_count,
            "raw_tokens_total": report.raw_tokens_total,
            "net_tokens_total": report.net_tokens_total,
            "cost_usd": report.cost_usd,
            "interactive_session_count": report.interactive_session_count,
            "interactive_raw_tokens_total": report.interactive_raw_tokens_total,
            "interactive_net_tokens_total": report.interactive_net_tokens_total,
            "interactive_cost_usd": report.interactive_cost_usd,
            "headless_worker_session_count": report.headless_worker_session_count,
            "headless_worker_raw_tokens_total": report.headless_worker_raw_tokens_total,
            "headless_worker_net_tokens_total": report.headless_worker_net_tokens_total,
            "headless_worker_cost_usd": report.headless_worker_cost_usd,
        }
    return {
        "session_id": report.session_id,
        "session_name": report.session_name,
        "runtime": report.runtime,
        "session_kind": report.session_kind,
        "models_used": report.models_used,
        "tokens_input": report.tokens_input,
        "tokens_output": report.tokens_output,
        "tokens_reasoning": report.tokens_reasoning,
        "tokens_cache_read": report.tokens_cache_read,
        "tokens_cache_write": report.tokens_cache_write,
        "raw_tokens_total": report.raw_tokens_total,
        "net_tokens_total": report.net_tokens_total,
        "child_session_count": report.child_session_count,
        "compaction_count": report.compaction_count,
        "mcps_active": report.mcps_active,
        "mcps_configured": report.mcps_active,
        "mcps_observed": report.mcps_observed,
        "started_at": report.started_at,
        "finished_at": report.finished_at,
        "cost_usd": report.cost_usd,
        "request_count": report.request_count,
        "tool_call_count": report.tool_call_count,
        "source_session_ids": report.source_session_ids,
        "cost_provenance": report.cost_provenance,
        "lineage_provenance": report.lineage_provenance,
        "compaction_provenance": report.compaction_provenance,
    }


def _format_int(value: int) -> str:
    return f"{value:,}"


def _session_kind_label(value: str) -> str:
    labels = {"interactive": "Interactive", "headless_worker": "Headless worker"}
    return labels.get(value, value.replace("_", " ").title() or "Unknown")


def session_kind_summary(reports: list[Any]) -> list[dict[str, Any]]:
    grouped: dict[str, dict[str, Any]] = {}
    for row in reports:
        kind = row.session_kind
        data = grouped.setdefault(
            kind,
            {
                "session_kind": kind,
                "label": _session_kind_label(kind),
                "session_count": 0,
                "raw_tokens_total": 0,
                "net_tokens_total": 0,
                "cost_usd": 0.0,
            },
        )
        data["session_count"] += 1
        data["raw_tokens_total"] += row.raw_tokens_total
        data["net_tokens_total"] += row.net_tokens_total
        data["cost_usd"] += row.cost_usd
    rows = sorted(
        grouped.values(),
        key=lambda item: (item["session_kind"] != "interactive", item["session_kind"]),
    )
    for row in rows:
        row["cost_usd"] = round(row["cost_usd"], 6)
    return rows


def write_markdown(reports: list[Any], daily_usage: list[Any], output_dir: Path, generated_at: str) -> Path:
    report_path = output_dir / "report.md"
    net_total = sum(row.net_tokens_total for row in reports)
    raw_total = sum(row.raw_tokens_total for row in reports)
    lines = [
        "# Token Use Report",
        "",
        f"Generated: {generated_at}",
        f"Sessions: {len(reports)}",
        f"Net tokens (excludes cache reads): {_format_int(net_total)}",
        f"Raw tokens (includes cache reads): {_format_int(raw_total)}",
    ]
    lines.extend(_session_kind_markdown(session_kind_summary(reports)))
    if daily_usage:
        lines.extend(_daily_markdown(daily_usage))
    lines.extend(
        [
            "",
            "## Sessions",
            "",
            "| Session name | Runtime | Type | Models | Tokens in | Tokens out | Cached-read | Raw tokens | Net tokens | Cost | Compactions | MCPs configured | MCPs observed | Started | Finished |",
            "|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|---|",
        ]
    )
    for row in reports:
        lines.append(_markdown_row(row))
    lines.extend(
        [
            "",
            "## Notes",
            "",
            "- Net tokens are input + output + reasoning + cache-write tokens, excluding cache reads so the main total tracks paid/metered work more closely.",
            "- Raw tokens include cache reads for context volume analysis. Provider-specific cached-read billing discounts are best represented by the Cost column when available.",
            "- Session type is inferred from runtime metadata. OpenCode sessions under the runtime temporary work directory are reported as headless worker sessions; other local sessions are reported as interactive.",
            "- OpenCode rows recursively include child sessions via `session.parent_id` and, when available, `llm_requests.parent_session_id` so compacted sessions are counted with their root session.",
            "- JSON session fields `cost_provenance`, `lineage_provenance`, and `compaction_provenance` identify the source used for each derived value; `unavailable` is not a measured zero.",
            "- MCPs configured lists configured OpenCode MCP server names at report time. MCPs observed are inferred from session tool-call names when available and are the better proxy for actual use.",
        ]
    )
    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return report_path


def _session_kind_markdown(summary: list[dict[str, Any]]) -> list[str]:
    lines = [
        "",
        "## Session type summary",
        "",
        "| Type | Sessions | Raw tokens | Net tokens | Cost |",
        "|---|---:|---:|---:|---:|",
    ]
    for row in summary:
        lines.append(
            f"| {row['label']} | {row['session_count']} | {_format_int(row['raw_tokens_total'])} | {_format_int(row['net_tokens_total'])} | ${row['cost_usd']:.6f} |"
        )
    return lines


def _daily_markdown(daily_usage: list[Any]) -> list[str]:
    lines = [
        "",
        "## Daily usage",
        "",
        "| Date | Interactive sessions | Interactive net | Headless sessions | Headless net | Total sessions | Total net | Total raw | Cost |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in daily_usage:
        lines.append(
            f"| {row.date} | {row.interactive_session_count} | {_format_int(row.interactive_net_tokens_total)} | {row.headless_worker_session_count} | {_format_int(row.headless_worker_net_tokens_total)} | {row.session_count} | {_format_int(row.net_tokens_total)} | {_format_int(row.raw_tokens_total)} | ${row.cost_usd:.6f} |"
        )
    return lines


def _markdown_row(row: Any) -> str:
    cells = [
        row.session_name.replace("|", "\\|"),
        row.runtime,
        _session_kind_label(row.session_kind),
        ", ".join(row.models_used).replace("|", "\\|"),
        _format_int(row.tokens_input),
        _format_int(row.tokens_output),
        _format_int(row.tokens_cache_read),
        _format_int(row.raw_tokens_total),
        _format_int(row.net_tokens_total),
        f"${row.cost_usd:.6f}",
        str(row.compaction_count),
        ", ".join(row.mcps_active) or "none configured",
        ", ".join(row.mcps_observed) or "none observed",
        row.started_at,
        row.finished_at,
    ]
    return "| " + " | ".join(cells) + " |"


def write_html(reports: list[Any], daily_usage: list[Any], output_dir: Path, generated_at: str) -> Path:
    report_path = output_dir / "report.html"
    body = "\n".join(_html_row(row) for row in reports)
    daily_body = "\n".join(_daily_html_row(row) for row in daily_usage)
    kind_body = "\n".join(_session_kind_html_row(row) for row in session_kind_summary(reports))
    net_total = _format_int(sum(row.net_tokens_total for row in reports))
    raw_total = _format_int(sum(row.raw_tokens_total for row in reports))
    html_doc = f"""<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
  <title>Token Use Report</title>
  <style>
    body {{ color: #172033; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 2rem; }}
    table {{ border-collapse: collapse; margin-bottom: 2rem; table-layout: fixed; width: 100%; }}
    table.summary {{ max-width: 64rem; }}
    table.daily {{ min-width: 82rem; }}
    th, td {{ border-bottom: 1px solid #d8dee9; padding: .55rem; text-align: left; vertical-align: top; }}
    th.num, td.num {{ text-align: right; }}
    th {{ background: #f5f7fb; position: sticky; top: 0; }}
    .meta {{ color: #5f6b7a; }}
  </style>
</head>
<body>
  <h1>Token Use Report</h1>
  <p class=\"meta\">Generated: {html.escape(generated_at)} · Sessions: {len(reports)} · Net tokens: {net_total} · Raw tokens: {raw_total}</p>
  <h2>Session type summary</h2>
  <table class="summary">
    <colgroup><col style="width: 12rem"><col style="width: 7rem"><col style="width: 12rem"><col style="width: 12rem"><col style="width: 9rem"></colgroup>
    <thead><tr><th>Type</th><th class="num">Sessions</th><th class="num">Raw tokens</th><th class="num">Net tokens</th><th class="num">Cost</th></tr></thead>
    <tbody>
{kind_body}
    </tbody>
  </table>
  <h2>Daily usage</h2>
  <table class="daily">
    <colgroup><col style="width: 9rem"><col style="width: 8rem"><col style="width: 11rem"><col style="width: 8rem"><col style="width: 11rem"><col style="width: 8rem"><col style="width: 11rem"><col style="width: 11rem"><col style="width: 9rem"></colgroup>
    <thead><tr><th>Date</th><th class="num">Interactive sessions</th><th class="num">Interactive net</th><th class="num">Headless sessions</th><th class="num">Headless net</th><th class="num">Total sessions</th><th class="num">Total net</th><th class="num">Total raw</th><th class="num">Cost</th></tr></thead>
    <tbody>
{daily_body}
    </tbody>
  </table>
  <h2>Sessions</h2>
  <table>
    <thead><tr><th>Session name</th><th>Runtime</th><th>Type</th><th>Models</th><th class="num">Tokens in</th><th class="num">Tokens out</th><th class="num">Cached-read</th><th class="num">Raw tokens</th><th class="num">Net tokens</th><th class="num">Cost</th><th class="num">Compactions</th><th>MCPs configured</th><th>MCPs observed</th><th>Started</th><th>Finished</th></tr></thead>
    <tbody>
{body}
    </tbody>
  </table>
</body>
</html>
"""
    report_path.write_text(html_doc, encoding="utf-8")
    return report_path


def _html_row(row: Any) -> str:
    return (
        "<tr>"
        f"<td>{html.escape(row.session_name)}</td>"
        f"<td>{html.escape(row.runtime)}</td>"
        f"<td>{html.escape(_session_kind_label(row.session_kind))}</td>"
        f"<td>{html.escape(', '.join(row.models_used))}</td>"
        f"<td class=\"num\">{_format_int(row.tokens_input)}</td>"
        f"<td class=\"num\">{_format_int(row.tokens_output)}</td>"
        f"<td class=\"num\">{_format_int(row.tokens_cache_read)}</td>"
        f"<td class=\"num\">{_format_int(row.raw_tokens_total)}</td>"
        f"<td class=\"num\">{_format_int(row.net_tokens_total)}</td>"
        f"<td class=\"num\">${row.cost_usd:.6f}</td>"
        f"<td class=\"num\">{row.compaction_count}</td>"
        f"<td>{html.escape(', '.join(row.mcps_active) or 'none configured')}</td>"
        f"<td>{html.escape(', '.join(row.mcps_observed) or 'none observed')}</td>"
        f"<td>{html.escape(row.started_at)}</td>"
        f"<td>{html.escape(row.finished_at)}</td>"
        "</tr>"
    )


def _session_kind_html_row(row: dict[str, Any]) -> str:
    return (
        "<tr>"
        f"<td>{html.escape(row['label'])}</td>"
        f"<td class=\"num\">{row['session_count']}</td>"
        f"<td class=\"num\">{_format_int(row['raw_tokens_total'])}</td>"
        f"<td class=\"num\">{_format_int(row['net_tokens_total'])}</td>"
        f"<td class=\"num\">${row['cost_usd']:.6f}</td>"
        "</tr>"
    )


def _daily_html_row(row: Any) -> str:
    return (
        "<tr>"
        f"<td>{html.escape(row.date)}</td>"
        f"<td class=\"num\">{row.interactive_session_count}</td>"
        f"<td class=\"num\">{_format_int(row.interactive_net_tokens_total)}</td>"
        f"<td class=\"num\">{row.headless_worker_session_count}</td>"
        f"<td class=\"num\">{_format_int(row.headless_worker_net_tokens_total)}</td>"
        f"<td class=\"num\">{row.session_count}</td>"
        f"<td class=\"num\">{_format_int(row.net_tokens_total)}</td>"
        f"<td class=\"num\">{_format_int(row.raw_tokens_total)}</td>"
        f"<td class=\"num\">${row.cost_usd:.6f}</td>"
        "</tr>"
    )


def write_json(reports: list[Any], daily_usage: list[Any], output_dir: Path, generated_at: str) -> Path:
    report_path = output_dir / "report.json"
    payload = {
        "generated_at": generated_at,
        "session_count": len(reports),
        "raw_tokens_total": sum(row.raw_tokens_total for row in reports),
        "net_tokens_total": sum(row.net_tokens_total for row in reports),
        "usage_by_session_kind": session_kind_summary(reports),
        "daily_usage": [as_dict(row) for row in daily_usage],
        "sessions": [as_dict(row) for row in reports],
    }
    report_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return report_path
