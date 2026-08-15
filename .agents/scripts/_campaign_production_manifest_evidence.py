"""Evidence and lifecycle validation for production manifests."""

from __future__ import annotations

from datetime import date, datetime
from typing import Any

from _campaign_production_definitions import SHA256_RE, ManifestError


def _validate_requirements(value: dict[str, Any]) -> None:
    for field in ("disclosure_requirements", "rights_requirements"):
        items = value.get(field)
        if not isinstance(items, list) or any(not isinstance(item, str) for item in items):
            raise ManifestError("manifest authenticity requirements must be arrays")


def _valid_provenance_shape(provenance: Any) -> bool:
    return isinstance(provenance, dict) and set(provenance) == {"source", "recipe_sha256"}


def _valid_provenance_source(provenance: dict[str, Any]) -> bool:
    return isinstance(provenance.get("source"), str) and bool(provenance.get("source"))


def _valid_recipe(recipe: Any) -> bool:
    return isinstance(recipe, str) and bool(SHA256_RE.fullmatch(recipe))


def _validate_provenance(provenance: Any) -> None:
    if provenance is not None:
        valid = _valid_provenance_shape(provenance)
        valid = valid and _valid_provenance_source(provenance)
        recipe = provenance.get("recipe_sha256") if isinstance(provenance, dict) else None
        valid = valid and _valid_recipe(recipe)
        if not valid:
            raise ManifestError("manifest provenance fields are invalid")


def validate_authenticity(value: dict[str, Any]) -> None:
    _validate_requirements(value)
    _validate_provenance(value.get("provenance"))
    _validate_clearance(value.get("rights_clearance"))


def _validate_clearance(clearance: Any) -> None:
    if clearance is None:
        return
    expected = {"license", "consent", "territory", "expires_at"}
    if not isinstance(clearance, dict) or set(clearance) != expected:
        raise ManifestError("manifest rights-clearance fields are invalid")
    for field in ("license", "consent", "territory"):
        if not isinstance(clearance.get(field), str) or not clearance.get(field):
            raise ManifestError("manifest rights-clearance fields are invalid")
    _validate_clearance_expiry(clearance.get("expires_at"))


def _validate_clearance_expiry(expires_at: Any) -> None:
    if expires_at is not None and not isinstance(expires_at, str):
        raise ManifestError("manifest rights-clearance fields are invalid")
    if expires_at:
        try:
            date.fromisoformat(expires_at)
        except ValueError as error:
            raise ManifestError("manifest rights-clearance expiry must be an ISO date") from error


def _validate_review_core(value: dict[str, Any]) -> None:
    criteria = value.get("criteria")
    if not isinstance(criteria, list) or not criteria:
        raise ManifestError("manifest review fields are invalid")
    if any(not isinstance(item, str) for item in criteria):
        raise ManifestError("manifest review fields are invalid")
    status = value.get("status")
    if not isinstance(status, str) or status not in {"required", "pending", "approved", "rejected"}:
        raise ManifestError("manifest review fields are invalid")


def _validate_decision_by(decision_by: Any) -> None:
    if decision_by is not None and (not isinstance(decision_by, str) or not decision_by):
        raise ManifestError("manifest review decision_by is invalid")


def _validate_decision_at(decision_at: Any) -> None:
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


def validate_review(value: dict[str, Any]) -> None:
    _validate_review_core(value)
    _validate_decision_by(value.get("decision_by"))
    _validate_decision_at(value.get("decision_at"))


def _valid_reference(item: Any) -> bool:
    if not isinstance(item, dict) or set(item) != {"reference", "required"}:
        return False
    reference = item.get("reference")
    return isinstance(reference, str) and bool(reference) and isinstance(item.get("required"), bool)


def _valid_output(item: Any) -> bool:
    if not isinstance(item, dict) or set(item) != {"path", "sha256", "media_type"}:
        return False
    for field in ("path", "sha256", "media_type"):
        if not isinstance(item.get(field), str) or not item.get(field):
            return False
    return True


def _validate_experiment(document: dict[str, Any]) -> None:
    experiment = document["experiment"]
    invalid_experiment = any(not isinstance(experiment.get(field), str) or not experiment.get(field) for field in ("experiment_id", "hypothesis"))
    if invalid_experiment:
        raise ManifestError("manifest experiment fields are invalid")


def _validate_lifecycle_evidence(document: dict[str, Any]) -> None:
    evidence = document["lifecycle"].get("status_evidence")
    if not isinstance(evidence, list) or any(not isinstance(item, str) for item in evidence):
        raise ManifestError("manifest lifecycle evidence must be an array")


def _validate_assets(document: dict[str, Any]) -> None:
    inputs = document["asset_inputs"]
    if not isinstance(inputs, list) or any(not _valid_reference(item) for item in inputs):
        raise ManifestError("manifest asset_inputs must contain reference objects")
    outputs = document["outputs"]
    if not isinstance(outputs, list) or any(not _valid_output(item) for item in outputs):
        raise ManifestError("manifest outputs must contain path, sha256, and media_type objects")


def validate_collections(document: dict[str, Any]) -> None:
    _validate_experiment(document)
    _validate_lifecycle_evidence(document)
    _validate_assets(document)
