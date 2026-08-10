#!/usr/bin/env python3
"""Validate and query LM Studio's supported local CLI surfaces."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess


COMMAND_TIMEOUT_SECONDS = 15
MAX_JSON_BYTES = 1024 * 1024
MODEL_IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/@:+-]{0,255}$")


class LMStudioError(ValueError):
    """Raised when LM Studio's supported local interface is unsafe or unusable."""


def validate_executable(candidate, label):
    """Return one trusted local executable path or raise for an explicit override."""
    path = Path(os.path.expanduser(candidate))
    if not path.is_absolute():
        raise LMStudioError(f"{label} must be an absolute path")
    try:
        resolved = path.resolve(strict=True)
        metadata = resolved.lstat()
    except OSError as error:
        raise LMStudioError(f"{label} is unavailable") from error
    if not stat.S_ISREG(metadata.st_mode) or not os.access(resolved, os.X_OK):
        raise LMStudioError(f"{label} must be an executable regular file")
    if metadata.st_uid not in (0, os.getuid()) or stat.S_IMODE(metadata.st_mode) & 0o022:
        raise LMStudioError(f"{label} permissions are unsafe")
    return resolved


def resolve_lms_cli():
    """Resolve LM Studio's supported CLI without launching the GUI application."""
    configured = os.environ.get("AIDEVOPS_LM_STUDIO_CLI")
    if configured:
        return validate_executable(configured, "AIDEVOPS_LM_STUDIO_CLI")
    candidates = []
    path_candidate = shutil.which("lms")
    if path_candidate:
        candidates.append(path_candidate)
    candidates.append(str(Path.home() / ".lmstudio" / "bin" / "lms"))
    for candidate in candidates:
        try:
            return validate_executable(candidate, "LM Studio CLI")
        except LMStudioError:
            continue
    return None


def run_json_command(executable, arguments, label):
    """Run one bounded fixed-argument JSON command."""
    try:
        result = subprocess.run(  # nosec B603 -- validated executable and fixed argv
            [str(executable), *arguments],
            check=False,
            capture_output=True,
            text=True,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LMStudioError(f"{label} failed") from error
    if result.returncode != 0:
        raise LMStudioError(f"{label} exited unsuccessfully")
    if len(result.stdout.encode("utf-8")) > MAX_JSON_BYTES:
        raise LMStudioError(f"{label} output exceeded its size limit")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise LMStudioError(f"{label} returned invalid JSON") from error


def validated_model_identifier(value):
    """Return one prompt-safe LM Studio model identifier."""
    if not isinstance(value, str) or not MODEL_IDENTIFIER_PATTERN.fullmatch(value):
        return None
    return value


def loaded_llm_identifiers(value):
    """Extract sorted unique identifiers for currently loaded LLMs."""
    if not isinstance(value, list):
        raise LMStudioError("LM Studio loaded-model response has an unexpected shape")
    identifiers = set()
    for record in value:
        if not isinstance(record, dict) or str(record.get("type", "")).casefold() != "llm":
            continue
        identifier = validated_model_identifier(
            record.get("identifier") or record.get("modelKey") or record.get("modelIdentifier")
        )
        if identifier:
            identifiers.add(identifier)
    return sorted(identifiers, key=lambda item: (item.casefold(), item))
