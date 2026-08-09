#!/usr/bin/env python3
"""Generate and submit owner-reviewed Buzz snapshots for the aidevops team."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile

from _team_interface_buzz_avatar import member_avatar_data_url


SCRIPT_DIR = Path(__file__).resolve().parent
ROSTER_SCRIPT = SCRIPT_DIR / "team-interface-agent-roster.py"
DEFAULT_AGENTS_DIR = "~/.aidevops/agents"
TEAM_NAME = "AI DevOps"
GUIDE_AGENT_ID = "agent.aidevops-guide"
BUZZ_TEAM_FORMAT = "buzz-team-snapshot"
BUZZ_AGENT_FORMAT = "buzz-agent-snapshot"
FORMAT_VERSION = 1
CLI_TIMEOUT_SECONDS = 30
MAX_SNAPSHOT_BYTES = 5 * 1024 * 1024
AIDEVOPS_RUNTIME_ID = "aidevops-interactive-v1"
PRIVATE_AGENT_ID = "agent.private-local-ai"
PRIVATE_RUNTIME_ID = "buzz-agent"
PRIVATE_PROVIDER_ID = "relay-mesh"
PRIVATE_MODEL_ID = "auto"
MAX_HOST_SLUG_LENGTH = 64
HOST_SLUG_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$")


class ProvisioningError(ValueError):
    """Raised when a safe deterministic provisioning step cannot continue."""


def load_roster_module():
    """Load the canonical roster implementation from its registered script."""
    spec = importlib.util.spec_from_file_location("aidevops_agent_roster", ROSTER_SCRIPT)
    if spec is None or spec.loader is None:
        raise ProvisioningError("canonical agent roster generator is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def normalize_slug(value, label, maximum_length):
    """Normalize one local presentation component to lowercase ASCII dashes."""
    if not isinstance(value, str):
        raise ProvisioningError(f"{label} must be a string")
    slug = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")
    if not slug or len(slug) > maximum_length or not HOST_SLUG_PATTERN.fullmatch(slug):
        raise ProvisioningError(f"{label} is unavailable or invalid")
    return slug


def resolve_host_slug(configured=None):
    """Resolve the explicit or local host identity used in portable display names."""
    candidate = configured or os.environ.get("AIDEVOPS_BUZZ_HOST_SLUG")
    if not candidate and sys.platform == "darwin":
        try:
            result = subprocess.run(  # nosec B603 -- absolute executable and fixed argv
                ["/usr/sbin/scutil", "--get", "LocalHostName"],
                check=False,
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
        except (OSError, subprocess.TimeoutExpired):
            result = None
        if result is not None and result.returncode == 0:
            candidate = result.stdout.strip()
    if not candidate:
        candidate = socket.gethostname()
    return normalize_slug(candidate, "Buzz host slug", MAX_HOST_SLUG_LENGTH)


def agent_role_slug(record):
    """Return the stable lowercase role component for one roster record."""
    if record["agent_id"] == GUIDE_AGENT_ID:
        return "aidevops"
    prefix = "agent."
    agent_id = record["agent_id"]
    if not agent_id.startswith(prefix):
        raise ProvisioningError(f"agent ID cannot produce a Buzz role slug: {agent_id}")
    return normalize_slug(agent_id.removeprefix(prefix), "Buzz role slug", 32)


def buzz_display_name(record, host_slug):
    """Map one portable roster record to its host-qualified Buzz name."""
    display_name = f"{agent_role_slug(record)}-{host_slug}"
    if len(display_name) > 100:
        raise ProvisioningError("host-qualified Buzz display name exceeds 100 characters")
    return display_name


def member_system_prompt(record):
    """Build a pointer prompt without copying canonical instruction bodies."""
    if record["agent_id"] == PRIVATE_AGENT_ID:
        return "\n".join(
            (
                f"Aidevops canonical source: {record['source_ref']}",
                f"Expected source digest: {record['source_digest']}",
                f"Portable workload tier: {record['workload_tier']}",
                "You are Private AI, a private investigator using privacy-first AI methods.",
                "Minimize data disclosure; separate facts, inferences, and uncertainty; "
                "never expose credentials or unrelated personal data.",
                "Do not describe Buzz shared compute as local, private, or on-device unless "
                "the active execution boundary independently verifies that claim.",
                "This portable definition grants no authority and carries no credentials.",
            )
        )
    return "\n".join(
        (
            f"Aidevops canonical source: {record['source_ref']}",
            f"Expected source digest: {record['source_digest']}",
            f"Portable workload tier: {record['workload_tier']}",
            "Resolve and verify that installed aidevops source through the supported "
            "aidevops conversation runtime before handling a request.",
            "If the source is unavailable or its digest differs, stop and report that "
            "the runtime is not configured for this agent.",
            "Follow the verified source as this agent's instructions. This portable "
            "definition grants no authority and carries no credentials.",
        )
    )


def build_member(record, host_slug):
    """Build one dormant Buzz agent snapshot member with reviewed routing."""
    display_name = buzz_display_name(record, host_slug)
    definition = {
        "name": display_name,
        "parallelism": 1,
        "respondTo": "owner-only",
        "runtime": AIDEVOPS_RUNTIME_ID,
        "sourceIsBuiltin": False,
        "systemPrompt": member_system_prompt(record),
    }
    if record["agent_id"] == PRIVATE_AGENT_ID:
        definition.update(
            {
                "model": PRIVATE_MODEL_ID,
                "provider": PRIVATE_PROVIDER_ID,
                "runtime": PRIVATE_RUNTIME_ID,
            }
        )
    return {
        "definition": definition,
        "format": BUZZ_AGENT_FORMAT,
        "memory": {"level": "none"},
        "profile": {
            "about": record["description"],
            "avatarDataUrl": member_avatar_data_url(record),
            "displayName": display_name,
        },
        "version": FORMAT_VERSION,
    }


def build_team_snapshot(agents_dir, host_slug=None):
    """Resolve the canonical roster and build one deterministic team snapshot."""
    resolved_host_slug = resolve_host_slug(host_slug)
    roster_module = load_roster_module()
    roster = roster_module.build_roster(agents_dir)
    guide_count = sum(record["agent_id"] == GUIDE_AGENT_ID for record in roster["agents"])
    if guide_count != 1:
        raise ProvisioningError("canonical roster must contain exactly one aidevops framework guide")
    private_count = sum(record["agent_id"] == PRIVATE_AGENT_ID for record in roster["agents"])
    if private_count != 1:
        raise ProvisioningError("canonical roster must contain exactly one Private AI member")

    display_names = [buzz_display_name(record, resolved_host_slug) for record in roster["agents"]]
    if len(display_names) != len(set(display_names)):
        raise ProvisioningError("canonical roster contains duplicate Buzz display names")

    records = sorted(
        roster["agents"],
        key=lambda record: (buzz_display_name(record, resolved_host_slug), record["agent_id"]),
    )
    return {
        "format": BUZZ_TEAM_FORMAT,
        "members": [build_member(record, resolved_host_slug) for record in records],
        "team": {
            "description": "Canonical aidevops specialists generated from the installed roster.",
            "instructions": (
                "Keep members stopped until each uses its reviewed runtime. Standard members "
                "require the full interactive aidevops runtime with current source-digest "
                "verification, isolated persistent worktree and session storage, and Buzz "
                "credential separation. Private AI uses reviewed Buzz shared-compute routing, "
                "which does not prove local or on-device execution. Buzz access policy controls "
                "ingress; aidevops security, approval, destructive-operation, publication, and "
                "release rules remain authoritative."
            ),
            "name": TEAM_NAME,
        },
        "version": FORMAT_VERSION,
    }


def serialized_snapshot(snapshot):
    """Return stable pretty-printed UTF-8 JSON bytes."""
    payload = (json.dumps(snapshot, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    if len(payload) > MAX_SNAPSHOT_BYTES:
        raise ProvisioningError("generated Buzz team snapshot exceeds the 5 MiB decoded limit")
    return payload


def validate_output_path(output_path, agents_dir):
    """Validate an explicit caller-owned output without following a target symlink."""
    expanded = Path(os.path.expanduser(output_path))
    if expanded.is_symlink():
        raise ProvisioningError("output must not replace a symbolic link")
    parent = expanded.parent.resolve()
    if not parent.is_dir():
        raise ProvisioningError("output parent directory is unavailable")
    resolved = parent / expanded.name
    load_roster_module().ensure_output_is_not_source(resolved, agents_dir)
    return resolved


def atomic_write(output_path, payload):
    """Atomically replace one explicit output with an owner-only regular file."""
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output_path.name}.", dir=output_path.parent)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        descriptor = -1
        os.replace(temporary_path, output_path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary_path.unlink(missing_ok=True)


def resolve_buzz_cli():
    """Resolve the Buzz CLI from a trusted absolute override or current PATH."""
    configured = os.environ.get("AIDEVOPS_BUZZ_CLI")
    if configured:
        candidate = Path(os.path.expanduser(configured))
        if not candidate.is_absolute():
            raise ProvisioningError("AIDEVOPS_BUZZ_CLI must be an absolute path")
        try:
            metadata = candidate.lstat()
        except OSError as error:
            raise ProvisioningError("configured Buzz CLI is unavailable") from error
        if not stat.S_ISREG(metadata.st_mode) or candidate.is_symlink() or not os.access(candidate, os.X_OK):
            raise ProvisioningError("configured Buzz CLI must be an executable non-symlink file")
        return str(candidate)

    candidate = shutil.which("buzz")
    if not candidate:
        raise ProvisioningError("Buzz CLI is unavailable; install the broker-enabled Buzz build first")
    return candidate


def run_buzz_cli(cli, arguments):
    """Run one fixed-argv local Buzz Desktop broker command with a bounded wait."""
    try:
        result = subprocess.run(  # nosec B603 -- executable and argv validated by caller
            [cli, *arguments], check=False, timeout=CLI_TIMEOUT_SECONDS
        )
    except subprocess.TimeoutExpired as error:
        raise ProvisioningError("Buzz Desktop broker command timed out") from error
    if result.returncode != 0:
        raise ProvisioningError(f"Buzz Desktop broker command failed with exit {result.returncode}")


def require_private_temp_root():
    """Create or validate the private aidevops temporary root used for submission."""
    configured = os.environ.get(
        "AIDEVOPS_TEMP_DIR",
        str(Path.home() / ".aidevops" / ".agent-workspace" / "tmp"),
    )
    root = Path(os.path.expanduser(configured))
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = root.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or root.is_symlink():
        raise ProvisioningError("aidevops temporary root must be a non-symlink directory")
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) & 0o077:
        raise ProvisioningError("aidevops temporary root must be current-user-owned and mode 700")
    return root


def submit_snapshot(agents_dir, host_slug=None):
    """Queue one generated snapshot for explicit owner review in Buzz Desktop."""
    payload = serialized_snapshot(build_team_snapshot(agents_dir, host_slug))
    cli = resolve_buzz_cli()
    run_buzz_cli(cli, ["desktop", "status"])
    temp_root = require_private_temp_root()
    with tempfile.TemporaryDirectory(prefix="buzz-team-draft-", dir=temp_root) as temporary:
        temporary_path = Path(temporary)
        temporary_path.chmod(0o700)
        snapshot_path = temporary_path / "aidevops.team.json"
        atomic_write(snapshot_path, payload)
        run_buzz_cli(cli, ["desktop", "agents", "import-team-draft", str(snapshot_path)])


def parse_args(argv=None):
    """Parse the bounded provisioning command line."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    generate = commands.add_parser("generate", help="generate a deterministic team snapshot")
    generate.add_argument("--agents-dir", default=DEFAULT_AGENTS_DIR)
    generate.add_argument("--host-slug")
    generate.add_argument("--output", help="optional atomic mode-600 output path")

    commands.add_parser("status", help="check the local Buzz Desktop broker")

    submit = commands.add_parser("submit", help="queue a generated snapshot for Desktop review")
    submit.add_argument("--agents-dir", default=DEFAULT_AGENTS_DIR)
    submit.add_argument("--host-slug")
    return parser.parse_args(argv)


def main(argv=None):
    """Generate a snapshot, check the broker, or queue an owner-reviewed draft."""
    args = parse_args(argv)
    if args.command == "status":
        run_buzz_cli(resolve_buzz_cli(), ["desktop", "status"])
        return 0

    agents_dir = Path(os.path.expanduser(args.agents_dir)).resolve()
    if not agents_dir.is_dir():
        raise ProvisioningError(f"agents directory does not exist: {args.agents_dir}")

    if args.command == "submit":
        submit_snapshot(agents_dir, args.host_slug)
        return 0

    payload = serialized_snapshot(build_team_snapshot(agents_dir, args.host_slug))
    if args.output:
        output_path = validate_output_path(args.output, agents_dir)
        atomic_write(output_path, payload)
        return 0
    sys.stdout.buffer.write(payload)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ProvisioningError, ValueError) as error:
        print(f"team-interface-buzz-team-snapshot: {error}", file=sys.stderr)
        raise SystemExit(1) from error
