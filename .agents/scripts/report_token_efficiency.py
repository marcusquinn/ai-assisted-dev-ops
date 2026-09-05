#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read-only, consistently repriced efficiency evidence from the request ledger."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import sqlite3
import statistics
from collections import defaultdict
from contextlib import closing
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

TOKEN_FIELDS = ("tokens_input", "tokens_output", "tokens_reasoning", "tokens_cache_read", "tokens_cache_write")
OPTIONAL_FIELDS = ("provider_id", "variant", "parent_session_id", "pricing_version", "cost", "error_type", "routing_attempt", "routing_escalated", "routing_tier")
RATE_FIELDS = ("input", "output", "output", "cache_read", "cache_write")


def new_totals() -> dict[str, Any]:
    return dict.fromkeys((*TOKEN_FIELDS, "requests", "priced_requests", "recorded_cost_requests", "recorded_cost_usd", "known_repriced_cost_usd", "errors", "retry_requests", "retry_observed_requests", "escalated_requests", "escalation_observed_requests"), 0)


def model_rates(model: str, pricing: dict[str, Any]) -> dict[str, float] | None:
    # Do not infer a Pro/unknown model's prices from a cheaper family substring.
    name = model.rsplit("/", 1)[-1]
    rates = pricing.get("models", {}).get(name)
    if not isinstance(rates, dict):
        return None
    if any(not isinstance(rates.get(key), (int, float)) or not math.isfinite(rates[key]) or rates[key] < 0 for key in set(RATE_FIELDS)):
        return None
    return rates


def add_request(total: dict[str, Any], row: dict[str, Any], pricing: dict[str, Any]) -> None:
    total["requests"] += 1
    for field in TOKEN_FIELDS:
        total[field] += row[field] or 0
    if row.get("cost") is not None:
        total["recorded_cost_requests"] += 1
        total["recorded_cost_usd"] += row["cost"]
    rates = model_rates(row["model_id"] or "", pricing)
    if rates is not None:
        total["priced_requests"] += 1
        total["known_repriced_cost_usd"] += sum((row[field] or 0) * rates[rate] / 1e6 for field, rate in zip(TOKEN_FIELDS, RATE_FIELDS))
    total["errors"] += bool(row.get("error_type"))
    for source, observed, value, threshold in (
        ("routing_attempt", "retry_observed_requests", "retry_requests", 1),
        ("routing_escalated", "escalation_observed_requests", "escalated_requests", 0),
    ):
        # routing_escalated historically defaults to zero even without routing.
        # Require routing attribution before treating that default as observation.
        if source == "routing_escalated" and not row.get("routing_tier"):
            continue
        if row.get(source) is not None:
            total[observed] += 1
            total[value] += row[source] > threshold


def ratio(numerator: float, denominator: float, scale: float = 1) -> float | None:
    return round(scale * numerator / denominator, 2) if denominator else None


def finish_totals(total: dict[str, Any]) -> dict[str, Any]:
    result = dict(total)
    prompt = sum(total[field] for field in ("tokens_input", "tokens_cache_read", "tokens_cache_write"))
    result["cache_token_hit_pct"] = ratio(total["tokens_cache_read"], prompt, 100)
    result["mean_prompt_tokens"] = ratio(prompt, total["requests"])
    result["raw_tokens_total"] = sum(total[field] for field in TOKEN_FIELDS)
    for field in ("recorded_cost_usd", "known_repriced_cost_usd"):
        result[field] = round(total[field], 6)
    result["repriced_api_equivalent_usd"] = result["known_repriced_cost_usd"] if total["priced_requests"] == total["requests"] and total["requests"] else None
    if not total["recorded_cost_requests"]:
        result["recorded_cost_usd"] = None
    for label, observed, value in (("retry", "retry_observed_requests", "retry_requests"), ("escalation", "escalation_observed_requests", "escalated_requests")):
        result[f"{label}_observed_pct"] = ratio(total[value], total[observed], 100)
    return result


def lineage_roots(parents: dict[str, set[str]]) -> tuple[dict[str, str], int]:
    roots = {}
    ambiguous = 0
    for session in parents:
        current, seen = session, set()
        while current not in seen and len(parents.get(current, set())) == 1:
            seen.add(current)
            current = next(iter(parents[current]))
        if current in seen or len(parents.get(current, set())) > 1:
            # Never manufacture a lineage for conflicting/cyclic telemetry.
            roots[session] = session
            ambiguous += 1
        else:
            roots[session] = current
    return roots, ambiguous


def ledger_rows(db: Path, since: str, parents: dict[str, set[str]]):
    # mode=ro prevents accidental database creation and never rewrites historical prices.
    with closing(sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True, timeout=5)) as conn:
        conn.row_factory = sqlite3.Row
        conn.execute("BEGIN")
        columns = {row[1] for row in conn.execute("PRAGMA table_info(llm_requests)")}
        required = {"session_id", "model_id", "timestamp", *TOKEN_FIELDS}
        if not required.issubset(columns):
            raise ValueError("request ledger lacks required token/model columns")
        selected = required.union(OPTIONAL_FIELDS)
        if "parent_session_id" in columns:
            for row in conn.execute("SELECT DISTINCT session_id, parent_session_id FROM llm_requests WHERE parent_session_id IS NOT NULL AND parent_session_id != ''"):
                parents[row[0]].add(row[1])
        # Static SQL supports older schemas; only allowlisted fields leave this reader.
        for raw in conn.execute("SELECT * FROM llm_requests WHERE timestamp >= ?", (since,)):
            yield {field: raw[field] if field in columns else None for field in selected}


