#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Signed grants, revocations, and per-device encrypted social batches."""

from __future__ import annotations

import hashlib
import json
import secrets
import time
from dataclasses import dataclass
from typing import Any

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from _knowledge_social_share_crypto import (
    HEX_64,
    KEY_BYTES,
    SCHEMA_VERSION,
    PrivateIdentity,
    PublicIdentity,
    ShareError,
    _sign,
    _verify,
    b64d,
    b64e,
    canonical_json,
    validate_opaque,
    validate_positive_int,
)

BATCH_KIND = "social-shared-batch"
GRANT_KIND = "social-workspace-grant"
REVOCATION_KIND = "social-workspace-revocation"
SNAPSHOT_KIND = "social-workspace-snapshot"
AEAD_NAME = "AES-256-GCM"
NONCE_BYTES = 12
MAX_RECIPIENTS = 1024
MAX_BATCH_PLAINTEXT_BYTES = 64 * 1024 * 1024
CAPABILITIES = {"knowledge.read", "knowledge.write"}
BATCH_AAD = b"aidevops-social-shared-batch-v1"
WRAP_INFO = b"aidevops-social-shared-key-wrap-v1"


@dataclass(frozen=True)
class WorkspaceScope:
    workspace_id: str
    corpus_id: str
    key_generation: int


@dataclass(frozen=True)
class BatchParameters:
    scope: WorkspaceScope
    sequence: int
    expires_at: int | None = None


def _sender_fields(sender: PublicIdentity) -> dict[str, Any]:
    return {
        "sender_principal_id": sender.principal_id,
        "sender_device_id": sender.device_id,
        "sender_signing_public_key": b64e(sender.signing_public_key),
    }


def _validated_signed_record(
    envelope: dict[str, Any], sender: PublicIdentity, kind: str
) -> dict[str, Any]:
    if set(envelope) != {"record", "signature"}:
        raise ShareError("SOCIAL_SHARE_INVALID", "sharing envelope fields are invalid", 3)
    record = envelope.get("record")
    if not isinstance(record, dict):
        raise ShareError("SOCIAL_SHARE_INVALID", "sharing record is missing", 3)
    if record.get("schema_version") != SCHEMA_VERSION or record.get("kind") != kind:
        raise ShareError("SOCIAL_SHARE_INVALID", "unsupported sharing record", 3)
    expected_sender = _sender_fields(sender)
    if any(record.get(field) != value for field, value in expected_sender.items()):
        raise ShareError(
            "SOCIAL_SHARE_SENDER_MISMATCH",
            "sharing sender does not match the trusted identity",
            4,
        )
    _verify(record, envelope.get("signature"), sender.signing_public_key)
    return record


def _validated_scope(scope: WorkspaceScope) -> WorkspaceScope:
    return WorkspaceScope(
        validate_opaque(scope.workspace_id, "workspace_id"),
        validate_opaque(scope.corpus_id, "corpus_id"),
        validate_positive_int(scope.key_generation, "key_generation"),
    )


def _validate_workspace_record(record: dict[str, Any]) -> WorkspaceScope:
    return WorkspaceScope(
        validate_opaque(record.get("workspace_id"), "workspace_id"),
        validate_opaque(record.get("corpus_id"), "corpus_id"),
        validate_positive_int(record.get("key_generation"), "key_generation"),
    )


def create_grant_envelope(
    sender: PrivateIdentity,
    recipient: PublicIdentity,
    scope: WorkspaceScope,
    capabilities: list[str],
) -> dict[str, Any]:
    scope = _validated_scope(scope)
    normalized = sorted(set(capabilities))
    if not normalized or any(item not in CAPABILITIES for item in normalized):
        raise ShareError("SOCIAL_SHARE_INVALID", "sharing capabilities are invalid", 3)
    record = {
        "schema_version": SCHEMA_VERSION,
        "kind": GRANT_KIND,
        "grant_id": secrets.token_hex(32),
        "workspace_id": scope.workspace_id,
        "corpus_id": scope.corpus_id,
        "key_generation": scope.key_generation,
        **_sender_fields(sender.public),
        "recipient_identity": recipient.descriptor(),
        "capabilities": normalized,
        "created_at": int(time.time()),
    }
    return {"record": record, "signature": _sign(record, sender.signing_private_key)}


