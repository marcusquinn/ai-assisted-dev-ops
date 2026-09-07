#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Tests for the email-to-Markdown summary transport boundary."""

import sys
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS_DIR = Path(__file__).parent.parent / ".agents" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import email_md_summary  # noqa: E402


class TestOllamaApiUrlValidation(unittest.TestCase):
    """Keep configurable Ollama requests on network URL schemes."""

    def test_accepts_http_and_https_urls_with_authorities(self):
        for url in (
            "http://localhost:11434/api/generate",
            "https://ollama.example.test/api/generate",
        ):
            with self.subTest(url=url), mock.patch.object(
                email_md_summary, "OLLAMA_API_URL", url
            ):
                self.assertEqual(email_md_summary._validated_ollama_api_url(), url)

    def test_rejects_non_network_and_malformed_urls(self):
        for url in (
            "file:///etc/passwd",
            "localhost:11434/api/generate",
            "http:///api/generate",
            "http://[invalid",
        ):
            with self.subTest(url=url), mock.patch.object(
                email_md_summary, "OLLAMA_API_URL", url
            ):
                self.assertIsNone(email_md_summary._validated_ollama_api_url())

    def test_invalid_url_uses_existing_non_fatal_fallback(self):
        with mock.patch.object(
            email_md_summary, "OLLAMA_API_URL", "file:///etc/passwd"
        ):
            with mock.patch.object(email_md_summary.urllib.request, "urlopen") as urlopen:
                self.assertIsNone(
                    email_md_summary._summarise_with_ollama("Body", "Subject")
                )
                urlopen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
