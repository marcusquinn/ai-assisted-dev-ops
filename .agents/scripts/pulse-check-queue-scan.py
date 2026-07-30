#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Privacy-preserving repos.json auto-dispatch queue scanner."""

from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
from typing import Any, Optional

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import pulse_check_dependencies as dependency_scan

AGGREGATE_KEY = "aggregate"
ERROR_KEY = "error"
GH_ERRORS_KEY = "gh_errors"
NATIVE_ABSENT = dependency_scan.NATIVE_ABSENT
NATIVE_CLEAR = dependency_scan.NATIVE_CLEAR
NATIVE_UNKNOWN = dependency_scan.NATIVE_UNKNOWN
NATIVE_UNRESOLVED = dependency_scan.NATIVE_UNRESOLVED
REPO_SLUG_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
BLOCKING_LABELS = frozenset({
    "parent-task",
    "needs-maintainer-review",
    "needs-maintainer-permissions",
    "no-auto-dispatch",
    "infrastructure",
    "hold-for-review",
    "blocked",
    "status:blocked",
    "status:in-review",
})
def _int_from_env(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, str(default)))
    except ValueError:
        return default


def _empty_aggregate() -> dict[str, int]:
    return {
        "repos": 0,
        "auto_dispatch_open": 0,
        "available_unassigned": 0,
        "available_old": 0,
        "oldest_available_age_min": 0,
        "repos_with_available": 0,
        "queued": 0,
        "assigned": 0,
        "blocked_labels": 0,
        "dependency_inconsistent_available": 0,
        "needs_tier": 0,
        "needs_status": 0,
        "parent_task": 0,
        "nmr": 0,
        "no_auto_dispatch": 0,
        "infrastructure": 0,
        GH_ERRORS_KEY: 0,
    }


def _emit(aggregate: dict[str, int], error: str = "", scanned_at: str = "") -> None:
    payload: dict[str, Any] = {AGGREGATE_KEY: aggregate}
    if error:
        payload[ERROR_KEY] = error
    if scanned_at:
        payload["scanned_at"] = scanned_at
    print(json.dumps(payload))


def _issue_labels(issue: dict[str, Any]) -> set[str]:
    labels = issue.get("labels", [])
    if not isinstance(labels, list):
        return set()
    return {str(label.get("name") or "") for label in labels if isinstance(label, dict)}


def _valid_repo_slug(slug: str) -> bool:
    return bool(REPO_SLUG_RE.fullmatch(slug))


