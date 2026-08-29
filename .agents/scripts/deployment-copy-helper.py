#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Audited copies from a verified linked worktree into an allowed non-Git target."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
from typing import Any, NamedTuple


SCHEMA = "aidevops.deployment-copy/v1"
RESULT_SCHEMA = "aidevops.deployment-copy-result/v1"
OPERATION_RE = re.compile(r"^op-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$")
SHA_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
TREE_SHA_RE = re.compile(r"^[0-9a-f]{64}$")
RECOVER_CONFIRMATION = "RECOVER_DEPLOYMENT_COPY"
ROLLBACK_CONFIRMATION = "ROLLBACK_DEPLOYMENT_COPY"


class DeploymentError(RuntimeError):
    """A safe, user-facing deployment refusal."""

    def __init__(self, message: str, operation_id_value: str | None = None) -> None:
        super().__init__(message)
        self.operation_id = operation_id_value


class PreparedDeployment(NamedTuple):
    """Validated inputs shared by deployment phases."""

    state_root: Path
    source_context: dict[str, Any]
    destination: Path
    source_tree: dict[str, Any]
    destination_tree: dict[str, Any] | None


class DeploymentOperation(NamedTuple):
    """Mutable state for one deployment attempt."""

    identifier: str
    prepared: PreparedDeployment
    rollback_path: Path
    displaced_path: Path
    receipt_path: Path
    receipt: dict[str, Any]
    progress: dict[str, Any]


class RecoveryOperation(NamedTuple):
    """Validated paths and receipt state shared by recovery phases."""

    identifier: str
    destination: Path
    rollback_path: Path
    stage_path: Path | None
    receipt_path: Path
    receipt: dict[str, Any]


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def operation_id() -> str:
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"op-{timestamp}-{secrets.token_hex(6)}"


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    """Raise a user-facing refusal when a required invariant is false."""
    if not condition:
        raise DeploymentError(message)


