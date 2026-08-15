"""Fail-closed distribution eligibility for campaign production."""

from __future__ import annotations

import hashlib
from datetime import date
from pathlib import Path
from typing import Any

from _campaign_production_brief import validate_brief
from _campaign_production_definitions import ManifestError
from _campaign_production_io import digest, read_document
from _campaign_production_manifest import validate_manifest


def _file_digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return "sha256:" + hasher.hexdigest()


def _require_approved_review(document: dict[str, Any]) -> None:
    review = document["review"]
    if review.get("status") != "approved":
        raise ManifestError("production manifest requires an attributed approved review")
    if not isinstance(review.get("decision_by"), str) or not review.get("decision_by"):
        raise ManifestError("production manifest requires an attributed approved review")
    if not isinstance(review.get("decision_at"), str) or not review.get("decision_at"):
        raise ManifestError("production manifest requires an attributed approved review")


def _require_provenance(provenance: Any) -> None:
    if not isinstance(provenance, dict):
        raise ManifestError("production manifest requires source provenance and a recipe hash")
    if any(not isinstance(provenance.get(field), str) or not provenance.get(field) for field in ("source", "recipe_sha256")):
        raise ManifestError("production manifest requires source provenance and a recipe hash")


def _require_clearance(clearance: Any) -> None:
    if not isinstance(clearance, dict):
        raise ManifestError("production manifest requires license, consent, and territory clearance")
    if any(not isinstance(clearance.get(field), str) or not clearance.get(field) for field in ("license", "consent", "territory")):
        raise ManifestError("production manifest requires license, consent, and territory clearance")
    _require_valid_expiry(clearance.get("expires_at"))


def _require_valid_expiry(expires_at: Any) -> None:
    if expires_at is not None and not isinstance(expires_at, str):
        raise ManifestError("production manifest rights expiry must be an ISO date")
    try:
        if expires_at and date.fromisoformat(expires_at) < date.today():
            raise ManifestError("production manifest rights clearance has expired")
    except ValueError as error:
        raise ManifestError("production manifest rights expiry must be an ISO date") from error


def _require_rights_and_provenance(document: dict[str, Any]) -> None:
    authenticity = document["authenticity"]
    _require_provenance(authenticity.get("provenance"))
    _require_clearance(authenticity.get("rights_clearance"))


def _resolve_output_path(root: Path, relative: Path) -> Path:
    if relative.is_absolute() or ".." in relative.parts:
        raise ManifestError("production manifest output path is unsafe")
    candidate = root
    for component in relative.parts:
        candidate /= component
        if candidate.is_symlink():
            raise ManifestError("production manifest output path must not contain symlinks")
    output_path = candidate.resolve()
    if root not in output_path.parents or not output_path.is_file():
        raise ManifestError("production manifest output is missing or outside the campaign directory")
    return output_path


def _verify_outputs(outputs: list[dict[str, Any]], campaign_dir: Path) -> None:
    root = campaign_dir.resolve()
    for output in outputs:
        output_path = _resolve_output_path(root, Path(output["path"]))
        if _file_digest(output_path) != output["sha256"]:
            raise ManifestError("production manifest output hash does not match recorded evidence")


def _validate_manifest_identity(document: dict[str, Any], campaign_dir: Path) -> None:
    if document["campaign_id"] != campaign_dir.name:
        raise ManifestError("production manifest campaign_id does not match its campaign directory")
    if document["brief_id"] != f"brief:{document['campaign_id']}":
        raise ManifestError("production manifest brief_id does not match its campaign")
    expected_job = f"job:{document['campaign_id']}:{document['channel']}:{document['variant_id']}"
    if document["job_id"] != expected_job:
        raise ManifestError("production manifest job_id does not match its campaign")


def _load_current_brief(document: dict[str, Any], campaign_dir: Path) -> dict[str, Any]:
    drafts_dir = campaign_dir / "drafts"
    if drafts_dir.is_symlink() or not drafts_dir.is_dir():
        raise ManifestError("campaign drafts directory must be a regular directory")
    brief = read_document(drafts_dir / "creative-brief-v1.json", "creative brief")
    validate_brief(brief)
    if brief["brief_id"] != document["brief_id"]:
        raise ManifestError("production manifest does not match the current creative brief")
    if brief["campaign_id"] != document["campaign_id"]:
        raise ManifestError("creative brief campaign_id does not match its campaign")
    return brief


def _validate_current_snapshot(document: dict[str, Any], brief: dict[str, Any]) -> None:
    snapshot = digest({"brief": digest(brief), "channel": document["channel"], "variant": int(document["variant_id"][1:]), "asset_class": document["format"]["asset_class"]})
    if document["input_snapshot_sha256"] != snapshot:
        raise ManifestError("production manifest input snapshot is stale")


def validate_distribution_eligibility(document: dict[str, Any], campaign_dir: Path) -> None:
    """Require completed output with review, rights, and provenance evidence."""
    validate_manifest(document)
    _validate_manifest_identity(document, campaign_dir)
    brief = _load_current_brief(document, campaign_dir)
    _validate_current_snapshot(document, brief)
    if document["lifecycle"].get("status") != "approved":
        raise ManifestError("production manifest lifecycle must be approved before distribution")
    _require_approved_review(document)
    _require_rights_and_provenance(document)
    _verify_outputs(document["outputs"], campaign_dir)
