#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Tests for tabby-profile-sync.py compatibility and helpers.

t2250: covers the two root causes behind duplicate Tabby profiles
(``>-`` folded YAML scalars missed by the dedup regex) and worktree
leakage (the string-heuristic failing on names with dots like
``wpallstars.com-chore-aidevops-init``).
"""

import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

SCRIPTS_DIR = Path(__file__).parent.parent / ".agents" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

spec = importlib.util.spec_from_file_location(
    "tabby_profile_sync", SCRIPTS_DIR / "tabby-profile-sync.py"
)
tabby_profile_sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tabby_profile_sync)

# Re-import helpers directly so tests exercise the same module the script uses.
from tabby_yaml_helpers import extract_existing_cwds  # noqa: E402
from tabby_shell_resolver import ShellResolutionError, resolve_login_shell  # noqa: E402


class TestTabbyProfileSync(unittest.TestCase):
    """Test Python 3.9-safe imports and helpers."""

    def test_module_imports_under_current_python(self):
        self.assertTrue(callable(tabby_profile_sync.extract_group_id))

    def test_extract_group_id_returns_projects_group(self):
        config_text = """groups:
  - id: abc-123
    name: Projects
  - id: def-456
    name: Other
profiles:
  - name: repo
"""

        self.assertEqual(tabby_profile_sync.extract_group_id(config_text), "abc-123")


class TestExtractExistingCwds(unittest.TestCase):
    """Regression tests for YAML scalar parsing (t2250 root cause A).

    Before the fix the dedup regex matched only single-line ``cwd: value``
    assignments. Tabby's GUI reformats long paths as folded block scalars
    on every save, causing the dedup check to miss the path and generate a
    duplicate profile on every sync.
    """

    def test_inline_plain_scalar(self):
        cwds = extract_existing_cwds(
            """profiles:
  - name: foo
    options:
      cwd: /Users/alice/repo
"""
        )
        self.assertIn("/Users/alice/repo", cwds)

    def test_inline_single_quoted_scalar(self):
        cwds = extract_existing_cwds(
            """profiles:
  - name: foo
    options:
      cwd: '/Users/alice/repo'
"""
        )
        self.assertIn("/Users/alice/repo", cwds)

    def test_inline_double_quoted_scalar(self):
        cwds = extract_existing_cwds(
            """profiles:
  - name: foo
    options:
      cwd: "/Users/alice/repo"
"""
        )
        self.assertIn("/Users/alice/repo", cwds)

    def test_folded_block_scalar(self):
        """Tabby's GUI-saved form — the exact shape that caused duplicates."""
        cwds = extract_existing_cwds(
            """profiles:
  - name: foo
    options:
      cwd: >-
        /Users/marcusquinn/Git/wordpress/wp-plugin-starter-template-for-ai-coding
    color: '#DA5CD3'
"""
        )
        self.assertIn(
            "/Users/marcusquinn/Git/wordpress/wp-plugin-starter-template-for-ai-coding",
            cwds,
        )
        self.assertNotIn(">-", cwds)

    def test_literal_block_scalar(self):
        cwds = extract_existing_cwds(
            """profiles:
  - name: foo
    options:
      cwd: |-
        /Users/alice/nested/project
"""
        )
        self.assertIn("/Users/alice/nested/project", cwds)
        self.assertNotIn("|-", cwds)

    def test_mixed_forms_in_one_config(self):
        """All three forms in one file are extracted correctly."""
        cwds = extract_existing_cwds(
            """profiles:
  - name: a
    options:
      cwd: /path/a
  - name: b
    options:
      cwd: '/path/b'
  - name: c
    options:
      cwd: >-
        /path/c
  - name: d
    options:
      cwd: |-
        /path/d
"""
        )
        self.assertEqual(
            cwds, {"/path/a", "/path/b", "/path/c", "/path/d"}
        )

    def test_empty_config_returns_empty_set(self):
        self.assertEqual(extract_existing_cwds(""), set())

    def test_config_without_profiles_returns_empty_set(self):
        self.assertEqual(extract_existing_cwds("version: 1\nhotkeys: {}\n"), set())


