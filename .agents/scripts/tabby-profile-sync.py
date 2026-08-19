#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Sync Tabby terminal profiles from aidevops repos.json and detected workspaces.

Creates a profile for each registered repo and an optional Buzz workspace with:
- Unique bright tab colour (dark-mode friendly)
- Matching built-in Tabby colour scheme (closest hue)
- Direct OpenCode launch that leaves a shell open after exit
- Grouped under "Projects"

Existing profiles (matched by cwd path) are never overwritten.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import uuid
from pathlib import Path
from typing import NamedTuple, Optional

from tabby_colour_utils import generate_tab_colour, find_closest_scheme
from tabby_profile_repair import (
    _repair_broken_opencode_launch_profile_block,
    repair_broken_opencode_launch_profiles,
)
from tabby_profile_utils import (
    LEGACY_TABBY_COMMAND_FIELD_OPENCODE,
    LEGACY_TABBY_OPENCODE_LAUNCH,
    TABBY_COMMAND_FIELD_OPENCODE,
    TABBY_OPENCODE_LAUNCH,
)
from tabby_profile_validation import (
    ProfileArgTypeIssue,
    find_profile_arg_type_issues,
    find_profile_command_issues,
    report_profile_arg_type_issues,
    report_profile_command_issues,
)
from tabby_shell_resolver import ShellResolutionError, resolve_login_shell
from tabby_yaml_helpers import (
    load_yaml_simple,
    save_yaml,
    extract_existing_cwds,
    extract_group_id,
    insert_profiles_block,
)


class ProfileAppearance(NamedTuple):
    """Colour settings used to render one generated Tabby profile."""

    tab_colour: str
    scheme: dict


def is_linked_worktree(repo_path: str) -> bool:
    """Return True iff ``repo_path`` is a linked git worktree (not the main one).

    Deterministic replacement for the old string-heuristic that tried to guess
    worktrees from the basename pattern ``repo.branch-name``. That heuristic
    broke whenever the repo name itself contained a dot (domain-like names such
    as ``wpallstars.com`` / ``example.io``) or when a worktree branch did not
    start with one of the six hard-coded prefixes.

    Detection rule: a linked worktree's ``git rev-parse --git-common-dir``
    resolves to the *main* repo's ``.git`` directory, while the worktree's own
    ``git rev-parse --git-dir`` resolves to ``<main>/.git/worktrees/<name>``.
    For the main checkout (or any non-worktree clone) those two paths collapse
    to the same ``.git`` directory. Comparing absolute paths gives a
    heuristic-free answer that works for any repo name, branch name, or future
    worktree convention.

    Returns False on non-git paths or on any git invocation error — the caller
    treats those as "not a worktree" so normal repos are never excluded.
    """
    git_dir = _run_git(repo_path, "rev-parse", "--git-dir")
    common_dir = _run_git(repo_path, "rev-parse", "--git-common-dir")
    if not git_dir or not common_dir:
        return False

    def _absolute(path: str) -> str:
        # git may return a relative path (e.g. ``.git``) — resolve against
        # ``repo_path`` so we always compare absolute paths.
        if not os.path.isabs(path):
            path = os.path.join(repo_path, path)
        return os.path.realpath(path)

    return _absolute(git_dir) != _absolute(common_dir)


