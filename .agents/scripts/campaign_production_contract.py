"""Campaign production manifest validation and persistence contract."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any


CHANNELS = {"facebook", "instagram", "linkedin", "twitter", "email", "blog", "youtube", "short-form", "social-linkedin", "social-reddit", "social-x", "podcast"}
ASSET_OWNERS = {"writing": "content/production-writing.md", "image": "content/production-image.md", "video": "content/production-video.md", "audio": "content/production-audio.md", "editor": "tools/video/video-editor.md"}
DEFAULT_FORMATS = {"facebook": ("image", "1:1", None), "instagram": ("image", "4:5", None), "linkedin": ("image", "1.91:1", None), "twitter": ("writing", "text", None), "email": ("writing", "text", None), "blog": ("writing", "text", None), "youtube": ("video", "16:9", 60), "short-form": ("video", "9:16", 30), "social-linkedin": ("image", "1.91:1", None), "social-reddit": ("writing", "text", None), "social-x": ("writing", "text", None), "podcast": ("audio", "audio", 300)}


class ManifestError(ValueError):
    """Raised when a production contract cannot be created or trusted."""


@dataclass(frozen=True)
class ManifestRequest:
    """Inputs needed to construct one immutable production job."""

    campaign_id: str
    brief: dict[str, Any]
    channel: str
    variant: int
    asset_class: str | None
    capability: str | None


def digest(value: Any) -> str:
    """Return a stable SHA-256 reference for JSON-compatible content."""
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def atomic_json_write(path: Path, document: dict[str, Any]) -> None:
    """Atomically write a JSON document without replacing valid state on failure."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def read_document(path: Path, label: str) -> dict[str, Any]:
    """Read one object document with a useful contract error."""
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ManifestError(f"invalid {label}: {path}: {error}") from error
    if not isinstance(document, dict):
        raise ManifestError(f"invalid {label}: {path} must contain an object")
    return document


def validate_brief(document: dict[str, Any]) -> None:
    """Validate fields that downstream production must rely on."""
    required = ("schema_version", "brief_id", "campaign_id", "source_snapshot_sha256", "claims", "lifecycle")
    if any(not document.get(field) for field in required) or document.get("schema_version") != 1:
        raise ManifestError("creative brief is missing required schema-v1 fields")
    if document["lifecycle"].get("status") != "brief_ready":
        raise ManifestError("creative brief lifecycle must be brief_ready")
    if not all(claim.get("evidence_reference") for claim in document["claims"]):
        raise ManifestError("creative brief claims require evidence references")


def validate_manifest(document: dict[str, Any]) -> None:
    """Reject invalid status claims and incomplete downstream jobs."""
    required = ("schema_version", "job_id", "campaign_id", "brief_id", "channel", "variant_id", "input_snapshot_sha256", "format", "execution", "lifecycle", "outputs")
    if any(field not in document for field in required) or document.get("schema_version") != 1:
        raise ManifestError("manifest is missing required schema-v1 fields")
    if document["channel"] not in CHANNELS:
        raise ManifestError("manifest has an unsupported channel")
    status, outputs = document["lifecycle"].get("status"), document["outputs"]
    if status in {"generated", "edited", "approved"} and not outputs:
        raise ManifestError(f"manifest status {status} requires verified outputs")
    if status in {"brief_ready", "prompts_ready", "queued", "running", "blocked"} and outputs:
        raise ManifestError(f"manifest status {status} must not claim completed outputs")
    if status == "blocked" and document["execution"].get("status") != "blocked":
        raise ManifestError("blocked lifecycle requires an explicit blocked execution route")


def _file_digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return "sha256:" + hasher.hexdigest()


def validate_distribution_eligibility(document: dict[str, Any], campaign_dir: Path) -> None:
    """Fail closed unless a completed output has review, rights, and provenance evidence."""
    validate_manifest(document)
    if document["lifecycle"].get("status") != "approved":
        raise ManifestError("production manifest lifecycle must be approved before distribution")
    review, authenticity = document["review"], document["authenticity"]
    if review.get("status") != "approved" or not review.get("decision_by") or not review.get("decision_at"):
        raise ManifestError("production manifest requires an attributed approved review")
    provenance, clearance = authenticity.get("provenance"), authenticity.get("rights_clearance")
    if not provenance or not provenance.get("source") or not provenance.get("recipe_sha256"):
        raise ManifestError("production manifest requires source provenance and a recipe hash")
    if not clearance or any(not clearance.get(field) for field in ("license", "consent", "territory")):
        raise ManifestError("production manifest requires license, consent, and territory clearance")
    expires_at = clearance.get("expires_at")
    try:
        if expires_at and date.fromisoformat(expires_at) < date.today():
            raise ManifestError("production manifest rights clearance has expired")
    except ValueError as error:
        raise ManifestError("production manifest rights expiry must be an ISO date") from error
    root = campaign_dir.resolve()
    for output in document["outputs"]:
        output_path = (root / output["path"]).resolve()
        if root not in output_path.parents or not output_path.is_file():
            raise ManifestError("production manifest output is missing or outside the campaign directory")
        if _file_digest(output_path) != output["sha256"]:
            raise ManifestError("production manifest output hash does not match recorded evidence")
