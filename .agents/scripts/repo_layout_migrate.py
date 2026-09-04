#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Plan and execute interruption-safe canonical repository layout migrations."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any, Iterable


PLAN_SCHEMA = "aidevops-repo-layout-plan/v1"
RECEIPT_SCHEMA = "aidevops-repo-layout-receipt/v1"
REMOTE_RE = re.compile(
    r"^(?:(?:[a-z][a-z0-9+.-]*://)(?:[^/@]+@)?|[^@/]+@)?"
    r"(?P<host>[^/:]+)[:/](?P<owner>[^/]+)/(?P<repo>[^/]+?)(?:\.git)?$",
    re.IGNORECASE,
)


class MigrationError(RuntimeError):
    """A safety invariant refused the requested migration operation."""


def canonical_bytes(value: Any) -> bytes:
    """Return deterministic UTF-8 JSON bytes."""
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    """Return a lowercase SHA-256 digest."""
    return hashlib.sha256(value).hexdigest()


def file_sha256(path: Path) -> str:
    """Hash one regular file without following a final symlink."""
    if path.is_symlink() or not path.is_file():
        raise MigrationError(f"Unsafe or missing file: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def private_directory(path: Path) -> None:
    """Create or validate an owner-private directory."""
    if path.exists():
        details = path.lstat()
        if (
            not stat.S_ISDIR(details.st_mode)
            or path.is_symlink()
            or details.st_uid != os.getuid()
        ):
            raise MigrationError(f"Unsafe state directory: {path}")
    else:
        path.mkdir(parents=True, mode=0o700)
    path.chmod(0o700)


def atomic_write(path: Path, payload: bytes, mode: int = 0o600) -> None:
    """Atomically replace a file on its current filesystem."""
    if path.parent.is_symlink() or not path.parent.is_dir():
        raise MigrationError(f"Unsafe destination directory: {path.parent}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.chmod(mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def load_json(path: Path) -> Any:
    """Load a regular JSON file."""
    if path.is_symlink() or not path.is_file():
        raise MigrationError(f"Unsafe or missing JSON file: {path}")
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise MigrationError(f"Malformed JSON file: {path}") from exc


def expand_path(value: str) -> Path:
    """Expand user syntax and return an absolute lexical path."""
    return Path(os.path.abspath(os.path.expanduser(value)))


def run(command: list[str], *, cwd: Path | None = None, binary: bool = False) -> Any:
    """Run a structured local command and return stdout."""
    try:
        result = subprocess.run(  # nosec B603
            command,
            cwd=cwd,
            check=True,
            capture_output=True,
            text=not binary,
            timeout=30,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        detail = getattr(exc, "stderr", "")
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace")
        raise MigrationError(f"Command failed: {command[0]} {str(detail).strip()}") from exc
    return result.stdout


def git(repo: Path, *arguments: str, binary: bool = False) -> Any:
    """Run Git against one repository without a shell."""
    return run(["git", "-C", str(repo), *arguments], binary=binary)


def parse_remote(remote: str) -> tuple[str, str, str] | None:
    """Return sanitized host/owner/repository identity for a Git remote."""
    match = REMOTE_RE.match(remote.strip())
    if not match:
        return None
    host = match.group("host").lower()
    owner = match.group("owner")
    repository = match.group("repo")
    if not all(re.fullmatch(r"[A-Za-z0-9._-]+", item) for item in (host, owner, repository)):
        return None
    return host, owner, repository


def discover_repositories(workspace: Path, discovery_lib: Path) -> list[Path]:
    """Call the shared bounded shell discovery policy and parse NUL records."""
    script = 'source "$1"; aidevops_discover_canonical_repos "$2"'
    output = run(
        ["bash", "-c", script, "repo-layout-discovery", str(discovery_lib), str(workspace)],
        binary=True,
    )
    return sorted(Path(item.decode()) for item in output.split(b"\0") if item)


def recommended_path(
    workspace: Path,
    host: str,
    owner: str,
    repository: str,
    repos_json: Path,
    discovery_lib: Path,
) -> Path:
    """Call the shared host-aware owner path policy."""
    script = 'source "$1"; aidevops_recommended_repo_path "$2" "$3" "$4" "$5" "$6"'
    output = run(
        [
            "bash",
            "-c",
            script,
            "repo-layout-recommend",
            str(discovery_lib),
            str(workspace),
            host,
            owner,
            repository,
            str(repos_json),
        ]
    )
    return expand_path(output.strip())


def status_records(repo: Path) -> tuple[str, int]:
    """Return a stable status digest and entry count."""
    raw = git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all", binary=True)
    return sha256_bytes(raw), len([item for item in raw.split(b"\0") if item])


def working_tree_digest(repo: Path) -> str:
    """Hash tracked diffs and exact untracked file content."""
    digest = hashlib.sha256()
    digest.update(git(repo, "diff", "--no-ext-diff", "--binary", binary=True))
    digest.update(
        git(repo, "diff", "--cached", "--no-ext-diff", "--binary", binary=True)
    )
    untracked = git(
        repo,
        "ls-files",
        "--others",
        "--exclude-standard",
        "-z",
        binary=True,
    )
    for raw_path in sorted(item for item in untracked.split(b"\0") if item):
        digest.update(raw_path)
        path = repo / os.fsdecode(raw_path)
        if path.is_symlink():
            digest.update(b"symlink\0" + os.readlink(path).encode())
        elif path.is_file():
            digest.update(b"file\0" + path.read_bytes())
        else:
            raise MigrationError(f"Unsupported untracked path: {path}")
    return digest.hexdigest()


def worktree_records(repo: Path) -> list[dict[str, Any]]:
    """Return normalized worktree identities, preserving linked paths."""
    records: list[dict[str, Any]] = []
    current: dict[str, Any] = {}
    for line in git(repo, "worktree", "list", "--porcelain").splitlines() + [""]:
        if not line:
            if current:
                path = Path(current.get("worktree", ""))
                if path.is_dir():
                    status_hash, status_count = status_records(path)
                    current["status_sha256"] = status_hash
                    current["status_entries"] = status_count
                    current["working_tree_sha256"] = working_tree_digest(path)
                # Git always lists the main worktree first. Normalize that
                # location because its spelling changes during a move.
                current["worktree"] = "<canonical>" if not records else str(path)
                records.append(current)
                current = {}
            continue
        key, _, value = line.partition(" ")
        current[key] = value
    return records


def repository_fingerprint(repo: Path) -> dict[str, Any]:
    """Capture the exact local Git state that a move must preserve."""
    status_hash, status_count = status_records(repo)
    branches = git(
        repo,
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname)%00%(objectname)",
        "refs/heads",
    ).splitlines()
    stashes = git(
        repo,
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname)%00%(objectname)",
        "refs/stash",
    ).splitlines()
    gitmodules = repo / ".gitmodules"
    modules_hash = file_sha256(gitmodules) if gitmodules.exists() else None
    submodule_state: list[dict[str, str]] = []
    index_records = git(repo, "ls-files", "--stage", "-z", binary=True)
    for record in index_records.split(b"\0"):
        if not record:
            continue
        metadata, _, raw_path = record.partition(b"\t")
        mode, object_name, _stage = metadata.decode().split(" ", 2)
        if mode != "160000":
            continue
        relative_path = raw_path.decode()
        child = repo / relative_path
        actual_head = "unavailable"
        if child.exists():
            try:
                actual_head = git(child, "rev-parse", "HEAD").strip()
            except MigrationError:
                actual_head = "unavailable"
        submodule_state.append(
            {
                "path": relative_path,
                "index_head": object_name,
                "actual_head": actual_head,
                "working_tree_sha256": (
                    working_tree_digest(child)
                    if child.exists() and actual_head != "unavailable"
                    else "unavailable"
                ),
            }
        )
    return {
        "head": git(repo, "rev-parse", "HEAD").strip(),
        "branch": git(repo, "symbolic-ref", "--quiet", "--short", "HEAD").strip(),
        "branches": branches,
        "status_sha256": status_hash,
        "status_entries": status_count,
        "working_tree_sha256": working_tree_digest(repo),
        "stashes": stashes,
        "stash_count": len(stashes),
        "gitmodules_sha256": modules_hash,
        "submodules_sha256": sha256_bytes(canonical_bytes(submodule_state)),
        "worktrees": worktree_records(repo),
    }


def linked_pointer_records(repo: Path, records: list[dict[str, Any]]) -> list[dict[str, str]]:
    """Record exact linked-worktree pointer content for guarded repair."""
    pointers: list[dict[str, str]] = []
    prefix = f"gitdir: {repo}/.git/"
    for record in records:
        worktree = record.get("worktree")
        if not worktree or worktree == "<canonical>":
            continue
        marker = Path(worktree) / ".git"
        if marker.is_symlink() or not marker.is_file():
            raise MigrationError(f"Linked worktree pointer is unavailable: {marker}")
        content = marker.read_text(encoding="utf-8")
        if not content.startswith(prefix):
            raise MigrationError(f"Unexpected linked worktree pointer: {marker}")
        pointers.append(
            {"path": str(marker), "sha256": sha256_bytes(content.encode()), "content": content}
        )
    return pointers


def nearest_existing_parent(path: Path) -> Path:
    """Find the nearest existing parent without creating anything."""
    candidate = path
    while not candidate.exists() and candidate != candidate.parent:
        candidate = candidate.parent
    if not candidate.is_dir():
        raise MigrationError(f"No safe destination parent exists for {path}")
    return candidate


def safe_destination_parent(workspace: Path, destination: Path) -> Path:
    """Reject symlink escapes and return the nearest destination parent."""
    candidate = destination.parent
    while candidate != workspace:
        if candidate.exists() and candidate.is_symlink():
            raise MigrationError(f"Destination traverses a symlink: {candidate}")
        if candidate == candidate.parent or not path_is_inside(workspace, candidate):
            raise MigrationError("Destination escaped the workspace")
        candidate = candidate.parent
    parent = nearest_existing_parent(destination.parent)
    if parent.is_symlink() or not path_is_inside(workspace, parent.resolve()):
        raise MigrationError("Destination parent escaped the workspace")
    return parent


def same_existing_path(first: Path, second: Path) -> bool:
    """Return whether two existing names resolve to the same filesystem object."""
    try:
        return os.path.samefile(first, second)
    except (FileNotFoundError, OSError):
        return False


def path_is_inside(parent: Path, candidate: Path) -> bool:
    """Return whether candidate is at or below parent lexically."""
    try:
        candidate.relative_to(parent)
        return True
    except ValueError:
        return False


def sqlite_schema(connection: sqlite3.Connection) -> dict[str, list[str]]:
    """Return only the migration-relevant SQLite table columns."""
    result: dict[str, list[str]] = {}
    for table in ("project", "session"):
        try:
            rows = connection.execute(f"PRAGMA table_info({table})").fetchall()
        except sqlite3.Error as exc:
            raise MigrationError(f"Could not inspect SQLite table: {table}") from exc
        if rows:
            result[table] = [str(row[1]) for row in rows]
    return result


def validated_sql_target(table: str, column: str) -> tuple[str, str]:
    """Allow only the two fixed OpenCode path columns."""
    if (table, column) not in {("project", "worktree"), ("session", "directory")}:
        raise MigrationError("Receipt contains an unsupported database target")
    return table, column


def sqlite_consumer(path: Path, mappings: dict[str, str]) -> dict[str, Any]:
    """Capture relevant exact-path SQLite rows and schema."""
    if path.is_symlink() or not path.is_file() or path.stat().st_uid != os.getuid():
        raise MigrationError(f"Unsafe OpenCode database: {path}")
    uri = f"file:{path}?mode=ro"
    try:
        connection = sqlite3.connect(uri, uri=True, timeout=2)
        schema = sqlite_schema(connection)
        rows: list[dict[str, str]] = []
        for table, column in (("project", "worktree"), ("session", "directory")):
            if table not in schema or "id" not in schema[table] or column not in schema[table]:
                continue
            parent_clause = " AND parent_id IS NULL" if table == "session" and "parent_id" in schema[table] else ""
            for old_path in mappings:
                query = f"SELECT id, {column} FROM {table} WHERE {column} = ?{parent_clause}"
                for row_id, value in connection.execute(query, (old_path,)).fetchall():
                    rows.append({"table": table, "column": column, "id": str(row_id), "value": str(value)})
        integrity = connection.execute("PRAGMA integrity_check").fetchone()
    except sqlite3.Error as exc:
        raise MigrationError(f"Could not inspect OpenCode database: {path}") from exc
    finally:
        if "connection" in locals():
            connection.close()
    if not integrity or integrity[0] != "ok":
        raise MigrationError(f"SQLite integrity check failed: {path}")
    return {"path": str(path), "schema": schema, "rows": rows}


def existing_optional_path(value: str | None, default: Path) -> Path | None:
    """Resolve an optional path, returning None when it does not exist."""
    path = expand_path(value) if value else default
    return path if path.exists() else None


def migration_mappings(repositories: Iterable[dict[str, Any]]) -> dict[str, str]:
    """Build the exact old-to-new path map."""
    return {item["source"]: item["destination"] for item in repositories}


def plan_consumers(args: argparse.Namespace, mappings: dict[str, str]) -> dict[str, Any]:
    """Inventory local config, terminal, runtime database, and marker consumers."""
    home = Path.home()
    repos_json = expand_path(args.repos_json) if args.repos_json else home / ".config/aidevops/repos.json"
    tabby = existing_optional_path(
        args.tabby_config,
        home / "Library/Application Support/tabby/config.yaml",
    )
    opencode = existing_optional_path(
        args.opencode_db,
        home / ".local/share/opencode/opencode.db",
    )
    isolated_root = existing_optional_path(
        args.isolated_root,
        home / ".aidevops/.agent-workspace/work/opencode-interactive",
    )
    recovery_root = existing_optional_path(
        args.recovery_root,
        home / ".aidevops/.agent-workspace/work/opencode-tabby-recovery",
    )
    consumers: dict[str, Any] = {
        "repos_json": None,
        "tabby": None,
        "databases": [],
        "markers": [],
    }
    if repos_json.exists():
        config = load_json(repos_json)
        matches = []
        for index, item in enumerate(config.get("initialized_repos", [])):
            if isinstance(item, dict) and item.get("path") in mappings:
                matches.append({"index": index, "path": item["path"]})
        consumers["repos_json"] = {
            "path": str(repos_json),
            "sha256": file_sha256(repos_json),
            "matches": matches,
        }
    if tabby:
        tabby_text = tabby.read_text(encoding="utf-8")
        try:
            load_tabby_module(Path(__file__).with_name("tabby-profile-sync.py")).retarget_profile_cwds(
                tabby_text, {}
            )
        except Exception as exc:  # Validation adapter normalizes parser failures.
            raise MigrationError(f"Malformed Tabby config: {tabby}") from exc
        consumers["tabby"] = {
            "path": str(tabby),
            "sha256": file_sha256(tabby),
            "matched_paths": sorted(old for old in mappings if old in tabby_text),
        }
    database_paths: list[Path] = []
    if opencode and opencode.is_file():
        database_paths.append(opencode)
    if isolated_root and isolated_root.is_dir():
        database_paths.extend(sorted(isolated_root.glob("*/opencode/opencode.db")))
    for database in dict.fromkeys(database_paths):
        consumers["databases"].append(sqlite_consumer(database, mappings))
    if recovery_root and recovery_root.is_dir():
        for marker in sorted(recovery_root.glob("*/recovery.json")):
            if marker.is_symlink() or not marker.is_file():
                raise MigrationError(f"Unsafe recovery marker: {marker}")
            marker_details = marker.stat()
            directory_details = marker.parent.stat()
            if (
                marker_details.st_uid != os.getuid()
                or directory_details.st_uid != os.getuid()
                or marker_details.st_mode & 0o077
                or directory_details.st_mode & 0o077
            ):
                raise MigrationError(f"Recovery marker is not owner-private: {marker}")
            payload = load_json(marker)
            if payload.get("schema_version") == 1 and payload.get("directory") in mappings:
                consumers["markers"].append(
                    {
                        "path": str(marker),
                        "sha256": file_sha256(marker),
                        "directory": payload["directory"],
                    }
                )
    return consumers


def plan_command(args: argparse.Namespace) -> int:
    """Create a deterministic, non-mutating migration plan."""
    workspace = expand_path(args.workspace)
    output = expand_path(args.output)
    discovery_lib = expand_path(args.discovery_lib)
    if workspace.is_symlink() or not workspace.is_dir():
        raise MigrationError("Workspace must be an existing non-symlink directory")
    workspace = workspace.resolve()
    repos_json = expand_path(args.repos_json) if args.repos_json else Path.home() / ".config/aidevops/repos.json"
    registrations: list[dict[str, Any]] = []
    if repos_json.exists():
        payload = load_json(repos_json)
        entries = payload.get("initialized_repos", [])
        if not isinstance(entries, list):
            raise MigrationError("repos.json initialized_repos must be an array")
        registrations = [item for item in entries if isinstance(item, dict)]

    repositories: list[dict[str, Any]] = []
    exclusions: list[dict[str, str]] = []
    for source in discover_repositories(workspace, discovery_lib):
        try:
            remote = git(source, "remote", "get-url", "origin").strip()
        except MigrationError:
            exclusions.append({"path": str(source), "reason": "missing-origin"})
            continue
        identity = parse_remote(remote)
        if not identity:
            exclusions.append({"path": str(source), "reason": "unsupported-remote"})
            continue
        host, owner, repository = identity
        if host != "github.com":
            exclusions.append({"path": str(source), "reason": "non-github-remote"})
            continue
        destination = recommended_path(
            workspace, host, owner, repository, repos_json, discovery_lib
        )
        if destination == source:
            continue
        if not path_is_inside(workspace, destination):
            raise MigrationError("Recommended destination escaped the workspace")
        registration_matches = [
            item for item in registrations if expand_path(str(item.get("path", ""))) == source
        ]
        if any(item.get("local_only") is True for item in registration_matches):
            exclusions.append({"path": str(source), "reason": "local-only-registration"})
            continue
        if registration_matches and not args.include_registered_paths:
            exclusions.append({"path": str(source), "reason": "explicit-registration-not-approved"})
            continue
        destination_parent = safe_destination_parent(workspace, destination)
        source_device = source.stat().st_dev
        destination_device = destination_parent.stat().st_dev
        worktrees = worktree_records(source)
        stage = workspace / f".aidevops-layout-stage-{uuid.uuid4().hex[:12]}"
        repositories.append(
            {
                "source": str(source),
                "destination": str(destination),
                "stage": str(stage),
                "remote": {"host": host, "owner": owner, "repository": repository},
                "fingerprint": repository_fingerprint(source),
                "linked_pointers": linked_pointer_records(source, worktrees),
                "registered": bool(registration_matches),
                "registration_update_approved": bool(registration_matches),
                "source_device": source_device,
                "destination_device": destination_device,
                "destination_collision": (
                    destination.exists() and not same_existing_path(source, destination)
                ),
            }
        )

    mappings = migration_mappings(repositories)
    consumers = plan_consumers(args, mappings)
    state_dir = (
        expand_path(args.state_dir)
        if args.state_dir
        else Path.home() / ".aidevops/.agent-workspace/work/repo-layout-migrations"
    )
    consumer_paths = []
    for name in ("repos_json", "tabby"):
        consumer = consumers.get(name)
        if consumer:
            consumer_paths.append(Path(consumer["path"]))
    consumer_paths.extend(Path(item["path"]) for item in consumers["databases"])
    consumer_paths.extend(Path(item["path"]) for item in consumers["markers"])
    for item in repositories:
        source = Path(item["source"])
        protected_paths = [output, state_dir, *consumer_paths]
        if any(path_is_inside(source, path) for path in protected_paths):
            raise MigrationError(
                "Plan, receipt, and consumer paths must remain outside moved repositories"
            )
    plan: dict[str, Any] = {
        "schema": PLAN_SCHEMA,
        "plan_id": uuid.uuid4().hex,
        "created_at": int(time.time()),
        "workspace": str(workspace),
        "workspace_device": workspace.stat().st_dev,
        "registered_paths_approved": bool(args.include_registered_paths),
        "repositories": repositories,
        "exclusions": exclusions,
        "consumers": consumers,
        "state_dir": str(state_dir),
    }
    plan["plan_sha256"] = sha256_bytes(canonical_bytes(plan))
    if any(item["destination_collision"] for item in repositories):
        raise MigrationError("Destination collision detected; no plan was written")
    if any(item["source_device"] != item["destination_device"] for item in repositories):
        raise MigrationError("Cross-device move detected; no plan was written")
    atomic_write(output, canonical_bytes(plan))
    print(
        json.dumps(
            {
                "plan": str(output),
                "plan_sha256": plan["plan_sha256"],
                "moves": len(repositories),
                "exclusions": len(exclusions),
            },
            sort_keys=True,
        )
    )
    return 0


def validate_plan(plan: dict[str, Any], confirmation: str) -> None:
    """Validate schema, embedded digest, and operator confirmation."""
    if plan.get("schema") != PLAN_SCHEMA:
        raise MigrationError("Unsupported migration plan schema")
    embedded = plan.get("plan_sha256")
    unsigned = dict(plan)
    unsigned.pop("plan_sha256", None)
    observed = sha256_bytes(canonical_bytes(unsigned))
    if embedded != observed or confirmation != observed:
        raise MigrationError("Plan SHA-256 confirmation does not match")


def receipt_paths(plan: dict[str, Any]) -> tuple[str, Path, Path]:
    """Resolve deterministic private receipt paths for a plan."""
    receipt_id = f"layout-{plan['plan_id']}"
    root = expand_path(plan["state_dir"])
    directory = root / receipt_id
    return receipt_id, directory, directory / "receipt.jsonl"


def append_event(journal: Path, event: dict[str, Any]) -> None:
    """Append and fsync one receipt event."""
    private_directory(journal.parent)
    payload = dict(event)
    payload.setdefault("timestamp", int(time.time()))
    with journal.open("ab") as handle:
        os.chmod(journal, 0o600)
        handle.write(canonical_bytes(payload))
        handle.flush()
        os.fsync(handle.fileno())


def read_events(
    journal: Path, *, repair_incomplete_tail: bool = False
) -> list[dict[str, Any]]:
    """Read complete JSONL records and optionally discard a torn final record."""
    if journal.is_symlink() or not journal.is_file():
        raise MigrationError(f"Receipt does not exist: {journal}")
    events: list[dict[str, Any]] = []
    try:
        raw = journal.read_bytes()
        valid_length = 0
        lines = raw.splitlines(keepends=True)
        for index, line in enumerate(lines):
            if not line.endswith(b"\n"):
                if index != len(lines) - 1:
                    raise MigrationError("Receipt journal has an invalid record boundary")
                if repair_incomplete_tail:
                    with journal.open("r+b") as handle:
                        handle.truncate(valid_length)
                        handle.flush()
                        os.fsync(handle.fileno())
                break
            events.append(json.loads(line))
            valid_length += len(line)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MigrationError("Receipt journal is malformed") from exc
    if events and events[0].get("schema") != RECEIPT_SCHEMA:
        raise MigrationError("Unsupported receipt schema")
    return events


def done_keys(events: list[dict[str, Any]]) -> set[str]:
    """Return completed idempotency keys."""
    return {str(event["key"]) for event in events if event.get("event") == "completed"}


def event_for_key(events: list[dict[str, Any]], key: str) -> dict[str, Any] | None:
    """Return the latest durable started or completed event for a key."""
    for event in reversed(events):
        if event.get("event") in {"started", "completed"} and event.get("key") == key:
            return event
    return None


def start_step(
    journal: Path,
    events: list[dict[str, Any]],
    key: str,
    details: dict[str, Any],
) -> dict[str, Any]:
    """Persist recovery details before a step can mutate external state."""
    existing = event_for_key(events, key)
    if existing:
        if existing.get("details") != details:
            raise MigrationError(f"Receipt step details changed: {key}")
        return details
    event = {"event": "started", "key": key, "details": details}
    append_event(journal, event)
    events.append(event)
    return details


def complete_step(
    journal: Path,
    events: list[dict[str, Any]],
    completed: set[str],
    key: str,
    details: dict[str, Any],
) -> None:
    """Record one verified mutation boundary as completed."""
    event = {"event": "completed", "key": key, "details": details}
    append_event(journal, event)
    events.append(event)
    completed.add(key)


def process_identity(pid: int) -> str:
    """Return a stable-enough process start identity when ps is available."""
    ps = shutil.which("ps")
    if not ps:
        return ""
    try:
        observed = subprocess.run(  # nosec B603
            [ps, "-o", "lstart=", "-p", str(pid)],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return observed.stdout.strip() if observed.returncode == 0 else ""


def lock_owner_is_live(owner: dict[str, Any]) -> bool:
    """Return whether a lock still belongs to the same live process."""
    try:
        pid = int(owner["pid"])
        os.kill(pid, 0)
    except (KeyError, TypeError, ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True
    expected_start = str(owner.get("process_start", ""))
    observed_start = process_identity(pid)
    return not expected_start or not observed_start or expected_start == observed_start


def acquire_lock(plan: dict[str, Any], receipt_id: str) -> Path:
    """Acquire a workspace-scoped mkdir lock."""
    state_root = expand_path(plan["state_dir"])
    private_directory(state_root)
    workspace_key = sha256_bytes(plan["workspace"].encode())[:20]
    lock = state_root / f"workspace-{workspace_key}.lock"
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError as exc:
        owner_path = lock / "owner.json"
        try:
            owner = load_json(owner_path)
        except MigrationError:
            raise MigrationError(f"Unverifiable workspace migration lock: {lock}") from exc
        if lock_owner_is_live(owner):
            raise MigrationError(
                f"Another layout migration owns the workspace lock: {lock}"
            ) from exc
        owner_path.unlink()
        try:
            lock.rmdir()
            lock.mkdir(mode=0o700)
        except OSError as recovery_error:
            raise MigrationError(f"Could not recover stale workspace lock: {lock}") from recovery_error
    atomic_write(
        lock / "owner.json",
        canonical_bytes(
            {
                "receipt_id": receipt_id,
                "pid": os.getpid(),
                "process_start": process_identity(os.getpid()),
            }
        ),
    )
    return lock


def release_lock(lock: Path) -> None:
    """Release a lock created by acquire_lock."""
    (lock / "owner.json").unlink(missing_ok=True)
    try:
        lock.rmdir()
    except OSError:
        pass


def assert_no_active_path(plan: dict[str, Any]) -> None:
    """Reject observed process working directories below a planned path."""
    current = Path.cwd().resolve()
    active_directories = [current]
    lsof = shutil.which("lsof")
    if lsof:
        try:
            observed = subprocess.run(  # nosec B603
                [lsof, "-a", "-d", "cwd", "-Fpn"],
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
            )
            if observed.returncode in (0, 1):
                active_directories.extend(
                    Path(line[1:]).resolve()
                    for line in observed.stdout.splitlines()
                    if line.startswith("n/")
                )
        except (OSError, subprocess.TimeoutExpired):
            pass
    for item in plan["repositories"]:
        source = Path(item["source"])
        destination = Path(item["destination"])
        for active in active_directories:
            if path_is_inside(source, active) or path_is_inside(destination, active):
                raise MigrationError(
                    "Active-path ambiguity: a process cwd is inside a planned repository"
                )


def validate_repository_plan(
    item: dict[str, Any], completed: bool, workspace: Path, started: bool = False
) -> None:
    """Verify one source or already-moved destination against the plan."""
    source = Path(item["source"])
    destination = Path(item["destination"])
    stage = Path(item["stage"])
    location = destination if completed or (not source.exists() and destination.exists()) else source
    if not location.is_dir():
        if stage.is_dir():
            location = stage
        else:
            raise MigrationError(f"Planned repository is missing: {source}")
    if not (started and location == stage) and repository_fingerprint(location) != item["fingerprint"]:
        raise MigrationError(f"Repository drift detected: {source}")
    if source.exists() and destination.exists() and not same_existing_path(source, destination):
        raise MigrationError(f"Source and destination both exist: {source}")
    parent = safe_destination_parent(workspace, destination)
    if location.stat().st_dev != parent.stat().st_dev:
        raise MigrationError(f"Cross-device move refused: {source}")


def validate_consumers(
    plan: dict[str, Any], completed: set[str], events: list[dict[str, Any]]
) -> None:
    """Reject pre-apply config, marker, and database drift."""
    consumers = plan["consumers"]
    for name in ("repos_json", "tabby"):
        consumer = consumers.get(name)
        key = f"consumer:{name}"
        if consumer and key not in completed:
            path = Path(consumer["path"])
            allowed = {consumer["sha256"]}
            started = event_for_key(events, key)
            if started:
                allowed.add(started["details"]["after_sha256"])
            if file_sha256(path) not in allowed:
                raise MigrationError(f"Consumer drift detected: {name}")
    for index, database in enumerate(consumers.get("databases", [])):
        key = f"consumer:database:{index}"
        if key not in completed:
            started = event_for_key(events, key)
            if started:
                path = Path(database["path"])
                with sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=2) as connection:
                    schema = sqlite_schema(connection)
                if (
                    schema != database["schema"]
                    or database_change_state(path, started["details"]["changes"])
                    not in {"before", "after"}
                ):
                    raise MigrationError(
                        f"Database schema or row drift detected: {database['path']}"
                    )
            else:
                observed = sqlite_consumer(
                    Path(database["path"]), migration_mappings(plan["repositories"])
                )
                if observed["schema"] != database["schema"] or observed["rows"] != database["rows"]:
                    raise MigrationError(
                        f"Database schema or row drift detected: {database['path']}"
                    )
    for index, marker in enumerate(consumers.get("markers", [])):
        key = f"consumer:marker:{index}"
        if key not in completed:
            allowed = {marker["sha256"]}
            started = event_for_key(events, key)
            if started:
                allowed.add(started["details"]["after_sha256"])
            if file_sha256(Path(marker["path"])) not in allowed:
                raise MigrationError(f"Recovery marker drift detected: {marker['path']}")


def create_parent_directories(path: Path, workspace: Path) -> list[str]:
    """Create missing destination parents beneath the workspace."""
    missing: list[Path] = []
    candidate = path
    while not candidate.exists():
        if candidate == workspace or not path_is_inside(workspace, candidate):
            raise MigrationError("Destination parent escaped workspace")
        missing.append(candidate)
        candidate = candidate.parent
    for directory in reversed(missing):
        directory.mkdir(mode=0o700)
    return [str(item) for item in missing]


def planned_parent_directories(path: Path, workspace: Path) -> list[str]:
    """Describe destination parents that the migration owns before mutation."""
    missing: list[Path] = []
    candidate = path
    while not candidate.exists():
        if candidate == workspace or not path_is_inside(workspace, candidate):
            raise MigrationError("Destination parent escaped workspace")
        missing.append(candidate)
        candidate = candidate.parent
    return [str(item) for item in missing]


def repository_step_details(
    item: dict[str, Any], workspace: Path
) -> dict[str, Any]:
    """Build deterministic rollback details before moving a repository."""
    source = Path(item["source"])
    destination = Path(item["destination"])
    self_nested = path_is_inside(source, destination) and source != destination
    if self_nested:
        created_directories = []
        candidate = destination.parent
        while path_is_inside(source, candidate):
            created_directories.append(str(candidate))
            if candidate == source:
                break
            candidate = candidate.parent
    else:
        created_directories = planned_parent_directories(
            destination.parent, workspace
        )
    old_prefix = f"gitdir: {source}/.git/"
    new_prefix = f"gitdir: {destination}/.git/"
    pointer_changes = []
    for pointer in item["linked_pointers"]:
        before = pointer["content"]
        if not before.startswith(old_prefix):
            raise MigrationError(f"Unexpected planned linked pointer: {pointer['path']}")
        pointer_changes.append(
            {
                "path": pointer["path"],
                "before": before,
                "after": new_prefix + before[len(old_prefix) :],
            }
        )
    return {
        "source": str(source),
        "destination": str(destination),
        "created_directories": created_directories,
        "self_nested": self_nested,
        "pointer_changes": pointer_changes,
        "post_fingerprint": item["fingerprint"],
    }


def repair_linked_pointers(item: dict[str, Any], new_root: Path) -> list[dict[str, str]]:
    """Rewrite only exact expected linked-worktree gitdir prefixes."""
    old_root = Path(item["source"])
    changes: list[dict[str, str]] = []
    for pointer in item["linked_pointers"]:
        path = Path(pointer["path"])
        content = path.read_text(encoding="utf-8")
        old_prefix = f"gitdir: {old_root}/.git/"
        new_prefix = f"gitdir: {new_root}/.git/"
        if content.startswith(new_prefix):
            continue
        if sha256_bytes(content.encode()) != pointer["sha256"] or not content.startswith(old_prefix):
            raise MigrationError(f"Unexpected linked worktree pointer content: {path}")
        updated = new_prefix + content[len(old_prefix) :]
        atomic_write(path, updated.encode(), mode=path.stat().st_mode & 0o777)
        changes.append({"path": str(path), "before": content, "after": updated})
    return changes


def move_repository(
    item: dict[str, Any], workspace: Path, details: dict[str, Any]
) -> dict[str, Any]:
    """Move one repository, recover staging, repair pointers, and verify state."""
    source = Path(item["source"])
    destination = Path(item["destination"])
    stage = Path(item["stage"])
    create_parent_directories(destination.parent, workspace)
    case_only = str(source).lower() == str(destination).lower() and source != destination
    self_nested = path_is_inside(source, destination) and source != destination
    if destination.exists() and not source.exists():
        pass
    elif stage.exists() and not source.exists():
        create_parent_directories(destination.parent, workspace)
        os.rename(stage, destination)
    elif source.exists() and (
        not destination.exists()
        or (case_only and same_existing_path(source, destination))
    ):
        if case_only or self_nested:
            if stage.exists():
                raise MigrationError(f"Migration stage collision: {stage}")
            os.rename(source, stage)
            create_parent_directories(destination.parent, workspace)
            os.rename(stage, destination)
        else:
            os.rename(source, destination)
    else:
        raise MigrationError(f"Ambiguous move state: {source}")
    repair_linked_pointers(item, destination)
    observed = repository_fingerprint(destination)
    if observed != item["fingerprint"]:
        changed_fields = sorted(
            key
            for key in set(observed) | set(item["fingerprint"])
            if observed.get(key) != item["fingerprint"].get(key)
        )
        raise MigrationError(
            f"Post-move repository verification failed ({','.join(changed_fields)}): "
            f"{destination}"
        )
    if observed != details["post_fingerprint"]:
        raise MigrationError(f"Receipt repository details changed: {source}")
    return details


def backup_regular_file(source: Path, destination: Path) -> None:
    """Atomically copy one regular file to a private receipt backup."""
    if source.is_symlink() or not source.is_file():
        raise MigrationError(f"Unsafe backup source: {source}")
    private_directory(destination.parent)
    atomic_write(destination, source.read_bytes(), mode=0o600)


def ensure_file_backup(source: Path, backup: Path, before_sha256: str) -> bytes:
    """Create once and authenticate a pre-mutation regular-file backup."""
    if backup.exists():
        details = backup.lstat()
        if (
            backup.is_symlink()
            or not backup.is_file()
            or details.st_uid != os.getuid()
            or details.st_mode & 0o077
            or file_sha256(backup) != before_sha256
        ):
            raise MigrationError(f"Unsafe or mismatched receipt backup: {backup}")
    else:
        if file_sha256(source) != before_sha256:
            raise MigrationError(f"Consumer drift detected before backup: {source}")
        backup_regular_file(source, backup)
    return backup.read_bytes()


def apply_prepared_file(details: dict[str, Any], payload: bytes, mode: int) -> None:
    """Idempotently apply a file mutation authenticated by before/after hashes."""
    path = Path(details["path"])
    observed = file_sha256(path)
    if observed == details["after_sha256"]:
        return
    if observed != details["before_sha256"]:
        raise MigrationError(f"Consumer drift blocks apply: {path}")
    atomic_write(path, payload, mode=mode)
    if file_sha256(path) != details["after_sha256"]:
        raise MigrationError(f"Consumer verification failed after apply: {path}")


def prepare_repos_json(
    consumer: dict[str, Any], mappings: dict[str, str], backup: Path
) -> tuple[dict[str, Any], bytes]:
    """Prepare authenticated repository-registration bytes and rollback details."""
    path = Path(consumer["path"])
    original = ensure_file_backup(path, backup, consumer["sha256"])
    try:
        payload = json.loads(original)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MigrationError(f"Malformed JSON backup: {backup}") from exc
    changed = 0
    for item in payload.get("initialized_repos", []):
        if isinstance(item, dict) and item.get("path") in mappings:
            item["path"] = mappings[item["path"]]
            changed += 1
    encoded = json.dumps(payload, indent=2, ensure_ascii=False).encode() + b"\n"
    return (
        {
            "path": str(path),
            "backup": str(backup),
            "before_sha256": consumer["sha256"],
            "after_sha256": sha256_bytes(encoded),
            "changed": changed,
        },
        encoded,
    )


def load_tabby_module(script_path: Path) -> Any:
    """Load the existing Tabby implementation for exact path retargeting."""
    sys.path.insert(0, str(script_path.parent))
    specification = importlib.util.spec_from_file_location("aidevops_tabby_profile_sync", script_path)
    if specification is None or specification.loader is None:
        raise MigrationError("Could not load Tabby profile sync module")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def prepare_tabby(
    consumer: dict[str, Any], mappings: dict[str, str], backup: Path, script_path: Path
) -> tuple[dict[str, Any], bytes]:
    """Prepare authenticated Tabby bytes while preserving unrelated content."""
    path = Path(consumer["path"])
    original_bytes = ensure_file_backup(path, backup, consumer["sha256"])
    module = load_tabby_module(script_path)
    original = original_bytes.decode("utf-8")
    updated, changed = module.retarget_profile_cwds(original, mappings)
    encoded = updated.encode()
    return (
        {
            "path": str(path),
            "backup": str(backup),
            "before_sha256": consumer["sha256"],
            "after_sha256": sha256_bytes(encoded),
            "changed": changed,
        },
        encoded,
    )


def database_change_state(path: Path, changes: list[dict[str, str]]) -> str:
    """Classify exact guarded rows as wholly before, wholly after, or drifted."""
    states: set[str] = set()
    try:
        with sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=2) as connection:
            for change in changes:
                table, column = validated_sql_target(change["table"], change["column"])
                row = connection.execute(
                    f"SELECT {column} FROM {table} WHERE id = ?", (change["id"],)
                ).fetchone()
                if not row:
                    return "drift"
                if row[0] == change["value"]:
                    states.add("before")
                elif row[0] == change["after"]:
                    states.add("after")
                else:
                    return "drift"
    except sqlite3.Error as exc:
        raise MigrationError(f"Could not inspect OpenCode database: {path}") from exc
    if len(states) > 1:
        return "drift"
    return next(iter(states), "before")


def prepare_database(
    consumer: dict[str, Any], mappings: dict[str, str], backup: Path
) -> dict[str, Any]:
    """Prepare a database backup and deterministic guarded row changes."""
    path = Path(consumer["path"])
    private_directory(backup.parent)
    changes = [
        {**row, "after": mappings[row["value"]]}
        for row in consumer["rows"]
    ]
    if backup.exists():
        details = backup.lstat()
        if (
            backup.is_symlink()
            or not backup.is_file()
            or details.st_uid != os.getuid()
            or details.st_mode & 0o077
        ):
            raise MigrationError(f"Unsafe database backup: {backup}")
    else:
        if database_change_state(path, changes) != "before":
            raise MigrationError(f"OpenCode row drift detected: {path}")
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{backup.name}.", dir=backup.parent
        )
        os.close(descriptor)
        temporary = Path(temporary_name)
        temporary.unlink()
        try:
            with sqlite3.connect(path, timeout=2) as connection:
                with sqlite3.connect(temporary) as backup_connection:
                    connection.backup(backup_connection)
            temporary.chmod(0o600)
            with temporary.open("rb") as handle:
                os.fsync(handle.fileno())
            os.replace(temporary, backup)
        except (sqlite3.Error, OSError) as exc:
            raise MigrationError(f"OpenCode database backup failed: {path}") from exc
        finally:
            temporary.unlink(missing_ok=True)
    return {
        "path": str(path),
        "backup": str(backup),
        "backup_sha256": file_sha256(backup),
        "changes": changes,
    }


