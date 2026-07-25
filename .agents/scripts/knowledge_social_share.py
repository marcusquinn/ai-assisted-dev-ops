#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Encrypted workspace social-batch distribution and grant revocation."""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import json
import os
import secrets
import sqlite3
import sys
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidSignature, InvalidTag
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from knowledge_corpus_catalog import (
    _connect_catalog,
    _open_authorized_catalog,
    _authorized_rows,
    resolve,
)
from knowledge_corpus_context import CatalogError, validate_private_file
from knowledge_social_import import import_archive_payload
from knowledge_social_store import SocialStoreError, validate_root

FORMAT_VERSION = 1
AAD = b"aidevops-social-share-v1"


class ShareError(RuntimeError):
    """Raised when a social sharing boundary fails closed."""


def b64e(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def b64d(value: str) -> bytes:
    return base64.b64decode((value + "=" * (-len(value) % 4)).encode("ascii"), altchars=b"-_", validate=True)


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def read_json(path: Path, *, private: bool = False) -> dict[str, Any]:
    if private:
        validate_private_file(path, "social share private key", repair=False)
    elif path.is_symlink() or not path.is_file():
        raise ShareError("social share input must be a regular non-symlink file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ShareError("social share input is not valid UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise ShareError("social share input must contain a JSON object")
    return value


def write_json(path: Path, value: dict[str, Any], mode: int) -> None:
    if path.exists() or path.is_symlink():
        raise ShareError("refusing to replace an existing social share file")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")


def keygen(base: Path, private_path: Path, public_path: Path) -> dict[str, Any]:
    _resolved, principal_id, read_connection = _open_authorized_catalog(base)
    read_connection.close()
    encryption = X25519PrivateKey.generate()
    signing = Ed25519PrivateKey.generate()
    public = {
        "format": FORMAT_VERSION,
        "principal_id": principal_id,
        "encryption_public": b64e(encryption.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)),
        "signing_public": b64e(signing.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)),
    }
    private = dict(public)
    private["encryption_private"] = b64e(encryption.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()))
    private["signing_private"] = b64e(signing.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()))
    write_json(private_path, private, 0o600)
    write_json(public_path, public, 0o644)
    return {"principal_id": principal_id, "public_key": str(public_path)}


def writable_catalog(base: Path, alias: str) -> tuple[str, sqlite3.Connection, sqlite3.Row]:
    resolved, principal_id, read_connection = _open_authorized_catalog(base)
    try:
        rows = _authorized_rows(read_connection, principal_id, "knowledge.manage", alias)
        if len(rows) != 1:
            raise ShareError("access denied: workspace management grant required")
        row = rows[0]
    finally:
        read_connection.close()
    connection = _connect_catalog(resolved / "catalog.db", read_only=False)
    return principal_id, connection, row


def grant(base: Path, alias: str, public_path: Path) -> dict[str, Any]:
    public = read_json(public_path)
    target = str(public.get("principal_id", ""))
    if not target.startswith("prn_") or len(target) != 36:
        raise ShareError("recipient public key has invalid principal identity")
    try:
        X25519PublicKey.from_public_bytes(b64d(str(public["encryption_public"])))
        Ed25519PublicKey.from_public_bytes(b64d(str(public["signing_public"])))
    except (KeyError, ValueError) as error:
        raise ShareError("recipient public key has invalid key material") from error
    owner, connection, corpus = writable_catalog(base, alias)
    try:
        connection.execute("BEGIN IMMEDIATE")
        workspace = connection.execute("SELECT kind,status FROM workspaces WHERE workspace_id=?", (corpus["workspace_id"],)).fetchone()
        if workspace is None or workspace["kind"] != "workspace" or workspace["status"] != "active":
            raise ShareError("sharing requires an active workspace corpus")
        if target != owner:
            connection.execute("INSERT INTO principals(principal_id,kind,status) VALUES(?, 'human', 'active') ON CONFLICT(principal_id) DO UPDATE SET status='active'", (target,))
            connection.execute("INSERT INTO workspace_memberships(workspace_id,principal_id,role,status) VALUES(?,?,'member','active') ON CONFLICT(workspace_id,principal_id) DO UPDATE SET role='member',status='active'", (corpus["workspace_id"], target))
            for capability in ("knowledge.read", "knowledge.write"):
                connection.execute("INSERT INTO corpus_grants(corpus_id,principal_id,role,capability,scope,status) VALUES(?,?,'member',?,'corpus','active') ON CONFLICT(corpus_id,principal_id,capability,scope) DO UPDATE SET role='member',status='active'", (corpus["corpus_id"], target, capability))
        connection.execute("INSERT INTO social_share_principals(corpus_id,principal_id,encryption_public,signing_public,status) VALUES(?,?,?,?,'active') ON CONFLICT(corpus_id,principal_id) DO UPDATE SET encryption_public=excluded.encryption_public,signing_public=excluded.signing_public,status='active'", (corpus["corpus_id"], target, str(public["encryption_public"]), str(public["signing_public"])))
        connection.execute("INSERT OR IGNORE INTO social_share_epochs(corpus_id,key_epoch) VALUES(?,1)", (corpus["corpus_id"],))
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
    return {"alias": alias, "principal_id": target, "status": "active"}


