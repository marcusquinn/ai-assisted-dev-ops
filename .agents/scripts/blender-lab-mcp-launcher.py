# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Opt-in official Blender Lab MCP provisioning and stdio launch.

Consent flags are operator attestations, not sandbox detection. Both Blender
and this process must already be inside the operator's isolated environment.
"""

import argparse
import os
import re
import shutil
import socket
import subprocess
import sys
from pathlib import Path

REVISION = "4309a39646e644261624bfcd2bca669b343b7621"
SOURCE = (
    "git+https://projects.blender.org/lab/blender_mcp.git@"
    + REVISION
    + "#subdirectory=mcp"
)


def require_consent():
    """Fail before probing, downloading, or executing external programs."""
    # aidevops:trust-boundary -- never infer approval from MCP registration.
    if (os.environ.get("AIDEVOPS_BLENDER_ISOLATED") != "1"
            or os.environ.get("AIDEVOPS_BLENDER_CODE_EXECUTION") != "approved"):
        raise ValueError(
            "Blender Lab executes unguarded Python. Inside an isolated system only, "
            "the operator must set AIDEVOPS_BLENDER_ISOLATED=1 and "
            "AIDEVOPS_BLENDER_CODE_EXECUTION=approved before starting the client. "
            "These attestations do not create or verify a sandbox."
        )


def connection_settings():
    host = os.environ.get("BLENDER_MCP_HOST", "127.0.0.1")
    # Use literal loopback only: do not trust localhost DNS or arbitrary hosts.
    if host not in ("127.0.0.1", "::1"):
        raise ValueError("BLENDER_MCP_HOST must be literal loopback (127.0.0.1 or ::1)")
    port = int(os.environ.get("BLENDER_MCP_PORT", "9876"))
    if not 1 <= port <= 65535:
        raise ValueError("BLENDER_MCP_PORT must be between 1 and 65535")
    return host, port


def prerequisites():
    uv = shutil.which("uv")
    if not uv:
        raise ValueError("Install uv in the isolated system before using Blender Lab MCP")
    if not shutil.which("git"):
        raise ValueError("Install Git in the isolated system for pinned source provisioning")
    blender = os.environ.get("BLENDER_EXECUTABLE") or shutil.which("blender")
    mac_blender = Path("/Applications/Blender.app/Contents/MacOS/Blender")
    if not blender and sys.platform == "darwin" and mac_blender.is_file():
        blender = str(mac_blender)
    if not blender:
        raise ValueError("Install Blender 5.1+ and its official MCP add-on; set BLENDER_EXECUTABLE if needed")
    result = subprocess.run(
        [blender, "--factory-startup", "--disable-autoexec", "--background", "--version"],
        capture_output=True, text=True, timeout=15, check=True,
    )
    version = re.search(r"^Blender (\d+)\.(\d+)", result.stdout, re.MULTILINE)
    if not version or tuple(map(int, version.groups())) < (5, 1):
        raise ValueError("Blender 5.1 or newer is required by the official MCP add-on")
    return uv


def launch_environment(host, port):
    # Do not let inherited uv/Git overrides or Python import hooks select a
    # different package. This is provenance hygiene, not host isolation.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("UV_", "GIT_", "PYTHON"))}
    env["BLENDER_MCP_HOST"] = host
    env["BLENDER_MCP_PORT"] = str(port)
    env["PYTHONNOUSERSITE"] = "1"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_CONFIG_GLOBAL"] = os.devnull
    return env


def run(action):
    require_consent()
    host, port = connection_settings()
    uv = prerequisites()
    if action != "prepare":
        try:
            with socket.create_connection((host, port), timeout=2):
                pass
        except OSError as exc:
            raise ValueError(
                "Start the official MCP add-on bridge in Blender on the configured "
                "loopback port. No server package was installed or launched."
            ) from exc
    if action == "check":
        print("Prerequisites and TCP reachability verified; add-on identity is not verified.")
        return 0
    command = [
        uv, "tool", "run", "--no-config", "--isolated", "--python", "3.11",
        "--from", SOURCE, "blender-mcp",
    ]
    if action == "prepare":
        # Prewarm deliberately before MCP connection to avoid client startup
        # timeouts on the first Git/Python/dependency download. No Blender UI/bridge.
        command.append("--help")
    else:
        command.extend(["--transport", "stdio"])
    os.execvpe(uv, command, launch_environment(host, port))
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("run", "check", "prepare"), default="run", nargs="?")
    args = parser.parse_args()
    try:
        return run(args.action)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        # Keep protocol stdout clean and avoid relaying untrusted child output.
        detail = str(exc) if isinstance(exc, ValueError) else type(exc).__name__
        print("Blender Lab MCP: " + detail, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
