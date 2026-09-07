#!/usr/bin/env python3
"""Human-approved, session-bound exceptions for low-confidence source-read blocks."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
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
MAX_MANIFEST_ENTRIES = _SOURCE_CORE.MAX_MANIFEST_ENTRIES
MAX_SOURCE_BYTES = _SOURCE_CORE.MAX_SOURCE_BYTES
MAX_TTL_SECONDS = _SOURCE_CORE.MAX_TTL_SECONDS
OVERRIDABLE_REASON = _SOURCE_CORE.OVERRIDABLE_REASON
REQUEST_REUSE_SECONDS = _SOURCE_CORE.REQUEST_REUSE_SECONDS
SCHEMA_PAYLOAD = _SOURCE_CORE.SCHEMA_PAYLOAD
SCHEMA_RECEIPT = _SOURCE_CORE.SCHEMA_RECEIPT
SCHEMA_MANIFEST_PAYLOAD = _SOURCE_CORE.SCHEMA_MANIFEST_PAYLOAD
SCHEMA_MANIFEST_RECEIPT = _SOURCE_CORE.SCHEMA_MANIFEST_RECEIPT
SCHEMA_MANIFEST_REQUEST = _SOURCE_CORE.SCHEMA_MANIFEST_REQUEST
SCHEMA_BOUND_PAYLOAD = _SOURCE_CORE.SCHEMA_BOUND_PAYLOAD
SCHEMA_BOUND_RECEIPT = _SOURCE_CORE.SCHEMA_BOUND_RECEIPT
SCHEMA_TRUST = _SOURCE_CORE.SCHEMA_TRUST
SIGNATURE_NAMESPACE = _SOURCE_CORE.SIGNATURE_NAMESPACE
SIGNER_IDENTITY = _SOURCE_CORE.SIGNER_IDENTITY
SSH_KEYGEN = _SOURCE_CORE.SSH_KEYGEN
TRUST_KEY_SOURCE_DEDICATED = _SOURCE_CORE.TRUST_KEY_SOURCE_DEDICATED
ApprovalBinding = _SOURCE_CORE.ApprovalBinding
ApprovalSpec = _SOURCE_CORE.ApprovalSpec
Config = _SOURCE_CORE.Config
ManifestRequestSpec = _SOURCE_CORE.ManifestRequestSpec
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
create_manifest_request = _SOURCE_CORE.create_manifest_request
list_approvals = _SOURCE_CORE.list_approvals
manifest_scope_id = _SOURCE_CORE.manifest_scope_id
parse_ttl = _SOURCE_CORE.parse_ttl
real_user = _SOURCE_CORE.real_user
request_directory = _SOURCE_CORE.request_directory
repository_id = _SOURCE_CORE.repository_id
scope_id = _SOURCE_CORE.scope_id
secure_source_content = _SOURCE_CORE.secure_source_content
setup_key_material = _SOURCE_CORE.setup_key_material
tracked_source_identity = _SOURCE_CORE.tracked_source_identity
validate_key_material = _SOURCE_CORE.validate_key_material

__all__ = [
    "MAX_TTL_SECONDS",
    "OVERRIDABLE_REASON",
    "SSH_KEYGEN",
    "ApprovalSpec",
    "Config",
    "ManifestRequestSpec",
    "RequestSpec",
    "SourceAccessError",
    "VerificationSpec",
    "approve_request",
    "canonical_json",
    "create_request",
    "create_manifest_request",
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


def _confirmed_timestamp(spec: ApprovalSpec, prepared_at: int) -> int:
    confirmed_at = int(time.time() if spec.now is None else spec.now)
    if confirmed_at < prepared_at:
        raise SourceAccessError("source-access clock moved backwards during confirmation")
    return confirmed_at


def approve_request(config: Config, spec: ApprovalSpec) -> dict[str, Any]:
    issued_at = int(time.time() if spec.now is None else spec.now)
    request = _load_request(config, spec.home, spec.request_id, spec.expected_uid)
    if request.get("schema") == SCHEMA_MANIFEST_REQUEST:
        return _approve_manifest_request(config, spec, request, issued_at)
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
    issued_at = _confirmed_timestamp(spec, issued_at)

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


def _validated_manifest_request(
    request: dict[str, Any], expected_uid: int
) -> tuple[str, str, str, list[dict[str, str]]]:
    if request.get("uid") != expected_uid:
        raise SourceAccessError("request user does not match the invoking sudo user")
    session_id = _validate_session_id(str(request.get("session_id", "")))
    reason = _validate_reason(str(request.get("reason", "")))
    raw_entries = request.get("entries")
    if not isinstance(raw_entries, list) or not 2 <= len(raw_entries) <= MAX_MANIFEST_ENTRIES:
        raise SourceAccessError("source-access manifest entry count is invalid")
    identities = [tracked_source_identity(str(entry.get("path", ""))) for entry in raw_entries]
    repo_roots = {identity[1] for identity in identities}
    if len(repo_roots) != 1:
        raise SourceAccessError("all manifest paths must belong to one Git worktree")
    repo_root = repo_roots.pop()
    entries = sorted(
        ({"path": path, "relative_path": relative} for path, _repo, relative in identities),
        key=lambda entry: entry["relative_path"],
    )
    paths = [entry["path"] for entry in entries]
    if len(paths) != len(set(paths)):
        raise SourceAccessError("source-access manifest paths must be unique")
    expected_id = manifest_scope_id(session_id, expected_uid, repo_root, reason, paths)
    if request.get("request_id") != expected_id:
        raise SourceAccessError("source-access manifest binding is invalid")
    if request.get("repo_root") != repo_root or request.get("repository_id") != repository_id(repo_root):
        raise SourceAccessError("source-access manifest repository binding is invalid")
    if request.get("entries") != entries:
        raise SourceAccessError("source-access manifest entries are invalid")
    return session_id, reason, repo_root, entries


def _approve_manifest_request(
    config: Config,
    spec: ApprovalSpec,
    request: dict[str, Any],
    issued_at: int,
) -> dict[str, Any]:
    session_id, reason, repo_root, entries = _validated_manifest_request(
        request, spec.expected_uid
    )
    created_at = request.get("created_at")
    if isinstance(created_at, bool) or not isinstance(created_at, int):
        raise SourceAccessError("source-access request timestamp is invalid")
    request_age = issued_at - created_at
    if request_age < 0 or request_age > REQUEST_REUSE_SECONDS:
        raise SourceAccessError("source-access request has expired; create the manifest again")
    if not config.private_key.exists() or not config.public_key.exists():
        raise SourceAccessError("run the installed root-owned source-access broker setup first")

    approval_id = str(request["request_id"])
    approved_entries: list[dict[str, Any]] = []
    contents: dict[str, bytes] = {}
    total_bytes = 0
    for entry in entries:
        content, content_sha256 = secure_source_content(entry["path"])
        total_bytes += len(content)
        if total_bytes > MAX_SOURCE_BYTES:
            raise SourceAccessError("source-access manifest exceeds the total size limit")
        entry_id = hashlib.sha256(entry["path"].encode("utf-8")).hexdigest()[:32]
        snapshot_path = (
            config.state_dir
            / "snapshots"
            / str(spec.expected_uid)
            / f"{approval_id}-{entry_id}.source"
        )
        approved_entry = {
            **entry,
            "content_sha256": content_sha256,
            "snapshot_path": str(snapshot_path),
        }
        approved_entries.append(approved_entry)
        contents[str(snapshot_path)] = content

    confirmation_scope = {
        **request,
        "entries": approved_entries,
        "ttl_seconds": spec.ttl_seconds,
    }
    if spec.confirm is not None and not spec.confirm(confirmation_scope):
        raise SourceAccessError("source-access approval cancelled")
    issued_at = _confirmed_timestamp(spec, issued_at)
    payload = {
        "schema": SCHEMA_MANIFEST_PAYLOAD,
        "approval_id": approval_id,
        "request_id": spec.request_id,
        "session_id": session_id,
        "uid": spec.expected_uid,
        "repo_root": repo_root,
        "repository_id": repository_id(repo_root),
        "reason": reason,
        "entries": approved_entries,
        "issued_at": issued_at,
        "expires_at": issued_at + spec.ttl_seconds,
    }
    receipt = {
        "schema": SCHEMA_MANIFEST_RECEIPT,
        "payload": payload,
        "signature": _sign_payload(config, payload),
    }
    for snapshot_path, content in contents.items():
        atomic_write(Path(snapshot_path), content, 0o444, config.trust_uid, directory_mode=0o755)
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
        try:
            payload, signature = _validated_receipt(config, binding)
            _require_valid_approval(_verify_signature(config, payload, signature))
            return True
        except (OSError, ValueError, TypeError, json.JSONDecodeError, SourceAccessError):
            return _verify_manifest_approval(
                config, VerificationSpec(session_id, spec.uid, path, reason,
                                         context_socket=spec.context_socket), checked_at
            )
    except (OSError, ValueError, TypeError, json.JSONDecodeError, SourceAccessError):
        return False


def _bound_manifest_scope(spec: VerificationSpec, payload: dict[str, Any], paths: list[str]) -> str:
    """Verify V3 context through the native peer, never a CLI-supplied PID."""
    proposal = payload.get("proposal")
    _require_valid_approval(isinstance(proposal, dict))
    _require_valid_approval(proposal.get("uid") == spec.uid and proposal.get("session_id") == spec.session_id)
    _require_valid_approval(proposal.get("reason") == spec.reason)
    recorded = proposal.get("runtime_context")
    _require_valid_approval(isinstance(recorded, dict) and bool(spec.context_socket))
    _require_valid_approval(recorded.get("socket_path") == spec.context_socket)
    _SOURCE_CORE.revalidate_source_proposal_context(proposal, spec.uid)
    current = _SOURCE_CORE._proposal_source_snapshot(ManifestRequestSpec(
        spec.session_id, spec.uid, Path.home(), tuple(paths), spec.reason,
    ))
    repository = proposal.get("repository")
    _require_valid_approval(isinstance(repository, dict))
    _require_valid_approval(isinstance(repository.get("head"), str))
    _require_valid_approval(re.fullmatch(r"[a-f0-9]{40,64}", repository["head"]) is not None)
    # As in the Read hook, HEAD is approval-time evidence, not a prohibition on
    # committing verified edits in the original worktree.
    for key, value in current["repository"].items():
        if key != "head":
            _require_valid_approval(repository.get(key) == value)
    _require_valid_approval(proposal.get("entries") == current["entries"])
    return _bound_proposal_id(proposal, payload)


def _bound_proposal_id(proposal: dict[str, Any], payload: dict[str, Any]) -> str:
    nonce = proposal.get("nonce")
    digest = proposal.get("issue_snapshot_sha256")
    created = proposal.get("created_at")
    _require_valid_approval(isinstance(nonce, str) and re.fullmatch(r"[a-f0-9]{32}", nonce) is not None)
    _require_valid_approval(type(created) is int and created >= 0)
    _require_valid_approval(type(payload.get("issued_at")) is int and created <= payload["issued_at"])
    _require_valid_approval(isinstance(digest, str) and re.fullmatch(r"[a-f0-9]{64}", digest) is not None)
    _require_valid_approval(payload.get("issue_snapshot_sha256") == digest)
    proposal_id = hashlib.sha256(canonical_json(proposal)).hexdigest()
    _require_valid_approval(payload.get("proposal_id") == proposal_id)
    return proposal_id


def _legacy_manifest_scope(spec: VerificationSpec, payload: dict[str, Any], paths: list[str]) -> str:
    return manifest_scope_id(spec.session_id, spec.uid, payload["repo_root"], spec.reason, paths)


def _manifest_verification_policy(receipt: dict[str, Any], payload: Any) -> tuple[int, Any]:
    policies = {
        SCHEMA_MANIFEST_RECEIPT: (SCHEMA_MANIFEST_PAYLOAD, 2, _legacy_manifest_scope),
        SCHEMA_BOUND_RECEIPT: (SCHEMA_BOUND_PAYLOAD, 1, _bound_manifest_scope),
    }
    policy = policies.get(receipt.get("schema"))
    _require_valid_approval(policy is not None and isinstance(payload, dict))
    schema, minimum_entries, identify_scope = policy
    _require_valid_approval(payload.get("schema") == schema)
    return minimum_entries, identify_scope


def _manifest_storage(config: Config, spec: VerificationSpec, payload: dict[str, Any], receipt_path: Path) -> bool:
    atomic = payload.get("snapshot_layout") == _SOURCE_CORE.ATOMIC_BUNDLE_LAYOUT
    if "snapshot_layout" in payload:
        _require_valid_approval(atomic and payload.get("schema") == SCHEMA_BOUND_PAYLOAD)
    approval_id = payload["approval_id"]
    expected = (
        _SOURCE_CORE.atomic_bundle_directory(config, spec.uid, approval_id) / "receipt.json"
        if atomic else config.state_dir / "approvals" / str(spec.uid) / f"{approval_id}.json"
    )
    _require_valid_approval(receipt_path == expected and _trusted_directory(receipt_path.parent, config.trust_uid))
    revocations = config.state_dir / "revocations" / str(spec.uid)
    if atomic or revocations.exists():
        _require_valid_approval(_trusted_directory(revocations, config.trust_uid))
        _require_valid_approval(f"{approval_id}.json" not in {path.name for path in revocations.iterdir()})
    return atomic


def _verify_manifest_approval(
    config: Config,
    spec: VerificationSpec,
    checked_at: int,
) -> bool:
    for receipt_path in _SOURCE_CORE.manifest_receipt_paths(config, spec.uid):
        try:
            if not _trusted_file(receipt_path, config.trust_uid):
                continue
            _require_valid_approval(receipt_path.stat().st_size <= 1024 * 1024)
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            _require_valid_approval(isinstance(receipt, dict))
            payload = receipt.get("payload")
            minimum_entries, identify_scope = _manifest_verification_policy(receipt, payload)
            _require_valid_approval(payload.get("session_id") == spec.session_id)
            _require_valid_approval(payload.get("uid") == spec.uid)
            _require_valid_approval(payload.get("reason") == spec.reason)
            raw_entries = payload.get("entries")
            _require_valid_approval(
                isinstance(raw_entries, list)
                and minimum_entries <= len(raw_entries) <= MAX_MANIFEST_ENTRIES
            )
            _require_valid_approval(all(isinstance(entry, dict) for entry in raw_entries))
            identities = [
                tracked_source_identity(str(entry.get("path", ""))) for entry in raw_entries
            ]
            repo_roots = {identity[1] for identity in identities}
            _require_valid_approval(len(repo_roots) == 1)
            repo_root = repo_roots.pop()
            _require_valid_approval(payload.get("repo_root") == repo_root)
            _require_valid_approval(payload.get("repository_id") == repository_id(repo_root))
            expected_entries = sorted(
                (
                    {"path": source_path, "relative_path": relative_path}
                    for source_path, _repo, relative_path in identities
                ),
                key=lambda entry: entry["relative_path"],
            )
            paths = [entry["path"] for entry in expected_entries]
            _require_valid_approval(len(paths) == len(set(paths)))
            approval_id = identify_scope(spec, payload, paths)
            _require_valid_approval(payload.get("approval_id") == approval_id)
            _require_valid_approval(payload.get("request_id") == approval_id)
            atomic_layout = _manifest_storage(config, spec, payload, receipt_path)
            _require_valid_approval(spec.path in paths)
            _require_valid_approval(len(raw_entries) == len(expected_entries))
            total_bytes = 0
            for raw_entry, expected_entry in zip(raw_entries, expected_entries):
                _require_valid_approval(
                    raw_entry.get("path") == expected_entry["path"]
                    and raw_entry.get("relative_path") == expected_entry["relative_path"]
                )
                content, content_sha256 = secure_source_content(expected_entry["path"])
                total_bytes += len(content)
                _require_valid_approval(total_bytes <= MAX_SOURCE_BYTES)
                _require_valid_approval(raw_entry.get("content_sha256") == content_sha256)
                entry_id = hashlib.sha256(expected_entry["path"].encode("utf-8")).hexdigest()[:32]
                snapshot_path = (
                    _SOURCE_CORE.atomic_bundle_directory(config, spec.uid, approval_id) / f"{entry_id}.source"
                    if atomic_layout else config.state_dir / "snapshots" / str(spec.uid) / f"{approval_id}-{entry_id}.source"
                )
                _require_valid_approval(raw_entry.get("snapshot_path") == str(snapshot_path))
                _require_valid_approval(_trusted_directory(snapshot_path.parent, config.trust_uid))
                _require_valid_approval(_trusted_file(snapshot_path, config.trust_uid))
                _require_valid_approval(snapshot_path.stat().st_size <= MAX_SOURCE_BYTES)
                _require_valid_approval(
                    hashlib.sha256(snapshot_path.read_bytes()).hexdigest() == content_sha256
                )
            issued_at = payload.get("issued_at")
            expires_at = payload.get("expires_at")
            _require_valid_approval(isinstance(issued_at, int) and not isinstance(issued_at, bool))
            _require_valid_approval(isinstance(expires_at, int) and not isinstance(expires_at, bool))
            _require_valid_approval(checked_at >= issued_at)
            _require_valid_approval(checked_at < expires_at)
            _require_valid_approval(expires_at - issued_at <= MAX_TTL_SECONDS)
            signature = receipt.get("signature")
            _require_valid_approval(isinstance(signature, str))
            _require_valid_approval(_verify_signature(config, payload, signature))
            return True
        except (OSError, ValueError, TypeError, json.JSONDecodeError, SourceAccessError):
            continue
    return False


def _snapshot_belongs_to_approval(path: Path, directory: Path, approval_id: str) -> bool:
    if path.parent != directory:
        return False
    return path.name == f"{approval_id}.source" or re.fullmatch(
        rf"{approval_id}-[a-f0-9]{{32}}\.source", path.name,
    ) is not None


def revoke_approval(config: Config, *, approval_id: str, uid: int) -> None:
    if not ID_PATTERN.fullmatch(approval_id):
        raise SourceAccessError("invalid approval identifier")
    withdrew_atomic = _SOURCE_CORE.withdraw_atomic_bundle(config, uid, approval_id)
    receipt_path = config.state_dir / "approvals" / str(uid) / f"{approval_id}.json"
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        if withdrew_atomic:
            return
        raise SourceAccessError("source-access approval was not found") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise SourceAccessError("source-access approval is malformed") from exc
    receipt_path.unlink()
    payload = receipt.get("payload", {})
    snapshot_paths = [config.state_dir / "snapshots" / str(uid) / f"{approval_id}.source"]
    if receipt.get("schema") in (SCHEMA_MANIFEST_RECEIPT, SCHEMA_BOUND_RECEIPT) and isinstance(payload, dict):
        snapshot_paths = [
            Path(str(entry.get("snapshot_path", "")))
            for entry in payload.get("entries", [])
            if isinstance(entry, dict)
        ]
    expected_snapshot_dir = config.state_dir / "snapshots" / str(uid)
    for snapshot_path in snapshot_paths:
        try:
            if _snapshot_belongs_to_approval(snapshot_path, expected_snapshot_dir, approval_id):
                snapshot_path.unlink()
        except FileNotFoundError:
            pass


class _BundleApproval:
    """Human-confirmed issue/source transaction; transport callbacks confer no authority."""

    def __init__(self, config: Config, spec: ApprovalSpec, reader: Any) -> None:
        self.config = config
        self.spec = spec
        self.reader = reader
        self.core = _SOURCE_CORE
        self.path = self.core.bundle_journal_path(config, spec.expected_uid, spec.request_id)

    def now(self) -> int:
        return int(time.time() if self.spec.now is None else self.spec.now)

    def check(self, condition: bool, message: str) -> None:
        self.core._require_source(condition, message)

    def save(self, row: dict[str, Any]) -> None:
        # Cancellation and revocation use the commit lock without waiting for
        # an in-flight human prompt or remote publication. Never revive their
        # terminal record with an older copy held by the operation owner.
        with self.core.bundle_transaction_lock(self.config, self.spec.expected_uid, self.spec.request_id, "commit"):
            current = self.load()
            self.check(current is None or current.get("state") not in ("CANCELLED", "REVOKED"),
                       "proposal is cancelled or revoked")
            self._write_locked(row)

    def _write_locked(self, row: dict[str, Any]) -> None:
        """Persist only while the caller holds the transaction commit lock."""
        content = canonical_json(row)
        self.check(len(content) <= self.core.MAX_REQUEST_BYTES, "bundle transaction metadata exceeds the limit")
        atomic_write(self.path, content, 0o600, self.config.trust_uid)

    def load(self) -> dict[str, Any] | None:
        if not self.path.exists():
            return None
        row = self.core._read_request_record(self.path, self.config.trust_uid)
        self.check(row.get("proposal_id") == self.spec.request_id and row.get("uid") == self.spec.expected_uid,
                   "transaction identity mismatch")
        self.check(row.get("state") in ("CANCELLED", "REVOKED") or
                   (row.get("repository") == self.reader.repository and row.get("issue") == self.reader.number),
                   "a proposal cannot be rebound to another issue")
        return row

    def current_source(self) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
        body = self.core.load_source_proposal(self.config, self.spec.home, self.spec.request_id, self.spec.expected_uid)
        entries = body.get("entries")
        self.check(isinstance(entries, list) and 1 <= len(entries) <= MAX_MANIFEST_ENTRIES,
                   "invalid proposed source set")
        self.check(all(isinstance(entry, dict) and isinstance(entry.get("path"), str) for entry in entries),
                   "invalid proposed source paths")
        request = ManifestRequestSpec(body["session_id"], self.spec.expected_uid, self.spec.home,
                                      tuple(entry["path"] for entry in entries), body["reason"], self.now())
        _validate_session_id(request.session_id)
        _validate_reason(request.reason)
        context = self.core.revalidate_source_proposal_context(body, self.spec.expected_uid)
        snapshot = self.core._proposal_source_snapshot(request)
        original_repository = body.get("repository", {})
        self.check(all(original_repository.get(key) == value for key, value in snapshot["repository"].items() if key != "head"),
                   "worktree identity changed; new explicit context consent is required")
        self.check([entry["path"] for entry in entries] == [entry["path"] for entry in snapshot["entries"]],
                   "source paths cannot be silently rebound")
        for entry in snapshot["entries"]:
            content, digest = secure_source_content(entry["path"])
            self.check(digest == entry["content_sha256"], "source changed during classification")
            self.core.require_source_only_content(content)
        return body, snapshot, context

    def public_keys(self) -> tuple[str, str]:
        validate_key_material(self.config)
        issue_key = self.spec.home / ".aidevops" / "approval-keys" / "private" / "approval.key"
        with self.core.protected_key_descriptor(issue_key, self.config.trust_uid) as descriptor:
            issue_public = self.core.descriptor_public_key(descriptor).decode("ascii")
        with self.core.protected_key_descriptor(self.config.private_key, self.config.trust_uid) as descriptor:
            source_public = self.core.descriptor_public_key(descriptor).decode("ascii")
        self.check(issue_public != source_public, "issue and source approval require independent keys")
        return issue_public, source_public

    def snapshot(self, issued_at: str, excluded: int | None = None) -> dict[str, Any]:
        snapshot = self.core.collect_issue_signing_snapshot(self.reader, issued_at, excluded)
        self.check(snapshot["lifecycle"]["locked"] is True and snapshot["lifecycle"]["lock_anchor"] is not None,
                   "issue has no verified uninterrupted lock; no authority was issued")
        return snapshot

    def prepare(self) -> dict[str, Any]:
        original, source, context = self.current_source()
        issue_public, source_public = self.public_keys()
        self.core.private_bundle_parent(self.config, self.spec.expected_uid)
        self.core.root_data_directory(self.config.state_dir / "revocations" / str(self.spec.expected_uid), self.config.trust_uid, 0o755)
        prepared_at = self.now()
        issued_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(prepared_at))
        # The helper runs as the owning user. Only the subsequent trusted REST
        # snapshot establishes the lock; a successful exit alone is insufficient.
        self.core.github_issue_action(self.spec.expected_uid, self.reader, "lock")
        snapshot = self.snapshot(issued_at)
        digest = hashlib.sha256(self.core.issue_snapshot_bytes(snapshot)).hexdigest()
        body = {"session_id": original["session_id"], "uid": self.spec.expected_uid,
                "reason": original["reason"], "created_at": prepared_at, "nonce": self.core.secrets.token_hex(16),
                "issue_snapshot_sha256": digest, "runtime_context": context, **source}
        row = {"schema": "aidevops-source-transaction/v1", "state": "PREPARED",
               "proposal_id": self.spec.request_id, "uid": self.spec.expected_uid,
               "repository": self.reader.repository, "issue": self.reader.number,
               "body": body, "issue_lifecycle": snapshot["lifecycle"],
               "issue_public": issue_public, "source_public": source_public,
               "ttl_seconds": self.spec.ttl_seconds,
               "approval_id": hashlib.sha256(canonical_json(body)).hexdigest()}
        self.save(row)
        self.check(self.spec.confirm is not None, "bundle approval requires explicit confirmation")
        scope = {"repository": self.reader.repository, "issue": self.reader.number,
                 "issue_snapshot_sha256": digest, "session_id": body["session_id"],
                 "uid": self.spec.expected_uid, "runtime_context": context,
                 "repo_root": source["repository"]["root"], "commit": source["repository"]["head"],
                 "entries": source["entries"], "ttl_seconds": self.spec.ttl_seconds,
                 "proposal_id": self.spec.request_id, "approval_id": row["approval_id"]}
        if not self.spec.confirm(scope):
            row["state"] = "CANCELLED"
            self.save(row)
            raise SourceAccessError("bundle approval cancelled; no signing authority was issued")
        confirmed_at = _confirmed_timestamp(self.spec, prepared_at)
        issued_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(confirmed_at))
        after = self.snapshot(issued_at)
        self.check(hashlib.sha256(self.core.issue_snapshot_bytes(after)).hexdigest() == digest,
                   "issue scope changed during confirmation; review the refreshed proposal")
        row.update(state="CONFIRMED", confirmed_at=confirmed_at,
                   issue_payload={"schema": "aidevops-approval/v2", "authority": "development",
                                  "issued_at": issued_at, "target": {"kind": "issue", "repository": self.reader.repository.lower(),
                                                                    "number": self.reader.number},
                                  "snapshot_sha256": digest, "pr": None, "issue": {"lifecycle": after["lifecycle"]}})
        self.validate_source(row)
        self.save(row)
        return row

    def validate_source(self, row: dict[str, Any]) -> None:
        _original, source, context = self.current_source()
        self.check(source["entries"] == row["body"]["entries"] and source["repository"] == row["body"]["repository"]
                   and context == row["body"]["runtime_context"], "source or runtime changed after confirmation")
        self.check(self.public_keys() == (row["issue_public"], row["source_public"]), "signing trust changed after confirmation")
        self.check(row["confirmed_at"] <= self.now() < row["confirmed_at"] + row["ttl_seconds"],
                   "confirmed consent expired; it cannot be renewed automatically")

    def issue_signature(self, row: dict[str, Any]) -> str:
        key = self.spec.home / ".aidevops" / "approval-keys" / "private" / "approval.key"
        with self.core.protected_key_descriptor(key, self.config.trust_uid) as descriptor:
            self.check(self.core.descriptor_public_key(descriptor).decode("ascii") == row["issue_public"], "issue key changed")
            return self.core.descriptor_signature(self.config, descriptor, self.core.ISSUE_SIGNATURE_NAMESPACE,
                                                  self.core.issue_snapshot_bytes(row["issue_payload"]))

    def comment_body(self, row: dict[str, Any]) -> str:
        payload = self.core.issue_snapshot_bytes(row["issue_payload"]).decode("utf-8")
        return ("<!-- aidevops-signed-approval -->\n## Maintainer Approval (cryptographically signed)\n\n"
                f"```\n{payload}\n```\n\n```\n{row['issue_signature'].strip()}\n```\n\n"
                "This approval was signed with a root-protected SSH key. It cannot be forged by automation.\n\n"
                "> **This issue is now locked.** To propose scope changes, open a new issue referencing this one.")

    def verify_publication(self, row: dict[str, Any]) -> int:
        publication = self.core.collect_issue_signing_snapshot(
            self.reader, row["issue_payload"]["issued_at"], approval_body=self.comment_body(row))
        identifier = publication["comment_id"]
        snapshot = publication["snapshot"]
        self.check(hashlib.sha256(self.core.issue_snapshot_bytes(snapshot)).hexdigest() == row["body"]["issue_snapshot_sha256"],
                   "published issue approval no longer matches the confirmed snapshot")
        self.check(_verify_bundle_issue_signature(self.config, row), "independent issue signature verification failed")
        return identifier

    def accept_issue(self, row: dict[str, Any]) -> None:
        self.validate_source(row)
        if row["state"] == "CONFIRMED":
            row["issue_signature"] = self.issue_signature(row)
            row["state"] = "POSTING"
            self.save(row)  # Never blindly repeat an ambiguous remote write.
            self.core.github_issue_action(self.spec.expected_uid, self.reader, "publish", self.comment_body(row).encode("utf-8"))
        row["issue_comment_id"] = self.verify_publication(row)
        row["state"] = "ISSUE_VERIFIED"
        self.save(row)

    def source_payload(self, row: dict[str, Any]) -> dict[str, Any]:
        destination = self.core.atomic_bundle_directory(self.config, self.spec.expected_uid, row["approval_id"])
        entries = [{"path": entry["path"], "relative_path": entry["relative_path"],
                    "content_sha256": entry["content_sha256"],
                    "snapshot_path": str(destination / (hashlib.sha256(entry["path"].encode("utf-8")).hexdigest()[:32] + ".source"))}
                   for entry in row["body"]["entries"]]
        return {"schema": SCHEMA_BOUND_PAYLOAD, "snapshot_layout": self.core.ATOMIC_BUNDLE_LAYOUT,
                "approval_id": row["approval_id"], "request_id": row["approval_id"],
                "original_proposal_id": self.spec.request_id, "proposal_id": row["approval_id"], "proposal": row["body"],
                "uid": self.spec.expected_uid, "session_id": row["body"]["session_id"], "reason": row["body"]["reason"],
                "repo_root": row["body"]["repository"]["root"], "repository_id": repository_id(row["body"]["repository"]["root"]),
                "issue_snapshot_sha256": row["body"]["issue_snapshot_sha256"], "issue_comment_id": row["issue_comment_id"],
                "entries": entries, "issued_at": row["confirmed_at"], "expires_at": row["confirmed_at"] + row["ttl_seconds"]}

    def recover_source(self, row: dict[str, Any]) -> dict[str, Any]:
        with self.core.bundle_transaction_lock(self.config, self.spec.expected_uid, self.spec.request_id, "commit"):
            current = self.load()
            self.check(current is not None and current.get("state") in ("ISSUE_VERIFIED", "SOURCE_COMMITTED"),
                       "proposal is cancelled or revoked")
            self.validate_source(row)
            payload = self.source_payload(row)
            directory = self.core.atomic_bundle_directory(self.config, self.spec.expected_uid, row["approval_id"])
            self.check(_trusted_directory(directory, self.config.trust_uid), "stored bundle directory is unsafe")
            self.check(not os.path.lexists(self.config.state_dir / "revocations" / str(self.spec.expected_uid) /
                                          f'{row["approval_id"]}.json'), "bundle is revoked")
            receipt_path = directory / "receipt.json"
            self.check(_trusted_file(receipt_path, self.config.trust_uid), "stored bundle receipt is unsafe")
            content, _digest = secure_source_content(str(receipt_path))
            self.check(len(content) <= 1024 * 1024, "stored bundle receipt exceeds the limit")
            receipt = json.loads(content.decode("utf-8"))
            self.check(receipt.get("schema") == SCHEMA_BOUND_RECEIPT and receipt.get("payload") == payload
                       and isinstance(receipt.get("signature"), str), "stored bundle does not match confirmed consent")
            self.check(_verify_signature(self.config, payload, receipt["signature"]), "stored bundle signature is invalid")
            for entry in payload["entries"]:
                self.check(_trusted_file(Path(entry["snapshot_path"]), self.config.trust_uid), "stored snapshot is unsafe")
                _content, digest = secure_source_content(entry["snapshot_path"])
                self.check(digest == entry["content_sha256"], "stored snapshot was changed")
            row["state"] = "SOURCE_COMMITTED"
            self._write_locked(row)
            return payload

    def publish_source(self, row: dict[str, Any]) -> dict[str, Any]:
        self.validate_source(row)
        self.verify_publication(row)
        destination = self.core.atomic_bundle_directory(self.config, self.spec.expected_uid, row["approval_id"])
        if os.path.lexists(destination):
            return self.recover_source(row)
        payload = self.source_payload(row)
        staging_root = self.core.root_data_directory(self.config.state_dir / ".staging" / str(self.spec.expected_uid), self.config.trust_uid)
        with tempfile.TemporaryDirectory(prefix="bundle-", dir=staging_root) as temporary:
            stage = Path(temporary) / "grant"
            stage.mkdir(mode=0o700)
            for entry in payload["entries"]:
                content, digest = secure_source_content(entry["path"])
                self.check(digest == entry["content_sha256"], "source changed before publication")
                name = Path(entry["snapshot_path"]).name
                atomic_write(stage / name, content, 0o444, self.config.trust_uid, directory_mode=0o700)
            with self.core.protected_key_descriptor(self.config.private_key, self.config.trust_uid) as descriptor:
                signature = self.core.descriptor_signature(self.config, descriptor, SIGNATURE_NAMESPACE, canonical_json(payload))
            receipt = {"schema": SCHEMA_BOUND_RECEIPT, "payload": payload, "signature": signature}
            self.check(_verify_signature(self.config, payload, signature), "source signature verification failed")
            atomic_write(stage / "receipt.json", canonical_json(receipt), 0o644, self.config.trust_uid, directory_mode=0o700)
            with self.core.bundle_transaction_lock(self.config, self.spec.expected_uid, self.spec.request_id, "commit"):
                current = self.load()
                self.check(current is not None and current.get("state") == "ISSUE_VERIFIED", "bundle was cancelled or revoked")
                self.validate_source(row)
                os.chmod(stage, 0o755)
                os.replace(stage, destination)  # Receipt and every snapshot become visible together.
                row["state"] = "SOURCE_COMMITTED"
                self._write_locked(row)
            return payload

    def run(self) -> dict[str, Any]:
        with self.core.bundle_transaction_lock(self.config, self.spec.expected_uid, self.spec.request_id, "operation"):
            row = self.load()
            if row is None or row.get("state") == "PREPARED":
                row = self.prepare()
            self.check(row["state"] not in ("CANCELLED", "REVOKED"), "proposal is cancelled or revoked")
            self.check(row.get("ttl_seconds") == self.spec.ttl_seconds, "confirmed lifetime cannot be silently changed")
            if row["state"] == "SOURCE_COMMITTED":
                return self.recover_source(row)
            self.check(row["state"] in ("CONFIRMED", "POSTING", "ISSUE_VERIFIED"), "transaction state is not recoverable")
            if row["state"] != "ISSUE_VERIFIED":
                self.accept_issue(row)
            return self.publish_source(row)


def _verify_bundle_issue_signature(config: Config, row: dict[str, Any]) -> bool:
    directory = _SOURCE_CORE.root_data_directory(config.config_dir / "private" / "verification", config.trust_uid)
    with tempfile.TemporaryDirectory(prefix="issue-", dir=directory) as temporary:
        root = Path(temporary)
        allowed = root / "allowed_signers"
        signature = root / "signature"
        atomic_write(allowed, f'approval@aidevops.sh namespaces="aidevops-approve" {row["issue_public"]}\n'.encode("ascii"), 0o600, config.trust_uid)
        atomic_write(signature, row["issue_signature"].encode("ascii"), 0o600, config.trust_uid)
        result = _run([SSH_KEYGEN, "-Y", "verify", "-f", str(allowed), "-I", "approval@aidevops.sh",
                       "-n", _SOURCE_CORE.ISSUE_SIGNATURE_NAMESPACE, "-s", str(signature)],
                      input_bytes=_SOURCE_CORE.issue_snapshot_bytes(row["issue_payload"]))
        return result.returncode == 0


def approve_bundle(config: Config, spec: ApprovalSpec, repository: str, issue: int) -> dict[str, Any]:
    _SOURCE_CORE._require_source(spec.confirm is not None and 0 < spec.ttl_seconds <= MAX_TTL_SECONDS,
                                 "bundle approval requires bounded lifetime and explicit consent")
    credential = _SOURCE_CORE.github_credential_for_user(spec.expected_uid)
    reader = _SOURCE_CORE.GitHubIssueReader(repository, issue, credential)
    return _BundleApproval(config, spec, reader).run()


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


def cancel_bundle(config: Config, proposal_id: str, uid: int) -> None:
    """Persist cancellation before withdrawing any already-published capability."""
    path = _SOURCE_CORE.bundle_journal_path(config, uid, proposal_id)
    with _SOURCE_CORE.bundle_transaction_lock(config, uid, proposal_id, "commit"):
        row = (_SOURCE_CORE._read_request_record(path, config.trust_uid) if path.exists() else
               {"schema": "aidevops-source-transaction/v1", "proposal_id": proposal_id, "uid": uid})
        _SOURCE_CORE._require_source(row.get("proposal_id") == proposal_id and row.get("uid") == uid,
                                     "transaction identity mismatch")
        row["state"] = "CANCELLED"
        atomic_write(path, canonical_json(row), 0o600, config.trust_uid)
    approval_id = row.get("approval_id")
    if isinstance(approval_id, str):
        _SOURCE_CORE.withdraw_atomic_bundle(config, uid, approval_id)


def _confirm_bundle(scope: dict[str, Any]) -> bool:
    print("Approve this exact issue scope AND the following temporary source-read capability.")
    print("Review the named source files for credentials; content screening is not a proof of absence.")
    # Escape issue/path/control characters rather than interpreting terminal input.
    print(json.dumps(scope, ensure_ascii=True, sort_keys=True, indent=2))
    return input("Type APPROVE ISSUE AND SOURCE to confirm: ") == "APPROVE ISSUE AND SOURCE"


def _run_approve_bundle(args: argparse.Namespace, config: Config, uid: int, home: Path) -> int:
    _require_root_tty(config)
    payload = approve_bundle(config, ApprovalSpec(args.proposal_id, home, uid, parse_ttl(args.ttl),
                                                confirm=_confirm_bundle), args.repo, args.issue)
    print(f"Approved issue {args.repo}#{args.issue} and source capability: {payload['approval_id']}")
    print(f"Expires epoch: {payload['expires_at']}")
    return 0


def _run_cancel_bundle(args: argparse.Namespace, config: Config, uid: int, _home: Path) -> int:
    _require_root_tty(config)
    cancel_bundle(config, args.proposal_id, uid)
    print(f"Cancelled proposal: {args.proposal_id}; published issue signatures are not undone.")
    return 0


def _confirm_setup() -> bool:
    print("Create a dedicated root-only key for source-access signatures.")
    return input("Type SETUP SOURCE ACCESS to confirm: ") == "SETUP SOURCE ACCESS"


def _confirm_request(request: dict[str, Any]) -> bool:
    print("Approve temporary source-code read access:")
    print(f"  Session: {request['session_id']}")
    if request.get("schema") == SCHEMA_MANIFEST_REQUEST:
        print(f"  Repo:    {request['repo_root']}")
        print("  Paths:")
        for entry in request["entries"]:
            print(f"    - {entry['relative_path']} [{entry['content_sha256']}]")
    else:
        print(f"  Path:    {request['path']}")
    print(f"  Reason:  {request['reason']}")
    print(f"  TTL:     {request['ttl_seconds'] // 60} minutes")
    return input("Type APPROVE to confirm: ") == "APPROVE"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="aidevops source-access")
    subparsers = parser.add_subparsers(dest="command", required=True)
    _add_proposal_commands(subparsers)
    subparsers.add_parser("setup")
    request = subparsers.add_parser("request")
    request.add_argument("--session", required=True)
    request.add_argument("--path", required=True, action="append")
    request.add_argument("--reason", required=True)
    approve = subparsers.add_parser("approve")
    approve.add_argument("request_id")
    approve.add_argument("--ttl", default="12h")
    verify = subparsers.add_parser("verify")
    verify.add_argument("--session", required=True)
    verify.add_argument("--path", required=True)
    verify.add_argument("--reason", required=True)
    verify.add_argument("--quiet", action="store_true")
    verify.add_argument("--context-socket", default=os.environ.get("AIDEVOPS_SOURCE_CONTEXT_SOCKET", ""))
    revoke = subparsers.add_parser("revoke")
    revoke.add_argument("approval_id")
    subparsers.add_parser("status")
    subparsers.add_parser("trust-check")
    return parser


def _add_proposal_commands(subparsers: Any) -> None:
    proposal = subparsers.add_parser("propose", help="prepare powerless runtime-bound proposal metadata")
    proposal.add_argument("--session", required=True)
    proposal.add_argument("--path", required=True, action="append")
    proposal.add_argument("--reason", required=True)
    issue_source = proposal.add_mutually_exclusive_group(required=True)
    issue_source.add_argument("--issue-snapshot-sha256")
    issue_source.add_argument("--repo", help="read the issue snapshot without signing or modifying it")
    proposal.add_argument("--issue", type=int)
    proposal.add_argument("--context-socket", default=os.environ.get("AIDEVOPS_SOURCE_CONTEXT_SOCKET", ""))
    withdrawal = subparsers.add_parser("withdraw-proposal", help="remove pending metadata; does not revoke grants")
    withdrawal.add_argument("proposal_id")
    bundle = subparsers.add_parser("approve-bundle", help="confirm one issue and its exact runtime-bound source set")
    bundle.add_argument("proposal_id")
    bundle.add_argument("--repo", required=True)
    bundle.add_argument("--issue", required=True, type=int)
    bundle.add_argument("--ttl", default="12h")
    cancellation = subparsers.add_parser("cancel-proposal", help="permanently cancel a proposal and withdraw its source grant")
    cancellation.add_argument("proposal_id")


def _run_propose(args: argparse.Namespace, config: Config, uid: int, home: Path) -> int:
    if not args.context_socket:
        raise SourceAccessError("proposal preparation requires a live runtime context socket")
    _SOURCE_CORE._require_source(uid > 0 and os.geteuid() == uid, "prepare proposals as their non-root owning user")
    digest = args.issue_snapshot_sha256
    if args.repo:
        _SOURCE_CORE._require_source(type(args.issue) is int and args.issue > 0, "--repo requires a positive --issue")
        reader = _SOURCE_CORE.GitHubIssueReader(args.repo, args.issue, _SOURCE_CORE.github_credential_for_user(uid))
        snapshot = _SOURCE_CORE.collect_issue_signing_snapshot(reader, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time())))
        digest = hashlib.sha256(_SOURCE_CORE.issue_snapshot_bytes(snapshot)).hexdigest()
    elif args.issue is not None:
        raise SourceAccessError("--issue requires --repo")
    proposal_id = _SOURCE_CORE.create_source_proposal(
        config, ManifestRequestSpec(args.session, uid, home, _SOURCE_CORE.proposal_candidate_paths(args.path), args.reason),
        issue_snapshot_sha256=digest, context_socket=args.context_socket,
    )
    print(proposal_id)
    return 0


def _run_withdraw_proposal(args: argparse.Namespace, config: Config, uid: int, home: Path) -> int:
    _SOURCE_CORE.withdraw_source_proposal(config, home, args.proposal_id, uid)
    print(f"Withdrawn pending proposal: {args.proposal_id}; existing grants were not revoked.")
    return 0


def _run_setup(_args: argparse.Namespace, config: Config, _uid: int, _home: Path) -> int:
    _require_root_tty(config)
    if not _confirm_setup():
        raise SourceAccessError("source-access setup cancelled")
    setup_key_material(config)
    print("Source-access trust is configured with a dedicated root-only key.")
    return 0


def _run_request(args: argparse.Namespace, config: Config, uid: int, home: Path) -> int:
    if len(args.path) == 1:
        request_id = create_request(
            config,
            RequestSpec(args.session, uid, home, args.path[0], args.reason),
        )
    else:
        request_id = create_manifest_request(
            config,
            ManifestRequestSpec(args.session, uid, home, tuple(args.path), args.reason),
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
        VerificationSpec(args.session, uid, args.path, args.reason, context_socket=args.context_socket),
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
        "propose": _run_propose,
        "withdraw-proposal": _run_withdraw_proposal,
        "approve-bundle": _run_approve_bundle,
        "cancel-proposal": _run_cancel_bundle,
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
