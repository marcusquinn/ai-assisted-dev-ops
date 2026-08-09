"""Content-addressed immutable anchor management for Buzz OpenCode runtimes."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile

from _team_interface_buzz_runtime_agents import copy_pinned_agents
from _team_interface_buzz_runtime_config import (
    config_contains_private_fields,
    expected_command_payloads,
    hash_opencode_config,
    pinned_content_digest,
    pinned_opencode_config,
    write_pinned_opencode_config,
)
from _team_interface_buzz_runtime_io import (
    RuntimeError,
    atomic_write,
    canonical_payload,
    command_payloads,
    hash_runtime_tree,
    require_safe_directory_chain,
    valid_runtime_marker,
)


SCRIPT_DIR = Path(__file__).resolve().parent
AGENTS_DIR = SCRIPT_DIR.parent
VALIDATION_TIMEOUT_SECONDS = 30
PINNED_RUNTIME_SCHEMA_VERSION = 2
PINNED_RUNTIME_MARKER = "buzz-runtime-anchor-v1.json"
PINNED_CONFIG_DIRECTORY = "opencode-config"
PINNED_NODE_PACKAGES = (
    "@opencode-ai/plugin",
    "@opencode-ai/sdk",
    "ajv",
    "fast-deep-equal",
    "fast-uri",
    "json-schema-traverse",
    "require-from-string",
    "zod",
)
OPENCODE_PLUGIN_PACKAGES = {"@opencode-ai/plugin", "@opencode-ai/sdk", "zod"}


def git_common_node_modules():
    """Return the canonical checkout dependency directory for a linked worktree."""
    git = shutil.which("git")
    if not git:
        return None
    try:
        result = subprocess.run(  # nosec B603 -- resolved executable and fixed argv
            [
                git,
                "-C",
                str(AGENTS_DIR),
                "rev-parse",
                "--path-format=absolute",
                "--git-common-dir",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=VALIDATION_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0 or not result.stdout.strip():
        return None
    common_directory = Path(result.stdout.strip())
    if common_directory.name != ".git":
        return None
    return common_directory.parent / "node_modules"


def pinned_node_package_sources(config_source):
    """Resolve the closed local dependency set needed by the pinned plugin."""
    configured = os.environ.get("AIDEVOPS_BUZZ_OPENCODE_NODE_MODULES_DIR", "")
    opencode_candidates = []
    if configured:
        configured_path = Path(os.path.expanduser(configured))
        if not configured_path.is_absolute():
            raise RuntimeError("AIDEVOPS_BUZZ_OPENCODE_NODE_MODULES_DIR must be absolute")
        opencode_candidates.append(configured_path)
    opencode_candidates.append(config_source / "node_modules")
    framework_candidates = [
        AGENTS_DIR / "node_modules",
        AGENTS_DIR.parent / "node_modules",
    ]
    common_node_modules = git_common_node_modules()
    if common_node_modules is not None:
        framework_candidates.append(common_node_modules)
    sources = {}
    for package in PINNED_NODE_PACKAGES:
        candidates = opencode_candidates if package in OPENCODE_PLUGIN_PACKAGES else framework_candidates
        source = next(
            (
                candidate / package
                for candidate in candidates
                if (candidate / package).is_dir() and not (candidate / package).is_symlink()
            ),
            None,
        )
        if source is None:
            raise RuntimeError(f"pinned Node dependency is unavailable: {package}")
        package_manifest = source / "package.json"
        if package_manifest.is_symlink() or not package_manifest.is_file():
            raise RuntimeError(f"pinned Node dependency manifest is unavailable: {package}")
        sources[package] = source
    plugin_manifest = json.loads(
        sources["@opencode-ai/plugin"].joinpath("package.json").read_text(encoding="utf-8")
    )
    for dependency in ("@opencode-ai/sdk", "zod"):
        dependency_manifest = json.loads(
            sources[dependency].joinpath("package.json").read_text(encoding="utf-8")
        )
        expected_version = plugin_manifest.get("dependencies", {}).get(dependency)
        if not expected_version or dependency_manifest.get("version") != expected_version:
            raise RuntimeError(f"pinned OpenCode plugin dependency version drifted: {dependency}")
    return sources


def hash_pinned_agents(source_agents, node_packages):
    """Hash agent files and their closed runtime dependency set."""
    digest = hashlib.sha256()
    digest.update(hash_runtime_tree(source_agents).encode("ascii"))
    for package, source in sorted(node_packages.items()):
        digest.update(b"\0")
        digest.update(package.encode("utf-8"))
        digest.update(b"\0")
        digest.update(hash_runtime_tree(source).encode("ascii"))
    return digest.hexdigest()


def opencode_config_source():
    """Return the current private OpenCode configuration selected for pinning."""
    source = Path.home() / ".config" / "opencode"
    config = source / "opencode.json"
    if source.is_symlink() or not source.is_dir():
        raise RuntimeError("OpenCode config directory is unavailable for runtime pinning")
    if config.is_symlink() or not config.is_file():
        raise RuntimeError("OpenCode config is unavailable for runtime pinning")
    return source


def _load_pinned_runtime_documents(root, marker, config):
    """Load marker/config documents after validating their filesystem types."""
    try:
        metadata = root.lstat()
        marker_metadata = marker.lstat()
        config_metadata = config.lstat()
        marker_value = json.loads(marker.read_text(encoding="utf-8"))
        config_value = json.loads(config.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError("pinned Buzz runtime is unavailable or invalid") from error
    if not stat.S_ISDIR(metadata.st_mode) or root.is_symlink():
        raise RuntimeError("pinned Buzz runtime root is unsafe")
    if not stat.S_ISREG(marker_metadata.st_mode) or marker.is_symlink():
        raise RuntimeError("pinned Buzz runtime marker is unsafe")
    if not stat.S_ISREG(config_metadata.st_mode) or config.is_symlink():
        raise RuntimeError("pinned OpenCode config is unsafe")
    return marker_value, config_value


def _anchored_node_packages(root):
    """Return the validated closed Node dependency set in one runtime anchor."""
    anchored_packages = {}
    for package in PINNED_NODE_PACKAGES:
        package_root = root / "node_modules" / package
        package_manifest = package_root / "package.json"
        if (
            package_root.is_symlink()
            or not package_root.is_dir()
            or package_manifest.is_symlink()
            or not package_manifest.is_file()
        ):
            raise RuntimeError(f"pinned Node dependency is unavailable: {package}")
        anchored_packages[package] = package_root
    return anchored_packages


def _anchored_agents_digest(agents, anchored_packages):
    """Hash anchored agents and convert filesystem failures to runtime errors."""
    try:
        return hash_pinned_agents(agents, anchored_packages)
    except OSError as error:
        raise RuntimeError("pinned Buzz runtime content is unavailable") from error


def _anchored_command_payloads(config):
    """Read anchored command payloads with a stable runtime-facing error."""
    try:
        return command_payloads(config.parent)
    except OSError as error:
        raise RuntimeError("pinned OpenCode command content is unavailable") from error


def _require_anchored_command(command):
    """Require one executable regular command inside the anchor."""
    if command.is_symlink() or not command.is_file() or not os.access(command, os.X_OK):
        raise RuntimeError("pinned Buzz runtime command is unavailable")


def _require_anchored_agents(root):
    """Require and return the non-symlink anchored agents directory."""
    agents = root / "agents"
    if agents.is_symlink() or not agents.is_dir():
        raise RuntimeError("pinned Buzz runtime agent directory is unsafe")
    return agents


def pinned_runtime_content(root, profile):
    """Read and verify one self-contained immutable runtime anchor."""
    root = require_safe_directory_chain(root)
    marker = root / PINNED_RUNTIME_MARKER
    command = root / "agents" / "bin" / profile["command"]
    config = root / PINNED_CONFIG_DIRECTORY / "opencode" / "opencode.json"
    marker_value, config_value = _load_pinned_runtime_documents(root, marker, config)
    if not valid_runtime_marker(marker_value, profile["id"], PINNED_RUNTIME_SCHEMA_VERSION):
        raise RuntimeError("pinned Buzz runtime marker is invalid")
    _require_anchored_command(command)
    agents = _require_anchored_agents(root)
    anchored_agents_digest = _anchored_agents_digest(agents, _anchored_node_packages(root))
    if anchored_agents_digest != marker_value["agents_digest"]:
        raise RuntimeError("pinned Buzz runtime agent or dependency content drifted")
    expected_plugin = (root / "agents" / "plugins" / "opencode-aidevops" / "index.mjs").as_uri()
    if config_value.get("plugin") != [expected_plugin]:
        raise RuntimeError("pinned OpenCode config does not select the anchored plugin")
    if config_contains_private_fields(config_value):
        raise RuntimeError("pinned OpenCode config contains credential-bearing fields")
    actual_commands = _anchored_command_payloads(config)
    actual_digest = pinned_content_digest(anchored_agents_digest, config_value, actual_commands)
    if actual_digest != marker_value["content_digest"]:
        raise RuntimeError("pinned Buzz runtime content digest drifted")
    return {"commands": actual_commands, "config": config_value, "marker": marker_value}


def validate_existing_pinned_runtime(root, profile):
    """Validate an existing anchor without consulting mutable source state."""
    pinned_runtime_content(root, profile)
    return root


def validate_pinned_runtime(root, profile, expectation):
    """Validate one immutable runtime anchor against its current source state."""
    content = pinned_runtime_content(root, profile)
    if content["marker"] != expectation["marker"]:
        raise RuntimeError("pinned Buzz runtime marker does not match its source state")
    if content["config"] != expectation["config"]:
        raise RuntimeError("pinned OpenCode config content drifted")
    if content["commands"] != expectation["commands"]:
        raise RuntimeError("pinned OpenCode command content drifted")
    return root


def materialize_pinned_runtime(profile):
    """Copy tested agent state and the OpenCode profile into an immutable anchor."""
    source_agents = AGENTS_DIR.resolve(strict=True)
    source_config = opencode_config_source()
    node_packages = pinned_node_package_sources(source_config)
    config_digest = hash_opencode_config(source_config)
    parent = require_safe_directory_chain(
        Path.home() / ".aidevops" / "buzz-runtimes" / profile["id"]
    )
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    require_safe_directory_chain(parent)
    os.chmod(parent, 0o700)
    staging = Path(tempfile.mkdtemp(prefix=".staging-", dir=parent))
    try:
        copy_pinned_agents(source_agents, staging / "agents")
        agents_digest = hash_pinned_agents(staging / "agents", node_packages)
        root = parent / (
            f"v{PINNED_RUNTIME_SCHEMA_VERSION}-{agents_digest[:16]}-{config_digest[:16]}"
        )
        pinned_agents = root / "agents"
        expected_config = pinned_opencode_config(source_config, source_agents, pinned_agents)
        expected_commands = expected_command_payloads(source_config, source_agents, pinned_agents)
        expectation = {
            "commands": expected_commands,
            "config": expected_config,
            "marker": {
                "agents_digest": agents_digest,
                "config_digest": config_digest,
                "content_digest": pinned_content_digest(
                    agents_digest, expected_config, expected_commands
                ),
                "runtime_id": profile["id"],
                "schema_version": PINNED_RUNTIME_SCHEMA_VERSION,
            },
        }
        if root.exists() or root.is_symlink():
            return validate_pinned_runtime(root, profile, expectation)
        for package, source in node_packages.items():
            shutil.copytree(
                source,
                staging / "node_modules" / package,
                symlinks=True,
                ignore=shutil.ignore_patterns(".DS_Store", "__pycache__", "*.pyc"),
            )
        write_pinned_opencode_config(
            staging / PINNED_CONFIG_DIRECTORY / "opencode",
            expected_config,
            expected_commands,
        )
        atomic_write(
            staging / PINNED_RUNTIME_MARKER,
            canonical_payload(expectation["marker"]),
        )
        os.replace(staging, root)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return validate_pinned_runtime(root, profile, expectation)
