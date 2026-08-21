#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Score and explain source-backed exact-match domain candidates."""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys

from domain_opportunity_scoring import (
    POLICY_VERSION,
    DomainOpportunityScoringError,
    ScoringPolicy,
    explain_domain,
    export_candidates,
    load_fixture,
    score_store,
)
from domain_opportunity_store import DomainOpportunityStore, DomainOpportunityStoreError


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
