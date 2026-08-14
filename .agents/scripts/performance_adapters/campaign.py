"""Campaign JSON envelope and legacy results.md adapter."""

from __future__ import annotations

import datetime as dt
import re
from typing import Any

from performance_adapters.base import envelope

METRICS = {
    "impressions": ("marketing.reach.impressions", "Impressions", "count", "impression"),
    "clicks": ("marketing.engagement.clicks", "Clicks", "count", "click"),
    "ctr (%)": ("marketing.engagement.ctr", "Click-through rate", "percentage", "percent"),
    "conversions": ("marketing.conversions.total", "Conversions", "count", "conversion"),
    "cost": ("marketing.spend.cost", "Cost", "currency", "currency"),
    "revenue / value": ("marketing.revenue.gross", "Revenue", "currency", "currency"),
    "roi": ("marketing.revenue.roi", "Return on investment", "ratio", "ratio"),
}


def _markdown(text: str, account: str, evidence_ref: str | None) -> dict[str, Any]:
    now = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    launched = re.search(r"\*\*Launched:\*\*\s*([^\n]+)", text)
    occurred = f"{launched.group(1).strip()}T00:00:00Z" if launched else now
    events = []
    for line in text.splitlines():
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) != 2 or cells[0].lower() not in METRICS or not cells[1]:
            continue
        raw = re.sub(r"[^0-9.\-]", "", cells[1])
        if not raw:
            continue
        metric_id, label, kind, unit = METRICS[cells[0].lower()]
        value = float(raw)
        if kind == "percentage":
            value /= 100
        currency = None
        if kind == "currency":
            match = re.search(r"\b[A-Z]{3}\b", cells[1])
            currency = match.group(0) if match else None
        events.append({
            "source_event_id": f"{account}:{metric_id}:{occurred}", "event_type": "cost" if metric_id == "marketing.spend.cost" else "outcome",
            "metric": {"id": metric_id, "label": label, "kind": kind, "version": 1},
            "measurement": {"value": value, "unit": unit, "currency": currency, "aggregation": "sum", "period_start": None, "period_end": None},
            "occurred_at": occurred, "dimensions": {"campaign_id": account},
            "quality": {"confidence": "medium", "freshness": "unknown", "verification_status": "unverified", "notes": "Imported from legacy campaign results.md"},
        })
    return {"source": {"provider": "campaign-manual", "account_id": account, "captured_at": now, "cursor": f"legacy:{account}", "coverage": 1.0, "scope_status": "complete", "evidence_ref": evidence_ref or "results.md"}, "subjects": [], "events": events}


def normalize(document: Any, *, source_account: str | None = None, evidence_ref: str | None = None) -> dict[str, Any]:
    account = source_account or "campaign"
    if isinstance(document, str):
        document = _markdown(document, account, evidence_ref)
    return envelope(document, "campaign", source_account=account, evidence_ref=evidence_ref)
