"""Private immutable evidence persistence for the performance store."""

from __future__ import annotations

import hashlib
import os
import secrets
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from _performance_store_types import EvidenceWriteContext


@dataclass(frozen=True)
class RawPublication:
    """Pinned state for one no-replacement evidence publication."""

    store: Any
    directory: Path
    directory_fd: int
    destination_name: str
    digest: str
    raw_bytes: bytes


def ensure_private_directory(store: Any, path: Path) -> None:
    """Preserve the facade helper while rejecting symlinked directories."""
    if path.is_symlink():
        raise store.error_type("raw evidence directory is unsafe")
    path.mkdir(parents=False, exist_ok=True, mode=0o700)
    if path.is_symlink() or not path.is_dir():
        raise store.error_type("raw evidence directory is unsafe")
    os.chmod(path, 0o700)


def regular_file_digest(store: Any, path: Path) -> str:
    """Preserve the facade helper for one no-follow regular file."""
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
        raise store.error_type(
            "raw evidence destination is not a readable regular file"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _directory_flags() -> int:
    """Return flags for pinned no-follow directory traversal."""
    return os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_DIRECTORY | os.O_NOFOLLOW


def _relative_parts(store: Any, path: Path) -> tuple[str, ...]:
    """Return safe repository-relative path components."""
    try:
        relative = Path(os.path.abspath(path)).relative_to(Path(os.path.abspath(store.paths.repo)))
    except ValueError as error:
        raise store.error_type("raw evidence path escapes its repository") from error
    if any(component in {"", ".", ".."} for component in relative.parts):
        raise store.error_type("raw evidence path contains an unsafe component")
    return relative.parts


def _open_directory(store: Any, path: Path) -> int:
    """Open an existing repository directory through pinned components."""
    descriptor = -1
    try:
        descriptor = os.open(store.paths.repo, _directory_flags())
        for component in _relative_parts(store, path):
            child = os.open(component, _directory_flags(), dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except store.error_type:
        if descriptor >= 0:
            os.close(descriptor)
        raise
    except OSError as error:
        if descriptor >= 0:
            os.close(descriptor)
        raise store.error_type("raw evidence directory is unsafe") from error


def _private_child(store: Any, parent_fd: int, name: str) -> int:
    """Create and pin one owner-only child directory."""
    if Path(name).name != name or name in {"", ".", ".."}:
        raise store.error_type("raw evidence directory name is unsafe")
    descriptor = -1
    try:
        try:
            os.mkdir(name, 0o700, dir_fd=parent_fd)
            os.fsync(parent_fd)
        except FileExistsError:
            pass
        descriptor = os.open(name, _directory_flags(), dir_fd=parent_fd)
        os.fchmod(descriptor, 0o700)
        return descriptor
    except OSError as error:
        if descriptor >= 0:
            os.close(descriptor)
        raise store.error_type("raw evidence directory is unsafe") from error


def _regular_file_digest(store: Any, directory_fd: int, name: str) -> str | None:
    """Hash one descriptor-relative regular file without following symlinks."""
    descriptor = -1
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW,
            dir_fd=directory_fd,
        )
    except FileNotFoundError:
        return None
    except OSError as error:
        raise store.error_type("raw evidence destination is not a readable regular file") from error
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise store.error_type("raw evidence destination is not a regular file")
        digest = hashlib.sha256()
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _descriptor_matches_entry(descriptor: int, directory_fd: int, name: str) -> bool:
    """Return whether a pinned regular descriptor owns one directory entry."""
    try:
        descriptor_stat = os.fstat(descriptor)
        entry_stat = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except OSError:
        return False
    return (
        stat.S_ISREG(descriptor_stat.st_mode)
        and stat.S_ISREG(entry_stat.st_mode)
        and (descriptor_stat.st_dev, descriptor_stat.st_ino) == (entry_stat.st_dev, entry_stat.st_ino)
    )


def _directory_binding_matches(store: Any, path: Path, descriptor: int) -> bool:
    """Return whether the repository path still identifies a pinned directory."""
    try:
        current = _open_directory(store, path)
    except store.error_type:
        return False
    try:
        expected = os.fstat(descriptor)
        observed = os.fstat(current)
        return (expected.st_dev, expected.st_ino) == (observed.st_dev, observed.st_ino)
    finally:
        os.close(current)


def _unlink(directory_fd: int, name: str) -> None:
    """Remove one descriptor-relative temporary entry if present."""
    try:
        os.unlink(name, dir_fd=directory_fd)
        os.fsync(directory_fd)
    except FileNotFoundError:
        pass


def _publish_raw_artifact(publication: RawPublication) -> bool:
    """Write, link, and verify one artifact through a pinned directory."""
    temporary_name = f".{publication.digest}.{os.getpid()}.{secrets.token_hex(4)}.tmp"
    temporary_fd = -1
    created = False
    try:
        temporary_fd = os.open(
            temporary_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW,
            0o600,
            dir_fd=publication.directory_fd,
        )
        with os.fdopen(os.dup(temporary_fd), "wb") as handle:
            handle.write(publication.raw_bytes)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(
                temporary_name,
                publication.destination_name,
                src_dir_fd=publication.directory_fd,
                dst_dir_fd=publication.directory_fd,
                follow_symlinks=False,
            )
            os.fsync(publication.directory_fd)
            created = True
        except FileExistsError:
            created = False
        destination_matches = _descriptor_matches_entry(
            temporary_fd,
            publication.directory_fd,
            publication.destination_name,
        )
        if created and not destination_matches:
            raise publication.store.error_type("raw evidence changed during publication")
        observed_digest = _regular_file_digest(
            publication.store,
            publication.directory_fd,
            publication.destination_name,
        )
        if observed_digest != publication.digest:
            if created and destination_matches:
                _unlink(publication.directory_fd, publication.destination_name)
            raise publication.store.error_type("raw evidence failed digest verification")
        if not _directory_binding_matches(
            publication.store,
            publication.directory,
            publication.directory_fd,
        ):
            if created and destination_matches:
                _unlink(publication.directory_fd, publication.destination_name)
            raise publication.store.error_type("raw evidence directory changed during publication")
        return created
    finally:
        if temporary_fd >= 0:
            os.close(temporary_fd)
        _unlink(publication.directory_fd, temporary_name)


def write_raw(store: Any, context: EvidenceWriteContext) -> tuple[Path, bool]:
    """Publish one content-addressed evidence artifact without replacement."""
    source = context.source
    account_ref = context.account_ref
    digest = context.digest
    suffix = context.suffix
    raw_bytes = context.raw_bytes
    source_directory = store.paths.raw / source
    directory = source_directory / account_ref
    destination_name = f"{digest}{suffix}"
    if Path(destination_name).name != destination_name:
        raise store.error_type("raw evidence destination name is unsafe")
    raw_fd = _open_directory(store, store.paths.raw)
    source_fd = -1
    directory_fd = -1
    try:
        source_fd = _private_child(store, raw_fd, source)
        directory_fd = _private_child(store, source_fd, account_ref)
        existing_digest = _regular_file_digest(store, directory_fd, destination_name)
        if existing_digest is not None:
            if existing_digest != digest:
                raise store.error_type("raw evidence digest collision")
            if not _directory_binding_matches(store, directory, directory_fd):
                raise store.error_type("raw evidence directory changed during publication")
            return directory / destination_name, False
        publication = RawPublication(
            store,
            directory,
            directory_fd,
            destination_name,
            digest,
            raw_bytes,
        )
        created = _publish_raw_artifact(publication)
        return directory / destination_name, created
    except OSError as error:
        raise store.error_type("raw evidence publication failed") from error
    finally:
        if directory_fd >= 0:
            os.close(directory_fd)
        if source_fd >= 0:
            os.close(source_fd)
        os.close(raw_fd)
