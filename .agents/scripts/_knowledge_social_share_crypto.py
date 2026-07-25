#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Standard-primitive envelopes for encrypted social workspace batches."""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import re
import secrets
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)

SCHEMA_VERSION = 1
IDENTITY_KIND = "social-share-identity"
KEY_FILE = "message-device.json"
KEY_BYTES = 32
MAX_JSON_BYTES = 128 * 1024 * 1024
OPAQUE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$")
PRINCIPAL_ID = re.compile(r"^prn_[0-9a-f]{32}$")
WORKSPACE_ID = re.compile(r"^wsp_[0-9a-f]{32}$")
CORPUS_ID = re.compile(r"^cor_[0-9a-f]{32}$")
HEX_64 = re.compile(r"^[0-9a-f]{64}$")


class ShareError(RuntimeError):
    """Expected sharing failure with a stable privacy-safe error code."""

    def __init__(self, code: str, message: str, exit_code: int = 1) -> None:
        super().__init__(message)
        self.code = code
        self.exit_code = exit_code


@dataclass(frozen=True)
class PublicIdentity:
    """Opaque principal plus one verified Vault message-device public identity."""

    principal_id: str
    device_id: str
    signing_public_key: bytes
    encryption_public_key: bytes

    def descriptor(self) -> dict[str, Any]:
        return {
            "schema_version": SCHEMA_VERSION,
            "kind": IDENTITY_KIND,
            "principal_id": self.principal_id,
            "device_id": self.device_id,
            "signing_public_key": b64e(self.signing_public_key),
            "encryption_public_key": b64e(self.encryption_public_key),
        }


@dataclass(frozen=True)
class PrivateIdentity:
    """Verified local private device identity."""

    public: PublicIdentity
    signing_private_key: Ed25519PrivateKey
    encryption_private_key: X25519PrivateKey