def open_grant_envelope(
    envelope: dict[str, Any], sender: PublicIdentity, recipient: PublicIdentity
) -> dict[str, Any]:
    record = _validated_signed_record(envelope, sender, GRANT_KIND)
    _validate_workspace_record(record)
    if not HEX_64.fullmatch(str(record.get("grant_id", ""))):
        raise ShareError("SOCIAL_SHARE_INVALID", "sharing grant id is invalid", 3)
    if record.get("recipient_identity") != recipient.descriptor():
        raise ShareError(
            "SOCIAL_SHARE_ACCESS_DENIED",
            "sharing grant does not target this principal and device",
            5,
        )
    capabilities = record.get("capabilities")
    if (
        not isinstance(capabilities, list)
        or not capabilities
        or capabilities != sorted(set(capabilities))
        or any(item not in CAPABILITIES for item in capabilities)
    ):
        raise ShareError("SOCIAL_SHARE_INVALID", "sharing grant capabilities are invalid", 3)
    validate_positive_int(record.get("created_at"), "created_at")
    return record


def _batch_header(
    parameters: BatchParameters,
    distribution_id: str,
    sender: PublicIdentity,
    payload_hash: str,
) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "kind": BATCH_KIND,
        "distribution_id": distribution_id,
        "workspace_id": parameters.scope.workspace_id,
        "corpus_id": parameters.scope.corpus_id,
        "key_generation": parameters.scope.key_generation,
        "batch_sequence": parameters.sequence,
        **_sender_fields(sender),
        "created_at": int(time.time()),
        "expires_at": parameters.expires_at,
        "payload_sha256": payload_hash,
    }


def _header_keys() -> tuple[str, ...]:
    return (
        "schema_version",
        "kind",
        "distribution_id",
        "workspace_id",
        "corpus_id",
        "key_generation",
        "batch_sequence",
        "sender_principal_id",
        "sender_device_id",
        "sender_signing_public_key",
        "created_at",
        "expires_at",
        "payload_sha256",
    )


def _derive_wrap_key(
    private_key: X25519PrivateKey,
    public_key: X25519PublicKey,
    header: dict[str, Any],
    recipient: PublicIdentity,
) -> bytes:
    shared = private_key.exchange(public_key)
    context = {
        "distribution_id": header["distribution_id"],
        "workspace_id": header["workspace_id"],
        "corpus_id": header["corpus_id"],
        "key_generation": header["key_generation"],
        "batch_sequence": header["batch_sequence"],
        "recipient_principal_id": recipient.principal_id,
        "recipient_device_id": recipient.device_id,
    }
    return HKDF(
        algorithm=hashes.SHA256(),
        length=KEY_BYTES,
        salt=bytes.fromhex(str(header["distribution_id"])),
        info=WRAP_INFO + canonical_json(context),
    ).derive(shared)


def _wrap_content_key(
    content_key: bytes, header: dict[str, Any], recipient: PublicIdentity
) -> dict[str, Any]:
    ephemeral_private = X25519PrivateKey.generate()
    ephemeral_public = ephemeral_private.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    metadata = {
        "recipient_principal_id": recipient.principal_id,
        "recipient_device_id": recipient.device_id,
        "ephemeral_public_key": b64e(ephemeral_public),
    }
    nonce = secrets.token_bytes(NONCE_BYTES)
    wrap_key = _derive_wrap_key(
        ephemeral_private,
        X25519PublicKey.from_public_bytes(recipient.encryption_public_key),
        header,
        recipient,
    )
    ciphertext = AESGCM(wrap_key).encrypt(nonce, content_key, canonical_json(metadata))
    return {
        **metadata,
        "aead": AEAD_NAME,
        "nonce": b64e(nonce),
        "ciphertext": b64e(ciphertext),
    }


def create_batch_envelope(
    payload: dict[str, Any],
    sender: PrivateIdentity,
    recipients: list[PublicIdentity],
    parameters: BatchParameters,
) -> dict[str, Any]:
    scope = _validated_scope(parameters.scope)
    sequence = validate_positive_int(parameters.sequence, "batch_sequence")
    if parameters.expires_at is not None:
        validate_positive_int(parameters.expires_at, "expires_at")
    parameters = BatchParameters(scope, sequence, parameters.expires_at)
    unique = {(item.principal_id, item.device_id): item for item in recipients}
    if not unique or len(unique) > MAX_RECIPIENTS:
        raise ShareError("SOCIAL_SHARE_NO_RECIPIENTS", "active sharing recipient count is invalid", 5)
    distribution_id = secrets.token_hex(32)
    plaintext = canonical_json(payload)
    if len(plaintext) > MAX_BATCH_PLAINTEXT_BYTES:
        raise ShareError("SOCIAL_SHARE_TOO_LARGE", "sharing snapshot exceeds the size limit", 3)
    header = _batch_header(
        parameters,
        distribution_id,
        sender.public,
        hashlib.sha256(plaintext).hexdigest(),
    )
    content_key = secrets.token_bytes(KEY_BYTES)
    nonce = secrets.token_bytes(NONCE_BYTES)
    ciphertext = AESGCM(content_key).encrypt(
        nonce, plaintext, BATCH_AAD + canonical_json(header)
    )
    wraps = [
        _wrap_content_key(content_key, header, recipient)
        for recipient in sorted(
            unique.values(), key=lambda item: (item.principal_id, item.device_id)
        )
    ]
    record = {
        **header,
        "key_wraps": wraps,
        "payload": {
            "aead": AEAD_NAME,
            "nonce": b64e(nonce),
            "ciphertext": b64e(ciphertext),
        },
    }
    return {"record": record, "signature": _sign(record, sender.signing_private_key)}


