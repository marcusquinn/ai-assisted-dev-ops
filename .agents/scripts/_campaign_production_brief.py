"""Creative-brief validation for campaign production."""

from __future__ import annotations

from typing import Any

from _campaign_production_definitions import (
    BRIEF_ID_RE,
    SHA256_RE,
    ManifestError,
    validate_campaign_id,
)


def _valid_brief_id(brief_id: Any, campaign_id: str) -> bool:
    return (
        isinstance(brief_id, str)
        and bool(BRIEF_ID_RE.fullmatch(brief_id))
        and brief_id == f"brief:{campaign_id}"
    )


def _valid_snapshot(snapshot: Any) -> bool:
    return isinstance(snapshot, str) and bool(SHA256_RE.fullmatch(snapshot))


def _valid_revision(revision: Any) -> bool:
    return isinstance(revision, int) and not isinstance(revision, bool) and revision >= 1


def _validate_identity(document: dict[str, Any]) -> None:
    campaign_id = validate_campaign_id(document["campaign_id"])
    valid_brief = _valid_brief_id(document["brief_id"], campaign_id)
    valid_snapshot = _valid_snapshot(document["source_snapshot_sha256"])
    valid_revision = _valid_revision(document["revision"])
    if not valid_brief or not valid_snapshot or not valid_revision:
        raise ManifestError("creative brief identity fields are invalid")


def _validate_object_field(field: str, value: Any, keys: set[str], require_non_empty: bool) -> None:
    if not isinstance(value, dict) or set(value) != keys:
        raise ManifestError(f"creative brief {field} is malformed")
    if any(not isinstance(item, str) for item in value.values()):
        raise ManifestError(f"creative brief {field} is malformed")
    if require_non_empty and any(not item for item in value.values()):
        raise ManifestError(f"creative brief {field} is malformed")


def _validate_claim(claim: Any) -> bool:
    if not isinstance(claim, dict):
        return False
    if set(claim) != {"claim", "evidence_reference", "approval_status"}:
        return False
    if not isinstance(claim.get("claim"), str) or not claim.get("claim"):
        return False
    evidence = claim.get("evidence_reference")
    if not isinstance(evidence, str) or not evidence:
        return False
    return claim.get("approval_status") in {"approved", "pending", "rejected"}


def _validate_authenticity_arrays(value: dict[str, Any], arrays: set[str]) -> None:
    for field in arrays:
        items = value.get(field)
        if not isinstance(items, list) or any(not isinstance(item, str) for item in items):
            raise ManifestError("creative brief authenticity fields are malformed")


def _validate_authenticity(value: Any) -> None:
    arrays = {"source_requirements", "consent_requirements", "disclosure_requirements"}
    expected = arrays | {"synthetic_people_or_voice", "testimonial_or_ugc_style"}
    if not isinstance(value, dict) or set(value) != expected:
        raise ManifestError("creative brief authenticity fields are malformed")
    flags = (value.get("synthetic_people_or_voice"), value.get("testimonial_or_ugc_style"))
    if any(not isinstance(flag, bool) for flag in flags):
        raise ManifestError("creative brief authenticity fields are malformed")
    _validate_authenticity_arrays(value, arrays)


def _valid_review_criteria(criteria: Any) -> bool:
    return (
        isinstance(criteria, list)
        and bool(criteria)
        and all(isinstance(item, str) for item in criteria)
    )


def _validate_review(value: Any) -> None:
    if not isinstance(value, dict) or set(value) != {"criteria", "owner", "status"}:
        raise ManifestError("creative brief review fields are malformed")
    if not _valid_review_criteria(value.get("criteria")):
        raise ManifestError("creative brief review fields are malformed")
    if not isinstance(value.get("owner"), str) or not value.get("owner"):
        raise ManifestError("creative brief review fields are malformed")
    if value.get("status") not in {"required", "pending", "approved", "rejected"}:
        raise ManifestError("creative brief review fields are malformed")


def _validate_content_fields(document: dict[str, Any]) -> None:
    object_fields = {
        "objective": ({"metric", "target"}, True),
        "audience_insight": ({"segment", "pain", "outcome"}, True),
        "message": ({"positioning", "hook", "story", "cta"}, True),
        "creative": ({"copy_direction", "script_direction", "shot_direction", "visual_direction", "audio_direction"}, False),
    }
    for field, (keys, require_non_empty) in object_fields.items():
        _validate_object_field(field, document[field], keys, require_non_empty)


def _validate_references(references: Any) -> None:
    if not isinstance(references, list) or not references:
        raise ManifestError("creative brief brand references are malformed")
    if any(not isinstance(item, str) or not item for item in references):
        raise ManifestError("creative brief brand references are malformed")


def _validate_claims(claims: Any) -> None:
    if not isinstance(claims, list) or not claims or any(not _validate_claim(item) for item in claims):
        raise ManifestError("creative brief claims are malformed")


def _validate_references_and_claims(document: dict[str, Any]) -> None:
    _validate_references(document["brand_references"])
    _validate_claims(document["claims"])


def _validate_lifecycle(lifecycle: Any) -> None:
    valid_lifecycle = isinstance(lifecycle, dict)
    valid_lifecycle = valid_lifecycle and set(lifecycle) == {"status", "asset_evidence"}
    valid_lifecycle = valid_lifecycle and lifecycle.get("status") == "brief_ready"
    valid_lifecycle = valid_lifecycle and lifecycle.get("asset_evidence") == []
    if not valid_lifecycle:
        raise ManifestError("creative brief lifecycle must be unexecuted brief_ready")


def validate_brief(document: dict[str, Any]) -> None:
    """Validate the complete canonical creative-brief schema."""
    required = {
        "schema_version", "brief_id", "campaign_id", "revision",
        "source_snapshot_sha256", "objective", "audience_insight", "message",
        "creative", "brand_references", "claims", "authenticity", "review", "lifecycle",
    }
    if set(document) != required or document.get("schema_version") != 1:
        raise ManifestError("creative brief is missing required schema-v1 fields")
    _validate_identity(document)
    _validate_content_fields(document)
    _validate_references_and_claims(document)
    _validate_authenticity(document["authenticity"])
    _validate_review(document["review"])
    _validate_lifecycle(document["lifecycle"])
