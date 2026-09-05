#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Observe one supported native REST request without GH_DEBUG or payload logs.

Return 125 with attempted=false for unsupported shapes; an executed native125
is distinguished by attempted=true. Never decide fallback from exit code alone.
Explicit pagination invokes this once per page.
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


def _value_option(option: str, value: str) -> tuple[str, str]:
    # Streamed input and inherited descriptors must retain native execution.
    if option == "--input" or any(part in value for part in ("/dev/fd/", "/proc/self/fd/")):
        raise ValueError("unsupported input")
    # Caller-supplied authorization is a different identity; caching is opaque.
    if option in {"-H", "--header"}:
        if value.split(":", 1)[0].strip().lower() in {"authorization", "x-gh-cache-ttl"}:
            raise ValueError("unsupported header")
    aliases = {"-X": "--method", "-F": "--field", "-f": "--field", "--raw-field": "--field"}
    return aliases.get(option, option), value


def _request_options(args: list[str]) -> tuple[str, dict[str, str]]:
    endpoint = ""
    options: dict[str, str] = {}
    remaining = iter(args)
    for arg in remaining:
        option, separator, value = arg.partition("=")
        if option in VALUE_FLAGS:
            if not separator:
                value = next(remaining)
            option, value = _value_option(option, value)
            options[option] = value
        elif arg in BOOL_FLAGS:
            options[arg] = ""
        elif endpoint or arg.startswith(("-", "//")):
            # Unknown options and multiple endpoints retain native transport.
            raise ValueError("unsupported argument")
        else:
            endpoint = arg.lstrip("/")
    return endpoint, options


def _request_resource(host: str, endpoint: str, options: dict[str, str]) -> str:
    path = endpoint.split("?", 1)[0]
    unsupported = (
        host != "github.com", not path, ":" in path, "#" in endpoint,
        options.get("--method", "GET").upper() != "GET",
        {"--field", "--method"}.intersection(options) == {"--field"},
        path in {"graphql", "rate_limit"},
    )
    if any(unsupported):
        raise ValueError("unsupported request")
    if path == "search/code":
        return "code_search"
    return "search" if path.startswith("search/") else "core"


def request_shape(args: list[str]) -> tuple[str, str, bool, bool] | None:
    if args[:1] != ["api"] or os.environ.get("GH_DEBUG"):
        return None
    try:
        endpoint, options = _request_options(args[1:])
        host = options.get("--hostname", os.environ.get("GH_HOST", "github.com")).lower()
        resource = _request_resource(host, endpoint, options)
        include = not {"--include", "-i"}.isdisjoint(options)
        return host, resource, include, "--silent" in options
    except (ValueError, StopIteration):
        return None


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


def execute(executable: str, args: list[str], output, environment: dict[str, str]) -> int:
    child = subprocess.Popen([executable, *args], stdout=output, env=environment)
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


def _acquire(budget: Budget, resource: str) -> str:
    # Queue briefly for local admission, never retry HTTP or a mutation.
    for admission_try in range(21):
        try:
            return budget.acquire(resource)
        except Deferred as pause:
            if not pause.retryable or admission_try == 20:
                raise
            time.sleep(0.1)


def _copy_response(output, include: bool, silent: bool, status: int, body_offset: int) -> int:
    if include:
        output.seek(0)
        shutil.copyfileobj(output, sys.stdout.buffer)
    elif not status:
        # Unknown framing must not leak injected headers or report success.
        print("[gh-transport] unrecognized native response framing", file=sys.stderr)
        return 1
    elif not silent:
        output.seek(body_offset)
        shutil.copyfileobj(output, sys.stdout.buffer)
    return 0


def _response_metadata(status: int, headers: dict[str, str], authenticated: bool) -> dict:
    # Persist numeric metadata only, never endpoint, query, body or auth.
    resource = headers.get("x-ratelimit-resource", "")
    known_resource = resource in {"core", "search", "code_search"}
    cost = None
    if known_resource and 200 <= status < 400:
        cost = 1
        if status == 304:
            cost = 0 if authenticated else None
    result = {
        "attempted": True, "status": status or None,
        "resource": resource if known_resource else None, "cost": cost,
    }
    for name, header in (("remaining", "x-ratelimit-remaining"),
                         ("reset", "x-ratelimit-reset"), ("retry_after", "retry-after")):
        value = headers.get(header, "")
        result[name] = int(value) if value.isdecimal() else None
    return result


def _exit_status(rc: int) -> int:
    return rc if rc >= 0 else 128 - rc


def _finish_budget(budget, reservation: str, resource: str, headers: dict[str, str], started: float) -> None:
    if budget is None:
        return
    if reservation:
        try:
            budget.finish(reservation, resource, headers, started=started)
        except (OSError, ValueError, sqlite3.Error):
            print("[gh-transport] quota observation remains uncertain", file=sys.stderr)
    budget.close()


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
        credential, authenticated, environment = credential_identity(executable, host)
        if not authenticated:
            # Do not mix anonymous-IP and authenticated-user allowances or
            # trust an identity which could change before native execution.
            return 125
        budget = Budget(directory, scope_key(host), credential)
        reservation = _acquire(budget, resource)
        with tempfile.TemporaryFile(dir=temp_dir) as output:
            native_args = args if include else [*args, "--include"]
            metadata.write_text('{"attempted":true}', encoding="utf-8")
            rc = execute(executable, native_args, output, environment)
            status, headers, body_offset = included_headers(output)
            framing_rc = _copy_response(output, include, silent, status, body_offset)
            rc = rc or framing_rc
            result = _response_metadata(status, headers, authenticated)
            metadata.write_text(json.dumps(result), encoding="utf-8")
            return _exit_status(rc)
    except Deferred as exc:
        print(f"[gh-transport] deferred: {exc}", file=sys.stderr)
        return 75
    except (OSError, ValueError, sqlite3.Error):
        # Metadata failure after execution is not permission to retry a
        # successful mutation. Keep the observed native status when available.
        print("[gh-transport] safe REST transport state unavailable", file=sys.stderr)
        return _exit_status(rc) if rc is not None else 75
    finally:
        _finish_budget(budget, reservation, resource, headers, started)


if __name__ == "__main__":
    if len(sys.argv) < 4:
        raise SystemExit(2)
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    for handled_signal in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(handled_signal, interrupted)
    raise SystemExit(run(Path(sys.argv[1]), sys.argv[2], sys.argv[3:]))
