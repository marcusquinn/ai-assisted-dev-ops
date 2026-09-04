#!/usr/bin/env python3
"""cch-sign.py — Compute Claude Code billing header for OAuth pool requests.

Replicates the exact billing header that the installed Claude CLI generates,
so OAuth pool requests appear identical to native Claude CLI requests.

Two-part signing:
  Part 1 (version suffix): SHA-256(salt + picked_chars + version)[:3]
  Part 2 (body hash):      xxHash64(body_utf8, seed) & 0xFFFFF → 5-char hex

Usage:
    # Compute version suffix for a user message
    cch-sign.py suffix "Hello, world"

    # Build complete billing header
    cch-sign.py header "Hello, world"

    # Build billing header using cached constants
    cch-sign.py header "Hello, world" --cache

    # Compute body hash (xxHash, for Bun-era clients only)
    cch-sign.py body-hash '{"system":[...],"messages":[...]}'

    # Verify against known oracle (from captured traffic)
    cch-sign.py verify --suffix abc --message "Hello, world"

Constants are read from:
  1. ~/.aidevops/cch-constants.json (if --cache or file exists)
  2. Live extraction from installed Claude CLI (fallback)
  3. Hardcoded defaults (last resort)
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Defaults (v2.1.92 — update via cch-extract.sh --cache)
# ---------------------------------------------------------------------------

DEFAULT_VERSION = "2.1.92"
DEFAULT_SALT = "59cf53e54c78"
DEFAULT_CHAR_INDICES = [4, 7, 20]
DEFAULT_ENTRYPOINT = "cli"

# xxHash seed from Bun binary (required for body hash computation)
XXHASH_SEED = 0x6E52736AC806831E

CACHE_FILE = Path.home() / ".aidevops" / "cch-constants.json"

# ---------------------------------------------------------------------------
# Constants loader
# ---------------------------------------------------------------------------


def installed_claude_version() -> str | None:
    """Return the installed Claude version without changing the fallback path."""
    claude = shutil.which("claude")
    if claude is None:
        return None
    try:
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        result = subprocess.run(  # nosec B603 -- resolved Claude executable and fixed version argv.
            [claude, "--version"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (subprocess.TimeoutExpired, OSError, FileNotFoundError):
        return None
    if result.returncode != 0:
        return None
    match = re.match(r"^(\d+\.\d+\.\d+)", result.stdout.strip())
    return match.group(1) if match else None


def load_constants(use_cache: bool = True) -> dict:
    """Load signing constants from cache, live extraction, or defaults."""
    # Try cache first
    if use_cache and CACHE_FILE.exists():
        try:
            with open(CACHE_FILE) as f:
                data = json.load(f)
            if "version" in data and "salt" in data:
                return data
        except (json.JSONDecodeError, OSError):
            pass

    # Try live extraction
    try:
        extractor = Path.home() / ".aidevops" / "agents" / "scripts" / "cch-extract.sh"
        if not extractor.is_file() or extractor.is_symlink():
            raise FileNotFoundError("trusted CCH extractor is unavailable")
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        result = subprocess.run(  # nosec B603 -- absolute, verified deployed helper and fixed argv.
            [str(extractor)],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            data = json.loads(result.stdout.strip())
            if "version" in data and "salt" in data:
                return data
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError, FileNotFoundError):
        pass

    # Try claude --version for at least the version
    version = installed_claude_version() or DEFAULT_VERSION

    return {
        "version": version,
        "salt": DEFAULT_SALT,
        "char_indices": DEFAULT_CHAR_INDICES,
        "entrypoint": DEFAULT_ENTRYPOINT,
        "has_xxhash": False,
    }


# ---------------------------------------------------------------------------
# Part 1: Version suffix
# ---------------------------------------------------------------------------


def compute_version_suffix(
    user_message: str,
    version: str,
    salt: str,
    char_indices: list[int],
) -> str:
    """Compute the 3-char hex version suffix.

    Picks characters from the first user message at specified indices,
    then SHA-256 hashes salt + picked_chars + version, taking first 3 hex chars.
    """
    chars = "".join(
        user_message[i] if i < len(user_message) else "0" for i in char_indices
    )
    payload = f"{salt}{chars}{version}"
    digest = hashlib.sha256(payload.encode()).hexdigest()
    return digest[:3]


# ---------------------------------------------------------------------------
# Part 2: Body hash (xxHash — Bun-era only)
# ---------------------------------------------------------------------------


def compute_body_hash(body_json: str, seed: int = XXHASH_SEED) -> str:
    """Compute the 5-char hex body hash using xxHash64.

    Only needed for Bun-era clients. Node.js clients send cch=00000.
    Requires the xxhash package: pip install xxhash
    """
    try:
        import xxhash
    except ImportError:
        print(
            "ERROR: xxhash package required for body hash. Install: pip install xxhash",
            file=sys.stderr,
        )
        sys.exit(1)

    # Hash is computed over the body with cch=00000 placeholder
    h = xxhash.xxh64(body_json.encode(), seed=seed).intdigest() & 0xFFFFF
    return f"{h:05x}"


# ---------------------------------------------------------------------------
# Billing header builder
# ---------------------------------------------------------------------------


def build_billing_header(
    user_message: str,
    constants: dict,
    workload: str | None = None,
) -> str:
    """Build the complete x-anthropic-billing-header string.

    Matches the exact format generated by Claude CLI's GG8() function.
    """
    version = constants["version"]
    salt = constants["salt"]
    char_indices = constants.get("char_indices", DEFAULT_CHAR_INDICES)
    entrypoint = constants.get("entrypoint", DEFAULT_ENTRYPOINT)
    has_xxhash = constants.get("has_xxhash", False)

    suffix = compute_version_suffix(user_message, version, salt, char_indices)
    cc_version = f"{version}.{suffix}"

    # cch=00000 for Node.js client (no xxHash replacement)
    cch_part = " cch=00000;" if not has_xxhash else " cch=00000;"
    workload_part = f" cc_workload={workload};" if workload else ""

    return (
        f"x-anthropic-billing-header: cc_version={cc_version};"
        f" cc_entrypoint={entrypoint};{cch_part}{workload_part}"
    )


def build_billing_header_with_body_hash(
    user_message: str,
    body_json: str,
    constants: dict,
    workload: str | None = None,
) -> str:
    """Build billing header and replace cch placeholder with computed hash.

    For Bun-era clients only. The body_json should contain cch=00000.
    """
    header = build_billing_header(user_message, constants, workload)

    if constants.get("has_xxhash"):
        cch = compute_body_hash(body_json)
        header = header.replace("cch=00000", f"cch={cch}")

    return header


# ---------------------------------------------------------------------------
# CLI interface
# ---------------------------------------------------------------------------


def cmd_suffix(args: list[str]) -> None:
    """Compute version suffix only."""
    if not args:
        print("Usage: cch-sign.py suffix <user_message>", file=sys.stderr)
        sys.exit(1)

    message = args[0]
    use_cache = "--cache" in args
    constants = load_constants(use_cache=use_cache)

    suffix = compute_version_suffix(
        message, constants["version"], constants["salt"],
        constants.get("char_indices", DEFAULT_CHAR_INDICES),
    )
    print(suffix)


def cmd_header(args: list[str]) -> None:
    """Build complete billing header."""
    if not args:
        print("Usage: cch-sign.py header <user_message> [--cache]", file=sys.stderr)
        sys.exit(1)

    message = args[0]
    use_cache = "--cache" in args
    constants = load_constants(use_cache=use_cache)

    header = build_billing_header(message, constants)
    print(header)


def cmd_body_hash(args: list[str]) -> None:
    """Compute body hash (xxHash64, Bun-era only)."""
    if not args:
        print("Usage: cch-sign.py body-hash <json_body>", file=sys.stderr)
        sys.exit(1)

    body = args[0]
    cch = compute_body_hash(body)
    print(cch)


def cmd_verify(args: list[str]) -> None:
    """Verify a suffix against a known value."""
    suffix = None
    message = None

    i = 0
    while i < len(args):
        if args[i] == "--suffix" and i + 1 < len(args):
            suffix = args[i + 1]
            i += 2
        elif args[i] == "--message" and i + 1 < len(args):
            message = args[i + 1]
            i += 2
        else:
            i += 1

    if not suffix or not message:
        print(
            "Usage: cch-sign.py verify --suffix <hex> --message <text>",
            file=sys.stderr,
        )
        sys.exit(1)

    constants = load_constants()
    computed = compute_version_suffix(
        message, constants["version"], constants["salt"],
        constants.get("char_indices", DEFAULT_CHAR_INDICES),
    )

    if computed == suffix:
        print(f"MATCH: {computed} == {suffix}")
    else:
        print(f"MISMATCH: computed={computed}, expected={suffix}")
        sys.exit(1)


def cmd_json(args: list[str]) -> None:
    """Output all signing parameters as JSON (for integration)."""
    message = args[0] if args else ""
    use_cache = "--cache" in args
    constants = load_constants(use_cache=use_cache)

    suffix = compute_version_suffix(
        message, constants["version"], constants["salt"],
        constants.get("char_indices", DEFAULT_CHAR_INDICES),
    ) if message else ""

    output = {
        "version": constants["version"],
        "salt": constants["salt"],
        "char_indices": constants.get("char_indices", DEFAULT_CHAR_INDICES),
        "entrypoint": constants.get("entrypoint", DEFAULT_ENTRYPOINT),
        "has_xxhash": constants.get("has_xxhash", False),
        "suffix": suffix,
        "cc_version": f"{constants['version']}.{suffix}" if suffix else constants["version"],
        "billing_header": build_billing_header(message, constants) if message else "",
        "user_agent": f"claude-cli/{constants['version']} (external, cli)",
    }
    print(json.dumps(output, indent=2))


def main() -> None:
    if len(sys.argv) < 2:
        print(
            "Usage: cch-sign.py <command> [args]\n"
            "\n"
            "Commands:\n"
            "  suffix <message>            Compute 3-char version suffix\n"
            "  header <message>            Build complete billing header\n"
            "  body-hash <json_body>       Compute xxHash64 body hash (Bun-era)\n"
            "  verify --suffix X --message Y  Verify suffix against oracle\n"
            "  json [message] [--cache]    Output all params as JSON\n",
            file=sys.stderr,
        )
        sys.exit(1)

    command = sys.argv[1]
    args = sys.argv[2:]

    commands = {
        "suffix": cmd_suffix,
        "header": cmd_header,
        "body-hash": cmd_body_hash,
        "verify": cmd_verify,
        "json": cmd_json,
    }

    if command in commands:
        commands[command](args)
    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
