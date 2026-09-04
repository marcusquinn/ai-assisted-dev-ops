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

Custom profiles are preserved. Confidently identified aidevops-managed profiles
are reconciled when their cwd is stale or duplicated.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
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
    _parse_block_scalar,
    load_yaml_simple,
    save_yaml,
    extract_existing_cwds,
    extract_group_id,
    extract_profile_blocks,
    insert_profiles_block,
    remove_profile_blocks,
    validate_yaml_document,
)


class ProfileAppearance(NamedTuple):
    """Colour settings used to render one generated Tabby profile."""

    tab_colour: str
    scheme: dict


class ProfileReconciliation(NamedTuple):
    """A non-mutating managed-profile reconciliation plan."""

    stale: list
    duplicates: list

    @property
    def removals(self) -> list:
        """Return all profile blocks selected for removal."""
        return self.stale + self.duplicates


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
    if not all((git_dir, common_dir)):
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
    return (result.stdout.strip(), "")[result.returncode != 0]


def profile_name_from_path(repo_path: str) -> str:
    """Derive a profile name from the repo path.

    Uses the last path component, or last two if nested (e.g., cloudron/netbird-app).
    """
    parts = Path(repo_path).parts
    try:
        parent = parts[-2]
        name = parts[-1]
    except IndexError:
        return Path(repo_path).name
    grouping_dirs = {
        "git",
        "repos",
        "projects",
        "src",
        "code",
        os.path.basename(os.path.expanduser("~")),
    }
    if parent.lower() in grouping_dirs:
        return name
    return f"{parent}/{name}"


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


def _add_projects_to_existing_groups(config_text: str, group_id: str) -> str:
    """Add Projects to an existing groups section when it is absent."""
    if extract_group_id(config_text):
        return config_text
    group_entry = build_group_yaml(group_id)
    return re.sub(
        r"^(groups:\s*\n)",
        f"\\1{group_entry}\n",
        config_text,
        count=1,
        flags=re.MULTILINE,
    )


def _add_groups_section(config_text: str, group_id: str) -> str:
    """Insert a new groups section before the first conventional config key."""
    group_section = f"groups:\n{build_group_yaml(group_id)}\n"
    top_level_keys = ("configSync:", "hotkeys:", "terminal:", "ssh:", "clickableLinks:")
    insertion_key = next((key for key in top_level_keys if key in config_text), None)
    if insertion_key:
        return config_text.replace(insertion_key, f"{group_section}{insertion_key}", 1)
    return f"{config_text}\n{group_section}"


def ensure_groups_section(config_text: str, group_id: str) -> str:
    """Ensure the groups section exists with a Projects group."""
    if re.search(r"^groups:", config_text, re.MULTILINE):
        return _add_projects_to_existing_groups(config_text, group_id)
    return _add_groups_section(config_text, group_id)


def _repo_profile_target(repo: dict) -> dict | None:
    """Build a profile target for one available canonical repository."""
    path = repo.get("path", "")
    if not path:
        return None
    path = os.path.expanduser(path)
    if not os.path.isdir(path):
        return None
    if is_linked_worktree(path):
        return None
    return {"path": path, "name": profile_name_from_path(path), "repo": repo}


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

    targets = map(_repo_profile_target, data.get("initialized_repos", []))
    return [target for target in targets if target is not None]


def get_registered_paths(repos_json_path: str) -> set[str]:
    """Return normalized paths registered in repos.json, including offline paths."""
    with open(repos_json_path) as handle:
        data = json.load(handle)
    return {
        normalize_cwd(repo["path"])
        for repo in data.get("initialized_repos", [])
        if repo.get("path")
    }


def normalize_cwd(path: str) -> str:
    """Normalize a profile cwd for conservative equality checks."""
    return os.path.normcase(os.path.realpath(os.path.expanduser(path)))


def _has_managed_profile_id(profile: dict) -> bool:
    """Return True only for IDs emitted by :func:`build_profile_yaml`."""
    profile_id = profile.get("id")
    if not isinstance(profile_id, str):
        return False
    try:
        uuid.UUID(profile_id.rsplit(":", 1)[1])
    except (ValueError, IndexError):
        return False
    return profile_id.startswith("local:custom:")


