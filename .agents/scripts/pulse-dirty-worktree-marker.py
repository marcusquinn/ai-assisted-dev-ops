#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Evaluate dirty-worktree marker state from a GitHub comments JSON stream."""

from __future__ import annotations

import datetime
import json
import math
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
        timestamp = datetime.datetime.fromisoformat(
            str(value).replace("Z", "+00:00")
        )
        if timestamp.tzinfo is None or timestamp.utcoffset() is None:
            return None
        return timestamp.timestamp()
    except ValueError:
        return None


def load_comments() -> list[dict[str, object]]:
    value = json.load(sys.stdin)
    if not isinstance(value, list):
        raise ValueError("comments must be an array")
    # Native --paginate --slurp produces an array of pages. Legacy callers may
    # still pass a flat page; both require complete, well-formed comment objects.
    if value and all(isinstance(page, list) for page in value):
        value = [comment for page in value for comment in page]
    if not all(isinstance(comment, dict) and "body" in comment
               and (comment["body"] is None or isinstance(comment["body"], str))
               for comment in value):
        raise ValueError("incomplete comments")
    return value


def resolve_now(now_override: str) -> float:
    if not now_override:
        return datetime.datetime.now(datetime.timezone.utc).timestamp()

    value = float(now_override)
    if not math.isfinite(value) or value < 0:
        raise ValueError("invalid observation clock")
    return value


def latest_marker_state(
    comments: list[dict[str, object]],
) -> tuple[float | None, float | None, str]:
    latest_marker_ts = None
    latest_resolution_ts = None
    latest_marker_body = ""

    for comment in comments:
        body = str(comment.get("body") or "")
        created = parse_timestamp(comment.get("created_at") or comment.get("createdAt"))
        if created is None:
            raise ValueError("missing comment timestamp")
        if any(token in body for token in RESOLUTION_TOKENS):
            if latest_resolution_ts is None or created > latest_resolution_ts:
                latest_resolution_ts = created
        elif "WORKER_DIRTY_WORKTREE" in body:
            if latest_marker_ts is None or created > latest_marker_ts:
                latest_marker_ts = created
                latest_marker_body = body
            elif created == latest_marker_ts and body != latest_marker_body:
                # Ambiguous same-second ownership cannot grant runner resume.
                latest_marker_body = ""
    return latest_marker_ts, latest_resolution_ts, latest_marker_body


def extract_runner_key(marker_body: str) -> str:
    for token in marker_body.split():
        if token.startswith("runner_key="):
            return token.split("=", 1)[1]
    return ""


def main() -> int:
    try:
        since_mode = len(sys.argv) > 1 and sys.argv[1] == "--since"
        offset = 2 if since_mode else 1
        hold_seconds = int(sys.argv[offset])
        if hold_seconds < 0:
            raise ValueError("negative hold")
        now_override = sys.argv[offset + 1] if len(sys.argv) > offset + 1 else ""
        now_epoch = resolve_now(now_override)
        if since_mode:
            # Include the integer-age boundary and GitHub's exclusive `since`.
            cutoff = datetime.datetime.fromtimestamp(
                now_epoch - hold_seconds - 1, datetime.timezone.utc
            )
            print(cutoff.strftime("%Y-%m-%dT%H:%M:%SZ"))
            return 0
        latest_marker_ts, latest_resolution_ts, latest_marker_body = latest_marker_state(
            load_comments()
        )
    except (ValueError, TypeError, IndexError, OverflowError, UnicodeDecodeError):
        print("unknown")
        return 1

    if latest_marker_ts is None or (
        # Equal timestamps do not prove that resolution happened after failure.
        latest_resolution_ts is not None and latest_resolution_ts > latest_marker_ts
    ):
        print(CLEAR_STATE)
        return 0

    age = max(0, int(now_epoch - latest_marker_ts))
    runner_key = extract_runner_key(latest_marker_body)
    state = "block" if age <= hold_seconds else "expired"
    print(f"{state}:age={age}:runner_key={runner_key}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
