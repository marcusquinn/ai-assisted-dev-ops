#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Instruction-candidate clustering for the session-miner compressor."""

from collections import defaultdict
from typing import Callable, Iterable


def _extract_candidate(
    record: dict, redactor: Callable[[str], str], normalizer: Callable[[str], str],
) -> tuple[str, dict] | None:
    """Return one compatibility-preserving candidate observation."""
    raw_text = record.get("text", "")
    if not raw_text or len(raw_text) < 20:
        return None

    target_file = record.get("target_file", ".agents/AGENTS.md")
    display_text = redactor((record.get("display_text") or raw_text)[:800])
    return target_file, {
        "text": raw_text[:800],
        "display_text": display_text,
        "confidence": record.get("confidence", 0.5),
        "category": record.get("category", "general"),
        "session_title": record.get("session_title", "")[:80],
        "session_id": record.get("session_id", ""),
        "timestamp": record.get("timestamp"),
        "source_hash": record.get("source_hash", ""),
        "fingerprint": record.get("fingerprint") or normalizer(raw_text),
        "polarity": record.get("polarity", "positive"),
        "explicit_persistence": record.get("explicit_persistence", True),
    }


def _summarize_cluster(observations: list[dict]) -> dict | None:
    """Return a qualified candidate summary, or omit unsupported guidance."""
    distinct_sessions = sorted({item["session_id"] for item in observations if item["session_id"]})
    explicit = any(item["explicit_persistence"] for item in observations)
    polarities = {item["polarity"] for item in observations}
    timestamps = [item["timestamp"] for item in observations if item["timestamp"] is not None]
    support = len(distinct_sessions)
    basis = "explicit_persistence" if explicit else "recurring" if support >= 2 else "insufficient_support"
    if basis == "insufficient_support":
        return None
    return {
        **max(observations, key=lambda item: item["confidence"]),
        "support": support,
        "first_seen": min(timestamps) if timestamps else None,
        "last_seen": max(timestamps) if timestamps else None,
        "qualification_basis": basis,
        "requires_judgment": len(polarities) > 1,
        "contradictions": sorted(polarities) if len(polarities) > 1 else [],
    }


def compress_instruction_candidates(
    records: Iterable[dict], redactor: Callable[[str], str], normalizer: Callable[[str], str],
) -> dict[str, list[dict]]:
    """Cluster observations by target and fingerprint, retaining qualification evidence."""
    clusters: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for record in records:
        extracted = _extract_candidate(record, redactor, normalizer)
        if extracted is not None:
            target_file, candidate = extracted
            clusters[(target_file, candidate["fingerprint"])].append(candidate)

    result: dict[str, list[dict]] = {}
    for (target_file, _fingerprint), observations in sorted(clusters.items()):
        candidate = _summarize_cluster(observations)
        if candidate is not None:
            result.setdefault(target_file, []).append(candidate)

    for candidates in result.values():
        candidates.sort(key=lambda item: (-item["support"], -item["confidence"]))
    return result
