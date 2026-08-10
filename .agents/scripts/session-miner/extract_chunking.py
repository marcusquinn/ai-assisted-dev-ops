#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Chunk-building helpers for session-miner extraction."""

import json
from collections import defaultdict
from dataclasses import dataclass
from typing import Any, Optional


@dataclass(frozen=True)
class ChunkConfig:
    """Configuration for chunk assembly."""

    stats: dict[str, Any]
    git_correlations: Optional[list[dict]] = None
    instruction_candidates: Optional[list[dict]] = None
    max_chunk_bytes: int = 80_000


def _chunk_records(
    records: list[dict], chunk_type: str, category: str, chunks: list[dict], max_chunk_bytes: int,
) -> None:
    """Split a list of records into size-bounded chunks."""
    current_chunk: list[dict] = []
    current_size = 0

    for record in records:
        record_size = len(json.dumps(record).encode("utf-8"))
        if current_size + record_size > max_chunk_bytes and current_chunk:
            chunks.append({
                "chunk_id": f"{chunk_type}_{category}_{len(chunks)}",
                "chunk_type": chunk_type,
                "category": category,
                "record_count": len(current_chunk),
                "records": current_chunk,
            })
            current_chunk = []
            current_size = 0

        current_chunk.append(record)
        current_size += record_size

    if current_chunk:
        chunks.append({
            "chunk_id": f"{chunk_type}_{category}_{len(chunks)}",
            "chunk_type": chunk_type,
            "category": category,
            "record_count": len(current_chunk),
            "records": current_chunk,
        })


def _build_git_summary_chunk(git_correlations: list[dict]) -> dict:
    """Build an aggregate summary chunk for git correlation data."""
    productive = [record for record in git_correlations if record["commits_count"] > 0]
    total_sessions = len(git_correlations)
    avg_duration = round(
        sum(record["duration_minutes"] for record in git_correlations) / total_sessions, 1,
    ) if total_sessions > 0 else 0
    avg_commits_per_message = round(
        sum(record["commits_per_message"] for record in productive) / len(productive), 3,
    ) if productive else 0

    return {
        "chunk_id": "git_summary",
        "chunk_type": "git_correlation",
        "category": "summary",
        "data": {
            "total_sessions": total_sessions,
            "productive_sessions": len(productive),
            "unproductive_sessions": total_sessions - len(productive),
            "productivity_rate": round(len(productive) / max(total_sessions, 1), 3),
            "total_commits": sum(record["commits_count"] for record in git_correlations),
            "total_insertions": sum(record["insertions"] for record in git_correlations),
            "total_deletions": sum(record["deletions"] for record in git_correlations),
            "avg_session_duration_min": avg_duration,
            "avg_commits_per_message": avg_commits_per_message,
        },
    }


def _group_error_records(errors: list[dict]) -> dict[str, list[dict]]:
    """Group error records by error category."""
    grouped: dict[str, list[dict]] = defaultdict(list)
    for record in errors:
        grouped[record["error_category"]].append(record)
    return grouped


def _group_instruction_candidates(records: list[dict]) -> dict[str, list[dict]]:
    """Group instruction candidates by target file."""
    grouped: dict[str, list[dict]] = defaultdict(list)
    for record in records:
        grouped[record["target_file"]].append(record)
    return grouped


def build_chunks(steerage: list[dict], errors: list[dict], config: ChunkConfig) -> list[dict]:
    """Build analysis-ready chunks that fit within model context."""
    chunks: list[dict] = [{
        "chunk_id": "stats",
        "chunk_type": "summary",
        "data": config.stats,
    }]

    # One steerage record can have several classifications. Store it once and
    # retain all memberships on the record so no category loses a valid signal.
    _chunk_records(steerage, "steerage", "all", chunks, config.max_chunk_bytes)

    for category, records in _group_error_records(errors).items():
        _chunk_records(records, "error", category, chunks, config.max_chunk_bytes)

    if config.git_correlations:
        chunks.append(_build_git_summary_chunk(config.git_correlations))
        productive = [record for record in config.git_correlations if record["commits_count"] > 0]
        unproductive = [record for record in config.git_correlations if record["commits_count"] == 0]
        _chunk_records(productive, "git", "productive", chunks, config.max_chunk_bytes)
        _chunk_records(unproductive, "git", "unproductive", chunks, config.max_chunk_bytes)

    if config.instruction_candidates:
        for target, records in _group_instruction_candidates(config.instruction_candidates).items():
            safe_key = target.replace("/", "_").replace(".", "_")
            _chunk_records(records, "instruction_candidate", safe_key, chunks, config.max_chunk_bytes)

    return chunks