def b64e(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def b64d(value: str, field: str, expected_length: int | None = None) -> bytes:
    try:
        decoded = base64.b64decode(
            (value + ("=" * (-len(value) % 4))).encode("ascii"),
            altchars=b"-_",
            validate=True,
        )
    except (UnicodeEncodeError, binascii.Error, ValueError) as error:
        raise ShareError("SOCIAL_SHARE_INVALID", f"invalid {field}", 3) from error
    if expected_length is not None and len(decoded) != expected_length:
        raise ShareError("SOCIAL_SHARE_INVALID", f"invalid {field} length", 3)
    return decoded


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def validate_opaque(value: Any, field: str) -> str:
    patterns = {
        "principal_id": PRINCIPAL_ID,
        "workspace_id": WORKSPACE_ID,
        "corpus_id": CORPUS_ID,
    }
    if not isinstance(value, str) or not patterns.get(field, OPAQUE_ID).fullmatch(value):
        raise ShareError("SOCIAL_SHARE_INVALID", f"{field} must be opaque", 3)
    return value


def validate_positive_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ShareError("SOCIAL_SHARE_INVALID", f"{field} must be a positive integer", 3)
    return value


def _validated_file_stat(path: Path, *, private: bool, maximum: int) -> os.stat_result:
    try:
        file_stat = path.lstat()
    except FileNotFoundError as error:
        raise ShareError("SOCIAL_SHARE_MISSING", "required sharing input is missing", 2) from error
    if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISREG(file_stat.st_mode):
        raise ShareError("SOCIAL_SHARE_UNSAFE_FILE", "sharing input must be a regular non-symlink file", 3)
    if file_stat.st_size > maximum:
        raise ShareError("SOCIAL_SHARE_TOO_LARGE", "sharing input exceeds the size limit", 3)
    if private and (file_stat.st_uid != os.getuid() or stat.S_IMODE(file_stat.st_mode) & 0o077):
        raise ShareError("SOCIAL_SHARE_UNSAFE_FILE", "private sharing input must be owner-only", 3)
    return file_stat


def read_json(path: Path, *, private: bool = False, maximum: int = MAX_JSON_BYTES) -> dict[str, Any]:
    before = _validated_file_stat(path, private=private, maximum=maximum)
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ShareError("SOCIAL_SHARE_UNSAFE_FILE", "sharing input changed during validation", 3) from error
    try:
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            after = os.fstat(handle.fileno())
            if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
                raise ShareError("SOCIAL_SHARE_UNSAFE_FILE", "sharing input changed during validation", 3)
            payload = handle.read(maximum + 1)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if len(payload) > maximum:
        raise ShareError("SOCIAL_SHARE_TOO_LARGE", "sharing input exceeds the size limit", 3)
    try:
        value = json.loads(payload.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeError) as error:
        raise ShareError("SOCIAL_SHARE_INVALID", "sharing input is not valid UTF-8 JSON", 3) from error
    if not isinstance(value, dict):
        raise ShareError("SOCIAL_SHARE_INVALID", "sharing input must be a JSON object", 3)
    return value


def _safe_output_parent(path: Path, *, private: bool) -> Path:
    parent = path.parent if path.parent != Path("") else Path(".")
    absolute = Path(os.path.abspath(parent))
    try:
        resolved = parent.resolve(strict=True)
        parent_stat = parent.lstat()
    except OSError as error:
        raise ShareError("SOCIAL_SHARE_UNSAFE_FILE", "sharing output directory is unavailable", 3) from error
    if resolved != absolute or not stat.S_ISDIR(parent_stat.st_mode):
        raise ShareError("SOCIAL_SHARE_UNSAFE_FILE", "sharing output directory cannot contain symlinks", 3)
    if parent_stat.st_uid != os.getuid():
        raise ShareError("SOCIAL_SHARE_UNSAFE_FILE", "sharing output directory owner is invalid", 3)
    mode = stat.S_IMODE(parent_stat.st_mode)
    if mode & 0o022:
        raise ShareError(
            "SOCIAL_SHARE_UNSAFE_FILE",
            "sharing output directory must not be writable by other users",
            3,
        )
    if private and mode & 0o077:
        raise ShareError("SOCIAL_SHARE_UNSAFE_FILE", "private sharing output directory must be owner-only", 3)
    return resolved


def write_json_atomic(path: Path, value: dict[str, Any], *, private: bool) -> None:
    path = path.expanduser()
    parent = _safe_output_parent(path, private=private)
    path = parent / path.name
    if os.path.lexists(path):
        raise ShareError("SOCIAL_SHARE_CONFLICT", "refusing to replace an existing sharing output", 4)
    payload = json.dumps(value, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(8)}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, 0o600 if private else 0o644)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary, path, follow_symlinks=False)
        except FileExistsError as error:
            raise ShareError(
                "SOCIAL_SHARE_CONFLICT", "refusing to replace an existing sharing output", 4
            ) from error
        except OSError as error:
            raise ShareError(
                "SOCIAL_SHARE_UNSAFE_FILE", "sharing output could not be created safely", 3
            ) from error
        temporary.unlink()
        directory_flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            directory_flags |= os.O_DIRECTORY
        directory_fd = os.open(parent, directory_flags)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _device_id(signing_public: bytes, encryption_public: bytes) -> str:
    return hashlib.sha256(signing_public + encryption_public).hexdigest()


def _public_identity(payload: dict[str, Any]) -> PublicIdentity:
    expected = {
        "schema_version",
        "kind",
        "principal_id",
        "device_id",
        "signing_public_key",
        "encryption_public_key",
    }
    if set(payload) != expected:
        raise ShareError("SOCIAL_SHARE_IDENTITY_INVALID", "sharing identity fields are invalid", 3)
    if payload.get("schema_version") != SCHEMA_VERSION or payload.get("kind") != IDENTITY_KIND:
        raise ShareError("SOCIAL_SHARE_IDENTITY_INVALID", "unsupported sharing identity", 3)
    principal_id = validate_opaque(payload.get("principal_id"), "principal_id")
    signing_public = b64d(str(payload.get("signing_public_key", "")), "signing public key", KEY_BYTES)
    encryption_public = b64d(
        str(payload.get("encryption_public_key", "")), "encryption public key", KEY_BYTES
    )
    try:
        X25519PrivateKey.generate().exchange(
            X25519PublicKey.from_public_bytes(encryption_public)
        )
    except ValueError as error:
        raise ShareError(
            "SOCIAL_SHARE_IDENTITY_INVALID",
            "sharing encryption public key is unsafe",
            3,
        ) from error
    device_id = str(payload.get("device_id", ""))
    if not HEX_64.fullmatch(device_id) or device_id != _device_id(signing_public, encryption_public):
        raise ShareError("SOCIAL_SHARE_IDENTITY_INVALID", "sharing device identity does not match its keys", 3)
    return PublicIdentity(principal_id, device_id, signing_public, encryption_public)


