#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Reconcile known Codex MCP defaults without rewriting unrelated TOML."""

import argparse
import copy
import os
from pathlib import Path
import stat
import tempfile

from lib.codex_mcp_toml import render, tomllib

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


def migrate_npx(name, server, messages):
    if Path(server.get("command", "")).name not in ("npx", "npx.cmd"):
        return
    args = server.get("args", [])
    if name == "playwright" and known_package(args, "@anthropic-ai/mcp-server-playwright"):
        args = [
            "@playwright/mcp@0.0.79"
            if arg.startswith("@anthropic-ai/mcp-server-playwright") else arg
            for arg in args
        ]
        server["args"] = args
        messages.append("playwright: replaced nonexistent legacy npm package")
    if name not in NPX_PACKAGES or not known_package(args, NPX_PACKAGES[name]):
        return
    if "-y" not in args and "--yes" not in args:
        server["args"] = ["-y", *args]
    if "startup_timeout_sec" not in server and "startup_timeout_ms" not in server:
        server["startup_timeout_sec"] = 60
        messages.append(f"{name}: allow 60 seconds for npm cold start")


def migrate_remote(name, server, messages):
    if name not in DEFAULTS or "url" not in server:
        return
    if server["url"] != DEFAULTS[name].get("url"):
        return
    if server.get("type") == "url":
        del server["type"]
    # Old setup implicitly enabled OAuth without login. Preserve explicit choices.
    if name == "cloudflare-api" and "enabled" not in server:
        server["enabled"] = False
        messages.append("cloudflare-api: disabled pending explicit OAuth setup")


def migrate_unavailable(name, server, messages):
    if not server.get("enabled", True):
        return
    command = server.get("command", "")
    if name == "auggie-mcp" and Path(command).name == "auggie":
        if server.get("args") == ["--mcp"]:
            server["enabled"] = False
            messages.append("auggie-mcp: disabled deprecated integration")
    if name != "node_repl" or not command.startswith("/Applications/"):
        return
    if command.endswith("/cua_node/bin/node_repl") and not os.path.isfile(command):
        server["enabled"] = False
        messages.append("node_repl: disabled stale app executable; reinstall via the app")


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
        migrate_npx(name, server, messages)
        migrate_remote(name, server, messages)
        migrate_unavailable(name, server, messages)
    return desired, messages


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
