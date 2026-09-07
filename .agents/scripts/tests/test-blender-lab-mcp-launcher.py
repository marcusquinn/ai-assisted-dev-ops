# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exercise the real launcher process with offline executable fixtures."""

import json
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

LAUNCHER = Path(__file__).resolve().parents[1] / "blender-lab-mcp-launcher.py"


class BlenderLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="blender-launcher-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.marker = self.root / "uv-called.json"
        self.env = {
            "PATH": str(self.root), "HOME": str(self.root),
            "AIDEVOPS_BLENDER_ISOLATED": "1",
            "AIDEVOPS_BLENDER_CODE_EXECUTION": "approved",
            "TEST_MARKER": str(self.marker),
        }
        self.executable("blender", "print('Blender 5.1.0')")
        self.executable("git", "pass")
        self.executable("uv", """
import json, os, sys
from pathlib import Path
Path(os.environ['TEST_MARKER']).write_text(json.dumps({
    'args': sys.argv[1:], 'env': dict(os.environ)
}))
if '--help' not in sys.argv:
    sys.stdout.write(sys.stdin.read())
""")

    def executable(self, name, code):
        path = self.root / name
        path.write_text(f"#!{sys.executable}\n{code}\n", encoding="utf-8")
        path.chmod(0o700)

    def invoke(self, *args, payload=""):
        return subprocess.run(
            [sys.executable, "-I", str(LAUNCHER), *args],
            input=payload, capture_output=True, text=True, env=self.env, timeout=10, check=False,
        )

    def bridge(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(2)
        self.addCleanup(listener.close)
        self.env["BLENDER_MCP_PORT"] = str(listener.getsockname()[1])

    def test_missing_consent_stops_before_executables(self):
        for flag in ("AIDEVOPS_BLENDER_ISOLATED", "AIDEVOPS_BLENDER_CODE_EXECUTION"):
            with self.subTest(flag=flag):
                original = self.env.pop(flag)
                result = self.invoke("prepare")
                self.env[flag] = original
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unguarded Python", result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertFalse(self.marker.exists())

    def test_non_loopback_and_invalid_ports_fail_without_provisioning(self):
        for host, port in (("localhost", "9876"), ("0.0.0.0", "9876"),
                           ("::1", "9876"),
                           ("example.invalid", "9876"), ("127.0.0.1", "0"),
                           ("127.0.0.1", "65536"), ("127.0.0.1", "abc")):
            with self.subTest(host=host, port=port):
                self.env.update(BLENDER_MCP_HOST=host, BLENDER_MCP_PORT=port)
                self.assertNotEqual(self.invoke("prepare").returncode, 0)
                self.assertFalse(self.marker.exists())

    def test_old_blender_fails(self):
        self.executable("blender", "print('Blender 4.5.0')")
        result = self.invoke("prepare")
        self.assertIn("5.1 or newer", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_missing_uv_fails(self):
        (self.root / "uv").unlink()
        self.assertIn("Install uv", self.invoke("prepare").stderr)

    def test_bridge_unavailable_does_not_install(self):
        # Reserve a port without listening so no unrelated service can answer.
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            self.env["BLENDER_MCP_PORT"] = str(reserved.getsockname()[1])
            result = self.invoke()
        self.assertIn("Start the official MCP add-on", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertFalse(self.marker.exists())

    def test_prepare_uses_official_pin_and_ignores_package_overrides(self):
        self.env.update(UV_OVERRIDE="bad.txt", PYTHONPATH="untrusted", UV_CONFIG_FILE="bad.toml")
        self.env.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="url.bad.insteadOf",
                        GIT_CONFIG_VALUE_0="https://projects.blender.org/", GIT_CONFIG_GLOBAL="bad.gitconfig")
        result = self.invoke("prepare")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = json.loads(self.marker.read_text())
        self.assertIn("--isolated", call["args"])
        self.assertIn("--no-config", call["args"])
        self.assertEqual(call["args"][-2:], ["blender-mcp", "--help"])
        source = call["args"][call["args"].index("--from") + 1]
        self.assertEqual(source, "git+https://projects.blender.org/lab/blender_mcp.git@"
                         "4309a39646e644261624bfcd2bca669b343b7621#subdirectory=mcp")
        for name in ("UV_OVERRIDE", "PYTHONPATH", "UV_CONFIG_FILE", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0"):
            self.assertNotIn(name, call["env"])
        self.assertEqual(call["env"]["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertEqual(call["env"]["GIT_CONFIG_GLOBAL"], "/dev/null")

    def test_check_probes_without_installing(self):
        self.bridge()
        result = self.invoke("check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("identity is not verified", result.stdout)
        self.assertFalse(self.marker.exists())

    def test_run_preserves_stdio(self):
        self.bridge()
        payload = '{"jsonrpc":"2.0","id":1}\n'
        result = self.invoke(payload=payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, payload)
        self.assertEqual(result.stderr, "")
        call = json.loads(self.marker.read_text())
        self.assertEqual(call["args"][-3:], ["blender-mcp", "--transport", "stdio"])
        self.assertEqual(call["env"]["BLENDER_MCP_HOST"], "127.0.0.1")


if __name__ == "__main__":
    unittest.main()
