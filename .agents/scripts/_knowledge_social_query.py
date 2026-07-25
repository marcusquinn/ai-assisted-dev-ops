#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only per-corpus social search and deterministic result fusion."""

from __future__ import annotations

import json
import math
import re
import sqlite3
from pathlib import Path
from typing import Any

from knowledge_social_store import (
    SocialStoreError,
    connect_read_only,
    database_path,
    require_schema,
)

RRF_K = 60
MAX_QUERY_CHARACTERS = 1024
MAX_QUERY_TERMS = 32
MAX_CANDIDATES = 500
INVALID_INFERENCE_CONFIDENCE = (
    "inferred evidence is missing a valid confidence score"
)
AUTHORED_CLASSES = {"authored"}
INFERRED_CLASSES = {"generated", "inferred"}
WEAK_ACTIVITY_TYPES = {"bookmark", "bookmarked", "bookmarks", "like", "liked", "likes"}
DISTRIBUTION_ACTIVITY_TYPES = {"quote", "quoted", "repost", "reposted", "reposts"}
RELATIONSHIP_ACTIVITY_TYPES = {
    "follow",
    "followed",
    "followers",
    "following",
    "listed",
    "lists",
}


def social_store_exists(root: Path) -> bool:
    path = database_path(root)
    if path.is_symlink():
        raise SocialStoreError("social database cannot be a symlink")
    if not path.exists():
        return False
    if not path.is_file():
        raise SocialStoreError("social database is not a regular file")
    return True


def build_fts_query(query: str) -> str:
    if not query or len(query) > MAX_QUERY_CHARACTERS:
        raise SocialStoreError("query must contain 1 to 1024 characters")
    terms = re.findall(r"\w+", query, flags=re.UNICODE)
    if not terms:
        raise SocialStoreError("query must contain searchable text")
    if len(terms) > MAX_QUERY_TERMS:
        raise SocialStoreError("query contains too many terms")
    return " AND ".join(f'"{term}"' for term in terms)


def candidate_limit(result_limit: int) -> int:
    return min(MAX_CANDIDATES, max(result_limit, result_limit * 5))


def _activities(
    connection: sqlite3.Connection, provider: str, remote_id: str
) -> list[dict[str, Any]]:
    rows = connection.execute(
        """SELECT activity_type,remote_id,actor_remote_id,occurred_at,
                  observed_at,state,batch_id
             FROM activities
            WHERE provider=? AND object_remote_id=? AND state='active'
            ORDER BY activity_type,remote_id""",
        (provider, remote_id),
    ).fetchall()
    return [dict(row) for row in rows]


def _batch_stream(connection: sqlite3.Connection, batch_id: str) -> str | None:
    row = connection.execute(
        "SELECT stream FROM fetch_batches WHERE batch_id=?", (batch_id,)
    ).fetchone()
    return str(row["stream"]) if row is not None else None


def _inference_confidence(row: sqlite3.Row) -> float | None:
    if str(row["evidence_class"]).lower() not in INFERRED_CLASSES:
        return None
    try:
        metadata = json.loads(str(row["provider_json"]))
    except (json.JSONDecodeError, TypeError) as error:
        raise SocialStoreError(INVALID_INFERENCE_CONFIDENCE) from error
    confidence = metadata.get("confidence") if isinstance(metadata, dict) else None
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
        raise SocialStoreError(INVALID_INFERENCE_CONFIDENCE)
    try:
        score = float(confidence)
    except (OverflowError, ValueError) as error:
        raise SocialStoreError(INVALID_INFERENCE_CONFIDENCE) from error
    if not math.isfinite(score) or not 0.0 <= score <= 1.0:
        raise SocialStoreError(INVALID_INFERENCE_CONFIDENCE)
    return score


def _citation(
    connection: sqlite3.Connection, alias: str, row: sqlite3.Row
) -> dict[str, Any]:
    provider = str(row["provider"])
    remote_id = str(row["remote_id"])
    batch_id = str(row["batch_id"])
    return {
        "corpus_alias": alias,
        "provider": provider,
        "object_type": str(row["object_type"]),
        "remote_id": remote_id,
        "account_remote_id": row["account_remote_id"],
        "evidence_class": str(row["evidence_class"]),
        "inference_confidence": _inference_confidence(row),
        "created_at": row["created_at"],
        "observed_at": str(row["observed_at"]),
        "batch_id": batch_id,
        "batch_stream": _batch_stream(connection, batch_id),
        "activities": _activities(connection, provider, remote_id),
    }


