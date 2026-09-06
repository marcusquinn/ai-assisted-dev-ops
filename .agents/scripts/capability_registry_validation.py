"""Drift validation for the committed capability registry."""

from __future__ import annotations

from pathlib import Path
import re
from typing import Any


def _identity_errors(capability: dict[str, Any], names: set[str], aliases: set[str]) -> list[str]:
    name = capability.get("name", "")
    errors = [f"duplicate capability: {name}"] if name in names else []
    names.add(name)
    for alias in capability.get("aliases", []):
        if alias in aliases or alias in names:
            errors.append(f"duplicate alias: {alias}")
        aliases.add(alias)
    return errors


def _reference_errors(capability: dict[str, Any], agents_dir: Path, agent_index: str) -> list[str]:
    name = capability.get("name", "")
    owner = capability.get("owner", "")
    errors = [] if re.search(rf"^{re.escape(owner)},", agent_index, re.MULTILINE) else [f"unknown owner: {owner} ({name})"]
    errors.extend(f"invalid entry point: {entry} ({name})" for entry in capability.get("entry_points", []) if not (agents_dir / entry).is_file())
    return errors


def _readiness_errors(capability: dict[str, Any], dimensions: set[str]) -> list[str]:
    name = capability.get("name", "")
    probes = capability.get("probes", {})
    errors: list[str] = []
    for dimension in capability.get("required", []):
        if dimension not in dimensions:
            errors.append(f"unknown readiness dimension: {dimension} ({name})")
        if dimension not in probes and dimension not in {"catalogued", "runtime_compatible"}:
            errors.append(f"required claim has no probe: {dimension} ({name})")
    return errors


def _mcp_errors(capability: dict[str, Any], mcp_source: str) -> list[str]:
    mcp = capability.get("mcp")
    known = not mcp or re.search(rf'name:\s*["\']{re.escape(mcp)}["\']', mcp_source)
    return [] if known else [f"unknown MCP: {mcp} ({capability.get('name', '')})"]


def _view_errors(registry: dict[str, Any], agents_dir: Path) -> list[str]:
    names: set[str] = set()
    errors: list[str] = []
    for view in registry.get("views", []):
        name = view.get("name", "")
        if not name:
            errors.append("view has no name")
        elif name in names:
            errors.append(f"duplicate view: {name}")
        names.add(name)
        for field in ("owner", "source"):
            if not view.get(field):
                errors.append(f"view has no {field}: {name}")
        for field in ("source", "derived"):
            path = view.get(field)
            if path and not (agents_dir / path).is_file():
                errors.append(f"invalid {field} view path: {path} ({name})")
    return errors


def validate(registry: dict[str, Any], agents_dir: Path) -> list[str]:
    agent_index = (agents_dir / "subagent-index.toon").read_text(encoding="utf-8")
    mcp_source = (agents_dir / "plugins" / "opencode-aidevops" / "mcp-registry.mjs").read_text(encoding="utf-8")
    dimensions = set(registry.get("dimensions", []))
    names: set[str] = set()
    aliases: set[str] = set()
    errors = _view_errors(registry, agents_dir)
    for capability in registry.get("capabilities", []):
        errors.extend(_identity_errors(capability, names, aliases))
        errors.extend(_reference_errors(capability, agents_dir, agent_index))
        errors.extend(_readiness_errors(capability, dimensions))
        errors.extend(_mcp_errors(capability, mcp_source))
    return errors
