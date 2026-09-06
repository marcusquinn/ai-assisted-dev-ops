"""Shared agent configuration constants and helpers.

Single source of truth for agent definitions used by both agent-discovery.py
and opencode-agent-discovery.py. Extracted as part of t2130 to eliminate
duplication and reduce file complexity.
"""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import glob
import os
import sys
import tempfile

from discovery_utils import parse_frontmatter


# Darwin's unistd.h exposes this confstr key, but Python omits its symbolic
# name from os.confstr_names. Passing the native key avoids spawning getconf.
_CS_DARWIN_USER_TEMP_DIR = 65537


# =============================================================================
# AGENT CONSTANTS — Single source of truth
# =============================================================================

# Agent display name mappings (filename -> display name)
# If not in this map, derive from filename (e.g., build-agent.md -> Build-Agent)
DISPLAY_NAMES = {
    "build-plus": "Build+",
    "pr": "PR",
    "seo": "SEO",
    "social-media": "Social-Media",
}

# Agent ordering (agents listed here appear first in this order, rest alphabetical)
# Note: Build+ is now the single unified coding agent (Plan+ and AI-DevOps consolidated)
AGENT_ORDER = ["Build+", "Automate"]

# Files to skip (not primary agents - includes demoted agents)
# plan-plus.md and aidevops.md are now subagents, not primary agents
# browser-extension-dev.md and mobile-app-dev.md are specialist subagents under Build+
SKIP_PRIMARY_AGENTS = {"plan-plus.md", "aidevops.md", "browser-extension-dev.md", "mobile-app-dev.md"}


def managed_external_directories():
    """Return stable framework paths plus this user's resolved OS temp path."""
    paths = [
        "~/.aidevops",
        "~/.aidevops/**",
        "~/.config/aidevops",
        "~/.config/aidevops/**",
        "~/.config/opencode/command",
        "~/.config/opencode/command/**",
    ]
    is_worktree_base_configured = "AIDEVOPS_WORKTREE_BASE_DIR" in os.environ
    configured_worktree_base = os.environ.get("AIDEVOPS_WORKTREE_BASE_DIR", "")
    worktree_base = configured_worktree_base.rstrip("/") if is_worktree_base_configured else "~/Git/_worktrees"
    if is_worktree_base_configured and (not worktree_base.startswith("/") or worktree_base == "/"):
        raise ValueError("AIDEVOPS_WORKTREE_BASE_DIR must be a non-root absolute path")
    paths.extend((worktree_base, f"{worktree_base}/**"))
    configured_temp = tempfile.gettempdir().rstrip("/")
    temp_dirs = {configured_temp, os.path.realpath(configured_temp)}
    if sys.platform == "darwin":
        try:
            darwin_temp = os.confstr(_CS_DARWIN_USER_TEMP_DIR).rstrip("/")
            if darwin_temp:
                temp_dirs.update((darwin_temp, os.path.realpath(darwin_temp)))
        except (OSError, ValueError):
            pass
    for temp_dir in sorted(temp_dirs):
        if temp_dir:
            paths.extend((temp_dir, f"{temp_dir.rstrip('/')}/**"))
    return tuple(paths)

