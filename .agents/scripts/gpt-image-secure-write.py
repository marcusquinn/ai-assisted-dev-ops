#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Publish a generated PNG through descriptor-relative filesystem operations."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import PurePosixPath
import secrets
import stat
import sys
import zlib

MAX_OUTPUT_BYTES = 64 * 1024 * 1024
MAX_OUTPUT_VERSION = 999
MAX_PIXELS = 8_294_400
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


class SecureWriteError(Exception):
    """Represent a safe user-facing image publication failure."""


def directory_flags() -> int:
    """Return fail-closed flags for pinned directory traversal."""
    if not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW"):
        raise SecureWriteError("secure descriptor-relative image writes are unsupported on this platform")
    return os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_DIRECTORY | os.O_NOFOLLOW


def parse_output_path(value: str) -> tuple[tuple[str, ...], str]:
    """Validate and split one portable project-relative PNG path."""
    portable = value.replace("\\", "/")
    path = PurePosixPath(portable)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise SecureWriteError("image output must be a safe project-relative path")
    if not path.parts or path.suffix.lower() != ".png":
        raise SecureWriteError("image output must end in .png")
    if any(part.casefold() == ".git" for part in path.parts):
        raise SecureWriteError("image output cannot be written inside .git")
    return path.parts[:-1], path.parts[-1]


def read_png() -> bytes:
    """Read and structurally validate one bounded PNG from stdin."""
    payload = sys.stdin.buffer.read(MAX_OUTPUT_BYTES + 1)
    if len(payload) > MAX_OUTPUT_BYTES:
        raise SecureWriteError("generated PNG exceeds the 64 MiB limit")
    validate_png(payload)
    return payload


def validate_png(payload: bytes) -> None:
    """Validate PNG chunks, CRCs, dimensions, and terminal structure."""
    if not payload.startswith(PNG_MAGIC):
        raise SecureWriteError("image provider returned an invalid PNG")
    offset = len(PNG_MAGIC)
    chunk_index = 0
    color_type = -1
    data_state = "before"
    seen_chunks: set[bytes] = set()
    while offset + 12 <= len(payload):
        length = int.from_bytes(payload[offset : offset + 4], "big")
        end = offset + 12 + length
        if end > len(payload):
            raise SecureWriteError("image provider returned a truncated PNG")
        chunk_type = payload[offset + 4 : offset + 8]
        chunk_data = payload[offset + 8 : offset + 8 + length]
        expected_crc = int.from_bytes(payload[offset + 8 + length : end], "big")
        if zlib.crc32(chunk_type + chunk_data) & 0xFFFFFFFF != expected_crc:
            raise SecureWriteError("image provider returned a PNG with an invalid checksum")
        if chunk_index == 0:
            color_type = validate_ihdr(chunk_type, chunk_data)
        validate_chunk_order(chunk_type, data_state, seen_chunks, color_type)
        if chunk_type == b"IDAT":
            data_state = "data"
        elif data_state == "data":
            data_state = "after"
        if chunk_type == b"IEND":
            if length != 0 or end != len(payload) or b"IDAT" not in seen_chunks:
                raise SecureWriteError("image provider returned an invalid terminal PNG chunk")
            return
        seen_chunks.add(chunk_type)
        offset = end
        chunk_index += 1
    raise SecureWriteError("image provider returned a PNG without a terminal chunk")


def validate_ihdr(chunk_type: bytes, data: bytes) -> int:
    """Validate the required first PNG header chunk."""
    if chunk_type != b"IHDR" or len(data) != 13:
        raise SecureWriteError("image provider returned an invalid PNG header")
    width = int.from_bytes(data[0:4], "big")
    height = int.from_bytes(data[4:8], "big")
    bit_depth, color_type, compression, filtering, interlace = data[8:13]
    valid_depths = {0: {1, 2, 4, 8, 16}, 2: {8, 16}, 3: {1, 2, 4, 8}, 4: {8, 16}, 6: {8, 16}}
    if width < 1 or height < 1 or width * height > MAX_PIXELS:
        raise SecureWriteError("generated PNG dimensions exceed the safe limit")
    if bit_depth not in valid_depths.get(color_type, set()) or compression != 0 or filtering != 0 or interlace not in {0, 1}:
        raise SecureWriteError("image provider returned unsupported PNG parameters")
    return color_type


def validate_chunk_order(
    chunk_type: bytes,
    data_state: str,
    seen_chunks: set[bytes],
    color_type: int,
) -> None:
    """Reject duplicate, misplaced, and unknown critical PNG chunks."""
    critical_chunks = {b"IHDR", b"PLTE", b"IDAT", b"IEND"}
    if chunk_type[0] & 0x20 == 0 and chunk_type not in critical_chunks:
        raise SecureWriteError("image provider returned an unknown critical PNG chunk")
    if chunk_type == b"IHDR" and chunk_type in seen_chunks:
        raise SecureWriteError("image provider returned a duplicate PNG header")
    if chunk_type == b"PLTE":
        if chunk_type in seen_chunks or data_state != "before" or color_type in {0, 4}:
            raise SecureWriteError("image provider returned an invalid PNG palette")
    if chunk_type == b"IDAT":
        if data_state == "after" or (color_type == 3 and b"PLTE" not in seen_chunks):
            raise SecureWriteError("image provider returned invalid PNG image-data ordering")
    if chunk_type == b"IEND" and data_state != "data":
        raise SecureWriteError("image provider returned a PNG without contiguous image data")


