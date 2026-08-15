"""Channel, hash, and lifecycle validation for production manifests."""

from __future__ import annotations

from typing import Any

from _campaign_production_definitions import CHANNELS, SHA256_RE, ManifestError


def validate_status(document: dict[str, Any]) -> None:
    """Validate final channel, hash, and status invariants in order."""
    if document["channel"] not in CHANNELS:
        raise ManifestError("manifest has an unsupported channel")
    if not SHA256_RE.fullmatch(document["input_snapshot_sha256"]):
        raise ManifestError("manifest input snapshot must be a SHA-256 reference")
    if any(not SHA256_RE.fullmatch(output["sha256"]) for output in document["outputs"]):
        raise ManifestError("manifest output hashes must be SHA-256 references")
    status = document["lifecycle"].get("status")
    completed = {"generated", "edited", "approved"}
    incomplete = {"brief_ready", "prompts_ready", "queued", "running", "blocked"}
    supported = completed | incomplete | {"review_required", "rejected", "failed"}
    if not isinstance(status, str) or status not in supported:
        raise ManifestError("manifest lifecycle status is unsupported")
    if status in completed and not document["outputs"]:
        raise ManifestError(f"manifest status {status} requires verified outputs")
    if status in incomplete and document["outputs"]:
        raise ManifestError(f"manifest status {status} must not claim completed outputs")
    if status == "blocked" and document["execution"].get("status") != "blocked":
        raise ManifestError("blocked lifecycle requires an explicit blocked execution route")
