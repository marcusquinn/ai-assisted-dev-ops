#!/usr/bin/env python3
"""Race-safe plaintext credential store operations.

This helper never prints credential values. It serializes writes under one
config-wide lock, keeps a protected pre-write backup, and atomically replaces
complete files from a unique same-directory temporary file.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import time


EXPORT_RE = re.compile(r"^export[ \t]+([A-Z][A-Z0-9_]*)=(.*)$")
TENANT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")


class StoreError(RuntimeError):
    """A credential-store error whose message contains no credential value."""


def validate_contained_path(config_dir: Path, path: Path) -> None:
    config_real = config_dir.resolve()
    candidate = path.resolve(strict=False)
    if candidate != config_real and config_real not in candidate.parents:
        raise StoreError("credential path escapes the configuration directory")
    current = path
    while current != config_dir.parent:
        if current.exists() and current.is_symlink():
            raise StoreError("credential path contains a symlink")
        if current == config_dir:
            break
        current = current.parent


def validate_existing_file(path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        raise StoreError("credential source must be a regular non-symlink file")
    metadata = path.stat()
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) & 0o077:
        raise StoreError("credential source must be owner-only")


def ensure_private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or not path.is_dir() or path.stat().st_uid != os.getuid():
        raise StoreError("credential directory is unsafe")
    os.chmod(path, 0o700)


@contextlib.contextmanager
def store_lock(config_dir: Path):
    ensure_private_directory(config_dir)
    lock_path = config_dir / ".credentials.lock"
    if lock_path.is_symlink():
        raise StoreError("credential lock path is unsafe")
    flags = os.O_CREAT | os.O_RDWR
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(lock_path, flags, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def atomic_write(path: Path, content: str) -> None:
    ensure_private_directory(path.parent)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        temporary.unlink(missing_ok=True)


def backup(config_dir: Path, path: Path) -> None:
    if not path.exists():
        return
    validate_existing_file(path)
    recovery = config_dir / "vault" / "recovery"
    ensure_private_directory(config_dir / "vault")
    ensure_private_directory(recovery)
    relative = "-".join(path.relative_to(config_dir).parts)
    destination = recovery / f"{relative}.{time.time_ns()}.{os.getpid()}.bak"
    shutil.copyfile(path, destination)
    os.chmod(destination, 0o600)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return ["#!/usr/bin/env bash", ""]
    validate_existing_file(path)
    return path.read_text(encoding="utf-8").splitlines()


def export_lines(lines: list[str]) -> dict[str, str]:
    exports: dict[str, str] = {}
    for line in lines:
        match = EXPORT_RE.match(line)
        if match:
            exports[match.group(1)] = line
    return exports


def serialize_value(value: str) -> str:
    if "\x00" in value or "\n" in value or "\r" in value:
        raise StoreError("plaintext fallback does not support multiline credential values")
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")


def active_tenant(config_dir: Path) -> str:
    marker = config_dir / "active-tenant"
    tenant = marker.read_text(encoding="utf-8").strip() if marker.exists() else "default"
    if not TENANT_RE.fullmatch(tenant):
        raise StoreError("active tenant name is invalid")
    return tenant


def resolve_target(config_dir: Path) -> Path:
    tenant = active_tenant(config_dir)
    tenant_file = config_dir / "tenants" / tenant / "credentials.sh"
    if tenant_file.exists():
        validate_existing_file(tenant_file)
        return tenant_file
    return config_dir / "credentials.sh"


def ensure_store_file(config_dir: Path, target: Path) -> None:
    validate_contained_path(config_dir, target)
    with store_lock(config_dir):
        if target.exists():
            validate_existing_file(target)
            return
        atomic_write(target, "#!/usr/bin/env bash\n\n")


def upsert(
    config_dir: Path,
    target: Path | None,
    name: str,
    value: str,
    *,
    active: bool = False,
    only_if_missing: bool = False,
) -> str:
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", name):
        raise StoreError("credential name is invalid")
    if not active:
        if target is None:
            raise StoreError("upsert requires target")
        validate_contained_path(config_dir, target)
    serialized = f'export {name}="{serialize_value(value)}"'
    with store_lock(config_dir):
        if active:
            target = resolve_target(config_dir)
        if target is None:
            raise StoreError("upsert target resolution failed")
        lines = read_lines(target)
        existing = export_lines(lines)
        if only_if_missing and name in existing:
            return "existing"
        action = "updated" if name in existing else "added"
        output = [line for line in lines if not (EXPORT_RE.match(line) and EXPORT_RE.match(line).group(1) == name)]
        if output and output[-1] != "":
            output.append("")
        output.append(serialized)
        backup(config_dir, target)
        atomic_write(target, "\n".join(output) + "\n")
    return action


def remove(
    config_dir: Path,
    target: Path | None,
    name: str,
    *,
    active: bool = False,
    contains: str | None = None,
) -> str:
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", name):
        raise StoreError("credential name is invalid")
    if not active:
        if target is None:
            raise StoreError("remove requires target")
        validate_contained_path(config_dir, target)
    with store_lock(config_dir):
        if active:
            target = resolve_target(config_dir)
        if target is None:
            raise StoreError("remove target resolution failed")
        lines = read_lines(target)
        existing = export_lines(lines)
        if name not in existing or (contains is not None and contains not in existing[name]):
            return "missing"
        output = [line for line in lines if not (EXPORT_RE.match(line) and EXPORT_RE.match(line).group(1) == name)]
        backup(config_dir, target)
        atomic_write(target, "\n".join(output) + "\n")
    return "removed"


def loader_content(config_dir: Path, tenant: str) -> str:
    tenant_file = config_dir / "tenants" / tenant / "credentials.sh"
    return f'''#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Multi-Tenant Credential Loader
# Sources the active tenant's credentials
# Active tenant: {tenant}
# Managed by: credential-helper.sh
# DO NOT edit manually - use: credential-helper.sh switch <tenant>
# ------------------------------------------------------------------------------

AIDEVOPS_ACTIVE_TENANT="{tenant}"
export AIDEVOPS_ACTIVE_TENANT

if [[ -f "{tenant_file}" ]]; then
    source "{tenant_file}"
fi
'''


def write_loader(config_dir: Path, tenant: str) -> None:
    if not TENANT_RE.fullmatch(tenant):
        raise StoreError("tenant name is invalid")
    target = config_dir / "tenants" / tenant / "credentials.sh"
    validate_existing_file(target)
    root = config_dir / "credentials.sh"
    with store_lock(config_dir):
        backup(config_dir, root)
        atomic_write(root, loader_content(config_dir, tenant))
        atomic_write(config_dir / "active-tenant", tenant + "\n")


def migrate_default(config_dir: Path) -> int:
    root = config_dir / "credentials.sh"
    default = config_dir / "tenants" / "default" / "credentials.sh"
    with store_lock(config_dir):
        root_lines = read_lines(root)
        if any("AIDEVOPS_ACTIVE_TENANT=" in line for line in root_lines):
            return 0
        default_lines = read_lines(default)
        root_exports = export_lines(root_lines)
        default_exports = export_lines(default_lines)
        conflicts = sorted(
            name for name in root_exports.keys() & default_exports.keys()
            if root_exports[name] != default_exports[name]
        )
        if conflicts:
            raise StoreError("legacy/default credential conflict: " + ", ".join(conflicts))
        missing = sorted(root_exports.keys() - default_exports.keys())
        merged = list(default_lines)
        if merged and merged[-1] != "":
            merged.append("")
        merged.extend(root_exports[name] for name in missing)
        backup(config_dir, root)
        backup(config_dir, default)
        atomic_write(default, "\n".join(merged) + "\n")
        atomic_write(config_dir / "active-tenant", "default\n")
        atomic_write(root, loader_content(config_dir, "default"))
        return len(missing)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=(
            "resolve-target",
            "ensure",
            "upsert",
            "upsert-active",
            "add-if-missing",
            "add-active-if-missing",
            "remove",
            "remove-active",
            "remove-if-contains",
            "remove-active-if-contains",
            "migrate-default",
            "write-loader",
        ),
    )
    parser.add_argument("--config-dir", required=True, type=Path)
    parser.add_argument("--target", type=Path)
    parser.add_argument("--name")
    parser.add_argument("--tenant")
    parser.add_argument("--contains")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config_dir = args.config_dir.expanduser()
    try:
        validate_contained_path(config_dir, config_dir)
        if args.command == "resolve-target":
            print(resolve_target(config_dir))
        elif args.command == "ensure":
            if args.target is None:
                raise StoreError("ensure requires target")
            ensure_store_file(config_dir, args.target)
        elif args.command == "upsert":
            if args.target is None or args.name is None:
                raise StoreError("upsert requires target and name")
            print(upsert(config_dir, args.target, args.name, os.sys.stdin.read()))
        elif args.command == "upsert-active":
            if args.name is None:
                raise StoreError("upsert-active requires name")
            print(upsert(config_dir, None, args.name, os.sys.stdin.read(), active=True))
        elif args.command == "add-if-missing":
            if args.target is None or args.name is None:
                raise StoreError("add-if-missing requires target and name")
            print(upsert(config_dir, args.target, args.name, os.sys.stdin.read(), only_if_missing=True))
        elif args.command == "add-active-if-missing":
            if args.name is None:
                raise StoreError("add-active-if-missing requires name")
            print(upsert(config_dir, None, args.name, os.sys.stdin.read(), active=True, only_if_missing=True))
        elif args.command == "remove":
            if args.target is None or args.name is None:
                raise StoreError("remove requires target and name")
            print(remove(config_dir, args.target, args.name))
        elif args.command == "remove-active":
            if args.name is None:
                raise StoreError("remove-active requires name")
            print(remove(config_dir, None, args.name, active=True))
        elif args.command == "remove-if-contains":
            if args.target is None or args.name is None or args.contains is None:
                raise StoreError("remove-if-contains requires target, name, and contains")
            print(remove(config_dir, args.target, args.name, contains=args.contains))
        elif args.command == "remove-active-if-contains":
            if args.name is None or args.contains is None:
                raise StoreError("remove-active-if-contains requires name and contains")
            print(remove(config_dir, None, args.name, active=True, contains=args.contains))
        elif args.command == "migrate-default":
            print(migrate_default(config_dir))
        elif args.command == "write-loader":
            if args.tenant is None:
                raise StoreError("write-loader requires tenant")
            write_loader(config_dir, args.tenant)
    except (OSError, UnicodeError, StoreError) as error:
        print(f"credential store error: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
