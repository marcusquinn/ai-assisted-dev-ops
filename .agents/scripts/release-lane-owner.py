#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Observe release executor identity without equating a fence with liveness."""

import hashlib
import json
import os
import socket
import subprocess
import sys
import uuid
from pathlib import Path


def host_id():
    """Publish only a digest, never a host name or hardware address."""
    node = uuid.getnode()
    # uuid's random fallback cannot establish stable cross-process identity.
    if (node >> 40) & 1:
        raise ValueError("stable host identity unavailable")
    namespace = "darwin"
    if sys.platform == "linux":
        # Host-network containers can share MAC/hostname but not PID visibility.
        boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        namespace = f"{boot}:{os.readlink('/proc/self/ns/pid')}"
    elif sys.platform != "darwin":
        raise ValueError("unsupported process identity platform")
    return hashlib.sha256(f"{socket.gethostname()}:{node}:{namespace}".encode()).hexdigest()


def process_start(pid):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart="],
        capture_output=True, text=True, timeout=5, check=False,
        env={**os.environ, "LC_ALL": "C"},
    )
    if result.returncode or not result.stdout.strip():
        raise ValueError("process identity unavailable")
    return " ".join(result.stdout.split())


def capture(pid):
    if pid <= 1:
        raise ValueError("invalid executor pid")
    return {"host_id": host_id(), "pid": pid, "started_at": process_start(pid)}


def observe(executor):
    unknown = {"state": "unknown", "reason": "missing-or-foreign-identity"}
    if not isinstance(executor, dict) or executor.get("host_id") != host_id():
        return unknown
    pid = executor.get("pid")
    started = executor.get("started_at")
    if type(pid) is not int or pid <= 1 or not isinstance(started, str) or not started:
        return unknown
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return {"state": "dead", "reason": "process-absent"}
    except PermissionError:
        return {"state": "unknown", "reason": "process-permission"}
    if process_start(pid) != started:
        return {"state": "dead", "reason": "pid-reused"}
    return {"state": "live", "reason": "process-identity-matches"}


def main():
    try:
        if sys.argv[1:] and sys.argv[1] == "capture":
            result = capture(int(sys.argv[2]))
        elif sys.argv[1:] == ["observe"]:
            result = observe(json.load(sys.stdin))
        else:
            return 1
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        if sys.argv[1:] == ["observe"]:
            result = {"state": "unknown", "reason": "observation-unavailable"}
        else:
            return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
