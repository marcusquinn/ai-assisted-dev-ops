"""Production-manifest validation behind the compatibility facade."""

from __future__ import annotations

from datetime import date, datetime
from typing import Any

from _campaign_production_definitions import (
    ASSET_OWNERS,
    BRIEF_ID_RE,
    CHANNELS,
    JOB_ID_RE,
    SHA256_RE,
    VARIANT_ID_RE,
    ManifestError,
    validate_campaign_id,
)

REQUIRED = (
    "schema_version", "job_id", "campaign_id", "brief_id", "channel",
    "variant_id", "revision", "input_snapshot_sha256", "format",
    "asset_inputs", "execution", "authenticity", "review", "experiment",
    "lifecycle", "outputs",
)
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
    if set(document) != set(REQUIRED):
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


def _validate_authenticity(value: dict[str, Any]) -> None:
    for field in ("disclosure_requirements", "rights_requirements"):
        items = value.get(field)
        if not isinstance(items, list) or any(not isinstance(item, str) for item in items):
            raise ManifestError("manifest authenticity requirements must be arrays")
    provenance = value.get("provenance")
    if provenance is not None:
        valid = isinstance(provenance, dict) and set(provenance) == {"source", "recipe_sha256"}
        valid = valid and isinstance(provenance.get("source"), str) and bool(provenance.get("source"))
        recipe = provenance.get("recipe_sha256") if isinstance(provenance, dict) else None
        valid = valid and isinstance(recipe, str) and bool(SHA256_RE.fullmatch(recipe))
        if not valid:
            raise ManifestError("manifest provenance fields are invalid")
    _validate_clearance(value.get("rights_clearance"))


def _validate_clearance(clearance: Any) -> None:
    if clearance is None:
        return
    if not isinstance(clearance, dict) or set(clearance) != {"license", "consent", "territory", "expires_at"}:
        raise ManifestError("manifest rights-clearance fields are invalid")
    for field in ("license", "consent", "territory"):
        if not isinstance(clearance.get(field), str) or not clearance.get(field):
            raise ManifestError("manifest rights-clearance fields are invalid")
    expires_at = clearance.get("expires_at")
    if expires_at is not None and not isinstance(expires_at, str):
        raise ManifestError("manifest rights-clearance fields are invalid")
    if expires_at:
        try:
            date.fromisoformat(expires_at)
        except ValueError as error:
            raise ManifestError("manifest rights-clearance expiry must be an ISO date") from error


def _validate_review(value: dict[str, Any]) -> None:
    criteria = value.get("criteria")
    if not isinstance(criteria, list) or not criteria:
        raise ManifestError("manifest review fields are invalid")
    if any(not isinstance(item, str) for item in criteria):
        raise ManifestError("manifest review fields are invalid")
    status = value.get("status")
    if not isinstance(status, str) or status not in {"required", "pending", "approved", "rejected"}:
        raise ManifestError("manifest review fields are invalid")
    decision_by = value.get("decision_by")
    if decision_by is not None and (not isinstance(decision_by, str) or not decision_by):
        raise ManifestError("manifest review decision_by is invalid")
    decision_at = value.get("decision_at")
    if decision_at is None:
        return
    if not isinstance(decision_at, str) or not decision_at:
        raise ManifestError("manifest review decision_at is invalid")
    try:
        parsed = datetime.fromisoformat(decision_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise ManifestError("manifest review decision_at is invalid") from error
    if parsed.tzinfo is None:
        raise ManifestError("manifest review decision_at requires a timezone")


def _valid_reference(item: Any) -> bool:
    if not isinstance(item, dict) or set(item) != {"reference", "required"}:
        return False
    return isinstance(item.get("reference"), str) and bool(item.get("reference")) and isinstance(item.get("required"), bool)


def _valid_output(item: Any) -> bool:
    if not isinstance(item, dict) or set(item) != {"path", "sha256", "media_type"}:
        return False
    for field in ("path", "sha256", "media_type"):
        if not isinstance(item.get(field), str) or not item.get(field):
            return False
    return True


def _validate_collections(document: dict[str, Any]) -> None:
    experiment = document["experiment"]
    if any(not isinstance(experiment.get(field), str) or not experiment.get(field) for field in ("experiment_id", "hypothesis")):
        raise ManifestError("manifest experiment fields are invalid")
    evidence = document["lifecycle"].get("status_evidence")
    if not isinstance(evidence, list) or any(not isinstance(item, str) for item in evidence):
        raise ManifestError("manifest lifecycle evidence must be an array")
    inputs = document["asset_inputs"]
    if not isinstance(inputs, list) or any(not _valid_reference(item) for item in inputs):
        raise ManifestError("manifest asset_inputs must contain reference objects")
    outputs = document["outputs"]
    if not isinstance(outputs, list) or any(not _valid_output(item) for item in outputs):
        raise ManifestError("manifest outputs must contain path, sha256, and media_type objects")


def _validate_status(document: dict[str, Any]) -> None:
    if document["channel"] not in CHANNELS:
        raise ManifestError("manifest has an unsupported channel")
    if not SHA256_RE.fullmatch(document["input_snapshot_sha256"]):
        raise ManifestError("manifest input snapshot must be a SHA-256 reference")
    if any(not SHA256_RE.fullmatch(output["sha256"]) for output in document["outputs"]):
        raise ManifestError("manifest output hashes must be SHA-256 references")
    status = document["lifecycle"].get("status")
    completed = {"generated", "edited", "approved"}
    incomplete = {"brief_ready", "prompts_ready", "queued", "running", "blocked"}
    if not isinstance(status, str) or status not in completed | incomplete | {"review_required", "rejected", "failed"}:
        raise ManifestError("manifest lifecycle status is unsupported")
    if status in completed and not document["outputs"]:
        raise ManifestError(f"manifest status {status} requires verified outputs")
    if status in incomplete and document["outputs"]:
        raise ManifestError(f"manifest status {status} must not claim completed outputs")
    if status == "blocked" and document["execution"].get("status") != "blocked":
        raise ManifestError("blocked lifecycle requires an explicit blocked execution route")


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
