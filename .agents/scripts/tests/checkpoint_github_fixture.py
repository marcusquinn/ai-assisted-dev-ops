#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Offline GitHub transport for checkpoint tests; unknown operations fail closed."""

import datetime as dt
import json
import os
import pathlib
import sys


def comment(number, body, author="worker", association="COLLABORATOR"):
    return {"id": number, "body": body, "user": {"login": author},
            "author_association": association, "created_at": "2026-09-05T12:00:00Z"}


def set_issue(args, data):
    issue = data["issue"]
    issue["labels"] = [label for label in issue["labels"] if not label["name"].startswith("status:")]
    issue["labels"].append({"name": "status:" + args[3]})
    owners = {a["login"] for a in issue["assignees"]}
    for index, arg in enumerate(args):
        if arg == "--add-assignee":
            owners.add(args[index + 1])
        elif arg == "--remove-assignee":
            owners.discard(args[index + 1])
    issue["assignees"] = [{"login": owner} for owner in sorted(owners)]


def comments_request(args, data, state):
    if "POST" not in args:
        print(json.dumps([data["comments"]] if "--slurp" in args else data["comments"]))
        return
    body = next(a[5:] for a in args if a.startswith("body="))
    number = max(c["id"] for c in data["comments"]) + 1
    added = comment(number, body, "next-worker")
    added["created_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    data["comments"].append(added)
    state.write_text(json.dumps(data))
    print(number)


def read_response(args, data):
    responses = {
        "api user": "next-worker" if "--jq" in args else json.dumps({"login": "next-worker"}),
        "api repos/owner/repo/collaborators/maintainer/permission": "write",
        "pr view": json.dumps(data["pr"]),
        "issue view": json.dumps({**data["issue"], "state": "OPEN"}),
        "api repos/owner/repo/issues/123": json.dumps(data["issue"]),
    }
    key = " ".join(args[:2])
    if key not in responses:
        raise ValueError("Unexpected mocked GitHub call: " + repr(args))
    print(responses[key])


def main(args):
    state = pathlib.Path(os.environ["CHECKPOINT_TEST_STATE"])
    data = json.loads(state.read_text())
    if args[0] == "--set-issue":
        set_issue(args, data)
        state.write_text(json.dumps(data))
    elif args[0] == "api" and "/comments" in args[1]:
        comments_request(args, data, state)
    else:
        read_response(args, data)


if __name__ == "__main__":
    main(sys.argv[2:] if sys.argv[1] == "--gh" else sys.argv[1:])