def model_rows(groups: dict) -> list[dict[str, Any]]:
    models = []
    for (provider, model, variant), group in groups.items():
        prompts = sorted(group["prompts"])
        models.append({"provider": provider, "model": model, "variant": variant,
                       **finish_totals(group["totals"]), "median_prompt_tokens": statistics.median(prompts),
                       "p95_prompt_tokens": prompts[math.ceil(len(prompts) * 0.95) - 1]})
    return sorted(models, key=lambda row: -row["requests"])


def session_families(sessions: dict, roots: dict) -> list[dict[str, Any]]:
    families: dict[str, dict[str, Any]] = {}
    for session, values in sessions.items():
        root = roots.get(session, session)
        family = families.setdefault(root, {"totals": new_totals(), "observed_sessions": 0, "observed_child_sessions": 0})
        family["observed_sessions"] += 1
        family["observed_child_sessions"] += session != root
        for field, value in values.items():
            family["totals"][field] += value
    return [{"session_fingerprint": hashlib.sha256(root.encode()).hexdigest()[:16],
                    "observed_sessions": family["observed_sessions"], "observed_child_sessions": family["observed_child_sessions"],
                    **finish_totals(family["totals"])} for root, family in families.items()]


def collect_efficiency(db: Path, pricing: dict[str, Any], since: str, limit: int = 10) -> dict[str, Any]:
    groups: dict[tuple, dict] = {}
    sessions: dict[str, dict] = {}
    parents: dict[str, set[str]] = defaultdict(set)
    versions: dict[str, int] = defaultdict(int)
    total = new_totals()
    for row in ledger_rows(db, since, parents):
        key = tuple(row[field] or "unknown" for field in ("provider_id", "model_id", "variant"))
        group = groups.setdefault(key, {"totals": new_totals(), "prompts": []})
        group["prompts"].append(sum(row[field] or 0 for field in ("tokens_input", "tokens_cache_read", "tokens_cache_write")))
        session = row["session_id"]
        parents.setdefault(session, set())
        session_total = sessions.setdefault(session, new_totals())
        for accumulator in (total, group["totals"], session_total):
            add_request(accumulator, row, pricing)
        versions[row["pricing_version"] or "unknown"] += 1
    roots, ambiguous = lineage_roots(parents)
    family_rows = session_families(sessions, roots)
    return {
        "schema_version": 1, "since": since, "generated_at": datetime.now(timezone.utc).isoformat(),
        "pricing_version": pricing.get("version", "unknown"), "recorded_pricing_versions": dict(sorted(versions.items())),
        "summary": finish_totals(total), "models": model_rows(groups),
        "session_family_count": len(family_rows), "ambiguous_lineage_sessions": ambiguous,
        "largest_session_families": sorted(family_rows, key=lambda row: -row["raw_tokens_total"])[:limit],
        "verified_completion_rate": None, "cost_per_verified_objective_usd": None,
        "notes": [
            "Cache rate is token-weighted: read / (uncached input + cache read + cache write), not request hit rate.",
            "Repriced costs use one current flat Standard short-context API table, including separate reasoning tokens. They are not invoices or subscription allowance measurements; long-context and service-tier uplifts are not modelled.",
            "Unknown exact model prices produce null complete estimates; known_repriced_cost_usd is only the priced subtotal. Historical recorded estimates remain untouched.",
            "Retries/escalations describe recorded routing metadata, not unobserved transport attempts. Coverage counts distinguish missing metadata from zero.",
            "Session families use observed parent links, including ancestors outside the time window. Missing links can fragment families. Largest families rank by raw tokens, not price or failure.",
            "Completion and cost per verified objective are unavailable: a finished model response is not acceptance evidence. Join task acceptance before evaluating routing quality.",
        ],
    }


def print_summary(report: dict[str, Any]) -> None:
    print(f"Token efficiency since {report['since']} | pricing {report['pricing_version']}")
    print("Model / effort | Requests | Median / p95 prompt | Reasoning | Cache tokens % | Repriced API-equivalent USD")
    for row in report["models"]:
        price = row["repriced_api_equivalent_usd"]
        display_price = "unavailable" if price is None else f"${price:,.2f}"
        print(f"{row['model']} / {row['variant']} | {row['requests']:,} | {row['median_prompt_tokens']:,.0f} / {row['p95_prompt_tokens']:,} | {row['tokens_reasoning']:,} | {row['cache_token_hit_pct']} | {display_price}")
    print(f"Requests: {report['summary']['requests']:,}; reasoning: {report['summary']['tokens_reasoning']:,}; session families: {report['session_family_count']:,}")
    for note in report["notes"]:
        print(f"- {note}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--since", default="30d", help="window such as 24h, 7d, or 4w")
    parser.add_argument("--limit", type=int, default=10, help="maximum session families included")
    parser.add_argument("--db", type=Path, default=Path(os.environ.get("AIDEVOPS_REPORT_TOKEN_USE_OBS_DB", str(Path.home() / ".aidevops/.agent-workspace/observability/llm-requests.db"))))
    parser.add_argument("--pricing", type=Path, default=Path(__file__).resolve().parent.parent / "configs/model-pricing.json")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    match = re.fullmatch(r"([1-9][0-9]*)([hdw])", args.since)
    if not match or args.limit < 1:
        parser.error("use a positive --since duration and --limit")
    try:
        seconds = int(match[1]) * {"h": 3600, "d": 86400, "w": 604800}[match[2]]
        since = (datetime.now(timezone.utc) - timedelta(seconds=seconds)).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        report = collect_efficiency(args.db, json.loads(args.pricing.read_text(encoding="utf-8")), since, args.limit)
    except (OSError, ValueError, OverflowError, sqlite3.Error) as exc:
        parser.exit(1, f"Efficiency evidence unavailable: {exc}\n")
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0
    print_summary(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
