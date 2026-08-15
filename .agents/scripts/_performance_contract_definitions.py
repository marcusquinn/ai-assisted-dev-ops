#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared definitions for the marketing performance contract."""

from __future__ import annotations

import re

SCHEMA_VERSION = 1
SOURCE_KINDS = {"campaign", "phase1", "social", "analytics", "crm", "commerce", "outreach", "normalized"}
EVENT_TYPES = set("impression engagement follower subscriber social_receipt visit conversion lead_created lead_stage sale revenue refund cost outreach_sent outreach_reply outreach_bounce unsubscribe correction".split())
SUBJECT_KINDS = {"aggregate", "anonymous", "lead", "contact", "account", "audience"}
IDENTITY_STATES = {"not_applicable", "isolated", "linked", "split", "ambiguous"}
UNITS = set("impression engagement follower subscriber receipt visit conversion lead sale refund currency message reply bounce unsubscribe ratio".split())
AGGREGATIONS = {"sum", "average", "latest", "none"}
CONFIDENCE = {"low", "medium", "high", "verified"}
COMPLETENESS = {"complete", "partial", "unknown"}
SOURCE_TYPES = {"manual", "api_export", "csv_export", "derived", "fixture", "agent_estimate", "external_report"}

ALIAS_RE = re.compile(r"^[a-z0-9][a-z0-9._:-]{0,127}$")
METRIC_RE = re.compile(r"^marketing\.[a-z0-9_]+(?:\.[a-z0-9_]+)+$")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
TIMESTAMP_RE = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]{1,6})?Z$"
)
DIMENSION_KEY_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
PUBLIC_DIMENSION_KEYS = frozenset({
    "audience", "case_type", "cohort", "environment", "experiment_variant",
    "priority", "project_phase", "region",
})
RESERVED_DIMENSION_KEYS = frozenset({"channel", "creative_id", "touchpoint_id", "outcome_id", "currency"})
DIRECT_DIMENSION_KEY_RE = re.compile(
    r"(?:^|_)(?:address|credential|destination|email|first_name|full_name|"
    r"last_name|name|password|payload|phone|secret|token)(?:_|$)"
)
DIRECT_DIMENSION_VALUE_RE = re.compile(
    r"(?:[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}|"
    r"https?://|mailto:|tel:|\b[0-9]{10,15}\b|\+[0-9 ()-]{9,})",
    re.IGNORECASE,
)
PHONE_CANDIDATE_RE = re.compile(r"\+?[0-9][0-9 /()._:-]{8,}[0-9]")
VANITY_PHONE_RE = re.compile(
    r"\b(?:1[-. /_:]?)?(?:800|833|844|855|866|877|888)"
    r"[-. /_:]?[a-z0-9]{7,}\b",
    re.IGNORECASE,
)
MAX_SAFE_JSON_INTEGER = 9_007_199_254_740_991

METRIC_DEFINITIONS: dict[str, tuple[str, str, str]] = {
    "marketing.impressions.total": ("Impressions", "count", "Observed content impressions"),
    "marketing.engagement.total": ("Engagements", "count", "Observed engagement actions"),
    "marketing.followers.total": ("Followers", "count", "Observed follower count or change"),
    "marketing.subscribers.total": ("Subscribers", "count", "Observed subscriber count or change"),
    "marketing.social.receipts.succeeded": ("Successful social receipts", "count", "Content-free successful social provider receipts"),
    "marketing.visits.total": ("Visits", "count", "Observed site or campaign visits"),
    "marketing.clicks.total": ("Clicks", "count", "Observed campaign link clicks"),
    "marketing.clicks.rate": ("Click-through rate", "ratio", "Clicks divided by impressions"),
    "marketing.conversions.total": ("Conversions", "count", "Observed conversion outcomes"),
    "marketing.leads.created": ("Leads created", "count", "New source-observed leads"),
    "marketing.leads.qualified": ("Qualified leads", "count", "Leads accepted as qualified"),
    "marketing.sales.total": ("Sales", "count", "Completed sale outcomes"),
    "marketing.refunds.total": ("Refunds", "count", "Completed refund outcomes"),
    "marketing.revenue.gross": ("Gross revenue", "currency", "Gross source-observed revenue"),
    "marketing.revenue.refunded": ("Refunded revenue", "currency", "Source-observed refunded amount"),
    "marketing.cost.amount": ("Marketing cost", "currency", "Source-observed marketing cost"),
    "marketing.return_on_investment.ratio": ("Return on investment", "ratio", "Revenue return relative to cost"),
    "marketing.outreach.sent": ("Outreach sent", "count", "Outreach messages reported sent"),
    "marketing.outreach.replies": ("Outreach replies", "count", "Replies attributed to outreach"),
    "marketing.outreach.bounces": ("Outreach bounces", "count", "Outreach delivery bounces"),
    "marketing.outreach.unsubscribes": ("Outreach unsubscribes", "count", "Outreach unsubscribe outcomes"),
}

METRIC_CONTRACTS: dict[str, tuple[set[str], str, set[str]]] = {
    "marketing.impressions.total": ({"impression"}, "impression", {"sum"}),
    "marketing.engagement.total": ({"engagement"}, "engagement", {"sum"}),
    "marketing.followers.total": ({"follower"}, "follower", {"sum", "latest"}),
    "marketing.subscribers.total": ({"subscriber"}, "subscriber", {"sum", "latest"}),
    "marketing.social.receipts.succeeded": ({"social_receipt"}, "receipt", {"sum"}),
    "marketing.visits.total": ({"visit"}, "visit", {"sum"}),
    "marketing.clicks.total": ({"engagement"}, "engagement", {"sum"}),
    "marketing.clicks.rate": ({"engagement"}, "ratio", {"average", "latest", "none"}),
    "marketing.conversions.total": ({"conversion"}, "conversion", {"sum"}),
    "marketing.leads.created": ({"lead_created"}, "lead", {"sum"}),
    "marketing.leads.qualified": ({"lead_stage"}, "lead", {"sum"}),
    "marketing.sales.total": ({"sale"}, "sale", {"sum"}),
    "marketing.refunds.total": ({"refund"}, "refund", {"sum"}),
    "marketing.revenue.gross": ({"revenue"}, "currency", {"sum"}),
    "marketing.revenue.refunded": ({"refund"}, "currency", {"sum"}),
    "marketing.cost.amount": ({"cost"}, "currency", {"sum"}),
    "marketing.return_on_investment.ratio": ({"conversion", "engagement"}, "ratio", {"average", "latest", "none"}),
    "marketing.outreach.sent": ({"outreach_sent"}, "message", {"sum"}),
    "marketing.outreach.replies": ({"outreach_reply"}, "reply", {"sum"}),
    "marketing.outreach.bounces": ({"outreach_bounce"}, "bounce", {"sum"}),
    "marketing.outreach.unsubscribes": ({"unsubscribe"}, "unsubscribe", {"sum"}),
}


class PerformanceContractError(ValueError):
    """Raised when an ingest contract cannot be normalized safely."""
