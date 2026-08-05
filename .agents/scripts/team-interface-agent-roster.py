#!/usr/bin/env python3
"""Generate the provider-neutral aidevops agent roster."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))

from agent_config import WORKLOAD_TIERS, iter_primary_agent_sources  # noqa: E402
from discovery_utils import atomic_json_write, parse_frontmatter  # noqa: E402


AGENT_NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
SOURCE_FILENAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.md$")
DIGEST_PREFIX = "sha256:"
DOCUMENT_TYPE = "agent_roster"
ROSTER_ID = "agent-roster.aidevops"
SCHEMA_VERSION = 1


class RosterError(ValueError):
    """Raised when source metadata cannot produce a safe portable roster."""


def canonical_bytes(value):
    """Return compact canonical JSON bytes for hashing."""
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def canonical_order(value):
    """Recursively order mappings before stdout or atomic JSON serialization."""
    if isinstance(value, dict):
        return {key: canonical_order(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        return [canonical_order(item) for item in value]
    return value


def sha256_bytes(value):
    """Return a tagged SHA-256 digest for bytes."""
    return DIGEST_PREFIX + hashlib.sha256(value).hexdigest()


def require_string(value, label):
    """Return a stripped non-empty string or raise a source error."""
    if not isinstance(value, str) or not value.strip():
        raise RosterError(f"{label} must be a non-empty string")
    return value.strip()


def source_ref(filename):
    """Build a deployment-relative registered source reference."""
    if Path(filename).name != filename or not SOURCE_FILENAME_PATTERN.fullmatch(filename):
        raise RosterError(f"source filename is not relative and registered: {filename}")
    return f"agents:{filename}"


def source_record(record, kind="primary", agent_id=None, display_name=None):
    """Convert one discovered source into a portable roster record."""
    if not record["name_explicit"]:
        raise RosterError(f"{record['filename']} is missing explicit frontmatter name")

    source_name = require_string(record["source_name"], f"{record['filename']} name")
    if not AGENT_NAME_PATTERN.fullmatch(source_name):
        raise RosterError(f"{record['filename']} has invalid agent name: {source_name}")

    tier = record["workload_tier"] or "standard"
    if tier not in WORKLOAD_TIERS:
        raise RosterError(f"{record['filename']} has non-canonical workload tier: {tier}")

    description = require_string(
        record["frontmatter"].get("description"),
        f"{record['filename']} description",
    )
    if len(description) > 1000:
        raise RosterError(f"{record['filename']} description exceeds 1000 characters")
    resolved_display_name = display_name or record["display_name"]
    if not isinstance(resolved_display_name, str) or not 1 <= len(resolved_display_name) <= 100:
        raise RosterError(f"{record['filename']} display name must contain 1-100 characters")
    path = Path(record["path"])
    try:
        content = path.read_bytes()
    except OSError as error:
        raise RosterError(f"cannot read source {record['filename']}: {error.strerror}") from error

    return {
        "agent_id": agent_id or f"agent.{source_name}",
        "description": description,
        "display_name": resolved_display_name,
        "kind": kind,
        "source_digest": sha256_bytes(content),
        "source_ref": source_ref(record["filename"]),
        "workload_tier": tier,
    }


def framework_guide_record(agents_dir):
    """Load the separately registered aidevops framework guide."""
    guide_path = agents_dir / "aidevops.md"
    if not guide_path.is_file():
        raise RosterError("aidevops.md framework guide is missing")
    frontmatter = parse_frontmatter(str(guide_path))
    name = frontmatter.get("name")
    record = {
        "path": str(guide_path),
        "filename": guide_path.name,
        "frontmatter": frontmatter,
        "source_name": name,
        "name_explicit": bool(name),
        "display_name": "AI DevOps",
        "subagents": frontmatter.get("subagents"),
        "workload_tier": frontmatter.get("model"),
    }
    return source_record(
        record,
        kind="framework_guide",
        agent_id="agent.aidevops-guide",
        display_name="AI DevOps",
    )


def validate_unique_ids(records):
    """Reject duplicate stable IDs before serializing a roster."""
    seen = set()
    for record in records:
        agent_id = record["agent_id"]
        if agent_id in seen:
            raise RosterError(f"duplicate agent ID: {agent_id}")
        seen.add(agent_id)


def build_roster(agents_dir):
    """Build and validate one deterministic roster document."""
    records = [
        source_record(record)
        for record in iter_primary_agent_sources(str(agents_dir))
    ]
    records.append(framework_guide_record(agents_dir))
    if len(records) < 2:
        raise RosterError("roster requires at least one primary agent and the framework guide")
    validate_unique_ids(records)

    unsigned_document = {
        "agents": records,
        "document_type": DOCUMENT_TYPE,
        "roster_id": ROSTER_ID,
        "schema_version": SCHEMA_VERSION,
    }
    document = {
        **unsigned_document,
        "roster_digest": sha256_bytes(canonical_bytes(unsigned_document)),
    }
    return canonical_order(document)


def ensure_output_is_not_source(output_path, agents_dir):
    """Prevent explicit output from replacing a canonical Markdown source."""
    resolved_output = output_path.resolve()
    for source in agents_dir.glob("*.md"):
        if resolved_output == source.resolve():
            raise RosterError(f"output path aliases agent source: {source.name}")


def parse_args(argv=None):
    """Parse the bounded roster command line."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--agents-dir",
        default="~/.aidevops/agents",
        help="canonical agent source directory",
    )
    parser.add_argument("--format", choices=("json",), default="json")
    parser.add_argument("--output", help="optional atomic JSON output path")
    return parser.parse_args(argv)


def main(argv=None):
    """Generate stdout JSON or atomically replace an explicit output file."""
    args = parse_args(argv)
    agents_dir = Path(os.path.expanduser(args.agents_dir)).resolve()
    if not agents_dir.is_dir():
        raise RosterError(f"agents directory does not exist: {args.agents_dir}")

    document = build_roster(agents_dir)
    if args.output:
        output_path = Path(os.path.expanduser(args.output))
        ensure_output_is_not_source(output_path, agents_dir)
        atomic_json_write(str(output_path), document, indent=2, trailing_newline=True)
        return 0

    json.dump(document, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RosterError as error:
        print(f"team-interface-agent-roster: {error}", file=sys.stderr)
        raise SystemExit(1) from error
