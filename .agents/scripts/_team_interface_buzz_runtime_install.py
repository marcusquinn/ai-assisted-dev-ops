"""Local process and rollback helpers for Buzz runtime installation."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from datetime import datetime, timezone
import os
from pathlib import Path
import subprocess
import sys

from _team_interface_buzz_runtime_io import RuntimeError, atomic_write


def default_app_data_dir():
    """Return the supported local Buzz app-data directory."""
    configured = os.environ.get("AIDEVOPS_BUZZ_APP_DATA_DIR")
    if configured:
        candidate = Path(os.path.expanduser(configured))
        if not candidate.is_absolute():
            raise RuntimeError("AIDEVOPS_BUZZ_APP_DATA_DIR must be absolute")
        return candidate
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "xyz.block.buzz.app"
    raise RuntimeError("set AIDEVOPS_BUZZ_APP_DATA_DIR on this platform")


def buzz_is_running():
    """Return whether Buzz is running, with a deterministic test override."""
    override = os.environ.get("AIDEVOPS_BUZZ_RUNNING_OVERRIDE")
    if override in {"true", "1"}:
        return True
    if override in {"false", "0"} or sys.platform != "darwin":
        return False
    result = subprocess.run(  # nosec B603 -- absolute executable and fixed argv
        ["/usr/bin/pgrep", "-x", "Buzz"],
        check=False,
        capture_output=True,
        timeout=5,
    )
    return result.returncode == 0


def backup_existing(path, runtime_id):
    """Copy an existing runtime manifest into private aidevops rollback storage."""
    if not path.exists():
        return None
    backup_dir = Path.home() / ".aidevops" / "buzz-backups"
    if backup_dir.is_symlink():
        raise RuntimeError("backup directory must not be a symbolic link")
    backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if backup_dir.is_symlink() or not backup_dir.is_dir():
        raise RuntimeError("backup directory is unsafe")
    os.chmod(backup_dir, 0o700)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = backup_dir / f"{runtime_id}.{timestamp}.json"
    atomic_write(backup, path.read_bytes())
    return backup