def update_database(details: dict[str, Any]) -> None:
    """Idempotently apply prepared exact OpenCode row changes."""
    path = Path(details["path"])
    state = database_change_state(path, details["changes"])
    if state == "after":
        return
    if state != "before":
        raise MigrationError(f"OpenCode row drift detected: {path}")
    try:
        connection = sqlite3.connect(path, timeout=2)
        connection.execute("BEGIN IMMEDIATE")
        for change in details["changes"]:
            table, column = validated_sql_target(change["table"], change["column"])
            query = f"UPDATE {table} SET {column} = ? WHERE id = ? AND {column} = ?"
            cursor = connection.execute(
                query, (change["after"], change["id"], change["value"])
            )
            if cursor.rowcount != 1:
                raise MigrationError(f"OpenCode row drift detected: {path}")
        integrity = connection.execute("PRAGMA integrity_check").fetchone()
        if not integrity or integrity[0] != "ok":
            raise MigrationError(f"SQLite integrity check failed: {path}")
        connection.commit()
    except (sqlite3.Error, OSError) as exc:
        if "connection" in locals() and connection.in_transaction:
            connection.rollback()
        raise MigrationError(f"OpenCode database update failed: {path}") from exc
    finally:
        if "connection" in locals():
            connection.close()
    if database_change_state(path, details["changes"]) != "after":
        raise MigrationError(f"OpenCode database verification failed: {path}")