def _validated_batch_record(
    envelope: dict[str, Any], sender: PublicIdentity
) -> tuple[dict[str, Any], dict[str, Any]]:
    record = _validated_signed_record(envelope, sender, BATCH_KIND)
    _validate_workspace_record(record)
    validate_positive_int(record.get("batch_sequence"), "batch_sequence")
    validate_positive_int(record.get("created_at"), "created_at")
    distribution_id = record.get("distribution_id")
    payload_hash = record.get("payload_sha256")
    if not isinstance(distribution_id, str) or not HEX_64.fullmatch(distribution_id):
        raise ShareError("SOCIAL_SHARE_INVALID", "sharing distribution id is invalid", 3)
    if not isinstance(payload_hash, str) or not HEX_64.fullmatch(payload_hash):
        raise ShareError("SOCIAL_SHARE_INVALID", "sharing payload hash is invalid", 3)
    expires_at = record.get("expires_at")
    if expires_at is not None:
        validate_positive_int(expires_at, "expires_at")
        if expires_at < int(time.time()):
            raise ShareError("SOCIAL_SHARE_EXPIRED", "sharing record has expired", 4)
    try:
        header = {key: record[key] for key in _header_keys()}
    except KeyError as error:
        raise ShareError("SOCIAL_SHARE_INVALID", "sharing header is incomplete", 3) from error
    return record, header


def _validated_wraps(record: dict[str, Any]) -> list[dict[str, Any]]:
    wraps = record.get("key_wraps")
    if not isinstance(wraps, list) or not 1 <= len(wraps) <= MAX_RECIPIENTS:
        raise ShareError("SOCIAL_SHARE_INVALID", "sharing key wraps are invalid", 3)
    validated: list[dict[str, Any]] = []
    identities: set[tuple[str, str]] = set()
    for value in wraps:
        if not isinstance(value, dict):
            raise ShareError("SOCIAL_SHARE_INVALID", "sharing key wrap is invalid", 3)
        principal_id = validate_opaque(value.get("recipient_principal_id"), "principal_id")
        device_id = value.get("recipient_device_id")
        if not isinstance(device_id, str) or not HEX_64.fullmatch(device_id):
            raise ShareError("SOCIAL_SHARE_INVALID", "sharing recipient device is invalid", 3)
        identity = (principal_id, device_id)
        if identity in identities:
            raise ShareError("SOCIAL_SHARE_INVALID", "sharing key wraps contain a duplicate", 3)
        identities.add(identity)
        validated.append(value)
    return validated


def validated_batch_header(
    envelope: dict[str, Any], sender: PublicIdentity
) -> dict[str, Any]:
    """Verify the signed public header before local authorization or decryption."""
    _, header = _validated_batch_record(envelope, sender)
    return header


