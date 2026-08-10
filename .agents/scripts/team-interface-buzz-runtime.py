#!/usr/bin/env python3
"""Prepare and install aidevops Buzz runtime contracts."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import argparse
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys

from _team_interface_buzz_runtime_anchor import (
    materialize_pinned_runtime,
    validate_existing_pinned_runtime,
)
from _team_interface_buzz_runtime_install import (
    backup_existing,
    buzz_is_running,
    default_app_data_dir,
)
from _team_interface_buzz_runtime_io import RuntimeError, atomic_write, canonical_payload
from _team_interface_buzz_runtime_prepare import prepare_runtime


SCRIPT_DIR = Path(__file__).resolve().parent
AGENTS_DIR = SCRIPT_DIR.parent
PROJECT_VALIDATOR = SCRIPT_DIR / "team-interface-opencode-overlay.mjs"
RUNTIME_PROFILES = {
    "conversation": {
        "command": "aidevops-buzz-acp",
        "id": "aidevops-conversation-v1",
        "manifest": AGENTS_DIR / "configs" / "buzz-runtime-aidevops-conversation-v1.json",
    },
    "interactive": {
        "command": "aidevops-buzz-acp-interactive",
        "id": "aidevops-interactive-v1",
        "manifest": AGENTS_DIR / "configs" / "buzz-runtime-aidevops-interactive-v1.json",
    },
    "lm-studio": {
        "command": "aidevops-buzz-lm-studio-acp",
        "id": "aidevops-lm-studio-v1",
        "manifest": AGENTS_DIR / "configs" / "buzz-runtime-aidevops-lm-studio-v1.json",
    },
}
EXPECTED_MANIFEST_KEYS = {
    "args",
    "command",
    "env",
    "id",
    "installHint",
    "installInstructionsUrl",
    "label",
}
MAX_MANIFEST_BYTES = 64 * 1024
VALIDATION_TIMEOUT_SECONDS = 30


def runtime_profile(name):
    """Return one closed runtime profile by its command-line name."""
    try:
        return RUNTIME_PROFILES[name]
    except KeyError as error:
        raise RuntimeError("unknown aidevops Buzz runtime profile") from error


def validate_manifest(value, profile):
    """Validate the closed custom-harness manifest owned by aidevops."""
    if not isinstance(value, dict) or set(value) != EXPECTED_MANIFEST_KEYS:
        raise RuntimeError("canonical Buzz runtime manifest has an unexpected shape")
    if value.get("id") != profile["id"] or value.get("command") != profile["command"]:
        raise RuntimeError("canonical Buzz runtime identity or command drifted")
    if value.get("args") != [] or value.get("env") != {}:
        raise RuntimeError("canonical Buzz runtime source must remain machine-neutral")
    if not isinstance(value.get("label"), str) or not value["label"].strip():
        raise RuntimeError("canonical Buzz runtime label is unavailable")
    for key in ("installHint", "installInstructionsUrl"):
        if not isinstance(value.get(key), str):
            raise RuntimeError(f"canonical Buzz runtime {key} must be a string")
    return value


def load_manifest(profile):
    """Load the bounded canonical runtime manifest."""
    try:
        source = profile["manifest"]
        metadata = source.lstat()
        if not stat.S_ISREG(metadata.st_mode) or source.is_symlink():
            raise RuntimeError("canonical Buzz runtime manifest must be a regular non-symlink file")
        if metadata.st_size > MAX_MANIFEST_BYTES:
            raise RuntimeError("canonical Buzz runtime manifest exceeds its size limit")
        return validate_manifest(json.loads(source.read_text(encoding="utf-8")), profile)
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError("canonical Buzz runtime manifest is unavailable or invalid") from error


def registered_project_root(requested, repos_path):
    """Resolve a project root through the existing closed repository validator."""
    requested_path = Path(os.path.expanduser(requested))
    if not requested_path.is_absolute():
        raise RuntimeError("project root must be absolute")
    node = shutil.which("node")
    if not node:
        raise RuntimeError("node is required to validate the registered project root")
    result = subprocess.run(  # nosec B603 -- resolved executable and fixed validator argv
        [
            node,
            str(PROJECT_VALIDATOR),
            "validate-project-root",
            "--dir",
            str(requested_path),
            "--repos",
            str(Path(os.path.expanduser(repos_path))),
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=VALIDATION_TIMEOUT_SECONDS,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise RuntimeError("project root is not a registered canonical repository or linked worktree")
    return Path(result.stdout.strip())


def stable_runtime_command(profile):
    """Resolve the stable deployed launcher without trusting ambient PATH lookup."""
    stable_command = Path.home() / ".aidevops" / "bin" / profile["command"]
    expected_command = AGENTS_DIR / "bin" / profile["command"]
    try:
        stable_target = stable_command.resolve(strict=True)
        expected_target = expected_command.resolve(strict=True)
        metadata = stable_target.lstat()
    except OSError as error:
        raise RuntimeError("stable aidevops Buzz runtime command is unavailable") from error
    if stable_target != expected_target:
        raise RuntimeError("stable aidevops Buzz runtime command points outside the active bundle")
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise RuntimeError("stable aidevops Buzz runtime command is not a current-user regular file")
    if stat.S_IMODE(metadata.st_mode) & 0o022 or not os.access(stable_target, os.X_OK):
        raise RuntimeError("stable aidevops Buzz runtime command permissions are unsafe")
    return stable_command


def materialized_manifest(project_root, profile, pinned_runtime=None):
    """Bind one portable manifest to a validated local project root."""
    manifest = dict(load_manifest(profile))
    agents_dir = None if pinned_runtime is None else pinned_runtime / "agents"
    manifest["command"] = str(
        stable_runtime_command(profile)
        if agents_dir is None
        else agents_dir / "bin" / profile["command"]
    )
    manifest["env"] = {
        "AIDEVOPS_BUZZ_PROJECT_ROOT": str(project_root),
        "BUZZ_ACP_CWD": str(project_root),
    }
    if agents_dir is not None:
        manifest["env"]["AIDEVOPS_BUZZ_AGENTS_DIR"] = str(agents_dir)
        manifest["env"]["AIDEVOPS_REMOTE_REQUIRE_PINNED_RUNTIME"] = "1"
    return manifest


def install_manifest(project_root, app_data_dir, replace, profile):
    """Install one validated custom-harness definition while Buzz is stopped."""
    if buzz_is_running():
        raise RuntimeError("quit Buzz before installing or replacing its custom runtime manifest")
    runtime_id = profile["id"]
    target = app_data_dir / "custom_harnesses" / f"{runtime_id}.json"
    pinned = materialize_pinned_runtime(profile) if runtime_id == "aidevops-interactive-v1" else None
    payload = canonical_payload(materialized_manifest(project_root, profile, pinned))
    backup = None
    if target.exists() or target.is_symlink():
        if target.is_symlink() or not target.is_file():
            raise RuntimeError("existing Buzz runtime path is not a regular file")
        if target.read_bytes() == payload:
            return target, None
        if not replace:
            raise RuntimeError("Buzz runtime already exists with different content; inspect it or pass --replace")
        backup = backup_existing(target, runtime_id)
    atomic_write(target, payload)
    return target, backup


def parse_args(argv=None):
    """Parse the bounded runtime management command line."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    manifest = commands.add_parser("manifest", help="materialize the local runtime manifest")
    manifest.add_argument("--project-root", required=True)
    manifest.add_argument("--runtime", choices=tuple(RUNTIME_PROFILES), default="conversation")
    manifest.add_argument("--repos", default="~/.config/aidevops/repos.json")
    manifest.add_argument("--output")
    install = commands.add_parser("install", help="install the local Buzz custom runtime")
    install.add_argument("--project-root", required=True)
    install.add_argument("--runtime", choices=tuple(RUNTIME_PROFILES), default="conversation")
    install.add_argument("--repos", default="~/.config/aidevops/repos.json")
    install.add_argument("--app-data-dir")
    install.add_argument("--replace", action="store_true")
    prepare = commands.add_parser("prepare", help="prepare private inputs for one trusted launch")
    prepare.add_argument("--agents-dir", required=True)
    prepare.add_argument("--output-dir", required=True)
    verify = commands.add_parser("verify-anchor", help="verify an existing immutable runtime anchor")
    verify.add_argument("--root", required=True)
    verify.add_argument("--runtime", choices=tuple(RUNTIME_PROFILES), default="interactive")
    return parser.parse_args(argv)