def active_share_record(base: Path, alias: str, principal_id: str) -> tuple[sqlite3.Row, int]:
    resolved, _current, connection = _open_authorized_catalog(base)
    try:
        row = connection.execute("""SELECT s.*,c.corpus_id FROM social_share_principals s
            JOIN corpus_grants g ON g.principal_id=s.principal_id AND g.corpus_id=s.corpus_id AND g.status='active' AND g.capability='knowledge.read'
            JOIN corpora c ON c.corpus_id=g.corpus_id JOIN corpus_aliases a ON a.corpus_id=c.corpus_id
            JOIN workspace_memberships m ON m.workspace_id=c.workspace_id AND m.principal_id=s.principal_id AND m.status='active'
            WHERE a.alias=? AND s.principal_id=? AND s.status='active'""", (alias, principal_id)).fetchone()
        if row is None:
            raise ShareError("recipient is not an active authorized workspace principal")
        epoch_row = connection.execute("SELECT key_epoch FROM social_share_epochs WHERE corpus_id=?", (row["corpus_id"],)).fetchone()
        return row, int(epoch_row["key_epoch"] if epoch_row else 1)
    finally:
        connection.close()


def export_bundle(base: Path, alias: str, recipient_path: Path, sender_path: Path, output: Path) -> dict[str, Any]:
    recipient = read_json(recipient_path)
    sender = read_json(sender_path, private=True)
    root = validate_root(resolve(base, alias, "knowledge.read"))
    recipient_record, epoch = active_share_record(base, alias, str(recipient.get("principal_id", "")))
    if str(recipient.get("encryption_public")) != recipient_record["encryption_public"]:
        raise ShareError("recipient key does not match the active workspace grant")
    sender_record, sender_epoch = active_share_record(base, alias, str(sender.get("principal_id", "")))
    if sender_epoch != epoch or str(sender.get("signing_public")) != sender_record["signing_public"]:
        raise ShareError("sender key does not match an active workspace grant")
    raw_root = root / "sources" / "social" / "raw"
    batches = []
    if raw_root.exists():
        for path in sorted(raw_root.glob("*/*/*.json.gz")):
            if path.is_symlink() or not path.is_file():
                raise ShareError("raw batch tree contains an unsafe entry")
            payload = gzip.decompress(path.read_bytes())
            batches.append({"sha256": hashlib.sha256(payload).hexdigest(), "archive": json.loads(payload)})
    plaintext = canonical({"alias": alias, "epoch": epoch, "batches": batches})
    ephemeral = X25519PrivateKey.generate()
    shared = ephemeral.exchange(X25519PublicKey.from_public_bytes(b64d(recipient_record["encryption_public"])))
    salt = secrets.token_bytes(16)
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=AAD).derive(shared)
    nonce = secrets.token_bytes(12)
    ciphertext = AESGCM(key).encrypt(nonce, plaintext, AAD)
    unsigned = {"format": FORMAT_VERSION, "recipient": recipient_record["principal_id"], "sender": sender["principal_id"], "epoch": epoch, "ephemeral_public": b64e(ephemeral.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)), "salt": b64e(salt), "nonce": b64e(nonce), "ciphertext": b64e(ciphertext)}
    signature = Ed25519PrivateKey.from_private_bytes(b64d(str(sender["signing_private"]))).sign(canonical(unsigned))
    bundle = dict(unsigned, signature=b64e(signature))
    write_json(output, bundle, 0o600)
    return {"batches": len(batches), "epoch": epoch, "recipient": recipient_record["principal_id"]}


