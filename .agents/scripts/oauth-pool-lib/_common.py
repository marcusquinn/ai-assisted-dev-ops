#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
oauth-pool-lib/_common.py — Shared primitives for pool_ops_*.py modules.

Houses cross-platform locking, atomic file writes, the provider endpoint
tables, and the auth.json entry builder. Extracted from pool_ops.py during
the t2069 decomposition so each per-command module imports from here rather
than re-declaring its own copies.

Security: No token values are printed by any helper here.
"""

from __future__ import annotations

import json
import os
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from typing import Any


TOKEN_URLS: dict[str, str] = {
    "anthropic": "https://platform.claude.com/v1/oauth/token",
    "openai": "https://auth.openai.com/oauth/token",
    "google": "https://oauth2.googleapis.com/token",
}

CLIENT_IDS: dict[str, str] = {
    "anthropic": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
    "openai": "app_EMoamEEZ73f0CkXaXp7hrann",
    "google": "681255809395-oo8ft6t5t0rnmhfqgpnkqtev5b9a2i5j.apps.googleusercontent.com",
}

TOKEN_REFRESH_ERROR_KEY = "__aidevops_token_refresh_error__"
_AUTH_ERROR_CODES = {
    "access_denied",
    "invalid_client",
    "invalid_grant",
    "invalid_request",
    "unauthorized_client",
}


# ---------------------------------------------------------------------------
# Cross-runtime exclusive lock (stdlib only, no pip dependencies).
# ---------------------------------------------------------------------------

_LOCK_WAIT_SECONDS = 30.0
_OWNERLESS_LOCK_GRACE_SECONDS = 30.0


def _process_is_live(pid: object) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _stale_lock_snapshot(lock_dir: str, owner_path: str) -> str | None:
    try:
        with open(owner_path, encoding="utf-8") as owner_file:
            raw = owner_file.read()
        owner = json.loads(raw)
        return None if _process_is_live(owner.get("pid")) else raw
    except (OSError, ValueError, TypeError, AttributeError):
        try:
            age = time.time() - os.stat(lock_dir).st_mtime
        except OSError:
            return None
        return "" if age >= _OWNERLESS_LOCK_GRACE_SECONDS else None


def _remove_stale_lock(lock_dir: str, owner_path: str, snapshot: str) -> None:
    try:
        with open(owner_path, encoding="utf-8") as owner_file:
            current = owner_file.read()
        if current != snapshot:
            return
    except OSError:
        if snapshot != "":
            return
    try:
        os.unlink(owner_path)
    except OSError:
        pass
    try:
        os.rmdir(lock_dir)
    except OSError:
        pass


def acquire_lock(lock_fd, timeout: float = _LOCK_WAIT_SECONDS) -> None:
    """Acquire the mkdir lock shared with the OpenCode OAuth pool."""
    lock_path = os.fspath(lock_fd.name)
    lock_dir = lock_path + ".d"
    owner_path = os.path.join(lock_dir, "owner")
    token = str(uuid.uuid4())
    deadline = time.monotonic() + timeout
    os.chmod(lock_path, 0o600)

    while time.monotonic() < deadline:
        try:
            os.mkdir(lock_dir, 0o700)
        except FileExistsError:
            snapshot = _stale_lock_snapshot(lock_dir, owner_path)
            if snapshot is not None:
                _remove_stale_lock(lock_dir, owner_path, snapshot)
                continue
            time.sleep(0.05)
            continue

        try:
            owner_fd = os.open(owner_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(owner_fd, "w", encoding="utf-8") as owner_file:
                json.dump(
                    {
                        "schema": "aidevops.oauth-lock/v1",
                        "pid": os.getpid(),
                        "token": token,
                        "createdAt": int(time.time() * 1000),
                    },
                    owner_file,
                )
            os.chmod(lock_dir, 0o700)
            os.chmod(owner_path, 0o600)
            lock_fd._aidevops_lock = (lock_dir, owner_path, token)
            return
        except BaseException:
            try:
                os.unlink(owner_path)
            except OSError:
                pass
            try:
                os.rmdir(lock_dir)
            except OSError:
                pass
            raise

    raise TimeoutError("timed out waiting for OAuth pool lock")


def release_lock(lock_fd) -> None:
    """Release only the mkdir lock owned by this descriptor."""
    ownership = getattr(lock_fd, "_aidevops_lock", None)
    if not ownership:
        return
    lock_dir, owner_path, token = ownership
    try:
        with open(owner_path, encoding="utf-8") as owner_file:
            owner = json.load(owner_file)
        if owner.get("pid") != os.getpid() or owner.get("token") != token:
            return
        os.unlink(owner_path)
        os.rmdir(lock_dir)
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    finally:
        delattr(lock_fd, "_aidevops_lock")


def atomic_write_json(path: str, data: Any) -> None:
    """Atomically write JSON data to a file (write-to-temp then rename)."""
    parent = os.path.dirname(path)
    d = parent or "."
    os.makedirs(d, mode=0o700, exist_ok=True)
    if parent:
        os.chmod(d, 0o700)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------
# Auth-entry builder (shared by rotate + refresh self-heal).
# ---------------------------------------------------------------------------

def build_auth_entry(provider: str, account: dict, current_auth: dict) -> dict:
    """Build the per-provider entry for ``auth.json`` from a pool account.

    Carries over ``accountId`` for OpenAI (preserving the workspace selection
    when the new account doesn't override it), and falls back to the existing
    ``type`` from ``current_auth`` if present (defaults to ``oauth``).
    """
    entry: dict[str, Any] = {
        "type": current_auth.get("type", "oauth") if isinstance(current_auth, dict) else "oauth",
        "refresh": account.get("refresh", ""),
        "access": account.get("access", ""),
        "expires": account.get("expires", 0),
    }
    if provider == "openai":
        existing_id = current_auth.get("accountId", "") if isinstance(current_auth, dict) else ""
        account_id = account.get("accountId", existing_id)
        if account_id:
            entry["accountId"] = account_id
    return entry


def token_refresh_error_label(response: dict | None) -> str:
    """Return the sanitized token-refresh error label carried by ``response``."""
    if not isinstance(response, dict):
        return ""
    label = response.get(TOKEN_REFRESH_ERROR_KEY, "")
    return label if isinstance(label, str) else ""


def _classify_http_error(exc: urllib.error.HTTPError) -> str:
    """Classify an OAuth HTTP error without exposing response bodies or tokens."""
    status = int(getattr(exc, "code", 0) or 0)
    label = f"http_{status}" if status else "http_error"
    try:
        body = exc.read(4096).decode("utf-8", errors="replace")
        parsed = json.loads(body)
    except (OSError, ValueError, TypeError):
        return label

    error_code = parsed.get("error", "") if isinstance(parsed, dict) else ""
    if isinstance(error_code, str) and error_code in _AUTH_ERROR_CODES:
        return f"auth_{error_code}"
    return label


# ---------------------------------------------------------------------------
# OAuth refresh request (shared by cmd_refresh + cmd_rotate auto-refresh).
# ---------------------------------------------------------------------------

def call_token_endpoint(
    token_url: str,
    client_id: str,
    refresh_tok: str,
    ua_header: str,
    timeout: int = 15,
) -> dict | None:
    """POST a refresh-token grant to ``token_url`` and return the parsed JSON.

    Returns a dict carrying ``TOKEN_REFRESH_ERROR_KEY`` on HTTP/network errors.
    The caller is responsible for deciding what counts as success — a 200
    response that omits ``access_token`` should still be treated as a failure by
    the caller.
    """
    body = json.dumps(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh_tok,
            "client_id": client_id,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        token_url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "User-Agent": ua_header,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw_data = resp.read()
    except urllib.error.HTTPError as exc:
        return {TOKEN_REFRESH_ERROR_KEY: _classify_http_error(exc)}
    except (urllib.error.URLError, OSError):
        return {TOKEN_REFRESH_ERROR_KEY: "network"}

    try:
        data = json.loads(raw_data.decode("utf-8"))
        if isinstance(data, dict):
            return data
    except (ValueError, TypeError):
        pass
    return {TOKEN_REFRESH_ERROR_KEY: "invalid_response"}
