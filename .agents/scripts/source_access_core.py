#!/usr/bin/env python3
"""Core policy and request handling for temporary source access."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import pwd
import re
import secrets
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from operator import itemgetter
from pathlib import Path
from typing import Any, Callable, Iterator

SCHEMA_REQUEST = "aidevops-source-access-request/v1"
SCHEMA_MANIFEST_REQUEST = "aidevops-source-access-request/v2"
SCHEMA_PROPOSAL = "aidevops-source-access-proposal/v1"
SCHEMA_RECEIPT = "aidevops-source-access-receipt/v1"
SCHEMA_MANIFEST_RECEIPT = "aidevops-source-access-receipt/v2"
SCHEMA_PAYLOAD = "aidevops-source-access-approval/v1"
SCHEMA_MANIFEST_PAYLOAD = "aidevops-source-access-approval/v2"
SCHEMA_TRUST = "aidevops-source-access-trust/v1"
SIGNATURE_NAMESPACE = "aidevops-source-access-v1"
SIGNER_IDENTITY = "source-access@aidevops.sh"
TRUST_KEY_SOURCE_DEDICATED = "dedicated"
OVERRIDABLE_REASON = "secret-bearing basename"
MAX_TTL_SECONDS = 12 * 60 * 60
REQUEST_REUSE_SECONDS = 60 * 60
MAX_SOURCE_BYTES = 10 * 1024 * 1024
MAX_MANIFEST_ENTRIES = 32
MAX_REQUEST_BYTES = 256 * 1024
MAX_PENDING_PROPOSALS = 128
ID_PATTERN = re.compile(r"^[a-f0-9]{32,64}$")
SESSION_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{6,256}$")
ALLOWED_SUFFIXES = frozenset(
    ".c .cjs .cpp .go .h .hpp .java .js .json .jsx .kt .md .mjs .php .py .rb "
    ".rs .sh .swift .toml .ts .tsx .yaml .yml".split()
)
DENIED_NAMES = frozenset(
    ".netrc .npmrc .pypirc auth.json credentials credentials.json id_dsa id_ecdsa "
    "id_ed25519 id_rsa kubeconfig".split()
)
DENIED_SUFFIXES = frozenset(".jks .key .keystore .p12 .pem .pfx".split())
GIT = "/usr/bin/git"
SSH_KEYGEN = "/usr/bin/ssh-keygen"


def _current_timestamp() -> int:
    return int(time.time())


class SourceAccessError(RuntimeError):
    """Typed user-facing failure without source content."""


@dataclass(frozen=True)
class Config:
    config_dir: Path = Path("/etc/aidevops/source-access")
    state_dir: Path = Path("/var/run/aidevops/source-access")
    request_root: Path | None = None
    trust_uid: int = 0

    @property
    def private_key(self) -> Path:
        return self.config_dir / "private" / "source-access.key"

    @property
    def public_key(self) -> Path:
        return self.config_dir / "source-access.pub"

    @property
    def trust_marker(self) -> Path:
        return self.config_dir / "source-access.trust"


@dataclass(frozen=True)
class RequestSpec:
    session_id: str
    uid: int
    home: Path
    path: str
    reason: str
    now: int | None = None


@dataclass(frozen=True)
class ManifestRequestSpec:
    session_id: str
    uid: int
    home: Path
    paths: tuple[str, ...]
    reason: str
    now: int = field(default_factory=_current_timestamp)


@dataclass(frozen=True)
class ApprovalSpec:
    request_id: str
    home: Path
    expected_uid: int
    ttl_seconds: int
    now: int | None = None
    confirm: Callable[[dict[str, Any]], bool] | None = None


@dataclass(frozen=True)
class VerificationSpec:
    session_id: str
    uid: int
    path: str
    reason: str
    now: int | None = None


@dataclass(frozen=True)
class ApprovalBinding:
    approval_id: str
    checked_at: int
    path: str
    reason: str
    receipt_path: Path
    session_id: str
    snapshot_path: Path
    uid: int


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _run(command: list[str], *, input_bytes: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    _require_source(bool(command) and command[0] in (GIT, SSH_KEYGEN), "required command is not approved")
    environment = None
    if command and command[0] == GIT:
        # #aidevops:trust-boundary — even ls-files runs core.fsmonitor. Never
        # execute repository hooks or inherit a caller's Git scope as the broker.
        command = [GIT, "--no-pager", "-c", "core.fsmonitor=false",
                   "-c", "core.hooksPath=/dev/null", *command[1:]]
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        environment.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                            "GIT_OPTIONAL_LOCKS": "0"})
    try:
        return subprocess.run(  # nosec B603 -- fixed system binary allowlist, argv only, Git hooks disabled
            command,
            input=input_bytes,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SourceAccessError(f"required command failed: {command[0]}") from exc


def _ensure_directory(path: Path, mode: int, owner_uid: int | None = None) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, mode)
    if owner_uid is not None and os.geteuid() == 0:
        os.chown(path, owner_uid, 0)


def atomic_write(
    path: Path,
    content: bytes,
    mode: int,
    owner_uid: int | None = None,
    directory_mode: int | None = None,
) -> None:
    parent_mode = directory_mode if directory_mode is not None else (0o755 if mode == 0o644 else 0o700)
    _ensure_directory(path.parent, parent_mode, owner_uid)
    descriptor, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
            os.fchmod(handle.fileno(), mode)
            if owner_uid is not None and os.geteuid() == 0:
                os.fchown(handle.fileno(), owner_uid, 0)
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def _require_source(condition: bool, message: str) -> None:
    if not condition:
        raise SourceAccessError(message)


def _validate_session_id(session_id: str) -> str:
    _require_source(SESSION_PATTERN.fullmatch(session_id) is not None, "invalid runtime session identifier")
    return session_id


def _validate_reason(reason: str) -> str:
    _require_source(reason == OVERRIDABLE_REASON, "only the basename-only source guard can be approved")
    return reason


def _path_components(path: Path) -> list[Path]:
    current = Path(path.anchor)
    components = []
    for part in path.parts[1:]:
        current /= part
        components.append(current)
    return components


def _is_symlink(path: Path) -> bool:
    try:
        return stat.S_ISLNK(os.lstat(path).st_mode)
    except FileNotFoundError:
        return False


def _has_symlink_component(path: Path) -> bool:
    return any(_is_symlink(component) for component in _path_components(path))


def canonical_tracked_source(raw_path: str) -> str:
    _require_source(bool(raw_path), "source path is empty or contains control characters")
    _require_source(
        all(ord(character) >= 32 for character in raw_path),
        "source path is empty or contains control characters",
    )
    absolute = Path(os.path.abspath(os.path.expanduser(raw_path)))
    _require_source(not _has_symlink_component(absolute), "symlinked source paths cannot be approved")
    try:
        resolved = absolute.resolve(strict=True)
        file_stat = resolved.stat()
    except OSError as exc:
        raise SourceAccessError("source path is unavailable") from exc
    _require_source(stat.S_ISREG(file_stat.st_mode), "source path is not a regular file")

    basename = resolved.name.lower()
    _require_source(
        not basename.startswith(".env") and basename not in DENIED_NAMES,
        "credential-like source paths cannot be approved",
    )
    suffix = resolved.suffix.lower()
    _require_source(suffix not in DENIED_SUFFIXES, "private key and credential containers cannot be approved")
    _require_source(suffix in ALLOWED_SUFFIXES, "path is not an approved source or documentation type")

    root_result = _run([GIT, "-C", str(resolved.parent), "rev-parse", "--show-toplevel"])
    _require_source(root_result.returncode == 0, "source path is not inside a Git worktree")
    git_root = Path(root_result.stdout.decode("utf-8").strip()).resolve()
    try:
        relative_path = resolved.relative_to(git_root)
    except ValueError as exc:
        raise SourceAccessError("source path escapes its Git worktree") from exc
    tracked_result = _run(
        [GIT, "-C", str(git_root), "ls-files", "--error-unmatch", "--", str(relative_path)]
    )
    _require_source(tracked_result.returncode == 0, "only Git-tracked source files can be approved")
    return str(resolved)


def tracked_source_identity(raw_path: str) -> tuple[str, str, str]:
    path = canonical_tracked_source(raw_path)
    resolved = Path(path)
    root_result = _run([GIT, "-C", str(resolved.parent), "rev-parse", "--show-toplevel"])
    _require_source(root_result.returncode == 0, "source path is not inside a Git worktree")
    repo_root = str(Path(root_result.stdout.decode("utf-8").strip()).resolve())
    relative_path = str(resolved.relative_to(Path(repo_root)))
    return path, repo_root, relative_path


def scope_id(session_id: str, uid: int, path: str, reason: str) -> str:
    scope = f"{session_id}\0{uid}\0{path}\0{reason}".encode("utf-8")
    return hashlib.sha256(scope).hexdigest()


def repository_id(repo_root: str) -> str:
    return hashlib.sha256(repo_root.encode("utf-8")).hexdigest()


def manifest_scope_id(
    session_id: str, uid: int, repo_root: str, reason: str, paths: list[str]
) -> str:
    scope = "\0".join([session_id, str(uid), repo_root, reason, *paths]).encode("utf-8")
    return hashlib.sha256(scope).hexdigest()


def secure_source_content(path: str) -> tuple[bytes, str]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise SourceAccessError("source path could not be opened safely") from exc
    digest = hashlib.sha256()
    content = bytearray()
    total = 0
    try:
        opened_stat = os.fstat(descriptor)
        _require_source(
            stat.S_ISREG(opened_stat.st_mode) and opened_stat.st_nlink == 1,
            "hard-linked or non-regular source files cannot be approved",
        )
        _require_source(
            opened_stat.st_size <= MAX_SOURCE_BYTES,
            "source file exceeds the approval size limit",
        )
        while chunk := os.read(descriptor, 64 * 1024):
            total += len(chunk)
            _require_source(total <= MAX_SOURCE_BYTES, "source file exceeds the approval size limit")
            content.extend(chunk)
            digest.update(chunk)
        current_stat = os.lstat(path)
        _require_source(
            stat.S_ISREG(current_stat.st_mode)
            and current_stat.st_dev == opened_stat.st_dev
            and current_stat.st_ino == opened_stat.st_ino,
            "source path changed during approval",
        )
    except OSError as exc:
        raise SourceAccessError("source path changed during approval") from exc
    finally:
        os.close(descriptor)
    return bytes(content), digest.hexdigest()


def request_directory(config: Config, home: Path) -> Path:
    return config.request_root or home / ".aidevops" / ".agent-workspace" / "source-access" / "requests"


def _reusable_request_id(
    existing: dict[str, Any], spec: RequestSpec, path: str, issued_at: int
) -> str | None:
    created_at = existing.get("created_at")
    if isinstance(created_at, bool) or not isinstance(created_at, int):
        return None
    expected = {
        "schema": SCHEMA_REQUEST,
        "session_id": spec.session_id,
        "uid": spec.uid,
        "path": path,
        "reason": spec.reason,
    }
    if any(existing.get(key) != value for key, value in expected.items()):
        return None
    request_age = issued_at - created_at
    if request_age < 0 or request_age > REQUEST_REUSE_SECONDS:
        return None
    request_id = str(existing.get("request_id", ""))
    return request_id if ID_PATTERN.fullmatch(request_id) else None


def create_request(config: Config, spec: RequestSpec) -> str:
    issued_at = int(time.time() if spec.now is None else spec.now)
    session_id = _validate_session_id(spec.session_id)
    reason = _validate_reason(spec.reason)
    path = canonical_tracked_source(spec.path)
    normalized_spec = RequestSpec(session_id, spec.uid, spec.home, path, reason, spec.now)
    directory = request_directory(config, spec.home)
    _ensure_directory(directory, 0o700)

    for candidate in directory.glob("*.json"):
        try:
            existing = json.loads(candidate.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        reusable_id = _reusable_request_id(existing, normalized_spec, path, issued_at)
        if reusable_id is not None:
            return reusable_id

    request_id = secrets.token_hex(16)
    request = {
        "schema": SCHEMA_REQUEST,
        "request_id": request_id,
        "session_id": session_id,
        "uid": spec.uid,
        "path": path,
        "reason": reason,
        "created_at": issued_at,
    }
    atomic_write(directory / f"{request_id}.json", canonical_json(request) + b"\n", 0o600)
    return request_id


def create_manifest_request(config: Config, spec: ManifestRequestSpec) -> str:
    issued_at = spec.now
    session_id = _validate_session_id(spec.session_id)
    reason = _validate_reason(spec.reason)
    _require_source(
        2 <= len(spec.paths) <= MAX_MANIFEST_ENTRIES,
        f"source-access manifests require 2 to {MAX_MANIFEST_ENTRIES} paths",
    )
    identities = list(map(tracked_source_identity, spec.paths))
    repo_roots = set(map(itemgetter(1), identities))
    _require_source(len(repo_roots) == 1, "all manifest paths must belong to one Git worktree")
    entries = sorted(map(_manifest_entry, identities), key=itemgetter("relative_path"))
    paths = list(map(itemgetter("path"), entries))
    _require_source(len(paths) == len(set(paths)), "source-access manifest paths must be unique")
    repo_root = repo_roots.pop()
    request_id = manifest_scope_id(session_id, spec.uid, repo_root, reason, paths)
    request = {
        "schema": SCHEMA_MANIFEST_REQUEST,
        "request_id": request_id,
        "session_id": session_id,
        "uid": spec.uid,
        "repo_root": repo_root,
        "repository_id": repository_id(repo_root),
        "reason": reason,
        "entries": entries,
        "created_at": issued_at,
    }
    directory = request_directory(config, spec.home)
    _ensure_directory(directory, 0o700)
    request_path = directory / f"{request_id}.json"
    atomic_write(request_path, canonical_json(request) + b"\n", 0o600)
    return request_id


def _manifest_entry(identity: tuple[str, str, str]) -> dict[str, str]:
    path, _repo_root, relative_path = identity
    return {"path": path, "relative_path": relative_path}


def proposal_directory(config: Config, home: Path) -> Path:
    return request_directory(config, home) / "proposals"


def _source_context_socket(path: Path, uid: int) -> dict[str, int]:
    _require_source(path.is_absolute() and not _has_symlink_component(path), "unsafe context socket")
    for ancestor in path.parents:
        metadata = ancestor.lstat()
        _require_source(
            stat.S_ISDIR(metadata.st_mode) and metadata.st_uid in (0, uid)
            and metadata.st_mode & 0o022 == 0,
            "unsafe context socket ancestry",
        )
    _require_source(_trusted_private_directory(path.parent, uid), "unsafe context socket directory")
    metadata = path.lstat()
    _require_source(
        stat.S_ISSOCK(metadata.st_mode) and metadata.st_uid == uid
        and metadata.st_mode & 0o077 == 0 and metadata.st_nlink == 1,
        "unsafe context socket",
    )
    return {"device": metadata.st_dev, "inode": metadata.st_ino}


def _context_peer_identity(connection: socket.socket) -> tuple[int, int]:
    if sys.platform == "darwin":
        # Darwin sys/un.h: SOL_LOCAL=0, LOCAL_PEERCRED=1, LOCAL_PEERPID=2.
        # sys/ucred.h: xucred begins with cr_version and effective cr_uid.
        credentials = connection.getsockopt(0, 1, 128)
        version, uid = struct.unpack_from("=II", credentials)
        _require_source(version == 0, "unsupported context peer credential layout")
        return connection.getsockopt(0, 2), uid
    _require_source(hasattr(socket, "SO_PEERCRED"), "context peer credentials are unsupported")
    credentials = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
    pid, uid, _gid = struct.unpack("=iII", credentials)
    return pid, uid


def _validated_context_reply(
    reply: Any, query: dict[str, Any], pid: int, uid: int
) -> dict[str, Any]:
    _require_source(isinstance(reply, dict), "invalid source context response")
    expected = {"schema": "aidevops-source-context-reply/v1", "authority": "none",
                "nonce": query["nonce"], "session_id": query["session_id"],
                "repo_root": query["repo_root"], "runtime_pid": pid, "uid": uid}
    _require_source(
        all(reply.get(key) == value for key, value in expected.items())
        and type(reply.get("runtime_pid")) is int and type(reply.get("uid")) is int,
        "source context peer identity or challenge did not match",
    )
    generation_error = "source context generation is invalid"
    _require_source(
        isinstance(reply.get("runtime_instance_id"), str)
        and re.fullmatch(r"[a-f0-9]{32}", reply["runtime_instance_id"]) is not None,
        generation_error,
    )
    _require_source(
        type(reply.get("session_created_at")) is int and reply["session_created_at"] >= 0,
        generation_error,
    )
    _require_source(
        isinstance(reply.get("project_id"), str) and 0 < len(reply["project_id"]) <= 256,
        generation_error,
    )
    fields = ("session_id", "repo_root", "runtime_pid", "uid", "runtime_instance_id",
              "session_created_at", "project_id")
    return {key: reply[key] for key in fields}


def _context_timeout(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    _require_source(remaining > 0, "source context deadline exceeded")
    return remaining


def query_source_context(socket_path: str, session_id: str, repo_root: str, uid: int) -> dict[str, Any]:
    """Challenge a live peer. This metadata alone never authorizes source reads."""
    query = {"schema": "aidevops-source-context-query/v1", "nonce": secrets.token_hex(32),
             "session_id": _validate_session_id(session_id), "repo_root": repo_root}
    path = Path(socket_path)
    try:
        identity = _source_context_socket(path, uid)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            deadline = time.monotonic() + 5
            connection.settimeout(_context_timeout(deadline))
            connection.connect(str(path))
            pid, peer_uid = _context_peer_identity(connection)
            _require_source(pid > 0 and peer_uid == uid, "source context belongs to another user")
            connection.settimeout(_context_timeout(deadline))
            connection.sendall(canonical_json(query) + b"\n")
            response = bytearray()
            while True:
                connection.settimeout(_context_timeout(deadline))
                chunk = connection.recv(4096)
                if not chunk:
                    break
                response.extend(chunk)
                _require_source(len(response) <= 8192, "source context response is too large")
            reply = json.loads(response.decode("utf-8"))
        _require_source(identity == _source_context_socket(path, uid), "source context socket changed")
        context = _validated_context_reply(reply, query, pid, peer_uid)
        return {**context, "socket_path": str(path), "socket_identity": identity}
    except (OSError, ValueError, struct.error, RecursionError) as exc:
        raise SourceAccessError("source context is unavailable; no authority was issued") from exc


@contextmanager
def _proposal_store(config: Config, home: Path, uid: int) -> Iterator[Path]:
    """Serialize user-space proposal metadata; never run this writer as sudo."""
    _require_source(type(uid) is int and uid > 0 and os.geteuid() == uid,
                    "prepare or withdraw proposals as their non-root owning user")
    directory = proposal_directory(config, home)
    _require_source(not _has_symlink_component(directory), "unsafe proposal directory")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    _require_source(_trusted_private_directory(directory, uid), "unsafe proposal directory")
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(directory / ".lock", flags, 0o600)
    except OSError as exc:
        raise SourceAccessError("unsafe or unavailable proposal lock") from exc
    try:
        metadata = os.fstat(descriptor)
        _require_source(
            stat.S_ISREG(metadata.st_mode) and metadata.st_uid == uid
            and metadata.st_nlink == 1 and metadata.st_mode & 0o077 == 0,
            "unsafe proposal lock",
        )
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield directory
    except OSError as exc:
        raise SourceAccessError("proposal store unavailable or busy; no authority was changed") from exc
    finally:
        os.close(descriptor)


def _proposal_file_identity(path: Path) -> dict[str, int]:
    metadata = path.lstat()
    return {"device": metadata.st_dev, "inode": metadata.st_ino}


def _proposal_repository_identity(repo_root: str) -> dict[str, Any]:
    root = Path(repo_root)
    values = []
    for option in ("--absolute-git-dir", "--git-common-dir", "HEAD"):
        result = _run([GIT, "-C", repo_root, "rev-parse", option])
        _require_source(result.returncode == 0, "proposal requires an existing committed worktree")
        values.append(result.stdout.decode("utf-8").strip())
    git_dir = (root / values[0]).resolve(strict=True)
    common_dir = (root / values[1]).resolve(strict=True)
    _require_source(git_dir != common_dir, "proposal requires a linked implementation worktree")
    listing = _run([GIT, "-C", repo_root, "worktree", "list", "--porcelain", "-z"])
    _require_source(
        listing.returncode == 0 and b"worktree " + os.fsencode(root) in listing.stdout.split(b"\0"),
        "proposal worktree is no longer registered",
    )
    return {
        "root": repo_root, "head": values[2], "git_dir": str(git_dir),
        "common_dir": str(common_dir), "root_identity": _proposal_file_identity(root),
        "git_identity": _proposal_file_identity(git_dir),
        "common_identity": _proposal_file_identity(common_dir),
    }


def _proposal_source_snapshot(spec: ManifestRequestSpec) -> dict[str, Any]:
    _require_source(1 <= len(spec.paths) <= MAX_MANIFEST_ENTRIES, "invalid proposal entry count")
    identities = [tracked_source_identity(path) for path in spec.paths]
    roots = {identity[1] for identity in identities}
    paths = [identity[0] for identity in identities]
    _require_source(len(roots) == 1, "proposal paths must share one worktree")
    _require_source(len(set(paths)) == len(paths), "proposal paths must be unique")
    repository = _proposal_repository_identity(roots.pop())
    entries = []
    total_bytes = 0
    for path, _root, relative in sorted(identities):
        before = _proposal_file_identity(Path(path))
        content, digest = secure_source_content(path)
        _require_source(before == _proposal_file_identity(Path(path)), "proposal source was replaced")
        total_bytes += len(content)
        _require_source(total_bytes <= MAX_SOURCE_BYTES, "proposal exceeds the total source size limit")
        entries.append({"path": path, "relative_path": relative, "content_sha256": digest,
                        "size": len(content), "identity": before})
    _require_source(
        repository == _proposal_repository_identity(repository["root"]),
        "proposal repository changed while collecting metadata",
    )
    return {"repository": repository, "entries": entries}


def _proposal_records(directory: Path) -> list[Path]:
    records = []
    with os.scandir(directory) as iterator:
        for entry in iterator:
            if entry.name.endswith(".json"):
                records.append(Path(entry.path))
                _require_source(len(records) <= MAX_PENDING_PROPOSALS, "proposal store is over capacity")
    return sorted(records)


def create_source_proposal(
    config: Config, spec: ManifestRequestSpec, *, issue_snapshot_sha256: str,
    context_socket: str | None = None,
) -> str:
    """Persist candidate identities, not approval, ownership or liveness evidence."""
    _require_source(type(spec.uid) is int and spec.uid > 0 and os.geteuid() == spec.uid,
                    "prepare proposals as their non-root owning user")
    _require_source(type(spec.now) is int and spec.now >= 0, "invalid proposal timestamp")
    _require_source(
        isinstance(issue_snapshot_sha256, str)
        and re.fullmatch(r"[a-f0-9]{64}", issue_snapshot_sha256) is not None,
        "proposal requires an exact issue snapshot digest",
    )
    body = {
        "session_id": _validate_session_id(spec.session_id), "uid": spec.uid,
        "reason": _validate_reason(spec.reason), "created_at": spec.now,
        "nonce": secrets.token_hex(16), "issue_snapshot_sha256": issue_snapshot_sha256,
        **_proposal_source_snapshot(spec),
    }
    if context_socket is not None:
        body["runtime_context"] = query_source_context(
            context_socket, spec.session_id, body["repository"]["root"], spec.uid,
        )
    proposal_id = hashlib.sha256(canonical_json(body)).hexdigest()
    record = {"schema": SCHEMA_PROPOSAL, "proposal_id": proposal_id, "state": "pending", "body": body}
    content = canonical_json(record) + b"\n"
    _require_source(len(content) <= MAX_REQUEST_BYTES, "proposal metadata exceeds the storage limit")
    with _proposal_store(config, spec.home, spec.uid) as directory:
        records = _proposal_records(directory)
        for candidate in records:
            try:
                existing = load_source_proposal(config, spec.home, candidate.stem, spec.uid)
            except SourceAccessError:
                continue
            comparable = {**body, "nonce": existing.get("nonce"), "created_at": existing["created_at"]}
            if existing["created_at"] <= spec.now and canonical_json(comparable) == canonical_json(existing):
                return candidate.stem
        _require_source(
            len(records) < MAX_PENDING_PROPOSALS,
            "proposal store is full; explicitly withdraw an unused proposal",
        )
        _require_source(not os.path.lexists(directory / f"{proposal_id}.json"), "proposal already exists")
        atomic_write(directory / f"{proposal_id}.json", content, 0o600)
    return proposal_id


def load_source_proposal(config: Config, home: Path, proposal_id: str, uid: int) -> dict[str, Any]:
    """Load a content-bound, powerless proposal; elapsed age is not authority."""
    _require_source(re.fullmatch(r"[a-f0-9]{64}", proposal_id) is not None, "invalid proposal identifier")
    directory = proposal_directory(config, home)
    _require_source(
        not _has_symlink_component(directory) and _trusted_private_directory(directory, uid),
        "proposal was withdrawn, removed or is unavailable",
    )
    record = _read_request_record(directory / f"{proposal_id}.json", uid)
    body = record.get("body")
    identity_error = "proposal identity is invalid or was changed"
    _require_source(
        record.get("schema") == SCHEMA_PROPOSAL and record.get("proposal_id") == proposal_id
        and record.get("state") == "pending" and isinstance(body, dict),
        identity_error,
    )
    _require_source(type(body.get("uid")) is int and body["uid"] == uid, identity_error)
    _require_source(
        hashlib.sha256(canonical_json(body)).hexdigest() == proposal_id,
        identity_error,
    )
    _require_source(
        type(body.get("created_at")) is int and body["created_at"] >= 0,
        "proposal timestamp is invalid",
    )
    return body


def revalidate_source_proposal_metadata(
    config: Config, spec: ManifestRequestSpec, proposal_id: str, *, issue_snapshot_sha256: str
) -> dict[str, Any]:
    """Check candidate metadata only. This MUST NOT be used as approval admission."""
    body = load_source_proposal(config, spec.home, proposal_id, spec.uid)
    _require_source(
        body.get("session_id") == _validate_session_id(spec.session_id)
        and body.get("reason") == _validate_reason(spec.reason)
        and body.get("issue_snapshot_sha256") == issue_snapshot_sha256,
        "proposal context changed; new explicit context consent is required",
    )
    created_at = body.get("created_at")
    _require_source(type(spec.now) is int and spec.now >= created_at, "proposal clock moved backwards")
    snapshot = _proposal_source_snapshot(spec)
    _require_source(
        all(body.get(key) == value for key, value in snapshot.items()),
        "proposal source or worktree changed; do not silently refresh it",
    )
    return body


def revalidate_source_proposal_context(body: dict[str, Any], uid: int) -> dict[str, Any]:
    """Re-challenge the recorded endpoint; never silently rebind its generation."""
    recorded = body.get("runtime_context")
    error = "proposal has no actionable runtime context; new explicit context consent is required"
    _require_source(
        isinstance(recorded, dict) and isinstance(recorded.get("socket_path"), str), error,
    )
    _require_source(
        isinstance(body.get("repository"), dict)
        and isinstance(body["repository"].get("root"), str)
        and type(body.get("uid")) is int and body["uid"] == uid, error,
    )
    current = query_source_context(
        recorded["socket_path"], body.get("session_id", ""), body["repository"]["root"], uid,
    )
    _require_source(current == recorded, "proposal runtime changed; new explicit context consent is required")
    return current


def withdraw_source_proposal(config: Config, home: Path, proposal_id: str, uid: int) -> None:
    """Remove pending metadata, freeing capacity; never revoke a signed capability."""
    with _proposal_store(config, home, uid) as directory:
        load_source_proposal(config, home, proposal_id, uid)
        (directory / f"{proposal_id}.json").unlink()


def parse_ttl(value: str) -> int:
    match = re.fullmatch(r"([1-9][0-9]*)([mh])", value)
    _require_source(match is not None, "TTL must use minutes or hours, for example 30m or 12h")
    amount = int(match.group(1))
    seconds = amount * (60 if match.group(2) == "m" else 3600)
    _require_source(60 <= seconds <= MAX_TTL_SECONDS, "TTL must be between 1 minute and 12 hours")
    return seconds


def _trusted_node(
    path: Path,
    owner_uid: int,
    expected_kind: Callable[[int], bool],
    forbidden_mode: int,
) -> bool:
    try:
        metadata = path.lstat()
    except OSError:
        return False
    return (
        expected_kind(metadata.st_mode)
        and not stat.S_ISLNK(metadata.st_mode)
        and metadata.st_uid == owner_uid
        and metadata.st_mode & forbidden_mode == 0
    )


def _trusted_file(path: Path, owner_uid: int) -> bool:
    return _trusted_node(path, owner_uid, stat.S_ISREG, 0o022)


def _trusted_private_key(path: Path, owner_uid: int) -> bool:
    return _trusted_node(path, owner_uid, stat.S_ISREG, 0o077)


def _trusted_directory(path: Path, owner_uid: int) -> bool:
    return _trusted_node(path, owner_uid, stat.S_ISDIR, 0o022)


def _trusted_private_directory(path: Path, owner_uid: int) -> bool:
    return _trusted_node(path, owner_uid, stat.S_ISDIR, 0o077)


def _derive_public_key(config: Config) -> bytes:
    _require_source(
        _trusted_private_directory(config.private_key.parent, config.trust_uid),
        "source-access signing key directory ownership or permissions are unsafe",
    )
    _require_source(
        _trusted_private_key(config.private_key, config.trust_uid),
        "source-access signing key ownership or permissions are unsafe",
    )
    result = _run(
        [
            SSH_KEYGEN,
            "-y",
            "-f",
            str(config.private_key),
        ]
    )
    _require_source(result.returncode == 0, "failed to derive the source-access verification key")
    public_key_output = result.stdout.strip()
    public_key_parts = public_key_output.split()
    key_error = "failed to derive a valid source-access verification key"
    _require_source(len(public_key_parts) >= 2, key_error)
    _require_source(public_key_parts[0] == b"ssh-ed25519", key_error)
    _require_source(bool(public_key_parts[1]), key_error)
    _require_source(b"\n" not in public_key_output, key_error)
    _require_source(b"\r" not in public_key_output, key_error)
    return b" ".join(public_key_parts[:2])


def _trust_marker_content(public_key: bytes) -> bytes:
    return (
        b"schema="
        + SCHEMA_TRUST.encode("ascii")
        + b"\nkey_source="
        + TRUST_KEY_SOURCE_DEDICATED.encode("ascii")
        + b"\npublic_key="
        + public_key
        + b"\n"
    )


def validate_key_material(config: Config) -> None:
    trust_error = "source-access signing trust ownership, permissions, or key binding are unsafe"
    _require_source(_trusted_directory(config.config_dir, config.trust_uid), trust_error)
    _require_source(_trusted_file(config.public_key, config.trust_uid), trust_error)
    _require_source(_trusted_file(config.trust_marker, config.trust_uid), trust_error)
    derived_public_key = _derive_public_key(config)
    try:
        public_key = config.public_key.read_bytes()
        trust_marker = config.trust_marker.read_bytes()
    except OSError as exc:
        raise SourceAccessError(trust_error) from exc
    _require_source(public_key == derived_public_key + b"\n", trust_error)
    _require_source(trust_marker == _trust_marker_content(derived_public_key), trust_error)


def _read_request_record(request_path: Path, expected_uid: int) -> dict[str, Any]:
    """Read bounded untrusted metadata through the descriptor we validate."""
    trust_error = "source-access request ownership or permissions are unsafe"
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(request_path, flags)
    except OSError as exc:
        raise SourceAccessError(trust_error) from exc
    try:
        metadata = os.fstat(descriptor)
        _require_source(
            stat.S_ISREG(metadata.st_mode)
            and metadata.st_nlink == 1
            and metadata.st_uid == expected_uid
            and metadata.st_mode & 0o022 == 0,
            trust_error,
        )
        _require_source(metadata.st_size <= MAX_REQUEST_BYTES, "source-access request is too large")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            content = handle.read(MAX_REQUEST_BYTES + 1)
        _require_source(len(content) <= MAX_REQUEST_BYTES, "source-access request is too large")
        current = request_path.lstat()
        final = os.fstat(descriptor)
        identity_fields = (
            "st_dev", "st_ino", "st_mode", "st_nlink", "st_uid",
            "st_size", "st_mtime_ns", "st_ctime_ns",
        )
        _require_source(
            (current.st_dev, current.st_ino) == (metadata.st_dev, metadata.st_ino)
            and all(getattr(final, field) == getattr(metadata, field) for field in identity_fields),
            "source-access request changed while reading",
        )
        request = json.loads(content.decode("utf-8"))
    except (OSError, ValueError, RecursionError) as exc:
        raise SourceAccessError("source-access request was not found or is malformed") from exc
    finally:
        os.close(descriptor)
    _require_source(isinstance(request, dict), "source-access request must be an object")
    return request


def _load_request(
    config: Config, home: Path, request_id: str, expected_uid: int
) -> dict[str, Any]:
    _require_source(ID_PATTERN.fullmatch(request_id) is not None, "invalid request identifier")
    request_path = request_directory(config, home) / f"{request_id}.json"
    trust_error = "source-access request ownership or permissions are unsafe"
    _require_source(_trusted_directory(request_path.parent, expected_uid), trust_error)
    _require_source(_trusted_file(request_path, expected_uid), trust_error)
    request = _read_request_record(request_path, expected_uid)
    schema_error = "source-access request schema or identifier is invalid"
    _require_source(
        request.get("schema") in (SCHEMA_REQUEST, SCHEMA_MANIFEST_REQUEST), schema_error
    )
    _require_source(request.get("request_id") == request_id, schema_error)
    return request


def _create_trusted_directory(path: Path, mode: int, owner_uid: int) -> None:
    try:
        path.mkdir(mode=mode)
    except OSError as exc:
        raise SourceAccessError("failed to create the source-access signing key directory") from exc
    if os.geteuid() == 0:
        os.chown(path, owner_uid, 0)


def _prepare_trusted_directory(path: Path, mode: int, owner_uid: int) -> None:
    trust_error = "source-access signing key directory ownership or permissions are unsafe"
    if not os.path.lexists(path):
        _create_trusted_directory(path, mode, owner_uid)
    _require_source(_trusted_directory(path, owner_uid), trust_error)
    os.chmod(path, mode)
    _require_source(_trusted_directory(path, owner_uid), trust_error)


def _generate_dedicated_signing_key(config: Config) -> None:
    public_companion = Path(f"{config.private_key}.pub")
    _prepare_trusted_directory(config.config_dir, 0o755, config.trust_uid)
    _prepare_trusted_directory(config.private_key.parent, 0o700, config.trust_uid)
    _require_source(
        not os.path.lexists(config.private_key) and not os.path.lexists(public_companion),
        "source-access signing key path already exists or is unsafe",
    )
    result = _run(
        [
            SSH_KEYGEN,
            "-q",
            "-t",
            "ed25519",
            "-N",
            "",
            "-C",
            "aidevops-source-access-signing",
            "-f",
            str(config.private_key),
        ]
    )
    _require_source(result.returncode == 0, "failed to create the source-access signing key")
    for key_path in (config.private_key, public_companion):
        if os.geteuid() == 0:
            os.chown(key_path, config.trust_uid, 0)
        os.chmod(key_path, 0o600)
        _require_source(
            _trusted_private_key(key_path, config.trust_uid),
            "failed to create the source-access signing key",
        )


def setup_key_material(config: Config) -> None:
    if not os.path.lexists(config.private_key):
        _generate_dedicated_signing_key(config)
    _prepare_trusted_directory(config.config_dir, 0o755, config.trust_uid)
    public_key = _derive_public_key(config)
    atomic_write(config.public_key, public_key + b"\n", 0o644, config.trust_uid)
    atomic_write(
        config.trust_marker,
        _trust_marker_content(public_key),
        0o644,
        config.trust_uid,
    )
    validate_key_material(config)


def _single_approval_path(payload: dict[str, Any]) -> str:
    return str(payload["path"])


def _manifest_approval_path(payload: dict[str, Any]) -> str:
    entries = payload["entries"]
    _require_source(isinstance(entries, list), "source-access manifest is malformed")
    return f"{payload['repo_root']} ({len(entries)} exact paths)"


_APPROVAL_PATH_READERS = {
    SCHEMA_PAYLOAD: _single_approval_path,
    SCHEMA_MANIFEST_PAYLOAD: _manifest_approval_path,
}


def list_approvals(config: Config, *, uid: int, now: int | None = None) -> list[dict[str, Any]]:
    checked_at = int(time.time() if now is None else now)
    results: list[dict[str, Any]] = []
    directory = config.state_dir / "approvals" / str(uid)
    if not directory.is_dir():
        return results
    for receipt_path in sorted(directory.glob("*.json")):
        try:
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            payload = receipt["payload"]
            path = _APPROVAL_PATH_READERS[payload["schema"]](payload)
            results.append(
                {
                    "approval_id": payload["approval_id"],
                    "session_id": payload["session_id"],
                    "path": path,
                    "expires_at": payload["expires_at"],
                    "status": "active" if checked_at < int(payload["expires_at"]) else "expired",
                }
            )
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
            continue
    return results


def real_user() -> tuple[int, Path]:
    sudo_user = os.environ.get("SUDO_USER", "")
    if os.geteuid() == 0 and sudo_user:
        account = pwd.getpwnam(sudo_user)
        return account.pw_uid, Path(account.pw_dir)
    return os.getuid(), Path.home()
