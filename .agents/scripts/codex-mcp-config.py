#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Reconcile known Codex MCP defaults without rewriting unrelated TOML."""

import argparse
import copy
import json
import os
from pathlib import Path
import re
import stat
import tempfile

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        raise SystemExit("Codex MCP migration requires Python 3.11+ or tomli; config unchanged") from None


DEFAULTS = {
    "context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp@latest"]},
    "playwright": {
        "command": "npx",
        "args": ["-y", "@playwright/mcp@0.0.79", "--headless", "--isolated"],
    },
    "shadcn": {"command": "npx", "args": ["-y", "shadcn@latest", "mcp"]},
    "openapi-search": {"url": "https://openapi-mcp.openapisearch.com/mcp"},
    "cloudflare-api": {"url": "https://mcp.cloudflare.com/mcp"},
}
NPX_PACKAGES = {
    "context7": "@upstash/context7-mcp",
    "playwright": "@playwright/mcp",
    "shadcn": "shadcn",
    "macos-automator": "@steipete/macos-automator-mcp",
    "shopify-dev-mcp": "@shopify/dev-mcp",
}


def known_package(args, package):
    """Match package names exactly, including an optional version suffix."""
    return any(arg == package or arg.startswith(package + "@") for arg in args)


def reconcile(data):
    """Return desired config and human-readable changes, never credential values."""
    desired = copy.deepcopy(data)
    servers = desired.setdefault("mcp_servers", {})
    messages = []
    for name, default in DEFAULTS.items():
        if name not in servers:
            servers[name] = dict(default, enabled=False)
            messages.append(f"{name}: added disabled; enable explicitly when needed")
    for name, server in servers.items():
        command = server.get("command", "")
        args = server.get("args", [])
        is_npx = Path(command).name in ("npx", "npx.cmd")
        if name == "playwright" and is_npx and known_package(
            args, "@anthropic-ai/mcp-server-playwright"
        ):
            server["args"] = [
                "@playwright/mcp@0.0.79"
                if arg.startswith("@anthropic-ai/mcp-server-playwright") else arg
                for arg in args
            ]
            args = server["args"]
            messages.append("playwright: replaced nonexistent legacy npm package")
        if is_npx and name in NPX_PACKAGES and known_package(args, NPX_PACKAGES[name]):
            if "-y" not in args and "--yes" not in args:
                server["args"] = ["-y", *args]
            if "startup_timeout_sec" not in server and "startup_timeout_ms" not in server:
                server["startup_timeout_sec"] = 60
                messages.append(f"{name}: allow 60 seconds for npm cold start")
        if name in DEFAULTS and "url" in server and server["url"] == DEFAULTS[name].get("url"):
            if server.get("type") == "url":
                del server["type"]
            # Old setup implicitly enabled an OAuth service without a login step.
            # Preserve explicit opt-in/opt-out decisions on subsequent updates.
            if name == "cloudflare-api" and "enabled" not in server:
                server["enabled"] = False
                messages.append("cloudflare-api: disabled pending explicit OAuth setup")
        if name == "auggie-mcp" and Path(command).name == "auggie" and args == ["--mcp"]:
            if server.get("enabled", True):
                server["enabled"] = False
                messages.append("auggie-mcp: disabled deprecated integration")
        if (name == "node_repl" and command.startswith("/Applications/")
                and command.endswith("/cua_node/bin/node_repl")
                and not os.path.isfile(command) and server.get("enabled", True)):
            server["enabled"] = False
            messages.append("node_repl: disabled stale app executable; reinstall via the app")
    return desired, messages


def section_span(text, name):
    headers = list(re.finditer(r"(?m)^\s*\[[^\n]+\][ \t]*(?:#[^\n]*)?$", text))
    for index, header in enumerate(headers):
        try:
            parsed = tomllib.loads(header.group() + "\n__probe__ = true\n")
        except tomllib.TOMLDecodeError:
            continue
        if parsed == {"mcp_servers": {name: {"__probe__": True}}}:
            end = headers[index + 1].start() if index + 1 < len(headers) else len(text)
            return header.end(), end
    raise ValueError(f"Cannot safely locate MCP table {name}")


def change_field(block, key, old, new, remove=False):
    match = re.search(r"(?m)^[ \t]*" + re.escape(key) + r"[ \t]*=", block)
    if match is None:
        if old is not None:
            raise ValueError(f"Cannot safely locate field {key}")
        return "\n" + key + " = " + json.dumps(new) + "\n" + block.lstrip("\n")
    # Parse progressively to include multiline arrays without swallowing the next key.
    end = match.end()
    while end < len(block):
        newline = block.find("\n", end)
        end = len(block) if newline < 0 else newline + 1
        try:
            value = tomllib.loads(block[match.start():end])
        except tomllib.TOMLDecodeError:
            continue
        if value != {key: old}:
            raise ValueError(f"Cannot safely replace field {key}")
        replacement = "" if remove else key + " = " + json.dumps(new) + "\n"
        return block[:match.start()] + replacement + block[end:]
    raise ValueError(f"Cannot safely parse field {key}")


def render(text, original, desired):
    old_servers = original.get("mcp_servers", {})
    for name, server in desired["mcp_servers"].items():
        if name not in old_servers:
            text += "\n[mcp_servers." + json.dumps(name) + "]\n"
            text += "".join(key + " = " + json.dumps(value) + "\n" for key, value in server.items())
            continue
        previous = old_servers[name]
        if previous == server:
            continue
        start, end = section_span(text, name)
        block = text[start:end]
        for key in previous.keys() | server.keys():
            if previous.get(key) != server.get(key):
                block = change_field(block, key, previous.get(key), server.get(key), key not in server)
        text = text[:start] + block + text[end:]
    # Fail closed for exotic TOML layouts: no semantic change outside the plan.
    if tomllib.loads(text) != desired:
        raise ValueError("MCP migration would alter unrelated configuration")
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path.home() / ".codex/config.toml")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    config = args.config.expanduser().resolve()
    original_bytes = config.read_bytes() if config.exists() else b""
    text = original_bytes.decode("utf-8")
    original = tomllib.loads(text)
    desired, messages = reconcile(original)
    updated = render(text, original, desired)
    if updated == text:
        print("Codex MCP configuration already reconciled")
        return
    for message in messages:
        print(message)
    if args.dry_run:
        print("Dry run: no files changed")
        return
    config.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(config.stat().st_mode) if config.exists() else 0o600
    fd, temporary = tempfile.mkstemp(prefix=".codex-mcp-", dir=config.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(updated.encode("utf-8"))
            os.fchmod(output.fileno(), mode)
        if config.exists():
            if config.read_bytes() != original_bytes:
                raise ValueError("Codex configuration changed concurrently; retry setup")
            backup_fd, backup = tempfile.mkstemp(prefix="config.toml.before-mcp-", dir=config.parent)
            with os.fdopen(backup_fd, "wb") as output:
                output.write(original_bytes)
            print(f"Backup saved: {Path(backup).name}")
        os.replace(temporary, config)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(f"Codex MCP migration failed ({type(error).__name__}); config left unchanged") from None
