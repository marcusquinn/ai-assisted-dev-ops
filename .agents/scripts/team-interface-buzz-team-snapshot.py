#!/usr/bin/env python3
"""Generate the immutable owner-reviewed Buzz team import snapshot."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_AGENTS_DIR = SCRIPT_DIR.parent
ROSTER_SCRIPT = SCRIPT_DIR / "team-interface-agent-roster.py"
DIGEST_PREFIX = "sha256:"
PRIVATE_AGENT_ID = "agent.private-local-ai"
INTERACTIVE_RUNTIME_ID = "aidevops-interactive-v1"


class SnapshotError(ValueError):
    """Raised when the canonical roster cannot create a safe Buzz import."""


def canonical_json(value):
    """Return compact canonical JSON for content-addressed records."""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def digest(value):
    """Return a tagged SHA-256 digest for canonical JSON content."""
    return (
        DIGEST_PREFIX
        + hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()
    )


def load_roster(agents_dir):
    """Run the canonical roster producer rather than duplicating source discovery."""
    result = subprocess.run(
        [sys.executable, str(ROSTER_SCRIPT), "--agents-dir", str(agents_dir)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SnapshotError("canonical agent roster generation failed")
    try:
        roster = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise SnapshotError("canonical agent roster is not valid JSON") from error
    if not isinstance(roster, dict) or not isinstance(roster.get("agents"), list):
        raise SnapshotError("canonical agent roster has no agent collection")
    return roster


def require_agent_value(agent, name):
    """Read one bounded canonical agent field without accepting absent values."""
    value = agent.get(name)
    if not isinstance(value, str) or not value:
        raise SnapshotError(f"canonical agent is missing {name}")
    return value


def base_member(agent):
    """Create the shared immutable import record for one canonical agent."""
    member = {
        "agent_id": require_agent_value(agent, "agent_id"),
        "display_name": require_agent_value(agent, "display_name"),
        "runtime": INTERACTIVE_RUNTIME_ID,
        "source_digest": require_agent_value(agent, "source_digest"),
        "source_ref": require_agent_value(agent, "source_ref"),
    }
    member["runtime_anchor"] = digest(
        {
            "agent_id": member["agent_id"],
            "runtime": member["runtime"],
            "source_digest": member["source_digest"],
            "source_ref": member["source_ref"],
        }
    )
    return member


def private_member(agent):
    """Add the sole provider-specific import profile without changing other members."""
    member = base_member(agent)
    member.update(
        {
            "agent_kind": "Buzz Agent",
            "investigator_profile": "private_ai_investigator_v1",
            "max_parallelism": 1,
            "model": "auto",
            "portable_memory": False,
            "provider": "relay-mesh",
            "response_policy": "owner_only",
        }
    )
    return member


def build_snapshot(agents_dir):
    """Build a deterministic create-only owner-review snapshot from source digests."""
    roster = load_roster(agents_dir)
    agents = roster["agents"]
    ids = [require_agent_value(agent, "agent_id") for agent in agents]
    if len(ids) != len(set(ids)):
        raise SnapshotError("canonical agent roster contains duplicate agent IDs")
    if ids.count(PRIVATE_AGENT_ID) != 1:
        raise SnapshotError(
            "canonical agent roster must contain exactly one private-local-ai agent"
        )

    members = []
    for agent in sorted(agents, key=lambda item: item["agent_id"]):
        member = (
            private_member(agent)
            if agent["agent_id"] == PRIVATE_AGENT_ID
            else base_member(agent)
        )
        members.append(member)
    if len(members) != 15:
        raise SnapshotError(
            "Buzz team snapshot must contain exactly fifteen canonical members"
        )

    unsigned = {
        "document_type": "buzz_team_import_snapshot",
        "import_mode": "owner_reviewed_create_only",
        "members": members,
        "roster_digest": require_agent_value(roster, "roster_digest"),
        "roster_id": require_agent_value(roster, "roster_id"),
        "schema_version": 1,
        "team_id": "team.aidevops",
    }
    return {**unsigned, "snapshot_digest": digest(unsigned)}


def atomic_write(output_path, content):
    """Atomically write an explicit snapshot artifact without replacing a source file."""
    output_path = output_path.resolve()
    if output_path.is_symlink() or not output_path.parent.is_dir():
        raise SnapshotError("snapshot output path is unsafe")
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=output_path.parent,
        prefix=f".{output_path.name}.",
        delete=False,
    ) as temporary:
        temporary.write(content)
        temporary.flush()
        temporary_path = Path(temporary.name)
    temporary_path.chmod(0o600)
    temporary_path.replace(output_path)


def parse_args(argv=None):
    """Parse the bounded snapshot generator arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agents-dir", default=str(DEFAULT_AGENTS_DIR))
    parser.add_argument("--output")
    return parser.parse_args(argv)


def main(argv=None):
    """Write canonical snapshot JSON to stdout or one explicit output file."""
    args = parse_args(argv)
    agents_dir = Path(args.agents_dir).expanduser().resolve()
    if not agents_dir.is_dir():
        raise SnapshotError("canonical agents directory is unavailable")
    document = build_snapshot(agents_dir)
    content = f"{json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True)}\n"
    if args.output:
        atomic_write(Path(args.output), content)
    else:
        sys.stdout.write(content)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SnapshotError as error:
        print(f"team-interface-buzz-team-snapshot: {error}", file=sys.stderr)
        raise SystemExit(1) from error
