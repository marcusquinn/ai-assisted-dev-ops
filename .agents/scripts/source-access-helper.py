#!/usr/bin/env python3
"""Human-approved, session-bound exceptions for low-confidence source-read blocks."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pwd
import re
import secrets
import stat
import subprocess
import sys
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
ALLOWED_SUFFIXES = {
    ".c",
    ".cjs",
    ".cpp",
    ".go",
    ".h",
    ".hpp",
    ".java",
    ".js",
    ".json",
    ".jsx",
    ".kt",
    ".md",
    ".mjs",
    ".php",
    ".py",
    ".rb",
    ".rs",
    ".sh",
    ".swift",
    ".toml",
    ".ts",
    ".tsx",
    ".yaml",
    ".yml",
}
DENIED_NAMES = {
    ".netrc",
    ".npmrc",
    ".pypirc",
    "auth.json",
    "credentials",
    "credentials.json",
    "id_dsa",
    "id_ecdsa",
    "id_ed25519",
    "id_rsa",
    "kubeconfig",
}
DENIED_SUFFIXES = {".jks", ".key", ".keystore", ".p12", ".pem", ".pfx"}
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


def _validate_session_id(session_id: str) -> str:
    if not SESSION_PATTERN.fullmatch(session_id):
        raise SourceAccessError("invalid runtime session identifier")
    return session_id


def _validate_reason(reason: str) -> str:
    if reason != OVERRIDABLE_REASON:
        raise SourceAccessError("only the basename-only source guard can be approved")
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
    if not raw_path or any(ord(character) < 32 for character in raw_path):
        raise SourceAccessError("source path is empty or contains control characters")
    absolute = Path(os.path.abspath(os.path.expanduser(raw_path)))
    if _has_symlink_component(absolute):
        raise SourceAccessError("symlinked source paths cannot be approved")
    try:
        resolved = absolute.resolve(strict=True)
        file_stat = resolved.stat()
    except OSError as exc:
        raise SourceAccessError("source path is unavailable") from exc
    if not stat.S_ISREG(file_stat.st_mode):
        raise SourceAccessError("source path is not a regular file")

    basename = resolved.name.lower()
    if basename.startswith(".env") or basename in DENIED_NAMES:
        raise SourceAccessError("credential-like source paths cannot be approved")
    if resolved.suffix.lower() in DENIED_SUFFIXES:
        raise SourceAccessError("private key and credential containers cannot be approved")
    if resolved.suffix.lower() not in ALLOWED_SUFFIXES:
        raise SourceAccessError("path is not an approved source or documentation type")

    root_result = _run([GIT, "-C", str(resolved.parent), "rev-parse", "--show-toplevel"])
    if root_result.returncode != 0:
        raise SourceAccessError("source path is not inside a Git worktree")
    git_root = Path(root_result.stdout.decode("utf-8").strip()).resolve()
    try:
        relative_path = resolved.relative_to(git_root)
    except ValueError as exc:
        raise SourceAccessError("source path escapes its Git worktree") from exc
    tracked_result = _run(
        [GIT, "-C", str(git_root), "ls-files", "--error-unmatch", "--", str(relative_path)]
    )
    if tracked_result.returncode != 0:
        raise SourceAccessError("only Git-tracked source files can be approved")
    return str(resolved)


def scope_id(session_id: str, uid: int, path: str, reason: str) -> str:
    scope = f"{session_id}\0{uid}\0{path}\0{reason}".encode("utf-8")
    return hashlib.sha256(scope).hexdigest()


def secure_source_content(path: str) -> tuple[bytes, str]:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise SourceAccessError("source path could not be opened safely") from exc
    digest = hashlib.sha256()
    content = bytearray()
    total = 0
    try:
        opened_stat = os.fstat(descriptor)
        if not stat.S_ISREG(opened_stat.st_mode) or opened_stat.st_nlink != 1:
            raise SourceAccessError("hard-linked or non-regular source files cannot be approved")
        if opened_stat.st_size > MAX_SOURCE_BYTES:
            raise SourceAccessError("source file exceeds the approval size limit")
        while chunk := os.read(descriptor, 64 * 1024):
            total += len(chunk)
            if total > MAX_SOURCE_BYTES:
                raise SourceAccessError("source file exceeds the approval size limit")
            content.extend(chunk)
            digest.update(chunk)
        current_stat = os.lstat(path)
        if (
            not stat.S_ISREG(current_stat.st_mode)
            or current_stat.st_dev != opened_stat.st_dev
            or current_stat.st_ino != opened_stat.st_ino
        ):
            raise SourceAccessError("source path changed during approval")
    except OSError as exc:
        raise SourceAccessError("source path changed during approval") from exc
    finally:
        os.close(descriptor)
    return bytes(content), digest.hexdigest()


def request_directory(config: Config, home: Path) -> Path:
    if config.request_root is not None:
        return config.request_root
    return home / ".aidevops" / ".agent-workspace" / "source-access" / "requests"


def create_request(
    config: Config,
    *,
    session_id: str,
    uid: int,
    home: Path,
    path: str,
    reason: str,
    now: int | None = None,
) -> str:
    issued_at = int(time.time() if now is None else now)
    session_id = _validate_session_id(session_id)
    reason = _validate_reason(reason)
    path = canonical_tracked_source(path)
    directory = request_directory(config, home)
    _ensure_directory(directory, 0o700)

    for candidate in directory.glob("*.json"):
        try:
            existing = json.loads(candidate.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        created_at = existing.get("created_at")
        if isinstance(created_at, bool) or not isinstance(created_at, int):
            continue
        if (
            existing.get("schema") == SCHEMA_REQUEST
            and existing.get("session_id") == session_id
            and existing.get("uid") == uid
            and existing.get("path") == path
            and existing.get("reason") == reason
            and 0 <= issued_at - created_at <= REQUEST_REUSE_SECONDS
        ):
            request_id = str(existing.get("request_id", ""))
            if ID_PATTERN.fullmatch(request_id):
                return request_id

    request_id = secrets.token_hex(16)
    request = {
        "schema": SCHEMA_REQUEST,
        "request_id": request_id,
        "session_id": session_id,
        "uid": uid,
        "path": path,
        "reason": reason,
        "created_at": issued_at,
    }
    atomic_write(directory / f"{request_id}.json", canonical_json(request) + b"\n", 0o600)
    return request_id


def parse_ttl(value: str) -> int:
    match = re.fullmatch(r"([1-9][0-9]*)([mh])", value)
    if not match:
        raise SourceAccessError("TTL must use minutes or hours, for example 30m or 12h")
    amount = int(match.group(1))
    seconds = amount * (60 if match.group(2) == "m" else 3600)
    if seconds < 60 or seconds > MAX_TTL_SECONDS:
        raise SourceAccessError("TTL must be between 1 minute and 12 hours")
    return seconds


def setup_key_material(config: Config) -> None:
    if not _trusted_directory(config.private_key.parent, config.trust_uid):
        raise SourceAccessError("existing approval key directory ownership or permissions are unsafe")
    if not _trusted_private_key(config.private_key, config.trust_uid):
        raise SourceAccessError(
            "existing root-owned aidevops approval key is unavailable"
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
    if result.returncode != 0:
        raise SourceAccessError("failed to derive the source-access verification key")
    atomic_write(config.public_key, result.stdout.strip() + b"\n", 0o644, config.trust_uid)


def _load_request(
    config: Config, home: Path, request_id: str, expected_uid: int
) -> dict[str, Any]:
    if not ID_PATTERN.fullmatch(request_id):
        raise SourceAccessError("invalid request identifier")
    request_path = request_directory(config, home) / f"{request_id}.json"
    if not _trusted_directory(request_path.parent, expected_uid) or not _trusted_file(
        request_path, expected_uid
    ):
        raise SourceAccessError("source-access request ownership or permissions are unsafe")
    try:
        request = json.loads(request_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SourceAccessError("source-access request was not found or is malformed") from exc
    if request.get("schema") != SCHEMA_REQUEST or request.get("request_id") != request_id:
        raise SourceAccessError("source-access request schema or identifier is invalid")
    return request


def _sign_payload(config: Config, payload: dict[str, Any]) -> str:
    if not _trusted_directory(config.private_key.parent, config.trust_uid) or not _trusted_private_key(
        config.private_key, config.trust_uid
    ):
        raise SourceAccessError("source-access private key ownership or permissions are unsafe")
    with tempfile.TemporaryDirectory(prefix="aidevops-source-access-sign-") as temp_dir:
        payload_path = Path(temp_dir) / "payload.json"
        payload_path.write_bytes(canonical_json(payload))
        result = _run(
            [
                SSH_KEYGEN,
                "-Y",
                "sign",
                "-f",
                str(config.private_key),
                "-n",
                SIGNATURE_NAMESPACE,
                str(payload_path),
            ]
        )
        signature_path = Path(f"{payload_path}.sig")
        if result.returncode != 0 or not signature_path.is_file():
            raise SourceAccessError("failed to sign source-access approval")
        return signature_path.read_text(encoding="utf-8")


def approve_request(
    config: Config,
    *,
    request_id: str,
    home: Path,
    expected_uid: int,
    ttl_seconds: int,
    now: int | None = None,
    confirm: Callable[[dict[str, Any]], bool] | None = None,
) -> dict[str, Any]:
    issued_at = int(time.time() if now is None else now)
    request = _load_request(config, home, request_id, expected_uid)
    if request.get("uid") != expected_uid:
        raise SourceAccessError("request user does not match the invoking sudo user")
    session_id = _validate_session_id(str(request.get("session_id", "")))
    reason = _validate_reason(str(request.get("reason", "")))
    path = canonical_tracked_source(str(request.get("path", "")))
    content, content_sha256 = secure_source_content(path)
    if not config.private_key.exists() or not config.public_key.exists():
        raise SourceAccessError("run the installed root-owned source-access broker setup first")
    created_at = request.get("created_at")
    if isinstance(created_at, bool) or not isinstance(created_at, int):
        raise SourceAccessError("source-access request timestamp is invalid")
    request_age = issued_at - created_at
    if request_age < 0 or request_age > REQUEST_REUSE_SECONDS:
        raise SourceAccessError("source-access request has expired; retry the blocked read")
    confirmation_scope = {**request, "ttl_seconds": ttl_seconds}
    if confirm is not None and not confirm(confirmation_scope):
        raise SourceAccessError("source-access approval cancelled")

    approval_id = scope_id(session_id, expected_uid, path, reason)
    snapshot_path = (
        config.state_dir / "snapshots" / str(expected_uid) / f"{approval_id}.source"
    )
    payload = {
        "schema": SCHEMA_PAYLOAD,
        "approval_id": approval_id,
        "request_id": request_id,
        "session_id": session_id,
        "uid": expected_uid,
        "path": path,
        "reason": reason,
        "content_sha256": content_sha256,
        "snapshot_path": str(snapshot_path),
        "issued_at": issued_at,
        "expires_at": issued_at + ttl_seconds,
    }
    receipt = {
        "schema": SCHEMA_RECEIPT,
        "payload": payload,
        "signature": _sign_payload(config, payload),
    }
    atomic_write(snapshot_path, content, 0o444, config.trust_uid, directory_mode=0o755)
    receipt_path = config.state_dir / "approvals" / str(expected_uid) / f"{approval_id}.json"
    atomic_write(receipt_path, canonical_json(receipt) + b"\n", 0o644, config.trust_uid)
    try:
        (request_directory(config, home) / f"{request_id}.json").unlink()
    except FileNotFoundError:
        pass
    return payload


def _trusted_file(path: Path, owner_uid: int) -> bool:
    try:
        file_stat = path.lstat()
    except OSError:
        return False
    return (
        stat.S_ISREG(file_stat.st_mode)
        and not stat.S_ISLNK(file_stat.st_mode)
        and file_stat.st_uid == owner_uid
        and file_stat.st_mode & 0o022 == 0
    )


def _trusted_private_key(path: Path, owner_uid: int) -> bool:
    try:
        file_stat = path.lstat()
    except OSError:
        return False
    return (
        stat.S_ISREG(file_stat.st_mode)
        and not stat.S_ISLNK(file_stat.st_mode)
        and file_stat.st_uid == owner_uid
        and file_stat.st_mode & 0o077 == 0
    )


def _trusted_directory(path: Path, owner_uid: int) -> bool:
    try:
        directory_stat = path.lstat()
    except OSError:
        return False
    return (
        stat.S_ISDIR(directory_stat.st_mode)
        and not stat.S_ISLNK(directory_stat.st_mode)
        and directory_stat.st_uid == owner_uid
        and directory_stat.st_mode & 0o022 == 0
    )


def _verify_signature(config: Config, payload: dict[str, Any], signature: str) -> bool:
    if not _trusted_directory(config.public_key.parent, config.trust_uid):
        return False
    if not _trusted_file(config.public_key, config.trust_uid):
        return False
    with tempfile.TemporaryDirectory(prefix="aidevops-source-access-verify-") as temp_dir:
        temp = Path(temp_dir)
        payload_path = temp / "payload.json"
        signature_path = temp / "payload.sig"
        allowed_path = temp / "allowed_signers"
        payload_path.write_bytes(canonical_json(payload))
        signature_path.write_text(signature, encoding="utf-8")
        public_key = config.public_key.read_text(encoding="utf-8").strip()
        allowed_path.write_text(
            f'{SIGNER_IDENTITY} namespaces="{SIGNATURE_NAMESPACE}" {public_key}\n',
            encoding="utf-8",
        )
        result = _run(
            [
                SSH_KEYGEN,
                "-Y",
                "verify",
                "-f",
                str(allowed_path),
                "-I",
                SIGNER_IDENTITY,
                "-n",
                SIGNATURE_NAMESPACE,
                "-s",
                str(signature_path),
            ],
            input_bytes=canonical_json(payload),
        )
        return result.returncode == 0


def verify_approval(
    config: Config,
    *,
    session_id: str,
    uid: int,
    path: str,
    reason: str,
    now: int | None = None,
) -> bool:
    try:
        checked_at = int(time.time() if now is None else now)
        session_id = _validate_session_id(session_id)
        reason = _validate_reason(reason)
        path = canonical_tracked_source(path)
        approval_id = scope_id(session_id, uid, path, reason)
        receipt_path = config.state_dir / "approvals" / str(uid) / f"{approval_id}.json"
        if not _trusted_directory(receipt_path.parent, config.trust_uid):
            return False
        if not _trusted_file(receipt_path, config.trust_uid):
            return False
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        payload = receipt.get("payload")
        if receipt.get("schema") != SCHEMA_RECEIPT or not isinstance(payload, dict):
            return False
        expected = {
            "approval_id": approval_id,
            "session_id": session_id,
            "uid": uid,
            "path": path,
            "reason": reason,
        }
        if any(payload.get(key) != value for key, value in expected.items()):
            return False
        if payload.get("schema") != SCHEMA_PAYLOAD:
            return False
        content_sha256 = payload.get("content_sha256")
        if not isinstance(content_sha256, str) or not re.fullmatch(r"[a-f0-9]{64}", content_sha256):
            return False
        _, current_sha256 = secure_source_content(path)
        if current_sha256 != content_sha256:
            return False
        expected_snapshot = config.state_dir / "snapshots" / str(uid) / f"{approval_id}.source"
        if payload.get("snapshot_path") != str(expected_snapshot):
            return False
        if not _trusted_directory(expected_snapshot.parent, config.trust_uid):
            return False
        if not _trusted_file(expected_snapshot, config.trust_uid):
            return False
        if hashlib.sha256(expected_snapshot.read_bytes()).hexdigest() != content_sha256:
            return False
        if checked_at < int(payload.get("issued_at", 0)):
            return False
        if checked_at >= int(payload.get("expires_at", 0)):
            return False
        if int(payload["expires_at"]) - int(payload["issued_at"]) > MAX_TTL_SECONDS:
            return False
        signature = receipt.get("signature")
        return isinstance(signature, str) and _verify_signature(config, payload, signature)
    except (OSError, ValueError, TypeError, json.JSONDecodeError, SourceAccessError):
        return False


def revoke_approval(config: Config, *, approval_id: str, uid: int) -> None:
    if not ID_PATTERN.fullmatch(approval_id):
        raise SourceAccessError("invalid approval identifier")
    receipt_path = config.state_dir / "approvals" / str(uid) / f"{approval_id}.json"
    try:
        receipt_path.unlink()
    except FileNotFoundError as exc:
        raise SourceAccessError("source-access approval was not found") from exc
    snapshot_path = config.state_dir / "snapshots" / str(uid) / f"{approval_id}.source"
    try:
        snapshot_path.unlink()
    except FileNotFoundError:
        pass


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


def _real_user() -> tuple[int, Path]:
    sudo_user = os.environ.get("SUDO_USER", "")
    if os.geteuid() == 0 and sudo_user:
        account = pwd.getpwnam(sudo_user)
        return account.pw_uid, Path(account.pw_dir)
    return os.getuid(), Path.home()


def _trusted_root_broker(config: Config) -> bool:
    try:
        actual = Path(__file__).resolve(strict=True)
        expected = (config.config_dir / "source-access-helper.py").resolve(strict=True)
        if actual != expected:
            return False
        current = actual
        while True:
            metadata = current.lstat()
            if metadata.st_uid != config.trust_uid or metadata.st_mode & 0o022:
                return False
            if current == Path(current.anchor):
                break
            current = current.parent
        return _trusted_file(actual, config.trust_uid)
    except OSError:
        return False


def _require_root_tty(config: Config) -> None:
    if os.geteuid() != 0:
        raise SourceAccessError("privileged commands must use the installed root-owned source-access broker")
    if not sys.stdin.isatty():
        raise SourceAccessError("this command requires an interactive terminal")
    if not _trusted_root_broker(config):
        raise SourceAccessError("refusing privileged execution outside the root-owned source-access broker")


def _confirm_setup() -> bool:
    print("Reuse the root-owned aidevops approval key for source-access signatures.")
    return input("Type SETUP SOURCE ACCESS to confirm: ") == "SETUP SOURCE ACCESS"


def _confirm_request(request: dict[str, Any]) -> bool:
    print("Approve temporary source-code read access:")
    print(f"  Session: {request['session_id']}")
    print(f"  Path:    {request['path']}")
    print(f"  Reason:  {request['reason']}")
    print(f"  TTL:     {request['ttl_seconds'] // 60} minutes")
    return input("Type APPROVE SOURCE ACCESS to confirm: ") == "APPROVE SOURCE ACCESS"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="aidevops source-access")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("setup")
    request = subparsers.add_parser("request")
    request.add_argument("--session", required=True)
    request.add_argument("--path", required=True)
    request.add_argument("--reason", required=True)
    approve = subparsers.add_parser("approve")
    approve.add_argument("request_id")
    approve.add_argument("--ttl", default="12h")
    verify = subparsers.add_parser("verify")
    verify.add_argument("--session", required=True)
    verify.add_argument("--path", required=True)
    verify.add_argument("--reason", required=True)
    verify.add_argument("--quiet", action="store_true")
    revoke = subparsers.add_parser("revoke")
    revoke.add_argument("approval_id")
    subparsers.add_parser("status")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    uid, home = _real_user()
    config = Config(signing_key=home / ".aidevops" / "approval-keys" / "private" / "approval.key")
    try:
        if args.command == "setup":
            _require_root_tty(config)
            if not _confirm_setup():
                raise SourceAccessError("source-access setup cancelled")
            setup_key_material(config)
            print("Source-access trust is configured with the existing approval key.")
            return 0
        if args.command == "request":
            request_id = create_request(
                config,
                session_id=args.session,
                uid=uid,
                home=home,
                path=args.path,
                reason=args.reason,
            )
            print(request_id)
            return 0
        if args.command == "approve":
            _require_root_tty(config)
            payload = approve_request(
                config,
                request_id=args.request_id,
                home=home,
                expected_uid=uid,
                ttl_seconds=parse_ttl(args.ttl),
                confirm=_confirm_request,
            )
            print(f"Approved: {payload['approval_id']}")
            print(f"Expires epoch: {payload['expires_at']}")
            return 0
        if args.command == "verify":
            valid = verify_approval(
                config,
                session_id=args.session,
                uid=uid,
                path=args.path,
                reason=args.reason,
            )
            if valid and not args.quiet:
                print("VERIFIED")
            return 0 if valid else 1
        if args.command == "revoke":
            _require_root_tty(config)
            revoke_approval(config, approval_id=args.approval_id, uid=uid)
            print(f"Revoked: {args.approval_id}")
            return 0
        if args.command == "status":
            approvals = list_approvals(config, uid=uid)
            if not approvals:
                print("No source-access approvals.")
                return 0
            for approval in approvals:
                print(
                    f"{approval['approval_id']}\t{approval['status']}\t"
                    f"{approval['expires_at']}\t{approval['session_id']}\t{approval['path']}"
                )
            return 0
    except SourceAccessError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
