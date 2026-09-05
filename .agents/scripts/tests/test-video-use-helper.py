# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Offline boundary checks; the helper's smoke-test exercises real rendering."""

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "video_use", Path(__file__).resolve().parents[1] / "video-use-helper.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SHA = "a" * 40


class VideoUseTests(unittest.TestCase):
    def test_reviewed_pin_is_immutable(self):
        config = MODULE.configuration()
        self.assertRegex(config["reviewed_commit"], r"^[0-9a-f]{40}$")
        self.assertIn("helpers/render.py", config["required_files"])
        self.assertIn("skills/manim-video/SKILL.md", config["required_files"])

    def test_missing_subtitles_filter_fails_readiness(self):
        with (
            patch.object(MODULE.shutil, "which", return_value="ffmpeg"),
            patch.object(
                MODULE, "command", return_value=" T.. overlay VV->V\n T.. afade A->A"
            ),
            self.assertRaisesRegex(RuntimeError, "subtitles"),
        ):
            MODULE.verify_ffmpeg()

    def test_complete_filter_build_passes(self):
        filters = "\n".join(
            f" T.. {name} V->V"
            for name in (
                "subtitles",
                "overlay",
                "afade",
                "loudnorm",
                "zscale",
                "tonemap",
            )
        )
        with (
            patch.object(MODULE.shutil, "which", return_value="ffmpeg"),
            patch.object(MODULE, "command", return_value=filters),
        ):
            MODULE.verify_ffmpeg()

    def test_transcription_is_not_exposed(self):
        with patch.object(MODULE, "verify_runtime") as verify:
            with self.assertRaisesRegex(ValueError, "approval"):
                MODULE.run_helper({}, Path("unused"), "transcribe", [])
            verify.assert_not_called()

    def test_existing_invalid_install_is_preserved(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(MODULE, "verify_runtime", side_effect=RuntimeError("dirty")),
            patch.object(MODULE, "command") as command,
        ):
            with self.assertRaisesRegex(RuntimeError, "dirty"):
                MODULE.install({}, Path(directory))
            command.assert_not_called()
            self.assertTrue(Path(directory).is_dir())

    def test_wrong_installed_commit_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / ".git").mkdir()
            with (
                patch.object(MODULE, "command", return_value="b" * 40),
                self.assertRaisesRegex(RuntimeError, "reviewed commit"),
            ):
                MODULE.verify_source(path, {"reviewed_commit": SHA})

    def test_helper_only_upstream_changes_are_reported_without_install(self):
        config = {"reviewed_commit": SHA, "github_repository": "browser-use/video-use"}
        output = io.StringIO()
        with (
            patch.object(MODULE, "verify_runtime"),
            patch.object(MODULE, "command", return_value="b" * 40) as command,
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(MODULE.status(config, Path("unused"), upstream=True), 0)
        self.assertTrue(json.loads(output.getvalue())["update_available"])
        self.assertEqual(command.call_count, 1)
        self.assertIn(
            "repos/browser-use/video-use/commits/HEAD", command.call_args.args[0]
        )

    def test_smoke_refuses_existing_output(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(MODULE, "verify_runtime"),
            patch.object(MODULE, "command") as command,
        ):
            with self.assertRaises(FileExistsError):
                MODULE.smoke_test({}, Path("/unused"), Path(directory))
            command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