class TestIsLinkedWorktree(unittest.TestCase):
    """Deterministic worktree detection (t2250 root cause B).

    Replaces the old string-heuristic that tried to guess worktrees from
    basename patterns like ``repo.branch-name``. That heuristic broke for:

    - repo names containing a dot (``wpallstars.com``, ``example.io``)
    - worktrees whose branch prefix is not in the hard-coded list
      (``feature-``, ``bugfix-``, ``hotfix-``, ``refactor-``,
      ``chore-``, ``experiment-``)
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name).resolve()

    def _git(self, *args, cwd=None):
        subprocess.run(
            ["git", *args],
            cwd=cwd,
            check=True,
            capture_output=True,
        )

    def test_main_worktree_is_not_linked(self):
        repo = self.tmp / "repo"
        repo.mkdir()
        self._git("init", "-q", cwd=repo)
        self._git("commit", "--allow-empty", "-q", "-m", "init", cwd=repo)
        self.assertFalse(tabby_profile_sync.is_linked_worktree(str(repo)))

    def test_non_git_path_is_not_linked(self):
        plain = self.tmp / "plain"
        plain.mkdir()
        self.assertFalse(tabby_profile_sync.is_linked_worktree(str(plain)))

    def test_nonexistent_path_is_not_linked(self):
        self.assertFalse(
            tabby_profile_sync.is_linked_worktree(str(self.tmp / "missing"))
        )

    def test_linked_worktree_is_detected(self):
        """The critical case: a linked worktree must return True."""
        repo = self.tmp / "repo"
        repo.mkdir()
        self._git("init", "-q", "-b", "main", cwd=repo)
        self._git("commit", "--allow-empty", "-q", "-m", "init", cwd=repo)
        wt = self.tmp / "repo-feature"
        self._git(
            "worktree", "add", "-q", str(wt), "-b", "feature/x", cwd=repo
        )
        self.assertTrue(tabby_profile_sync.is_linked_worktree(str(wt)))
        # Main remains not-linked.
        self.assertFalse(tabby_profile_sync.is_linked_worktree(str(repo)))

    def test_worktree_with_dot_in_repo_name_is_detected(self):
        """The original bug: worktrees of repos with TLD-style names.

        ``wpallstars.com`` worktree named ``wpallstars.com-chore-aidevops-init``
        was not caught by the old heuristic because splitting on the first
        dot yielded ``com-chore-aidevops-init``, which does not start with
        any of the hard-coded branch prefixes.
        """
        repo = self.tmp / "wpallstars.com"
        repo.mkdir()
        self._git("init", "-q", "-b", "main", cwd=repo)
        self._git("commit", "--allow-empty", "-q", "-m", "init", cwd=repo)
        wt = self.tmp / "wpallstars.com-chore-aidevops-init"
        self._git(
            "worktree", "add", "-q",
            str(wt), "-b", "chore/aidevops-init",
            cwd=repo,
        )
        self.assertTrue(tabby_profile_sync.is_linked_worktree(str(wt)))


class TestGetReposExcludesWorktrees(unittest.TestCase):
    """End-to-end: repos.json entries for worktrees do not reach the sync."""

    def test_worktree_entry_is_filtered(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name).resolve()

        repo = root / "demo.com"
        repo.mkdir()
        subprocess.run(
            ["git", "init", "-q", "-b", "main"], cwd=repo, check=True
        )
        subprocess.run(
            ["git", "commit", "--allow-empty", "-q", "-m", "init"],
            cwd=repo, check=True,
        )
        wt = root / "demo.com-chore-task"
        subprocess.run(
            ["git", "worktree", "add", "-q", str(wt), "-b", "chore/task"],
            cwd=repo, check=True,
        )

        repos_json = root / "repos.json"
        repos_json.write_text(
            '{{"initialized_repos":[{{"path":"{main}"}},{{"path":"{wt}"}}]}}'.format(
                main=str(repo), wt=str(wt)
            )
        )
        result = tabby_profile_sync.get_repos(str(repos_json))
        paths = [r["path"] for r in result]
        self.assertIn(str(repo), paths)
        self.assertNotIn(str(wt), paths)


class TestGetProfileTargets(unittest.TestCase):
    """Detected workspaces augment, but do not pollute, repos.json targets."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name).resolve()
        self.repos_json = self.root / "repos.json"
        self.repos_json.write_text('{"initialized_repos": []}')

    def test_existing_buzz_workspace_is_included(self):
        buzz_path = self.root / ".buzz"
        buzz_path.mkdir()

        targets = tabby_profile_sync.get_profile_targets(
            str(self.repos_json), home=str(self.root)
        )

        self.assertEqual(
            targets,
            [
                {
                    "path": str(buzz_path),
                    "name": "Buzz",
                    "repo": {
                        "path": str(buzz_path),
                        "profile_kind": "buzz-workspace",
                    },
                }
            ],
        )

    def test_missing_buzz_workspace_is_not_included(self):
        targets = tabby_profile_sync.get_profile_targets(
            str(self.repos_json), home=str(self.root)
        )

        self.assertEqual(targets, [])

    def test_buzz_target_builds_opencode_profile_at_workspace(self):
        buzz_path = self.root / ".buzz"
        buzz_path.mkdir()
        targets = tabby_profile_sync.get_profile_targets(
            str(self.repos_json), home=str(self.root)
        )

        profiles = tabby_profile_sync.build_new_profiles(
            targets, existing_cwds=set(), group_id="group-1"
        )

        self.assertEqual(len(profiles), 1)
        profile = profiles[0][1]
        self.assertIn("  - name: Buzz", profile)
        self.assertIn(f"      cwd: {buzz_path}", profile)
        self.assertIn("        - 'exec aidevops opencode --tabby-shell'", profile)

    def test_registered_buzz_path_is_not_duplicated(self):
        buzz_path = self.root / ".buzz"
        buzz_path.mkdir()
        self.repos_json.write_text(
            '{{"initialized_repos": [{{"path": "{}"}}]}}'.format(buzz_path)
        )

        targets = tabby_profile_sync.get_profile_targets(
            str(self.repos_json), home=str(self.root)
        )

        self.assertEqual([target["path"] for target in targets], [str(buzz_path)])