def open_batch_envelope(
    envelope: dict[str, Any], sender: PublicIdentity, recipient: PrivateIdentity
) -> tuple[dict[str, Any], dict[str, Any]]:
    record, header = _validated_batch_record(envelope, sender)
    matches = [
        item
        for item in _validated_wraps(record)
        if item.get("recipient_principal_id") == recipient.public.principal_id
        and item.get("recipient_device_id") == recipient.public.device_id
    ]
    if len(matches) != 1:
        raise ShareError(
            "SOCIAL_SHARE_ACCESS_DENIED",
            "no active key grant exists for this principal and device",
            5,
        )
    wrap = matches[0]
    if wrap.get("aead") != AEAD_NAME:
        raise ShareError("SOCIAL_SHARE_INVALID", "unsupported sharing key-wrap algorithm", 3)
    ephemeral_public = b64d(
        str(wrap.get("ephemeral_public_key", "")), "ephemeral public key", KEY_BYTES
    )
    metadata = {
        "recipient_principal_id": recipient.public.principal_id,
        "recipient_device_id": recipient.public.device_id,
        "ephemeral_public_key": b64e(ephemeral_public),
    }
    try:
        wrap_key = _derive_wrap_key(
            recipient.encryption_private_key,
            X25519PublicKey.from_public_bytes(ephemeral_public),
            header,
            recipient.public,
        )
        content_key = AESGCM(wrap_key).decrypt(
            b64d(str(wrap.get("nonce", "")), "key-wrap nonce", NONCE_BYTES),
            b64d(str(wrap.get("ciphertext", "")), "wrapped content key"),
            canonical_json(metadata),
        )
    except (InvalidTag, ValueError) as error:
        raise ShareError("SOCIAL_SHARE_DECRYPT_FAILED", "content-key unwrap failed", 4) from error
    encrypted_payload = record.get("payload")
    if (
        len(content_key) != KEY_BYTES
        or not isinstance(encrypted_payload, dict)
        or encrypted_payload.get("aead") != AEAD_NAME
    ):
        raise ShareError("SOCIAL_SHARE_INVALID", "encrypted sharing payload is invalid", 3)
    encrypted_bytes = b64d(str(encrypted_payload.get("ciphertext", "")), "encrypted payload")
    if len(encrypted_bytes) > MAX_BATCH_PLAINTEXT_BYTES + 16:
        raise ShareError("SOCIAL_SHARE_TOO_LARGE", "encrypted sharing payload exceeds the size limit", 3)
    try:
        plaintext = AESGCM(content_key).decrypt(
            b64d(str(encrypted_payload.get("nonce", "")), "payload nonce", NONCE_BYTES),
            encrypted_bytes,
            BATCH_AAD + canonical_json(header),
        )
    except (InvalidTag, ValueError) as error:
        raise ShareError("SOCIAL_SHARE_DECRYPT_FAILED", "sharing payload decrypt failed", 4) from error
    if len(plaintext) > MAX_BATCH_PLAINTEXT_BYTES:
        raise ShareError("SOCIAL_SHARE_TOO_LARGE", "sharing snapshot exceeds the size limit", 3)
    if hashlib.sha256(plaintext).hexdigest() != header["payload_sha256"]:
        raise ShareError("SOCIAL_SHARE_DECRYPT_FAILED", "sharing payload hash mismatch", 4)
    try:
        payload = json.loads(plaintext.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ShareError("SOCIAL_SHARE_INVALID", "decrypted sharing payload is invalid", 3) from error
    if not isinstance(payload, dict):
        raise ShareError("SOCIAL_SHARE_INVALID", "decrypted sharing payload must be an object", 3)
    return header, payload


def create_revocation_envelope(
    sender: PrivateIdentity,
    scope: WorkspaceScope,
    principal_id: str,
    revoked_devices: list[str],
) -> dict[str, Any]:
    scope = _validated_scope(scope)
    devices = sorted(set(revoked_devices))
    if any(not HEX_64.fullmatch(item) for item in devices):
        raise ShareError("SOCIAL_SHARE_INVALID", "revoked device list is invalid", 3)
    record = {
        "schema_version": SCHEMA_VERSION,
        "kind": REVOCATION_KIND,
        "event_id": secrets.token_hex(32),
        "workspace_id": scope.workspace_id,
        "corpus_id": scope.corpus_id,
        "revoked_principal_id": validate_opaque(principal_id, "principal_id"),
        "revoked_device_ids": devices,
        "key_generation": scope.key_generation,
        **_sender_fields(sender.public),
        "created_at": int(time.time()),
    }
    if scope.key_generation < 2:
        raise ShareError("SOCIAL_SHARE_INVALID", "revocation must rotate the key generation", 3)
    return {"record": record, "signature": _sign(record, sender.signing_private_key)}


def open_revocation_envelope(
    envelope: dict[str, Any], sender: PublicIdentity
) -> dict[str, Any]:
    record = _validated_signed_record(envelope, sender, REVOCATION_KIND)
    scope = _validate_workspace_record(record)
    if scope.key_generation < 2 or not HEX_64.fullmatch(str(record.get("event_id", ""))):
        raise ShareError("SOCIAL_SHARE_INVALID", "revocation metadata is invalid", 3)
    validate_opaque(record.get("revoked_principal_id"), "principal_id")
    devices = record.get("revoked_device_ids")
    if (
        not isinstance(devices, list)
        or devices != sorted(set(devices))
        or any(not isinstance(item, str) or not HEX_64.fullmatch(item) for item in devices)
    ):
        raise ShareError("SOCIAL_SHARE_INVALID", "revoked device list is invalid", 3)
    validate_positive_int(record.get("created_at"), "created_at")
    return record
