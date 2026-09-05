#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate a revision-bound approval against fresh metadata supplied on stdin.

This predicate enforces the authorised brief owner's decision; arbitrary prose,
labels and edited comments grant nothing. Event/lease checks are shared pure
predicates in pr_checkpoint_events.
"""

import datetime as dt
import hashlib
import json
import sys

from pr_checkpoint_events import release_for, successors_valid, timestamp, trusted

PREFIX = "CHECKPOINT_CONTINUATION_APPROVED "


def binding(data):
    issue, pr = data["issue"], data["pr"]
    return {"repo": data["repo"], "issue": issue["number"], "pr": pr["number"],
            "head": pr["headRefOid"], "ref": pr["headRefName"],
            "runner": pr["author"]["login"],
            "brief_sha256": hashlib.sha256(issue["body"].encode()).hexdigest()}


def approval_matches(data, approval, comment, now):
    attempt = approval.get("attempt")
    return all((all(approval.get(key) == value for key, value in binding(data).items()),
                0 <= now - timestamp(comment["created_at"]) <= 86400,
                isinstance(attempt, str) and attempt.startswith("attempt:")))


def approved_comment(data, comment, now):
    lines = [line for line in comment["body"].splitlines() if line.startswith(PREFIX)]
    if not trusted(comment) or len(lines) != 1:
        return None
    approval = json.loads(lines[0][len(PREFIX):])
    if not approval_matches(data, approval, comment, now):
        return None
    return approval


def candidate(data, comments, comment, now):
    approval = approved_comment(data, comment, now)
    if approval is None:
        return None
    release = release_for(comments, approval, comment)
    if release is None or not successors_valid(data, comments, release["id"], comment["id"], now):
        return None
    owners = [a["login"] for a in data["issue"].get("assignees", [])]
    allowed_owners = [[data["assignee"]]]
    if not data.get("lease") or data.get("claiming"):
        allowed_owners = [[], [approval["runner"]]]
    if owners not in allowed_owners:
        return None
    return {**approval, "approval_id": comment["id"], "approval_actor": comment["user"]["login"]}


def validate(data):
    comments = data["comments"]
    if comments and isinstance(comments[0], list):
        comments = [c for page in comments for c in page]
    comments = sorted(comments, key=lambda c: (c["created_at"], c["id"]))
    now = data.get("now", dt.datetime.now(dt.timezone.utc).timestamp())
    candidates = [result for c in comments if (result := candidate(data, comments, c, now)) is not None]
    if len(candidates) != 1:
        raise ValueError("missing or ambiguous current revision approval")
    return candidates[0]


if __name__ == "__main__":
    try:
        payload = json.load(sys.stdin)
        if sys.argv[1:] == ["template"]:
            print(PREFIX + json.dumps({**binding(payload), "release_id": payload["release_id"], "attempt": payload["attempt"]}))
        else:
            print(json.dumps(validate(payload)))
    except (ValueError, KeyError, TypeError, OverflowError):
        sys.exit(1)