def prepare_marker(
    consumer: dict[str, Any], mappings: dict[str, str], backup: Path
) -> tuple[dict[str, Any], bytes]:
    """Prepare authenticated schema-v1 recovery-marker bytes."""
    path = Path(consumer["path"])
    original = ensure_file_backup(path, backup, consumer["sha256"])
    try:
        payload = json.loads(original)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MigrationError(f"Malformed JSON backup: {backup}") from exc
    old = payload["directory"]
    payload["directory"] = mappings[old]
    encoded = canonical_bytes(payload)
    return (
        {
            "path": str(path),
            "backup": str(backup),
            "before_sha256": consumer["sha256"],
            "after_sha256": sha256_bytes(encoded),
            "before": old,
            "after": payload["directory"],
        },
        encoded,
    )


def maybe_inject_failure(key: str) -> None:
    """Provide deterministic fixture-only interruption boundaries."""
    requested = os.environ.get("AIDEVOPS_MIGRATE_FAIL_AFTER")
    if requested and requested == key:
        raise MigrationError(f"Injected failure after {key}")


def maybe_inject_post_mutation_failure(key: str) -> None:
    """Provide fixture-only termination after mutation but before completion."""
    requested = os.environ.get("AIDEVOPS_MIGRATE_FAIL_AFTER_MUTATION")
    if requested and requested == key:
        raise MigrationError(f"Injected failure after mutation {key}")


