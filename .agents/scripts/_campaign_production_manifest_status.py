"""Channel, hash, and lifecycle validation for production manifests."""

from __future__ import annotations

from typing import Any

from _campaign_production_definitions import CHANNELS, SHA256_RE, ManifestError


def _validate_channel_and_hashes(document: dict[str, Any]) -> None:
    if document["channel"] not in CHANNELS:
        raise ManifestError("manifest has an unsupported channel")
    if not SHA256_RE.fullmatch(document["input_snapshot_sha256"]):
        raise ManifestError("manifest input snapshot must be a SHA-256 reference")
    if any(not SHA256_RE.fullmatch(output["sha256"]) for output in document["outputs"]):
        raise ManifestError("manifest output hashes must be SHA-256 references")


def _validate_output_state(document: dict[str, Any], status: str, completed: set[str], incomplete: set[str]) -> None:
    if status in completed and not document["outputs"]:
        raise ManifestError(f"manifest status {status} requires verified outputs")
    if status in incomplete and document["outputs"]:
        raise ManifestError(f"manifest status {status} must not claim completed outputs")


def _validate_lifecycle_status(document: dict[str, Any]) -> None:
    status = document["lifecycle"].get("status")
    completed = {"generated", "edited", "approved"}
    incomplete = {"brief_ready", "prompts_ready", "queued", "running", "blocked"}
    supported = completed | incomplete | {"review_required", "rejected", "failed"}
    if not isinstance(status, str) or status not in supported:
        raise ManifestError("manifest lifecycle status is unsupported")
    _validate_output_state(document, status, completed, incomplete)
    if status == "blocked" and document["execution"].get("status") != "blocked":
        raise ManifestError("blocked lifecycle requires an explicit blocked execution route")


def validate_status(document: dict[str, Any]) -> None:
    """Validate final channel, hash, and status invariants in order."""
    _validate_channel_and_hashes(document)
    _validate_lifecycle_status(document)
