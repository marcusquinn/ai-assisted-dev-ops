#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Score and explain source-backed exact-match domain candidates."""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Any, Mapping

from domain_opportunity_contract import CandidateScore, content_hash, utc_now
from domain_opportunity_scoring import (
    POLICY_VERSION,
    DomainOpportunityScoringError,
    ScoringPolicy,
    score_listing,
)
from domain_opportunity_store import DomainOpportunityStore, DomainOpportunityStoreError


def _raw_evidence(store: DomainOpportunityStore, listing: Mapping[str, Any]) -> dict[str, Any]:
    """Read the current provider/operator evidence object."""
    row = store.connection.execute(
        """SELECT o.raw_json FROM listings l JOIN listing_observations o
             ON o.observation_id=l.current_observation_id
           WHERE l.provider=? AND l.provider_listing_id=?""",
        (listing["provider"], listing["provider_listing_id"]),
    ).fetchone()
    try:
        decoded = json.loads(row["raw_json"])
    except (KeyError, TypeError, json.JSONDecodeError):
        return {}
    return decoded if isinstance(decoded, dict) else {}


def _keyword_evidence(store: DomainOpportunityStore, listing: Mapping[str, Any]) -> list[dict[str, Any]]:
    """Read source-labelled keyword JSON without interpreting absent values."""
    rows = store.connection.execute(
        """SELECT k.source,k.value_text,k.observed_at FROM keyword_metrics k
             JOIN listings l ON l.listing_id=k.listing_id
           WHERE l.provider=? AND l.provider_listing_id=?
           ORDER BY k.observed_at DESC,k.metric_id DESC""",
        (listing["provider"], listing["provider_listing_id"]),
    ).fetchall()
    evidence: list[dict[str, Any]] = []
    for row in rows:
        try:
            value = json.loads(row["value_text"])
            evidence.append({"source": row["source"], "observed_at": row["observed_at"], **value})
        except (TypeError, json.JSONDecodeError):
            continue
    return evidence


def score_store(store: DomainOpportunityStore, policy: ScoringPolicy) -> dict[str, Any]:
    """Score current listings and persist one atomic, idempotent policy run."""
    policy.validate()
    explanations = [
        score_listing(listing, policy, _raw_evidence(store, listing), _keyword_evidence(store, listing))
        for listing in store.current_listings()
    ]
    calculated_at = utc_now()
    for explanation in explanations:
        explanation["calculated_at"] = calculated_at
    run_hash = content_hash({"policy": asdict(policy), "inputs": [item["input_hash"] for item in explanations]})
    run_id = f"domain-score-{policy.version}-{run_hash[:24]}"
    with store.transaction():
        store.begin_source_run(run_id, "domain-opportunity-scoring", started_at=calculated_at)
        for explanation in explanations:
            store.insert_candidate_score(CandidateScore(
                provider=str(explanation["provider"]), provider_listing_id=str(explanation["provider_listing_id"]),
                source_run_id=run_id, model=policy.version, score_micros=int(explanation["score_micros"]),
                observed_at=calculated_at, components=explanation["components"],
                payload_hash=explanation["input_hash"],
            ))
        store.complete_source_run(run_id, len(explanations))
    return {"policy_version": policy.version, "run_id": run_id, "records": len(explanations), "candidates": explanations}


def explain_domain(store: DomainOpportunityStore, domain: str, policy_version: str) -> dict[str, Any]:
    """Read the newest persisted explanation for one domain and policy."""
    row = store.connection.execute(
        """SELECT s.score_id,s.score_micros,s.observed_at,s.payload_hash,l.fqdn
             FROM candidate_scores s JOIN listings l ON l.listing_id=s.listing_id
           WHERE l.fqdn=? AND s.model=? ORDER BY s.score_id DESC LIMIT 1""",
        (domain.casefold().rstrip("."), policy_version),
    ).fetchone()
    if row is None:
        raise DomainOpportunityScoringError("no persisted score matches the domain and policy")
    components = store.connection.execute(
        "SELECT name,value_micros,weight_micros,evidence_json FROM score_components WHERE score_id=? ORDER BY name",
        (row["score_id"],),
    ).fetchall()
    return {
        "domain": row["fqdn"], "policy_version": policy_version, "score_micros": row["score_micros"],
        "calculated_at": row["observed_at"], "input_hash": row["payload_hash"],
        "components": {component["name"]: {
            "value_micros": component["value_micros"], "weight_micros": component["weight_micros"],
            "evidence": json.loads(component["evidence_json"]),
        } for component in components},
    }


