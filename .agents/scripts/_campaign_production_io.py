"""Fail-closed JSON and digest helpers for campaign production."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from pathlib import Path
from typing import Any

from _campaign_production_definitions import ManifestError


def digest(value: Any) -> str:
    """Return a stable SHA-256 reference for JSON-compatible content."""
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def atomic_json_write(path: Path, document: dict[str, Any]) -> None:
    """Atomically write JSON without replacing valid state on failure."""
    unsafe_existing = path.exists() and not path.is_file()
    if path.is_symlink() or path.parent.is_symlink() or unsafe_existing:
        raise ManifestError("production JSON destination must be a regular path")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def read_document(path: Path, label: str) -> dict[str, Any]:
    """Read one object document with a useful contract error."""
    if path.is_symlink() or not path.is_file():
        raise ManifestError(f"invalid {label}: path must be a regular non-symlink file")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, ValueError) as error:
        raise ManifestError(f"invalid {label}: {path}: {error}") from error
    if not isinstance(document, dict):
        raise ManifestError(f"invalid {label}: {path} must contain an object")
    return document