def apply_command(args: argparse.Namespace) -> int:
    """Apply or resume a confirmed plan."""
    plan_path = expand_path(args.plan)
    plan = load_json(plan_path)
    validate_plan(plan, args.confirm)
    receipt_id, receipt_dir, journal = receipt_paths(plan)
    private_directory(receipt_dir)
    lock = acquire_lock(plan, receipt_id)
    try:
        if journal.exists():
            events = read_events(journal, repair_incomplete_tail=True)
            if events:
                _stored_plan, events = validate_receipt_bundle(
                    receipt_id, receipt_dir, journal, expected_plan=plan
                )
            else:
                stored_plan_path = receipt_dir / "plan.json"
                assert_private_owned_path(stored_plan_path, directory=False)
                stored_plan = load_json(stored_plan_path)
                validate_plan(stored_plan, stored_plan.get("plan_sha256", ""))
                if canonical_bytes(stored_plan) != canonical_bytes(plan):
                    raise MigrationError("Empty receipt does not match its stored plan")
        else:
            events = []
        completed = done_keys(events)
        if not events:
            atomic_write(receipt_dir / "plan.json", canonical_bytes(plan))
            created = {
                "schema": RECEIPT_SCHEMA,
                "event": "created",
                "receipt_id": receipt_id,
                "plan_sha256": plan["plan_sha256"],
                "plan_path": str(plan_path),
            }
            append_event(journal, created)
            events.append(created)
        if "migration:complete" in completed:
            print(json.dumps(receipt_status(receipt_id, receipt_dir, journal), sort_keys=True))
            return 0
        assert_no_active_path(plan)
        workspace = Path(plan["workspace"])
        for index, item in enumerate(plan["repositories"]):
            key = f"repository:{index}"
            started = event_for_key(events, key)
            source = Path(item["source"])
            destination = Path(item["destination"])
            if started and key not in completed and not source.exists() and destination.exists():
                repair_linked_pointers(item, destination)
            validate_repository_plan(
                item, key in completed, workspace, bool(started)
            )
        validate_consumers(plan, completed, events)
        for index, item in enumerate(plan["repositories"]):
            key = f"repository:{index}"
            if key in completed:
                continue
            existing = event_for_key(events, key)
            details = (
                existing["details"]
                if existing
                else repository_step_details(item, workspace)
            )
            start_step(journal, events, key, details)
            move_repository(item, workspace, details)
            maybe_inject_post_mutation_failure(key)
            complete_step(journal, events, completed, key, details)
            maybe_inject_failure(key)

        mappings = migration_mappings(plan["repositories"])
        backups = receipt_dir / "backups"
        repos_consumer = plan["consumers"].get("repos_json")
        if repos_consumer and "consumer:repos_json" not in completed:
            key = "consumer:repos_json"
            details, payload = prepare_repos_json(
                repos_consumer, mappings, backups / "repos.json"
            )
            start_step(journal, events, key, details)
            apply_prepared_file(
                details, payload, mode=Path(details["path"]).stat().st_mode & 0o777
            )
            maybe_inject_post_mutation_failure(key)
            complete_step(journal, events, completed, key, details)
            maybe_inject_failure(key)
        tabby_consumer = plan["consumers"].get("tabby")
        if tabby_consumer and "consumer:tabby" not in completed:
            key = "consumer:tabby"
            tabby_script = Path(__file__).with_name("tabby-profile-sync.py")
            details, payload = prepare_tabby(
                tabby_consumer, mappings, backups / "tabby.yaml", tabby_script
            )
            start_step(journal, events, key, details)
            apply_prepared_file(
                details, payload, mode=Path(details["path"]).stat().st_mode & 0o777
            )
            maybe_inject_post_mutation_failure(key)
            complete_step(journal, events, completed, key, details)
            maybe_inject_failure(key)
        for index, consumer in enumerate(plan["consumers"].get("databases", [])):
            key = f"consumer:database:{index}"
            if key in completed:
                continue
            details = prepare_database(
                consumer, mappings, backups / f"opencode-{index}.db"
            )
            start_step(journal, events, key, details)
            update_database(details)
            maybe_inject_post_mutation_failure(key)
            complete_step(journal, events, completed, key, details)
            maybe_inject_failure(key)
        for index, consumer in enumerate(plan["consumers"].get("markers", [])):
            key = f"consumer:marker:{index}"
            if key in completed:
                continue
            details, payload = prepare_marker(
                consumer, mappings, backups / f"recovery-{index}.json"
            )
            start_step(journal, events, key, details)
            apply_prepared_file(details, payload, mode=0o600)
            maybe_inject_post_mutation_failure(key)
            complete_step(journal, events, completed, key, details)
            maybe_inject_failure(key)
        append_event(journal, {"event": "completed", "key": "migration:complete"})
        print(json.dumps(receipt_status(receipt_id, receipt_dir, journal), sort_keys=True))
        return 0
    finally:
        release_lock(lock)