def run_git(git_bin: str, cwd: Path, *args: str) -> str:
    result = subprocess.run(  # nosec B603 -- argv array; Git data is validated separately
        [git_bin, "-C", str(cwd), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    require(result.returncode == 0, "Git provenance could not be verified")
    return result.stdout.strip()


def path_is_within(candidate: Path, root: Path) -> bool:
    try:
        candidate.relative_to(root)
    except ValueError:
        return False
    return True


def assert_no_symlink_components(path: Path, require_leaf: bool = True) -> None:
    absolute = Path(os.path.abspath(str(path)))
    current = Path(absolute.anchor)
    parts = absolute.parts[1:]
    for index, part in enumerate(parts):
        current = current / part
        is_leaf = index == len(parts) - 1
        if not os.path.lexists(current):
            if require_leaf or not is_leaf:
                raise DeploymentError("A required path component does not exist")
            continue
        if stat.S_ISLNK(os.lstat(current).st_mode):
            raise DeploymentError("Symlinked paths are not accepted")


def assert_existing_components_not_symlinks(path: Path) -> None:
    absolute = Path(os.path.abspath(str(path)))
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current = current / part
        if not os.path.lexists(current):
            continue
        if stat.S_ISLNK(os.lstat(current).st_mode):
            raise DeploymentError("Symlinked paths are not accepted")


def canonical_existing_directory(raw_path: str, purpose: str) -> Path:
    candidate = Path(raw_path)
    require(candidate.is_absolute(), f"{purpose} must be an absolute path")
    assert_no_symlink_components(candidate)
    require(candidate.is_dir(), f"{purpose} must be an existing directory")
    resolved = candidate.resolve(strict=True)
    require(
        not stat.S_ISLNK(os.lstat(candidate).st_mode),
        "Symlinked paths are not accepted",
    )
    return resolved


def canonical_destination(raw_path: str) -> Path:
    candidate = Path(raw_path)
    require(candidate.is_absolute(), "Destination must be an absolute path")
    normalized = Path(os.path.normpath(str(candidate)))
    parent = normalized.parent
    assert_no_symlink_components(parent)
    require(parent.is_dir(), "Destination parent must be an existing directory")
    if os.path.lexists(normalized):
        assert_no_symlink_components(normalized)
        require(normalized.is_dir(), "Destination must be a directory or absent")
        return normalized.resolve(strict=True)
    assert_no_symlink_components(normalized, require_leaf=False)
    return parent.resolve(strict=True) / normalized.name


def secure_state_root() -> Path:
    configured = os.environ.get(
        "AIDEVOPS_DEPLOYMENT_COPY_STATE_DIR",
        str(Path.home() / ".aidevops" / ".agent-workspace" / "deployment-copy"),
    )
    root = Path(configured)
    require(root.is_absolute(), "Deployment-copy state root must be absolute")
    normalized = Path(os.path.normpath(str(root)))
    if normalized == Path(normalized.anchor) or normalized == Path.home().resolve(strict=True):
        raise DeploymentError("Root and home directories cannot store deployment-copy state")
    assert_existing_components_not_symlinks(root)
    root_existed = os.path.lexists(root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    assert_no_symlink_components(root)
    resolved = root.resolve(strict=True)
    current = resolved.stat()
    require(
        current.st_uid == os.getuid(),
        "Deployment-copy state root has an unsafe owner",
    )
    if root_existed and stat.S_IMODE(current.st_mode) & 0o077:
        raise DeploymentError("Deployment-copy state root permissions are unsafe")
    if not root_existed:
        os.chmod(resolved, 0o700)
    for child in ("locks", "operations", "tmp"):
        child_path = resolved / child
        child_existed = os.path.lexists(child_path)
        child_path.mkdir(mode=0o700, exist_ok=True)
        require(
            not child_path.is_symlink() and child_path.stat().st_uid == os.getuid(),
            "Deployment-copy state storage is unsafe",
        )
        if child_existed and stat.S_IMODE(child_path.stat().st_mode) & 0o077:
            raise DeploymentError("Deployment-copy state storage permissions are unsafe")
        if not child_existed:
            os.chmod(child_path, 0o700)
    return resolved


def validate_source(raw_source: str, expected_sha: str, git_bin: str) -> dict[str, Any]:
    require(
        bool(SHA_RE.fullmatch(expected_sha)),
        "Expected source SHA must be a full commit identifier",
    )
    source = canonical_existing_directory(raw_source, "Source")
    require(
        not any(part.lower() == ".git" for part in source.parts),
        "Git metadata cannot be deployed",
    )
    repo_root = Path(run_git(git_bin, source, "rev-parse", "--show-toplevel")).resolve()
    git_dir = Path(
        run_git(git_bin, source, "rev-parse", "--path-format=absolute", "--git-dir")
    ).resolve()
    common_dir = Path(
        run_git(
            git_bin, source, "rev-parse", "--path-format=absolute", "--git-common-dir"
        )
    ).resolve()
    require(git_dir != common_dir, "Source must be inside a registered linked worktree")
    require(path_is_within(source, repo_root), "Source escapes its linked worktree")
    registered_worktrees = {
        Path(line.removeprefix("worktree ")).resolve()
        for line in run_git(git_bin, repo_root, "worktree", "list", "--porcelain").splitlines()
        if line.startswith("worktree ")
    }
    require(
        repo_root in registered_worktrees,
        "Source worktree is not registered in its Git repository",
    )
    resolved_sha = run_git(git_bin, repo_root, "rev-parse", "--verify", f"{expected_sha}^{{commit}}")
    head_sha = run_git(git_bin, repo_root, "rev-parse", "HEAD")
    require(
        resolved_sha == expected_sha and head_sha == expected_sha,
        "Source worktree does not match the expected commit",
    )
    source_relative = os.path.relpath(source, repo_root)
    return {
        "source": source,
        "repo_root": repo_root,
        "git_dir": git_dir,
        "common_dir": common_dir,
        "source_relative": source_relative,
        "expected_sha": expected_sha,
        "git_bin": git_bin,
    }


def visit_tree(
    directory: Path, relative: PurePosixPath, entries: list[dict[str, Any]]
) -> None:
    directory_stat = os.lstat(directory)
    require(
        stat.S_ISDIR(directory_stat.st_mode),
        "Tree changed while it was being inspected",
    )
    require(
        not stat.S_IMODE(directory_stat.st_mode) & 0o7000,
        "Tree entries must not use special permission bits",
    )
    entries.append(
        {
            "mode": f"{stat.S_IMODE(directory_stat.st_mode):04o}",
            "path": str(relative),
            "type": "directory",
        }
    )
    for item in sorted(os.scandir(directory), key=lambda value: value.name):
        require(item.name.lower() != ".git", "Git metadata cannot be deployed")
        item_path = Path(item.path)
        item_relative = relative / item.name if str(relative) != "." else PurePosixPath(item.name)
        item_stat = item.stat(follow_symlinks=False)
        require(
            not stat.S_ISLNK(item_stat.st_mode),
            "Source and destination trees must not contain symlinks",
        )
        if stat.S_ISDIR(item_stat.st_mode):
            visit_tree(item_path, item_relative, entries)
            continue
        require(
            stat.S_ISREG(item_stat.st_mode),
            "Source and destination trees must contain only regular files",
        )
        require(
            not stat.S_IMODE(item_stat.st_mode) & 0o7000,
            "Tree entries must not use special permission bits",
        )
        entries.append(
            {
                "mode": f"{stat.S_IMODE(item_stat.st_mode):04o}",
                "path": str(item_relative),
                "sha256": sha256_file(item_path),
                "size": item_stat.st_size,
                "type": "file",
            }
        )


def scan_tree(root: Path, require_files: bool = True) -> dict[str, Any]:
    require(
        root.is_dir() and not root.is_symlink(),
        "Tree root must be a non-symlink directory",
    )
    entries: list[dict[str, Any]] = []
    visit_tree(root, PurePosixPath("."), entries)
    file_count = sum(1 for entry in entries if entry["type"] == "file")
    require(
        not require_files or file_count > 0,
        "Source tree must contain at least one regular file",
    )
    exact_digest = sha256_bytes(canonical_json(entries))
    normalized_entries = []
    for entry in entries:
        normalized = {"path": entry["path"], "type": entry["type"]}
        if entry["type"] == "file":
            normalized["executable"] = bool(int(entry["mode"], 8) & 0o111)
            normalized["sha256"] = entry["sha256"]
            normalized["size"] = entry["size"]
        normalized_entries.append(normalized)
    return {
        "entries": entries,
        "exact_digest": exact_digest,
        "normalized_digest": sha256_bytes(canonical_json(normalized_entries)),
        "file_count": file_count,
        "total_bytes": sum(
            int(entry.get("size", 0)) for entry in entries if entry["type"] == "file"
        ),
    }


def safe_extract_git_archive(archive_path: Path, destination: Path) -> None:
    with tarfile.open(archive_path, "r") as archive:
        for member in archive.getmembers():
            relative = PurePosixPath(member.name)
            require(
                not relative.is_absolute() and ".." not in relative.parts,
                "Git archive contains an unsafe path",
            )
            target = destination.joinpath(*relative.parts)
            if member.isdir():
                target.mkdir(mode=member.mode & 0o777, parents=True, exist_ok=True)
                continue
            require(
                member.isfile(),
                "Committed source contains an unsupported file type",
            )
            target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            source_handle = archive.extractfile(member)
            require(
                source_handle is not None,
                "Committed source could not be materialized",
            )
            with source_handle, target.open("xb") as target_handle:
                shutil.copyfileobj(source_handle, target_handle, 1024 * 1024)
            os.chmod(target, member.mode & 0o777)


def verify_committed_source(context: dict[str, Any], source_tree: dict[str, Any], state_root: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="proof-", dir=state_root / "tmp") as temp_name:
        temp_root = Path(temp_name)
        archive_path = temp_root / "source.tar"
        proof_root = temp_root / "tree"
        proof_root.mkdir(mode=0o700)
        command = [
            context["git_bin"],
            "-C",
            str(context["repo_root"]),
            "archive",
            "--format=tar",
            f"--output={archive_path}",
            context["expected_sha"],
        ]
        if context["source_relative"] != ".":
            command.extend(["--", context["source_relative"]])
        result = subprocess.run(  # nosec B603 -- argv array built from validated Git provenance
            command, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        require(
            result.returncode == 0,
            "Committed source subtree could not be materialized",
        )
        safe_extract_git_archive(archive_path, proof_root)
        committed_root = (
            proof_root
            if context["source_relative"] == "."
            else proof_root / context["source_relative"]
        )
        require(
            committed_root.is_dir(),
            "Source subtree is not present in the expected commit",
        )
        committed_tree = scan_tree(committed_root)
        require(
            committed_tree["normalized_digest"] == source_tree["normalized_digest"],
            "Source differs from the expected committed subtree; provide a reviewed tree digest for generated artifacts",
        )


def validate_tree_proof(
    context: dict[str, Any], source_tree: dict[str, Any], reviewed_digest: str | None, state_root: Path
) -> None:
    if reviewed_digest:
        require(
            bool(TREE_SHA_RE.fullmatch(reviewed_digest)),
            "Reviewed tree digest must be a SHA-256 value",
        )
        require(
            source_tree["exact_digest"] == reviewed_digest,
            "Source does not match the reviewed tree digest",
        )
        return
    verify_committed_source(context, source_tree, state_root)


def validate_allow_file(allow_file_raw: str, destination: Path, context: dict[str, Any]) -> Path:
    allow_file = Path(allow_file_raw)
    require(allow_file.is_absolute(), "Destination allow file must be absolute")
    assert_no_symlink_components(allow_file)
    require(
        allow_file.is_file() and not allow_file.is_symlink(),
        "Destination allow file must be a regular non-symlink file",
    )
    allow_file = allow_file.resolve(strict=True)
    file_stat = allow_file.stat()
    require(
        file_stat.st_uid == os.getuid() and not stat.S_IMODE(file_stat.st_mode) & 0o077,
        "Destination allow file must be owner-controlled with mode 0600 or stricter",
    )
    require(
        not path_is_within(allow_file, context["repo_root"])
        and not path_is_within(allow_file, destination),
        "Destination authority must be stored outside source and destination trees",
    )
    allowed: set[Path] = set()
    for raw_line in allow_file.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        allowed.add(canonical_destination(line))
    require(
        destination in allowed,
        "Destination is not present in the owner-controlled allow file",
    )
    return allow_file


def destination_is_in_git(git_bin: str, destination: Path) -> bool:
    probe = destination if destination.exists() else destination.parent
    result = subprocess.run(  # nosec B603 -- argv array; destination is canonicalized
        [git_bin, "-C", str(probe), "rev-parse", "--git-dir"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return result.returncode == 0


def validate_destination_safety(
    destination: Path, context: dict[str, Any], state_root: Path, allow_file_raw: str
) -> Path:
    home = Path.home().resolve(strict=True)
    require(
        destination != Path(destination.anchor) and destination != home,
        "Root and home directories cannot be deployment targets",
    )
    require(
        not any(part.lower() == ".git" for part in destination.parts),
        "Git metadata cannot be a deployment target",
    )
    repo_root = context["repo_root"]
    require(
        not path_is_within(destination, repo_root)
        and not path_is_within(repo_root, destination),
        "Destination must not overlap the source Git worktree",
    )
    require(
        not path_is_within(destination, state_root)
        and not path_is_within(state_root, destination),
        "Destination must not overlap deployment-copy state storage",
    )
    require(
        not destination_is_in_git(context["git_bin"], destination),
        "Destination must be outside every Git worktree",
    )
    validate_allow_file(allow_file_raw, destination, context)
    return destination


def copy_tree(source: Path, stage: Path, source_tree: dict[str, Any]) -> None:
    for entry in source_tree["entries"]:
        if entry["type"] != "directory" or entry["path"] == ".":
            continue
        target = stage.joinpath(*PurePosixPath(entry["path"]).parts)
        target.mkdir(mode=0o700, parents=True, exist_ok=False)
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    for entry in source_tree["entries"]:
        if entry["type"] != "file":
            continue
        relative = PurePosixPath(entry["path"])
        source_path = source.joinpath(*relative.parts)
        target_path = stage.joinpath(*relative.parts)
        source_stat = os.lstat(source_path)
        require(
            stat.S_ISREG(source_stat.st_mode),
            "Source changed while it was being staged",
        )
        descriptor = os.open(source_path, os.O_RDONLY | no_follow)
        try:
            with os.fdopen(descriptor, "rb", closefd=False) as source_handle, target_path.open(
                "xb"
            ) as target_handle:
                shutil.copyfileobj(source_handle, target_handle, 1024 * 1024)
        finally:
            os.close(descriptor)
        os.chmod(target_path, int(entry["mode"], 8))
    for entry in reversed(source_tree["entries"]):
        if entry["type"] != "directory":
            continue
        target = stage if entry["path"] == "." else stage.joinpath(
            *PurePosixPath(entry["path"]).parts
        )
        os.chmod(target, int(entry["mode"], 8))


def tree_plan(source_tree: dict[str, Any], destination_tree: dict[str, Any] | None) -> dict[str, list[str]]:
    source_entries = {
        entry["path"]: entry for entry in source_tree["entries"] if entry["path"] != "."
    }
    destination_entries = {
        entry["path"]: entry
        for entry in (destination_tree or {"entries": []})["entries"]
        if entry["path"] != "."
    }
    source_paths = set(source_entries)
    destination_paths = set(destination_entries)
    plan = {
        "add": sorted(source_paths - destination_paths),
        "change": sorted(
            path
            for path in source_paths & destination_paths
            if source_entries[path] != destination_entries[path]
        ),
        "delete": sorted(destination_paths - source_paths),
    }
    if destination_tree and source_tree["entries"][0] != destination_tree["entries"][0]:
        plan["change"].insert(0, ".")
    return plan


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(6)}")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        parent_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(parent_descriptor)
        finally:
            os.close(parent_descriptor)
    finally:
        if temporary.exists():
            temporary.unlink()


def update_receipt(receipt_path: Path, receipt: dict[str, Any], status_value: str) -> None:
    receipt["status"] = status_value
    receipt["updated_at"] = utc_now()
    atomic_write_json(receipt_path, receipt)


def validate_receipt_identity(receipt: Any, identifier: str) -> dict[str, Any]:
    if not isinstance(receipt, dict):
        raise DeploymentError("Operation receipt is invalid")
    require(
        receipt.get("schema") == SCHEMA and receipt.get("operation_id") == identifier,
        "Operation receipt is invalid",
    )
    return receipt


def validate_receipt_paths_and_flags(receipt: dict[str, Any]) -> None:
    required_strings = ("destination", "displaced_path", "rollback_path", "source_repo")
    require(
        all(isinstance(receipt.get(key), str) and bool(receipt[key]) for key in required_strings),
        "Operation receipt is invalid",
    )
    require(
        receipt.get("stage_path") is None or isinstance(receipt["stage_path"], str),
        "Operation receipt is invalid",
    )
    require(
        isinstance(receipt.get("previous_present"), bool),
        "Operation receipt is invalid",
    )
    require(isinstance(receipt.get("status"), str), "Operation receipt is invalid")


def validate_receipt_digests(receipt: dict[str, Any]) -> None:
    require(
        isinstance(receipt.get("tree_sha256"), str)
        and bool(TREE_SHA_RE.fullmatch(receipt["tree_sha256"])),
        "Operation receipt is invalid",
    )
    previous_digest = receipt.get("previous_tree_sha256")
    if receipt["previous_present"]:
        require(
            isinstance(previous_digest, str)
            and bool(TREE_SHA_RE.fullmatch(previous_digest)),
            "Operation receipt is invalid",
        )
    else:
        require(previous_digest is None, "Operation receipt is invalid")


def load_receipt(state_root: Path, identifier: str) -> tuple[Path, dict[str, Any]]:
    require(
        bool(OPERATION_RE.fullmatch(identifier)),
        "Operation identifier is malformed",
    )
    receipt_path = state_root / "operations" / f"{identifier}.json"
    assert_no_symlink_components(receipt_path)
    receipt_stat = receipt_path.stat()
    require(
        stat.S_ISREG(receipt_stat.st_mode) and receipt_stat.st_uid == os.getuid(),
        "Operation receipt is unsafe",
    )
    require(
        not stat.S_IMODE(receipt_stat.st_mode) & 0o077,
        "Operation receipt permissions are unsafe",
    )
    receipt = validate_receipt_identity(
        json.loads(receipt_path.read_text(encoding="utf-8")), identifier
    )
    validate_receipt_paths_and_flags(receipt)
    validate_receipt_digests(receipt)
    return receipt_path, receipt


def receipt_paths(receipt: dict[str, Any], destination: Path) -> tuple[Path, Path, Path | None]:
    identifier = receipt["operation_id"]
    rollback_path = destination.with_name(
        f".{destination.name}.aidevops-rollback-{identifier}"
    )
    displaced_path = destination.with_name(
        f".{destination.name}.aidevops-displaced-{identifier}"
    )
    require(
        receipt.get("rollback_path") == str(rollback_path),
        "Operation receipt rollback path is invalid",
    )
    require(
        receipt.get("displaced_path") == str(displaced_path),
        "Operation receipt displaced path is invalid",
    )
    stage_path = None
    if receipt.get("stage_path") is not None:
        stage_path = Path(receipt["stage_path"])
        expected_prefix = f".{destination.name}.aidevops-stage-{identifier}-"
        require(
            stage_path.parent == destination.parent
            and stage_path.name.startswith(expected_prefix),
            "Operation receipt stage path is invalid",
        )
    return rollback_path, displaced_path, stage_path


def validate_existing_operation_tree(path: Path, purpose: str) -> None:
    if not os.path.lexists(path):
        return
    assert_no_symlink_components(path)
    require(path.is_dir(), f"{purpose} must be a non-symlink directory")


def verify_operation_tree(path: Path, expected_digest: str, purpose: str) -> None:
    validate_existing_operation_tree(path, purpose)
    require(path.exists(), f"{purpose} is unavailable")
    measured = scan_tree(path, require_files=False)
    require(
        measured["exact_digest"] == expected_digest,
        f"{purpose} failed exact verification",
    )


def pid_is_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class DestinationLock:
    def __init__(self, destination: Path) -> None:
        self.path = destination.with_name(f".{destination.name}.aidevops-lock")
        self.token = secrets.token_hex(16)

    def publish(self) -> bool:
        pending = self.path.with_name(f"{self.path.name}.pending-{secrets.token_hex(6)}")
        pending.mkdir(mode=0o700)
        owner_payload = {"created_at": utc_now(), "pid": os.getpid(), "token": self.token}
        try:
            atomic_write_json(pending / "owner.json", owner_payload)
            os.rename(pending, self.path)
        except OSError:
            if pending.exists():
                shutil.rmtree(pending)
            return False
        return True

    def __enter__(self) -> "DestinationLock":
        if self.publish():
            return self
        assert_no_symlink_components(self.path)
        if not self.path.is_dir():
            raise DeploymentError("Destination lock path is unsafe")
        try:
            owner = json.loads((self.path / "owner.json").read_text(encoding="utf-8"))
            owner_pid = int(owner["pid"])
            owner_token = owner["token"]
        except (KeyError, OSError, TypeError, ValueError, json.JSONDecodeError) as error:
            raise DeploymentError("Destination lock is incomplete or unsafe") from error
        if not isinstance(owner_token, str) or not owner_token:
            raise DeploymentError("Destination lock is incomplete or unsafe")
        if pid_is_alive(owner_pid):
            raise DeploymentError("Another deployment owns the destination lock")
        stale_path = self.path.with_name(f"{self.path.name}.stale-{secrets.token_hex(6)}")
        try:
            os.rename(self.path, stale_path)
        except OSError as error:
            raise DeploymentError("Destination lock changed during stale recovery") from error
        shutil.rmtree(stale_path)
        if not self.publish():
            raise DeploymentError("Another deployment won the destination lock race")
        return self

    def __exit__(self, exc_type: Any, exc_value: Any, traceback: Any) -> None:
        try:
            owner = json.loads((self.path / "owner.json").read_text(encoding="utf-8"))
            if owner.get("token") == self.token:
                shutil.rmtree(self.path)
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return


def manifest_result(source_tree: dict[str, Any]) -> dict[str, Any]:
    return {
        "command": "manifest",
        "file_count": source_tree["file_count"],
        "status": "verified",
        "total_bytes": source_tree["total_bytes"],
        "tree_sha256": source_tree["exact_digest"],
    }


def emit_result(result: dict[str, Any], machine: bool) -> None:
    payload = {"schema": RESULT_SCHEMA, **result}
    if machine:
        print(json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
        return
    command = result.get("command")
    if command == "manifest":
        print(f"TREE_SHA256={result['tree_sha256']}")
        print(f"FILE_COUNT={result['file_count']}")
        print(f"TOTAL_BYTES={result['total_bytes']}")
        return
    print(f"STATUS={result['status']}")
    if result.get("operation_id"):
        print(f"OPERATION_ID={result['operation_id']}")
    if command == "deploy" and result.get("dry_run"):
        for action in ("add", "change", "delete"):
            for relative_path in result["plan"][action]:
                print(f"{action.upper()}={relative_path}")
    if result.get("rollback_available"):
        print(f"ROLLBACK_COMMAND=deployment-copy-helper.sh rollback --operation-id {result['operation_id']} --confirm {ROLLBACK_CONFIRMATION} --allow-file <path>")


def receipt_context(receipt: dict[str, Any], git_bin: str) -> dict[str, Any]:
    repo_root = Path(receipt["source_repo"])
    if not repo_root.is_absolute():
        raise DeploymentError("Recorded source repository must be absolute")
    repo_root = Path(os.path.normpath(str(repo_root)))
    assert_existing_components_not_symlinks(repo_root)
    return {"git_bin": git_bin, "repo_root": repo_root}


def prepare_deploy(args: argparse.Namespace) -> PreparedDeployment:
    state_root = secure_state_root()
    git_bin = os.environ.get("AIDEVOPS_REAL_GIT_BIN", "git")
    context = validate_source(args.source, args.expected_sha, git_bin)
    source_tree = scan_tree(context["source"])
    validate_tree_proof(context, source_tree, args.reviewed_tree_sha256, state_root)
    destination = canonical_destination(args.destination)
    validate_destination_safety(destination, context, state_root, args.allow_file)
    destination_tree = scan_tree(destination, require_files=False) if destination.exists() else None
    return PreparedDeployment(state_root, context, destination, source_tree, destination_tree)


def build_deploy_receipt(
    identifier: str,
    prepared: PreparedDeployment,
    rollback_path: Path,
    displaced_path: Path,
) -> dict[str, Any]:
    return {
        "created_at": utc_now(),
        "destination": str(prepared.destination),
        "displaced_path": str(displaced_path),
        "expected_sha": prepared.source_context["expected_sha"],
        "operation_id": identifier,
        "previous_present": prepared.destination_tree is not None,
        "previous_tree_sha256": (
            prepared.destination_tree["exact_digest"] if prepared.destination_tree else None
        ),
        "rollback_path": str(rollback_path),
        "schema": SCHEMA,
        "source": str(prepared.source_context["source"]),
        "source_repo": str(prepared.source_context["repo_root"]),
        "stage_path": None,
        "status": "preparing",
        "tree_sha256": prepared.source_tree["exact_digest"],
        "updated_at": utc_now(),
    }


def validate_locked_deploy(
    args: argparse.Namespace,
    prepared: PreparedDeployment,
    rollback_path: Path,
    displaced_path: Path,
) -> None:
    current_context = validate_source(
        args.source, args.expected_sha, prepared.source_context["git_bin"]
    )
    current_source_tree = scan_tree(current_context["source"])
    if current_source_tree["exact_digest"] != prepared.source_tree["exact_digest"]:
        raise DeploymentError("Source changed before staging began")
    validate_tree_proof(
        current_context, current_source_tree, args.reviewed_tree_sha256, prepared.state_root
    )
    current_destination = canonical_destination(args.destination)
    validate_destination_safety(
        current_destination, prepared.source_context, prepared.state_root, args.allow_file
    )
    if current_destination != prepared.destination:
        raise DeploymentError("Destination identity changed before staging")
    if os.path.lexists(rollback_path) or os.path.lexists(displaced_path):
        raise DeploymentError("Operation path collision blocked deployment")


def perform_deployment(operation: DeploymentOperation) -> None:
    prepared = operation.prepared
    prefix = f".{prepared.destination.name}.aidevops-stage-{operation.identifier}-"
    stage = Path(tempfile.mkdtemp(prefix=prefix, dir=prepared.destination.parent))
    operation.progress["stage"] = stage
    operation.receipt["stage_path"] = str(stage)
    update_receipt(operation.receipt_path, operation.receipt, "staging")
    copy_tree(prepared.source_context["source"], stage, prepared.source_tree)
    if scan_tree(stage)["exact_digest"] != prepared.source_tree["exact_digest"]:
        raise DeploymentError("Staged tree does not match the approved source")
    if (
        scan_tree(prepared.source_context["source"])["exact_digest"]
        != prepared.source_tree["exact_digest"]
    ):
        raise DeploymentError("Source changed while staging was in progress")
    current_tree = (
        scan_tree(prepared.destination, require_files=False)
        if prepared.destination.exists()
        else None
    )
    current_digest = current_tree["exact_digest"] if current_tree else None
    previous_digest = (
        prepared.destination_tree["exact_digest"] if prepared.destination_tree else None
    )
    if current_digest != previous_digest:
        raise DeploymentError("Destination changed while staging was in progress")
    update_receipt(operation.receipt_path, operation.receipt, "staged")
    if prepared.destination.exists():
        os.replace(prepared.destination, operation.rollback_path)
        update_receipt(operation.receipt_path, operation.receipt, "previous_moved")
    else:
        update_receipt(operation.receipt_path, operation.receipt, "activating")
    os.replace(stage, prepared.destination)
    operation.progress["activated"] = True
    operation.progress["stage"] = None
    operation.receipt["stage_path"] = None
    update_receipt(operation.receipt_path, operation.receipt, "active")
    if scan_tree(prepared.destination)["exact_digest"] != prepared.source_tree["exact_digest"]:
        raise DeploymentError("Activated destination failed exact verification")
    update_receipt(operation.receipt_path, operation.receipt, "success")


def first_deployment_activation_detected(
    destination: Path, receipt: dict[str, Any], progress: dict[str, Any]
) -> bool:
    if receipt["previous_present"]:
        return False
    if progress["activated"]:
        return True
    stage = progress["stage"]
    if receipt["status"] != "activating" or stage is None:
        return False
    return not stage.exists() and destination.exists()


def rollback_failed_deployment(operation: DeploymentOperation) -> None:
    destination = operation.prepared.destination
    stage = operation.progress["stage"]
    if destination.exists() and operation.rollback_path.exists():
        if operation.displaced_path.exists():
            raise DeploymentError("Automatic rollback path collision requires recovery")
        verify_operation_tree(
            operation.rollback_path,
            operation.receipt["previous_tree_sha256"],
            "Recorded rollback tree",
        )
        os.replace(destination, operation.displaced_path)
        os.replace(operation.rollback_path, destination)
        restored_tree = scan_tree(destination, require_files=False)
        if restored_tree["exact_digest"] != operation.receipt["previous_tree_sha256"]:
            raise DeploymentError("Automatic rollback verification failed")
        update_receipt(operation.receipt_path, operation.receipt, "rolled_back_after_failure")
    elif not destination.exists() and operation.rollback_path.exists():
        verify_operation_tree(
            operation.rollback_path,
            operation.receipt["previous_tree_sha256"],
            "Recorded rollback tree",
        )
        os.replace(operation.rollback_path, destination)
        update_receipt(operation.receipt_path, operation.receipt, "rolled_back_after_failure")
    elif first_deployment_activation_detected(destination, operation.receipt, operation.progress):
        if not destination.exists():
            raise DeploymentError("Activated destination disappeared during automatic rollback")
        os.replace(destination, operation.displaced_path)
        update_receipt(operation.receipt_path, operation.receipt, "rolled_back_after_failure")
    else:
        update_receipt(operation.receipt_path, operation.receipt, "failed_before_activation")
    if stage and stage.exists():
        shutil.rmtree(stage)


def raise_deployment_failure(
    operation: DeploymentOperation,
    error: BaseException,
) -> None:
    try:
        rollback_failed_deployment(operation)
    except BaseException as recovery_error:
        try:
            update_receipt(operation.receipt_path, operation.receipt, "recovery_required")
        except BaseException:
            pass
        raise DeploymentError(
            "Deployment failed and automatic recovery requires the recorded operation",
            operation.identifier,
        ) from recovery_error
    message = (
        str(error)
        if isinstance(error, DeploymentError)
        else "Deployment was interrupted and safe recovery was recorded"
    )
    raise DeploymentError(message, operation.identifier) from error


def deploy(args: argparse.Namespace) -> dict[str, Any]:
    prepared = prepare_deploy(args)
    plan = tree_plan(prepared.source_tree, prepared.destination_tree)
    if args.dry_run:
        return {
            "command": "deploy",
            "dry_run": True,
            "plan": plan,
            "status": "planned",
            "tree_sha256": prepared.source_tree["exact_digest"],
        }
    identifier = operation_id()
    receipt_path = prepared.state_root / "operations" / f"{identifier}.json"
    rollback_path = prepared.destination.with_name(
        f".{prepared.destination.name}.aidevops-rollback-{identifier}"
    )
    displaced_path = prepared.destination.with_name(
        f".{prepared.destination.name}.aidevops-displaced-{identifier}"
    )
    receipt = build_deploy_receipt(identifier, prepared, rollback_path, displaced_path)
    progress: dict[str, Any] = {"activated": False, "stage": None}
    operation = DeploymentOperation(
        identifier,
        prepared,
        rollback_path,
        displaced_path,
        receipt_path,
        receipt,
        progress,
    )
    with DestinationLock(prepared.destination):
        validate_locked_deploy(args, prepared, rollback_path, displaced_path)
        atomic_write_json(operation.receipt_path, operation.receipt)
        try:
            perform_deployment(operation)
        except BaseException as error:
            raise_deployment_failure(operation, error)
    return {
        "command": "deploy",
        "dry_run": False,
        "operation_id": identifier,
        "plan": plan,
        "rollback_available": bool(prepared.destination_tree),
        "status": "success",
        "tree_sha256": prepared.source_tree["exact_digest"],
    }


def validate_receipt_destination(
    receipt: dict[str, Any], allow_file: str, state_root: Path, git_bin: str
) -> tuple[Path, dict[str, Any]]:
    destination = canonical_destination(receipt["destination"])
    context = receipt_context(receipt, git_bin)
    validate_destination_safety(destination, context, state_root, allow_file)
    return destination, context


def recovery_result(
    identifier: str, status_value: str, rollback_available: bool = False
) -> dict[str, Any]:
    return {
        "command": "recover",
        "operation_id": identifier,
        "rollback_available": rollback_available,
        "status": status_value,
    }


def remove_recorded_stage(stage_path: Path | None, receipt: dict[str, Any]) -> None:
    if stage_path and stage_path.exists():
        shutil.rmtree(stage_path)
        receipt["stage_path"] = None


def recover_existing_destination(operation: RecoveryOperation) -> dict[str, Any] | None:
    if not operation.destination.exists():
        return None
    destination_tree = scan_tree(operation.destination, require_files=False)
    if destination_tree["exact_digest"] == operation.receipt["tree_sha256"]:
        remove_recorded_stage(operation.stage_path, operation.receipt)
        update_receipt(operation.receipt_path, operation.receipt, "success")
        return recovery_result(
            operation.identifier, "success", operation.rollback_path.exists()
        )
    if operation.receipt["previous_present"] and (
        destination_tree["exact_digest"] == operation.receipt["previous_tree_sha256"]
    ):
        remove_recorded_stage(operation.stage_path, operation.receipt)
        update_receipt(operation.receipt_path, operation.receipt, "recovered_previous")
        return recovery_result(operation.identifier, "recovered_previous")
    return None


def restore_previous_for_recovery(operation: RecoveryOperation) -> dict[str, Any] | None:
    if operation.destination.exists() or not operation.rollback_path.exists():
        return None
    verify_operation_tree(
        operation.rollback_path,
        operation.receipt["previous_tree_sha256"],
        "Recorded rollback tree",
    )
    os.replace(operation.rollback_path, operation.destination)
    restored = scan_tree(operation.destination, require_files=False)
    if restored["exact_digest"] != operation.receipt["previous_tree_sha256"]:
        update_receipt(operation.receipt_path, operation.receipt, "recovery_required")
        raise DeploymentError("Recovered destination failed exact verification")
    remove_recorded_stage(operation.stage_path, operation.receipt)
    update_receipt(operation.receipt_path, operation.receipt, "recovered_previous")
    return recovery_result(operation.identifier, "recovered_previous")


def recover(args: argparse.Namespace) -> dict[str, Any]:
    if args.confirm != RECOVER_CONFIRMATION:
        raise DeploymentError("Exact recovery confirmation is required")
    state_root = secure_state_root()
    receipt_path, receipt = load_receipt(state_root, args.operation_id)
    git_bin = os.environ.get("AIDEVOPS_REAL_GIT_BIN", "git")
    destination, _ = validate_receipt_destination(receipt, args.allow_file, state_root, git_bin)
    rollback_path, displaced_path, stage_path = receipt_paths(receipt, destination)
    with DestinationLock(destination):
        validate_existing_operation_tree(rollback_path, "Recorded rollback tree")
        validate_existing_operation_tree(displaced_path, "Recorded displaced tree")
        if stage_path is not None:
            validate_existing_operation_tree(stage_path, "Recorded stage tree")
        operation = RecoveryOperation(
            args.operation_id,
            destination,
            rollback_path,
            stage_path,
            receipt_path,
            receipt,
        )
        existing_result = recover_existing_destination(operation)
        if existing_result:
            return existing_result
        previous_result = restore_previous_for_recovery(operation)
        if previous_result:
            return previous_result
        if stage_path and stage_path.exists():
            remove_recorded_stage(stage_path, receipt)
            update_receipt(receipt_path, receipt, "aborted_before_activation")
            return recovery_result(args.operation_id, "aborted_before_activation")
        if not receipt.get("previous_present") and not destination.exists():
            update_receipt(receipt_path, receipt, "recovered_absent")
            return recovery_result(args.operation_id, "recovered_absent")
    raise DeploymentError("Receipt state requires manual inspection; no mutation was performed")


def rollback(args: argparse.Namespace) -> dict[str, Any]:
    if args.confirm != ROLLBACK_CONFIRMATION:
        raise DeploymentError("Exact rollback confirmation is required")
    state_root = secure_state_root()
    receipt_path, receipt = load_receipt(state_root, args.operation_id)
    if receipt.get("status") != "success":
        raise DeploymentError("Only a verified successful deployment can be rolled back")
    git_bin = os.environ.get("AIDEVOPS_REAL_GIT_BIN", "git")
    destination, _ = validate_receipt_destination(receipt, args.allow_file, state_root, git_bin)
    rollback_path, displaced_path, _ = receipt_paths(receipt, destination)
    with DestinationLock(destination):
        validate_existing_operation_tree(rollback_path, "Recorded rollback tree")
        validate_existing_operation_tree(displaced_path, "Recorded displaced tree")
        if not destination.exists():
            raise DeploymentError("Active destination is missing; use recovery instead")
        active = scan_tree(destination)
        if active["exact_digest"] != receipt["tree_sha256"]:
            raise DeploymentError("Active destination changed after deployment")
        if displaced_path.exists():
            raise DeploymentError("Displaced-tree path collision blocked rollback")
        if receipt["previous_present"]:
            verify_operation_tree(
                rollback_path,
                receipt["previous_tree_sha256"],
                "Recorded rollback tree",
            )
        os.replace(destination, displaced_path)
        try:
            if receipt["previous_present"]:
                if not rollback_path.exists():
                    raise DeploymentError("Verified previous destination is unavailable")
                os.replace(rollback_path, destination)
                restored = scan_tree(destination, require_files=False)
                if restored["exact_digest"] != receipt["previous_tree_sha256"]:
                    raise DeploymentError("Rolled-back destination failed exact verification")
            update_receipt(receipt_path, receipt, "rolled_back")
        except BaseException:
            if destination.exists() and receipt["previous_present"]:
                os.replace(destination, rollback_path)
            if not destination.exists() and displaced_path.exists():
                os.replace(displaced_path, destination)
            update_receipt(receipt_path, receipt, "rollback_failed_restored_active")
            raise
    return {
        "command": "rollback",
        "operation_id": args.operation_id,
        "rollback_available": False,
        "status": "rolled_back",
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Audited deployment copies from linked worktrees to allowed non-Git targets"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    manifest_parser = subparsers.add_parser(
        "manifest", help="Measure a linked-worktree source tree for explicit review"
    )
    manifest_parser.add_argument("--source", required=True)
    manifest_parser.add_argument("--expected-sha", required=True)
    manifest_parser.add_argument("--machine", action="store_true")

    deploy_parser = subparsers.add_parser("deploy", help="Plan or perform an audited copy")
    deploy_parser.add_argument("--source", required=True)
    deploy_parser.add_argument("--destination", required=True)
    deploy_parser.add_argument("--expected-sha", required=True)
    deploy_parser.add_argument("--allow-file", required=True)
    deploy_parser.add_argument("--reviewed-tree-sha256")
    deploy_parser.add_argument("--dry-run", action="store_true")
    deploy_parser.add_argument("--machine", action="store_true")

    recover_parser = subparsers.add_parser(
        "recover", help="Recover an interrupted operation from its private receipt"
    )
    recover_parser.add_argument("--operation-id", required=True)
    recover_parser.add_argument("--confirm", required=True)
    recover_parser.add_argument("--allow-file", required=True)
    recover_parser.add_argument("--machine", action="store_true")

    rollback_parser = subparsers.add_parser(
        "rollback", help="Restore the verified destination retained by a successful copy"
    )
    rollback_parser.add_argument("--operation-id", required=True)
    rollback_parser.add_argument("--confirm", required=True)
    rollback_parser.add_argument("--allow-file", required=True)
    rollback_parser.add_argument("--machine", action="store_true")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    machine = bool(getattr(args, "machine", False))
    try:
        handlers = {
            "manifest": manifest,
            "deploy": deploy,
            "recover": recover,
            "rollback": rollback,
        }
        result = handlers[args.command](args)
        emit_result(result, machine)
        return 0
    except (
        DeploymentError,
        json.JSONDecodeError,
        KeyError,
        OSError,
        TypeError,
        UnicodeError,
        ValueError,
    ) as error:
        message = str(error) if isinstance(error, DeploymentError) else "Deployment-copy state is invalid"
        operation_id_value = (
            error.operation_id if isinstance(error, DeploymentError) else None
        )
        if machine:
            payload = {"error": message, "schema": RESULT_SCHEMA, "status": "blocked"}
            if operation_id_value:
                payload["operation_id"] = operation_id_value
            print(
                json.dumps(
                    payload,
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                )
            )
        else:
            print(f"ERROR: {message}", file=sys.stderr)
            if operation_id_value:
                print(f"OPERATION_ID={operation_id_value}", file=sys.stderr)
        return 1


def manifest(args: argparse.Namespace) -> dict[str, Any]:
    state_root = secure_state_root()
    git_bin = os.environ.get("AIDEVOPS_REAL_GIT_BIN", "git")
    context = validate_source(args.source, args.expected_sha, git_bin)
    return manifest_result(scan_tree(context["source"]))


def _interrupt(_signal_number: int, _frame: Any) -> None:
    raise DeploymentError("Deployment was interrupted")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _interrupt)
    raise SystemExit(main())