def _run_git(cwd: str, *args: str) -> str:
    """Run ``git -C <cwd> <args...>`` and return stripped stdout, or ``""``."""
    try:
        result = subprocess.run(
            ["git", "-C", cwd, *args],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def profile_name_from_path(repo_path: str) -> str:
    """Derive a profile name from the repo path.

    Uses the last path component, or last two if nested (e.g., cloudron/netbird-app).
    """
    parts = Path(repo_path).parts
    if len(parts) >= 2:
        parent = parts[-2]
        name = parts[-1]
        # If parent is a grouping dir (not Git or home), include it
        if parent.lower() not in ("git", "repos", "projects", "src", "code",
                                   os.path.basename(os.path.expanduser("~"))):
            return f"{parent}/{name}"
    return Path(repo_path).name


def build_profile_yaml(
    name: str,
    cwd: str,
    appearance: ProfileAppearance,
    group_id: str,
    shell_path: str | None = None,
) -> str:
    """Build a YAML profile block as a string."""
    profile_id = f"local:custom:{name.replace('/', '-')}:{uuid.uuid4()}"
    shell_path = shell_path or resolve_login_shell()
    tab_colour = appearance.tab_colour
    scheme = appearance.scheme

    # Build colour list
    colours_yaml = ""
    for c in scheme["colors"]:
        colours_yaml += f"        - '{c}'\n"

    profile = f"""  - name: {name}
    icon: fas fa-terminal
    options:
      command: {shell_path}
      args:
        - '-l'
        - '-c'
        - '{TABBY_OPENCODE_LAUNCH}'
      env: {{}}
      cwd: {cwd}
    terminalColorScheme:
      name: {scheme['name']}
      foreground: '{scheme['foreground']}'
      background: '{scheme['background']}'
      cursor: '{scheme['cursor']}'
      colors:
{colours_yaml.rstrip()}
    color: '{tab_colour}'
    id: {profile_id}
    group: {group_id}
    disableDynamicTitle: false
    type: local"""

    return profile


def build_group_yaml(group_id: str) -> str:
    """Build a YAML group block."""
    return f"""  - id: {group_id}
    name: Projects"""


def ensure_groups_section(config_text: str, group_id: str) -> str:
    """Ensure the groups section exists with a Projects group."""
    if re.search(r"^groups:", config_text, re.MULTILINE):
        # Check if Projects group exists
        existing_id = extract_group_id(config_text)
        if existing_id:
            return config_text  # Already has Projects group
        # Add Projects group to existing groups section
        group_entry = build_group_yaml(group_id)
        config_text = re.sub(
            r"^(groups:\s*\n)",
            f"\\1{group_entry}\n",
            config_text,
            count=1,
            flags=re.MULTILINE,
        )
    else:
        # Add groups section before the first non-profile top-level key
        # or at the end
        group_section = f"groups:\n{build_group_yaml(group_id)}\n"
        # Insert before configSync, hotkeys, terminal, ssh, etc.
        for key in ("configSync:", "hotkeys:", "terminal:", "ssh:", "clickableLinks:"):
            if key in config_text:
                config_text = config_text.replace(key, f"{group_section}{key}", 1)
                return config_text
        # Fallback: append
        config_text += f"\n{group_section}"
    return config_text


def get_repos(repos_json_path: str) -> list[dict]:
    """Load repos from repos.json, filtering to those suitable for profiles.

    Excludes:
    - entries without a ``path`` field
    - paths that don't exist on disk
    - linked git worktrees (detected via :func:`is_linked_worktree`)

    Worktrees are excluded because each worktree shares its parent repo's
    purpose; creating a separate Tabby profile per branch would multiply
    entries every time a branch is checked out. The canonical repo's profile
    is sufficient — users ``cd`` into worktrees from the canonical terminal
    when they need them.
    """
    with open(repos_json_path) as f:
        data = json.load(f)

    repos = data.get("initialized_repos", [])
    result = []
    for repo in repos:
        path = repo.get("path", "")
        if not path:
            continue
        path = os.path.expanduser(path)
        if not os.path.isdir(path):
            continue
        if is_linked_worktree(path):
            continue
        result.append({"path": path, "name": profile_name_from_path(path), "repo": repo})
    return result


def get_profile_targets(
    repos_json_path: str, home: Optional[str] = None
) -> list[dict]:
    """Return registered repositories plus detected special workspaces.

    Buzz-backed OpenCode sessions are scoped to ``~/.buzz``. Include that
    workspace only when it exists, preserving the normal no-unused-profile
    behavior for users who do not have Buzz installed.
    """
    targets = get_repos(repos_json_path)
    home_path = (
        os.path.expanduser(home) if home is not None else os.path.expanduser("~")
    )
    buzz_path = os.path.join(home_path, ".buzz")
    if os.path.isdir(buzz_path) and all(
        target["path"] != buzz_path for target in targets
    ):
        targets.append(
            {
                "path": buzz_path,
                "name": "Buzz",
                "repo": {"path": buzz_path, "profile_kind": "buzz-workspace"},
            }
        )
    return targets


def show_status(repos: list[dict], existing_cwds: set[str]) -> None:
    """Print status of profile targets vs existing Tabby profiles."""
    workspace_count = sum(
        repo["repo"].get("profile_kind") == "buzz-workspace" for repo in repos
    )
    print(f"Repos in repos.json: {len(repos) - workspace_count}")
    if workspace_count:
        print(f"Detected workspaces: {workspace_count}")
    has_profile = 0
    needs_profile = 0
    for repo in repos:
        if repo["path"] in existing_cwds:
            has_profile += 1
            print(f"  [exists] {repo['name']} -> {repo['path']}")
        else:
            needs_profile += 1
            print(f"  [new]    {repo['name']} -> {repo['path']}")
    print(f"\nExisting: {has_profile}, New: {needs_profile}")
    if needs_profile > 0:
        print("Note: existing profiles are never modified — only new ones are created.")


def ensure_group(config_text: str) -> tuple[str, str]:
    """Return (config_text, group_id), creating a Projects group if needed."""
    group_id = extract_group_id(config_text)
    if not group_id:
        group_id = str(uuid.uuid4())
        config_text = ensure_groups_section(config_text, group_id)
    return config_text, group_id


def build_new_profiles(
    repos: list[dict], existing_cwds: set[str], group_id: str, shell_path: str | None = None
) -> list[tuple]:
    """Build profile entries for repos that don't yet have a Tabby profile."""
    new_profiles = []
    shell_path = shell_path or resolve_login_shell()
    for repo in repos:
        if repo["path"] not in existing_cwds:
            tab_colour = generate_tab_colour(repo["path"])
            scheme = find_closest_scheme(tab_colour)
            profile_yaml = build_profile_yaml(
                name=repo["name"],
                cwd=repo["path"],
                appearance=ProfileAppearance(tab_colour, scheme),
                group_id=group_id,
                shell_path=shell_path,
            )
            new_profiles.append((repo, profile_yaml, tab_colour, scheme["name"]))
    return new_profiles


def sync_profiles(args: argparse.Namespace) -> None:
    """Perform the profile sync: discover new repos and insert their profiles."""
    shell_path = resolve_login_shell()
    repos = get_profile_targets(args.repos_json)
    config_text = load_yaml_simple(args.tabby_config)
    existing_cwds = extract_existing_cwds(config_text)

    # Preserve custom profiles byte-for-byte, but make their invalid runtime
    # types visible instead of silently leaving a profile that can freeze Tabby.
    report_profile_arg_type_issues(config_text)

    config_text, repaired_count = repair_broken_opencode_launch_profiles(
        config_text, shell_path
    )
    if report_profile_command_issues(config_text):
        raise SystemExit(2)

    config_text, group_id = ensure_group(config_text)
    new_profiles = build_new_profiles(repos, existing_cwds, group_id, shell_path)

    if not new_profiles:
        if repaired_count:
            save_yaml(args.tabby_config, config_text)
            print(f"Repaired {repaired_count} existing Tabby profile(s).")
        else:
            print("All profile targets already have Tabby profiles. Nothing to do.")
        return

    new_block = "\n".join(p[1] for p in new_profiles)
    config_text = insert_profiles_block(config_text, new_block)
    save_yaml(args.tabby_config, config_text)

    if repaired_count:
        print(f"Repaired {repaired_count} existing Tabby profile(s).")
    print(f"Created {len(new_profiles)} new Tabby profile(s):")
    for repo, _, colour, scheme_name in new_profiles:
        print(f"  + {repo['name']} (colour: {colour}, scheme: {scheme_name})")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Sync Tabby profiles from repos.json and detected workspaces"
    )
    parser.add_argument("--repos-json", required=True, help="Path to repos.json")
    parser.add_argument("--tabby-config", required=True, help="Path to Tabby config.yaml")
    parser.add_argument("--status-only", action="store_true", help="Show status without modifying")
    args = parser.parse_args()

    repos = get_profile_targets(args.repos_json)
    config_text = load_yaml_simple(args.tabby_config)
    existing_cwds = extract_existing_cwds(config_text)

    if args.status_only:
        show_status(repos, existing_cwds)
        if report_profile_arg_type_issues(config_text) or report_profile_command_issues(
            config_text
        ):
            raise SystemExit(2)
        return

    try:
        sync_profiles(args)
    except ShellResolutionError as exc:
        print(f"Tabby profile sync failed: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc


if __name__ == "__main__":
    main()
