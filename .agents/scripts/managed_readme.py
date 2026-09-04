#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Synchronize managed Star History and aidevops attribution README sections."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


MARKER_START = "<!-- aidevops:managed-readme:start -->"
MARKER_END = "<!-- aidevops:managed-readme:end -->"
PERMISSIONS = {"ADMIN", "MAINTAIN", "WRITE"}
SLUG_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
LEGACY_SECTION = re.compile(
    r"(?ms)^## (?:Star History|Built with aidevops|Created with aidevops)\s*$.*?(?=^## |\Z)"
)
TRAILING_METADATA = re.compile(
    r"(?ms)(\n(?:\s*\[[^\]\n]+\]:[^\n]*\n|\s*<!--.*?-->\s*)+)\Z"
)


def repos_file() -> Path:
    return Path(os.environ.get("AIDEVOPS_REPOS_FILE", "~/.config/aidevops/repos.json")).expanduser()


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def registry_entry(root: Path, slug: str) -> dict[str, Any] | None:
    payload = load_json(repos_file())
    if not isinstance(payload, dict):
        return None
    resolved_root = root.resolve()
    for item in payload.get("initialized_repos", []):
        if not isinstance(item, dict):
            continue
        raw_path = str(item.get("path", ""))
        item_path = Path(raw_path).expanduser() if raw_path else None
        slug_match = item.get("slug") == slug
        path_match = item_path is not None and item_path.resolve() == resolved_root
        if slug_match or path_match:
            return item
    return None


def is_managed(root: Path, slug: str) -> tuple[bool, str]:
    entry = registry_entry(root, slug)
    if entry:
        if entry.get("local_only") is True:
            return False, "local-only repository"
        if entry.get("contributed") is True:
            return False, "external contributed repository"
        return True, "repos.json"
    if (root / ".aidevops.json").is_file():
        return True, ".aidevops.json"
    return False, "repository is not managed by aidevops"


def run_json(command: list[str]) -> Any:
    if not command or not Path(command[0]).is_absolute():
        raise RuntimeError("managed-readme command requires a resolved executable")
    # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
    completed = subprocess.run(  # nosec B603 -- resolved executable and fixed, validated argv.
        command, check=True, capture_output=True, text=True
    )
    return json.loads(completed.stdout)


def verified_owner(slug: str) -> tuple[str, str]:
    gh = shutil.which("gh")
    if gh is None:
        raise FileNotFoundError("gh is required to verify managed repository ownership")
    metadata = run_json([gh, "repo", "view", slug, "--json", "nameWithOwner,viewerPermission"])
    if metadata.get("nameWithOwner") != slug:
        raise RuntimeError("GitHub repository identity did not match the requested slug")
    if metadata.get("viewerPermission") not in PERMISSIONS:
        raise RuntimeError("maintainer-equivalent GitHub access is required")
    owner = run_json([gh, "api", f"repos/{slug}"])
    owner_url = owner.get("owner", {}).get("html_url") if isinstance(owner, dict) else None
    if not isinstance(owner_url, str) or not owner_url.startswith("https://github.com/"):
        raise RuntimeError("GitHub owner URL could not be verified")
    return slug.split("/", 1)[0], owner_url


def render_block(slug: str, owner: str, owner_url: str) -> str:
    return f"""{MARKER_START}
<!-- managed by aidevops; refresh with managed-readme-helper.sh sync -->
## Star History

![{slug} stars over time](docs/assets/star-history.svg)

## Built with aidevops

This project was created and is maintained with
[aidevops.sh](https://aidevops.sh).

[View {owner} on GitHub]({owner_url}) ·
[aidevops repository](https://github.com/marcusquinn/aidevops)
{MARKER_END}"""


def replace_block(readme: Path, block: str) -> bool:
    original = readme.read_text(encoding="utf-8")
    marker_pattern = re.compile(
        rf"(?ms)^{re.escape(MARKER_START)}$.*?^{re.escape(MARKER_END)}\s*"
    )
    content = marker_pattern.sub("", original).rstrip()
    trailing = ""
    trailing_match = TRAILING_METADATA.search(content)
    if trailing_match:
        trailing = trailing_match.group(1).strip()
        content = content[: trailing_match.start()].rstrip()
    content = LEGACY_SECTION.sub("", content).rstrip()
    updated = f"{content}\n\n{block}"
    if trailing:
        updated = f"{updated}\n\n{trailing}"
    updated = f"{updated}\n"
    if updated == original:
        return False
    readme.write_text(updated, encoding="utf-8")
    return True


