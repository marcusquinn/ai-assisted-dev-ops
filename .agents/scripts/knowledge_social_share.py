#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Manage encrypted, signed social workspace sharing between principals."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from pathlib import Path
from typing import Any

from _knowledge_social_share_catalog import (
    create_workspace,
    current_principal,
)
from _knowledge_social_share_crypto import (
    ShareError,
    identity_envelope,
    load_identity,
    load_private_identity,
    read_json,
    write_json_atomic,
)
from _knowledge_social_share_data import build_snapshot, restore_snapshot
from _knowledge_social_share_envelope import (
    BatchParameters,
    WorkspaceScope,
    create_batch_envelope,
    create_revocation_envelope,
    open_batch_envelope,
    open_grant_envelope,
    open_revocation_envelope,
    validated_batch_header,
)
from _knowledge_social_share_grants import accept_grant, authorized_grant
from _knowledge_social_share_state import (
    apply_revocation,
    authorized_export,
    authorized_import,
    authorized_revocation,
)
from knowledge_corpus_context import CatalogError
from knowledge_social_import import provision
from knowledge_social_store import SocialStoreError

DEFAULT_BASE = Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
DEFAULT_VAULT = Path(
    os.environ.get("AIDEVOPS_VAULT_DIR", str(Path.home() / ".config" / "aidevops" / "vault"))
)


