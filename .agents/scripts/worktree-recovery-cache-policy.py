#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Classify and prune explicitly regenerable worktree cache directories."""

import json
import os
from pathlib import Path, PurePosixPath
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import time
from typing import Callable, Dict, List, NamedTuple, Optional, Set, Tuple

CACHE_MANIFEST_SCHEMA = "aidevops.worktree-recovery-cache-manifest/v1"
GIT_OUTPUT_MAX_BYTES = 1024 * 1024
GIT_OUTPUT_LIMIT_RC = 125


class RootExpectation(NamedTuple):
    """Immutable cache-root identity and allocation evidence."""

    identity: str
    allocated_bytes: int


SAFE_COMPONENTS = {
    "node_modules",
    ".pnpm-store",
    ".turbo",
    ".parcel-cache",
    ".vite",
    "__pycache__",
    ".pytest_cache",
}
SAFE_CHAINS = {(".yarn", "cache"), (".next", "cache"), (".nuxt", "cache")}
SAFE_REPOSITORY_ROOTS = {".codegraph"}


def safe_root(raw_path: str) -> Optional[Tuple[str, ...]]:
    """Return the narrow recognised cache root containing a status path."""
    parts = PurePosixPath(raw_path.rstrip("/")).parts
    if not parts or parts[0] in {"/", ".", ".."} or ".." in parts:
        return None
    if parts[0] in SAFE_REPOSITORY_ROOTS:
        return parts[:1]
    for index, part in enumerate(parts):
        if part in SAFE_COMPONENTS:
            return parts[: index + 1]
        for chain in SAFE_CHAINS:
            if tuple(parts[index : index + len(chain)]) == chain:
                return parts[: index + len(chain)]
    return None


def ordinary_directory(root: Path, relative_parts: Tuple[str, ...]) -> Optional[Path]:
    """Resolve a directory without traversing any symlink component."""
    candidate = root
    for part in relative_parts:
        candidate = candidate / part
        if candidate.is_symlink():
            return None
    return candidate if candidate.is_dir() else None


def status_records(raw: bytes):
    """Yield porcelain state and path records without losing unusual filenames."""
    for record in raw.split(b"\0"):
        if not record:
            continue
        if len(record) < 4:
            yield b"??", ""
            continue
        yield record[:2], os.fsdecode(record[3:])


def status_bytes_have_user_data(
    raw_status: bytes,
    archive_root: Path,
    git_bin: str,
    deadline_epoch: Optional[int] = None,
) -> int:
    """Return 0 for protected data, 1 for recognised caches only, 2 on uncertainty."""
    checked: Set[Tuple[str, ...]] = set()
    for state, relative_path in status_records(raw_status):
        root_parts = safe_root(relative_path) if state == b"!!" else None
        if root_parts is None or ordinary_directory(archive_root, root_parts) is None:
            return 0
        if root_parts in checked:
            continue
        tracked_rc, tracked = git_output(
            git_bin,
            archive_root,
            ["ls-files", "-z", "--", "/".join(root_parts)],
            deadline_epoch,
        )
        if tracked_rc != 0:
            return 2
        if tracked:
            return 0
        checked.add(root_parts)
    return 1


def status_has_user_data(status_path: Path, archive_root: Path, git_bin: str) -> int:
    """Classify a previously captured status file."""
    try:
        raw_status = status_path.read_bytes()
    except OSError:
        return 2
    return status_bytes_have_user_data(raw_status, archive_root, git_bin)


def bounded_git_state(
    archive_root: Path, git_bin: str, deadline_epoch: Optional[int]
) -> int:
    """Classify current Git state without an unbounded status capture."""
    status_rc, raw_status = git_output(
        git_bin,
        archive_root,
        ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"],
        deadline_epoch,
    )
    if status_rc != 0:
        return 2
    return status_bytes_have_user_data(raw_status, archive_root, git_bin, deadline_epoch)


