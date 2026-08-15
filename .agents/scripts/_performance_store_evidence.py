"""Private immutable evidence persistence for the performance store."""

from __future__ import annotations

import hashlib
import os
import secrets
import stat
from pathlib import Path
from typing import Any

from _performance_store_types import EvidenceWriteContext


def ensure_private_directory(store: Any, path: Path) -> None:
    """Create one private directory without accepting a symlink."""
    if path.is_symlink():
        raise store.error_type("raw evidence directory is unsafe")
    path.mkdir(parents=False, exist_ok=True, mode=0o700)
    if path.is_symlink() or not path.is_dir():
        raise store.error_type("raw evidence directory is unsafe")
    os.chmod(path, 0o700)


def regular_file_digest(store: Any, path: Path) -> str:
    """Hash one regular file through a no-follow descriptor."""
    descriptor = -1
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise store.error_type("raw evidence destination is not a regular file")
        digest = hashlib.sha256()
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError as error:
        raise store.error_type("raw evidence destination is not a readable regular file") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def write_raw(store: Any, context: EvidenceWriteContext) -> tuple[Path, bool]:
    """Publish one content-addressed evidence artifact without replacement."""
    source = context.source
    account_ref = context.account_ref
    digest = context.digest
    suffix = context.suffix
    raw_bytes = context.raw_bytes
    source_directory = store.paths.raw / source
    directory = source_directory / account_ref
    for private_directory in (store.paths.raw, source_directory, directory):
        ensure_private_directory(store, private_directory)
    destination = directory / f"{digest}{suffix}"
    if destination.is_symlink() or (destination.exists() and not destination.is_file()):
        raise store.error_type("raw evidence destination is not a regular file")
    if destination.exists():
        if regular_file_digest(store, destination) != digest:
            raise store.error_type("raw evidence digest collision")
        return destination, False
    temporary = directory / f".{digest}.{os.getpid()}.{secrets.token_hex(4)}.tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(raw_bytes)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary, destination)
            created = True
        except FileExistsError:
            created = False
        temporary.unlink()
        if regular_file_digest(store, destination) != digest:
            raise store.error_type("raw evidence failed digest verification")
        return destination, created
    finally:
        if temporary.exists():
            temporary.unlink()