def search_corpus(
    alias: str, root: Path, fts_query: str, limit: int
) -> list[dict[str, Any]]:
    connection = connect_read_only(root)
    try:
        require_schema(connection)
        rows = connection.execute(
            """SELECT o.provider,o.object_type,o.remote_id,o.account_remote_id,
                       o.text_content,o.created_at,o.observed_at,o.evidence_class,
                       o.provider_json,o.batch_id,bm25(objects_fts) AS bm25_score
                 FROM objects_fts
                 JOIN objects o
                   ON o.provider=objects_fts.provider
                  AND o.object_type=objects_fts.object_type
                  AND o.remote_id=objects_fts.remote_id
                WHERE objects_fts MATCH ?
                ORDER BY bm25_score,o.provider,o.object_type,o.remote_id
                LIMIT ?""",
            (fts_query, limit),
        ).fetchall()
        return [
            {
                "key": (
                    str(row["provider"]),
                    str(row["object_type"]),
                    str(row["remote_id"]),
                ),
                "text": row["text_content"],
                "citation": _citation(connection, alias, row),
            }
            for row in rows
        ]
    except sqlite3.Error as error:
        raise SocialStoreError("social query could not be evaluated safely") from error
    finally:
        connection.close()


def _citation_classification(citation: dict[str, Any]) -> str:
    evidence_class = str(citation["evidence_class"]).lower()
    activity_types = {
        str(activity["activity_type"]).lower()
        for activity in citation.get("activities", [])
    }
    classification = "observed"
    if evidence_class in AUTHORED_CLASSES:
        classification = "authored"
    elif evidence_class in INFERRED_CLASSES:
        classification = "inferred"
    elif evidence_class == "weak_signal" or activity_types & WEAK_ACTIVITY_TYPES:
        classification = "weak_signal"
    elif (
        evidence_class in {"distributed", "quoted", "reposted"}
        or activity_types & DISTRIBUTION_ACTIVITY_TYPES
    ):
        classification = "distribution"
    elif evidence_class == "relationship" or activity_types & RELATIONSHIP_ACTIVITY_TYPES:
        classification = "relationship"
    return classification


def opinion_semantics(citations: list[dict[str, Any]]) -> dict[str, Any]:
    classifications = [
        (_citation_classification(citation), citation) for citation in citations
    ]
    labels = sorted({classification for classification, _ in classifications})
    inferred_citations = [
        citation
        for classification, citation in classifications
        if classification == "inferred"
    ]
    supports_opinion = "authored" in labels
    if supports_opinion:
        guidance = "Attribute opinions only to cited authored evidence."
    elif "inferred" in labels:
        guidance = (
            "Keep inference labelled, confidence-scored, reviewable, "
            "and evidence-linked."
        )
    else:
        guidance = (
            "Do not present distribution, weak, relationship, or observed signals "
            "as opinion."
        )
    return {
        "evidence_labels": labels,
        "supports_attributed_opinion": supports_opinion,
        "inference_review": {
            "required": bool(inferred_citations),
            "confidence_complete": (
                all(
                    citation.get("inference_confidence") is not None
                    for citation in inferred_citations
                )
                if inferred_citations
                else None
            ),
            "evidence_citation_count": len(inferred_citations),
        },
        "guidance": guidance,
    }


def fuse_results(
    corpus_results: list[tuple[str, list[dict[str, Any]]]], limit: int
) -> list[dict[str, Any]]:
    fused: dict[tuple[str, str, str], dict[str, Any]] = {}
    for alias, hits in sorted(corpus_results, key=lambda item: item[0]):
        for rank, hit in enumerate(hits, start=1):
            key = hit["key"]
            result = fused.setdefault(
                key,
                {
                    "provider": key[0],
                    "object_type": key[1],
                    "remote_id": key[2],
                    "text": hit["text"],
                    "rrf_score": 0.0,
                    "citations": [],
                    "_best_source": (rank, alias),
                },
            )
            result["rrf_score"] += 1.0 / (RRF_K + rank)
            result["citations"].append(hit["citation"])
            if (rank, alias) < result["_best_source"]:
                result["text"] = hit["text"]
                result["_best_source"] = (rank, alias)

    ordered = sorted(
        fused.values(),
        key=lambda item: (
            -float(item["rrf_score"]),
            str(item["provider"]),
            str(item["object_type"]),
            str(item["remote_id"]),
        ),
    )[:limit]
    for result in ordered:
        result.pop("_best_source")
        result["rrf_score"] = round(float(result["rrf_score"]), 12)
        result["citations"].sort(key=lambda item: str(item["corpus_alias"]))
        result["opinion_semantics"] = opinion_semantics(result["citations"])
    return ordered