def stop_process(process: subprocess.Popen) -> None:
    """Stop a Git process group after a resource limit is reached."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (OSError, ProcessLookupError):
        pass
    try:
        process.wait(timeout=0.2)
        stopped = True
    except subprocess.TimeoutExpired:
        stopped = False
    if not stopped:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            pass
        try:
            process.wait(timeout=0.2)
        except subprocess.TimeoutExpired:
            pass


def start_git_process(
    git_bin: str, source_root: Path, arguments: List[str]
) -> Optional[subprocess.Popen]:
    """Start one structured, non-shell Git query."""
    git_environment = os.environ.copy()
    git_environment["GIT_OPTIONAL_LOCKS"] = "0"
    try:
        # The trusted caller resolves git_bin; structured argv disables shell parsing.
        process = subprocess.Popen(
            [git_bin, "-C", str(source_root), *arguments],
            env=git_environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )  # nosec B603
    except OSError:
        return None
    return process


def stream_wait_seconds(deadline_epoch: Optional[int]) -> Optional[float]:
    """Return a short stream wait or None once the shared deadline expires."""
    if deadline_epoch is None:
        return 0.1
    remaining = deadline_epoch - time.time()
    return min(0.1, remaining) if remaining > 0 else None


def bounded_stream_output(
    process: subprocess.Popen,
    selector: selectors.BaseSelector,
    deadline_epoch: Optional[int],
) -> Tuple[Optional[int], bytearray]:
    """Read bounded stdout, returning a terminal limit code or EOF marker."""
    output = bytearray()
    while True:
        wait_seconds = stream_wait_seconds(deadline_epoch)
        if wait_seconds is None:
            return 124, bytearray()
        events = selector.select(wait_seconds)
        if not events:
            continue
        chunk = os.read(process.stdout.fileno(), 65536)
        if not chunk:
            return None, output
        output.extend(chunk)
        if len(output) > GIT_OUTPUT_MAX_BYTES:
            return GIT_OUTPUT_LIMIT_RC, bytearray()


def wait_for_process(
    process: subprocess.Popen, deadline_epoch: Optional[int]
) -> int:
    """Wait for process completion without extending the shared deadline."""
    wait_timeout = None
    if deadline_epoch is not None:
        wait_timeout = max(0.0, deadline_epoch - time.time())
    try:
        return process.wait(timeout=wait_timeout)
    except subprocess.TimeoutExpired:
        return 124


def read_process_output(
    process: subprocess.Popen, deadline_epoch: Optional[int]
) -> Tuple[int, bytes]:
    """Capture bounded process output until EOF or the shared deadline."""
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        terminal_rc, output = bounded_stream_output(process, selector, deadline_epoch)
        if terminal_rc is None:
            terminal_rc = wait_for_process(process, deadline_epoch)
        if terminal_rc in {124, GIT_OUTPUT_LIMIT_RC}:
            stop_process(process)
            output.clear()
    finally:
        selector.close()
        process.stdout.close()
    return terminal_rc, bytes(output)


def git_output(
    git_bin: str,
    source_root: Path,
    arguments: List[str],
    deadline_epoch: Optional[int] = None,
) -> Tuple[int, bytes]:
    """Run one read-only Git query with bounded captured output."""
    if deadline_epoch is not None and deadline_epoch <= time.time():
        return 124, b""
    process = start_git_process(git_bin, source_root, arguments)
    if process is None or process.stdout is None:
        if process is not None:
            stop_process(process)
        return 2, b""
    return read_process_output(process, deadline_epoch)


def allocated_entry(
    root: Path, current: Path, deadline_epoch: int
) -> Optional[Tuple[int, List[Path]]]:
    """Measure one safe filesystem entry and return its children."""
    try:
        if time.time() >= deadline_epoch:
            raise ValueError("allocation deadline expired")
        metadata = current.lstat()
        if current == root:
            if not stat.S_ISDIR(metadata.st_mode):
                raise ValueError("cache root is not a directory")
            if current.is_symlink():
                raise ValueError("cache root is a symlink")
        if stat.S_ISREG(metadata.st_mode) and metadata.st_nlink != 1:
            raise ValueError("cache entry is hard linked")
        children: List[Path] = []
        if stat.S_ISDIR(metadata.st_mode):
            with os.scandir(current) as entries:
                children = [Path(entry.path) for entry in entries]
    except (OSError, ValueError):
        return None
    return metadata.st_blocks * 512, children


def allocated_bytes(root: Path, deadline_epoch: int) -> Optional[int]:
    """Measure allocated bytes without following symlink entries or hard links."""
    total = 0
    stack = [root]
    while stack:
        current = stack.pop()
        measurement = allocated_entry(root, current, deadline_epoch)
        if measurement is None:
            return None
        allocated, children = measurement
        total += allocated
        stack.extend(children)
    return total


def exact_safe_root(relative_path: str) -> Optional[Tuple[str, ...]]:
    """Return a safe root only when the supplied path is exactly that root."""
    parts = PurePosixPath(relative_path).parts
    return parts if safe_root(relative_path) == parts else None


def root_identity(path: Path) -> Optional[str]:
    """Return a non-following device/inode identity for an ordinary directory."""
    try:
        metadata = path.lstat()
    except OSError:
        return None
    if not stat.S_ISDIR(metadata.st_mode) or path.is_symlink():
        return None
    return f"{metadata.st_dev}:{metadata.st_ino}"


def ignored_untracked_root(
    archive_root: Path,
    relative_root: str,
    git_bin: str,
    deadline_epoch: int,
) -> bool:
    """Prove that an exact approved root is ignored and contains no tracked path."""
    ignored_rc, _ = git_output(
        git_bin, archive_root, ["check-ignore", "-q", "--", relative_root], deadline_epoch
    )
    if ignored_rc != 0:
        return False
    tracked_rc, tracked = git_output(
        git_bin, archive_root, ["ls-files", "-z", "--", relative_root], deadline_epoch
    )
    return tracked_rc == 0 and not tracked


def discovered_cache_roots(raw_status: bytes) -> Set[Tuple[str, ...]]:
    """Collect recognised ignored cache roots from bounded status output."""
    roots: Set[Tuple[str, ...]] = set()
    for state_value, relative_path in status_records(raw_status):
        root_parts = safe_root(relative_path) if state_value == b"!!" else None
        if root_parts is not None:
            roots.add(root_parts)
    return roots


def manifest_candidate(
    archive_root: Path,
    root_parts: Tuple[str, ...],
    git_bin: str,
    deadline_epoch: int,
) -> Optional[dict]:
    """Build one candidate only after identity and Git safety proofs pass."""
    relative_root = "/".join(root_parts)
    candidate = ordinary_directory(archive_root, root_parts)
    if candidate is None or not ignored_untracked_root(
        archive_root, relative_root, git_bin, deadline_epoch
    ):
        return None
    identity = root_identity(candidate)
    measured_bytes = allocated_bytes(candidate, deadline_epoch)
    if identity is None or measured_bytes is None or measured_bytes <= 0:
        return None
    return {
        "relative_path": relative_root,
        "expected_allocated_bytes": measured_bytes,
        "path_identity": identity,
    }


def cache_manifest(
    archive_root: Path,
    git_bin: str,
    max_roots: int,
    max_bytes: int,
    deadline_epoch: int,
) -> Optional[dict]:
    """Build a bounded typed manifest of currently safe cache roots."""
    if not archive_root.is_absolute() or not archive_root.is_dir():
        return None
    if archive_root.is_symlink() or max_roots < 1 or max_bytes < 1:
        return None
    if time.time() >= deadline_epoch:
        return None
    status_rc, raw_status = git_output(
        git_bin,
        archive_root,
        ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"],
        deadline_epoch,
    )
    if status_rc != 0:
        return None
    roots = discovered_cache_roots(raw_status)
    selected = []
    selected_bytes = 0
    inspected = 0
    deferred = 0
    deadline_exhausted = False
    for root_parts in sorted(roots):
        if time.time() >= deadline_epoch:
            deadline_exhausted = True
            deferred += len(roots) - inspected
            break
        inspected += 1
        candidate = manifest_candidate(
            archive_root, root_parts, git_bin, deadline_epoch
        )
        if candidate is None:
            continue
        measured_bytes = candidate["expected_allocated_bytes"]
        if len(selected) >= max_roots or selected_bytes + measured_bytes > max_bytes:
            deferred += 1
            continue
        selected.append(candidate)
        selected_bytes += measured_bytes
    return {
        "schema": CACHE_MANIFEST_SCHEMA,
        "complete": not deadline_exhausted,
        "deadline_exhausted": deadline_exhausted,
        "inspected_root_count": inspected,
        "deferred_root_count": deferred,
        "candidate_count": len(selected),
        "candidate_bytes": selected_bytes,
        "entries": selected,
    }


def validate_original_root(
    archive_root: Path,
    relative_path: str,
    expected: RootExpectation,
    git_bin: str,
    deadline_epoch: int,
) -> int:
    """Revalidate one manifest root immediately before it is staged."""
    root_parts = exact_safe_root(relative_path)
    if root_parts is None or time.time() >= deadline_epoch:
        return 2
    candidate = ordinary_directory(archive_root, root_parts)
    if candidate is None or not ignored_untracked_root(
        archive_root, relative_path, git_bin, deadline_epoch
    ):
        return 2
    measured_bytes = allocated_bytes(candidate, deadline_epoch)
    if root_identity(candidate) != expected.identity:
        return 2
    if measured_bytes != expected.allocated_bytes:
        return 2
    return 0


def validate_staged_root(
    staged_path: Path,
    expected_identity: str,
    expected_bytes: int,
    deadline_epoch: int,
) -> int:
    """Validate one already-staged cache root for interruption recovery."""
    if not staged_path.is_absolute() or time.time() >= deadline_epoch:
        return 2
    measured_bytes = allocated_bytes(staged_path, deadline_epoch)
    if root_identity(staged_path) != expected_identity or measured_bytes != expected_bytes:
        return 2
    return 0


def measure_staged_root(
    staged_path: Path,
    expected_identity: str,
    expected_bytes: int,
    deadline_epoch: int,
) -> Optional[int]:
    """Return the exact current allocation for one validated staged root."""
    if not staged_path.is_absolute() or time.time() >= deadline_epoch:
        return None
    measured_bytes = allocated_bytes(staged_path, deadline_epoch)
    if root_identity(staged_path) != expected_identity or measured_bytes != expected_bytes:
        return None
    return measured_bytes


def validate_removing_root(
    staged_path: Path,
    expected_identity: str,
    expected_bytes: int,
    deadline_epoch: int,
) -> int:
    """Validate an isolated cache root that may be partly removed on retry."""
    if not staged_path.is_absolute() or time.time() >= deadline_epoch:
        return 2
    if not staged_path.exists() and not staged_path.is_symlink():
        return 0
    measured_bytes = allocated_bytes(staged_path, deadline_epoch)
    if root_identity(staged_path) != expected_identity or measured_bytes is None:
        return 2
    if measured_bytes > expected_bytes:
        return 2
    return 0


def validate_removed_root(staged_path: Path, deadline_epoch: int) -> int:
    """Prove the staged namespace has zero remaining allocated bytes."""
    if not staged_path.is_absolute() or time.time() >= deadline_epoch:
        return 2
    return 0 if not staged_path.exists() and not staged_path.is_symlink() else 2


def prune_caches(source_root: Path, archive_root: Path, git_bin: str) -> int:
    """Remove only ignored, untracked, recognised cache roots from an archive copy."""
    status_rc, raw_status = git_output(
        git_bin,
        source_root,
        ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"],
    )
    if status_rc != 0:
        return 2
    pruned: Set[Tuple[str, ...]] = set()
    for state, relative_path in status_records(raw_status):
        root_parts = safe_root(relative_path) if state == b"!!" else None
        if root_parts is None or root_parts in pruned:
            continue
        relative_root = "/".join(root_parts)
        tracked_rc, tracked = git_output(
            git_bin, source_root, ["ls-files", "-z", "--", relative_root]
        )
        if tracked_rc != 0:
            return 2
        if tracked:
            continue
        candidate = ordinary_directory(archive_root, root_parts)
        if candidate is None:
            continue
        try:
            shutil.rmtree(candidate)
        except OSError:
            return 2
        pruned.add(root_parts)
    return 0


def handle_legacy_mode(arguments: List[str]) -> int:
    """Handle the original status and prune command shapes."""
    if len(arguments) == 4:
        mode, source_raw, archive_raw, git_bin = arguments
        archive_root = Path(archive_raw)
        if not archive_root.is_dir() or archive_root.is_symlink():
            return 2
        if mode == "status":
            return status_has_user_data(Path(source_raw), archive_root, git_bin)
        source_root = Path(source_raw)
        if not source_root.is_dir() or source_root.is_symlink():
            return 2
        return prune_caches(source_root, archive_root, git_bin)
    return 2


def handle_git_state(arguments: List[str]) -> int:
    """Handle bounded current Git-state classification."""
    if len(arguments) == 4:
        _, archive_raw, git_bin, deadline_raw = arguments
        archive_root = Path(archive_raw)
        if not archive_root.is_dir() or archive_root.is_symlink():
            return 2
        try:
            deadline_value = int(deadline_raw)
        except ValueError:
            return 2
        deadline_epoch = deadline_value if deadline_value > 0 else None
        return bounded_git_state(archive_root, git_bin, deadline_epoch)
    return 2


def handle_manifest(arguments: List[str]) -> int:
    """Handle bounded cache-manifest generation."""
    if len(arguments) == 6:
        _, archive_raw, git_bin, max_roots_raw, max_bytes_raw, deadline_raw = arguments
        try:
            manifest = cache_manifest(
                Path(archive_raw),
                git_bin,
                int(max_roots_raw),
                int(max_bytes_raw),
                int(deadline_raw),
            )
        except ValueError:
            return 2
        if manifest is None:
            return 2
        print(json.dumps(manifest, sort_keys=True, separators=(",", ":")))
        return 0
    return 2


def handle_validate_original(arguments: List[str]) -> int:
    """Handle immediate original-root revalidation."""
    if len(arguments) == 7:
        _, archive_raw, relative_path, identity, bytes_raw, git_bin, deadline_raw = (
            arguments
        )
        try:
            return validate_original_root(
                Path(archive_raw),
                relative_path,
                RootExpectation(identity, int(bytes_raw)),
                git_bin,
                int(deadline_raw),
            )
        except ValueError:
            return 2
    return 2


def handle_validate_staged(arguments: List[str]) -> int:
    """Handle exact staged-root validation."""
    if len(arguments) == 5:
        _, staged_raw, identity, bytes_raw, deadline_raw = arguments
        try:
            return validate_staged_root(
                Path(staged_raw), identity, int(bytes_raw), int(deadline_raw)
            )
        except ValueError:
            return 2
    return 2


def handle_measure_staged(arguments: List[str]) -> int:
    """Handle independently measured staged allocation."""
    if len(arguments) == 5:
        _, staged_raw, identity, bytes_raw, deadline_raw = arguments
        try:
            measured_bytes = measure_staged_root(
                Path(staged_raw), identity, int(bytes_raw), int(deadline_raw)
            )
        except ValueError:
            return 2
        if measured_bytes is None:
            return 2
        print(measured_bytes)
        return 0
    return 2


def handle_validate_removing(arguments: List[str]) -> int:
    """Handle partially removed root validation."""
    if len(arguments) == 5:
        _, staged_raw, identity, bytes_raw, deadline_raw = arguments
        try:
            return validate_removing_root(
                Path(staged_raw), identity, int(bytes_raw), int(deadline_raw)
            )
        except ValueError:
            return 2
    return 2


def handle_validate_removed(arguments: List[str]) -> int:
    """Handle post-delete namespace validation."""
    if len(arguments) == 3:
        _, staged_raw, deadline_raw = arguments
        try:
            return validate_removed_root(Path(staged_raw), int(deadline_raw))
        except ValueError:
            return 2
    return 2


MODE_HANDLERS: Dict[str, Callable[[List[str]], int]] = {
    "status": handle_legacy_mode,
    "prune": handle_legacy_mode,
    "git-state": handle_git_state,
    "manifest": handle_manifest,
    "validate-original": handle_validate_original,
    "validate-staged": handle_validate_staged,
    "measure-staged": handle_measure_staged,
    "validate-removing": handle_validate_removing,
    "validate-removed": handle_validate_removed,
}


def main() -> int:
    """Dispatch one fail-closed cache-policy mode."""
    arguments = sys.argv[1:]
    mode = arguments[0] if arguments else ""
    handler = MODE_HANDLERS.get(mode)
    if handler is None:
        return 2
    return handler(arguments)


if __name__ == "__main__":
    raise SystemExit(main())
