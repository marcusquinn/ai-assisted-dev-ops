#!/usr/bin/env python3
"""Aggregate session tool-output metrics without retaining raw report content."""

from __future__ import annotations

import hashlib
import math
from collections import defaultdict
from dataclasses import dataclass
from typing import Any, Iterable

from session_output_receipts import receipt_background_bytes
from session_output_transcript import ToolResult


SCHEMA = "aidevops.session-output-efficiency/v1"


@dataclass(frozen=True)
class AnalysisConfig:
    runtime: str
    session_id: str
    source_kind: str
    parse_errors: int
    min_repeat_bytes: int
    oversized_bytes: int
    max_findings: int


def digest(*values: str) -> str:
    payload = "\0".join(values).encode("utf-8", errors="replace")
    return hashlib.sha256(payload).hexdigest()[:12]


def byte_length(value: str) -> int:
    return len(value.encode("utf-8", errors="replace"))


def _redundant_finding(kind: str, tool: str, fingerprint: str, count: int, size: int) -> dict[str, Any]:
    redundant_bytes = (count - 1) * size
    return {
        "kind": kind,
        "tool": tool,
        "fingerprint": fingerprint,
        "occurrences": count,
        "redundant_bytes": redundant_bytes,
        "approx_redundant_tokens": math.ceil(redundant_bytes / 4),
    }


def _fragment_findings(
    groups: dict[tuple[str, str], dict[str, int | str]],
    kind: str,
    minimum_count: int,
) -> list[dict[str, Any]]:
    findings = []
    for (tool, fragment_hash), item in groups.items():
        count = int(item["count"])
        if count >= minimum_count:
            findings.append(
                _redundant_finding(
                    kind,
                    tool,
                    digest(tool, kind, fragment_hash),
                    count,
                    int(item["bytes"]),
                )
            )
    findings.sort(key=lambda item: (-item["redundant_bytes"], item["tool"]))
    return findings


