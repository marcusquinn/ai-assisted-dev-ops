# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validated, minimally invasive TOML field edits for Codex MCP migration."""

import json
import re

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        raise SystemExit("Codex MCP migration requires Python 3.11+ or tomli; config unchanged") from None


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
