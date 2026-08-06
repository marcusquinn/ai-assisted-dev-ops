#!/usr/bin/env python3
"""Core policy and request handling for temporary source access."""

from __future__ import annotations

import hashlib
import json
import os
import pwd
import re
import secrets
import stat
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

SCHEMA_REQUEST = "aidevops-source-access-request/v1"
SCHEMA_RECEIPT = "aidevops-source-access-receipt/v1"
SCHEMA_PAYLOAD = "aidevops-source-access-approval/v1"
SIGNATURE_NAMESPACE = "aidevops-source-access-v1"
SIGNER_IDENTITY = "source-access@aidevops.sh"
OVERRIDABLE_REASON = "secret-bearing basename"
MAX_TTL_SECONDS = 12 * 60 * 60
REQUEST_REUSE_SECONDS = 60 * 60
MAX_SOURCE_BYTES = 10 * 1024 * 1024
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


class SourceAccessError(RuntimeError):
    """Typed user-facing failure without source content."""


@dataclass(frozen=True)
class Config:
    config_dir: Path = Path("/etc/aidevops/source-access")
    state_dir: Path = Path("/var/run/aidevops/source-access")
    request_root: Path | None = None
    signing_key: Path | None = None
    trust_uid: int = 0

    @property
    def private_key(self) -> Path:
        if self.signing_key is not None:
            return self.signing_key
        return self.config_dir / "private" / "source-access.key"

    @property
    def public_key(self) -> Path:
        return self.config_dir / "source-access.pub"


@dataclass(frozen=True)
class RequestSpec:
    session_id: str
    uid: int
    home: Path
    path: str
    reason: str
    now: int | None = None


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
    try:
        return subprocess.run(
            command,
            input=input_bytes,
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


def _has_symlink_component(path: Path) -> bool:
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            if stat.S_ISLNK(os.lstat(current).st_mode):
                return True
        except FileNotFoundError:
            return False
    return False


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


def scope_id(session_id: str, uid: int, path: str, reason: str) -> str:
    scope = f"{session_id}\0{uid}\0{path}\0{reason}".encode("utf-8")
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


def _load_request(
    config: Config, home: Path, request_id: str, expected_uid: int
) -> dict[str, Any]:
    _require_source(ID_PATTERN.fullmatch(request_id) is not None, "invalid request identifier")
    request_path = request_directory(config, home) / f"{request_id}.json"
    trust_error = "source-access request ownership or permissions are unsafe"
    _require_source(_trusted_directory(request_path.parent, expected_uid), trust_error)
    _require_source(_trusted_file(request_path, expected_uid), trust_error)
    try:
        request = json.loads(request_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SourceAccessError("source-access request was not found or is malformed") from exc
    schema_error = "source-access request schema or identifier is invalid"
    _require_source(request.get("schema") == SCHEMA_REQUEST, schema_error)
    _require_source(request.get("request_id") == request_id, schema_error)
    return request


def setup_key_material(config: Config) -> None:
    _require_source(
        _trusted_directory(config.private_key.parent, config.trust_uid),
        "existing approval key directory ownership or permissions are unsafe",
    )
    _require_source(
        _trusted_private_key(config.private_key, config.trust_uid),
        "existing root-owned aidevops approval key is unavailable",
    )
    _ensure_directory(config.config_dir, 0o755, config.trust_uid)
    result = _run(
        [
            SSH_KEYGEN,
            "-y",
            "-f",
            str(config.private_key),
        ]
    )
    _require_source(result.returncode == 0, "failed to derive the source-access verification key")
    atomic_write(config.public_key, result.stdout.strip() + b"\n", 0o644, config.trust_uid)


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
            results.append(
                {
                    "approval_id": payload["approval_id"],
                    "session_id": payload["session_id"],
                    "path": payload["path"],
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
