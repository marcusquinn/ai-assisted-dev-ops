#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Parse final assistant recovery evidence without interpreting it as authority."""

import json
from pathlib import PurePosixPath
import re

MARKER = "INTEGRATION_RECOVERY_REQUEST="
REASONS = {"adjacent_integration", "hard_boundary", "concurrent_owner", "missing_context", "human_decision"}
REQUEST_FIELDS = {"schema", "issue", "pr", "reason", "files", "evidence", "verification"}


def _assistant_texts(raw):
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
    return texts


def _validate_schema(request):
    if not isinstance(request, dict) or set(request) != REQUEST_FIELDS or request["schema"] != 1:
        raise ValueError("invalid recovery schema")
    if request["reason"] not in REASONS:
        raise ValueError("invalid reason")
    for key, minimum in (("issue", 1), ("pr", 0)):
        if type(request[key]) is not int or request[key] < minimum:
            raise ValueError("invalid target")


def _validate_paths(files):
    if not isinstance(files, list) or len(files) > 20:
        raise ValueError("invalid proposed paths")
    for path in files:
        if not isinstance(path, str) or not path or len(path) > 500:
            raise ValueError("invalid path")
        if PurePosixPath(path).is_absolute() or ".." in PurePosixPath(path).parts or re.search(r"[\s*?\[\]\\]", path):
            raise ValueError("paths must be exact repository-relative paths")


def _validate_evidence(request):
    evidence = request["evidence"]
    verification = request["verification"]
    if not isinstance(evidence, str) or not 1 <= len(evidence) <= 8000:
        raise ValueError("missing bounded evidence")
    if not isinstance(verification, list) or not 1 <= len(verification) <= 20:
        raise ValueError("missing verification")
    if any(not isinstance(item, str) or not 1 <= len(item) <= 1000 for item in verification):
        raise ValueError("invalid verification")


def final_request(raw):
    """Accept only a final normalized assistant text event, never tool text."""
    texts = _assistant_texts(raw)
    if not texts or not re.search(r"^BLOCKED:", texts[-1], re.M):
        raise ValueError("no final assistant recovery request")
    matches = [line[len(MARKER):] for line in texts[-1].splitlines() if line.startswith(MARKER)]
    if len(matches) != 1:
        raise ValueError("expected exactly one final request")
    request = json.loads(matches[0])
    _validate_schema(request)
    _validate_paths(request["files"])
    _validate_evidence(request)
    request["files"] = sorted(set(request["files"]))
    return request
