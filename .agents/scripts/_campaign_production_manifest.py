"""Production-manifest validation behind the compatibility facade."""

from __future__ import annotations

from typing import Any

from _campaign_production_manifest_evidence import (
    validate_authenticity as _validate_authenticity,
    validate_collections as _validate_collections,
    validate_review as _validate_review,
)
from _campaign_production_manifest_status import validate_status as _validate_status
from _campaign_production_definitions import (
    ASSET_OWNERS,
    BRIEF_ID_RE,
    JOB_ID_RE,
    VARIANT_ID_RE,
    ManifestError,
    validate_campaign_id,
)

REQUIRED = {
    "schema_version", "job_id", "campaign_id", "brief_id", "channel",
    "variant_id", "revision", "input_snapshot_sha256", "format", "asset_inputs",
    "execution", "authenticity", "review", "experiment", "lifecycle", "outputs",
}
EXACT_KEYS = {
    "format": {"asset_class", "dimensions", "duration_seconds"},
    "execution": {"owner", "provider_route", "capability", "fallback", "status"},
    "review": {"criteria", "status", "decision_by", "decision_at"},
    "experiment": {"experiment_id", "hypothesis"},
    "lifecycle": {"status", "status_evidence"},
}


def _validate_string_fields(document: dict[str, Any]) -> None:
    for field in ("job_id", "campaign_id", "brief_id", "channel", "variant_id", "input_snapshot_sha256"):
        if not isinstance(document[field], str) or not document[field]:
            raise ManifestError(f"manifest {field} must be a non-empty string")


def _validate_identity_fields(document: dict[str, Any]) -> None:
    validate_campaign_id(document["campaign_id"])
    identities = (
        JOB_ID_RE.fullmatch(document["job_id"]),
        BRIEF_ID_RE.fullmatch(document["brief_id"]),
        VARIANT_ID_RE.fullmatch(document["variant_id"]),
    )
    if not all(identities):
        raise ManifestError("manifest identity fields are invalid")


def _validate_header(document: dict[str, Any]) -> None:
    if any(field not in document for field in REQUIRED) or document.get("schema_version") != 1:
        raise ManifestError("manifest is missing required schema-v1 fields")
    if set(document) != REQUIRED:
        raise ManifestError("manifest contains unsupported top-level fields")
    _validate_string_fields(document)
    _validate_identity_fields(document)
    revision = document["revision"]
    if not isinstance(revision, int) or isinstance(revision, bool) or revision < 1:
        raise ManifestError("manifest revision must be a positive integer")


def _validate_object_shapes(document: dict[str, Any]) -> None:
    for field in ("format", "execution", "authenticity", "review", "experiment", "lifecycle"):
        if not isinstance(document[field], dict):
            raise ManifestError(f"manifest {field} must be an object")


def _validate_exact_shapes(document: dict[str, Any]) -> None:
    for field, allowed in EXACT_KEYS.items():
        if not set(document[field]) <= allowed:
            raise ManifestError(f"manifest {field} contains unsupported fields")
    for field in ("format", "execution", "experiment", "lifecycle"):
        if set(document[field]) != EXACT_KEYS[field]:
            raise ManifestError(f"manifest {field} is missing required fields")


def _validate_evidence_shapes(document: dict[str, Any]) -> None:
    if not {"criteria", "status"} <= set(document["review"]):
        raise ManifestError("manifest review is missing required fields")
    authenticity = document["authenticity"]
    allowed = {"disclosure_requirements", "rights_requirements", "provenance", "rights_clearance"}
    required = {"disclosure_requirements", "rights_requirements"}
    if not set(authenticity) <= allowed or not required <= set(authenticity):
        raise ManifestError("manifest authenticity fields are invalid")


def _validate_shapes(document: dict[str, Any]) -> None:
    _validate_object_shapes(document)
    _validate_exact_shapes(document)
    _validate_evidence_shapes(document)


def _valid_asset_class(asset_class: Any) -> bool:
    return isinstance(asset_class, str) and asset_class in ASSET_OWNERS


def _valid_dimensions(dimensions: Any) -> bool:
    return isinstance(dimensions, str) and bool(dimensions)


def _valid_duration(duration: Any) -> bool:
    return isinstance(duration, int) and not isinstance(duration, bool) and duration >= 1


def _validate_format(document: dict[str, Any]) -> None:
    value = document["format"]
    if not _valid_asset_class(value.get("asset_class")):
        raise ManifestError("manifest format requires a supported asset_class")
    if not _valid_dimensions(value.get("dimensions")):
        raise ManifestError("manifest format requires dimensions")
    duration = value.get("duration_seconds")
    if duration is not None and not _valid_duration(duration):
        raise ManifestError("manifest duration_seconds must be a positive integer")


def _valid_required_execution_values(value: dict[str, Any]) -> bool:
    required_values = (value.get("owner"), value.get("capability"))
    return all(isinstance(item, str) and bool(item) for item in required_values)


def _valid_optional_execution_values(value: dict[str, Any]) -> bool:
    optional_values = (value.get("provider_route"), value.get("fallback"))
    return all(item is None or isinstance(item, str) for item in optional_values)


def _validate_execution(value: dict[str, Any]) -> None:
    if not _valid_required_execution_values(value):
        raise ManifestError("manifest execution fields are invalid")
    status = value.get("status")
    if not isinstance(status, str) or status not in {"capability_required", "blocked", "ready"}:
        raise ManifestError("manifest execution fields are invalid")
    if not _valid_optional_execution_values(value):
        raise ManifestError("manifest execution fields are invalid")


def validate_manifest(document: dict[str, Any]) -> None:
    """Reject invalid status claims and incomplete downstream jobs."""
    _validate_header(document)
    _validate_shapes(document)
    _validate_format(document)
    _validate_execution(document["execution"])
    _validate_authenticity(document["authenticity"])
    _validate_review(document["review"])
    _validate_collections(document)
    _validate_status(document)