# Special tool configurations per agent (by display name)
# These are MCP tools that specific agents need access to
#
# MCP On-Demand Loading Strategy:
# The following MCPs are DISABLED globally to reduce context token usage:
#   - playwriter_*: ~3K tokens - enable via @playwriter subagent
#   - google-analytics-mcp_*: ~800 tokens - enable via @google-analytics subagent
#   - context7_*: ~800 tokens - enable via @context7 subagent (library docs lookup)
#   - openapi-search_*: ~500 tokens - enabled for Build+, AI-DevOps, Research only
AGENT_TOOLS = {
    "Build+": {
        "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True, "todoread": True, "todowrite": True,
        "openapi-search_*": True
    },
    "Onboarding": {
        "write": True, "edit": True, "bash": True,
        "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True
    },
    "Accounts": {
        "write": True, "edit": True, "bash": True,
        "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True, "quickfile_*": True
    },
    "Social-Media": {
        "write": True, "edit": True, "bash": True,
        "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True
    },
    "SEO": {
        "write": True, "read": True, "bash": True, "webfetch": True,
        "gsc_*": True, "ahrefs_*": True, "dataforseo_*": True
    },
    "WordPress": {
        "write": True, "edit": True, "bash": True,
        "read": True, "glob": True, "grep": True,
        "localwp_*": True
    },
    "Content": {
        "write": True, "edit": True, "read": True, "webfetch": True
    },
    "Research": {
        "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True,
        "openapi-search_*": True
    },
    "Automate": {
        "bash": True, "read": True, "glob": True, "grep": True,
        "task": True, "todoread": True, "todowrite": True
    },
}

# Default tools for agents not in AGENT_TOOLS
DEFAULT_TOOLS = {
    "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
    "webfetch": True, "task": True
}

# Temperature settings (by display name, default 0.2)
AGENT_TEMPS = {
    "Build+": 0.2,
    "Automate": 0.1,
    "Accounts": 0.1,
    "Legal": 0.1,
    "Content": 0.3,
    "Marketing": 0.3,
    "Research": 0.3,
}

# Legacy compatibility path retained for callers; primary prompts now load their
# selected canonical source, with core delivered independently by instructions.
DEFAULT_PROMPT = "~/.aidevops/agents/prompts/build.txt"

# Agents that should NOT receive a canonical source prompt (empty by default).
SKIP_CUSTOM_PROMPT = set()

# Workload tiers are routing intent, not concrete runtime model IDs.
WORKLOAD_TIERS = {"simple", "standard", "thinking"}

# Default model tier per agent (overridden by frontmatter 'model:' field)
AGENT_MODEL_TIERS = {}

# Files to skip (not primary agents)
SKIP_FILES = {"AGENTS.md", "README.md", "configs/SKILL-SCAN-RESULTS.md"} | SKIP_PRIMARY_AGENTS

# =============================================================================
# AGENT CONFIGURATION HELPERS
# =============================================================================

def filename_to_display(filename):
    """Convert filename to display name."""
    name = filename.replace(".md", "")
    if name in DISPLAY_NAMES:
        return DISPLAY_NAMES[name]
    return "-".join(word.capitalize() for word in name.split("-"))


def display_to_filename(display_name):
    """Convert display name back to filename stem."""
    reverse_map = {value: key for key, value in DISPLAY_NAMES.items()}
    if display_name in reverse_map:
        return reverse_map[display_name]
    return display_name.lower()


def get_agent_config(display_name, filename, subagents=None, model_tier=None):
    """Generate agent configuration.

    Args:
        display_name: Agent display name
        filename: Agent markdown filename
        subagents: Optional list of allowed subagent names (from frontmatter)
        model_tier: Optional provider-neutral tier (simple/standard/thinking) or legacy alias
    """
    tools = AGENT_TOOLS.get(display_name, DEFAULT_TOOLS.copy())
    temp = AGENT_TEMPS.get(display_name, 0.2)

    config = {
        "description": f"Read ~/.aidevops/agents/{filename}",
        "mode": "primary",
        "temperature": temp,
        "permission": {},
        "tools": tools
    }

    # Deliver the selected canonical source in the system prompt, not merely in
    # description metadata. The shared build.txt is a compatibility placeholder;
    # core guidance is independently delivered by the runtime instructions list.
    if display_name not in SKIP_CUSTOM_PROMPT:
        config["prompt"] = "{file:~/.aidevops/agents/" + filename + "}"

    # Canonical workload tiers inherit the runtime-selected model. Preserve only
    # explicit full provider/model IDs; those are operator overrides, not tiers.
    effective_tier = model_tier or AGENT_MODEL_TIERS.get(display_name)
    if effective_tier and effective_tier not in WORKLOAD_TIERS and "/" in effective_tier:
        config["model"] = effective_tier

    # OpenCode applies the external-directory boundary to shell paths too.
    # Permit only managed paths and this user's resolved OS temp directory so
    # disposable test worktrees work without opening all of /tmp or /var/folders.
    config["permission"] = {
        "external_directory": {
            path: "allow" for path in managed_external_directories()
        }
    }
    # Grep is a read-only search tool. Explicitly allow it when enabled so
    # OpenCode does not fall back to its interactive permission default.
    if tools.get("grep") is True:
        config["permission"]["grep"] = "allow"

    # Add subagent filtering via permission.task if subagents specified
    if subagents and isinstance(subagents, list) and len(subagents) > 0:
        task_perms = {"*": "deny"}
        for subagent in subagents:
            task_perms[subagent] = "allow"
        config["permission"]["task"] = task_perms
        print(f"    {display_name}: filtered to {len(subagents)} subagents")

    return config


