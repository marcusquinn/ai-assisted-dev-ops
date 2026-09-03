#!/usr/bin/env python3
"""Unit and drift tests for the capability readiness contract."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TEST_DIR = Path(__file__).resolve().parent
HELPER = TEST_DIR.parent / "capability-readiness-helper.py"
FIXTURE = TEST_DIR / "fixtures" / "capability-readiness-states.json"


class CapabilityReadinessTests(unittest.TestCase):
    def run_helper(
        self, *args: str, expected: int = 0, fixture: Path = FIXTURE
    ) -> dict:
        result = subprocess.run(
            [sys.executable, str(HELPER), "--fixture", str(fixture), *args],
            text=True,
            capture_output=True,
            check=False,
        )  # nosec B603
        self.assertEqual(expected, result.returncode, result.stderr or result.stdout)
        return json.loads(result.stdout) if result.stdout else {}

    def test_registry_has_no_drift(self) -> None:
        result = subprocess.run(
            [sys.executable, str(HELPER), "check"],
            text=True,
            capture_output=True,
            check=False,
        )  # nosec B603
        self.assertEqual(0, result.returncode, result.stdout)
        self.assertTrue(json.loads(result.stdout)["valid"])

    def test_healthy_capability_routes(self) -> None:
        output = self.run_helper("route", "code", "--runtime", "opencode")
        self.assertEqual("route", output["decision"])
        self.assertEqual("Build+", output["owner"])

    def test_unavailable_credentials_fall_back(self) -> None:
        output = self.run_helper("route", "github", "--runtime", "opencode", expected=3)
        self.assertEqual("fallback", output["decision"])
        self.assertIn("authenticated", output["coverage_impact"])

    def test_unreachable_service_falls_back(self) -> None:
        output = self.run_helper("route", "seo-data", "--runtime", "opencode", expected=3)
        self.assertIn("reachable", output["coverage_impact"])

    def test_missing_permission_falls_back(self) -> None:
        output = self.run_helper("route", "cloudflare", "--runtime", "opencode", expected=3)
        self.assertIn("authorized", output["coverage_impact"])

    def test_hidden_tool_falls_back(self) -> None:
        output = self.run_helper("route", "browser", "--runtime", "opencode", expected=3)
        self.assertIn("tool_visible", output["coverage_impact"])

    def test_provider_neutral_accounting_routes_without_a_provider(self) -> None:
        output = self.run_helper("route", "accounting", "--runtime", "opencode")
        self.assertEqual("route", output["decision"])
        self.assertEqual("Business", output["owner"])

    def test_ready_quickfile_accounting_routes(self) -> None:
        output = self.run_helper("route", "quickfile", "--runtime", "opencode")
        self.assertEqual("route", output["decision"])
        self.assertEqual("Business", output["owner"])

    def test_quickfile_authentication_uncertainty_falls_back(self) -> None:
        fixture = json.loads(FIXTURE.read_text())
        fixture["capabilities"]["quickfile-accounting"]["authenticated"] = "unknown"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "states.json"
            path.write_text(json.dumps(fixture))
            output = self.run_helper(
                "route", "quickfile", "--runtime", "opencode", expected=3, fixture=path
            )
        self.assertEqual("accounting-export-workpaper", output["fallback"])
        self.assertIn("authenticated", output["coverage_impact"])

    def test_home_path_probe_accepts_an_alternative_install(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            legacy_entrypoint = home / "Git" / "quickfile-mcp" / "dist" / "index.js"
            legacy_entrypoint.parent.mkdir(parents=True)
            legacy_entrypoint.write_text("")
            registry_path = home / "registry.json"
            registry_path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "dimensions": [
                            "catalogued",
                            "installed",
                            "runtime_compatible",
                        ],
                        "capabilities": [
                            {
                                "name": "alternative-home-path",
                                "aliases": ["alternative"],
                                "owner": "Business",
                                "runtimes": ["opencode"],
                                "entry_points": [],
                                "fallback": "manual",
                                "required": ["installed", "runtime_compatible"],
                                "probes": {
                                    "installed": {
                                        "path_home_any": [
                                            "Git/mcp/quickfile-mcp/dist/index.js",
                                            "Git/quickfile-mcp/dist/index.js",
                                        ]
                                    }
                                },
                            }
                        ],
                    }
                )
            )
            environment = dict(os.environ)
            environment["HOME"] = str(home)
            result = subprocess.run(
                [
                    sys.executable,
                    str(HELPER),
                    "--registry",
                    str(registry_path),
                    "route",
                    "alternative",
                    "--runtime",
                    "opencode",
                ],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )  # nosec B603
        self.assertEqual(0, result.returncode, result.stderr or result.stdout)
        self.assertEqual("route", json.loads(result.stdout)["decision"])

    def test_environment_pattern_probe_matches_a_profile_secret(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry_path = Path(directory) / "registry.json"
            registry_path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "dimensions": [
                            "catalogued",
                            "configured",
                            "runtime_compatible",
                        ],
                        "capabilities": [
                            {
                                "name": "profile-secret",
                                "aliases": ["profile"],
                                "owner": "Business",
                                "runtimes": ["opencode"],
                                "entry_points": [],
                                "fallback": "manual",
                                "required": ["configured", "runtime_compatible"],
                                "probes": {
                                    "configured": {
                                        "env_pattern": "SERVICE_<PROFILE>_TOKEN"
                                    }
                                },
                            }
                        ],
                    }
                )
            )
            environment = dict(os.environ)
            environment["SERVICE_BUSINESS_TOKEN"] = directory
            result = subprocess.run(
                [
                    sys.executable,
                    str(HELPER),
                    "--registry",
                    str(registry_path),
                    "route",
                    "profile",
                    "--runtime",
                    "opencode",
                ],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )  # nosec B603
        self.assertEqual(0, result.returncode, result.stderr or result.stdout)
        self.assertEqual("route", json.loads(result.stdout)["decision"])

    def test_generated_index_is_stable(self) -> None:
        committed = HELPER.parents[1] / "reference" / "capability-registry.md"
        with tempfile.TemporaryDirectory() as directory:
            generated = Path(directory) / "index.md"
            subprocess.run(
                [
                    sys.executable,
                    str(HELPER),
                    "generate",
                    "--output",
                    str(generated),
                ],
                check=True,
            )  # nosec B603
            self.assertEqual(committed.read_text(), generated.read_text())


if __name__ == "__main__":
    unittest.main()
