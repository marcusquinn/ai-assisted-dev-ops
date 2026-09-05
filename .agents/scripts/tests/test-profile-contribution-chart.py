#!/usr/bin/env python3
"""Focused standard-library checks for the contribution chart boundary.

SPDX-License-Identifier: MIT
SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""

import datetime as dt
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

SPEC = importlib.util.spec_from_file_location("chart", Path(__file__).parents[1] / "profile-contribution-chart.py")
chart = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(chart)
TODAY = dt.date(2026, 9, 5)


def client(query, login):
    if "createdAt" in query:
        return {"login": login, "createdAt": "2026-07-17T00:00:00Z"}
    return {"login": login, **{
        alias: {"contributionCalendar": {"totalContributions": 21}, "totalCommitContributions": 999}
        for alias in re.findall(r"(m\d+):contributionsCollection", query)
    }}


class ChartTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.readme = self.repo / "README.md"
        self.readme.write_text("# Profile\n\nManual content.\n")

    def refresh(self, **kwargs):
        return chart.refresh(self.repo, self.readme, "fixture", today=TODAY, client=client, **kwargs)

    def snapshot(self):
        return {str(path.relative_to(self.repo)): path.read_bytes() for path in self.repo.rglob("*") if path.is_file()}

    def test_disjoint_month_boundaries_and_current_day_exclusion(self):
        windows = list(chart.monthly_windows(dt.date(2024, 2, 20), dt.date(2024, 3, 2)))
        self.assertEqual(windows, [
            ("2024-02", "2024-02-01T00:00:00Z", "2024-02-29T23:59:59Z"),
            ("2024-03", "2024-03-01T00:00:00Z", "2024-03-01T23:59:59Z"),
        ])
        self.assertEqual(len(list(chart.monthly_windows(dt.date(2024, 2, 20), dt.date(2024, 3, 1)))), 1)

    def test_canonical_total_is_used_without_summing_private_buckets(self):
        data = chart.fetch_history("fixture", TODAY, client)
        self.assertEqual(data["total"], 63)
        self.assertEqual([row["cumulative"] for row in data["months"]], [21, 42, 63])
        self.assertEqual(data["through"], "2026-09-04")
        self.assertEqual(set(data["months"][0]), {"month", "total", "cumulative"})

    def test_history_is_batched_into_at_most_twelve_months(self):
        calls = []

        def long_history(query, login):
            if "createdAt" in query:
                return {"login": login, "createdAt": "2024-01-17T00:00:00Z"}
            calls.append(query)
            return client(query, login)

        data = chart.fetch_history("fixture", TODAY, long_history)
        self.assertEqual(len(data["months"]), 33)
        self.assertEqual(len(calls), 3)
        self.assertTrue(all(query.count("contributionsCollection") <= 12 for query in calls))

    def test_daily_refresh_is_idempotent_and_skips_remote_calls(self):
        self.assertTrue(self.refresh())
        before = self.snapshot()
        with patch.object(chart, "fetch_history", side_effect=AssertionError("unexpected remote fetch")):
            self.assertFalse(self.refresh())
        self.assertEqual(before, self.snapshot())

    def test_next_day_api_failure_preserves_all_existing_files(self):
        self.refresh()
        before = self.snapshot()
        with patch.object(chart, "fetch_history", side_effect=chart.FetchError("failure")):
            self.assertFalse(chart.refresh(self.repo, self.readme, "fixture", today=TODAY + dt.timedelta(days=1)))
        self.assertEqual(before, self.snapshot())

    def test_incomplete_or_invalid_months_never_replace_last_good(self):
        self.refresh()
        before = self.snapshot()
        for bad in (None, {}, {"contributionCalendar": {"totalContributions": True}}, {"contributionCalendar": {"totalContributions": -1}}):
            def invalid(query, login):
                value = client(query, login)
                if "m0:" in query:
                    value["m0"] = bad
                return value

            chart.refresh(self.repo, self.readme, "fixture", today=TODAY + dt.timedelta(days=1), client=invalid)
            self.assertEqual(before, self.snapshot())

    def test_dry_run_leaves_readme_and_assets_unchanged(self):
        before = self.snapshot()
        self.assertTrue(self.refresh(dry_run=True))
        self.assertEqual(before, self.snapshot())

    def test_svg_themes_are_well_formed_and_script_free(self):
        data = chart.fetch_history("fixture", TODAY, client)
        for dark in (False, True):
            svg = chart.render_svg(data, dark)
            root = ET.fromstring(svg)
            self.assertEqual(root.attrib["viewBox"], "0 0 960 420")
            self.assertIn("63 cumulative", svg)
            self.assertIn("#0d1117" if dark else "#ffffff", svg)
            self.assertNotIn("<script", svg)
            self.assertNotIn("<image", svg)

    def test_legacy_linked_chart_is_migrated_once(self):
        old = '# Heading\n<div align="center">\n<a href="https://commit-history.com/fixture?metric=total">\n<picture><img src="https://commit-history.com/embed/fixture" /></picture>\n</a>\n</div>\nManual suffix\n'
        migrated = chart.migrate_readme(old, "fixture")
        self.assertEqual(migrated, chart.migrate_readme(migrated, "fixture"))
        self.assertEqual(migrated.count(chart.START), 1)
        self.assertIn('target="_blank" rel="noopener noreferrer"', migrated)
        self.assertIn('https://commit-history.com/fixture?metric=total', migrated)
        self.assertIn("Manual suffix", migrated)
        self.assertNotIn("commit-history.com/embed/", migrated)

    def test_bad_markers_abort_before_asset_writes(self):
        self.readme.write_text(chart.START + "\n" + chart.START)
        before = self.snapshot()
        with self.assertRaises(ValueError):
            self.refresh()
        self.assertEqual(before, self.snapshot())

    def test_symlinked_asset_destination_is_rejected(self):
        (self.repo / "outside").mkdir()
        (self.repo / "assets").symlink_to(self.repo / "outside", target_is_directory=True)
        with self.assertRaises(ValueError):
            self.refresh()

    def test_cached_markup_is_not_trusted(self):
        self.refresh()
        path = self.repo / chart.ASSET_DIR / "total.json"
        data = json.loads(path.read_text())
        data["months"][0]["month"] = '</text><script>alert(1)</script>'
        self.assertFalse(chart.valid_history(data, "fixture", TODAY))
        path.write_text(json.dumps(data))
        self.refresh()
        self.assertNotIn("<script", (path.parent / "total-light.svg").read_text())


if __name__ == "__main__":
    unittest.main()
