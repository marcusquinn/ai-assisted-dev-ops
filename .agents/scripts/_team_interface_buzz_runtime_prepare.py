"""Owner-only Buzz environment preparation for one trusted ACP process."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import hashlib
import importlib.util
import os
from pathlib import Path
import re
import secrets

from _team_interface_buzz_runtime_io import RuntimeError, atomic_write, canonical_payload


SCRIPT_DIR = Path(__file__).resolve().parent
ROSTER_SCRIPT = SCRIPT_DIR / "team-interface-agent-roster.py"
SNAPSHOT_SCRIPT = SCRIPT_DIR / "team-interface-buzz-team-snapshot.py"
NONCE_PATTERN = re.compile(r"^[a-f0-9]{32}$")


def load_module(name, source, unavailable_message):
    """Load one registered team-interface Python module."""
    spec = importlib.util.spec_from_file_location(name, source)
    if spec is None or spec.loader is None:
        raise RuntimeError(unavailable_message)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def hash_ref(*values):
    """Return a non-reversible bounded correlation token."""
    return hashlib.sha256("\0".join(values).encode("utf-8")).hexdigest()[:32]


def select_agent(roster, display_name, snapshot_module, host_slug):
    """Map Buzz presentation metadata to exactly one canonical roster entry."""
    matches = [
        record
        for record in roster["agents"]
        if snapshot_module.buzz_display_name(record, host_slug) == display_name
    ]
    if len(matches) != 1:
        raise RuntimeError("Buzz display name does not select exactly one canonical aidevops agent")
    return matches[0]


def require_buzz_environment():
    """Validate the owner-only Buzz process evidence used to create an overlay."""
    display_name = os.environ.get("BUZZ_ACP_DISPLAY_NAME", "").strip()
    managed_instance = os.environ.get("BUZZ_MANAGED_AGENT", "").strip()
    start_nonce = os.environ.get("BUZZ_MANAGED_AGENT_START_NONCE", "").strip()
    relay_url = os.environ.get("BUZZ_RELAY_URL", "").strip()
    if not display_name or len(display_name) > 100:
        raise RuntimeError("BUZZ_ACP_DISPLAY_NAME is missing or invalid")
    if not managed_instance or len(managed_instance) > 300:
        raise RuntimeError("BUZZ_MANAGED_AGENT is missing or invalid")
    if not NONCE_PATTERN.fullmatch(start_nonce):
        raise RuntimeError("BUZZ_MANAGED_AGENT_START_NONCE is missing or invalid")
    if not relay_url.startswith(("wss://", "ws://")) or len(relay_url) > 2048:
        raise RuntimeError("BUZZ_RELAY_URL is missing or invalid")
    if os.environ.get("BUZZ_ACP_RESPOND_TO") != "owner-only":
        raise RuntimeError("Buzz agent is not restricted to owner-only messages")
    allowed = os.environ.get("BUZZ_ACP_ALLOWED_RESPOND_TO")
    if allowed and allowed != "owner-only":
        raise RuntimeError("Buzz build policy permits a wider response scope")
    return display_name, managed_instance, start_nonce, relay_url


def prepare_runtime(agents_dir, output_dir):
    """Create private roster/context inputs for one trusted ACP process."""
    if output_dir.is_symlink() or not output_dir.is_dir():
        raise RuntimeError("runtime output directory must be a non-symlink directory")
    display_name, managed_instance, start_nonce, relay_url = require_buzz_environment()
    roster_module = load_module(
        "aidevops_agent_roster",
        ROSTER_SCRIPT,
        "canonical agent roster generator is unavailable",
    )
    snapshot_module = load_module(
        "aidevops_buzz_snapshot",
        SNAPSHOT_SCRIPT,
        "canonical Buzz snapshot generator is unavailable",
    )
    roster = roster_module.build_roster(agents_dir)
    host_slug = snapshot_module.resolve_host_slug()
    agent = select_agent(roster, display_name, snapshot_module, host_slug)
    if os.environ.get("BUZZ_ACP_SYSTEM_PROMPT") != snapshot_module.member_system_prompt(agent):
        raise RuntimeError("Buzz agent source pointer or digest does not match the canonical roster")
    scope = hash_ref(
        managed_instance,
        start_nonce,
        display_name,
        relay_url,
        secrets.token_hex(16),
    )
    owner = os.environ.get("BUZZ_ACP_AGENT_OWNER", "buzz-owner")
    context = {
        "actor_ref": f"actor:{hash_ref(owner, scope)}",
        "app_team_ref": "app-team:ai-devops",
        "community_ref": f"community:{hash_ref(relay_url)}",
        "conversation_ref": f"conversation:buzz-runtime-{scope}",
        "correlation_ref": f"correlation:buzz-runtime-{scope}",
        "provider_ref": "provider:buzz",
        "trust_ref": "trust:buzz-owner-only",
    }
    atomic_write(output_dir / "roster.json", canonical_payload(roster))
    atomic_write(output_dir / "context.json", canonical_payload(context))
    atomic_write(output_dir / "agent-id.txt", f"{agent['agent_id']}\n".encode("utf-8"))
    atomic_write(output_dir / "host-slug.txt", f"{host_slug}\n".encode("utf-8"))
