"""Probe and assessment primitives for capability readiness."""

from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
from typing import Any, Callable

STATES = {"true", "false", "unknown", "not_applicable"}


def _command(spec: dict[str, Any], _: Path) -> str:
    return "true" if shutil.which(spec["command"]) else "false"


def _command_check(spec: dict[str, Any], _: Path) -> str:
    executable = shutil.which(spec["command_check"][0])
    if not executable:
        return "false"
    argv = [executable, *spec["command_check"][1:]]
    result = subprocess.run(argv, capture_output=True, check=False, timeout=10)  # nosec B603
    return "true" if result.returncode == 0 else "false"


def _path(spec: dict[str, Any], agents_dir: Path) -> str:
    return "true" if (agents_dir / spec["path"]).exists() else "false"


def _path_home(spec: dict[str, Any], _: Path) -> str:
    return "true" if (Path.home() / spec["path_home"]).exists() else "false"


def _path_home_any(spec: dict[str, Any], _: Path) -> str:
    return "true" if any((Path.home() / path).exists() for path in spec["path_home_any"]) else "false"


def _env_any(spec: dict[str, Any], _: Path) -> str:
    return "true" if any(os.environ.get(name) for name in spec["env_any"]) else "false"


def _env_all(spec: dict[str, Any], _: Path) -> str:
    return "true" if all(os.environ.get(name) for name in spec["env_all"]) else "false"


def _env_pattern(spec: dict[str, Any], _: Path) -> str:
    template = re.escape(spec["env_pattern"])
    pattern = (
        "^"
        + re.sub(r"<[^>]+>", "[A-Z0-9_]+", template).replace(r"\*", ".*")
        + "$"
    )
    return (
        "true"
        if any(value and re.match(pattern, name) for name, value in os.environ.items())
        else "false"
    )


def _tool(spec: dict[str, Any], _: Path) -> str:
    visible = [item.strip() for item in os.environ.get("AIDEVOPS_VISIBLE_TOOLS", "").split(",") if item.strip()]
    if not visible:
        return "unknown"
    pattern = "^" + re.escape(spec["tool"]).replace(r"\*", ".*") + "$"
    return "true" if any(re.match(pattern, item) for item in visible) else "false"


PROBES: tuple[tuple[str, Callable[[dict[str, Any], Path], str]], ...] = (
    ("command", _command), ("command_check", _command_check), ("path", _path),
    ("path_home", _path_home), ("path_home_any", _path_home_any),
    ("env_any", _env_any), ("env_all", _env_all), ("env_pattern", _env_pattern),
    ("tool", _tool),
)


def probe_value(spec: dict[str, Any], agents_dir: Path) -> str:
    handler = next((candidate for key, candidate in PROBES if key in spec), None)
    return handler(spec, agents_dir) if handler else "unknown"


def assess(capability: dict[str, Any], dimensions: list[str], runtime: str, fixture: dict[str, Any] | None, agents_dir: Path) -> dict[str, Any]:
    readiness = dict.fromkeys(dimensions, "unknown")
    readiness["catalogued"] = "true"
    readiness["runtime_compatible"] = "true" if runtime in capability["runtimes"] else ("unknown" if runtime == "unknown" else "false")
    readiness.update({dimension: probe_value(spec, agents_dir) for dimension, spec in capability.get("probes", {}).items()})
    overrides = (fixture or {}).get("capabilities", {}).get(capability["name"], {})
    readiness.update({dimension: value for dimension, value in overrides.items() if dimension in readiness and value in STATES})
    missing = [dimension for dimension in capability["required"] if readiness[dimension] != "true"]
    return {**capability, "readiness": readiness, "route_ready": not missing, "missing_required": missing, "runtime": runtime}