def restore_file(details: dict[str, Any]) -> None:
    """Idempotently restore an authenticated backup without overwriting drift."""
    path = Path(details["path"])
    backup = Path(details["backup"])
    if file_sha256(backup) != details["before_sha256"]:
        raise MigrationError(f"Receipt backup drift blocks rollback: {backup}")
    observed = file_sha256(path)
    if observed == details["before_sha256"]:
        return
    if observed != details["after_sha256"]:
        raise MigrationError(f"Post-plan drift blocks rollback: {path}")
    atomic_write(path, backup.read_bytes(), mode=path.stat().st_mode & 0o777)
    if file_sha256(path) != details["before_sha256"]:
        raise MigrationError(f"File rollback verification failed: {path}")


def rollback_database(details: dict[str, Any]) -> None:
    """Idempotently reverse rows still holding receipt-owned after values."""
    path = Path(details["path"])
    state = database_change_state(path, details["changes"])
    if state == "before":
        return
    if state != "after":
        raise MigrationError(f"Post-plan database drift blocks rollback: {path}")
    try:
        connection = sqlite3.connect(path, timeout=2)
        connection.execute("BEGIN IMMEDIATE")
        for change in details["changes"]:
            table, column = validated_sql_target(change["table"], change["column"])
            query = f"UPDATE {table} SET {column} = ? WHERE id = ? AND {column} = ?"
            cursor = connection.execute(query, (change["value"], change["id"], change["after"]))
            if cursor.rowcount != 1:
                raise MigrationError(f"Post-plan database drift blocks rollback: {path}")
        integrity = connection.execute("PRAGMA integrity_check").fetchone()
        if not integrity or integrity[0] != "ok":
            raise MigrationError(f"SQLite integrity check failed: {path}")
        connection.commit()
    except sqlite3.Error as exc:
        if "connection" in locals() and connection.in_transaction:
            connection.rollback()
        raise MigrationError(f"Database rollback failed: {path}") from exc
    finally:
        if "connection" in locals():
            connection.close()
    if database_change_state(path, details["changes"]) != "before":
        raise MigrationError(f"Database rollback verification failed: {path}")


