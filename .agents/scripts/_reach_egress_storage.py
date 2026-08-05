#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Durable descriptor-relative persistence for private Reach egress profiles."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import stat
from pathlib import Path
from typing import Any


class EgressStorageError(ValueError):
    """Raised when the private egress storage boundary is unsafe."""


def _directory_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )


def _open_private_directory(path: Path) -> int:
    descriptor = -1
    try:
        descriptor = os.open(path, _directory_flags())
        directory_stat = os.fstat(descriptor)
        if not stat.S_ISDIR(directory_stat.st_mode):
            raise EgressStorageError("egress storage is not a directory")
        if hasattr(os, "getuid") and directory_stat.st_uid != os.getuid():
            raise EgressStorageError("egress storage owner is invalid")
        if stat.S_IMODE(directory_stat.st_mode) & 0o077:
            raise EgressStorageError("egress storage permissions are invalid")
        return descriptor
    except EgressStorageError:
        if descriptor >= 0:
            os.close(descriptor)
        raise
    except OSError as error:
        if descriptor >= 0:
            os.close(descriptor)
        raise EgressStorageError("egress storage is unavailable") from error


def _create_temporary(directory_fd: int) -> tuple[int, str]:
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    for _ in range(16):
        name = f".egress-profile-{secrets.token_hex(12)}"
        try:
            return os.open(name, flags, 0o600, dir_fd=directory_fd), name
        except FileExistsError:
            continue
    raise EgressStorageError("egress temporary file allocation failed")


def _unlink_temporary(directory_fd: int, name: str) -> None:
    try:
        os.unlink(name, dir_fd=directory_fd)
        os.fsync(directory_fd)
    except FileNotFoundError:
        pass


def write_profile(path: Path, data: dict[str, Any], force: bool) -> int:
    """Atomically publish one mode-0600 profile and return its status code."""
    directory = _open_private_directory(path.parent)
    descriptor, temporary = _create_temporary(directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), 0o600)
            json.dump(data, handle, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        if force:
            os.replace(
                temporary,
                path.name,
                src_dir_fd=directory,
                dst_dir_fd=directory,
            )
            temporary = ""
        else:
            try:
                os.link(
                    temporary,
                    path.name,
                    src_dir_fd=directory,
                    dst_dir_fd=directory,
                    follow_symlinks=False,
                )
            except FileExistsError:
                return 2
        os.fsync(directory)
        return 0
    except OSError as error:
        raise EgressStorageError("egress profile persistence failed") from error
    finally:
        if temporary:
            _unlink_temporary(directory, temporary)
        os.close(directory)


def clear_profile(path: Path) -> int:
    """Durably remove one regular profile without following links."""
    try:
        directory = _open_private_directory(path.parent)
    except EgressStorageError as error:
        if isinstance(error.__cause__, FileNotFoundError):
            return 3
        raise
    try:
        try:
            file_stat = os.stat(path.name, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            return 3
        if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISREG(file_stat.st_mode):
            return 2
        os.unlink(path.name, dir_fd=directory)
        os.fsync(directory)
        return 0
    except OSError as error:
        raise EgressStorageError("egress profile cleanup failed") from error
    finally:
        os.close(directory)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    write = commands.add_parser("write")
    for field in (
        "path",
        "profile_name",
        "browser_class",
        "egress_class",
        "usage_scope",
        "session_mode",
        "country",
        "region",
        "city",
        "timezone",
        "locale",
        "credential_ref",
        "created_at",
        "notes",
        "force",
    ):
        write.add_argument(field)
    clear = commands.add_parser("clear")
    clear.add_argument("path")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "clear":
            return clear_profile(Path(args.path))
        data = {
            "schema_version": 1,
            "profile_name": args.profile_name,
            "browser_class": args.browser_class,
            "egress_class": args.egress_class,
            "usage_scope": args.usage_scope,
            "session_mode": args.session_mode,
            "country": args.country,
            "region": args.region,
            "city": args.city,
            "timezone": args.timezone,
            "locale": args.locale,
            "credential_ref": args.credential_ref,
            "created_at": args.created_at,
            "sensitivity": "private",
            "notes": args.notes,
        }
        return write_profile(Path(args.path), data, args.force == "true")
    except EgressStorageError:
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