def open_output_directory(root_fd: int, parts: tuple[str, ...]) -> int:
    """Create and pin output directories beneath the project descriptor."""
    descriptor = os.dup(root_fd)
    try:
        for part in parts:
            try:
                os.mkdir(part, 0o700, dir_fd=descriptor)
                os.fsync(descriptor)
            except FileExistsError:
                pass
            child = os.open(part, directory_flags(), dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except OSError as error:
        os.close(descriptor)
        raise SecureWriteError("image output directory is unsafe") from error


def open_existing_directory(root_fd: int, parts: tuple[str, ...]) -> int:
    """Pin an existing output directory without creating path components."""
    descriptor = os.dup(root_fd)
    try:
        for part in parts:
            child = os.open(part, directory_flags(), dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except OSError as error:
        os.close(descriptor)
        raise SecureWriteError("image output directory binding is unsafe") from error


def directory_binding_matches(root_fd: int, parts: tuple[str, ...], expected_fd: int) -> bool:
    """Confirm the project path still names the pinned output directory."""
    current = -1
    try:
        current = open_existing_directory(root_fd, parts)
        expected = os.fstat(expected_fd)
        observed = os.fstat(current)
        return (expected.st_dev, expected.st_ino) == (observed.st_dev, observed.st_ino)
    except (OSError, SecureWriteError):
        return False
    finally:
        if current >= 0:
            os.close(current)


def versioned_name(requested: str, version: int) -> str:
    """Return the requested name or a bounded non-overwriting variant."""
    if version == 1:
        return requested
    stem, extension = os.path.splitext(requested)
    return f"{stem}-v{version}{extension}"


def entry_matches(directory_fd: int, name: str, descriptor: int) -> bool:
    """Return whether a pinned descriptor still owns one regular entry."""
    try:
        linked = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        opened = os.fstat(descriptor)
        return stat.S_ISREG(linked.st_mode) and (linked.st_dev, linked.st_ino) == (
            opened.st_dev,
            opened.st_ino,
        )
    except OSError:
        return False


def cleanup_temporary(directory_fd: int, temporary: str, temp_fd: int) -> bool:
    """Clean temporary state and report whether durability cleanup failed."""
    failed = False
    try:
        os.close(temp_fd)
    except OSError:
        failed = True
    try:
        os.unlink(temporary, dir_fd=directory_fd)
        os.fsync(directory_fd)
    except FileNotFoundError:
        pass
    except OSError:
        failed = True
    return failed


def publish_png(directory_fd: int, requested: str, payload: bytes) -> tuple[str, bool, bool]:
    """Write and hard-link a private PNG without replacing existing output."""
    temporary = f".{requested}.aidevops-{secrets.token_hex(12)}.tmp"
    temp_fd = -1
    published = ""
    try:
        temp_fd = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW,
            0o600,
            dir_fd=directory_fd,
        )
        with os.fdopen(os.dup(temp_fd), "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        for version in range(1, MAX_OUTPUT_VERSION + 1):
            candidate = versioned_name(requested, version)
            try:
                os.link(
                    temporary,
                    candidate,
                    src_dir_fd=directory_fd,
                    dst_dir_fd=directory_fd,
                    follow_symlinks=False,
                )
                published = candidate
                os.fsync(directory_fd)
                if not entry_matches(directory_fd, candidate, temp_fd):
                    raise SecureWriteError("generated image changed during secure publication")
                cleanup_warning = cleanup_temporary(directory_fd, temporary, temp_fd)
                temp_fd = -1
                return candidate, version > 1, cleanup_warning
            except FileExistsError:
                continue
        raise SecureWriteError(f"no available image filename after {MAX_OUTPUT_VERSION} versions")
    except BaseException:
        if published and entry_matches(directory_fd, published, temp_fd):
            try:
                os.unlink(published, dir_fd=directory_fd)
                os.fsync(directory_fd)
            except OSError:
                pass
        raise
    finally:
        if temp_fd >= 0:
            cleanup_temporary(directory_fd, temporary, temp_fd)


def main() -> int:
    """Securely publish stdin and emit bounded project-relative JSON."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    directories, requested = parse_output_path(args.out)
    payload = read_png()
    root_fd = os.open(args.root, directory_flags())
    directory_fd = -1
    candidate = ""
    try:
        if not stat.S_ISDIR(os.fstat(root_fd).st_mode):
            raise SecureWriteError("OpenCode project root must be a regular directory")
        directory_fd = open_output_directory(root_fd, directories)
        candidate, versioned, cleanup_warning = publish_png(directory_fd, requested, payload)
        if not directory_binding_matches(root_fd, directories, directory_fd):
            os.unlink(candidate, dir_fd=directory_fd)
            os.fsync(directory_fd)
            raise SecureWriteError("image output directory changed during secure publication")
        project_path = "/".join((*directories, candidate))
        receipt = {"path": project_path, "versioned": versioned, "cleanup_warning": cleanup_warning}
        print(json.dumps(receipt, separators=(",", ":")))
        return 0
    finally:
        if directory_fd >= 0:
            os.close(directory_fd)
        os.close(root_fd)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SecureWriteError as error:
        print(f"Secure image write failed: {error}", file=sys.stderr)
        raise SystemExit(1) from None
    except OSError:
        print("Secure image write failed: a filesystem operation failed", file=sys.stderr)
        raise SystemExit(1) from None