def restore_linked_pointers(details: dict[str, Any]) -> None:
    """Idempotently restore receipt-owned linked-worktree pointer content."""
    for pointer in details["pointer_changes"]:
        path = Path(pointer["path"])
        content = path.read_text(encoding="utf-8")
        if content == pointer["before"]:
            continue
        if content != pointer["after"]:
            raise MigrationError(f"Linked pointer drift blocks rollback: {path}")
        atomic_write(path, pointer["before"].encode(), mode=path.stat().st_mode & 0o777)


def rollback_repository(item: dict[str, Any], details: dict[str, Any]) -> None:
    """Idempotently return an unchanged repository and pointers to its source."""
    source = Path(item["source"])
    destination = Path(item["destination"])
    stage = Path(item["stage"])
    self_nested = bool(details.get("self_nested"))
    case_only_same = (
        source != destination
        and str(source).lower() == str(destination).lower()
        and same_existing_path(source, destination)
    )
    if source.is_dir() and not destination.exists() and not stage.exists():
        restore_linked_pointers(details)
    elif stage.is_dir() and not source.exists() and not destination.exists():
        if not self_nested:
            raise MigrationError(f"Unexpected rollback stage: {stage}")
    elif destination.is_dir() and (
        not source.exists() or self_nested or case_only_same
    ):
        if repository_fingerprint(destination) != details["post_fingerprint"]:
            raise MigrationError(f"Post-plan repository drift blocks rollback: {destination}")
        for pointer in details["pointer_changes"]:
            if Path(pointer["path"]).read_text(encoding="utf-8") != pointer["after"]:
                raise MigrationError(
                    f"Linked pointer drift blocks rollback: {pointer['path']}"
                )
        if self_nested:
            os.rename(destination, stage)
        else:
            os.rename(destination, source)
    else:
        raise MigrationError(f"Repository rollback collision or missing destination: {source}")
    if self_nested and stage.exists():
        for directory_name in details.get("created_directories", []):
            directory = Path(directory_name)
            if not directory.exists():
                continue
            try:
                directory.rmdir()
            except OSError as exc:
                raise MigrationError(
                    f"Unexpected content blocks nested rollback: {directory}"
                ) from exc
        if source.exists():
            raise MigrationError(f"Nested rollback source remains occupied: {source}")
        os.rename(stage, source)
    restore_linked_pointers(details)
    if repository_fingerprint(source) != item["fingerprint"]:
        raise MigrationError(f"Repository rollback verification failed: {source}")
    if not self_nested:
        for directory_name in details.get("created_directories", []):
            directory = Path(directory_name)
            try:
                directory.rmdir()
            except OSError:
                pass


