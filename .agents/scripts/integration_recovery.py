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


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:24]


def final_request(raw):
    """Accept only a final normalized assistant text event, never tool text."""
    texts = []
    for line in raw.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict) or event.get("type") != "text":
            continue
        part = event.get("part", {})
        text = event.get("text") or (part.get("text") if isinstance(part, dict) else None)
        if isinstance(text, str):
            texts.append(text)
    if not texts or not re.search(r"^BLOCKED:", texts[-1], re.M):
        raise ValueError("no final assistant recovery request")
    matches = [line[len(MARKER):] for line in texts[-1].splitlines() if line.startswith(MARKER)]
    if len(matches) != 1:
        raise ValueError("expected exactly one final request")
    request = json.loads(matches[0])
    expected = {"schema", "issue", "pr", "reason", "files", "evidence", "verification"}
    if not isinstance(request, dict) or set(request) != expected or request["schema"] != 1:
        raise ValueError("invalid recovery schema")
    if request["reason"] not in REASONS:
        raise ValueError("invalid reason")
    for key in ("issue", "pr"):
        if type(request[key]) is not int or request[key] < (1 if key == "issue" else 0):
            raise ValueError("invalid target")
    files = request["files"]
    if not isinstance(files, list) or len(files) > 20:
        raise ValueError("invalid proposed paths")
    for path in files:
        if not isinstance(path, str) or not path or len(path) > 500:
            raise ValueError("invalid path")
        if PurePosixPath(path).is_absolute() or ".." in PurePosixPath(path).parts or re.search(r"[\s*?\[\]\\]", path):
            raise ValueError("paths must be exact repository-relative paths")
    evidence = request["evidence"]
    verification = request["verification"]
    if not isinstance(evidence, str) or not 1 <= len(evidence) <= 8000:
        raise ValueError("missing bounded evidence")
    if not isinstance(verification, list) or not 1 <= len(verification) <= 20:
        raise ValueError("missing verification")
    if any(not isinstance(item, str) or not 1 <= len(item) <= 1000 for item in verification):
        raise ValueError("invalid verification")
    request["files"] = sorted(set(files))
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
