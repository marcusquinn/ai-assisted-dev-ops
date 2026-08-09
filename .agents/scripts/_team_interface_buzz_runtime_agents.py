"""Sanitize deployed agent trees before immutable Buzz runtime anchoring."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from functools import partial
from pathlib import Path
import shutil


GENERATED_PLUGIN_DEPENDENCIES = Path("plugins/opencode-aidevops/node_modules")
TRANSIENT_AGENT_IGNORE = shutil.ignore_patterns(".DS_Store", "__pycache__", "*.pyc")


def pinned_agents_copy_ignore(source_agents, directory, names):
    """Ignore transient files and the deployed plugin's separately pinned dependencies."""
    ignored = set(TRANSIENT_AGENT_IGNORE(directory, names))
    relative_directory = Path(directory).relative_to(source_agents)
    if relative_directory == GENERATED_PLUGIN_DEPENDENCIES.parent:
        ignored.add(GENERATED_PLUGIN_DEPENDENCIES.name)
    return ignored


def copy_pinned_agents(source_agents, destination):
    """Copy one agent tree without its generated external dependency link."""
    shutil.copytree(
        source_agents,
        destination,
        symlinks=True,
        ignore=partial(pinned_agents_copy_ignore, source_agents),
    )