def assert_private_owned_path(path: Path, *, directory: bool) -> None:
    """Require an existing non-symlink owner-private file or directory."""
    try:
        details = path.lstat()
    except OSError as exc:
        raise MigrationError(f"Receipt path is unavailable: {path}") from exc
    expected_type = stat.S_ISDIR(details.st_mode) if directory else stat.S_ISREG(details.st_mode)
    if (
        path.is_symlink()
        or not expected_type
        or details.st_uid != os.getuid()
        or details.st_mode & 0o077
    ):
        raise MigrationError(f"Receipt path is not owner-private: {path}")


def validate_receipt_event_targets(
    plan: dict[str, Any], directory: Path, events: list[dict[str, Any]]
) -> None:
    """Bind every receipt event to exact paths and rows from its stored plan."""
    mappings = migration_mappings(plan["repositories"])
    expected: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(plan["repositories"]):
        expected[f"repository:{index}"] = {"kind": "repository", "item": item}
    consumers = plan["consumers"]
    if consumers.get("repos_json"):
        expected["consumer:repos_json"] = {
            "kind": "file",
            "path": consumers["repos_json"]["path"],
            "backup": str(directory / "backups/repos.json"),
        }
    if consumers.get("tabby"):
        expected["consumer:tabby"] = {
            "kind": "file",
            "path": consumers["tabby"]["path"],
            "backup": str(directory / "backups/tabby.yaml"),
        }
    for index, consumer in enumerate(consumers.get("databases", [])):
        expected[f"consumer:database:{index}"] = {
            "kind": "database",
            "path": consumer["path"],
            "backup": str(directory / f"backups/opencode-{index}.db"),
            "changes": [
                {**row, "after": mappings[row["value"]]} for row in consumer["rows"]
            ],
        }
    for index, consumer in enumerate(consumers.get("markers", [])):
        expected[f"consumer:marker:{index}"] = {
            "kind": "file",
            "path": consumer["path"],
            "backup": str(directory / f"backups/recovery-{index}.json"),
        }
    for event in events[1:]:
        if event.get("event") not in {"started", "completed"}:
            raise MigrationError("Receipt contains an unsupported event")
        key = str(event.get("key", ""))
        base_key = key.removeprefix("rollback:")
        if base_key in {"migration:complete", "migration:rolled-back"}:
            continue
        target = expected.get(base_key)
        details = event.get("details")
        if not target or not isinstance(details, dict):
            raise MigrationError(f"Receipt contains an unsupported step: {key}")
        if target["kind"] == "repository":
            item = target["item"]
            if (
                details.get("source") != item["source"]
                or details.get("destination") != item["destination"]
                or details.get("post_fingerprint") != item["fingerprint"]
                or bool(details.get("self_nested"))
                != (path_is_inside(Path(item["source"]), Path(item["destination"])) and item["source"] != item["destination"])
            ):
                raise MigrationError(f"Receipt repository target mismatch: {key}")
            planned_pointers = {entry["path"]: entry["content"] for entry in item["linked_pointers"]}
            for pointer in details.get("pointer_changes", []):
                before = planned_pointers.get(pointer.get("path"))
                expected_after = (
                    before.replace(
                        f"gitdir: {item['source']}/.git/",
                        f"gitdir: {item['destination']}/.git/",
                        1,
                    )
                    if before
                    else None
                )
                if pointer.get("before") != before or pointer.get("after") != expected_after:
                    raise MigrationError(f"Receipt linked pointer target mismatch: {key}")
            if len(details.get("pointer_changes", [])) != len(planned_pointers):
                raise MigrationError(f"Receipt linked pointer set mismatch: {key}")
            workspace = Path(plan["workspace"])
            destination_parent = Path(item["destination"]).parent
            for created in details.get("created_directories", []):
                created_path = Path(created)
                if (
                    created_path == workspace
                    or not path_is_inside(workspace, created_path)
                    or not path_is_inside(created_path, destination_parent)
                ):
                    raise MigrationError(f"Receipt directory target mismatch: {key}")
        else:
            if details.get("path") != target["path"] or details.get("backup") != target["backup"]:
                raise MigrationError(f"Receipt consumer target mismatch: {key}")
            if target["kind"] == "database" and details.get("changes") != target["changes"]:
                raise MigrationError(f"Receipt database target mismatch: {key}")