def _has_managed_launch(options: dict) -> bool:
    """Return True for current and historical aidevops OpenCode launch forms."""
    args = options.get("args")
    managed_args = (
        ["-l", "-c", TABBY_OPENCODE_LAUNCH],
        ["-l", "-c", "aidevops opencode; exec zsh"],
        ["-l", "-c", LEGACY_TABBY_OPENCODE_LAUNCH],
        ["-l", "-i", "-c", "opencode"],
    )
    command = options.get("command")
    managed_commands = (
        TABBY_COMMAND_FIELD_OPENCODE,
        LEGACY_TABBY_COMMAND_FIELD_OPENCODE,
        "/bin/zsh -l -c 'aidevops opencode; exec zsh'",
    )
    return any((args in managed_args, command in managed_commands))


def is_aidevops_managed_profile(profile: dict, projects_group_id: str | None) -> bool:
    """Identify a generated profile without claiming custom OpenCode profiles."""
    options = profile.get("options")
    if not isinstance(options, dict):
        return False
    return all(
        (
            projects_group_id,
            profile.get("group") == projects_group_id,
            profile.get("type") == "local",
            isinstance(options.get("cwd"), str),
            _has_managed_profile_id(profile),
            _has_managed_launch(options),
        )
    )


def _retarget_block_cwd(
    lines: list[str],
    index: int,
    match: re.Match[str],
    raw_value: str,
    path_mappings: dict[str, str],
) -> tuple[int, bool]:
    """Retarget one block-scalar cwd and return the next line index."""
    parent_indent = len(match.group("indent"))
    value, next_index = _parse_block_scalar(
        [line.rstrip("\r\n") for line in lines],
        index + 1,
        parent_indent,
        raw_value[0],
    )
    replacement = path_mappings.get(value)
    if not replacement:
        return next_index, False

    lines[index] = (
        f"{match.group('indent')}cwd: {replacement}"
        f"{match.group('newline') or ''}"
    )
    del lines[index + 1 : next_index]
    return index + 1, True


def _retarget_inline_cwd(
    match: re.Match[str], raw_value: str, path_mappings: dict[str, str]
) -> str | None:
    """Render a retargeted inline cwd line, preserving matching quotes."""
    quoted_value = re.fullmatch(r"(?P<quote>['\"])(?P<value>.*)(?P=quote)", raw_value)
    quote = quoted_value.group("quote") if quoted_value else ""
    value = quoted_value.group("value") if quoted_value else raw_value
    replacement = path_mappings.get(value)
    if not replacement:
        return None

    rendered = f"{quote}{replacement}{quote}" if quote else replacement
    return (
        f"{match.group('indent')}cwd: {rendered}"
        f"{match.group('newline') or ''}"
    )


def _retarget_cwd_line(
    lines: list[str],
    index: int,
    cwd_pattern: re.Pattern[str],
    path_mappings: dict[str, str],
) -> tuple[int, bool]:
    """Retarget the cwd at one line and return the next index and change flag."""
    match = cwd_pattern.match(lines[index])
    if not match:
        return index + 1, False
    raw_value = match.group("value").strip()
    if raw_value.startswith((">", "|")):
        return _retarget_block_cwd(lines, index, match, raw_value, path_mappings)
    retargeted_line = _retarget_inline_cwd(match, raw_value, path_mappings)
    if not retargeted_line:
        return index + 1, False
    lines[index] = retargeted_line
    return index + 1, True


def retarget_profile_cwds(
    config_text: str, path_mappings: dict[str, str]
) -> tuple[str, int]:
    """Retarget exact profile cwd scalars without changing unrelated bytes."""
    validate_yaml_document(config_text)
    lines = config_text.splitlines(keepends=True)
    changed = 0
    index = 0
    cwd_pattern = re.compile(r"^(?P<indent>\s+)cwd:\s*(?P<value>.*?)(?P<newline>\r?\n)?$")
    while index < len(lines):
        index, was_retargeted = _retarget_cwd_line(
            lines, index, cwd_pattern, path_mappings
        )
        changed += was_retargeted
    updated = "".join(lines)
    validate_yaml_document(updated)
    return updated, changed


def _reconciliation_category(
    block, projects_group_id: str | None, registered_paths: set[str], seen_cwds: set[str]
) -> str | None:
    """Classify a managed profile block for conservative reconciliation."""
    profile = block.data
    if not is_aidevops_managed_profile(profile, projects_group_id):
        return None

    cwd = profile["options"]["cwd"]
    normalized = normalize_cwd(cwd)
    cwd_is_known = any(
        (os.path.isdir(os.path.expanduser(cwd)), normalized in registered_paths)
    )
    if not cwd_is_known:
        return "stale"
    if normalized in seen_cwds:
        return "duplicate"
    seen_cwds.add(normalized)
    return None


