"""Secret-negative OpenCode config pinning for Buzz runtime anchors."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import hashlib
import json
from pathlib import Path
import re

from _team_interface_buzz_runtime_io import (
    RuntimeError,
    atomic_write,
    canonical_payload,
    command_payloads,
    hash_file_into,
    hash_runtime_tree,
)


SENSITIVE_CONFIG_KEY_PATTERN = re.compile(
    r"(?:api[_-]?key|access[_-]?(?:key|token)|auth[_-]?token|bearer[_-]?token|client[_-]?secret|private[_-]?key|refresh[_-]?token|secret[_-]?access[_-]?key|session[_-]?token|(?:encryption|service[_-]?account|signing|webhook)[_-]?key|password|passwd|secret|credentials?|authorization|cookie)$",
    re.IGNORECASE,
)
SENSITIVE_EXACT_CONFIG_KEYS = {"auth", "bearer", "key", "token"}
PRIVATE_CONTAINER_KEYS = {"env", "environment", "headers"}


def config_key_is_private(key):
    """Return whether one config key can directly or indirectly carry credentials."""
    key_text = str(key)
    return (
        key_text.casefold() in SENSITIVE_EXACT_CONFIG_KEYS
        or key_text.casefold() in PRIVATE_CONTAINER_KEYS
        or SENSITIVE_CONFIG_KEY_PATTERN.search(key_text) is not None
    )


def sanitize_opencode_config(value, path=()):
    """Remove persisted credential material from a private OpenCode config."""
    if isinstance(value, list):
        return [sanitize_opencode_config(item, path) for item in value]
    if not isinstance(value, dict):
        return value
    sanitized = {}
    for key, item in value.items():
        key_text = str(key)
        if config_key_is_private(key_text):
            continue
        sanitized[key] = sanitize_opencode_config(item, (*path, key_text))
    return sanitized


def load_sanitized_opencode_config(source):
    """Load and structurally sanitize the OpenCode config selected for pinning."""
    try:
        config = json.loads((source / "opencode.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError("OpenCode config is unavailable or invalid for runtime pinning") from error
    if not isinstance(config, dict):
        raise RuntimeError("OpenCode config must be a JSON object for runtime pinning")
    return sanitize_opencode_config(config)


def config_contains_private_fields(value, path=()):
    """Return whether a pinned config still contains a credential-bearing field."""
    if isinstance(value, list):
        found = any(config_contains_private_fields(item, path) for item in value)
    elif not isinstance(value, dict):
        found = False
    else:
        found = False
        for key, item in value.items():
            key_text = str(key)
            if (
                config_key_is_private(key_text)
                or config_contains_private_fields(item, (*path, key_text))
            ):
                found = True
                break
    return found


def hash_opencode_config(source):
    """Hash only sanitized OpenCode config state and copied generated commands."""
    digest = hashlib.sha256()
    digest.update(canonical_payload(load_sanitized_opencode_config(source)))
    command = source / "command"
    if command.exists():
        if command.is_symlink():
            raise RuntimeError("OpenCode config pin source must not be a symbolic link")
        if command.is_file():
            digest.update(b"command\0")
            hash_file_into(digest, command)
        else:
            digest.update(hash_runtime_tree(command).encode("ascii"))
    return digest.hexdigest()


def replace_agents_references(value, source_agents, pinned_agents):
    """Rewrite config references from mutable agent links to the pinned bundle."""
    replacements = (
        (str(Path.home() / ".aidevops" / "agents"), str(pinned_agents)),
        (str(source_agents), str(pinned_agents)),
        ("~/.aidevops/agents", str(pinned_agents)),
    )
    if isinstance(value, str):
        for old, new in replacements:
            value = value.replace(old, new)
        return value
    if isinstance(value, list):
        return [replace_agents_references(item, source_agents, pinned_agents) for item in value]
    if isinstance(value, dict):
        return {
            replace_agents_references(key, source_agents, pinned_agents): replace_agents_references(
                item, source_agents, pinned_agents
            )
            for key, item in value.items()
        }
    return value


def pinned_opencode_config(source, source_agents, pinned_agents):
    """Build the expected secret-negative OpenCode config for one anchor."""
    config = replace_agents_references(
        load_sanitized_opencode_config(source), source_agents, pinned_agents
    )
    source_plugin = source_agents / "plugins" / "opencode-aidevops" / "index.mjs"
    if source_plugin.is_symlink() or not source_plugin.is_file():
        raise RuntimeError("pinned aidevops OpenCode plugin is unavailable")
    config["plugin"] = [
        (pinned_agents / "plugins" / "opencode-aidevops" / "index.mjs").as_uri()
    ]
    return config


def expected_command_payloads(source, source_agents, pinned_agents):
    """Rewrite expected command payloads to the immutable agent bundle."""
    return {
        relative: replace_agents_references(payload, source_agents, pinned_agents)
        for relative, payload in command_payloads(source).items()
    }


def pinned_content_digest(agents_digest, config, commands):
    """Hash the exact agent, dependency, config, and command anchor contract."""
    digest = hashlib.sha256()
    digest.update(agents_digest.encode("ascii"))
    digest.update(b"\0opencode.json\0")
    digest.update(canonical_payload(config))
    for relative, payload in sorted(commands.items()):
        digest.update(b"\0command/")
        digest.update(relative.as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(payload.encode("utf-8"))
    return digest.hexdigest()


def write_pinned_opencode_config(destination, config, commands):
    """Write one prevalidated immutable OpenCode config contract."""
    destination.mkdir(mode=0o700, parents=True)
    atomic_write(destination / "opencode.json", canonical_payload(config))
    for relative, payload in commands.items():
        command_path = destination / "command" / relative
        command_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        atomic_write(command_path, payload.encode("utf-8"))