def validate_receipt_bundle(
    receipt_id: str,
    directory: Path,
    journal: Path,
    expected_plan: dict[str, Any] | None = None,
    repair_incomplete_tail: bool = False,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Authenticate an owner-private receipt against its immutable stored plan."""
    assert_private_owned_path(directory.parent, directory=True)
    assert_private_owned_path(directory, directory=True)
    plan_path = directory / "plan.json"
    assert_private_owned_path(plan_path, directory=False)
    assert_private_owned_path(journal, directory=False)
    plan = load_json(plan_path)
    validate_plan(plan, plan.get("plan_sha256", ""))
    expected_id, expected_directory, expected_journal = receipt_paths(plan)
    if (
        receipt_id != expected_id
        or directory != expected_directory
        or journal != expected_journal
        or expand_path(plan["state_dir"]) != directory.parent
        or (expected_plan is not None and canonical_bytes(expected_plan) != canonical_bytes(plan))
    ):
        raise MigrationError("Receipt does not match its stored plan")
    events = read_events(journal, repair_incomplete_tail=repair_incomplete_tail)
    if not events:
        raise MigrationError("Receipt journal has no complete creation event")
    created = events[0]
    if (
        created.get("event") != "created"
        or created.get("receipt_id") != receipt_id
        or created.get("plan_sha256") != plan["plan_sha256"]
    ):
        raise MigrationError("Receipt creation event does not match its stored plan")
    validate_receipt_event_targets(plan, directory, events)
    return plan, events


def locate_receipt(receipt: str, state_dir: str | None) -> tuple[str, Path, Path]:
    """Resolve only a strict receipt ID below the configured private state root."""
    if not re.fullmatch(r"layout-[a-f0-9]{32}", receipt):
        raise MigrationError("Invalid receipt ID")
    root = (
        expand_path(state_dir)
        if state_dir
        else Path.home() / ".aidevops/.agent-workspace/work/repo-layout-migrations"
    )
    receipt_id = receipt
    directory = root / receipt_id
    return receipt_id, directory, directory / "receipt.jsonl"


def receipt_status(receipt_id: str, directory: Path, journal: Path) -> dict[str, Any]:
    """Return machine-readable receipt state and its current confirmation hash."""
    _plan, events = validate_receipt_bundle(receipt_id, directory, journal)
    completed = done_keys(events)
    if "migration:rolled-back" in completed:
        state = "rolled-back"
    elif "migration:complete" in completed:
        state = "applied"
    else:
        state = "partial"
    created = events[0]
    if state == "partial":
        next_actions = [
            {
                "action": "resume",
                "plan": created.get("plan_path"),
                "confirm": created.get("plan_sha256"),
            },
            {"action": "rollback", "confirm": file_sha256(journal)},
        ]
    elif state == "applied":
        next_actions = [{"action": "rollback", "confirm": file_sha256(journal)}]
    else:
        next_actions = []
    return {
        "receipt_id": receipt_id,
        "state": state,
        "last_verified_step": next(
            (event.get("key", event.get("event")) for event in reversed(events)), "created"
        ),
        "receipt_sha256": file_sha256(journal),
        "receipt_directory": str(directory),
        "next_actions": next_actions,
    }


def status_command(args: argparse.Namespace) -> int:
    """Print current receipt state."""
    receipt_id, directory, journal = locate_receipt(args.receipt, args.state_dir)
    print(json.dumps(receipt_status(receipt_id, directory, journal), sort_keys=True))
    return 0


def run_rollback_step(
    journal: Path,
    events: list[dict[str, Any]],
    completed: set[str],
    key: str,
    details: dict[str, Any],
    operation: Any,
) -> None:
    """Persist, execute, and complete one idempotent rollback step."""
    rollback_key = f"rollback:{key}"
    if rollback_key in completed:
        return
    start_step(journal, events, rollback_key, details)
    operation(details)
    maybe_inject_post_mutation_failure(rollback_key)
    complete_step(journal, events, completed, rollback_key, details)


def rollback_command(args: argparse.Namespace) -> int:
    """Mechanically reverse receipt-owned changes after exact confirmation."""
    receipt_id, directory, journal = locate_receipt(args.receipt, args.state_dir)
    plan, _events = validate_receipt_bundle(receipt_id, directory, journal)
    lock = acquire_lock(plan, receipt_id)
    try:
        if file_sha256(journal) != args.confirm:
            raise MigrationError("Receipt SHA-256 confirmation does not match")
        plan, events = validate_receipt_bundle(
            receipt_id, directory, journal, repair_incomplete_tail=True
        )
        completed = done_keys(events)
        if "migration:rolled-back" in completed:
            print(json.dumps(receipt_status(receipt_id, directory, journal), sort_keys=True))
            return 0
        assert_no_active_path(plan)
        for index in reversed(range(len(plan["consumers"].get("markers", [])))):
            key = f"consumer:marker:{index}"
            event = event_for_key(events, key)
            if event:
                run_rollback_step(
                    journal, events, completed, key, event["details"], restore_file
                )
        for index in reversed(range(len(plan["consumers"].get("databases", [])))):
            key = f"consumer:database:{index}"
            event = event_for_key(events, key)
            if event:
                run_rollback_step(
                    journal,
                    events,
                    completed,
                    key,
                    event["details"],
                    rollback_database,
                )
        for key in ("consumer:tabby", "consumer:repos_json"):
            event = event_for_key(events, key)
            if event:
                run_rollback_step(
                    journal, events, completed, key, event["details"], restore_file
                )
        for index in reversed(range(len(plan["repositories"]))):
            key = f"repository:{index}"
            event = event_for_key(events, key)
            if event:
                run_rollback_step(
                    journal,
                    events,
                    completed,
                    key,
                    event["details"],
                    lambda details, item=plan["repositories"][index]: rollback_repository(
                        item, details
                    ),
                )
        append_event(journal, {"event": "completed", "key": "migration:rolled-back"})
        print(json.dumps(receipt_status(receipt_id, directory, journal), sort_keys=True))
        return 0
    finally:
        release_lock(lock)


def build_parser() -> argparse.ArgumentParser:
    """Build the versioned command-line contract."""
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    plan = subparsers.add_parser("plan")
    plan.add_argument("--workspace", required=True)
    plan.add_argument("--output", required=True)
    plan.add_argument("--include-registered-paths", action="store_true")
    plan.add_argument("--repos-json")
    plan.add_argument("--tabby-config")
    plan.add_argument("--opencode-db")
    plan.add_argument("--isolated-root")
    plan.add_argument("--recovery-root")
    plan.add_argument("--state-dir")
    plan.add_argument("--discovery-lib", required=True)
    plan.set_defaults(handler=plan_command)
    apply = subparsers.add_parser("apply")
    apply.add_argument("--plan", required=True)
    apply.add_argument("--confirm", required=True)
    apply.add_argument("--discovery-lib", required=True)
    apply.set_defaults(handler=apply_command)
    rollback = subparsers.add_parser("rollback")
    rollback.add_argument("--receipt", required=True)
    rollback.add_argument("--confirm", required=True)
    rollback.add_argument("--state-dir")
    rollback.add_argument("--discovery-lib", required=True)
    rollback.set_defaults(handler=rollback_command)
    status = subparsers.add_parser("status")
    status.add_argument("--receipt", required=True)
    status.add_argument("--state-dir")
    status.add_argument("--discovery-lib", required=True)
    status.set_defaults(handler=status_command)
    return parser


def main() -> int:
    """Run one migration command with concise fail-closed diagnostics."""
    arguments = build_parser().parse_args()
    try:
        return int(arguments.handler(arguments))
    except MigrationError as exc:
        print(f"repo layout migration refused: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
