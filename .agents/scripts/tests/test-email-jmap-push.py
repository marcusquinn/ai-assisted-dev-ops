#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Regression tests for JMAP EventSource URL validation and SSE parsing."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parents[1]
HELPER_PATH = SCRIPTS_DIR / "email_jmap_push.py"
sys.path.insert(0, str(SCRIPTS_DIR))
SPEC = importlib.util.spec_from_file_location("email_jmap_push", HELPER_PATH)
if not SPEC or not SPEC.loader:
    raise RuntimeError(f"Unable to load {HELPER_PATH}")
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


class EventSourceUrlTests(unittest.TestCase):
    """Lock in the local guard for CodeFactor's dynamic URL finding."""

    def test_accepts_absolute_http_endpoints(self) -> None:
        """Permit only absolute HTTP(S) EventSource URLs."""
        for url in ("https://mail.example/events", "http://localhost/events"):
            with self.subTest(url=url):
                self.assertEqual(HELPER._validate_event_source_url(url), url)

    def test_rejects_non_http_or_relative_endpoints(self) -> None:
        """Reject schemes that urllib must never open for JMAP push."""
        for url in ("file:///etc/passwd", "ftp://mail.example/events", "/events", "https:///events"):
            with self.subTest(url=url):
                with self.assertRaisesRegex(ValueError, "must use HTTP"):
                    HELPER._validate_event_source_url(url)

    def test_sse_parser_emits_structured_event(self) -> None:
        """Keep parsing outside the stream loop to bound its complexity."""
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            HELPER._emit_sse_event("state", '{"changed": true}')
        event = json.loads(output.getvalue())
        self.assertEqual(event["event_type"], "state")
        self.assertEqual(event["data"], {"changed": True})


if __name__ == "__main__":
    unittest.main()