class TestRepairBrokenOpenCodeLaunchProfiles(unittest.TestCase):
    """Regression coverage for Tabby OpenCode repair edge cases."""

    def test_generated_profile_quotes_opencode_command_arg(self):
        profile = tabby_profile_sync.build_profile_yaml(
            name="repo",
            cwd="/Users/alice/repo",
            appearance=tabby_profile_sync.ProfileAppearance(
                "#DA5CD3",
                {
                    "name": "test",
                    "foreground": "#ffffff",
                    "background": "#000000",
                    "cursor": "#ffffff",
                    "colors": ["#000000"],
                },
            ),
            group_id="group-1",
        )

        self.assertIn("        - 'exec aidevops opencode --tabby-shell'", profile)
        self.assertNotIn("        - exec aidevops opencode --tabby-shell", profile)
        self.assertIn("    disableDynamicTitle: false", profile)

    def test_generated_profile_uses_supplied_resolved_shell(self):
        profile = tabby_profile_sync.build_profile_yaml(
            name="repo",
            cwd="/srv/repo",
            appearance=tabby_profile_sync.ProfileAppearance(
                "#DA5CD3",
                {
                    "name": "test",
                    "foreground": "#ffffff",
                    "background": "#000000",
                    "cursor": "#ffffff",
                    "colors": ["#000000"],
                },
            ),
            group_id="group-1",
            shell_path="/bin/bash",
        )

        self.assertIn("      command: /bin/bash", profile)

    def test_missing_managed_shell_is_repaired(self):
        original = """profiles:
  - name: repo
    options:
      command: /missing/zsh
      args:
        - '-l'
        - '-c'
        - 'exec aidevops opencode --tabby-shell'
"""

        repaired, repairs = tabby_profile_sync.repair_broken_opencode_launch_profiles(
            original, shell_path="/bin/bash"
        )

        self.assertEqual(repairs, 1)
        self.assertIn("      command: /bin/bash", repaired)
        self.assertNotIn("/missing/zsh", repaired)

    def test_existing_opencode_profile_enables_dynamic_title(self):
        repaired, repairs = tabby_profile_sync.repair_broken_opencode_launch_profiles(
            """profiles:
  - name: repo
    options:
      command: /bin/zsh
      args:
        - '-l'
        - '-c'
        - 'aidevops opencode; exec zsh'
    disableDynamicTitle: true
    type: local
"""
        )

        self.assertEqual(repairs, 1)
        self.assertIn("        - 'exec aidevops opencode --tabby-shell'", repaired)
        self.assertIn("    disableDynamicTitle: false", repaired)
        self.assertNotIn("    disableDynamicTitle: true", repaired)

    def test_multiple_fixes_count_one_repaired_profile(self):
        repaired, repairs = tabby_profile_sync.repair_broken_opencode_launch_profiles(
            """profiles:
  - name: repo
    options:
      command: /bin/zsh -l -c 'opencode; exec zsh'
      args: []
      command: /bin/zsh -l -c 'opencode; exec zsh'
"""
        )

        self.assertEqual(repairs, 1)
        self.assertEqual(repaired.count("      command: /bin/zsh"), 1)
        self.assertIn("    disableDynamicTitle: false", repaired)

    def test_unrelated_profile_preserves_dynamic_title_setting(self):
        original = """profiles:
  - name: shell
    options:
      command: /bin/zsh
    disableDynamicTitle: true
    type: local
"""
        repaired, repairs = tabby_profile_sync.repair_broken_opencode_launch_profiles(original)

        self.assertEqual(repairs, 0)
        self.assertEqual(repaired, original)

    def test_command_field_with_trailing_comment_is_repaired(self):
        repaired, repairs = tabby_profile_sync.repair_broken_opencode_launch_profiles(
            """profiles:
  - name: repo
    options:
      command: /bin/zsh -l -c 'opencode; exec zsh' # legacy Tabby shape
      args: []
"""
        )

        self.assertEqual(repairs, 1)
        self.assertIn("      command: /bin/zsh", repaired)
        self.assertIn("        - 'exec aidevops opencode --tabby-shell'", repaired)

    def test_inline_args_blank_line_before_env_does_not_duplicate_env(self):
        repaired, repairs = tabby_profile_sync.repair_broken_opencode_launch_profiles(
            """profiles:
  - name: repo
    options:
      command: /bin/zsh -l -c 'opencode; exec zsh'
      args: []

      env: {}
"""
        )

        self.assertEqual(repairs, 1)
        self.assertEqual(repaired.count("      env:"), 1)
        self.assertIn("        - 'exec aidevops opencode --tabby-shell'", repaired)

    def test_block_args_comment_before_env_does_not_duplicate_env(self):
        repaired, repairs = tabby_profile_sync.repair_broken_opencode_launch_profiles(
            """profiles:
  - name: repo
    options:
      command: /bin/zsh -l -c 'opencode; exec zsh'
      args:
        - '-l'
        - '-c'
        - 'opencode; exec zsh'
      # keep existing env block
      env: {}
"""
        )

        self.assertEqual(repairs, 1)
        self.assertEqual(repaired.count("      env:"), 1)
        self.assertIn("      # keep existing env block", repaired)

    def test_last_opencode_profile_does_not_swallow_top_level_sections(self):
        original = """profiles:
  - name: repo
    options:
      command: /bin/zsh -l -c 'opencode; exec zsh'
      args: []
terminal:
  searchOptions:
    # opencode in a top-level section must not make it profile repair input
    regex: opencode
"""

        repaired, repairs = tabby_profile_sync.repair_broken_opencode_launch_profiles(
            original
        )

        self.assertEqual(repairs, 1)
        self.assertIn("terminal:\n", repaired)
        self.assertIn("    regex: opencode", repaired)
        self.assertTrue(repaired.endswith("    regex: opencode\n"))