def generate_chart(chart: Path, slug: str, script_dir: Path) -> bool:
    before = chart.read_bytes() if chart.exists() else None
    helper = script_dir / "star-history-helper.sh"
    if not helper.is_file() or helper.is_symlink():
        raise RuntimeError("managed-readme star-history helper is unavailable or unsafe")
    helper = helper.resolve()
    base_command = [
        "/bin/bash",
        str(helper),
    ]
    try:
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        subprocess.run(  # nosec B603 -- fixed Bash and verified helper with validated repository slug.
            base_command + ["fetch", "--repo", slug, "--output", str(chart)],
            check=True,
        )
    except subprocess.CalledProcessError:
        if chart.exists():
            print("managed-readme: live Star History refresh failed; preserving existing chart", file=sys.stderr)
            return False
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        subprocess.run(  # nosec B603 -- fixed Bash and verified helper with validated repository slug.
            base_command + ["seed", "--repo", slug, "--output", str(chart)],
            check=True,
        )
    return before != chart.read_bytes()


def ensure_assets(root: Path, slug: str, script_dir: Path, template: Path) -> list[str]:
    changed: list[str] = []
    chart = root / "docs/assets/star-history.svg"
    if generate_chart(chart, slug, script_dir):
        changed.append("docs/assets/star-history.svg")
    workflow = root / ".github/workflows/star-history.yml"
    if not workflow.exists():
        workflow.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(template, workflow)
        changed.append(".github/workflows/star-history.yml")
    return changed


def sync(root: Path, slug: str, script_dir: Path, template: Path) -> int:
    managed, reason = is_managed(root, slug)
    if not managed:
        print(f"managed-readme: skipped {slug}: {reason}", file=sys.stderr)
        return 0
    readme = root / "README.md"
    if not readme.is_file():
        print(f"managed-readme: README.md not found in {root}", file=sys.stderr)
        return 1
    try:
        owner, owner_url = verified_owner(slug)
        changed = ensure_assets(root, slug, script_dir, template)
        if replace_block(readme, render_block(slug, owner, owner_url)):
            changed.append("README.md")
    except (FileNotFoundError, OSError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"managed-readme: {exc}", file=sys.stderr)
        return 1
    state = ", ".join(changed) if changed else "already current"
    print(f"managed-readme: {slug}: {state}", file=sys.stderr)
    return 0


def check(root: Path, slug: str) -> int:
    managed, reason = is_managed(root, slug)
    if not managed:
        print(f"managed-readme: skipped {slug}: {reason}", file=sys.stderr)
        return 0
    readme = root / "README.md"
    required = [
        readme,
        root / "docs/assets/star-history.svg",
        root / ".github/workflows/star-history.yml",
    ]
    missing = [str(path.relative_to(root)) for path in required if not path.is_file()]
    text = readme.read_text(encoding="utf-8") if readme.is_file() else ""
    if text.count(MARKER_START) != 1 or text.count(MARKER_END) != 1:
        missing.append("one managed README marker block")
    if missing:
        print(f"managed-readme: drift: {', '.join(missing)}", file=sys.stderr)
        return 3
    print(f"managed-readme: {slug}: current", file=sys.stderr)
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("sync", "check"))
    parser.add_argument("--repo", required=True)
    parser.add_argument("--root", default=".")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if not SLUG_PATTERN.fullmatch(args.repo):
        print("managed-readme: invalid repository slug", file=sys.stderr)
        return 2
    root = Path(args.root).resolve()
    script_dir = Path(__file__).resolve().parent
    template = script_dir.parent / "templates/workflows/star-history-caller.yml"
    if args.command == "check":
        return check(root, args.repo)
    if not template.is_file():
        print(f"managed-readme: missing workflow template: {template}", file=sys.stderr)
        return 1
    return sync(root, args.repo, script_dir, template)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
