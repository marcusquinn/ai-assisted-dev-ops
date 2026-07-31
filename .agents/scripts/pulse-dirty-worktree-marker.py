#!/usr/bin/env python3
"""Evaluate dirty-worktree marker state from a GitHub comments JSON stream."""

from __future__ import annotations

import datetime
import json
import sys


CLEAR_STATE = "clear"
RESOLUTION_TOKENS = (
    "worker-dirty-worktree:resolved",
    "WORKER_DIRTY_WORKTREE_RESOLVED",
    "DIRTY_WORKTREE_RECOVERED",
    "worker_dirty_worktree_recovered",
)


def parse_timestamp(value: object) -> float | None:
    if not value:
        return None
    try:
        return datetime.datetime.fromisoformat(
            str(value).replace("Z", "+00:00")
        ).timestamp()
    except ValueError:
        return None


def main() -> int:
    hold_seconds = int(sys.argv[1])
    now_override = sys.argv[2] if len(sys.argv) > 2 else ""
    try:
        comments = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        print(CLEAR_STATE)
        return 0

    try:
        now_epoch = (
            float(now_override)
            if now_override
            else datetime.datetime.now(datetime.timezone.utc).timestamp()
        )
    except ValueError:
        now_epoch = datetime.datetime.now(datetime.timezone.utc).timestamp()

    latest_marker_ts = None
    latest_resolution_ts = None
    latest_marker_body = ""
    for comment in comments:
        body = str(comment.get("body") or "")
        created = parse_timestamp(comment.get("created_at") or comment.get("createdAt"))
        if created is None:
            continue
        if any(token in body for token in RESOLUTION_TOKENS):
            latest_resolution_ts = created
        elif "WORKER_DIRTY_WORKTREE" in body:
            latest_marker_ts = created
            latest_marker_body = body

    if latest_marker_ts is None or (
        latest_resolution_ts is not None and latest_resolution_ts >= latest_marker_ts
    ):
        print(CLEAR_STATE)
        return 0

    age = max(0, int(now_epoch - latest_marker_ts))
    runner_key = ""
    for token in latest_marker_body.split():
        if token.startswith("runner_key="):
            runner_key = token.split("=", 1)[1]
            break
    state = "block" if age <= hold_seconds else "expired"
    print(f"{state}:age={age}:runner_key={runner_key}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