class TestProfileArgTypeValidation(unittest.TestCase):
    """Regression coverage for shell operators saved as YAML mappings."""

    @staticmethod
    def _profile_config(args: str, command: str = "/bin/zsh") -> str:
        """Build a minimal Tabby profile with the supplied argument lines."""
        return (
            "profiles:\n"
            "  - name: site.local\n"
            "    options:\n"
            f"      command: {command}\n"
            "      args:\n"
            f"{args}"
        )

    def _assert_arg_issues(
        self, args: str, expected_values: list[str], command: str = "open"
    ) -> None:
        """Assert that argument lines are reported as non-string values."""
        config = self._profile_config(args, command)
        issues = tabby_profile_sync.find_profile_arg_type_issues(config)

        self.assertEqual(
            [issue.profile_name for issue in issues],
            ["site.local"] * len(expected_values),
        )
        self.assertEqual([issue.value for issue in issues], expected_values)

    def test_shell_quote_operator_mapping_is_rejected(self):
        self._assert_arg_issues(
            """        - '-a'
        - OrbStack
        - op: '&&'
        - until
        - docker
        - info
        - op: '>'
        - /dev/null
""",
            ["op: '&&'", "op: '>'"],
        )

    def test_quoted_shell_command_is_valid_string_arg(self):
        config = self._profile_config(
            """        - '-l'
        - '-c'
        - >-
          open -a OrbStack && until docker info >/dev/null 2>&1; do sleep 1;
          done && pnpm dev:web
"""
        )

        self.assertEqual(
            tabby_profile_sync.find_profile_arg_type_issues(config),
            [],
        )

    def test_mapping_with_quoted_key_or_later_separator_is_rejected(self):
        self._assert_arg_issues(
            """        - 'op': '&&'
        - http://localhost: 3000
""",
            ["'op': '&&'", "http://localhost: 3000"],
        )

    def test_fully_quoted_mapping_like_values_are_valid_strings(self):
        config = self._profile_config(
            """        - 'label: value'
        - "url: http://localhost: 3000"
"""
        )

        self.assertEqual(
            tabby_profile_sync.find_profile_arg_type_issues(config),
            [],
        )

    def test_report_groups_operator_lines_by_profile(self):
        config = self._profile_config(
            """        - op: '&&'
        - op: ';'
""",
            command="open",
        )
        stderr = io.StringIO()

        with redirect_stderr(stderr):
            found = tabby_profile_sync.report_profile_arg_type_issues(config)

        self.assertTrue(found)
        self.assertIn(
            "site.local: non-string argument at line(s) 6, 7",
            stderr.getvalue(),
        )
        self.assertIn("full quoted <login-shell> -l -c", stderr.getvalue())

    def test_missing_managed_profile_command_is_reported(self):
        config = self._profile_config(
            """        - '-l'
        - '-c'
        - 'exec aidevops opencode --tabby-shell'
""",
            command="/missing/zsh",
        )

        issues = tabby_profile_sync.find_profile_command_issues(config)

        self.assertEqual(len(issues), 1)
        self.assertEqual(issues[0].profile_name, "site.local")
        self.assertEqual(issues[0].value, "/missing/zsh")


