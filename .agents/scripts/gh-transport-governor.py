#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Observe one supported native REST request without GH_DEBUG or payload logs.

Return 125 only before execution, so callers may retain native handling for
unsupported CLI shapes. Explicit pagination invokes this once per actual page.
No response is cached, and no automatic transport retry is performed.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from gh_transport_budget import Budget, Deferred, credential_identity, private_directory, scope_key


VALUE_FLAGS = {
    "-X", "--method", "-H", "--header", "--hostname", "-F", "--field",
    "-f", "--raw-field", "--input", "-q", "--jq", "-p", "--preview",
    "-t", "--template",
}
BOOL_FLAGS = {"--include", "-i", "--silent"}


def request_shape(args: list[str]) -> tuple[str, str, bool, bool] | None:
    if not args or args[0] != "api":
        return None
    endpoint = ""
    host = os.environ.get("GH_HOST", "github.com").lower()
    include = silent = False
    index = 1
    while index < len(args):
        arg = args[index]
        option, _, value = arg.partition("=")
        if option in VALUE_FLAGS:
            if "=" not in arg:
                index += 1
                if index >= len(args):
                    return None
                value = args[index]
            if option == "--hostname":
                host = value.lower()
            # A caller-supplied Authorization header is a different identity.
            if option in {"-H", "--header"} and value.split(":", 1)[0].strip().lower() in {
                "authorization", "x-gh-cache-ttl",
            }:
                return None
        elif arg in BOOL_FLAGS:
            include |= arg in {"--include", "-i"}
            silent |= arg == "--silent"
        elif arg.startswith("-"):
            # Conservative: joined short options, cache, pagination, debug,
            # GraphQL and future CLI options retain their native transport.
            return None
        elif endpoint:
            return None
        else:
            endpoint = arg.lstrip("/")
        index += 1
    if host != "github.com" or not endpoint or ":" in endpoint or "#" in endpoint:
        return None
    path = endpoint.split("?", 1)[0]
    if path in {"graphql", "rate_limit"}:
        return None
    resource = "code_search" if path == "search/code" else (
        "search" if path.startswith("search/") else "core"
    )
    return host, resource, include, silent


def included_headers(stream) -> tuple[int, dict[str, str], int]:
    stream.seek(0)
    first = stream.readline(8192)
    match = re.fullmatch(rb"HTTP/[0-9.]+ ([0-9]{3})[^\r\n]*\r?\n", first)
    if not match:
        stream.seek(0)
        return 0, {}, 0
    headers: dict[str, str] = {}
    while stream.tell() < 65536:
        line = stream.readline(8192)
        if line in {b"\n", b"\r\n"}:
            return int(match[1]), headers, stream.tell()
        if not line or b":" not in line:
            break
        name, value = line.decode("ascii", errors="replace").split(":", 1)
        name = name.lower()
        if name in {"x-ratelimit-limit", "x-ratelimit-remaining", "x-ratelimit-used",
                    "x-ratelimit-reset", "x-ratelimit-resource", "retry-after"}:
            # Duplicate rate headers are ambiguous, not additional authority.
            if name in headers:
                return 0, {}, 0
            headers[name] = value.strip()
    return 0, {}, 0


def execute(executable: str, args: list[str], output) -> int:
    child = subprocess.Popen([executable, *args], stdout=output)
    try:
        return child.wait(timeout=90)
    except subprocess.TimeoutExpired:
        print("[gh-transport] native REST request timed out", file=sys.stderr)
        return 124
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


def run(metadata: Path, executable: str, args: list[str]) -> int:
    shape = request_shape(args)
    if shape is None or sys.stdout.isatty():
        return 125
    host, resource, include, silent = shape
    directory = Path(os.environ.get(
        "AIDEVOPS_GH_TRANSPORT_STATE_DIR",
        str(Path.home() / ".aidevops/state/gh-transport"),
    ))
    temp_dir = Path(os.environ.get(
        "AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp")
    ))
    budget = None
    reservation = ""
    started = time.time()
    headers: dict[str, str] = {}
    rc = None
    try:
        metadata.write_text('{"attempted":false}', encoding="utf-8")
        private_directory(temp_dir)
        credential, authenticated = credential_identity(executable, host)
        budget = Budget(directory, scope_key(host), credential)
        reservation = budget.acquire(resource)
        with tempfile.TemporaryFile(dir=temp_dir) as output:
            native_args = args if include else [*args, "--include"]
            metadata.write_text('{"attempted":true}', encoding="utf-8")
            rc = execute(executable, native_args, output)
            status, headers, body_offset = included_headers(output)
            if include:
                output.seek(0)
                shutil.copyfileobj(output, sys.stdout.buffer)
            elif not status:
                # A changed native framing contract must not turn injected
                # headers into application data or silently report success.
                print("[gh-transport] unrecognized native response framing", file=sys.stderr)
                rc = rc or 1
            elif not silent:
                output.seek(body_offset)
                shutil.copyfileobj(output, sys.stdout.buffer)
            # Persist numeric metadata only, never endpoint, query, body or auth.
            actual_resource = headers.get("x-ratelimit-resource", "")
            known_resource = actual_resource in {"core", "search", "code_search"}
            result = {
                "attempted": True,
                "status": status or None,
                "resource": actual_resource if known_resource else None,
                "remaining": int(headers["x-ratelimit-remaining"])
                if headers.get("x-ratelimit-remaining", "").isdecimal() else None,
                "reset": int(headers["x-ratelimit-reset"])
                if headers.get("x-ratelimit-reset", "").isdecimal() else None,
                "retry_after": int(headers["retry-after"])
                if headers.get("retry-after", "").isdecimal() else None,
                "cost": (0 if status == 304 else 1)
                if known_resource and 200 <= status < 400
                and (status != 304 or authenticated) else None,
            }
            metadata.write_text(json.dumps(result), encoding="utf-8")
            return rc if rc >= 0 else 128 - rc
    except Deferred as exc:
        print(f"[gh-transport] deferred: {exc}", file=sys.stderr)
        return 75
    except (OSError, ValueError, sqlite3.Error):
        # Metadata failure after execution is not permission to retry a
        # successful mutation. Keep the observed native status when available.
        print("[gh-transport] safe REST transport state unavailable", file=sys.stderr)
        return (rc if rc >= 0 else 128 - rc) if rc is not None else 75
    finally:
        if budget is not None:
            if reservation:
                try:
                    budget.finish(reservation, resource, headers, started=started)
                except (OSError, ValueError, sqlite3.Error):
                    print("[gh-transport] quota observation remains uncertain", file=sys.stderr)
            budget.close()


if __name__ == "__main__":
    if len(sys.argv) < 4:
        raise SystemExit(2)
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    for handled_signal in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(handled_signal, interrupted)
    raise SystemExit(run(Path(sys.argv[1]), sys.argv[2], sys.argv[3:]))
