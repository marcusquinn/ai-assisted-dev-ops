#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Protected, bounded integration-recovery requests. Records never grant authority.

The runtime supplies verified identity/state separately from final assistant text.
Pulse owns queued requests; decisions are evidence and wake conditions, not scope
approvals. Existing signed brief, lease and checkpoint guards remain authoritative.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sqlite3
import sys
import time

MARKER = "INTEGRATION_RECOVERY_REQUEST="
REASONS = {"adjacent_integration", "hard_boundary", "concurrent_owner", "missing_context", "human_decision"}
WAKES = {"brief_revision", "owner_change", "dependency_change", "human_decision"}
REQUEST_FIELDS = {"schema", "issue", "pr", "reason", "files", "evidence", "verification"}
NOT_TEXT = object()


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:24]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def event_text(line):
    try:
        event = json.loads(line)
        if event.get("type") != "text":
            return NOT_TEXT
        part = event.get("part", {})
        text = event.get("text") or part.get("text")
    except (AttributeError, ValueError):
        return NOT_TEXT
    return text if isinstance(text, str) else NOT_TEXT


def bounded_string(value, minimum, maximum, message):
    require(isinstance(value, str), message)
    require(len(value) in range(minimum, maximum + 1), message)


def validate_path(path):
    bounded_string(path, 1, 500, "invalid path")
    parts = PurePosixPath(path)
    require(not parts.is_absolute(), "paths must be exact repository-relative paths")
    require(".." not in parts.parts, "paths must be exact repository-relative paths")
    require(not re.search(r"[\s*?\[\]\\]", path), "paths must be exact repository-relative paths")


def validate_request(request):
    require(isinstance(request, dict), "invalid recovery schema")
    require(set(request) == REQUEST_FIELDS, "invalid recovery schema")
    require(request["schema"] == 1, "invalid recovery schema")
    require(request["reason"] in REASONS, "invalid reason")
    for key, minimum in (("issue", 1), ("pr", 0)):
        require(type(request[key]) is int, "invalid target")
        require(request[key] >= minimum, "invalid target")
    files = request["files"]
    require(isinstance(files, list), "invalid proposed paths")
    require(len(files) <= 20, "invalid proposed paths")
    for path in files:
        validate_path(path)
    bounded_string(request["evidence"], 1, 8000, "missing bounded evidence")
    verification = request["verification"]
    require(isinstance(verification, list), "missing verification")
    require(len(verification) in range(1, 21), "missing verification")
    for item in verification:
        bounded_string(item, 1, 1000, "invalid verification")


def final_request(raw):
    """Accept only a final normalized assistant text event, never tool text."""
    texts = [text for line in raw.splitlines() if (text := event_text(line)) is not NOT_TEXT]
    require(texts, "no final assistant recovery request")
    require(re.search(r"^BLOCKED:", texts[-1], re.M), "no final assistant recovery request")
    matches = [line.removeprefix(MARKER) for line in texts[-1].splitlines() if line.startswith(MARKER)]
    require(len(matches) == 1, "expected exactly one final request")
    request = json.loads(matches[0])
    validate_request(request)
    request["files"] = sorted(set(request["files"]))
    return request


def connect(root):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if root.is_symlink() or root.stat().st_uid != os.getuid() or root.stat().st_mode & 0o077:
        raise ValueError("recovery directory is not private and owned")
    path = root / "requests.sqlite3"
    if path.is_symlink():
        raise ValueError("invalid recovery database")
    old_mask = os.umask(0o077)
    try:
        db = sqlite3.connect(path, timeout=10)
    finally:
        os.umask(old_mask)
    os.chmod(path, 0o600)
    db.execute("CREATE TABLE IF NOT EXISTS requests (id TEXT PRIMARY KEY, record TEXT NOT NULL, decision TEXT, observed TEXT, status TEXT NOT NULL DEFAULT 'active', checked_at INTEGER NOT NULL DEFAULT 0)")
    db.execute("CREATE TABLE IF NOT EXISTS decisions (request_id TEXT, observation TEXT, decision TEXT NOT NULL, PRIMARY KEY(request_id, observation))")
    db.execute("CREATE TABLE IF NOT EXISTS local_attempts (repo TEXT, issue INTEGER, revision TEXT, PRIMARY KEY(repo, issue, revision))")
    # Preserve queues written by an earlier runtime bundle. Serialize inspection
    # and additive migration so concurrent intake processes cannot race ALTER.
    with db:
        db.execute("BEGIN IMMEDIATE")
        columns = {row[1] for row in db.execute("PRAGMA table_info(requests)")}
        for name, definition in (("observed", "TEXT"), ("status", "TEXT NOT NULL DEFAULT 'active'"),
                                 ("checked_at", "INTEGER NOT NULL DEFAULT 0")):
            if name not in columns:
                db.execute(f"ALTER TABLE requests ADD COLUMN {name} {definition}")
    return db


def has_explicit_boundary(body):
    # Conservative denial only, never an authority parser. Unrecognised language
    # still receives the independent semantic boundary check in the continuation.
    body = re.sub(r"(?im)^.*hard boundaries:\*?\*?\s*none[^\n]*$", "", body)
    return bool(re.search(r"hard boundar|only (?:these|the following|listed) files|"
                          r"(?:do not|must not|never) (?:modify|edit|change)|"
                          r"(?:file.count cap|explicit exclusions?:)", body, re.I))


