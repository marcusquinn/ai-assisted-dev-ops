# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Auditable, tracked-source inventory for the README's four public categories."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from agent_config import SKIP_FILES

KEYS = ("main_agents", "subagents", "scripts", "slash_commands")
LABELS = ("main agents", "sub agents", "helper scripts", "slash commands")
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
    "generated",
    "dist",
    ".cache",
    "coverage",
    "testdata",
    "__snapshots__",
}
SCRIPT_SUFFIXES = {
    ".sh",
    ".bash",
    ".py",
    ".mjs",
    ".cjs",
    ".js",
    ".ts",
    ".tsx",
    ".rb",
    ".pl",
    ".ps1",
    ".awk",
    ".jq",
}
DEFINITIONS = {
    "main_agents": "Root agent profiles eligible under agent_config.SKIP_FILES.",
    "subagents": "Individually path-addressable Markdown modules, including skills, "
    "workflows and references, plus demoted root profiles. Uses generator filename "
    "rules (not mode metadata); excludes README.md, AGENTS.md, *-skill.md wrappers, "
    "tests, generated/vendor/runtime files and symlink aliases. Not a count of "
    "unique flattened runtime names. Regular command sources also count here.",
    "scripts": "Production script/source files in .agents/scripts across scripting "
    "languages, including supporting modules and executable extensionless scripts; "
    "excludes tests, fixtures, generated/vendor files, declarations and aliases. "
    "Not restricted to *-helper filenames or standalone CLI entry points.",
    "slash_commands": "Markdown entry points directly in scripts/commands; "
    "symlinks must resolve to tracked regular files inside .agents.",
}


def source_path(root, name):
    """Do not read an external target even if a tracked path was replaced locally."""
    path = root / name
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(root / ".agents"):
        raise ValueError(f"Source escapes .agents: {name}")
    return path


def is_profile_file(path):
    """Match generate_subagent_stub and its find selection, without a mode filter."""
    return (
        path.suffix == ".md"
        and path.name not in {"AGENTS.md", "README.md"}
        and not path.name.endswith("-skill.md")
    )


def profile_category(path):
    if len(path.parts) == 2 and path.suffix == ".md" and path.name not in SKIP_FILES:
        return "main_agents"
    return "subagents" if is_profile_file(path) else None


def command_target(root, name, entries):
    path = source_path(root, name)
    target = path.resolve(strict=True).relative_to(root).as_posix()
    if entries.get(target) not in {"100644", "100755"}:
        raise ValueError(f"Command target is not a tracked regular source: {name}")
    if EXCLUDED_PARTS.intersection(Path(target).parts) or not target.endswith(".md"):
        raise ValueError(f"Command target is not a production Markdown source: {name}")
    if not path.is_file():
        raise ValueError(f"Command target is not a file: {name}")


def is_command(path):
    return (
        path.parent.as_posix() == ".agents/scripts/commands"
        and path.suffix == ".md"
        and path.name not in {"README.md", "AGENTS.md", "SKILL.md"}
    )


def validate_regular_source(root, name):
    local_path = source_path(root, name)
    if local_path.is_symlink() or not local_path.is_file():
        raise ValueError(f"Tracked regular source changed type: {name}")


def is_test_script(name):
    return name.startswith(("test-", "test_")) or any(
        marker in name for marker in (".test.", ".spec.", "_test.", "_spec.")
    )


def helper_category(root, path, mode):
    if is_test_script(path.name) or path.name.endswith(".d.ts"):
        return None
    if path.suffix.lower() in SCRIPT_SUFFIXES:
        return "scripts"
    if not path.suffix and mode == "100755":
        with source_path(root, path.as_posix()).open("rb") as source:
            if source.read(2) == b"#!":
                return "scripts"
    return None


def classify_source(root, name, mode, entries):
    path = Path(name)
    if EXCLUDED_PARTS.intersection(path.parts):
        return ()
    command = is_command(path)
    if command:
        command_target(root, name, entries)
    if mode not in {"100644", "100755"}:
        return ("slash_commands",) if command else ()
    validate_regular_source(root, name)
    categories = [profile_category(path)]
    if path.parts[:2] == (".agents", "scripts"):
        categories.append(helper_category(root, path, mode))
    if command:
        categories.append("slash_commands")
    return tuple(filter(None, categories))
