#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Publish a generated raster image through descriptor-relative operations."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import PurePosixPath
from runpy import run_path
import secrets
import stat
import sys

MAX_OUTPUT_BYTES = 64 * 1024 * 1024
MAX_OUTPUT_VERSION = 999
VALIDATOR_MODULES = {
    "png": ("gpt_image_png.py", "validate_png", "PngValidationError"),
    "jpeg": ("gpt_image_jpeg.py", "validate_jpeg", "JpegValidationError"),
    "webp": ("gpt_image_webp.py", "validate_webp", "WebpValidationError"),
}


class SecureWriteError(Exception):
    """Represent a safe user-facing image publication failure."""


def load_image_validator(image_format: str):
    """Load one adjacent format validator without ambient Python imports."""
    try:
        filename, function_name, error_name = VALIDATOR_MODULES[image_format]
        validator_path = os.path.join(os.path.dirname(os.path.realpath(__file__)), filename)
        module = run_path(validator_path)
        return module[function_name], module[error_name]
    except (OSError, KeyError) as error:
        raise SecureWriteError("secure image validation is unavailable") from error


def directory_flags() -> int:
    """Return fail-closed flags for pinned directory traversal."""
    if not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW"):
        raise SecureWriteError("secure descriptor-relative image writes are unsupported on this platform")
    return os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_DIRECTORY | os.O_NOFOLLOW


def parse_output_path(value: str) -> tuple[tuple[str, ...], str, str]:
    """Validate and split one portable project-relative raster image path."""
    portable = value.replace("\\", "/")
    path = PurePosixPath(portable)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise SecureWriteError("image output must be a safe project-relative path")
    formats = {".png": "png", ".jpg": "jpeg", ".jpeg": "jpeg", ".webp": "webp"}
    try:
        image_format = formats[path.suffix.lower()]
    except KeyError as error:
        raise SecureWriteError("image output must end in .png, .jpg, .jpeg, or .webp") from error
    if any(part.casefold() == ".git" for part in path.parts):
        raise SecureWriteError("image output cannot be written inside .git")
    return path.parts[:-1], path.parts[-1], image_format


def read_image(image_format: str) -> bytes:
    """Read and structurally validate one bounded raster image from stdin."""
    payload = sys.stdin.buffer.read(MAX_OUTPUT_BYTES + 1)
    if len(payload) > MAX_OUTPUT_BYTES:
        raise SecureWriteError("generated image exceeds the 64 MiB limit")
    validate_image, image_validation_error = load_image_validator(image_format)
    try:
        validate_image(payload)
    except image_validation_error as error:
        raise SecureWriteError(str(error)) from error
    return payload


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


def publish_image(directory_fd: int, requested: str, payload: bytes) -> tuple[str, bool, bool]:
    """Write and hard-link a private image without replacing existing output."""
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
    directories, requested, image_format = parse_output_path(args.out)
    payload = read_image(image_format)
    root_fd = os.open(args.root, directory_flags())
    directory_fd = -1
    candidate = ""
    try:
        if not stat.S_ISDIR(os.fstat(root_fd).st_mode):
            raise SecureWriteError("OpenCode project root must be a regular directory")
        directory_fd = open_output_directory(root_fd, directories)
        candidate, versioned, cleanup_warning = publish_image(directory_fd, requested, payload)
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