def main(argv=None):
    """Run one runtime management action."""
    args = parse_args(argv)
    if args.command == "prepare":
        agents_dir = Path(os.path.expanduser(args.agents_dir)).resolve()
        output_dir = Path(os.path.expanduser(args.output_dir))
        if not agents_dir.is_dir():
            raise RuntimeError("canonical agents directory is unavailable")
        prepare_runtime(agents_dir, output_dir)
        return 0
    if args.command == "verify-anchor":
        root = Path(os.path.expanduser(args.root))
        if not root.is_absolute():
            raise RuntimeError("Buzz runtime anchor root must be absolute")
        validate_existing_pinned_runtime(root, runtime_profile(args.runtime))
        return 0
    project_root = registered_project_root(args.project_root, args.repos)
    profile = runtime_profile(args.runtime)
    if args.command == "manifest":
        payload = canonical_payload(materialized_manifest(project_root, profile))
        if args.output:
            atomic_write(Path(os.path.expanduser(args.output)), payload)
        else:
            sys.stdout.buffer.write(payload)
        return 0
    app_data_dir = (
        Path(os.path.expanduser(args.app_data_dir))
        if args.app_data_dir
        else default_app_data_dir()
    )
    if not app_data_dir.is_absolute():
        raise RuntimeError("Buzz app-data directory must be absolute")
    target, backup = install_manifest(project_root, app_data_dir, args.replace, profile)
    print(f"Installed {profile['id']} at {target}")
    if backup:
        print(f"Previous manifest backed up at {backup}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(f"team-interface-buzz-runtime: {error}", file=sys.stderr)
        raise SystemExit(1) from error