def import_bundle(base: Path, alias: str, private_path: Path, bundle_path: Path) -> dict[str, Any]:
    private = read_json(private_path, private=True)
    bundle = read_json(bundle_path)
    _resolved, current, connection = _open_authorized_catalog(base)
    connection.close()
    if bundle.get("recipient") != current or private.get("principal_id") != current:
        raise ShareError("bundle recipient does not match the authenticated principal")
    sender_record, epoch = active_share_record(base, alias, str(bundle.get("sender", "")))
    if int(bundle.get("epoch", 0)) != epoch:
        raise ShareError("bundle key epoch is stale or revoked")
    unsigned = {key: value for key, value in bundle.items() if key != "signature"}
    try:
        Ed25519PublicKey.from_public_bytes(
            b64d(sender_record["signing_public"])
        ).verify(b64d(str(bundle["signature"])), canonical(unsigned))
    except InvalidSignature as error:
        raise ShareError("bundle sender signature verification failed") from error
    recipient_private = X25519PrivateKey.from_private_bytes(b64d(str(private["encryption_private"])))
    shared = recipient_private.exchange(X25519PublicKey.from_public_bytes(b64d(str(bundle["ephemeral_public"]))))
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=b64d(str(bundle["salt"])), info=AAD).derive(shared)
    try:
        plaintext = AESGCM(key).decrypt(
            b64d(str(bundle["nonce"])), b64d(str(bundle["ciphertext"])), AAD
        )
    except InvalidTag as error:
        raise ShareError("bundle authenticated decryption failed") from error
    payload = json.loads(plaintext)
    if not isinstance(payload, dict) or payload.get("alias") != alias or payload.get("epoch") != epoch:
        raise ShareError("decrypted bundle scope does not match the authorized corpus")
    batches = payload.get("batches")
    if not isinstance(batches, list) or any(not isinstance(batch, dict) for batch in batches):
        raise ShareError("decrypted bundle has invalid batch records")
    root = validate_root(resolve(base, alias, "knowledge.write"))
    imported = 0
    for batch in batches:
        archive_bytes = canonical(batch["archive"])
        if hashlib.sha256(archive_bytes).hexdigest() != batch["sha256"]:
            raise ShareError("decrypted batch hash mismatch")
        import_archive_payload(root, batch["archive"], archive_bytes)
        imported += 1
    return {"imported": imported, "epoch": epoch}


def revoke(base: Path, alias: str, principal_id: str) -> dict[str, Any]:
    _owner, connection, corpus = writable_catalog(base, alias)
    try:
        connection.execute("BEGIN IMMEDIATE")
        membership = connection.execute("UPDATE workspace_memberships SET status='inactive' WHERE workspace_id=? AND principal_id=? AND status='active'", (corpus["workspace_id"], principal_id)).rowcount
        grants = connection.execute("UPDATE corpus_grants SET status='inactive' WHERE corpus_id=? AND principal_id=? AND status='active'", (corpus["corpus_id"], principal_id)).rowcount
        share_key = connection.execute("UPDATE social_share_principals SET status='revoked' WHERE corpus_id=? AND principal_id=? AND status='active'", (corpus["corpus_id"], principal_id)).rowcount
        if membership != 1 or grants < 1 or share_key != 1:
            raise ShareError("principal did not have an active complete workspace grant")
        connection.execute("INSERT INTO social_share_epochs(corpus_id,key_epoch) VALUES(?,2) ON CONFLICT(corpus_id) DO UPDATE SET key_epoch=key_epoch+1", (corpus["corpus_id"],))
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
    return {"principal_id": principal_id, "status": "revoked"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("share-keygen", "share-grant", "share-export", "share-import", "share-revoke"))
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--alias", default="personal:default")
    parser.add_argument("--private-key", type=Path)
    parser.add_argument("--public-key", type=Path)
    parser.add_argument("--recipient-key", type=Path)
    parser.add_argument("--sender-key", type=Path)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--principal-id")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "share-keygen" and args.private_key and args.public_key:
            result = keygen(args.base, args.private_key, args.public_key)
        elif args.command == "share-grant" and args.public_key:
            result = grant(args.base, args.alias, args.public_key)
        elif args.command == "share-export" and args.recipient_key and args.sender_key and args.output:
            result = export_bundle(args.base, args.alias, args.recipient_key, args.sender_key, args.output)
        elif args.command == "share-import" and args.private_key and args.bundle:
            result = import_bundle(args.base, args.alias, args.private_key, args.bundle)
        elif args.command == "share-revoke" and args.principal_id:
            result = revoke(args.base, args.alias, args.principal_id)
        else:
            raise ShareError("required command arguments are missing")
        print(json.dumps(result, sort_keys=True))
        return 0
    except (CatalogError, InvalidSignature, InvalidTag, KeyError, OSError, ShareError, SocialStoreError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