def sort_key(name):
    """Sort key: ordered agents first, then alphabetical."""
    if name in AGENT_ORDER:
        return (0, AGENT_ORDER.index(name))
    return (1, name.lower())


# =============================================================================
# AGENT DISCOVERY
# =============================================================================

def iter_primary_agent_sources(agents_dir):
    """Yield canonical primary-agent source records in discovery order.

    ``source_name`` falls back to the filename stem for compatibility with
    custom and test agents created before explicit names were required. New
    portable consumers can require ``name_explicit`` without changing the
    existing runtime discovery contract.
    """
    records = []
    for filepath in glob.glob(os.path.join(agents_dir, "*.md")):
        filename = os.path.basename(filepath)
        if filename in SKIP_FILES:
            continue

        display_name = filename_to_display(filename)
        frontmatter = parse_frontmatter(filepath)
        subagents = frontmatter.get('subagents', None)
        model_tier = frontmatter.get('model', None)
        explicit_name = frontmatter.get('name', None)

        if not isinstance(subagents, (list, type(None))):
            print(f"  Warning: {display_name} has malformed subagents value "
                  f"(expected list, got {type(subagents).__name__}): {subagents}",
                  file=sys.stderr)
            subagents = None

        source_name = explicit_name if explicit_name else os.path.splitext(filename)[0]
        records.append({
            "path": filepath,
            "filename": filename,
            "frontmatter": frontmatter,
            "source_name": source_name,
            "name_explicit": bool(explicit_name),
            "display_name": display_name,
            "subagents": subagents,
            "workload_tier": model_tier,
        })

    for record in sorted(records, key=lambda item: sort_key(item["display_name"])):
        yield record


def discover_primary_agents(agents_dir):
    """Discover primary agents from root-level .md files.

    Returns (primary_agents, sorted_agents, subagent_filtered_count).
    """
    primary_agents = {}
    subagent_filtered_count = 0

    for record in iter_primary_agent_sources(agents_dir):
        if record["subagents"]:
            subagent_filtered_count += 1

        primary_agents[record["display_name"]] = get_agent_config(
            record["display_name"],
            record["filename"],
            record["subagents"],
            record["workload_tier"],
        )

    sorted_agents = dict(sorted(primary_agents.items(), key=lambda x: sort_key(x[0])))
    return primary_agents, sorted_agents, subagent_filtered_count


# Re-export subagent validation for backward compatibility
from subagent_validation import validate_subagent_refs  # noqa: F401


# =============================================================================
# DISABLED AGENTS — Demoted agents that are now subagents
# =============================================================================

DISABLED_AGENTS = {
    "build": {"disable": True},
    "plan": {"disable": True},
    "Plan+": {"disable": True},
    "AI-DevOps": {"disable": True},
    "Browser-Extension-Dev": {"disable": True},
    "Mobile-App-Dev": {"disable": True},
}


def apply_disabled_agents(sorted_agents):
    """Add disabled agent entries to sorted_agents dict."""
    for name, config in DISABLED_AGENTS.items():
        sorted_agents[name] = config
