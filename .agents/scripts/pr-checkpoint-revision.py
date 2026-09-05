#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate a revision-bound checkpoint approval; stdin is fresh GitHub metadata.

This is an authorization predicate, not a scope-policy decision engine. The
authorised brief owner publishes CHECKPOINT_CONTINUATION_APPROVED plus a JSON
object on one line. Arbitrary prose, labels and edited comments grant nothing.
"""

import datetime as dt
import hashlib
import json
import re
import sys

TRUSTED = {"OWNER", "MEMBER", "COLLABORATOR"}
PREFIX = "CHECKPOINT_CONTINUATION_APPROVED "
EVENTS = ("DISPATCH_CLAIM ", "DISPATCH_LEASE ", "CLAIM_RELEASED ",
          "Dispatching worker", "Interactive session claimed")


def timestamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def fields(line):
    pairs = re.findall(r"(?:^|\s)([a-z_]+)=([^\s]+)", line)
    parsed = dict(pairs)
    return parsed if len(parsed) == len(pairs) else {}


def trusted(comment):
    return (comment.get("author_association") in TRUSTED
            and bool(comment.get("user", {}).get("login"))
            and comment.get("updated_at", comment.get("created_at")) == comment.get("created_at"))


def binding(data):
    issue, pr = data["issue"], data["pr"]
    return {"repo": data["repo"], "issue": issue["number"], "pr": pr["number"],
            "head": pr["headRefOid"], "ref": pr["headRefName"],
            "runner": pr["author"]["login"],
            "brief_sha256": hashlib.sha256(issue["body"].encode()).hexdigest()}


def events(comments, start, end):
    for comment in comments:
        if not start < comment["id"] < end or comment.get("author_association") not in TRUSTED:
            continue
        for line in comment["body"].splitlines():
            if line.startswith(EVENTS):
                yield comment, line, fields(line)


def original_lease(comments, approval, release, released):
    ready = []
    for comment, line, f in events(comments, -1, release["id"]):
        if not trusted(comment) or comment["user"]["login"] != approval["runner"]:
            continue
        if (line.startswith("DISPATCH_LEASE ") and f.get("attempt_id") == approval["attempt"]
                and f.get("phase") == "ready"):
            ready.append((comment["id"], f))
    tokens = {f.get("lease_token") for _, f in ready}
    if len(tokens) != 1 or not next(iter(tokens)):
        return False
    token = next(iter(tokens))
    if released.get("lease_token", token) != token:
        return False
    # Even a legacy release cannot terminate another attempt that intervened
    # after the approved attempt's ready lease.
    for comment, line, f in events(comments, ready[-1][0], release["id"]):
        if line.startswith("Dispatching worker"):
            f = fields(comment["body"])
        if (not trusted(comment) or comment["user"]["login"] != approval["runner"]
                or f.get("lease_token") != token or line.startswith("DISPATCH_CLAIM ")):
            return False
    return True


def release_for(comments, approval, approval_comment):
    matches = [c for c in comments if c["id"] == approval.get("release_id")]
    if len(matches) != 1 or not trusted(matches[0]):
        return None
    release = matches[0]
    if release["user"]["login"] != approval["runner"] or release["id"] >= approval_comment["id"]:
        return None
    lines = [line for line in release["body"].splitlines() if line.startswith("CLAIM_RELEASED ")]
    if len(lines) != 1:
        return None
    released = fields(lines[0])
    if released.get("reason") != "blocked" or released.get("runner") != approval["runner"]:
        return None
    return release if original_lease(comments, approval, release, released) else None


def own_claim_matches(data, approval_id, comment, line, f):
    return (bool(data.get("lease")) and line.startswith("DISPATCH_CLAIM ")
            and f.get("nonce") == f.get("lease_token") == data["lease"]
            and f.get("checkpoint_approval") == str(approval_id)
            and f.get("session") == data.get("session")
            and f.get("runner") == data.get("assignee") == comment["user"]["login"])


def own_renewal_matches(claim, comment, line, f):
    return (bool(claim) and line.startswith("DISPATCH_LEASE ")
            and f.get("lease_token") == claim.get("lease_token")
            and f.get("session") == claim.get("session")
            and comment["user"]["login"] == claim.get("runner")
            and f.get("phase") in {"prelaunch", "ready"})


def successors_valid(data, comments, release_id, approval_id, now):
    claim = None
    for comment, line, f in events(comments, release_id, float("inf")):
        if not trusted(comment):
            return False
        if claim is None and own_claim_matches(data, approval_id, comment, line, f):
            claim = f
        elif own_renewal_matches(claim, comment, line, f):
            claim = {**claim, **f}
        else:
            return False
    return not data.get("lease") or bool(claim and int(claim.get("expires_at", 0)) > now)


def candidate(data, comments, comment, now):
    lines = [line for line in comment["body"].splitlines() if line.startswith(PREFIX)]
    if not trusted(comment) or len(lines) != 1:
        return None
    approval = json.loads(lines[0][len(PREFIX):])
    if any(approval.get(key) != value for key, value in binding(data).items()):
        return None
    if not 0 <= now - timestamp(comment["created_at"]) <= 86400:
        return None
    if not isinstance(approval.get("attempt"), str) or not approval["attempt"].startswith("attempt:"):
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
