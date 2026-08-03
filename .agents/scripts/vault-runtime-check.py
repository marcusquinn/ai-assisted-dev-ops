#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Verify the exact aidevops Vault runtime and required crypto primitives."""

from __future__ import annotations

import importlib.metadata
import os
import stat
import sys
from pathlib import Path
from typing import Optional

EXPECTED = {
    "cryptography": "50.0.0",
    "cffi": "2.1.0",
    "pycparser": "3.0",
}


def _has_allowed_owner(path_stat: os.stat_result, allowed_uids: set[int]) -> bool:
    return path_stat.st_uid in allowed_uids


def _has_protected_mode(path_stat: os.stat_result) -> bool:
    return not bool(path_stat.st_mode & 0o022)


def _symlink_target_is_trusted(path: Path, root: Path) -> bool:
    target = path.resolve(strict=True)
    allowed_uids = {0, os.geteuid()}
    for protected_path in [target, *target.parents]:
        target_stat = protected_path.stat()
        if not _has_allowed_owner(target_stat, allowed_uids):
            return False
        if not _has_protected_mode(target_stat):
            return False
        if protected_path == root:
            break
    return True


def _managed_entry_is_trusted(path: Path, root: Path) -> bool:
    path_stat = path.lstat()
    if not _has_allowed_owner(path_stat, {os.geteuid()}):
        return False
    if stat.S_ISLNK(path_stat.st_mode):
        return _symlink_target_is_trusted(path, root)
    return _has_protected_mode(path_stat)


def check_managed_path(root: Path, marker: Optional[Path] = None) -> int:
    try:
        paths = [root, *root.rglob("*")]
        if marker is not None:
            paths.append(marker)
        if not all(_managed_entry_is_trusted(path, root) for path in paths):
            return 1
    except (OSError, RuntimeError):
        return 1
    return 0


def check_ancestor_chain(home: Path, root: Path) -> int:
    try:
        home = home.absolute()
        current = root.absolute()
        if current != home and home not in current.parents:
            return 1
        while True:
            if os.path.lexists(current):
                current_stat = current.lstat()
                if stat.S_ISLNK(current_stat.st_mode) or current_stat.st_uid != os.geteuid() or current_stat.st_mode & 0o022:
                    return 1
            if current == home:
                break
            current = current.parent
    except OSError:
        return 1
    return 0


def check_crypto_runtime() -> int:
    for package, expected in EXPECTED.items():
        if importlib.metadata.version(package) != expected:
            return 1

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

    key = bytes(range(32))
    nonce = bytes(range(12))
    plaintext = b"aidevops-vault-runtime-check"
    ciphertext = AESGCM(key).encrypt(nonce, plaintext, b"runtime-check")
    if AESGCM(key).decrypt(nonce, ciphertext, b"runtime-check") != plaintext:
        return 1

    derived = Scrypt(salt=bytes(range(16)), length=32, n=2**14, r=8, p=1).derive(plaintext)
    if len(derived) != 32:
        return 1

    signing_key = Ed25519PrivateKey.generate()
    signature = signing_key.sign(plaintext)
    signing_key.public_key().verify(signature, plaintext)
    return 0


def main() -> int:
    if len(sys.argv) == 4 and sys.argv[1] == "--check-path":
        return check_managed_path(Path(sys.argv[2]), Path(sys.argv[3]))
    if len(sys.argv) == 3 and sys.argv[1] == "--check-path":
        return check_managed_path(Path(sys.argv[2]))
    if len(sys.argv) == 4 and sys.argv[1] == "--check-ancestors":
        return check_ancestor_chain(Path(sys.argv[2]), Path(sys.argv[3]))
    if len(sys.argv) != 1:
        return 1
    return check_crypto_runtime()


if __name__ == "__main__":
    raise SystemExit(main())
