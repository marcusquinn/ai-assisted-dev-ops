# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Auditable, tracked-source inventory for the README's four public categories."""

import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from agent_config import SKIP_FILES
from discovery_utils import parse_frontmatter

KEYS = ("main_agents", "subagents", "scripts", "slash_commands")
LABELS = ("main agents", "sub agents", "helper scripts", "slash commands")
AGENT_DIRS = {
    "aidevops",
    "business",
    "content",
    "health",
    "legal",
    "marketing-sales",
    "product",
    "public-relations",
    "reports",
    "research",
    "seo",
    "services",
    "tools",
    "vault",
}
EXCLUDED_PARTS = {
    "tests",
    "test",
    "fixtures",
    "node_modules",
    "vendor",
    "vendored",
    "custom",
    "draft",
    "loop-state",
    "__pycache__",
}
PROFILE_EXCLUSIONS = {
    "references",
    "reference",
    "templates",
    "skills",
    "workflows",
    "docs",
    "documentation",
}
HELPER_NAME = re.compile(r".+-helper\.(?:sh|bash|py|mjs|js|ts|rb|pl|ps1)$")
DEFINITIONS = {
    "main_agents": "Root agent profiles eligible under agent_config.SKIP_FILES.",
    "subagents": "Explicit mode: subagent profiles in agent-source directories, "
    "plus demoted root profiles; excludes skills, documentation-only directories, "
    "tests, templates, and symlink aliases.",
    "scripts": "Named *-helper entry points in .agents/scripts across supported "
    "script languages; excludes tests, fixtures, aliases, and implementation modules.",
    "slash_commands": "Markdown entry points directly in scripts/commands; "
    "symlinks must resolve to tracked regular files inside .agents.",
}


def tracked_sources(root):
    """Select index paths; count their current worktree contents, not untracked files."""
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--stage", "-z", "--", ".agents"],
        check=True,
        capture_output=True,
        text=True,
    )
    entries = {}
    for entry in result.stdout.split("\0"):
        if not entry:
            continue
        metadata, name = entry.split("\t", 1)
        mode, _oid, stage = metadata.split()
        if stage != "0":
            raise ValueError("Resolve index conflicts before counting sources")
        entries[name] = mode
    if not entries:
        raise ValueError("No tracked .agents sources found")
    return entries


def source_path(root, name):
    """Do not read an external target even if a tracked path was replaced locally."""
    path = root / name
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(root / ".agents"):
        raise ValueError(f"Source escapes .agents: {name}")
    return path


def is_profile_location(path):
    parts = path.parts
    if len(parts) < 3 or parts[1] not in AGENT_DIRS:
        return False
    if PROFILE_EXCLUSIONS.intersection(parts):
        return False
    if any(part.endswith("-skill") for part in parts):
        return False
    return not path.as_posix().startswith(".agents/tools/design/library/")


def profile_category(root, name):
    path = Path(name)
    if (
        path.suffix != ".md"
        or path.name in {"AGENTS.md", "README.md", "SKILL.md"}
        or path.name.endswith("-skill.md")
    ):
        return None
    if len(path.parts) == 2 and path.name not in SKIP_FILES:
        return "main_agents"
    if len(path.parts) != 2 and not is_profile_location(path):
        return None
    metadata = parse_frontmatter(source_path(root, name))
    if metadata.get("mode") == "subagent":
        return "subagents"
    return None


def command_target(root, name, entries):
    path = source_path(root, name)
    target = path.resolve(strict=True).relative_to(root).as_posix()
    if entries.get(target) not in {"100644", "100755"}:
        raise ValueError(f"Command target is not a tracked regular source: {name}")
    if EXCLUDED_PARTS.intersection(Path(target).parts) or not target.endswith(".md"):
        raise ValueError(f"Command target is not a production Markdown source: {name}")
    if not path.is_file():
        raise ValueError(f"Command target is not a file: {name}")


def classify_source(root, name, mode, entries):
    path = Path(name)
    if EXCLUDED_PARTS.intersection(path.parts):
        return None
    if (
        path.parent.as_posix() == ".agents/scripts/commands"
        and path.suffix == ".md"
        and path.name not in {"README.md", "AGENTS.md", "SKILL.md"}
    ):
        command_target(root, name, entries)
        return "slash_commands"
    if mode not in {"100644", "100755"}:
        return None
    local_path = source_path(root, name)
    if local_path.is_symlink() or not local_path.is_file():
        raise ValueError(f"Tracked regular source changed type: {name}")
    if path.parts[:2] == (".agents", "scripts"):
        if HELPER_NAME.fullmatch(path.name) and not path.name.startswith(
            ("test-", "test_")
        ):
            return "scripts"
        return None
    return profile_category(root, name)


def inventory(root):
    root = Path(root).resolve()
    entries = tracked_sources(root)
    files = {key: [] for key in KEYS}
    for name, mode in sorted(entries.items()):
        category = classify_source(root, name, mode, entries)
        if category:
            files[category].append(name)
    return {
        "counts": {key: len(files[key]) for key in KEYS},
        "files": files,
        "definitions": DEFINITIONS,
    }


def display_counts(counts):
    """Keep the established conservative display increments, never round upward."""
    steps = {"subagents": 50, "scripts": 10, "slash_commands": 10}
    return {
        key: f"{value // steps[key] * steps[key]:,}+"
        if key in steps and value >= steps[key]
        else f"{value:,}"
        for key, value in counts.items()
    }


def show_counts(data, output):
    if output == "inventory":
        print(json.dumps(data, indent=2))
    elif output == "json":
        print(json.dumps(data["counts"]))
    elif output == "approx":
        for key, value in display_counts(data["counts"]).items():
            print(f"{key}={value}")
    else:
        for key, label in zip(KEYS, LABELS):
            print(f"{label}: {data['counts'][key]}")


if __name__ == "__main__":
    from readme_inventory_cli import main

    sys.exit(main())