class TestTabbyShellResolver(unittest.TestCase):
    """Cross-platform shell resolution fixtures for managed Tabby profiles."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def _shell(self, name: str) -> str:
        path = self.root / name
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o700)
        return str(path)

    def test_configured_bash_wins_without_zsh(self):
        bash_path = self._shell("bash")
        with mock.patch.dict(
            os.environ,
            {"AIDEVOPS_TABBY_LOGIN_SHELL": bash_path, "SHELL": "/missing/zsh"},
        ), mock.patch("tabby_shell_resolver._account_login_shell", return_value=""):
            resolved = resolve_login_shell(fallback_candidates=[])

        self.assertEqual(resolved, bash_path)

    def test_macos_fallback_prefers_valid_zsh(self):
        with mock.patch.dict(
            os.environ,
            {"AIDEVOPS_TABBY_LOGIN_SHELL": "", "SHELL": ""},
        ), mock.patch("tabby_shell_resolver._account_login_shell", return_value=""):
            resolved = resolve_login_shell(
                configured_shell="relative/zsh",
                fallback_candidates=["/bin/zsh", "/bin/bash"],
                platform_name="Darwin",
                validator=lambda candidate: candidate == "/bin/zsh",
            )

        self.assertEqual(resolved, "/bin/zsh")

    def test_invalid_candidates_fail_visibly(self):
        with mock.patch.dict(
            os.environ,
            {"AIDEVOPS_TABBY_LOGIN_SHELL": "relative/bash", "SHELL": ""},
        ), mock.patch("tabby_shell_resolver._account_login_shell", return_value=""):
            with self.assertRaises(ShellResolutionError):
                resolve_login_shell(
                    fallback_candidates=[], validator=lambda _candidate: False
                )


if __name__ == "__main__":
    unittest.main()
