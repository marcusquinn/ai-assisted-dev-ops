#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded durable-progress evidence, independent of queue eligibility."""

import datetime as dt
from dataclasses import dataclass
from typing import Callable


@dataclass(frozen=True)
class ProgressContext:
    slug: str
    run_gh: Callable
    diagnostic: Callable
    persistent_labels: frozenset


def age_at(value, now):
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return max(0, int((now - parsed).total_seconds() // 60))
    except (ValueError, TypeError):
        return None


def linked_prs(slug, timeline):
    if not isinstance(timeline, list) or len(timeline) >= 100:
        return None
    linked = set()
    for event in timeline:
        source = event.get("source", {}).get("issue", {})
        if (event.get("event") == "cross-referenced" and source.get("pull_request")
                and str(source.get("repository_url", "")).endswith(f"/repos/{slug}")):
            linked.add(source.get("number"))
    return linked if len(linked) <= 5 else None


def pr_progress_times(pr):
    times = [pr.get("createdAt", "")]
    times.extend(c.get("committedDate", "") for c in pr.get("commits", []))
    times.extend(c.get("completedAt", "") for c in pr.get("statusCheckRollup", [])
                 if c.get("status") == "COMPLETED")
    return times


def pr_progress_age(slug, number, now, run_gh):
    if not isinstance(number, int) or number <= 0:
        return None
    pr = run_gh(["gh", "pr", "view", str(number), "--repo", slug,
                 "--json", "createdAt,commits,statusCheckRollup"])
    if not isinstance(pr, dict):
        return None
    ages = [age for value in pr_progress_times(pr) if (age := age_at(value, now)) is not None]
    return min(ages) if ages else None


def durable_progress_age(slug, issue, now, run_gh):
    """Creation, linked PR commits and terminal checks, never updatedAt/comments."""
    created_age = age_at(str(issue.get("createdAt") or ""), now)
    if created_age is None or created_age < 60:
        return created_age
    timeline = run_gh(["gh", "api", f"repos/{slug}/issues/{issue['number']}/timeline?per_page=100"])
    linked = linked_prs(slug, timeline)
    if linked is None:
        return None
    ages = [created_age]
    for number in linked:
        age = pr_progress_age(slug, number, now, run_gh)
        if age is None:
            return None
        ages.append(age)
    return min(ages)


def owned_dependency_wait(issue, labels, diagnostic):
    # Only the diagnostic probe receives available status; actual ownership and
    # lifecycle remain untouched. An old owned objective is not a dispatch grant.
    probe = {**issue, "labels": [{"name": label} for label in labels if not label.startswith("status:")]
             + [{"name": "status:available"}]}
    return diagnostic(probe)


def wait_classification(issue, labels, total_age, context):
    explicit_wait = labels & {"no-auto-dispatch", "hold-for-review", "needs-maintainer-review",
                              "needs-maintainer-permissions", "blocked", "status:blocked", "infrastructure"}
    if explicit_wait or issue.get("dependency_inconsistent"):
        return "external_wait_excluded"
    if total_age >= 60 and labels & {"status:in-review", "status:in-progress", "status:queued"}:
        waiting, unknown = owned_dependency_wait(issue, labels, context.diagnostic)
        if unknown:
            return "durable_progress_unknown"
        if waiting:
            return "external_wait_excluded"
    return ""


def record_progress_age(aggregate, total_age, progress_age):
    if progress_age is None:
        aggregate["durable_progress_unknown"] += 1
    else:
        aggregate["oldest_durable_progress_age_min"] = max(
            aggregate["oldest_durable_progress_age_min"], progress_age)
        aggregate["no_durable_progress_hour"] += int(total_age >= 60 and progress_age >= 60)


def count_progress(aggregate, issue, now, context):
    labels = {label.get("name", "") for label in issue.get("labels", []) if isinstance(label, dict)}
    if labels & context.persistent_labels or "parent-task" in labels:
        return
    total_age = age_at(str(issue.get("createdAt") or ""), now)
    if total_age is None:
        return
    aggregate["oldest_issue_age_min"] = max(aggregate["oldest_issue_age_min"], total_age)
    wait_kind = wait_classification(issue, labels, total_age, context)
    if wait_kind:
        aggregate[wait_kind] += 1
        return
    record_progress_age(aggregate, total_age, durable_progress_age(context.slug, issue, now, context.run_gh))
