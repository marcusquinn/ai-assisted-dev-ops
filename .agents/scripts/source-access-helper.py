#!/usr/bin/env python3
"""Human-approved, session-bound exceptions for low-confidence source-read blocks."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
import tempfile
import time
import types
from pathlib import Path
from typing import Any

_ROOT_BROKER_PATH = Path("/etc/aidevops/source-access/source-access-helper.py")
_SOURCE_CORE_PATH = Path(__file__).resolve().with_name("source_access_core.py")
_SOURCE_CORE_MODULE_NAME = "_aidevops_source_access_core"
_BOOTSTRAP_TRUST_UID = 0
_BOOTSTRAP_TRUST_ROOT = Path("/")


def _bootstrap_require(condition: bool) -> None:
    if not condition:
        raise RuntimeError("refusing privileged source-access startup from untrusted broker files")


def _validate_bootstrap_leaf(path: Path) -> None:
    metadata = path.lstat()
    _bootstrap_require(stat.S_ISREG(metadata.st_mode))
    _bootstrap_require(not stat.S_ISLNK(metadata.st_mode))
    _bootstrap_require(metadata.st_uid == _BOOTSTRAP_TRUST_UID)
    _bootstrap_require(metadata.st_mode & 0o022 == 0)


def _validate_bootstrap_ancestors(path: Path, *, allow_symlinks: bool) -> None:
    current = path
    while True:
        metadata = current.lstat()
        is_symlink = stat.S_ISLNK(metadata.st_mode)
        _bootstrap_require(metadata.st_uid == _BOOTSTRAP_TRUST_UID)
        _bootstrap_require(
            (allow_symlinks and is_symlink)
            or (stat.S_ISDIR(metadata.st_mode) and metadata.st_mode & 0o022 == 0)
        )
        if current == _BOOTSTRAP_TRUST_ROOT:
            break
        _bootstrap_require(current != current.parent)
        current = current.parent


def _validate_privileged_core_import() -> None:
    if os.geteuid() != 0:
        return
    try:
        actual = Path(__file__).resolve(strict=True)
        expected = _ROOT_BROKER_PATH.resolve(strict=True)
        expected_core_path = _ROOT_BROKER_PATH.with_name("source_access_core.py")
        expected_core = expected_core_path.resolve(strict=True)
        _bootstrap_require(actual == expected)
        _bootstrap_require(_SOURCE_CORE_PATH.resolve(strict=True) == expected_core)
        _validate_bootstrap_leaf(_ROOT_BROKER_PATH)
        _validate_bootstrap_leaf(expected_core_path)
        _validate_bootstrap_ancestors(_ROOT_BROKER_PATH.parent, allow_symlinks=True)
        _validate_bootstrap_ancestors(expected.parent, allow_symlinks=False)
    except OSError as exc:
        raise RuntimeError(
            "refusing privileged source-access startup from unavailable broker files"
        ) from exc


def _load_source_access_core() -> Any:
    _validate_privileged_core_import()
    try:
        source = _SOURCE_CORE_PATH.read_bytes()
    except OSError as exc:
        raise RuntimeError(
            "refusing privileged source-access startup from unavailable broker files"
        ) from exc
    module = types.ModuleType(_SOURCE_CORE_MODULE_NAME)
    module.__file__ = str(_SOURCE_CORE_PATH)
    module.__package__ = ""
    previous_module = sys.modules.get(_SOURCE_CORE_MODULE_NAME)
    sys.modules[_SOURCE_CORE_MODULE_NAME] = module
    try:
        code = compile(source, str(_SOURCE_CORE_PATH), "exec", dont_inherit=True)
        exec(code, module.__dict__)
    except BaseException:
        if previous_module is None:
            sys.modules.pop(_SOURCE_CORE_MODULE_NAME, None)
        else:
            sys.modules[_SOURCE_CORE_MODULE_NAME] = previous_module
        raise
    return module


_SOURCE_CORE = _load_source_access_core()
ID_PATTERN = _SOURCE_CORE.ID_PATTERN
MAX_TTL_SECONDS = _SOURCE_CORE.MAX_TTL_SECONDS
OVERRIDABLE_REASON = _SOURCE_CORE.OVERRIDABLE_REASON
REQUEST_REUSE_SECONDS = _SOURCE_CORE.REQUEST_REUSE_SECONDS
SCHEMA_PAYLOAD = _SOURCE_CORE.SCHEMA_PAYLOAD
SCHEMA_RECEIPT = _SOURCE_CORE.SCHEMA_RECEIPT
SCHEMA_TRUST = _SOURCE_CORE.SCHEMA_TRUST
SIGNATURE_NAMESPACE = _SOURCE_CORE.SIGNATURE_NAMESPACE
SIGNER_IDENTITY = _SOURCE_CORE.SIGNER_IDENTITY
SSH_KEYGEN = _SOURCE_CORE.SSH_KEYGEN
TRUST_KEY_SOURCE_DEDICATED = _SOURCE_CORE.TRUST_KEY_SOURCE_DEDICATED
ApprovalBinding = _SOURCE_CORE.ApprovalBinding
ApprovalSpec = _SOURCE_CORE.ApprovalSpec
Config = _SOURCE_CORE.Config
RequestSpec = _SOURCE_CORE.RequestSpec
SourceAccessError = _SOURCE_CORE.SourceAccessError
VerificationSpec = _SOURCE_CORE.VerificationSpec
_load_request = _SOURCE_CORE._load_request
_run = _SOURCE_CORE._run
_trusted_directory = _SOURCE_CORE._trusted_directory
_trusted_file = _SOURCE_CORE._trusted_file
_validate_reason = _SOURCE_CORE._validate_reason
_validate_session_id = _SOURCE_CORE._validate_session_id
atomic_write = _SOURCE_CORE.atomic_write
canonical_json = _SOURCE_CORE.canonical_json
canonical_tracked_source = _SOURCE_CORE.canonical_tracked_source
create_request = _SOURCE_CORE.create_request
list_approvals = _SOURCE_CORE.list_approvals
parse_ttl = _SOURCE_CORE.parse_ttl
real_user = _SOURCE_CORE.real_user
request_directory = _SOURCE_CORE.request_directory
scope_id = _SOURCE_CORE.scope_id
secure_source_content = _SOURCE_CORE.secure_source_content
setup_key_material = _SOURCE_CORE.setup_key_material
validate_key_material = _SOURCE_CORE.validate_key_material

__all__ = [
    "MAX_TTL_SECONDS",
    "OVERRIDABLE_REASON",
    "SSH_KEYGEN",
    "ApprovalSpec",
    "Config",
    "RequestSpec",
    "SourceAccessError",
    "VerificationSpec",
    "approve_request",
    "canonical_json",
    "create_request",
    "list_approvals",
    "main",
    "parse_ttl",
    "revoke_approval",
    "setup_key_material",
    "validate_key_material",
    "verify_approval",
]


def _sign_payload(config: Config, payload: dict[str, Any]) -> str:
    validate_key_material(config)
    with tempfile.TemporaryDirectory(prefix="aidevops-source-access-sign-") as temp_dir:
        payload_path = Path(temp_dir) / "payload.json"
        payload_path.write_bytes(canonical_json(payload))
        result = _run(
            [
                SSH_KEYGEN,
                "-Y",
                "sign",
                "-f",
                str(config.private_key),
                "-n",
                SIGNATURE_NAMESPACE,
                str(payload_path),
            ]
        )
        signature_path = Path(f"{payload_path}.sig")
        if result.returncode != 0 or not signature_path.is_file():
            raise SourceAccessError("failed to sign source-access approval")
        return signature_path.read_text(encoding="utf-8")


def approve_request(config: Config, spec: ApprovalSpec) -> dict[str, Any]:
    issued_at = int(time.time() if spec.now is None else spec.now)
    request = _load_request(config, spec.home, spec.request_id, spec.expected_uid)
    if request.get("uid") != spec.expected_uid:
        raise SourceAccessError("request user does not match the invoking sudo user")
    session_id = _validate_session_id(str(request.get("session_id", "")))
    reason = _validate_reason(str(request.get("reason", "")))
    path = canonical_tracked_source(str(request.get("path", "")))
    content, content_sha256 = secure_source_content(path)
    if not config.private_key.exists() or not config.public_key.exists():
        raise SourceAccessError("run the installed root-owned source-access broker setup first")
    created_at = request.get("created_at")
    if isinstance(created_at, bool) or not isinstance(created_at, int):
        raise SourceAccessError("source-access request timestamp is invalid")
    request_age = issued_at - created_at
    if request_age < 0 or request_age > REQUEST_REUSE_SECONDS:
        raise SourceAccessError("source-access request has expired; retry the blocked read")
    confirmation_scope = {**request, "ttl_seconds": spec.ttl_seconds}
    if spec.confirm is not None and not spec.confirm(confirmation_scope):
        raise SourceAccessError("source-access approval cancelled")

    approval_id = scope_id(session_id, spec.expected_uid, path, reason)
    snapshot_path = (
        config.state_dir / "snapshots" / str(spec.expected_uid) / f"{approval_id}.source"
    )
    payload = {
        "schema": SCHEMA_PAYLOAD,
        "approval_id": approval_id,
        "request_id": spec.request_id,
        "session_id": session_id,
        "uid": spec.expected_uid,
        "path": path,
        "reason": reason,
        "content_sha256": content_sha256,
        "snapshot_path": str(snapshot_path),
        "issued_at": issued_at,
        "expires_at": issued_at + spec.ttl_seconds,
    }
    receipt = {
        "schema": SCHEMA_RECEIPT,
        "payload": payload,
        "signature": _sign_payload(config, payload),
    }
    atomic_write(snapshot_path, content, 0o444, config.trust_uid, directory_mode=0o755)
    receipt_path = config.state_dir / "approvals" / str(spec.expected_uid) / f"{approval_id}.json"
    atomic_write(receipt_path, canonical_json(receipt) + b"\n", 0o644, config.trust_uid)
    try:
        (request_directory(config, spec.home) / f"{spec.request_id}.json").unlink()
    except FileNotFoundError:
        pass
    return payload


def _verify_signature(config: Config, payload: dict[str, Any], signature: str) -> bool:
    if not _trusted_directory(config.public_key.parent, config.trust_uid):
        return False
    if not _trusted_file(config.public_key, config.trust_uid):
        return False
    with tempfile.TemporaryDirectory(prefix="aidevops-source-access-verify-") as temp_dir:
        temp = Path(temp_dir)
        payload_path = temp / "payload.json"
        signature_path = temp / "payload.sig"
        allowed_path = temp / "allowed_signers"
        payload_path.write_bytes(canonical_json(payload))
        signature_path.write_text(signature, encoding="utf-8")
        public_key = config.public_key.read_text(encoding="utf-8").strip()
        allowed_path.write_text(
            f'{SIGNER_IDENTITY} namespaces="{SIGNATURE_NAMESPACE}" {public_key}\n',
            encoding="utf-8",
        )
        result = _run(
            [
                SSH_KEYGEN,
                "-Y",
                "verify",
                "-f",
                str(allowed_path),
                "-I",
                SIGNER_IDENTITY,
                "-n",
                SIGNATURE_NAMESPACE,
                "-s",
                str(signature_path),
            ],
            input_bytes=canonical_json(payload),
        )
        return result.returncode == 0


def _require_valid_approval(condition: bool) -> None:
    if not condition:
        raise SourceAccessError("source-access approval is invalid")


def _validated_receipt(config: Config, binding: ApprovalBinding) -> tuple[dict[str, Any], str]:
    _require_valid_approval(_trusted_directory(binding.receipt_path.parent, config.trust_uid))
    _require_valid_approval(_trusted_file(binding.receipt_path, config.trust_uid))
    receipt = json.loads(binding.receipt_path.read_text(encoding="utf-8"))
    _require_valid_approval(isinstance(receipt, dict))
    payload = receipt.get("payload")
    _require_valid_approval(receipt.get("schema") == SCHEMA_RECEIPT)
    _require_valid_approval(isinstance(payload, dict))
    expected = {
        "approval_id": binding.approval_id,
        "session_id": binding.session_id,
        "uid": binding.uid,
        "path": binding.path,
        "reason": binding.reason,
    }
    _require_valid_approval(not any(payload.get(key) != value for key, value in expected.items()))
    _require_valid_approval(payload.get("schema") == SCHEMA_PAYLOAD)
    content_sha256 = payload.get("content_sha256")
    _require_valid_approval(isinstance(content_sha256, str))
    _require_valid_approval(len(content_sha256) == 64)
    _require_valid_approval(all(character in "0123456789abcdef" for character in content_sha256))
    _, current_sha256 = secure_source_content(binding.path)
    _require_valid_approval(current_sha256 == content_sha256)
    _require_valid_approval(payload.get("snapshot_path") == str(binding.snapshot_path))
    _require_valid_approval(_trusted_directory(binding.snapshot_path.parent, config.trust_uid))
    _require_valid_approval(_trusted_file(binding.snapshot_path, config.trust_uid))
    snapshot_sha256 = hashlib.sha256(binding.snapshot_path.read_bytes()).hexdigest()
    _require_valid_approval(snapshot_sha256 == content_sha256)
    issued_at = payload.get("issued_at")
    expires_at = payload.get("expires_at")
    _require_valid_approval(isinstance(issued_at, int))
    _require_valid_approval(not isinstance(issued_at, bool))
    _require_valid_approval(isinstance(expires_at, int))
    _require_valid_approval(not isinstance(expires_at, bool))
    _require_valid_approval(binding.checked_at >= issued_at)
    _require_valid_approval(binding.checked_at < expires_at)
    _require_valid_approval(expires_at - issued_at <= MAX_TTL_SECONDS)
    signature = receipt.get("signature")
    _require_valid_approval(isinstance(signature, str))
    return payload, signature


def verify_approval(config: Config, spec: VerificationSpec) -> bool:
    try:
        checked_at = int(time.time() if spec.now is None else spec.now)
        session_id = _validate_session_id(spec.session_id)
        reason = _validate_reason(spec.reason)
        path = canonical_tracked_source(spec.path)
        approval_id = scope_id(session_id, spec.uid, path, reason)
        binding = ApprovalBinding(
            approval_id=approval_id,
            checked_at=checked_at,
            path=path,
            reason=reason,
            receipt_path=config.state_dir / "approvals" / str(spec.uid) / f"{approval_id}.json",
            session_id=session_id,
            snapshot_path=config.state_dir / "snapshots" / str(spec.uid) / f"{approval_id}.source",
            uid=spec.uid,
        )
        payload, signature = _validated_receipt(config, binding)
        _require_valid_approval(_verify_signature(config, payload, signature))
        return True
    except (OSError, ValueError, TypeError, json.JSONDecodeError, SourceAccessError):
        return False


def revoke_approval(config: Config, *, approval_id: str, uid: int) -> None:
    if not ID_PATTERN.fullmatch(approval_id):
        raise SourceAccessError("invalid approval identifier")
    receipt_path = config.state_dir / "approvals" / str(uid) / f"{approval_id}.json"
    try:
        receipt_path.unlink()
    except FileNotFoundError as exc:
        raise SourceAccessError("source-access approval was not found") from exc
    snapshot_path = config.state_dir / "snapshots" / str(uid) / f"{approval_id}.source"
    try:
        snapshot_path.unlink()
    except FileNotFoundError:
        pass


def _trusted_root_broker(config: Config) -> bool:
    try:
        actual = Path(__file__).resolve(strict=True)
        expected = (config.config_dir / "source-access-helper.py").resolve(strict=True)
        expected_core = (config.config_dir / "source_access_core.py").resolve(strict=True)
        if actual != expected:
            return False
        current = actual
        while True:
            metadata = current.lstat()
            if metadata.st_uid != config.trust_uid or metadata.st_mode & 0o022:
                return False
            if current == Path(current.anchor):
                break
            current = current.parent
        return _trusted_file(actual, config.trust_uid) and _trusted_file(
            expected_core, config.trust_uid
        )
    except OSError:
        return False


def _require_root_broker(config: Config, *, require_tty: bool) -> None:
    if os.geteuid() != 0:
        raise SourceAccessError("privileged commands must use the installed root-owned source-access broker")
    if require_tty and not sys.stdin.isatty():
        raise SourceAccessError("this command requires an interactive terminal")
    if not _trusted_root_broker(config):
        raise SourceAccessError("refusing privileged execution outside the root-owned source-access broker")


def _require_root_tty(config: Config) -> None:
    _require_root_broker(config, require_tty=True)


def _confirm_setup() -> bool:
    print("Create a dedicated root-only key for source-access signatures.")
    return input("Type SETUP SOURCE ACCESS to confirm: ") == "SETUP SOURCE ACCESS"


def _confirm_request(request: dict[str, Any]) -> bool:
    print("Approve temporary source-code read access:")
    print(f"  Session: {request['session_id']}")
    print(f"  Path:    {request['path']}")
    print(f"  Reason:  {request['reason']}")
    print(f"  TTL:     {request['ttl_seconds'] // 60} minutes")
    return input("Type APPROVE SOURCE ACCESS to confirm: ") == "APPROVE SOURCE ACCESS"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="aidevops source-access")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("setup")
    request = subparsers.add_parser("request")
    request.add_argument("--session", required=True)
    request.add_argument("--path", required=True)
    request.add_argument("--reason", required=True)
    approve = subparsers.add_parser("approve")
    approve.add_argument("request_id")
    approve.add_argument("--ttl", default="12h")
    verify = subparsers.add_parser("verify")
    verify.add_argument("--session", required=True)
    verify.add_argument("--path", required=True)
    verify.add_argument("--reason", required=True)
    verify.add_argument("--quiet", action="store_true")
    revoke = subparsers.add_parser("revoke")
    revoke.add_argument("approval_id")
    subparsers.add_parser("status")
    subparsers.add_parser("trust-check")
    return parser


def _run_setup(_args: argparse.Namespace, config: Config, _uid: int, _home: Path) -> int:
    _require_root_tty(config)
    if not _confirm_setup():
        raise SourceAccessError("source-access setup cancelled")
    setup_key_material(config)
    print("Source-access trust is configured with a dedicated root-only key.")
    return 0


def _run_request(args: argparse.Namespace, config: Config, uid: int, home: Path) -> int:
    request_id = create_request(
        config,
        RequestSpec(args.session, uid, home, args.path, args.reason),
    )
    print(request_id)
    return 0


def _run_approve(args: argparse.Namespace, config: Config, uid: int, home: Path) -> int:
    _require_root_tty(config)
    payload = approve_request(
        config,
        ApprovalSpec(
            request_id=args.request_id,
            home=home,
            expected_uid=uid,
            ttl_seconds=parse_ttl(args.ttl),
            confirm=_confirm_request,
        ),
    )
    print(f"Approved: {payload['approval_id']}")
    print(f"Expires epoch: {payload['expires_at']}")
    return 0


def _run_verify(args: argparse.Namespace, config: Config, uid: int, _home: Path) -> int:
    valid = verify_approval(
        config,
        VerificationSpec(args.session, uid, args.path, args.reason),
    )
    if valid and not args.quiet:
        print("VERIFIED")
    return 0 if valid else 1


def _run_revoke(args: argparse.Namespace, config: Config, uid: int, _home: Path) -> int:
    _require_root_tty(config)
    revoke_approval(config, approval_id=args.approval_id, uid=uid)
    print(f"Revoked: {args.approval_id}")
    return 0


def _run_status(_args: argparse.Namespace, config: Config, uid: int, _home: Path) -> int:
    approvals = list_approvals(config, uid=uid)
    if not approvals:
        print("No source-access approvals.")
        return 0
    for approval in approvals:
        print(
            f"{approval['approval_id']}\t{approval['status']}\t"
            f"{approval['expires_at']}\t{approval['session_id']}\t{approval['path']}"
        )
    return 0


def _run_trust_check(_args: argparse.Namespace, config: Config, _uid: int, _home: Path) -> int:
    _require_root_broker(config, require_tty=False)
    validate_key_material(config)
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    uid, home = real_user()
    config = Config()
    handlers = {
        "setup": _run_setup,
        "request": _run_request,
        "approve": _run_approve,
        "verify": _run_verify,
        "revoke": _run_revoke,
        "status": _run_status,
        "trust-check": _run_trust_check,
    }
    try:
        return handlers[args.command](args, config, uid, home)
    except SourceAccessError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
