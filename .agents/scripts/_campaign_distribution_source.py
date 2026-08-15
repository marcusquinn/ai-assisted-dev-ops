#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validated source resolution for campaign distribution commands."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

from campaign_production_contract import read_document, validate_distribution_eligibility

CHANNELS = {
    "x": {"aliases": {"x", "twitter", "social-x"}, "provider": "xapi"},
    "reddit": {"aliases": {"reddit", "social-reddit"}, "provider": "reddit"},
}
PUBLIC_STATES = {"draft", "approved", "claimed", "unknown", "failed", "succeeded", "cancelled"}


class DistributionError(ValueError):
    """Raised when a campaign cannot safely become an outbound intent."""


def _canonical_channel(channel: str) -> str:
    for canonical, values in CHANNELS.items():
        if channel in values["aliases"]:
            return canonical
    raise DistributionError("channel must be x or reddit (aliases: twitter, social-x, social-reddit)")


def _digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _campaign_dir(value: str) -> Path:
    campaign_input = Path(value).absolute()
    components = (campaign_input.parent.parent, campaign_input.parent, campaign_input)
    if any(path.is_symlink() for path in components) or not campaign_input.is_dir():
        raise DistributionError("campaign directory is unavailable")
    return campaign_input.resolve()


def _selected_output(outputs: list[dict[str, Any]], requested: str | None) -> str:
    if requested is None:
        if len(outputs) != 1:
            raise DistributionError("select one reviewed output with --output")
        requested = outputs[0]["path"]
    return requested


def _resolved_output(campaign_dir: Path, requested: str) -> Path:
    relative = Path(requested)
    if relative.is_absolute() or ".." in relative.parts:
        raise DistributionError("distribution output path is unsafe")
    candidate = campaign_dir
    for component in relative.parts:
        candidate /= component
        if candidate.is_symlink():
            raise DistributionError("distribution output path must not contain symlinks")
    output = candidate.resolve()
    if campaign_dir not in output.parents or not output.is_file():
        raise DistributionError("distribution output is missing or outside its campaign")
    return output


def _verify_output_evidence(output: Path, outputs: list[dict[str, Any]], requested: str) -> None:
    matching = next((entry for entry in outputs if entry["path"] == requested), None)
    if matching is None:
        raise DistributionError("selected output is not recorded by the approved manifest")
    digest = "sha256:" + hashlib.sha256(output.read_bytes()).hexdigest()
    if digest != matching["sha256"]:
        raise DistributionError("selected output no longer matches approved evidence")


def _safe_output(campaign_dir: Path, manifest: dict[str, Any], requested: str | None) -> Path:
    outputs = manifest["outputs"]
    requested = _selected_output(outputs, requested)
    output = _resolved_output(campaign_dir, requested)
    _verify_output_evidence(output, outputs, requested)
    return output


def resolve_source(arguments: argparse.Namespace) -> tuple[Path, dict[str, Any], Path, str, str, str]:
    """Resolve reviewed campaign evidence into stable queue identity."""
    campaign_dir = _campaign_dir(arguments.campaign_dir)
    manifest_input = Path(arguments.manifest).absolute()
    if manifest_input.is_symlink() or not manifest_input.is_file():
        raise DistributionError("production manifest must be a regular non-symlink file")
    manifest_path = manifest_input.resolve()
    if campaign_dir not in manifest_path.parents:
        raise DistributionError("production manifest must be inside its campaign")
    manifest = read_document(manifest_input, "production manifest")
    validate_distribution_eligibility(manifest, campaign_dir)
    channel = _canonical_channel(arguments.channel or str(manifest["channel"]))
    output = _safe_output(campaign_dir, manifest, arguments.output)
    scheduled_at = int(arguments.scheduled_at)
    if scheduled_at < 0:
        raise DistributionError("scheduled_at must be a non-negative epoch")
    source_id = f"campaign:{manifest['campaign_id']}:{manifest['variant_id']}:{channel}"
    subject = getattr(arguments, "subject", None)
    subject_hash = hashlib.sha256(Path(subject).read_bytes()).hexdigest() if subject and Path(subject).is_file() else None
    intent_key = _digest({
        "source_id": source_id, "channel": channel,
        "output_sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
        "scheduled_at": scheduled_at, "connection_id": arguments.connection_id,
        "account_id": arguments.account_id,
        "destination_id": getattr(arguments, "destination_id", None),
        "subject_sha256": subject_hash,
    })
    return campaign_dir, manifest, output, channel, source_id, intent_key


def operation_id(source_id: str, intent_key: str) -> str:
    """Build a stable outbound operation identity."""
    return "op_campaign_" + hashlib.sha256(f"{source_id}:{intent_key}".encode()).hexdigest()[:32]
