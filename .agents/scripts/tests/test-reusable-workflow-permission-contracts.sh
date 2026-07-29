#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Verify every canonical reusable-workflow caller grants its exact permission union.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1

python3 - "$REPO_ROOT" <<'PYEOF'
from __future__ import annotations

import pathlib
import re
import sys
import tempfile

try:
    import yaml
except ImportError as exc:
    raise SystemExit("FAIL: PyYAML is required for workflow permission contract tests") from exc


ROOT = pathlib.Path(sys.argv[1])
CALLER_DIR = ROOT / ".agents" / "templates" / "workflows"
REUSABLE_DIR = ROOT / ".github" / "workflows"
REMOTE_USES_PATTERN = re.compile(
    r"^marcusquinn/aidevops/\.github/workflows/([^/@]+\.ya?ml)@"
)
LOCAL_USES_PATTERN = re.compile(r"^\./\.github/workflows/([^/]+\.ya?ml)$")
LEVELS = {"none": 0, "read": 1, "write": 2}


def load_mapping(path: pathlib.Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        value = yaml.safe_load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: workflow root must be a mapping")
    return value


def explicit_permissions(value: object, context: str) -> dict[str, str]:
    if value is None:
        raise ValueError(f"{context}: permissions must be an explicit mapping")
    if not isinstance(value, dict):
        raise ValueError(f"{context}: permissions must be an explicit mapping")
    normalized: dict[str, str] = {}
    for permission, level in value.items():
        if not isinstance(permission, str) or level not in LEVELS:
            raise ValueError(f"{context}: unsupported permission {permission}={level}")
        if level != "none":
            normalized[permission] = level
    return normalized


def reusable_path_for_uses(
    uses: str, reusable_dir: pathlib.Path = REUSABLE_DIR
) -> pathlib.Path | None:
    local_match = LOCAL_USES_PATTERN.match(uses)
    if local_match:
        return reusable_dir / local_match.group(1)
    remote_match = REMOTE_USES_PATTERN.match(uses)
    if remote_match:
        return reusable_dir / remote_match.group(1)
    return None


def merge_permission_union(
    target: dict[str, str], additions: dict[str, str]
) -> None:
    for permission, level in additions.items():
        if LEVELS[level] > LEVELS.get(target.get(permission, "none"), 0):
            target[permission] = level


def reusable_permission_union(
    workflow_path: pathlib.Path,
    reusable_dir: pathlib.Path = REUSABLE_DIR,
    active: set[pathlib.Path] | None = None,
) -> dict[str, str]:
    resolved_path = workflow_path.resolve()
    active = set() if active is None else active
    if resolved_path in active:
        raise ValueError(f"{workflow_path}: recursive reusable-workflow cycle")
    active.add(resolved_path)
    workflow = load_mapping(workflow_path)
    context = str(workflow_path)
    top = (
        explicit_permissions(workflow["permissions"], f"{context}: top level")
        if "permissions" in workflow
        else None
    )
    required: dict[str, str] = {}
    jobs = workflow.get("jobs", {}) or {}
    if not isinstance(jobs, dict) or not jobs:
        raise ValueError(f"{context}: jobs must be a non-empty mapping")
    try:
        for job_name, job in jobs.items():
            if not isinstance(job, dict):
                raise ValueError(f"{context}: job {job_name} must be a mapping")
            permissions = explicit_permissions(
                job.get("permissions") if "permissions" in job else top,
                f"{context}: job {job_name}",
            )
            merge_permission_union(required, permissions)
            uses = job.get("uses")
            if isinstance(uses, str):
                nested_path = reusable_path_for_uses(uses, reusable_dir)
                if nested_path is not None:
                    nested_required = reusable_permission_union(
                        nested_path, reusable_dir, active
                    )
                    if permissions != nested_required:
                        raise ValueError(
                            f"{context}: job {job_name} permissions={permissions}; "
                            f"nested_union={nested_required} from {nested_path.name}"
                        )
                    merge_permission_union(required, nested_required)
        return required
    finally:
        active.remove(resolved_path)


def discover_caller_paths(
    caller_dir: pathlib.Path, workflow_dir: pathlib.Path
) -> list[pathlib.Path]:
    return sorted(
        set(caller_dir.glob("*-caller.yml"))
        | set(caller_dir.glob("*-caller.yaml"))
        | set(workflow_dir.glob("*.yml"))
        | set(workflow_dir.glob("*.yaml"))
    )


def assert_discovery_contract() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        root = pathlib.Path(temp_dir)
        caller_dir = root / "callers"
        workflow_dir = root / "workflows"
        caller_dir.mkdir()
        workflow_dir.mkdir()
        yaml_caller = caller_dir / "fixture-caller.yaml"
        nested_reusable = workflow_dir / "outer-reusable.yaml"
        inner_reusable = workflow_dir / "inner-reusable.yaml"
        yaml_caller.write_text("jobs: {}\n", encoding="utf-8")
        nested_reusable.write_text(
            "jobs:\n  nested:\n    permissions:\n      issues: read\n"
            "    uses: ./.github/workflows/inner-reusable.yaml\n",
            encoding="utf-8",
        )
        inner_reusable.write_text(
            "jobs:\n  leaf:\n    permissions:\n      issues: read\n    runs-on: ubuntu-latest\n    steps: []\n",
            encoding="utf-8",
        )
        discovered = set(discover_caller_paths(caller_dir, workflow_dir))
        if yaml_caller not in discovered or nested_reusable not in discovered:
            raise AssertionError(
                "caller discovery must include .yaml and reusable-to-reusable workflows"
            )
        nested_union = reusable_permission_union(nested_reusable, workflow_dir)
        if nested_union != {"issues": "read"}:
            raise AssertionError(
                f"nested reusable permission union was not propagated: {nested_union}"
            )
        implicit_reusable = workflow_dir / "implicit-reusable.yml"
        implicit_reusable.write_text(
            "jobs:\n  leaf:\n    runs-on: ubuntu-latest\n    steps: []\n",
            encoding="utf-8",
        )
        try:
            reusable_permission_union(implicit_reusable, workflow_dir)
        except ValueError as exc:
            if "permissions must be an explicit mapping" not in str(exc):
                raise
        else:
            raise AssertionError("implicit repository-default permissions were accepted")
        nested_reusable.write_text(
            "jobs:\n  nested:\n    permissions:\n      contents: read\n"
            "    uses: ./.github/workflows/inner-reusable.yaml\n",
            encoding="utf-8",
        )
        try:
            reusable_permission_union(nested_reusable, workflow_dir)
        except ValueError:
            pass
        else:
            raise AssertionError("insufficient intermediate permissions were accepted")


def main() -> int:
    checked = 0
    failures: list[str] = []
    assert_discovery_contract()
    caller_paths = discover_caller_paths(CALLER_DIR, REUSABLE_DIR)
    for caller_path in caller_paths:
        try:
            caller = load_mapping(caller_path)
            caller_top = (
                explicit_permissions(
                    caller["permissions"], f"{caller_path}: top level"
                )
                if "permissions" in caller
                else None
            )
            jobs = caller.get("jobs", {}) or {}
            if not isinstance(jobs, dict):
                raise ValueError(f"{caller_path}: jobs must be a mapping")
            for job_name, job in jobs.items():
                if not isinstance(job, dict):
                    continue
                uses = job.get("uses")
                if not isinstance(uses, str):
                    continue
                reusable_path = reusable_path_for_uses(uses)
                if reusable_path is None:
                    continue
                required = reusable_permission_union(reusable_path)
                granted = explicit_permissions(
                    job.get("permissions") if "permissions" in job else caller_top,
                    f"{caller_path}: calling job {job_name}",
                )
                checked += 1
                if granted != required:
                    failures.append(
                        f"{caller_path.name}:{job_name}: caller={granted}; "
                        f"required_union={required} from {reusable_path.name}"
                    )
                else:
                    print(f"PASS {caller_path.name} -> {reusable_path.name}")
        except (OSError, ValueError, yaml.YAMLError) as exc:
            failures.append(str(exc))

    if checked == 0:
        failures.append("no canonical reusable-workflow caller pairs were found")
    if failures:
        for failure in failures:
            print(f"FAIL {failure}", file=sys.stderr)
        return 1
    print(f"PASS all {checked} reusable-workflow permission contract(s)")
    return 0


raise SystemExit(main())
PYEOF