def _base(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--base", type=Path, default=DEFAULT_BASE)


def _identity(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--vault-dir", type=Path, default=DEFAULT_VAULT)


def _alias(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--alias", required=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    identity = commands.add_parser("identity-export", help="export a signed public identity")
    _base(identity)
    _identity(identity)
    identity.add_argument("--output", type=Path, required=True)

    create = commands.add_parser("workspace-create", help="create an owner-managed workspace")
    _base(create)
    _identity(create)
    _alias(create)

    grant = commands.add_parser("workspace-grant", help="grant a recipient device access")
    _base(grant)
    _identity(grant)
    _alias(grant)
    grant.add_argument("--recipient", type=Path, required=True)
    grant.add_argument(
        "--capability",
        action="append",
        choices=("knowledge.read", "knowledge.write"),
    )
    grant.add_argument("--output", type=Path, required=True)

    accept = commands.add_parser("workspace-accept", help="accept a signed workspace grant")
    _base(accept)
    _identity(accept)
    _alias(accept)
    accept.add_argument("--sender", type=Path, required=True)
    accept.add_argument("--grant", type=Path, required=True)

    export = commands.add_parser("share-export", help="encrypt a full shared snapshot")
    _base(export)
    _identity(export)
    _alias(export)
    export.add_argument("--output", type=Path, required=True)
    export.add_argument("--expires-at", type=int)

    import_command = commands.add_parser(
        "share-import", help="authorize, decrypt, and rebuild a local shared index"
    )
    _base(import_command)
    _identity(import_command)
    _alias(import_command)
    import_command.add_argument("--sender", type=Path, required=True)
    import_command.add_argument("--batch", type=Path, required=True)

    revoke = commands.add_parser("workspace-revoke", help="revoke a member and rotate epoch")
    _base(revoke)
    _identity(revoke)
    _alias(revoke)
    revoke.add_argument("--principal-id", required=True)
    revoke.add_argument("--output", type=Path, required=True)

    apply = commands.add_parser("revocation-apply", help="apply a signed local revocation")
    _base(apply)
    _alias(apply)
    apply.add_argument("--sender", type=Path, required=True)
    apply.add_argument("--revocation", type=Path, required=True)
    return parser.parse_args()


def _private_identity(args: argparse.Namespace) -> Any:
    principal_id = current_principal(args.base)
    return load_private_identity(args.vault_dir, principal_id)


def _state_result(state: Any) -> dict[str, Any]:
    return {
        "workspace_id": state.workspace_id,
        "corpus_id": state.corpus_id,
        "key_generation": state.key_generation,
    }


def _identity_export(args: argparse.Namespace) -> dict[str, Any]:
    identity = _private_identity(args)
    write_json_atomic(args.output, identity_envelope(identity), private=False)
    return {
        "principal_id": identity.public.principal_id,
        "device_id": identity.public.device_id,
    }


def _workspace_create(args: argparse.Namespace) -> dict[str, Any]:
    state = create_workspace(args.base, args.alias, _private_identity(args))
    provision(state.root)
    return _state_result(state)


def _workspace_grant(args: argparse.Namespace) -> dict[str, Any]:
    owner = _private_identity(args)
    recipient = load_identity(args.recipient)
    capabilities = args.capability or ["knowledge.read"]
    with authorized_grant(
        args.base, args.alias, owner, recipient, capabilities
    ) as (state, envelope):
        write_json_atomic(args.output, envelope, private=False)
    return {
        **_state_result(state),
        "recipient_principal_id": recipient.principal_id,
        "capabilities": sorted(set(capabilities)),
    }


def _workspace_accept(args: argparse.Namespace) -> dict[str, Any]:
    recipient = _private_identity(args)
    owner = load_identity(args.sender)
    record = open_grant_envelope(read_json(args.grant), owner, recipient.public)
    state = accept_grant(args.base, args.alias, owner, recipient, record)
    provision(state.root)
    return _state_result(state)


def _share_export(args: argparse.Namespace) -> dict[str, Any]:
    owner = _private_identity(args)
    with authorized_export(args.base, args.alias, owner) as (state, recipients):
        snapshot = build_snapshot(state.root, state.workspace_id, state.corpus_id)
        envelope = create_batch_envelope(
            snapshot,
            owner,
            recipients,
            BatchParameters(
                WorkspaceScope(state.workspace_id, state.corpus_id, state.key_generation),
                state.export_sequence,
                args.expires_at,
            ),
        )
        write_json_atomic(args.output, envelope, private=False)
    return {
        **_state_result(state),
        "batch_sequence": state.export_sequence,
        "recipients": len(recipients),
    }


def _share_import(args: argparse.Namespace) -> dict[str, Any]:
    recipient = _private_identity(args)
    sender = load_identity(args.sender)
    envelope = read_json(args.batch)
    header = validated_batch_header(envelope, sender)
    with authorized_import(args.base, args.alias, sender, recipient, header) as state:
        opened_header, snapshot = open_batch_envelope(envelope, sender, recipient)
        if opened_header != header:
            raise ShareError("SOCIAL_SHARE_INVALID", "sharing header changed during validation", 3)
        counts = restore_snapshot(state.root, snapshot, state.workspace_id, state.corpus_id)
    return {**_state_result(state), "batch_sequence": header["batch_sequence"], **counts}


def _workspace_revoke(args: argparse.Namespace) -> dict[str, Any]:
    owner = _private_identity(args)
    with authorized_revocation(
        args.base, args.alias, owner, args.principal_id
    ) as (state, devices):
        envelope = create_revocation_envelope(
            owner,
            WorkspaceScope(state.workspace_id, state.corpus_id, state.key_generation),
            args.principal_id,
            devices,
        )
        write_json_atomic(args.output, envelope, private=False)
    return {
        **_state_result(state),
        "revoked_principal_id": args.principal_id,
        "revoked_devices": len(devices),
    }


def _revocation_apply(args: argparse.Namespace) -> dict[str, Any]:
    sender = load_identity(args.sender)
    record = open_revocation_envelope(read_json(args.revocation), sender)
    state = apply_revocation(args.base, args.alias, sender, record)
    return {
        **_state_result(state),
        "revoked_principal_id": record["revoked_principal_id"],
    }


COMMANDS = {
    "identity-export": _identity_export,
    "workspace-create": _workspace_create,
    "workspace-grant": _workspace_grant,
    "workspace-accept": _workspace_accept,
    "share-export": _share_export,
    "share-import": _share_import,
    "workspace-revoke": _workspace_revoke,
    "revocation-apply": _revocation_apply,
}


def main() -> int:
    args = parse_args()
    try:
        result = COMMANDS[args.command](args)
        print(json.dumps(result, sort_keys=True))
        return 0
    except ShareError as error:
        print(f"ERROR: {error.code}: {error}", file=sys.stderr)
        return error.exit_code
    except (CatalogError, OSError, SocialStoreError, UnicodeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except sqlite3.Error:
        print("ERROR: social sharing catalog operation failed safely", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