def repeated_fragment_findings(results: list[ToolResult]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    line_groups: dict[tuple[str, str], dict[str, int | str]] = {}
    block_groups: dict[tuple[str, str], dict[str, int | str]] = {}
    for result in results:
        if byte_length(result.output) > 100_000:
            continue
        lines = [line.rstrip() for line in result.output.splitlines() if line.strip()]
        for line in lines:
            size = byte_length(line)
            if size >= 40:
                key = (result.tool, digest(line))
                item = line_groups.setdefault(key, {"tool": result.tool, "count": 0, "bytes": size})
                item["count"] = int(item["count"]) + 1
        for index in range(max(0, len(lines) - 2)):
            block = "\n".join(lines[index : index + 3])
            size = byte_length(block)
            if size >= 120:
                key = (result.tool, digest(block))
                item = block_groups.setdefault(key, {"tool": result.tool, "count": 0, "bytes": size})
                item["count"] = int(item["count"]) + 1
    return (
        _fragment_findings(line_groups, "repeated-line", 3),
        _fragment_findings(block_groups, "repeated-block", 2),
    )


def _unchanged_findings(results: list[ToolResult], minimum_bytes: int) -> tuple[list[dict[str, Any]], int, int]:
    groups: dict[tuple[str, str, str], list[ToolResult]] = defaultdict(list)
    for result in results:
        if byte_length(result.output) >= minimum_bytes:
            groups[(result.tool, digest(result.input_value), digest(result.output))].append(result)
    findings = []
    redundant_results = 0
    redundant_bytes = 0
    for (tool, input_hash, output_hash), group in groups.items():
        if len(group) < 2:
            continue
        finding = _redundant_finding(
            "unchanged-snapshot",
            tool,
            digest(tool, input_hash, output_hash),
            len(group),
            byte_length(group[0].output),
        )
        finding["redundant_results"] = len(group) - 1
        finding["bytes_each"] = byte_length(group[0].output)
        findings.append(finding)
        redundant_results += len(group) - 1
        redundant_bytes += int(finding["redundant_bytes"])
    findings.sort(key=lambda item: (-item["redundant_bytes"], item["tool"]))
    return findings, redundant_results, redundant_bytes


def _duplicate_findings(results: list[ToolResult], minimum_bytes: int) -> list[dict[str, Any]]:
    groups: dict[str, list[ToolResult]] = defaultdict(list)
    for result in results:
        if byte_length(result.output) >= minimum_bytes:
            groups[digest(result.output)].append(result)
    findings = []
    for output_hash, group in groups.items():
        signatures = {(item.tool, digest(item.input_value)) for item in group}
        if len(group) < 2 or len(signatures) < 2:
            continue
        tools = {item.tool for item in group}
        findings.append(
            _redundant_finding(
                "duplicate-output",
                "multiple" if len(tools) > 1 else group[0].tool,
                digest("duplicate", output_hash),
                len(group),
                byte_length(group[0].output),
            )
        )
    findings.sort(key=lambda item: (-item["redundant_bytes"], item["tool"]))
    return findings


def _size_findings(
    groups: dict[tuple[str, str], list[ToolResult]],
    kind: str,
) -> list[dict[str, Any]]:
    findings = []
    for (tool, output_hash), group in groups.items():
        sizes = [byte_length(item.output) for item in group]
        findings.append(
            {
                "kind": kind,
                "tool": tool,
                "fingerprint": digest(tool, kind, output_hash),
                "occurrences": len(group),
                "largest_bytes": max(sizes),
                "total_bytes": sum(sizes),
                "approx_total_tokens": math.ceil(sum(sizes) / 4),
            }
        )
    findings.sort(key=lambda item: (-item["total_bytes"], item["tool"]))
    return findings


def _oversized_groups(results: list[ToolResult], threshold: int) -> dict[tuple[str, str], list[ToolResult]]:
    groups: dict[tuple[str, str], list[ToolResult]] = defaultdict(list)
    for result in results:
        if byte_length(result.output) >= threshold:
            groups[(result.tool, digest(result.output))].append(result)
    return groups


def _visibility_metrics(
    results: list[ToolResult],
    threshold: int,
) -> tuple[dict[str, Any], dict[str, int], list[dict[str, Any]], list[dict[str, Any]]]:
    receipt_results = 0
    receipt_visible_bytes = 0
    background_bytes = 0
    raw_fallback_results = 0
    exact_bypass_results = 0
    fallback_groups: dict[tuple[str, str], list[ToolResult]] = defaultdict(list)
    success_groups: dict[tuple[str, str], list[ToolResult]] = defaultdict(list)
    for result in results:
        declared_bytes = receipt_background_bytes(result.output)
        if declared_bytes is not None:
            receipt_results += 1
            receipt_visible_bytes += byte_length(result.output)
            background_bytes += declared_bytes
        if "output_sandbox: evidence store unavailable; running with native output" in result.output:
            raw_fallback_results += 1
            fallback_groups[(result.tool, digest("raw-fallback"))].append(result)
        if "output_sandbox: bypass exact/verbatim command" in result.output:
            exact_bypass_results += 1
        if result.success is True and byte_length(result.output) >= threshold:
            success_groups[(result.tool, digest(result.output))].append(result)
    visibility = {
        "model_visible_tool_output_bytes": sum(byte_length(item.output) for item in results),
        "receipt_results": receipt_results,
        "receipt_model_visible_bytes": receipt_visible_bytes,
        "declared_background_evidence_bytes": background_bytes,
        "background_content_scanned": False,
    }
    stats = {
        "raw_fallback_results": raw_fallback_results,
        "exact_output_bypass_results": exact_bypass_results,
        "successful_oversized_results": sum(len(group) for group in success_groups.values()),
    }
    return visibility, stats, _size_findings(fallback_groups, "raw-fallback"), _size_findings(success_groups, "success-verbosity")


def _finding_bytes(finding: dict[str, Any]) -> int:
    return int(finding.get("redundant_bytes", finding.get("total_bytes", finding.get("largest_bytes", 0))))


def _category_summary(kind: str, findings: list[dict[str, Any]]) -> dict[str, Any]:
    leading = min(
        findings,
        key=lambda item: (-_finding_bytes(item), -int(item["occurrences"]), str(item["tool"])),
    )
    return {
        "kind": kind,
        "finding_count": len(findings),
        "occurrences": sum(int(item["occurrences"]) for item in findings),
        "aggregate_bytes": sum(_finding_bytes(item) for item in findings),
        "leading_tool": leading["tool"],
    }


def analyse(results: Iterable[ToolResult], config: AnalysisConfig) -> dict[str, Any]:
    materialized = list(results)
    total_bytes = sum(byte_length(result.output) for result in materialized)
    unchanged, redundant_results, redundant_bytes = _unchanged_findings(
        materialized, config.min_repeat_bytes
    )
    duplicates = _duplicate_findings(materialized, config.min_repeat_bytes)
    repeated_lines, repeated_blocks = repeated_fragment_findings(materialized)
    oversized_groups = _oversized_groups(materialized, config.oversized_bytes)
    oversized = _size_findings(oversized_groups, "oversized-output")
    visibility, visibility_stats, fallbacks, success_verbosity = _visibility_metrics(
        materialized, config.oversized_bytes
    )
    categories = (
        ("unchanged-snapshot", unchanged),
        ("duplicate-output", duplicates),
        ("repeated-block", repeated_blocks),
        ("repeated-line", repeated_lines),
        ("raw-fallback", fallbacks),
        ("success-verbosity", success_verbosity),
        ("oversized-output", oversized),
    )
    findings = [finding for _, category_findings in categories for finding in category_findings]
    category_summary = [
        _category_summary(kind, category_findings)
        for kind, category_findings in categories
        if category_findings
    ]
    stats = {
        "completed_tool_results": len(materialized),
        "tool_output_bytes": total_bytes,
        "approx_tool_output_tokens": math.ceil(total_bytes / 4),
        "repeated_snapshot_groups": len(unchanged),
        "redundant_tool_results": redundant_results,
        "redundant_output_bytes": redundant_bytes,
        "approx_redundant_tokens": math.ceil(redundant_bytes / 4),
        "duplicate_output_groups": len(duplicates),
        "repeated_line_groups": len(repeated_lines),
        "repeated_block_groups": len(repeated_blocks),
        "oversized_tool_results": sum(len(group) for group in oversized_groups.values()),
        "parse_errors": config.parse_errors,
        **visibility_stats,
    }
    return {
        "schema": SCHEMA,
        "runtime": config.runtime,
        "session": config.session_id or None,
        "source": config.source_kind,
        "thresholds": {
            "minimum_repeat_bytes": config.min_repeat_bytes,
            "oversized_output_bytes": config.oversized_bytes,
        },
        "stats": stats,
        "visibility": visibility,
        "category_summary": category_summary,
        "findings": findings[: config.max_findings],
        "privacy": "Raw tool inputs, outputs, commands, and paths are omitted.",
    }
