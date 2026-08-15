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


def _validate_header(document: dict[str, Any]) -> None:
    if any(field not in document for field in REQUIRED) or document.get("schema_version") != 1:
        raise ManifestError("manifest is missing required schema-v1 fields")
    if set(document) != REQUIRED:
        raise ManifestError("manifest contains unsupported top-level fields")
    for field in ("job_id", "campaign_id", "brief_id", "channel", "variant_id", "input_snapshot_sha256"):
        if not isinstance(document[field], str) or not document[field]:
            raise ManifestError(f"manifest {field} must be a non-empty string")
    validate_campaign_id(document["campaign_id"])
    valid_identity = JOB_ID_RE.fullmatch(document["job_id"])
    valid_identity = valid_identity and BRIEF_ID_RE.fullmatch(document["brief_id"])
    valid_identity = valid_identity and VARIANT_ID_RE.fullmatch(document["variant_id"])
    if not valid_identity:
        raise ManifestError("manifest identity fields are invalid")
    revision = document["revision"]
    if not isinstance(revision, int) or isinstance(revision, bool) or revision < 1:
        raise ManifestError("manifest revision must be a positive integer")


def _validate_shapes(document: dict[str, Any]) -> None:
    for field in ("format", "execution", "authenticity", "review", "experiment", "lifecycle"):
        if not isinstance(document[field], dict):
            raise ManifestError(f"manifest {field} must be an object")
    for field, allowed in EXACT_KEYS.items():
        if not set(document[field]) <= allowed:
            raise ManifestError(f"manifest {field} contains unsupported fields")
    for field in ("format", "execution", "experiment", "lifecycle"):
        if set(document[field]) != EXACT_KEYS[field]:
            raise ManifestError(f"manifest {field} is missing required fields")
    if not {"criteria", "status"} <= set(document["review"]):
        raise ManifestError("manifest review is missing required fields")
    authenticity = document["authenticity"]
    allowed = {"disclosure_requirements", "rights_requirements", "provenance", "rights_clearance"}
    required = {"disclosure_requirements", "rights_requirements"}
    if not set(authenticity) <= allowed or not required <= set(authenticity):
        raise ManifestError("manifest authenticity fields are invalid")


def _validate_format(document: dict[str, Any]) -> None:
    value = document["format"]
    asset_class = value.get("asset_class")
    if not isinstance(asset_class, str) or asset_class not in ASSET_OWNERS:
        raise ManifestError("manifest format requires a supported asset_class")
    dimensions = value.get("dimensions")
    if not isinstance(dimensions, str) or not dimensions:
        raise ManifestError("manifest format requires dimensions")
    duration = value.get("duration_seconds")
    if duration is not None:
        if not isinstance(duration, int) or isinstance(duration, bool) or duration < 1:
            raise ManifestError("manifest duration_seconds must be a positive integer")


def _validate_execution(value: dict[str, Any]) -> None:
    for field in ("owner", "capability"):
        if not isinstance(value.get(field), str) or not value.get(field):
            raise ManifestError("manifest execution fields are invalid")
    status = value.get("status")
    if not isinstance(status, str) or status not in {"capability_required", "blocked", "ready"}:
        raise ManifestError("manifest execution fields are invalid")
    for field in ("provider_route", "fallback"):
        if value.get(field) is not None and not isinstance(value.get(field), str):
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
