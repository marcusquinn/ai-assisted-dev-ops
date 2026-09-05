#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exercise real launcher processes with recording CLIs, without model inference."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("launcher", SCRIPTS / "runtime-launcher.py")
LAUNCHER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LAUNCHER)


class RuntimeLauncherTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="aidevops launcher ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.root), PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self.output = self.root / "result.json"
        self.env["RECORD_OUTPUT"] = str(self.output)
        for name, _ in LAUNCHER.RUNTIMES.values():
            if name:
                script = self.bin / name
                script.write_text(f"#!{sys.executable}\nimport json,os,sys\nfrom pathlib import Path\n"
                                  "data={'argv':sys.argv[1:],'cwd':os.getcwd()}\n"
                                  "if Path(sys.argv[0]).name == 'amp':data['stdin']=sys.stdin.read()\n"
                                  "Path(os.environ['RECORD_OUTPUT']).write_text(json.dumps(data))\n"
                                  "sys.exit(int(os.environ.get('RECORD_EXIT','0')))\n")
                script.chmod(0o755)

    def run_launcher(self, *args, input_text=""):
        return subprocess.run(  # nosec B603 -- fixed local launcher, test-owned argv and environment.
            ["/bin/bash", str(SCRIPTS / "runtime-launcher-helper.sh"), *args],
                              env=self.env, cwd=self.root, input=input_text, text=True,
                              capture_output=True, timeout=20)

    def record(self, *args):
        result = self.run_launcher(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(self.output.read_text())

    def test_codex_defaults_and_literal_passthrough(self):
        literal = "spaces $HOME `echo nope` $(false)"
        data = self.record("codex", "--", "-m", literal)
        self.assertEqual(data["argv"][:4], ["--sandbox", "danger-full-access", "--ask-for-approval", "never"])
        self.assertIn("main agent build-plus", data["argv"][5])
        self.assertEqual(data["argv"][-2:], ["-m", literal])
        self.assertEqual(Path(data["cwd"]).resolve(), self.root.resolve())

    def test_claude_selection_and_aliases(self):
        for alias in ("claude", "claude-code"):
            data = self.record(alias, "automate")
            self.assertEqual(data["argv"][:2], ["--dangerously-skip-permissions", "--append-system-prompt"])
            self.assertIn("main agent automate", data["argv"][2])
            self.assertIn("wait for the user's request", data["argv"][2])

    def test_all_terminal_adapters_remain_interactive(self):
        for runtime in LAUNCHER.RUNTIMES:
            if runtime in {"windsurf", "opencode"}:
                continue
            with self.subTest(runtime=runtime):
                data = self.record(runtime, "seo")
                self.assertNotIn("--execute", data["argv"])
                self.assertNotIn("--print", data["argv"])
                self.assertNotIn("--no-interactive", data["argv"])
                self.assertNotIn("exec", data["argv"])

    def test_amp_retains_user_stdin(self):
        result = self.run_launcher("amp", "automate", input_text="User's actual task\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        text = json.loads(self.output.read_text())["stdin"]
        self.assertIn("main agent automate", text)
        self.assertTrue(text.endswith("User's actual task\n"))

    def test_kimi_files_and_dry_run(self):
        result = self.run_launcher("kimi", "automate", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / ".aidevops").exists())
        data = self.record("kimi", "automate")
        config = Path(data["argv"][-1]).read_text()
        self.assertIn("extend: default", config)
        prompt_path = json.loads(config.split("system_prompt_path: ")[1])
        self.assertIn("main agent automate", Path(prompt_path).read_text())

    def test_errors_and_exit_status(self):
        for args in (("codex", "../automate"), ("codex", "does-not-exist"), ("windsurf",)):
            self.assertNotEqual(self.run_launcher(*args).returncode, 0)
        self.env["RECORD_EXIT"] = "37"
        self.assertEqual(self.run_launcher("codex").returncode, 37)

    def test_help_list_and_native_do_not_inject_defaults(self):
        for option in ("--help", "--list-agents"):
            result = self.run_launcher("codex", option)
            self.assertEqual(result.returncode, 0)
            self.assertIn("build-plus", result.stdout)
            self.assertFalse(self.output.exists())
        self.assertEqual(self.record("codex", "--native", "login", "--help")["argv"], ["login", "--help"])

    def test_opencode_protected_modes_are_unchanged(self):
        for mode in LAUNCHER.OPENCODE_MODES:
            with patch.object(LAUNCHER, "execute", side_effect=SystemExit) as execute:
                with self.assertRaises(SystemExit):
                    LAUNCHER.launch("opencode", [mode, "--dry-run"])
                self.assertEqual(execute.call_args.args[0][-2:], [mode, "--dry-run"])
                self.assertNotIn("--auto", execute.call_args.args[0])
        data = self.record("opencode", "seo", "--shared-db")
        self.assertEqual(data["argv"], ["--auto", "--agent", "SEO"])

    def test_registry_coverage(self):
        script = 'source "$1"; printf "%s\\n" "${_RT_IDS[@]}"'
        result = subprocess.run(  # nosec B603 -- constant shell program, repository-owned registry.
            ["/bin/bash", "-c", script, "bash", str(SCRIPTS / "runtime-registry.sh")],
                                capture_output=True, text=True, check=True)
        self.assertEqual(set(result.stdout.splitlines()), set(LAUNCHER.RUNTIMES))


if __name__ == "__main__":
    unittest.main()