def _issue_age_minutes(issue: dict[str, Any], now: dt.datetime) -> int:
    updated_at = str(issue.get("updatedAt") or "")
    try:
        updated = dt.datetime.fromisoformat(updated_at.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return 0
    return int((now - updated).total_seconds() // 60)


def _load_repos(repos_json: pathlib.Path) -> tuple[list[dict[str, Any]], str]:
    try:
        data = json.loads(repos_json.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [], f"repos_json_unreadable:{exc.__class__.__name__}"
    if not isinstance(data, dict):
        return [], "repos_json_unreadable:TypeError"
    initialized = data.get("initialized_repos", [])
    if not isinstance(initialized, list):
        return [], ""
    repos = []
    for repo in initialized:
        if not isinstance(repo, dict):
            continue
        if (
            repo.get("maintenance", True) is not False
            and repo.get("pulse") is True
            and not repo.get("local_only")
            and repo.get("slug")
        ):
            repos.append(repo)
    return repos, ""


def _fetch_repo_issues(slug: str, max_issues: int) -> Optional[list[dict[str, Any]]]:
    issues: Optional[list[dict[str, Any]]] = None
    cmd = [
        "gh", "issue", "list",
        "--repo", slug,
        "--state", "open",
        "--label", "auto-dispatch",
        "--limit", str(max_issues),
        "--json", "number,title,body,labels,assignees,updatedAt",
    ]
    if _valid_repo_slug(slug):
        try:
            # Fixed argv, shell=False, validated owner/repo slug.
            completed = subprocess.run(  # nosec B603
                cmd,
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            completed = None
        if completed is not None and completed.returncode == 0:
            try:
                parsed = json.loads(completed.stdout or "[]")
            except json.JSONDecodeError:
                parsed = None
            if isinstance(parsed, list):
                issues = [issue for issue in parsed if isinstance(issue, dict)]
    return issues


_run_gh_json = dependency_scan._run_gh_json
_native_dependency_state = dependency_scan._native_dependency_state


def _dependency_diagnostic(slug: str, issue: dict[str, Any]) -> tuple[bool, bool]:
    # Preserve the scanner's monkeypatch seam used by focused diagnostics tests.
    dependency_scan._run_gh_json = _run_gh_json
    dependency_scan._native_dependency_state = _native_dependency_state
    return dependency_scan.dependency_diagnostic(slug, issue)


def _dependency_inconsistent(slug: str, issue: dict[str, Any]) -> bool:
    inconsistent, _ = _dependency_diagnostic(slug, issue)
    return inconsistent


def _count_issue(
    aggregate: dict[str, int],
    issue: dict[str, Any],
    now: dt.datetime,
    old_minutes: int,
) -> bool:
    labels = _issue_labels(issue)
    assigned = bool(issue.get("assignees"))
    blocked = bool(labels & BLOCKING_LABELS)
    dependency_inconsistent = bool(issue.get("dependency_inconsistent"))
    aggregate["auto_dispatch_open"] += 1
    aggregate["assigned"] += int(assigned)
    aggregate["queued"] += int("status:queued" in labels)
    aggregate["needs_tier"] += int(not any(label.startswith("tier:") for label in labels))
    aggregate["needs_status"] += int(not any(label.startswith("status:") for label in labels))
    aggregate["blocked_labels"] += int(blocked)
    aggregate["dependency_inconsistent_available"] += int(dependency_inconsistent)
    aggregate["parent_task"] += int("parent-task" in labels)
    aggregate["nmr"] += int("needs-maintainer-review" in labels)
    aggregate["no_auto_dispatch"] += int("no-auto-dispatch" in labels)
    aggregate["infrastructure"] += int("infrastructure" in labels)
    available = "status:available" in labels and not assigned and not blocked and not dependency_inconsistent
    if available:
        aggregate["available_unassigned"] += 1
        age_min = _issue_age_minutes(issue, now)
        aggregate["available_old"] += int(age_min >= old_minutes)
        aggregate["oldest_available_age_min"] = max(aggregate["oldest_available_age_min"], age_min)
    return available


def _scan_repo(
    aggregate: dict[str, int],
    repo: dict[str, Any],
    max_issues: int,
    now: dt.datetime,
    old_minutes: int,
) -> None:
    slug = str(repo.get("slug") or "")
    issues = _fetch_repo_issues(slug, max_issues)
    if issues is None:
        aggregate[GH_ERRORS_KEY] += 1
        return
    for issue in issues:
        inconsistent, scan_error = _dependency_diagnostic(slug, issue)
        issue["dependency_inconsistent"] = inconsistent
        aggregate[GH_ERRORS_KEY] += int(scan_error)
    repo_available = sum(int(_count_issue(aggregate, issue, now, old_minutes)) for issue in issues)
    aggregate["repos_with_available"] += int(repo_available > 0)


def main() -> int:
    repos_json = pathlib.Path(os.environ.get("PULSE_CHECK_REPOS_JSON", ""))
    skip_gh = os.environ.get("PULSE_CHECK_SKIP_GH", "") in {"1", "true", "TRUE", "yes", "YES"}
    max_issues = _int_from_env("PULSE_CHECK_MAX_ISSUES_PER_REPO", 100)
    old_minutes = _int_from_env("PULSE_CHECK_OLD_AVAILABLE_MINUTES", 30)
    aggregate = _empty_aggregate()

    repos, load_error = _load_repos(repos_json)
    if load_error:
        _emit(aggregate, load_error)
        return 0
    aggregate["repos"] = len(repos)
    if skip_gh:
        _emit(aggregate, "api_cooldown_active")
        return 0
    if shutil.which("gh") is None:
        _emit(aggregate, "gh_missing")
        return 0

    now = dt.datetime.now(dt.timezone.utc)
    for repo in repos:
        _scan_repo(aggregate, repo, max_issues, now, old_minutes)

    _emit(aggregate, scanned_at=now.isoformat())
    return 0


if __name__ == "__main__":
    sys.exit(main())
