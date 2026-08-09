"""Filesystem primitives for content-addressed Buzz runtime anchors."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile


IGNORED_RUNTIME_NAMES = {".DS_Store", "__pycache__"}
RUNTIME_MARKER_KEYS = {
    "agents_digest",
    "config_digest",
    "content_digest",
    "runtime_id",
    "schema_version",
}


class RuntimeError(ValueError):
    """Raised when the Buzz runtime cannot be prepared safely."""


def require_safe_directory_chain(path):
    """Reject non-directory or symlinked runtime path components."""
    candidate = Path(os.path.abspath(path))
    current = Path(candidate.anchor)
    for part in candidate.parts[1:]:
        current /= part
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise RuntimeError("Buzz runtime anchor directory chain is unsafe")
    return candidate


def valid_runtime_marker(value, runtime_id, schema_version):
    """Return whether runtime marker metadata matches the closed schema."""
    if not isinstance(value, dict) or set(value) != RUNTIME_MARKER_KEYS:
        return False
    if value.get("runtime_id") != runtime_id or value.get("schema_version") != schema_version:
        return False
    for key in ("agents_digest", "config_digest", "content_digest"):
        digest = value.get(key)
        if not isinstance(digest, str) or len(digest) != 64:
            return False
        if any(character not in "0123456789abcdef" for character in digest):
            return False
    return True


def canonical_payload(value):
    """Return stable pretty-printed UTF-8 JSON bytes."""
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def atomic_write(path, payload):
    """Atomically replace one current-user-only regular file."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        owned_descriptor = descriptor
        descriptor = -1
        with os.fdopen(owned_descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary_path.unlink(missing_ok=True)


def hash_file_into(digest, path):
    """Add one regular file to a deterministic runtime digest."""
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)


def hash_runtime_tree(root):
    """Hash one trusted runtime tree without transient Python artifacts."""
    digest = hashlib.sha256()
    canonical_root = root.resolve(strict=True)
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root)
        if any(part in IGNORED_RUNTIME_NAMES for part in relative.parts) or path.suffix == ".pyc":
            continue
        metadata = path.lstat()
        digest.update(relative.as_posix().encode("utf-8"))
        digest.update(b"\0")
        if stat.S_ISLNK(metadata.st_mode):
            target = os.readlink(path)
            if os.path.isabs(target):
                raise RuntimeError("runtime source contains an absolute symbolic link")
            resolved = (path.parent / target).resolve(strict=True)
            if canonical_root not in (resolved, *resolved.parents):
                raise RuntimeError("runtime source symbolic link escapes its tree")
            digest.update(b"L\0")
            digest.update(target.encode("utf-8"))
        elif stat.S_ISREG(metadata.st_mode):
            digest.update(b"F\0")
            digest.update(str(stat.S_IMODE(metadata.st_mode) & 0o111).encode("ascii"))
            digest.update(b"\0")
            hash_file_into(digest, path)
        elif stat.S_ISDIR(metadata.st_mode):
            digest.update(b"D\0")
        else:
            raise RuntimeError("runtime source contains an unsupported filesystem entry")
        digest.update(b"\0")
    return digest.hexdigest()


def command_payloads(source):
    """Read one complete regular, non-symlink OpenCode command tree."""
    command_source = source / "command"
    if not command_source.exists():
        return {}
    if command_source.is_symlink() or not command_source.is_dir():
        raise RuntimeError("pinned OpenCode command root must be a non-symlink directory")
    payloads = {}
    for command_path in sorted(command_source.rglob("*")):
        metadata = command_path.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise RuntimeError("pinned OpenCode command files must be regular non-symlink files")
        try:
            payloads[command_path.relative_to(command_source)] = command_path.read_text(
                encoding="utf-8"
            )
        except UnicodeDecodeError as error:
            raise RuntimeError("pinned OpenCode command files must be UTF-8 text") from error
    return payloads
