#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Regression tests for public email facade exports."""

import importlib
import importlib.util
import re
import sys
import types
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = REPO_ROOT / ".agents" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))
if importlib.util.find_spec("html2text") is None:
    sys.modules["html2text"] = types.ModuleType("html2text")


JMAP_EXPORTS = {
    "INDEX_DIR", "INDEX_DB", "_init_index_db", "_upsert_jmap_email",
    "_first_or_empty", "_get_auth", "_make_auth_header", "_jmap_request",
    "_get_session", "_get_primary_account", "_session_context", "_find_response",
    "_resolve_mailbox_id", "_build_mailbox_path", "_format_email_header",
    "_format_addresses", "HEADER_PROPERTIES", "BODY_PROPERTIES", "KEYWORD_TAXONOMY",
    "cmd_connect", "cmd_fetch_headers", "cmd_fetch_body", "cmd_search",
    "cmd_list_mailboxes", "cmd_create_mailbox", "cmd_move_email", "cmd_set_keyword",
    "cmd_clear_keyword", "SyncContext", "cmd_index_sync", "cmd_push",
}
NORMALISER_EXPORTS = {
    "parse_eml", "parse_msg", "extract_header_safe", "parse_date_safe",
    "normalise_email_sections", "build_thread_map", "reconstruct_thread",
    "generate_thread_index",
}
MARKDOWN_EXPORTS = {
    "parse_eml", "parse_msg", "get_email_body", "extract_attachments",
    "load_dedup_registry", "save_dedup_registry", "get_file_size",
    "extract_header_safe", "parse_date_safe", "compute_content_hash",
    "_parse_email_file", "_extract_headers", "_parse_received_date",
    "normalise_email_sections", "build_thread_map", "reconstruct_thread",
    "generate_thread_index", "build_frontmatter", "format_size", "estimate_tokens",
    "yaml_escape", "generate_summary", "strip_markdown",
}


def load_markdown_facade():
    """Load the hyphenated facade through its supported file path."""
    spec = importlib.util.spec_from_file_location(
        "email_to_markdown_facade", SCRIPTS_DIR / "email-to-markdown.py"
    )
    if not spec or not spec.loader:
        raise RuntimeError("Unable to load email-to-markdown.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class EmailFacadeExportsTests(unittest.TestCase):
    """Protect compatibility facades from accidental export removal."""

    def assert_exports(self, module, expected):
        self.assertEqual(set(module.__all__), expected)
        for name in expected:
            with self.subTest(name=name):
                self.assertTrue(hasattr(module, name))

    def test_jmap_facade_exports_remain_importable(self):
        self.assert_exports(importlib.import_module("email_jmap_adapter"), JMAP_EXPORTS)

    def test_normaliser_facade_exports_remain_importable(self):
        self.assert_exports(importlib.import_module("email_normaliser"), NORMALISER_EXPORTS)

    def test_markdown_facade_exports_remain_importable(self):
        self.assert_exports(load_markdown_facade(), MARKDOWN_EXPORTS)

    def test_dead_standard_library_imports_do_not_return(self):
        normaliser = (SCRIPTS_DIR / "email_normaliser.py").read_text()
        thread = (SCRIPTS_DIR / "email_thread.py").read_text()
        self.assertNotRegex(normaliser, re.compile(r"^import re\\b", re.MULTILINE))
        self.assertNotRegex(thread, re.compile(r"^import os\\b", re.MULTILINE))
        self.assertNotRegex(thread, re.compile(r"^from datetime import\\b", re.MULTILINE))


if __name__ == "__main__":
    unittest.main()