def load_fixture(store: DomainOpportunityStore, path: str) -> dict[str, int]:
    """Import synthetic JSONL listings, continuing past malformed records."""
    fixture = Path(path)
    if fixture.is_symlink() or not fixture.is_file():
        raise DomainOpportunityScoringError("fixture must be a regular JSONL file")
    imported = rejected = 0
    for line in fixture.read_text(encoding="utf-8").splitlines():
        try:
            record = json.loads(line)
            raw = record.get("raw_json") if isinstance(record.get("raw_json"), dict) else {}
            raw["phrase_evidence"] = record.pop("phrase_evidence", raw.get("phrase_evidence", []))
            record["raw_json"] = raw
            with store.transaction():
                store.begin_source_run(record["source_run_id"], record["provider"], started_at=record["observed_at"])
                imported += int(store.upsert_listing_observation(record))
                store.complete_source_run(record["source_run_id"], 1)
        except (AttributeError, KeyError, TypeError, ValueError, json.JSONDecodeError):
            rejected += 1
    return {"imported": imported, "rejected": rejected}


def export_candidates(store: DomainOpportunityStore, policy_version: str) -> list[dict[str, Any]]:
    """Return one stable latest-score export row per domain."""
    domains = store.connection.execute(
        """SELECT DISTINCT l.fqdn FROM candidate_scores s JOIN listings l ON l.listing_id=s.listing_id
           WHERE s.model=? ORDER BY l.fqdn""", (policy_version,)
    ).fetchall()
    return [explain_domain(store, row["fqdn"], policy_version) for row in domains]


def _policy(args: argparse.Namespace) -> ScoringPolicy:
    """Build the versioned policy from explicit CLI overrides."""
    return ScoringPolicy(
        min_length=args.min_length, max_length=args.max_length,
        min_words=args.min_words, max_words=args.max_words,
        max_repeated_characters=args.max_repeated_characters,
        max_price_micros=args.max_price_micros,
        risk_penalty_micros=args.risk_penalty_micros,
        disallowed_terms=tuple(sorted(set(args.disallowed_term))),
    )


def cmd_score(args: argparse.Namespace) -> int:
    """Optionally import a fixture, then score the current store."""
    with DomainOpportunityStore(args.db, initialize=bool(args.fixture)) as store:
        fixture = load_fixture(store, args.fixture) if args.fixture else {"imported": 0, "rejected": 0}
        result = score_store(store, _policy(args))
    print(json.dumps({**fixture, **result}, sort_keys=True))
    return 0


def cmd_explain(args: argparse.Namespace) -> int:
    """Render one persisted component explanation."""
    with DomainOpportunityStore(args.db) as store:
        result = explain_domain(store, args.domain, args.policy_version)
    print(json.dumps(result, sort_keys=True) if args.json else _text_explanation(result))
    return 0


def _text_explanation(result: dict[str, object]) -> str:
    """Render a compact human-readable explanation."""
    lines = [f"{result['domain']}: {result['score_micros']} ({result['policy_version']})"]
    components = result.get("components", {})
    if isinstance(components, dict):
        for name, component in components.items():
            if isinstance(component, dict):
                lines.append(f"- {name}: {component.get('value_micros')} x {component.get('weight_micros')}")
    return "\n".join(lines)


def cmd_export(args: argparse.Namespace) -> int:
    """Print stable JSONL candidate explanations."""
    with DomainOpportunityStore(args.db) as store:
        rows = export_candidates(store, args.policy_version)
    for row in rows:
        print(json.dumps(row, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    """Build score, explain, and export commands."""
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    score = subparsers.add_parser("score")
    score.add_argument("--db", required=True)
    score.add_argument("--fixture")
    score.add_argument("--min-length", type=int, default=4)
    score.add_argument("--max-length", type=int, default=24)
    score.add_argument("--min-words", type=int, default=1)
    score.add_argument("--max-words", type=int, default=4)
    score.add_argument("--max-repeated-characters", type=int, default=3)
    score.add_argument("--max-price-micros", type=int, default=5_000_000_000)
    score.add_argument("--risk-penalty-micros", type=int, default=250_000)
    score.add_argument("--disallowed-term", action="append", default=["adult", "casino", "porn"])
    score.set_defaults(handler=cmd_score)
    explain = subparsers.add_parser("explain")
    explain.add_argument("--db", required=True)
    explain.add_argument("--domain", required=True)
    explain.add_argument("--policy-version", default=POLICY_VERSION)
    explain.add_argument("--json", action="store_true")
    explain.set_defaults(handler=cmd_explain)
    export = subparsers.add_parser("export")
    export.add_argument("--db", required=True)
    export.add_argument("--policy-version", default=POLICY_VERSION)
    export.set_defaults(handler=cmd_export)
    return parser


def main(argv: list[str] | None = None) -> int:
    """Run the local deterministic scorer."""
    args = build_parser().parse_args(argv)
    try:
        return int(args.handler(args))
    except (DomainOpportunityScoringError, DomainOpportunityStoreError):
        print("domain-opportunity-score: scoring request could not be completed", file=sys.stderr)
        return 1
    except (OSError, sqlite3.Error):
        print("domain-opportunity-score: local storage operation failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