def capture(db, envelope, request):
    if request["issue"] != envelope["issue"] or request["pr"] != envelope["pr"]:
        raise ValueError("request target differs from verified runtime target")
    # Head/attempt changes alone never re-arm an unchanged rejected brief.
    revision = digest({"title": envelope["brief"]["title"], "body": envelope["brief"]["body"]})
    identity = {"repo": envelope["repo"], "issue": envelope["issue"], "pr": envelope["pr"],
                "revision": revision, "files": request["files"]}
    request_id = digest(identity)
    record = dict(envelope, request=request, id=request_id, brief_revision=revision,
                  owner="pulse", next_action="assess_protected_integration_request",
                  wake="next_pulse", created_at=int(time.time()))
    # Brief bodies and lease tokens do not need retention in the queue.
    del record["brief"]
    with db:
        inserted = db.execute("INSERT OR IGNORE INTO requests(id,record) VALUES (?,?)",
                              (request_id, json.dumps(record))).rowcount == 1
        budget = db.execute("INSERT OR IGNORE INTO local_attempts VALUES (?,?,?)",
                            (envelope["repo"], envelope["issue"], revision)).rowcount == 1
    may_reassess = inserted and budget and request["reason"] == "adjacent_integration"
    may_reassess = may_reassess and not has_explicit_boundary(envelope["brief"]["body"])
    return {"id": request_id, "action": "continue" if may_reassess else "coordinator"}


def show(db, request_id):
    row = db.execute("SELECT record,decision,observed FROM requests WHERE id=?", (request_id,)).fetchone()
    if row is None:
        raise ValueError("unknown request")
    record, decision, observed = row
    return dict(json.loads(record), decision=json.loads(decision) if decision else None,
                observed=json.loads(observed) if observed else None)


def observe(db, request_id, state):
    record = show(db, request_id)
    brief = state["issue"]
    if brief["number"] != record["issue"] or brief["state"] not in {"open", "closed"}:
        raise ValueError("observation target mismatch")
    observed = {
        "brief_revision": digest({"title": brief["title"], "body": brief["body"]}),
        "owner_change": digest([brief["assignees"], brief["labels"], state["comments"]]),
        "dependency_change": digest(state["dependencies"]),
        "human_decision": digest([brief["body"], state["comments"]]),
    }
    with db:
        db.execute("UPDATE requests SET observed=?,status=? WHERE id=?",
                   (json.dumps(observed), "resolved" if brief["state"] == "closed" else "active", request_id))
    if brief["state"] == "closed":
        return None
    decision = record["decision"]
    if decision and decision["observed"][decision["wake"]] == observed[decision["wake"]]:
        return None
    return dict(record, observed=observed)


def decide(db, request_id, decision):
    if set(decision) != {"wake", "next_action", "evidence", "actor"} or decision["wake"] not in WAKES:
        raise ValueError("decision must retain an owner, next action and specific wake condition")
    if any(not isinstance(value, str) or not 1 <= len(value) <= 8000 for value in decision.values()):
        raise ValueError("invalid decision evidence")
    record = show(db, request_id)
    if not record["observed"]:
        raise ValueError("fresh coordinator observation required")
    decision = dict(decision, observed=record["observed"])
    observation = digest(record["observed"])
    with db:
        db.execute("INSERT INTO decisions VALUES (?,?,?)", (request_id, observation, json.dumps(decision)))
        db.execute("UPDATE requests SET decision=? WHERE id=?", (json.dumps(decision), request_id))
    return {"id": request_id, "owner": "pulse", "wake": decision["wake"]}


def pending(db):
    # Rotate bounded intake even when old holds or unavailable APIs persist.
    # A stuck request must not starve the twenty-first executable objective.
    with db:
        rows = db.execute("SELECT id FROM requests WHERE status='active' ORDER BY checked_at,rowid LIMIT 20").fetchall()
        for row in rows:
            db.execute("UPDATE requests SET checked_at=? WHERE id=?", (time.time_ns(), row[0]))
    return [show(db, row[0]) for row in rows]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("extract", "capture", "pending", "decision", "show", "observe"))
    parser.add_argument("--output")
    parser.add_argument("--root", type=Path, default=Path.home() / ".aidevops/.agent-workspace/integration-recovery")
    parser.add_argument("--id")
    args = parser.parse_args()
    if args.action == "extract":
        print(json.dumps(final_request(Path(args.output).read_text(errors="replace"))))
        return
    with connect(args.root) as db:
        if args.action == "capture":
            payload = json.load(sys.stdin)
            print(json.dumps(capture(db, payload["envelope"], payload["request"])))
        elif args.action == "pending":
            print(json.dumps(pending(db)))
        elif args.action == "show":
            print(json.dumps(show(db, args.id)))
        elif args.action == "observe":
            print(json.dumps(observe(db, args.id, json.load(sys.stdin))))
        else:
            print(json.dumps(decide(db, args.id, json.load(sys.stdin))))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, sqlite3.Error, KeyError, TypeError) as error:
        print(f"integration recovery: {error}", file=sys.stderr)
        sys.exit(1)