def _sign(value: dict[str, Any], private_key: Ed25519PrivateKey) -> str:
    return b64e(private_key.sign(canonical_json(value)))


def _verify(value: dict[str, Any], signature: Any, public_key: bytes) -> None:
    if not isinstance(signature, str):
        raise ShareError("SOCIAL_SHARE_SIGNATURE_INVALID", "sharing signature is missing", 4)
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(
            b64d(signature, "signature", 64), canonical_json(value)
        )
    except InvalidSignature as error:
        raise ShareError("SOCIAL_SHARE_SIGNATURE_INVALID", "sharing signature is invalid", 4) from error


def load_private_identity(vault_dir: Path, principal_id: str) -> PrivateIdentity:
    principal_id = validate_opaque(principal_id, "principal_id")
    try:
        absolute = Path(os.path.abspath(vault_dir))
        resolved_vault = vault_dir.resolve(strict=True)
        vault_stat = vault_dir.lstat()
    except OSError as error:
        raise ShareError("SOCIAL_SHARE_MISSING", "Vault message identity directory is missing", 2) from error
    if (
        resolved_vault != absolute
        or stat.S_ISLNK(vault_stat.st_mode)
        or not stat.S_ISDIR(vault_stat.st_mode)
    ):
        raise ShareError("SOCIAL_SHARE_UNSAFE_FILE", "Vault message identity directory is unsafe", 3)
    if vault_stat.st_uid != os.getuid() or stat.S_IMODE(vault_stat.st_mode) & 0o077:
        raise ShareError("SOCIAL_SHARE_UNSAFE_FILE", "Vault message identity directory must be owner-only", 3)
    key = read_json(resolved_vault / KEY_FILE, private=True, maximum=64 * 1024)
    if key.get("schema_version") != 1:
        raise ShareError("SOCIAL_SHARE_IDENTITY_INVALID", "unsupported Vault message identity", 3)
    signing_private_bytes = b64d(str(key.get("signing_private_key", "")), "signing private key", KEY_BYTES)
    encryption_private_bytes = b64d(
        str(key.get("encryption_private_key", "")), "encryption private key", KEY_BYTES
    )
    signing_private = Ed25519PrivateKey.from_private_bytes(signing_private_bytes)
    encryption_private = X25519PrivateKey.from_private_bytes(encryption_private_bytes)
    signing_public = signing_private.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    encryption_public = encryption_private.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    if str(key.get("signing_public_key", "")) != b64e(signing_public) or str(
        key.get("encryption_public_key", "")
    ) != b64e(encryption_public):
        raise ShareError("SOCIAL_SHARE_IDENTITY_INVALID", "Vault message identity key mismatch", 3)
    device_id = str(key.get("device_id", ""))
    if device_id != _device_id(signing_public, encryption_public):
        raise ShareError("SOCIAL_SHARE_IDENTITY_INVALID", "Vault message device id mismatch", 3)
    public = PublicIdentity(principal_id, device_id, signing_public, encryption_public)
    return PrivateIdentity(public, signing_private, encryption_private)


def identity_envelope(identity: PrivateIdentity) -> dict[str, Any]:
    descriptor = identity.public.descriptor()
    return {"identity": descriptor, "signature": _sign(descriptor, identity.signing_private_key)}


def load_identity(path: Path) -> PublicIdentity:
    envelope = read_json(path, maximum=64 * 1024)
    if set(envelope) != {"identity", "signature"}:
        raise ShareError("SOCIAL_SHARE_IDENTITY_INVALID", "sharing identity envelope fields are invalid", 3)
    descriptor = envelope.get("identity")
    if not isinstance(descriptor, dict):
        raise ShareError("SOCIAL_SHARE_IDENTITY_INVALID", "sharing identity descriptor is missing", 3)
    identity = _public_identity(descriptor)
    _verify(descriptor, envelope.get("signature"), identity.signing_public_key)
    return identity
