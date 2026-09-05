#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Pure authenticated coordination-event predicates for checkpoint recovery."""

import datetime as dt
import re

TRUSTED = {"OWNER", "MEMBER", "COLLABORATOR"}
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


def events(comments, start, end):
    for comment in comments:
        if not start < comment["id"] < end or comment.get("author_association") not in TRUSTED:
            continue
        for line in comment["body"].splitlines():
            if line.startswith(EVENTS):
                yield comment, line, fields(line)


def ready_leases(comments, approval, release):
    ready = []
    for comment, line, f in events(comments, -1, release["id"]):
        if not trusted(comment) or comment["user"]["login"] != approval["runner"]:
            continue
        if (line.startswith("DISPATCH_LEASE ") and f.get("attempt_id") == approval["attempt"]
                and f.get("phase") == "ready"):
            ready.append((comment["id"], f))
    return ready


def original_lease(comments, approval, release, released):
    ready = ready_leases(comments, approval, release)
    tokens = {f.get("lease_token") for _, f in ready}
    if len(tokens) != 1 or not next(iter(tokens)):
        return False
    token = next(iter(tokens))
    if released.get("lease_token", token) != token:
        return False
    between = events(comments, ready[-1][0], release["id"])
    return intervening_events_valid(between, approval["runner"], token)


def intervening_events_valid(between, runner, token):
    # Even a legacy release cannot terminate another attempt that intervened
    # after the approved attempt's ready lease.
    for comment, line, f in between:
        if line.startswith("Dispatching worker"):
            f = fields(comment["body"])
        if (not trusted(comment) or comment["user"]["login"] != runner
                or f.get("lease_token") != token or line.startswith("DISPATCH_CLAIM ")):
            return False
    return True


def blocked_release_fields(release, runner):
    lines = [line for line in release["body"].splitlines() if line.startswith("CLAIM_RELEASED ")]
    if len(lines) != 1:
        return None
    released = fields(lines[0])
    if released.get("reason") != "blocked" or released.get("runner") != runner:
        return None
    return released


def release_for(comments, approval, approval_comment):
    matches = [c for c in comments if c["id"] == approval.get("release_id")]
    if len(matches) != 1:
        return None
    release = matches[0]
    identity_valid = all((trusted(release), release["user"]["login"] == approval["runner"],
                          release["id"] < approval_comment["id"]))
    released = blocked_release_fields(release, approval["runner"])
    if not identity_valid or released is None:
        return None
    return release if original_lease(comments, approval, release, released) else None


def own_claim_matches(data, approval_id, comment, line, f):
    expected = {"nonce": data.get("lease"), "lease_token": data.get("lease"),
                "checkpoint_approval": str(approval_id), "session": data.get("session"),
                "runner": data.get("assignee")}
    return all((bool(data.get("lease")), line.startswith("DISPATCH_CLAIM "),
                all(f.get(key) == value for key, value in expected.items()),
                data.get("assignee") == comment["user"]["login"]))


def own_renewal_matches(claim, comment, line, f):
    if not claim:
        return False
    return all((line.startswith("DISPATCH_LEASE "),
                f.get("lease_token") == claim.get("lease_token"),
                f.get("session") == claim.get("session"),
                comment["user"]["login"] == claim.get("runner"),
                f.get("phase") in {"prelaunch", "ready"}))


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