def plan_profile_reconciliation(
    config_text: str, registered_paths: set[str]
) -> ProfileReconciliation:
    """Plan safe stale and duplicate managed-profile removals."""
    projects_group_id = extract_group_id(config_text)
    seen_cwds: set[str] = set()
    stale = []
    duplicates = []
    categories = {"stale": stale, "duplicate": duplicates}
    for block in extract_profile_blocks(config_text):
        category = _reconciliation_category(
            block, projects_group_id, registered_paths, seen_cwds
        )
        if category:
            categories[category].append(block)
    return ProfileReconciliation(stale, duplicates)


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
    should_add_buzz = all(
        (
            os.path.isdir(buzz_path),
            all(target["path"] != buzz_path for target in targets),
        )
    )
    if should_add_buzz:
        targets.append(
            {
                "path": buzz_path,
                "name": "Buzz",
                "repo": {"path": buzz_path, "profile_kind": "buzz-workspace"},
            }
        )
    return targets


def _optional_line(value: object, line: str) -> str:
    """Return a newline-terminated status line only when value is truthy."""
    return ("", f"{line}\n")[bool(value)]


def show_status(
    repos: list[dict], existing_cwds: set[str], reconciliation: ProfileReconciliation
) -> None:
    """Print status of profile targets vs existing Tabby profiles."""
    workspace_count = sum(
        repo["repo"].get("profile_kind") == "buzz-workspace" for repo in repos
    )
    print(f"Repos in repos.json: {len(repos) - workspace_count}")
    print(
        _optional_line(workspace_count, f"Detected workspaces: {workspace_count}"),
        end="",
    )
    has_profile = sum(repo["path"] in existing_cwds for repo in repos)
    for repo in repos:
        labels = ("new]   ", "exists]")
        label = labels[repo["path"] in existing_cwds]
        print(f"  [{label} {repo['name']} -> {repo['path']}")
    needs_profile = len(repos) - has_profile
    print(f"\nExisting: {has_profile}, New: {needs_profile}")
    print(
        "Pending reconciliation: "
        f"{len(reconciliation.stale)} stale managed, "
        f"{len(reconciliation.duplicates)} duplicate managed"
    )


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
    missing_repos = (repo for repo in repos if repo["path"] not in existing_cwds)
    for repo in missing_repos:
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


def _report_reconciliation(
    repaired_count: int, reconciliation: ProfileReconciliation
) -> None:
    """Report profile repairs and removals performed during a sync."""
    repaired_line = f"Repaired {repaired_count} existing Tabby profile(s)."
    removed_line = (
        "Removed "
        f"{len(reconciliation.stale)} stale and "
        f"{len(reconciliation.duplicates)} duplicate managed profile(s)."
    )
    print(
        _optional_line(repaired_count, repaired_line)
        + _optional_line(reconciliation.removals, removed_line),
        end="",
    )


def _save_reconciled_config(
    config_path: str,
    config_text: str,
    repaired_count: int,
    reconciliation: ProfileReconciliation,
) -> bool:
    """Save and report a reconciliation-only update when one exists."""
    if not any((repaired_count, reconciliation.removals)):
        return False
    save_yaml(config_path, config_text)
    _report_reconciliation(repaired_count, reconciliation)
    return True


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

    reconciliation = plan_profile_reconciliation(
        config_text, get_registered_paths(args.repos_json)
    )
    config_text = remove_profile_blocks(config_text, reconciliation.removals)
    existing_cwds = extract_existing_cwds(config_text)
    config_text, group_id = ensure_group(config_text)
    new_profiles = build_new_profiles(repos, existing_cwds, group_id, shell_path)

    if not new_profiles:
        if not _save_reconciled_config(
            args.tabby_config, config_text, repaired_count, reconciliation
        ):
            print("All profile targets already have Tabby profiles. Nothing to do.")
        return

    new_block = "\n".join(p[1] for p in new_profiles)
    config_text = insert_profiles_block(config_text, new_block)
    save_yaml(args.tabby_config, config_text)

    _report_reconciliation(repaired_count, reconciliation)
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
        reconciliation = plan_profile_reconciliation(
            config_text, get_registered_paths(args.repos_json)
        )
        show_status(repos, existing_cwds, reconciliation)
        has_validation_issues = (
            report_profile_arg_type_issues(config_text)
            or report_profile_command_issues(config_text)
        )
        if has_validation_issues:
            raise SystemExit(2)
        return

    try:
        sync_profiles(args)
    except ShellResolutionError as exc:
        print(f"Tabby profile sync failed: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc


if __name__ == "__main__":
    main()
